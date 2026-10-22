package dev.glaz.glaz

import android.accessibilityservice.AccessibilityService
import android.content.Intent
import android.view.KeyEvent
import android.view.accessibility.AccessibilityEvent
import io.flutter.plugin.common.MethodChannel

/**
 * The keyboard remote while Glaz is not on screen. Android gives key events
 * to the foreground app only -- except to an accessibility service that
 * asks to filter them (res/xml/key_remote.xml), once the user turns it on.
 *
 * With Glaz on screen the keys go their usual way, to Flutter
 * (lib/services/keys.dart). Otherwise the ones Dart takes ([taken], set
 * while the glasses are connected) go to it on "glaz/keys" and are kept
 * from the app in front; the rest pass.
 */
class KeyRemoteService : AccessibilityService() {
    companion object {
        /** The user has turned the service on and Android has bound it. */
        var running = false

        /** Glaz is on screen: MainActivity between onResume and onPause. */
        var foreground = false

        /** To the Dart side; null without a Flutter engine. */
        var channel: MethodChannel? = null

        /** Android key codes Dart takes now; empty while it takes none. */
        var taken: Set<Int> = emptySet()

        /**
         * Every key a keyboard has goes to Dart: the terminal on the glasses
         * types them (lib/services/term.dart). The phone's own keys still
         * go their way, so the phone can still be left, turned down or off.
         */
        var takeAll = false

        private val phoneKeys = setOf(
            KeyEvent.KEYCODE_BACK, KeyEvent.KEYCODE_HOME, KeyEvent.KEYCODE_APP_SWITCH,
            KeyEvent.KEYCODE_POWER, KeyEvent.KEYCODE_VOLUME_UP, KeyEvent.KEYCODE_VOLUME_DOWN,
            KeyEvent.KEYCODE_VOLUME_MUTE, KeyEvent.KEYCODE_CAMERA, KeyEvent.KEYCODE_SLEEP,
            KeyEvent.KEYCODE_WAKEUP, KeyEvent.KEYCODE_ASSIST, KeyEvent.KEYCODE_VOICE_ASSIST,
        )

        /**
         * Flipper's Keynote sends its Back as Backspace and then Android's
         * own Back (hid_keynote.c); the second one, this soon, is dropped
         * rather than going to the app in front. keys.dart does the same.
         */
        private const val BACK_ECHO_MS = 500L
    }

    private var backspaceAt = Long.MIN_VALUE / 2
    private var echo = false

    override fun onServiceConnected() {
        running = true
    }

    override fun onUnbind(intent: Intent?): Boolean {
        running = false
        return super.onUnbind(intent)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}

    override fun onInterrupt() {}

    /** True: taken, the app in front never sees it. */
    override fun onKeyEvent(event: KeyEvent): Boolean {
        val channel = channel
        if (foreground || channel == null) return false
        val down = event.action == KeyEvent.ACTION_DOWN
        val code = event.keyCode
        if (code == KeyEvent.KEYCODE_BACK) {
            // its key up is dropped too, however late
            if (down && event.repeatCount == 0) {
                echo = event.eventTime - backspaceAt < BACK_ECHO_MS
            }
            val drop = echo
            if (!down) echo = false
            return drop
        }
        if (code !in taken && !(takeAll && code !in phoneKeys)) return false
        if (code == KeyEvent.KEYCODE_DEL && down) backspaceAt = event.eventTime
        // action: 0 down, 1 repeat, 2 up; then the character the key types
        // with the modifiers held (0 for none), and the modifiers
        val action = if (!down) 2 else if (event.repeatCount > 0) 1 else 0
        channel.invokeMethod(
            "key",
            listOf(
                action, code, event.scanCode, event.eventTime,
                event.getUnicodeChar(event.metaState), event.metaState,
            ),
        )
        return true
    }
}
