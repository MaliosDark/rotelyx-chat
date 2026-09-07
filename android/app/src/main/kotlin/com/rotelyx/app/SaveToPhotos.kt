package com.rotelyx.app

import android.content.ContentValues
import android.graphics.Bitmap
import android.os.Build
import android.provider.MediaStore
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.OutputStream

/**
 * Keeping a copy of a picture somebody was sent.
 *
 * # What this asks for, which on a modern Android is nothing
 *
 * `MediaStore` lets an application insert its own picture into the shared
 * collection without any permission at all from API 29 onwards, which is
 * every device this application supports. There is no runtime prompt and no
 * line on the permissions screen, because nothing is being read: this puts one
 * file in and can neither list nor open what is already there.
 *
 * The same shape as `ios/Runner/SaveToPhotos.swift`, which uses the add-only
 * photo permission for the same reason.
 *
 * # Why it takes pixels rather than a file
 *
 * What arrives is this application's own codec, which nothing on the system
 * can decode. Dart hands over the pixels and this writes a PNG of them, which
 * the gallery understands.
 */
class SaveToPhotos(private val activity: MainActivity) {

    companion object {
        const val CHANNEL = "rotelyx/photos"
    }

    private fun save(call: MethodCall, result: MethodChannel.Result) {
        val bytes = call.argument<ByteArray>("bytes")
        val width = call.argument<Int>("width") ?: 0
        val height = call.argument<Int>("height") ?: 0
        val name = call.argument<String>("name") ?: "Rotelyx"

        if (bytes == null || width <= 0 || height <= 0 ||
            bytes.size < width * height * 4
        ) {
            result.error("undecodable", "that picture could not be prepared", null)
            return
        }

        try {
            val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            // Dart sends RGBA and Android wants ARGB, so the bytes are turned
            // into pixels here rather than being copied straight in, which
            // would swap red and blue.
            val pixels = IntArray(width * height)
            for (i in pixels.indices) {
                val at = i * 4
                val r = bytes[at].toInt() and 0xFF
                val g = bytes[at + 1].toInt() and 0xFF
                val b = bytes[at + 2].toInt() and 0xFF
                val a = bytes[at + 3].toInt() and 0xFF
                pixels[i] = (a shl 24) or (r shl 16) or (g shl 8) or b
            }
            bitmap.setPixels(pixels, 0, width, 0, 0, width, height)

            val values = ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, "$name.png")
                put(MediaStore.Images.Media.MIME_TYPE, "image/png")
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/Rotelyx")
                }
            }

            val resolver = activity.contentResolver
            val uri = resolver.insert(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values
            )
            if (uri == null) {
                result.error("failed", "there is nowhere to put the picture", null)
                return
            }

            val stream: OutputStream? = resolver.openOutputStream(uri)
            if (stream == null) {
                result.error("failed", "the picture could not be written", null)
                return
            }
            stream.use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
            bitmap.recycle()
            result.success(null)
        } catch (e: Exception) {
            result.error("failed", e.message ?: "the picture could not be saved", null)
        }
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "save" -> save(call, result)
            else -> result.notImplemented()
        }
    }
}
