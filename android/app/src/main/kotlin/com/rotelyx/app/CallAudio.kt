package com.ideoalabs.rotelyx

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.AutomaticGainControl
import android.media.audiofx.NoiseSuppressor
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The microphone and the speaker, in twenty millisecond frames.
 *
 * # What this does and does not decide
 *
 * It moves samples. It does not encode, encrypt, conceal loss or choose a
 * bitrate: all of that is in the Rust library, reached from Dart, and putting
 * any of it here would mean two implementations of a codec.
 *
 * The contract is one number: [FRAME], 960 signed sixteen bit samples, mono, at
 * 48 kHz, which is twenty milliseconds. The codec was built around that window
 * and cannot negotiate, so this produces exactly that and nothing else.
 *
 * # Why the frames are pulled rather than pushed
 *
 * `AudioRecord` fills a buffer on its own thread at its own rate. Pushing every
 * frame across the platform channel the moment it appears would send fifty a
 * second whether or not anything was ready to encode them, and a channel that
 * is behind drops the newest rather than the oldest.
 *
 * So captured frames queue here, briefly, and Dart takes one when it has
 * finished with the last. The queue is bounded: on a call, a frame from a
 * second ago is not worth sending, and holding it would turn a slow moment into
 * a permanently late one.
 *
 * # The three effects, and why they are asked for rather than assumed
 *
 * Echo cancellation, noise suppression and gain control are hardware on most
 * phones and absent on some. Each is requested and each failure is survivable:
 * a call without echo cancellation is unpleasant, and a call that refused to
 * start because a chip was missing is worse.
 */
class CallAudio {

    companion object {
        const val CHANNEL = "rotelyx/call-audio"

        /** Samples in one frame. Twenty milliseconds at [RATE]. */
        const val FRAME = 960

        /** What the codec was built around. Not negotiable. */
        const val RATE = 48000

        /**
         * How many captured frames may wait before the oldest is dropped.
         *
         * Ten, which is two hundred milliseconds. Past that a frame is no
         * longer worth sending: the person it belongs to has moved on, and
         * delivering it late makes the call sound further behind rather than
         * more complete.
         */
        private const val BACKLOG = 10
    }

    private var record: AudioRecord? = null
    private var track: AudioTrack? = null

    private var echo: AcousticEchoCanceler? = null
    private var noise: NoiseSuppressor? = null
    private var gain: AutomaticGainControl? = null

    private val running = AtomicBoolean(false)
    private var capture: Thread? = null

    /** Captured frames waiting to be encoded. */
    private val ready = ArrayDeque<ByteArray>()
    private val lock = Object()

    /** Frames dropped because nothing collected them in time. */
    @Volatile
    private var dropped = 0

    fun start(result: MethodChannel.Result) {
        if (running.get()) {
            result.success(true)
            return
        }

        val inSize = AudioRecord.getMinBufferSize(
            RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT
        )
        val outSize = AudioTrack.getMinBufferSize(
            RATE, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT
        )

        if (inSize <= 0 || outSize <= 0) {
            result.error("audio", "this device will not open 48 kHz mono", null)
            return
        }

        try {
            // VOICE_COMMUNICATION rather than MIC. It is what turns on the
            // platform's own echo cancellation and tuning for a call; MIC gives
            // a flat recording, which is right for recording and wrong here.
            val recorder = AudioRecord(
                MediaRecorder.AudioSource.VOICE_COMMUNICATION,
                RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                // Four frames of room. Smaller and a scheduling hiccup drops
                // audio; much larger and the latency is audible.
                maxOf(inSize, FRAME * 2 * 4)
            )

            if (recorder.state != AudioRecord.STATE_INITIALIZED) {
                recorder.release()
                result.error("audio", "the microphone would not open", null)
                return
            }

            attachEffects(recorder.audioSessionId)

            val player = AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        // VOICE_COMMUNICATION again, so the system routes it to
                        // the earpiece and applies its call processing.
                        .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build()
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(RATE)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .build()
                )
                .setBufferSizeInBytes(maxOf(outSize, FRAME * 2 * 4))
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()

            record = recorder
            track = player
            dropped = 0

            recorder.startRecording()
            player.play()
            running.set(true)

            capture = Thread({ pump(recorder) }, "rotelyx-capture").apply {
                // Above normal, below the audio thread itself. A capture loop
                // that loses the processor drops frames, and dropped frames on
                // a call are gaps somebody hears.
                priority = Thread.MAX_PRIORITY - 1
                start()
            }

            result.success(true)
        } catch (e: SecurityException) {
            // RECORD_AUDIO was refused. Reported rather than crashed: a call
            // with no microphone is a call that cannot start, and the person
            // should be told which of the two happened.
            stop()
            result.error("permission", "the microphone permission was refused", null)
        } catch (e: Exception) {
            stop()
            result.error("audio", e.message ?: "the audio devices would not open", null)
        }
    }

    /**
     * Read frames until stopped.
     *
     * Blocking reads on their own thread, because that is what `AudioRecord` is
     * designed for and because a polled read on a timer drifts against the
     * device's own clock.
     */
    private fun pump(recorder: AudioRecord) {
        val frame = ShortArray(FRAME)

        while (running.get()) {
            var filled = 0
            while (filled < FRAME && running.get()) {
                val read = recorder.read(frame, filled, FRAME - filled)
                if (read <= 0) break
                filled += read
            }
            if (filled < FRAME) continue

            val bytes = ByteArray(FRAME * 2)
            ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
                .asShortBuffer().put(frame)

            synchronized(lock) {
                // The oldest goes, not the newest. A backlog means the encoder
                // is behind, and the frame worth keeping is the one closest to
                // now.
                if (ready.size >= BACKLOG) {
                    ready.removeFirst()
                    dropped++
                }
                ready.addLast(bytes)
            }
        }
    }

    /** Hand over the oldest captured frame, or nothing. */
    private fun take(result: MethodChannel.Result) {
        val frame = synchronized(lock) { ready.removeFirstOrNull() }
        result.success(frame)
    }

    /** Play one decoded frame. */
    private fun play(call: MethodCall, result: MethodChannel.Result) {
        val pcm = call.argument<ByteArray>("pcm")
        val player = track

        if (pcm == null || player == null) {
            result.success(false)
            return
        }

        // Non-blocking. A write that blocks holds the caller's thread until the
        // device drains, which on the interface thread is a frozen application
        // and on any thread is a loop that no longer keeps its own time.
        val written = player.write(pcm, 0, pcm.size, AudioTrack.WRITE_NON_BLOCKING)
        result.success(written > 0)
    }

    private fun attachEffects(sessionId: Int) {
        // Each is hardware on most phones and missing on some. Each failure is
        // survivable: a call without echo cancellation is unpleasant, and one
        // that refused to start over a missing chip is worse.
        if (AcousticEchoCanceler.isAvailable()) {
            echo = runCatching { AcousticEchoCanceler.create(sessionId) }.getOrNull()
            echo?.enabled = true
        }
        if (NoiseSuppressor.isAvailable()) {
            noise = runCatching { NoiseSuppressor.create(sessionId) }.getOrNull()
            noise?.enabled = true
        }
        if (AutomaticGainControl.isAvailable()) {
            gain = runCatching { AutomaticGainControl.create(sessionId) }.getOrNull()
            gain?.enabled = true
        }
    }

    /** Earpiece or speakerphone. */
    private fun route(call: MethodCall, context: android.content.Context,
                      result: MethodChannel.Result) {
        val loud = call.argument<Boolean>("speaker") ?: false
        val audio = context.getSystemService(android.content.Context.AUDIO_SERVICE)
            as AudioManager

        audio.mode = AudioManager.MODE_IN_COMMUNICATION
        @Suppress("DEPRECATION")
        audio.isSpeakerphoneOn = loud
        result.success(true)
    }

    fun stop() {
        running.set(false)
        capture?.join(500)
        capture = null

        echo?.release(); echo = null
        noise?.release(); noise = null
        gain?.release(); gain = null

        record?.runCatching { stop() }
        record?.release()
        record = null

        track?.runCatching { stop() }
        track?.release()
        track = null

        synchronized(lock) { ready.clear() }
    }

    fun handle(call: MethodCall, context: android.content.Context,
               result: MethodChannel.Result) {
        when (call.method) {
            "start" -> start(result)
            "take" -> take(result)
            "play" -> play(call, result)
            "route" -> route(call, context, result)
            "dropped" -> result.success(dropped)
            "stop" -> {
                stop()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }
}
