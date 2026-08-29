package com.rotelyx.app

import android.content.Context

/**
 * The one thing the native library needs handed to it rather than discovered.
 *
 * # Why this exists
 *
 * Audio on Android goes through oboe, which asks `ndk-context` for the JavaVM
 * and the Activity. Neither can be found from Rust: the VM belongs to the
 * runtime and the Activity belongs to Java. An application built around
 * `ndk-glue` gets this set up for it because glue owns `main`; this is a library
 * inside a Flutter application, which owns nothing, so nobody was setting it.
 *
 * What that looked like was not an error. `ndk_context::android_context()`
 * aborts, and an abort is the process ending: pressing call closed the whole
 * application with nothing in the interface to say why. The only trace was
 * `Abort message: 'android context was not initialized'` in a tombstone.
 *
 * # Why the application context and not the activity
 *
 * The reference is held for the life of the process. An Activity held that long
 * is an Activity that cannot be collected when the screen rotates, which is a
 * leak of every view attached to it. The application context is already
 * process-wide and is what audio needs.
 */
object Native {
    /** Called once, as early as there is a context to pass. */
    fun start(context: Context) {
        if (started) return
        started = true

        // Loaded here rather than left to the first FFI call, because the JNI
        // entry point below has to be resolvable before it is called and the
        // library that carries it is the same one Dart opens later.
        System.loadLibrary("rotelyx_mobile")
        initAndroidContext(context.applicationContext)
    }

    private var started = false

    private external fun initAndroidContext(context: Context)
}
