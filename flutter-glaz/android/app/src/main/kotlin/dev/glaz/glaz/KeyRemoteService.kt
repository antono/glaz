package dev.glaz.glaz

import android.accessibilityservice.AccessibilityService
import android.content.Context
import android.content.Intent
import android.hardware.input.InputManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
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
 *
 * A ring remote (a JX-05 TikTok ring) is no keyboard: it swipes and taps
 * like a finger, as a pointer (MOUSE | STYLUS), and its long presses are
 * volume keys. While Dart takes keys and a ring is attached, the service
 * listens to those pointer sources (Android 14 and later): every motion
 * from them comes here instead of to the apps, Glaz's own screen too, and
 * the ring's goes to Dart as "ring" (lib/services/ring.dart), with its
 * volume keys. Any other mouse is lost meanwhile, so the sources are on
 * only while a ring is there.
 */
class KeyRemoteService : AccessibilityService(), InputManager.InputDeviceListener {
    companion object {
        /** The user has turned the service on and Android has bound it. */
        var running = false

        /** The bound service, for [taken] to reach. */
        private var instance: KeyRemoteService? = null

        /** Glaz is on screen: MainActivity between onResume and onPause. */
        var foreground = false

        /** To the Dart side; null without a Flutter engine. */
        var channel: MethodChannel? = null

        /** Android key codes Dart takes now; empty while it takes none. */
        var taken: Set<Int> = emptySet()
            set(value) {
                field = value
                instance?.listen()
            }

        /** Ring remotes, by the name they give Android. */
        fun ring(dev: InputDevice?) = dev != null && dev.name.startsWith("JX-05")

        private const val POINTERS = InputDevice.SOURCE_MOUSE or InputDevice.SOURCE_STYLUS

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

    private var input: InputManager? = null
    private var listening: Boolean? = null

    override fun onServiceConnected() {
        running = true
        instance = this
        input = (getSystemService(Context.INPUT_SERVICE) as InputManager).also {
            it.registerInputDeviceListener(this, Handler(Looper.getMainLooper()))
        }
        listen()
    }

    override fun onUnbind(intent: Intent?): Boolean {
        running = false
        instance = null
        input?.unregisterInputDeviceListener(this)
        input = null
        return super.onUnbind(intent)
    }

    override fun onInputDeviceAdded(deviceId: Int) = listen()
    override fun onInputDeviceRemoved(deviceId: Int) = listen()
    override fun onInputDeviceChanged(deviceId: Int) = listen()

    /** Takes the pointers while Dart takes keys and a ring is attached. */
    private fun listen() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return
        val on = taken.isNotEmpty() &&
            InputDevice.getDeviceIds().any { ring(InputDevice.getDevice(it)) }
        if (on == listening) return
        listening = on
        val info = serviceInfo ?: return
        info.motionEventSources = if (on) POINTERS else 0
        serviceInfo = info
    }

    /**
     * The ring's swipes and taps, to Dart: `[action, x, y, time in ms]`,
     * action 0 touch, 1 move, 2 lift. Another pointer's motion is dropped:
     * it cannot be given back.
     */
    override fun onMotionEvent(event: MotionEvent) {
        val channel = channel ?: return
        if (!ring(event.device)) return
        val action = when (event.actionMasked) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_BUTTON_PRESS -> 0
            MotionEvent.ACTION_MOVE, MotionEvent.ACTION_HOVER_MOVE -> 1
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL,
            MotionEvent.ACTION_BUTTON_RELEASE -> 2
            else -> return
        }
        channel.invokeMethod(
            "ring",
            listOf(action, event.x.toDouble(), event.y.toDouble(), event.eventTime),
        )
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}

    override fun onInterrupt() {}

    /** True: taken, the app in front never sees it. */
    override fun onKeyEvent(event: KeyEvent): Boolean {
        val channel = channel ?: return false
        val down = event.action == KeyEvent.ACTION_DOWN
        val code = event.keyCode
        // the ring's long presses, on screen or not: its other keys (home,
        // power) are the phone's and pass
        if (ring(event.device) && taken.isNotEmpty() &&
            (code == KeyEvent.KEYCODE_VOLUME_UP || code == KeyEvent.KEYCODE_VOLUME_DOWN)
        ) {
            if (down) channel.invokeMethod("ringKey", listOf(code, event.eventTime))
            return true
        }
        if (foreground) return false
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
