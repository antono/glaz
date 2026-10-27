package dev.glaz.glaz

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor.DartEntrypoint
import io.flutter.plugin.common.MethodChannel

/**
 * The one Flutter engine, and so the one Dart: the glasses' link and the
 * Flipper's. Made by whatever needs it first -- the app opened, the
 * Flipper seen (FlipperPresence), the link service -- and kept in
 * FlutterEngineCache as [ID]; MainActivity shows it and leaves it
 * running when it closes. It goes with the process, or when the activity
 * closes with nothing to hold (MainActivity.shouldDestroyEngineWithHost).
 */
object GlazEngine {
    const val ID = "glaz"
    private const val TAG = "GlazEngine"

    /**
     * What made the engine: "app", "flipper", "service", "bound"
     * (FlipperPresence bound again with none); Dart logs it.
     */
    var why: String? = null
        private set

    var companion: Companion? = null
        private set

    /** The activity showing the engine, for what needs one: the chooser. */
    var activity: Activity? = null
        set(a) {
            field = a
            companion?.activity = a
        }

    private var speech: Speech? = null
    private var voice: Voice? = null
    private var tuner: Tuner? = null
    private var keyboards: Keyboards? = null

    /** The engine, made and running main() if there is none. Main thread. */
    fun get(context: Context, why: String): FlutterEngine {
        FlutterEngineCache.getInstance().get(ID)?.let { return it }
        val app = context.applicationContext
        // the constructor registers the plugins
        val engine = FlutterEngine(app)
        this.why = why
        channels(app, engine)
        engine.addEngineLifecycleListener(object : FlutterEngine.EngineLifecycleListener {
            override fun onPreEngineRestart() {}
            override fun onEngineWillDestroy() = closed()
        })
        engine.dartExecutor.executeDartEntrypoint(DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(ID, engine)
        Log.i(TAG, "engine made: $why")
        return engine
    }

    /**
     * The app's own channels, on the engine whether or not anything is on
     * screen. "glaz/keys": the keyboard remote in the background,
     * KeyRemoteService, and whether one is attached, Keyboards.
     */
    private fun channels(app: Context, engine: FlutterEngine) {
        val messenger = engine.dartExecutor.binaryMessenger
        val channel = MethodChannel(messenger, "glaz/keys")
        val keyboards = Keyboards(app, channel)
        this.keyboards = keyboards
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "take" -> {
                    KeyRemoteService.taken =
                        (call.arguments as List<*>).map { (it as Number).toInt() }.toSet()
                    result.success(null)
                }
                "takeAll" -> {
                    KeyRemoteService.takeAll = call.arguments as Boolean
                    result.success(null)
                }
                "background" -> result.success(KeyRemoteService.running)
                "keyboard" -> result.success(keyboards.attached)
                "settings" -> {
                    val from: Context = activity ?: app
                    val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                    if (from !is Activity) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    from.startActivity(intent)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        KeyRemoteService.channel = channel
        speech = Speech(messenger)
        voice = Voice(app, messenger)
        tuner = Tuner(app, messenger)
        companion = Companion(app, messenger).also { it.activity = activity }
        LinkService.attach(app, messenger)
    }

    private fun closed() {
        Log.i(TAG, "onEngineWillDestroy")
        speech?.close()
        speech = null
        voice?.close()
        voice = null
        tuner?.close()
        tuner = null
        keyboards?.close()
        keyboards = null
        companion?.close()
        companion = null
        KeyRemoteService.channel = null
        KeyRemoteService.taken = emptySet()
        KeyRemoteService.takeAll = false
        LinkService.detach()
        FlutterEngineCache.getInstance().remove(ID)
        why = null
    }
}
