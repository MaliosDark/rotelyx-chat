package com.rotelyx.app

import android.content.Context
import android.content.Intent
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/// Hands text to whatever the person already uses to talk to people.
///
/// # Why this is here instead of a package
///
/// It is an `ACTION_SEND` intent and a chooser, which is fifteen lines. A
/// dependency for that is fifteen lines plus somebody else's release schedule,
/// their transitive dependencies, and one more thing in the build that can
/// reach the network without anybody noticing. This application does not take
/// that trade anywhere else and there is no reason to start here.
///
/// # What Android sees
///
/// The chooser is drawn by the system, and the system knows the text: it has to,
/// it is putting it in another application. That is true of every share sheet on
/// every platform and it is why the invitation link keeps its payload after the
/// hash. The link is safe to hand around, which is the whole point of it.
class Sharing(private val context: Context) {

    companion object {
        const val CHANNEL = "rotelyx/share"
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "text" -> {
                val text = call.argument<String>("text")
                if (text.isNullOrEmpty()) {
                    result.error("empty", "there was nothing to share", null)
                    return
                }

                val send = Intent(Intent.ACTION_SEND).apply {
                    type = "text/plain"
                    putExtra(Intent.EXTRA_TEXT, text)
                    call.argument<String>("subject")?.let {
                        putExtra(Intent.EXTRA_SUBJECT, it)
                    }
                }

                // NEW_TASK because this is started from the application context
                // rather than from the activity: the activity is the one being
                // left, and holding a reference to it here to start a chooser
                // is a leak waiting for a rotation.
                val chooser = Intent.createChooser(send, call.argument<String>("title"))
                chooser.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

                context.startActivity(chooser)
                result.success(true)
            }

            else -> result.notImplemented()
        }
    }
}
