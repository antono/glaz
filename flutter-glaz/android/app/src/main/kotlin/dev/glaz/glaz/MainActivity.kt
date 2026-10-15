package dev.glaz.glaz

import android.content.Intent
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    /** "glaz/keys": the keyboard remote in the background, KeyRemoteService. */
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "glaz/keys")
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "take" -> {
                    KeyRemoteService.taken =
                        (call.arguments as List<*>).map { (it as Number).toInt() }.toSet()
                    result.success(null)
                }
                "background" -> result.success(KeyRemoteService.running)
                "settings" -> {
                    startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        KeyRemoteService.channel = channel
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        KeyRemoteService.channel = null
        KeyRemoteService.taken = emptySet()
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onResume() {
        super.onResume()
        KeyRemoteService.foreground = true
    }

    override fun onPause() {
        KeyRemoteService.foreground = false
        super.onPause()
    }
}
