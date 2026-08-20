package com.ideoalabs.rotelyx

import android.content.Context
import android.util.Size
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.util.concurrent.Executors

/**
 * The back camera, as a stream of grey frames Dart can read a QR code out of.
 *
 * # What is here and what is deliberately not
 *
 * The decoder is not here. `lib/qr/` already contains a complete QR reader that
 * has been tested against every version and correction level, against damage up
 * to the correction budget, and against a photograph taken at an angle in poor
 * light. It takes a width, a height and one byte of brightness per pixel.
 *
 * So this file's whole job is to produce those three things. Reimplementing the
 * decode in Kotlin, or reaching for a library that does, would mean two decoders
 * that agree until they do not, and the one that shipped would be the one with
 * no tests.
 *
 * # Why the luma plane is free
 *
 * The camera hands back YUV_420_888, in which the first plane is exactly one
 * byte of brightness per pixel. That is already what the decoder wants, so
 * there is no colour conversion anywhere in this path: the bytes are copied out
 * and passed along. A QR code is black and white, and colour would be thrown
 * away in the first step of decoding it.
 *
 * The one wrinkle is `rowStride`. The camera is allowed to pad each row out to
 * a convenient width, and the padding is not image data. Ignoring it produces a
 * picture that shears diagonally, which still looks like a photograph and never
 * decodes.
 *
 * # Why the frames are pulled rather than pushed
 *
 * An analyser that pushed every frame to Dart would send thirty a second
 * through the platform channel and drop most of them, because the decode takes
 * longer than the gap between frames. So the newest frame is kept here and Dart
 * asks when it is ready for one. Older frames are dropped by the camera itself
 * through `STRATEGY_KEEP_ONLY_LATEST`, which is what that setting is for.
 */
class QrCamera(
    private val context: Context,
    private val textures: TextureRegistry,
) {

    companion object {
        const val CHANNEL = "rotelyx/camera"

        /**
         * What to ask the camera for.
         *
         * Not the highest available. A QR code fills a good part of the frame
         * and its modules are large; the decoder locates the three corner
         * squares and reads a grid, and a five megapixel frame gives it the
         * same grid with twenty times the bytes to copy through a platform
         * channel. This is the resolution at which a code held at arm's length
         * is comfortably readable.
         */
        private val WANTED = Size(1280, 720)
    }

    private var provider: ProcessCameraProvider? = null
    private var entry: TextureRegistry.SurfaceTextureEntry? = null
    private val analysis = Executors.newSingleThreadExecutor()

    /** The most recent frame, replaced as they arrive and read when asked for. */
    @Volatile
    private var latest: Frame? = null

    private class Frame(val bytes: ByteArray, val width: Int, val height: Int)

    /**
     * CameraX binds to a lifecycle, and a `FlutterActivity` is not one this
     * code should reach into. Owning a small one is fewer assumptions than
     * casting whatever the embedding happens to extend this year.
     */
    private inner class Owner : LifecycleOwner {
        val registry = LifecycleRegistry(this)
        override val lifecycle: Lifecycle get() = registry
    }

    private var owner: Owner? = null

    fun start(result: MethodChannel.Result) {
        if (provider != null) {
            result.error("already", "the camera is already open", null)
            return
        }

        val future = ProcessCameraProvider.getInstance(context)
        future.addListener({
            try {
                bind(future.get(), result)
            } catch (e: Exception) {
                result.error("camera", e.message ?: "the camera would not open", null)
            }
        }, androidx.core.content.ContextCompat.getMainExecutor(context))
    }

    private fun bind(cameras: ProcessCameraProvider, result: MethodChannel.Result) {
        val surface = textures.createSurfaceTexture()
        entry = surface

        val resolution = ResolutionSelector.Builder()
            .setResolutionStrategy(
                ResolutionStrategy(WANTED, ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER)
            )
            .build()

        val preview = Preview.Builder().setResolutionSelector(resolution).build()
        preview.setSurfaceProvider { request ->
            val texture = surface.surfaceTexture()
            texture.setDefaultBufferSize(
                request.resolution.width,
                request.resolution.height
            )
            request.provideSurface(
                android.view.Surface(texture),
                analysis
            ) { it.surface.release() }
        }

        val reader = ImageAnalysis.Builder()
            .setResolutionSelector(resolution)
            // Drop what cannot be kept up with, rather than queueing it. A QR
            // code that was in front of the camera four frames ago is not
            // useful, and a backlog turns a slow decode into a frozen preview.
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
            .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_YUV_420_888)
            .build()

        reader.setAnalyzer(analysis) { image ->
            try {
                latest = luma(image)
            } finally {
                // Not closing this stops the camera after a handful of frames,
                // with no error anywhere: the buffer pool simply runs out.
                image.close()
            }
        }

        val own = Owner()
        owner = own
        own.registry.currentState = Lifecycle.State.RESUMED

        cameras.unbindAll()
        cameras.bindToLifecycle(own, CameraSelector.DEFAULT_BACK_CAMERA, preview, reader)
        provider = cameras

        result.success(
            mapOf(
                "texture" to surface.id(),
                "width" to WANTED.width,
                "height" to WANTED.height,
            )
        )
    }

    /**
     * The brightness plane, with the row padding removed.
     *
     * `rowStride` is how many bytes the camera puts between the start of one
     * row and the start of the next, and it is allowed to be wider than the
     * image. Copying the buffer straight out therefore shifts each row a little
     * further right than the last, which shears the picture diagonally. It
     * still looks like a photograph. It never decodes.
     */
    private fun luma(image: ImageProxy): Frame {
        val plane = image.planes[0]
        val buffer = plane.buffer
        val width = image.width
        val height = image.height
        val stride = plane.rowStride

        val out = ByteArray(width * height)

        if (stride == width) {
            buffer.get(out, 0, out.size)
        } else {
            val row = ByteArray(stride)
            var offset = 0
            for (y in 0 until height) {
                val remaining = buffer.remaining()
                if (remaining < stride) {
                    buffer.get(row, 0, remaining)
                } else {
                    buffer.get(row, 0, stride)
                }
                row.copyInto(out, offset, 0, width)
                offset += width
            }
        }

        return Frame(out, width, height)
    }

    /** Hand Dart the newest frame, or nothing if none has arrived yet. */
    private fun frame(result: MethodChannel.Result) {
        val held = latest
        if (held == null) {
            result.success(null)
            return
        }
        result.success(
            mapOf(
                "bytes" to held.bytes,
                "width" to held.width,
                "height" to held.height,
            )
        )
    }

    fun stop() {
        owner?.registry?.currentState = Lifecycle.State.DESTROYED
        owner = null
        provider?.unbindAll()
        provider = null
        entry?.release()
        entry = null
        latest = null
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> start(result)
            "frame" -> frame(result)
            "stop" -> {
                stop()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    fun dispose() {
        stop()
        analysis.shutdown()
    }
}
