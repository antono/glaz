package dev.glaz.glaz

import android.content.Context
import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * Shows the one engine, GlazEngine: made here if the Flipper or the link
 * service has not made it already. Its channels live on the engine, so
 * Dart runs the same with this activity or without it.
 */
class MainActivity : FlutterActivity() {
    override fun provideFlutterEngine(context: Context): FlutterEngine =
        GlazEngine.get(context, "app")

    /** Kept while the link service holds a link; else it goes as before. */
    override fun shouldDestroyEngineWithHost() =
        isFinishing && !isChangingConfigurations && !LinkService.running

    // not super's: it registers nothing for an engine given by the host
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        GlazEngine.activity = this
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        if (GlazEngine.activity === this) GlazEngine.activity = null
    }

    /** The Flipper chooser's answer goes to Companion, the rest to Flutter. */
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (GlazEngine.companion?.onActivityResult(requestCode, resultCode, data) == true) return
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onResume() {
        super.onResume()
        KeyRemoteService.foreground = true
        LinkService.update(this)
    }

    override fun onPause() {
        KeyRemoteService.foreground = false
        super.onPause()
    }
}
