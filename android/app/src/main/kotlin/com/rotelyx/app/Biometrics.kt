package com.ideoalabs.rotelyx

import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * A fingerprint or a face, instead of typing the PIN.
 *
 * # What this is and what it is not
 *
 * It is a **shortcut to the PIN, not a replacement for it.** The PIN is what
 * the lock is made of: it is stretched, rate limited, and it is what a
 * conversation is sealed under. This only decides whether the person has to
 * type it.
 *
 * That distinction has to be built in rather than discovered. A biometric that
 * replaced the PIN would mean the secret lives in the Keychain or the Keystore
 * rather than in somebody's head, and then a phone that is unlocked is a phone
 * that opens everything. So the PIN is still required to exist, this is offered
 * beside it, and switching it off leaves the lock exactly as it was.
 *
 * # Why the PIN is not stored to make this work
 *
 * Because then it would be stored. The application PIN is verified by opening a
 * blob, and this does not touch that: a successful biometric marks the session
 * as unlocked in memory, the same way entering the PIN does. Nothing is written
 * anywhere and a restart asks again.
 *
 * # DEVICE_CREDENTIAL is deliberately not offered
 *
 * `BiometricManager` can fall back to the phone's own screen lock. Allowing
 * that would mean the person's phone PIN opens this application, which is the
 * thing somebody who sets a separate PIN is trying to avoid.
 */
class Biometrics(private val activity: FragmentActivity) {

    companion object {
        const val CHANNEL = "rotelyx/biometrics"

        /** Strong biometrics only: a fingerprint sensor or a secure face unlock.
         *  `BIOMETRIC_WEAK` includes face unlock on hardware that a photograph
         *  can defeat, which is not a lock. */
        private const val STRENGTH = BiometricManager.Authenticators.BIOMETRIC_STRONG
    }

    /** Whether this device has one enrolled and usable. */
    private fun available(): Boolean =
        BiometricManager.from(activity).canAuthenticate(STRENGTH) ==
            BiometricManager.BIOMETRIC_SUCCESS

    private fun prompt(result: MethodChannel.Result) {
        if (!available()) {
            result.success(false)
            return
        }

        val prompt = BiometricPrompt(
            activity,
            ContextCompat.getMainExecutor(activity),
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(
                    authenticated: BiometricPrompt.AuthenticationResult
                ) {
                    result.success(true)
                }

                override fun onAuthenticationError(code: Int, message: CharSequence) {
                    // Cancelled, or too many attempts, or no hardware. All of
                    // them mean "type the PIN", which is a working path rather
                    // than a failure worth reporting.
                    result.success(false)
                }

                // onAuthenticationFailed is deliberately not overridden: one
                // finger that did not read is not an answer, and the system
                // lets them try again inside the same prompt.
            }
        )

        prompt.authenticate(
            BiometricPrompt.PromptInfo.Builder()
                .setTitle("Unlock Rotelyx")
                .setSubtitle("Or press cancel and type your PIN")
                .setNegativeButtonText("Use PIN")
                .setAllowedAuthenticators(STRENGTH)
                // No confirmation step. It exists for payments, where a second
                // deliberate tap is the point; here it is one more tap between
                // somebody and their messages.
                .setConfirmationRequired(false)
                .build()
        )
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "available" -> result.success(available())
            "prompt" -> prompt(result)
            else -> result.notImplemented()
        }
    }
}
