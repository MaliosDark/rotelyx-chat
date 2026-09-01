package com.rotelyx.app

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * Keeping this application's own connection alive.
 *
 * # Why this exists, demonstrated rather than assumed
 *
 * Without it, notifications do not work, and not because the notification code
 * is wrong. Measured on a phone: the application was paired, sent to the
 * background, and the screen was switched off. A message was deposited. The
 * screen came back on and the conversation still read "No messages yet". The
 * envelope was in the mailbox the whole time and nothing collected it, because
 * Android had frozen the process holding the socket.
 *
 * That is the platform working as designed. An application in the background
 * has its network suspended, and the ordinary answer is Firebase: Google holds
 * a socket on everybody's behalf and wakes the application when there is
 * something. The cost of that answer is in `docs/PUSH.md` and it is the reason
 * this file exists instead.
 *
 * A foreground service is exempt. It costs a notification that cannot be
 * dismissed and it costs battery, and both are stated to the user rather than
 * hidden, because a messenger that quietly runs all day is worse than one that
 * says it is going to.
 *
 * # What it does not do
 *
 * It holds no socket of its own and knows nothing about messages. The socket is
 * in the Dart isolate, which is in this process, and the only job here is to be
 * a reason for the system not to freeze it. That is also why there is no
 * background Flutter engine: a second engine would mean a second copy of the
 * MLS state, and two ratchets stepping over one another is a way to lose
 * messages permanently.
 *
 * # The service type, and what Google Play will ask
 *
 * Android 14 requires every foreground service to declare a type, and Android
 * 15 caps `dataSync` at six hours in any twenty four, which for a messenger
 * means it stops working every evening. `specialUse` has no cap and requires a
 * justification that a human at Play reads. Ours is in the manifest and in
 * `docs/RELEASING.md`, and it is true: this application maintains its own
 * end to end encrypted transport specifically so that no push service learns
 * when its users receive messages.
 */
class ConnectionService : Service() {

    companion object {
        private const val ID = 0x52545859
        private const val RUNNING = "rotelyx.running"

        const val ACTION_START = "com.rotelyx.app.CONNECT"
        const val ACTION_STOP = "com.rotelyx.app.DISCONNECT"

        fun start(context: Context) {
            val intent = Intent(context, ConnectionService::class.java)
                .setAction(ACTION_START)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.startService(
                Intent(context, ConnectionService::class.java).setAction(ACTION_STOP)
            )
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }

        // Within five seconds of startForegroundService or the system kills the
        // process with a ForegroundServiceDidNotStartInTimeException, so this is
        // the first thing done and not the last.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(ID, notice(), type())
        } else {
            startForeground(ID, notice())
        }

        // START_STICKY: if the system reclaims the process under memory
        // pressure, bring it back. The alternative is a messenger that silently
        // stops receiving and gives no sign of it.
        return START_STICKY
    }

    private fun type(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
        } else {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
        }

    /**
     * The notice the system requires.
     *
     * It says what is happening and why, because the alternative is a permanent
     * line in somebody's notification shade that reads "Rotelyx is running" and
     * gives them no way to judge whether that is reasonable.
     */
    private fun notice(): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java)
                .setFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, RUNNING)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle("Rotelyx is connected")
            .setContentText("Messages arrive as soon as they are sent")
            .setStyle(
                NotificationCompat.BigTextStyle().bigText(
                    "Rotelyx keeps its own connection to your mailbox, so a " +
                        "message reaches you as soon as it is sent and stays " +
                        "between you and the person who sent it. You can turn " +
                        "this off in Settings, and messages will then arrive " +
                        "when you open the app."
                )
            )
            .setOngoing(true)
            .setSilent(true)
            .setShowWhen(false)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setContentIntent(open)
            .build()
    }
}
