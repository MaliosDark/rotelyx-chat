package com.ideoalabs.rotelyx

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private lateinit var notifications: Notifications
    private var camera: QrCamera? = null
    private var files: FilePicker? = null
    private var audio: CallAudio? = null

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)

        notifications = Notifications(applicationContext)
        notifications.createChannels()

        val scanner = QrCamera(applicationContext, engine.renderer)
        camera = scanner
        MethodChannel(engine.dartExecutor.binaryMessenger, QrCamera.CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "permit") {
                    // Asked for when the scanner opens, not at launch. The
                    // answer is read back rather than awaited: the scanner
                    // screen calls `start` after this and gets a clean refusal
                    // if the answer was no.
                    requestCamera()
                    result.success(hasCamera())
                } else {
                    scanner.handle(call, result)
                }
            }

        val calls = CallAudio()
        audio = calls
        MethodChannel(engine.dartExecutor.binaryMessenger, CallAudio.CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "permit") {
                    requestMicrophone()
                    result.success(hasMicrophone())
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
                        requestPermission()
                        result.success(notifications.permitted())
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
        audio?.stop()
        audio = null
        camera?.dispose()
        camera = null
        super.onDestroy()
    }

    private fun hasCamera(): Boolean =
        ActivityCompat.checkSelfPermission(this, Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED

    private fun hasMicrophone(): Boolean =
        ActivityCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED

    private fun requestMicrophone() {
        if (!hasMicrophone()) {
            ActivityCompat.requestPermissions(
                this, arrayOf(Manifest.permission.RECORD_AUDIO), 3
            )
        }
    }

    private fun requestCamera() {
        if (!hasCamera()) {
            ActivityCompat.requestPermissions(
                this, arrayOf(Manifest.permission.CAMERA), 2
            )
        }
    }

    private fun requestPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return

        val granted = ActivityCompat.checkSelfPermission(
            this, Manifest.permission.POST_NOTIFICATIONS
        ) == PackageManager.PERMISSION_GRANTED

        if (!granted) {
            ActivityCompat.requestPermissions(
                this, arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1
            )
        }
    }
}
