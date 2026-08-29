package com.ideoalabs.rotelyx

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// `FlutterFragmentActivity` rather than `FlutterActivity`, for one reason:
/// `BiometricPrompt` requires a `FragmentActivity` and will not attach to
/// anything else. Everything else behaves identically.
class MainActivity : FlutterFragmentActivity() {

    private lateinit var notifications: Notifications
    private var camera: QrCamera? = null
    private var files: FilePicker? = null
    private var audio: CallAudio? = null
    private var biometrics: Biometrics? = null
    private var links: Links? = null

    /// `permit` calls that asked the user something and have not heard back,
    /// by request code. Dart is awaiting every one of these.
    private val waiting = mutableMapOf<Int, MethodChannel.Result>()

    companion object {
        private const val NOTIFICATIONS = 1
        private const val CAMERA = 2
        private const val MICROPHONE = 3
    }

    /// A link tapped while this is already running.
    ///
    /// `singleTop` in the manifest is what routes it here instead of starting
    /// a second copy of the activity, and `setIntent` keeps `getIntent` honest
    /// for anything that reads it afterwards.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        links?.deliver(intent)
    }

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)

        // Before anything can ask for a microphone. See `Native`: without this
        // the audio backend aborts the process rather than failing, and the
        // application simply disappears when somebody presses call.
        Native.start(applicationContext)

        notifications = Notifications(applicationContext)
        notifications.createChannels()

        val scanner = QrCamera(applicationContext, engine.renderer)
        camera = scanner
        MethodChannel(engine.dartExecutor.binaryMessenger, QrCamera.CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "permit") {
                    // Asked for when the scanner opens, not at launch, and
                    // waited for. Reading the answer back straight after asking
                    // would read it while the dialog is still on screen, which
                    // reports a refusal the user has not made yet: the reply is
                    // sent from `onRequestPermissionsResult` instead.
                    permit(Manifest.permission.CAMERA, CAMERA, result)
                } else {
                    scanner.handle(call, result)
                }
            }

        val linkChannel = MethodChannel(engine.dartExecutor.binaryMessenger, Links.CHANNEL)
        val incoming = Links(linkChannel)
        links = incoming
        // The intent that started this process, before anything asks for it.
        incoming.remember(intent)
        linkChannel.setMethodCallHandler { call, result ->
            if (call.method == "initial") incoming.take(result) else result.notImplemented()
        }

        val sharing = Sharing(applicationContext)
        MethodChannel(engine.dartExecutor.binaryMessenger, Sharing.CHANNEL)
            .setMethodCallHandler(sharing::handle)

        val fingerprint = Biometrics(this)
        biometrics = fingerprint
        MethodChannel(engine.dartExecutor.binaryMessenger, Biometrics.CHANNEL)
            .setMethodCallHandler(fingerprint::handle)

        val calls = CallAudio()
        audio = calls
        MethodChannel(engine.dartExecutor.binaryMessenger, CallAudio.CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "permit") {
                    permit(Manifest.permission.RECORD_AUDIO, MICROPHONE, result)
                } else {
                    calls.handle(call, applicationContext, result)
                }
            }

        val picker = FilePicker(this)
        files = picker
        MethodChannel(engine.dartExecutor.binaryMessenger, FilePicker.CHANNEL)
            .setMethodCallHandler(picker::handle)

        MethodChannel(engine.dartExecutor.binaryMessenger, Notifications.CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "request" -> {
                        // Through `permit`, and waited for, like the camera and
                        // the microphone.
                        //
                        // It used to call `requestPermissions` and then read the
                        // answer back on the next line, which reads it while the
                        // dialog is still on screen. The reply was therefore
                        // always whatever was true before the person was asked,
                        // so granting notifications flipped the switch back and
                        // told them notifications were off. The camera path
                        // carries a comment warning about exactly this.
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            permit(
                                Manifest.permission.POST_NOTIFICATIONS,
                                NOTIFICATIONS,
                                result,
                            )
                        } else {
                            // Before Android 13 there is no permission to ask
                            // for: posting is allowed unless the user switched
                            // the channel off, which `permitted` reads.
                            result.success(notifications.permitted())
                        }
                    }
                    "connect" -> {
                        ConnectionService.start(applicationContext)
                        result.success(true)
                    }
                    "disconnect" -> {
                        ConnectionService.stop(applicationContext)
                        result.success(true)
                    }
                    else -> notifications.handle(call, result)
                }
            }
    }

    /**
     * Ask for permission to notify, on the versions that require asking.
     *
     * From Android 13 the default is refused, so an application that never asks
     * simply never notifies, silently and on every device sold since 2022. The
     * request is fired and not awaited: the answer is read the next time
     * anything asks whether notifications are permitted, and refusing has no
     * effect on anything else working.
     */
    override fun onActivityResult(request: Int, code: Int, data: android.content.Intent?) {
        // The picker first, and only calling through when it was not ours.
        // Flutter's own plugins use this same callback, and swallowing a result
        // that belonged to one of them is a bug that shows up somewhere else
        // entirely.
        if (files?.onResult(request, code, data) != true) {
            super.onActivityResult(request, code, data)
        }
    }

    override fun onDestroy() {
        waiting.clear()
        audio?.stop()
        audio = null
        camera?.dispose()
        camera = null
        super.onDestroy()
    }

    /// Answer a `permit` call once the user has actually answered.
    ///
    /// Granted already is the common case and replies immediately. Otherwise the
    /// reply is held until `onRequestPermissionsResult`, because the dialog is
    /// asynchronous and the caller is asking a question only the user can
    /// answer.
    private fun permit(permission: String, code: Int, result: MethodChannel.Result) {
        if (ActivityCompat.checkSelfPermission(this, permission) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }

        // A second ask arriving while one is on screen would strand the first
        // waiting forever, so it is answered with what is true at this moment.
        waiting.remove(code)?.success(false)
        waiting[code] = result
        ActivityCompat.requestPermissions(this, arrayOf(permission), code)
    }

    override fun onRequestPermissionsResult(
        code: Int,
        permissions: Array<out String>,
        grants: IntArray,
    ) {
        super.onRequestPermissionsResult(code, permissions, grants)
        val asked = waiting.remove(code) ?: return
        asked.success(
            grants.isNotEmpty() && grants[0] == PackageManager.PERMISSION_GRANTED
        )
    }

}
