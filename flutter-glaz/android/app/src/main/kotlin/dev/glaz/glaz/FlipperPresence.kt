package dev.glaz.glaz

import android.companion.AssociationInfo
import android.companion.CompanionDeviceService
import android.companion.DevicePresenceEvent
import android.os.Build
import android.util.Log
import androidx.annotation.RequiresApi
import io.flutter.embedding.engine.FlutterEngineCache

/**
 * Bound by Android's Companion Device Manager as the paired Flipper comes
 * near, glaz running or not (Companion.observe). Its coming wakes glaz:
 * the engine, so Dart and its links, and the link service that keeps them.
 * Android 16 says it with onDevicePresenceEvent; 13..15 with
 * onDeviceAppeared(AssociationInfo); 12 with addresses.
 *
 * Android keeps glaz bound long after the Flipper has gone, and binds it
 * again in a fresh process about 10 s after glaz dies, with no new event
 * even if the Flipper is still near (nor later: Android's scan does not
 * always see it come back). So a bind finding no engine makes one: Dart
 * then connects what is there, and the link service holds what it
 * connected; with nothing there it stays a process with no service.
 *
 * Association ids are not checked: glaz's only associations are Flippers.
 */
@RequiresApi(Build.VERSION_CODES.S)
class FlipperPresence : CompanionDeviceService() {
    override fun onCreate() {
        super.onCreate()
        if (FlutterEngineCache.getInstance().get(GlazEngine.ID) != null || !remoteOn()) return
        Log.i(TAG, "bound with no engine")
        GlazEngine.get(this, "bound")
    }

    /** The Flipper remote's switch, as Dart keeps it (lib/settings.dart). */
    private fun remoteOn() =
        getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
            .getBoolean("flutter.service.flipper_remote", true)

    override fun onDevicePresenceEvent(event: DevicePresenceEvent) {
        when (event.event) {
            DevicePresenceEvent.EVENT_BLE_APPEARED -> seen("ble", true)
            DevicePresenceEvent.EVENT_BLE_DISAPPEARED -> seen("ble", false)
            DevicePresenceEvent.EVENT_BT_CONNECTED -> seen("bt", true)
            DevicePresenceEvent.EVENT_BT_DISCONNECTED -> seen("bt", false)
            else -> Log.i(TAG, "event ${event.event}")
        }
    }

    override fun onDeviceAppeared(associationInfo: AssociationInfo) = seen("near", true)

    override fun onDeviceDisappeared(associationInfo: AssociationInfo) = seen("near", false)

    @Deprecated("Android 13 has onDeviceAppeared(AssociationInfo)")
    override fun onDeviceAppeared(address: String) = seen("near", true)

    @Deprecated("Android 13 has onDeviceDisappeared(AssociationInfo)")
    override fun onDeviceDisappeared(address: String) = seen("near", false)

    private fun seen(how: String, on: Boolean) {
        Log.i(TAG, "${if (on) "appeared" else "gone"}: $how")
        if (on) GlazEngine.get(this, "flipper")
        LinkService.seen(this, how, on)
    }

    companion object {
        private const val TAG = "GlazPresence"
    }
}
