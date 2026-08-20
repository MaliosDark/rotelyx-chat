package com.ideoalabs.rotelyx

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

/**
 * Choosing a file, through the system picker and nothing else.
 *
 * # Why `ACTION_OPEN_DOCUMENT` and not a permission
 *
 * The obvious way to let somebody attach a photograph is to ask for
 * `READ_MEDIA_IMAGES` and browse their gallery. This does not, and the reason
 * is on the permission screen: an application that asks to read every image on
 * a phone has asked for something far larger than "let me send this one", and a
 * person reading that list has no way to tell the two apart.
 *
 * The Storage Access Framework asks for nothing. The system draws the picker,
 * the user chooses one file, and this process is handed a URI it may read
 * exactly once. Everything else on the device stays invisible to it, which is
 * the same shape as the rest of this application: the narrowest thing that
 * does the job.
 *
 * # Why the bytes are copied rather than the URI passed along
 *
 * A URI granted this way is valid for this task and not afterwards. Handing it
 * to Dart to open later produces a `SecurityException` at whatever moment the
 * user finally presses send, which is the worst place to discover it. So the
 * file is read here, while the grant is certainly alive, and what crosses the
 * channel is bytes.
 *
 * The ceiling matters for the same reason the mailbox has one: an attachment
 * becomes an envelope, envelopes are padded to a uniform size so that none
 * stands out, and something enormous cannot be padded into the crowd.
 */
class FilePicker(private val activity: Activity) {

    companion object {
        const val CHANNEL = "rotelyx/files"
        const val REQUEST = 0x51F0

        /** Refused before it is read, so a huge file is not copied into memory
         *  in order to be rejected afterwards. */
        private const val DEFAULT_MAX = 16 * 1024 * 1024
    }

    private var pending: MethodChannel.Result? = null
    private var limit = DEFAULT_MAX

    fun pick(call: MethodCall, result: MethodChannel.Result) {
        if (pending != null) {
            result.error("busy", "a picker is already open", null)
            return
        }

        limit = call.argument<Int>("maxBytes") ?: DEFAULT_MAX
        pending = result

        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
        }

        try {
            activity.startActivityForResult(intent, REQUEST)
        } catch (e: Exception) {
            pending = null
            result.error("nopicker", "this device has no file picker", null)
        }
    }

    /** Returns whether this was ours to handle. */
    fun onResult(request: Int, code: Int, data: Intent?): Boolean {
        if (request != REQUEST) return false

        val waiting = pending ?: return true
        pending = null

        if (code != Activity.RESULT_OK) {
            // Backed out. Not an error: null means "chose nothing", which is a
            // thing people do and should not produce a message.
            waiting.success(null)
            return true
        }

        val uri = data?.data
        if (uri == null) {
            waiting.success(null)
            return true
        }

        try {
            waiting.success(read(uri))
        } catch (e: TooLarge) {
            waiting.error("toolarge", e.message, null)
        } catch (e: Exception) {
            waiting.error("unreadable", e.message ?: "that file could not be read", null)
        }
        return true
    }

    private class TooLarge(message: String) : Exception(message)

    private fun read(uri: Uri): Map<String, Any> {
        val resolver = activity.contentResolver

        var name = "attachment"
        var declared = -1L
        resolver.query(uri, null, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val nameAt = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (nameAt >= 0 && !cursor.isNull(nameAt)) name = cursor.getString(nameAt)
                val sizeAt = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (sizeAt >= 0 && !cursor.isNull(sizeAt)) declared = cursor.getLong(sizeAt)
            }
        }

        // Checked before reading, when the provider says how big it is. Some
        // providers do not, which is why the read below also counts.
        if (declared > limit) {
            throw TooLarge("that file is ${declared / 1024 / 1024} MB, and the limit is ${limit / 1024 / 1024} MB")
        }

        val out = ByteArrayOutputStream()
        resolver.openInputStream(uri).use { input ->
            if (input == null) throw Exception("that file could not be opened")
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val read = input.read(buffer)
                if (read <= 0) break
                out.write(buffer, 0, read)
                if (out.size() > limit) {
                    throw TooLarge("that file is larger than ${limit / 1024 / 1024} MB")
                }
            }
        }

        return mapOf(
            "name" to name,
            "mime" to (resolver.getType(uri) ?: "application/octet-stream"),
            "bytes" to out.toByteArray(),
        )
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pick" -> pick(call, result)
            else -> result.notImplemented()
        }
    }
}
