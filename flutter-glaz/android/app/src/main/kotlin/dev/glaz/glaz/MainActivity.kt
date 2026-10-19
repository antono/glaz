package dev.glaz.glaz

import android.content.Intent
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var speech: Speech? = null
    private var voice: Voice? = null
    private var keyboards: Keyboards? = null

    /**
     * "glaz/keys": the keyboard remote in the background, KeyRemoteService,
     * and whether one is attached, Keyboards.
     */
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "glaz/keys")
        val keyboards = Keyboards(applicationContext, channel)
        this.keyboards = keyboards
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "take" -> {
                    KeyRemoteService.taken =
                        (call.arguments as List<*>).map { (it as Number).toInt() }.toSet()
                    result.success(null)
                }
                "background" -> result.success(KeyRemoteService.running)
                "keyboard" -> result.success(keyboards.attached)
                "settings" -> {
                    startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        KeyRemoteService.channel = channel
        speech = Speech(flutterEngine.dartExecutor.binaryMessenger)
        voice = Voice(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        speech?.close()
        speech = null
        voice?.close()
        voice = null
        keyboards?.close()
        keyboards = null
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
