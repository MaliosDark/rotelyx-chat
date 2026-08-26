package com.ideoalabs.rotelyx

import android.content.Intent
import io.flutter.plugin.common.MethodChannel

/// Invitation links arriving from outside the application.
///
/// # Why this is pull and push rather than only one
///
/// A link arrives in two quite different situations and they need different
/// handling. Tapping one while the application is closed starts it, and the
/// intent is already sitting on the activity before Dart exists to be told
/// about it: that one is pulled, by `initial`, once the interface is up.
/// Tapping one while it is running delivers to `onNewIntent` with everything
/// already listening: that one is pushed.
///
/// Answering only the second loses every invitation that arrives at a phone
/// where the application was not already open, which is most of them.
class Links(private val channel: MethodChannel) {

    companion object {
        const val CHANNEL = "rotelyx/links"
    }

    /// The link this process was started with, taken once.
    ///
    /// Cleared after it is read so that a rotation, which rebuilds the
    /// activity with the same intent, does not deliver the same invitation a
    /// second time and start a second pairing.
    private var pending: String? = null

    fun remember(intent: Intent?) {
        val link = linkOf(intent) ?: return
        pending = link
    }

    /// A link while the application is already up.
    fun deliver(intent: Intent?) {
        val link = linkOf(intent) ?: return
        channel.invokeMethod("link", link)
    }

    fun take(result: MethodChannel.Result) {
        result.success(pending)
        pending = null
    }

    private fun linkOf(intent: Intent?): String? {
        if (intent == null || intent.action != Intent.ACTION_VIEW) return null
        return intent.data?.toString()
    }
}
