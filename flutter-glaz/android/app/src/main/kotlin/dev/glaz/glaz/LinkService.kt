package dev.glaz.glaz

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.Manifest
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Keeps glaz running while the Flipper remote has something to hold: the
 * Flipper near or connected, or the glasses connected. A foreground
 * service, connectedDevice, with a quiet notification saying what is
 * connected; Dart (lib/services/hold.dart) tells it on "glaz/hold":
 *
 *   state({flipper, paired, flipperConnected, flipperName,
 *          glasses, glassesName})   Dart -> here, on every change
 *   started()                      what made the engine: app | flipper | service | bound
 *   present(bool)                  here -> Dart: the Flipper came or went
 *
 * Nothing left to hold, it stops [LINGER_MS] later, so a link that drops
 * and comes back does not stop it.
 */
class LinkService : Service() {
    companion object {
        private const val TAG = "GlazLink"
        private const val NOTE_ID = 137
        private const val NOTE_CHANNEL = "links"
        private const val LINGER_MS = 30_000L

        /** The Flipper remote is on; true until Dart says, as a wake means it. */
        private var flipper = true

        /** A Flipper is associated; true until Dart says, as a wake means it. */
        private var paired = true
        private var flipperConnected = false
        private var flipperName: String? = null
        private var glasses = false
        private var glassesName: String? = null

        /** How Android says the Flipper is near ("ble", "bt", "near"). */
        private val seen = mutableSetOf<String>()
        private val present get() = seen.isNotEmpty()

        /** Between onCreate and onDestroy. */
        var running = false
            private set

        /** Asked to start, not yet created: asked once, started once. */
        private var starting = false

        private var channel: MethodChannel? = null
        private var service: LinkService? = null
        private val main = Handler(Looper.getMainLooper())
        private var linger: Runnable? = null

        private fun wanted() = flipper && paired && (present || flipperConnected || glasses)

        /** Started if there is something to hold, else stopped a little later. */
        fun update(context: Context) {
            val app = context.applicationContext
            if (wanted()) {
                linger?.let { main.removeCallbacks(it) }
                linger = null
                if (running) {
                    service?.refresh()
                    return
                }
                if (starting) return
                if (!allowed(app)) {
                    Log.w(TAG, "not started: no Nearby devices permission")
                    return
                }
                starting = true
                try {
                    app.startForegroundService(Intent(app, LinkService::class.java))
                } catch (e: IllegalStateException) {
                    // ForegroundServiceStartNotAllowedException is one
                    starting = false
                    Log.w(TAG, "not started: $e")
                } catch (e: SecurityException) {
                    starting = false
                    Log.w(TAG, "not started: $e")
                }
                return
            }
            if (!running) return
            service?.refresh()
            if (linger != null) return
            val r = Runnable {
                linger = null
                if (!wanted() && running) {
                    Log.i(TAG, "stop")
                    app.stopService(Intent(app, LinkService::class.java))
                }
            }
            linger = r
            main.postDelayed(r, LINGER_MS)
        }

        /**
         * A connectedDevice service needs Nearby devices (Android 12+): without
         * it startForeground throws, and a service that never got to the
         * foreground takes the app down with it.
         */
        private fun allowed(context: Context) =
            Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
                context.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) ==
                PackageManager.PERMISSION_GRANTED

        /** Android says the Flipper is near, by [how], or no more. */
        fun seen(context: Context, how: String, on: Boolean) {
            val was = present
            if (on) seen.add(how) else seen.remove(how)
            if (present != was) channel?.invokeMethod("present", present)
            update(context)
        }

        fun attach(context: Context, messenger: BinaryMessenger) {
            val app = context.applicationContext
            val c = MethodChannel(messenger, "glaz/hold")
            c.setMethodCallHandler { call, result ->
                when (call.method) {
                    "state" -> {
                        val m = call.arguments as Map<*, *>
                        flipper = m["flipper"] == true
                        paired = m["paired"] == true
                        flipperConnected = m["flipperConnected"] == true
                        flipperName = m["flipperName"] as String?
                        glasses = m["glasses"] == true
                        glassesName = m["glassesName"] as String?
                        update(app)
                        result.success(null)
                    }
                    "started" -> result.success(GlazEngine.why)
                    else -> result.notImplemented()
                }
            }
            channel = c
        }

        fun detach() {
            channel?.setMethodCallHandler(null)
            channel = null
        }
    }

    override fun onCreate() {
        super.onCreate()
        running = true
        starting = false
        service = this
        GlazEngine.get(this, "service")
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(NOTE_CHANNEL, "Connections", NotificationManager.IMPORTANCE_LOW)
                .apply { setShowBadge(false) },
        )
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTE_ID, note(), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
            } else {
                startForeground(NOTE_ID, note())
            }
            Log.i(TAG, "start")
        } catch (e: Exception) {
            Log.w(TAG, "not started: $e")
            stopSelf()
            return START_NOT_STICKY
        }
        // what it was started for may have gone meanwhile: then the linger
        update(this)
        // CDM wakes glaz again while the Flipper is near; nothing else does
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        running = false
        service = null
        linger?.let { main.removeCallbacks(it) }
        linger = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun refresh() {
        getSystemService(NotificationManager::class.java).notify(NOTE_ID, note())
    }

    /** What is connected, in a line. */
    private fun text(): String {
        val f = "Flipper ${flipperName ?: "Glaz"}"
        val g = glassesName ?: "the glasses"
        return when {
            !wanted() -> "Nothing connected"
            flipperConnected && glasses -> "$f and $g connected"
            glasses -> "$g connected, waiting for the Flipper"
            flipperConnected -> "$f connected, glasses not"
            else -> "Flipper near, connecting"
        }
    }

    private fun note(): Notification {
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return Notification.Builder(this, NOTE_CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_glaz)
            .setContentTitle("Glaz")
            .setContentText(text())
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setContentIntent(open)
            .build()
    }
}
