package com.ideoalabs.rotelyx

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.media.AudioAttributes
import android.net.Uri
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.Person
import androidx.core.graphics.drawable.IconCompat
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Posting notifications, without anybody else's help.
 *
 * # Why this is written here rather than taken from a package
 *
 * A notification plugin would do most of this. Three things it would not do
 * are the reason this is a file instead of a dependency:
 *
 *   * The sender's name and picture in `MessagingStyle`, which is what makes
 *     an arriving message look like a message rather than an alert from an
 *     application. It needs a `Person` with an `IconCompat` built from bytes
 *     the Dart side holds, and most plugins expose a title and a body.
 *   * The lock screen decision. Whether the text is readable without unlocking
 *     is a privacy setting this application has to own, per conversation, and
 *     `setVisibility` plus `setPublicVersion` is how it is expressed.
 *   * A dependency in a messenger whose argument is that it depends on nobody
 *     is worth avoiding when the alternative is two hundred lines.
 *
 * # What it never does
 *
 * It never reaches the network. Nothing here talks to Google Play Services,
 * Firebase, or anything outside this process. A notification is posted because
 * this application already decrypted a message on this device.
 */
class Notifications(private val context: Context) {

    companion object {
        const val CHANNEL = "rotelyx/notifications"

        /** Arriving messages. Sound, vibration, and a heads-up banner. */
        private const val MESSAGES = "rotelyx.messages"

        /** The connection notice that a foreground service must show. Silent
         *  and at the lowest importance the system will still display, because
         *  it is a legal requirement rather than something to read. */
        private const val RUNNING = "rotelyx.running"

        /**
         * Two short pulses.
         *
         * Long enough to feel through a pocket, short enough not to buzz across
         * a table. The gap matters more than the length: one continuous
         * vibration reads as a call, and two beats read as a message.
         */
        private val PATTERN = longArrayOf(0, 60, 90, 60)
    }

    private val manager = NotificationManagerCompat.from(context)

    /**
     * Declare the channels.
     *
     * Called at startup rather than before the first notification. A channel's
     * sound, vibration and importance are fixed when it is created and cannot
     * be changed afterwards by the application: from then on they belong to the
     * user, which is the point of the design. Creating them late means the
     * first notification of a fresh install decides them, and creating them
     * early means the settings screen has something to show before anything has
     * arrived.
     */
    fun createChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val sound = Uri.parse("android.resource://${context.packageName}/raw/rotelyx_message")

        val messages = NotificationChannel(
            MESSAGES, "Messages", NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "Someone has sent you a message."
            enableVibration(true)
            vibrationPattern = PATTERN
            setSound(
                sound,
                AudioAttributes.Builder()
                    // SONIFICATION and NOTIFICATION rather than MUSIC, so the
                    // system ducks whatever is playing instead of stopping it,
                    // and so it follows the notification volume slider.
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
            )
            // Whether the text shows on a locked screen is decided per
            // notification, not here, so the channel permits it and each
            // notification chooses. A channel set to SECRET could not be
            // overridden by a conversation that wants its content shown.
            lockscreenVisibility = Notification.VISIBILITY_PRIVATE
            setShowBadge(true)
        }

        val running = NotificationChannel(
            RUNNING, "Staying connected", NotificationManager.IMPORTANCE_MIN
        ).apply {
            description =
                "Shown while Rotelyx holds its own connection, so messages arrive " +
                    "without Google or Apple being told that one did."
            setShowBadge(false)
            enableVibration(false)
            setSound(null, null)
        }

        val system = context.getSystemService(Context.NOTIFICATION_SERVICE)
            as NotificationManager
        system.createNotificationChannel(messages)
        system.createNotificationChannel(running)
    }

    /**
     * Show one message.
     *
     * [id] is the conversation, so a second message from the same person
     * replaces the first rather than stacking, which is what a conversation
     * does. [showContent] is the lock screen decision.
     */
    fun show(
        id: Int,
        title: String,
        body: String,
        picture: ByteArray?,
        showContent: Boolean,
        silent: Boolean,
    ) {
        val person = Person.Builder()
            .setName(title)
            .apply {
                if (picture != null) {
                    val bitmap = BitmapFactory.decodeByteArray(picture, 0, picture.size)
                    if (bitmap != null) setIcon(IconCompat.createWithBitmap(bitmap))
                }
            }
            .build()

        val style = NotificationCompat.MessagingStyle(person)
            .addMessage(body, System.currentTimeMillis(), person)

        val open = PendingIntent.getActivity(
            context,
            id,
            Intent(context, MainActivity::class.java)
                .setFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_NEW_TASK),
            // IMMUTABLE, and required from Android 12. A mutable pending intent
            // is one another application can fill in and fire.
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = NotificationCompat.Builder(context, MESSAGES)
            .setSmallIcon(R.drawable.ic_notification)
            .setStyle(style)
            .setContentTitle(title)
            .setContentText(body)
            .setAutoCancel(true)
            .setContentIntent(open)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setVisibility(
                if (showContent) NotificationCompat.VISIBILITY_PUBLIC
                else NotificationCompat.VISIBILITY_PRIVATE
            )

        // What a locked screen shows when the content is not to be shown. Left
        // to the system it would print "Contents hidden", which says nothing.
        // This says who it is from and not what they said, which is the useful
        // half and the half that is safe on a screen anybody can see.
        if (!showContent) {
            builder.setPublicVersion(
                NotificationCompat.Builder(context, MESSAGES)
                    .setSmallIcon(R.drawable.ic_notification)
                    .setContentTitle(title)
                    .setContentText("New message")
                    .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                    .build()
            )
        }

        if (silent) {
            builder.setSilent(true)
        } else {
            vibrate()
        }

        try {
            manager.notify(id, builder.build())
        } catch (e: SecurityException) {
            // POST_NOTIFICATIONS was refused. Not an error: the user said no,
            // and the message is already in the conversation either way.
        }
    }

    fun clear(id: Int) = manager.cancel(id)

    /**
     * Whether notifications are permitted at all.
     *
     * From Android 13 this is a runtime permission and the default is refused.
     * Anything that assumes a posted notification is a shown notification is
     * wrong on every device sold since 2022.
     */
    fun permitted(): Boolean = manager.areNotificationsEnabled()

    private fun vibrate() {
        val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val service = context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE)
                as VibratorManager
            service.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            context.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        }

        if (!vibrator.hasVibrator()) return

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            vibrator.vibrate(VibrationEffect.createWaveform(PATTERN, -1))
        } else {
            @Suppress("DEPRECATION")
            vibrator.vibrate(PATTERN, -1)
        }
    }

    /** Route one call from Dart. */
    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "createChannels" -> {
                createChannels()
                result.success(null)
            }
            "permitted" -> result.success(permitted())
            "show" -> {
                show(
                    id = call.argument<Int>("id") ?: 0,
                    title = call.argument<String>("title") ?: "",
                    body = call.argument<String>("body") ?: "",
                    picture = call.argument<ByteArray>("picture"),
                    showContent = call.argument<Boolean>("showContent") ?: true,
                    silent = call.argument<Boolean>("silent") ?: false,
                )
                result.success(null)
            }
            "clear" -> {
                clear(call.argument<Int>("id") ?: 0)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }
}
