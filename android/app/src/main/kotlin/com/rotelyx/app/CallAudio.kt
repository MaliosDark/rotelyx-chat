package com.rotelyx.app

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaPlayer
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

        /** Log tag for the level measurement. Silent unless made loggable. */
        private const val TAG = "RotelyxAudio"
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

    fun start(context: android.content.Context, result: MethodChannel.Result) {
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

        // The call mode, before either device is opened.
        //
        // It was only ever set in `route`, which runs when somebody presses
        // the speaker button. A call where nobody pressed it therefore ran
        // with the system in its ordinary mode, and in that mode the platform
        // does not set up the voice path: VOICE_COMMUNICATION is accepted,
        // a microphone is selected, and the echo canceller is enabled against
        // a reference the mode has not arranged, so what came back was
        // silence. Whichever phone had had the button pressed, or had been
        // left in the mode by an earlier call, captured better than the other,
        // which is the asymmetry that gave this away.
        val manager = context.getSystemService(android.content.Context.AUDIO_SERVICE)
            as AudioManager
        manager.mode = AudioManager.MODE_IN_COMMUNICATION

        try {
            // VOICE_COMMUNICATION, and nothing attached on top of it.
            //
            // The source and the effects below are one decision, not two, and
            // they were made separately: the source turned on the platform's
            // echo cancellation, suppression and gain, and then the same three
            // were attached again in software. Two echo cancellers in series
            // is not twice the cancellation. The second works on a signal the
            // first has already altered and can no longer tell a near voice
            // from what it is there to remove, and what came out was a call
            // whose microphone measured 10 to 15 rms against a full scale of
            // 32767 while somebody spoke into it.
            //
            // MIC was tried instead and measured worse, 1 to 28, which is the
            // other half of the same mistake: those three effects are defined
            // against VOICE_COMMUNICATION, and on a flat capture they are not
            // the processing a call needs.
            //
            // So: the platform's path, used as it is meant to be used, with
            // the platform doing the processing once. `attachEffects` stays in
            // the file because a device that does not implement this source
            // properly is the case it was written for, and that case is a
            // fallback rather than an addition.
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

            // Gain, and only gain.
            //
            // The echo canceller and the suppressor are the platform's to run
            // on this source, and running a second pair over the top is what
            // removed the voice. Gain is the one of the three that measurement
            // says is not being applied: with the call mode set and the voice
            // route selected, a person speaking close to the phone captured at
            // about -44 dBFS, roughly 20 dB under where speech belongs, and it
            // stayed there. The far end was playing that voice correctly and
            // nobody could hear it, because the touch tones mixed in later sit
            // at -12 dBFS and are 26 dB louder than the person talking.
            //
            // Attached after the mode is set, which is the part that was wrong
            // when all three were attached together and none of them worked.
            // The device's own gain is deliberately not attached beside
            // `makeUp`. Two things adjusting the same level cannot see each
            // other, so each reacts to the other's correction: the level
            // walks, and what a person hears is a voice that swells and
            // fades. `makeUp` is the one that stays, because it is the one
            // this project can measure and reason about.

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

            // The loudspeaker first, then the microphone.
            //
            // This platform enables an echo reference when the capture opens,
            // and takes it from whatever output is running at that moment. It
            // was opening the microphone first, so the reference was taken
            // against nothing: the log said `enabling echo-reference` and
            // `out_snd_device(0: )` on the same line. A canceller given no
            // reference has no way to tell a voice from an echo.
            player.play()
            recorder.startRecording()
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

            makeUp(frame)
            measure(frame)

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

    /** Where speech should peak.
     *
     * 13000, a little under half of full scale, which leaves about eight
     * decibels over the loudest syllable for the limiter below to catch. It
     * was 8192, and measured across a working call that put speech at the far
     * end around 2500 rms: audible, and quieter than a person expects a phone
     * call to be.
     */
    private val target = 13000.0

    /** The most this may lift a quiet capture. 24 dB. */
    private val ceiling = 16.0

    private var followed = 0.0
    private var applied = 1.0

    /**
     * Lift a capture that the device left too quiet, and never lower one.
     *
     * # Why this is here at all
     *
     * `AutomaticGainControl` is the platform's answer and is attached above,
     * and it is not offered by every device. Measured on two of them with the
     * call mode set and the voice route selected: a person speaking close to
     * the phone captured at about -44 dBFS and stayed there, roughly 20 dB
     * under where speech belongs. The far end played that voice correctly,
     * with a neighbouring sample correlation above 0.9, and nobody could hear
     * it: the touch tones mixed in later sit at -12 dBFS, so they arrived 26
     * dB louder than the person talking, and a call carried its keypad and not
     * its voices.
     *
     * # Why it only ever multiplies up
     *
     * So that it cannot fight the hardware. Where the device's own gain is
     * working the peak is already near [target], the factor computes to one,
     * and this does nothing at all. It is a floor under a device that is not
     * doing the job, not a second opinion about a device that is.
     *
     * # What it does to a silent room
     *
     * Lifts the noise floor by up to [ceiling], which is what any automatic
     * gain does and why the ceiling is not higher. A room measuring 5 rms
     * comes out at 80, which is still nothing anybody hears.
     *
     * The follower decays slowly and rises immediately, so a loud syllable
     * takes the gain down at once and it comes back over about a second rather
     * than pumping between words. Clamped rather than allowed to wrap: sixteen
     * bit addition that overflows turns a peak into its opposite, which is a
     * click.
     */
    private fun makeUp(frame: ShortArray) {
        var peak = 0
        for (v in frame) {
            val a = if (v < 0) -v.toInt() else v.toInt()
            if (a > peak) peak = a
        }

        followed = if (peak > followed) peak.toDouble() else followed * 0.98
        if (followed < 1.0) return

        val wanted = (target / followed).coerceIn(1.0, ceiling)

        // Down at once, up slowly, which is the way round every compressor
        // does it and the way round this had backwards.
        //
        // It moved five percent a frame in both directions. Five percent of a
        // twenty millisecond frame is about a second to travel the range, so
        // after a silence had lifted the gain toward [ceiling], the first loud
        // syllable was multiplied by a factor meant for the quiet before it,
        // for a good part of a second, and clipped for all of it. Every word
        // began distorted and the middle of it was clean, which is what a
        // person hears as a voice tearing rather than a voice that is too
        // loud.
        //
        // Needing less gain is knowledge about right now and is taken
        // immediately. Needing more is a guess about a silence that a word may
        // be about to end, and is taken slowly.
        val from = applied
        applied = if (wanted < applied) wanted else applied + (wanted - applied) * 0.02
        if (from <= 1.001 && applied <= 1.001) return

        // Ramped across the frame, not applied to it.
        //
        // One factor for a whole frame steps the waveform at the boundary, and
        // with an instant attack that step is the whole range: a frame ending
        // at sixteen times followed by one at one and a half is a twenty
        // decibel jump between two adjacent samples. That is a click, it
        // happens fifty times a second, and it sits on top of the voice as a
        // buzz at the frame rate. What a person hears is a signal that is
        // plainly loud and plainly not speech.
        //
        // The touch tones are mixed in on the Dart side, after this, so they
        // are the one thing in the call this never touched. They came through
        // clean while the voices did not, which is what pointed here.
        val step = (applied - from) / frame.size
        for (i in frame.indices) {
            val lifted = (frame[i] * (from + step * i)).toInt()
            frame[i] = when {
                lifted > 32767 -> 32767
                lifted < -32768 -> -32768
                else -> lifted
            }.toShort()
        }
    }

    private var writes = 0L
    private var shortWrites = 0L
    private var lostBytes = 0L

    private var measured = 0L

    /**
     * Say how loud the microphone is, here, before anything else sees it.
     *
     * This is the one measurement that separates the two remaining
     * explanations for a call that carries touch tones and not a voice. The
     * tones are mixed in on the Dart side, after this point, so everything
     * downstream of here is already proven to work by the fact that they
     * arrive: the codec, the encryption, the relay and the far speaker.
     *
     * That leaves the microphone, and two ways for it to be silent that need
     * opposite fixes. Either the platform is handing back silence on this
     * route, in which case the rate or the source is wrong and the answer is
     * to capture where the device is willing to; or it is handing back a voice
     * that stops being one between here and Dart, in which case the fault is
     * in the crossing, which is where the last one of these lived.
     *
     * Once a second, so it costs a division per frame and a line per fifty.
     *
     * # Why it is off unless asked for
     *
     * These are loudness and nothing else: one number for how loud a twentieth
     * of a second was. Speech cannot be recovered from them and they are not
     * audio. But a release build has no business writing anything about a call
     * to a log every other application on the phone can read, and "it is only
     * a level" is the argument every unnecessary log entry is defended with.
     * So it compiles out unless the build is a debug one.
     */
    private fun measure(frame: ShortArray) {
        // Off unless somebody turns it on from a cable:
        //
        //     adb shell setprop log.tag.RotelyxAudio INFO
        //
        // which is Android's own switch for this and does not survive a
        // reboot. A shipped build writes nothing about a call anywhere.
        if (!android.util.Log.isLoggable(TAG, android.util.Log.INFO)) return

        measured++
        if (measured % 50L != 0L) return

        var sum = 0.0
        var peak = 0
        for (s in frame) {
            sum += s.toDouble() * s.toDouble()
            val a = if (s < 0) -s.toInt() else s.toInt()
            if (a > peak) peak = a
        }

        val rms = Math.sqrt(sum / frame.size).toInt()
        android.util.Log.i(TAG, "ROTELYX_MIC frame=$measured rms=$rms peak=$peak")
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

        // Counted, because a short write is silent otherwise.
        //
        // A non-blocking write takes what fits and returns how much that was.
        // The rest is not queued and not retried: it is gone, in the middle of
        // a frame, which is a hole in the waveform rather than a gap between
        // frames. Fifty of those a second is the sound of something grinding.
        if (written < pcm.size) {
            shortWrites++
            lostBytes += pcm.size - maxOf(written, 0)
        }
        if (android.util.Log.isLoggable(TAG, android.util.Log.INFO)) {
            writes++
            if (writes % 50L == 0L) {
                android.util.Log.i(
                    TAG,
                    "ROTELYX_OUT writes=$writes short=$shortWrites lost=$lostBytes"
                )
            }
        }

        result.success(written > 0)
    }

    /**
     * Play one of the short generated tones, outside the call's own stream.
     *
     * Through a `MediaPlayer` on a resource rather than through [track],
     * because [track] carries the far end's voice and is fed a frame at a time
     * by the call loop: mixing a tone into it would mean either interrupting
     * that or resampling into it, and both are more machinery than a half
     * second sound is worth.
     *
     * Routed as voice communication so it follows the call: on a speakerphone
     * it comes out of the loudspeaker, and against an ear it comes out of the
     * earpiece, which is where somebody holding the phone is listening. A tone
     * that announces a call and plays out of the wrong opening is worse than
     * no tone.
     *
     * Released when it finishes. One player per tone rather than one kept
     * alive: these play at most twice in a call, and a retained player holds
     * an audio focus this application has no reason to hold between calls.
     */
    private fun tone(call: MethodCall, context: android.content.Context, result: MethodChannel.Result) {
        val name = call.argument<String>("name")
        val id = when (name) {
            "connected" -> R.raw.rotelyx_connected
            "failed" -> R.raw.rotelyx_failed
            else -> {
                result.success(false)
                return
            }
        }

        val player = MediaPlayer()
        val played = runCatching {
            val fd = context.resources.openRawResourceFd(id)
            player.setDataSource(fd.fileDescriptor, fd.startOffset, fd.length)
            fd.close()
            player.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
            )
            player.setOnCompletionListener { it.release() }
            player.prepare()
            player.start()
            true
        }.getOrElse {
            player.release()
            false
        }

        result.success(played)
    }

    /** Automatic gain, when the device offers it. */
    private fun attachGain(sessionId: Int) {
        if (!AutomaticGainControl.isAvailable()) return
        gain = runCatching { AutomaticGainControl.create(sessionId) }.getOrNull()
        gain?.enabled = true
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

    fun stop(context: android.content.Context? = null) {
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

        // Back to the ordinary mode. `start` puts the system into its call
        // mode and leaving it there is not this application's to do: it
        // changes how every other application's audio is routed, and a phone
        // whose media plays out of the earpiece after a call is one somebody
        // reboots.
        context?.let {
            val manager = it.getSystemService(android.content.Context.AUDIO_SERVICE)
                as AudioManager
            manager.mode = AudioManager.MODE_NORMAL
        }
    }

    fun handle(call: MethodCall, context: android.content.Context,
               result: MethodChannel.Result) {
        when (call.method) {
            "start" -> start(context, result)
            "take" -> take(result)
            "play" -> play(call, result)
            "route" -> route(call, context, result)
            "dropped" -> result.success(dropped)
            "tone" -> tone(call, context, result)
            "stop" -> {
                stop(context)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }
}
