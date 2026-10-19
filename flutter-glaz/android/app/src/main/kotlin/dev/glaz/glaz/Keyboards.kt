package dev.glaz.glaz

import android.content.Context
import android.hardware.input.InputManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.InputDevice
import io.flutter.plugin.common.MethodChannel

/**
 * Whether a keyboard remote is attached to the phone: a Bluetooth or USB
 * keyboard, a clicker, a gamepad, a Flipper in Remote. Told to Dart on
 * "glaz/keys" as "keyboard" with true or false each time it changes, so
 * the glasses' own gestures go off while one is there (keys.dart).
 *
 * The phone's own buttons (volume, power) are keyboards too, built in:
 * only external devices count, as Android tells them apart from Android 10
 * on. Older phones count every keyboard with letters.
 */
class Keyboards(context: Context, private val channel: MethodChannel) :
    InputManager.InputDeviceListener {
    private val input = context.getSystemService(Context.INPUT_SERVICE) as InputManager
    private var last: Boolean? = null

    init {
        input.registerInputDeviceListener(this, Handler(Looper.getMainLooper()))
    }

    fun close() = input.unregisterInputDeviceListener(this)

    val attached: Boolean
        get() = InputDevice.getDeviceIds().any { id ->
            val dev = InputDevice.getDevice(id) ?: return@any false
            remote(dev)
        }

    private fun remote(dev: InputDevice): Boolean {
        if (dev.isVirtual) return false
        // Bluetooth audio's media keys, on stacks that make a device of them
        if (dev.name.contains("AVRCP")) return false
        val keys = dev.supportsSource(InputDevice.SOURCE_KEYBOARD) ||
            dev.supportsSource(InputDevice.SOURCE_GAMEPAD) ||
            dev.supportsSource(InputDevice.SOURCE_DPAD)
        if (!keys) return false
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            dev.isExternal
        } else {
            dev.keyboardType == InputDevice.KEYBOARD_TYPE_ALPHABETIC
        }
    }

    private fun changed() {
        val now = attached
        if (now == last) return
        last = now
        channel.invokeMethod("keyboard", now)
    }

    override fun onInputDeviceAdded(deviceId: Int) = changed()
    override fun onInputDeviceRemoved(deviceId: Int) = changed()
    override fun onInputDeviceChanged(deviceId: Int) = changed()
}
