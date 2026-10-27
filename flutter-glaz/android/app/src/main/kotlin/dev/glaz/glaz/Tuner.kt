package dev.glaz.glaz

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * "glaz/tuner": the phone's microphone for the glasses' Tuner
 * (lib/services/tuner.dart). What it hears goes to "glaz/tuner/events"
 * as byte arrays of 16-bit little-endian mono PCM, 50 ms each.
 *
 *   start(rate)  true when hearing; false when Android will not
 *   stop()
 *
 * The UNPROCESSED source where the phone has one: MIC's processing (noise
 * suppression, gain control) is made for speech and fights a held note.
 */
class Tuner(private val context: Context, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var record: AudioRecord? = null
    private var thread: Thread? = null
    @Volatile private var running = false

    init {
        MethodChannel(messenger, "glaz/tuner").setMethodCallHandler(this)
        EventChannel(messenger, "glaz/tuner/events").setStreamHandler(this)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> result.success(start(call.argument<Int>("rate") ?: 16000))
            "stop" -> {
                stop()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    @SuppressLint("MissingPermission") // checked first
    private fun start(rate: Int): Boolean {
        if (running) return true
        if (context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return false
        }
        val min = AudioRecord.getMinBufferSize(
            rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
        )
        if (min <= 0) return false
        val audio = context.getSystemService(AudioManager::class.java)
        val source = if (audio.getProperty(
                AudioManager.PROPERTY_SUPPORT_AUDIO_SOURCE_UNPROCESSED,
            ) == "true"
        ) {
            MediaRecorder.AudioSource.UNPROCESSED
        } else {
            MediaRecorder.AudioSource.MIC
        }
        val r = try {
            AudioRecord(
                source, rate, AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT, maxOf(min, rate * 2 / 5),
            )
        } catch (e: Exception) {
            Log.w(TAG, "no AudioRecord", e)
            return false
        }
        if (r.state != AudioRecord.STATE_INITIALIZED) {
            r.release()
            return false
        }
        try {
            r.startRecording()
        } catch (e: IllegalStateException) {
            Log.w(TAG, "not recording", e)
            r.release()
            return false
        }
        record = r
        running = true
        val chunk = rate / 20 * 2
        thread = Thread({
            val buf = ByteArray(chunk)
            while (running) {
                val n = r.read(buf, 0, buf.size)
                if (n < 0) break
                if (n > 0) {
                    val piece = buf.copyOf(n)
                    main.post { sink?.success(piece) }
                }
            }
        }, "glaz-tuner").also { it.start() }
        Log.i(TAG, "hearing at $rate Hz, source $source")
        return true
    }

    private fun stop() {
        running = false
        thread?.join(500)
        thread = null
        record?.let {
            try {
                it.stop()
            } catch (_: IllegalStateException) {
            }
            it.release()
        }
        record = null
    }

    fun close() = stop()

    private companion object {
        const val TAG = "GlazTuner"
    }
}
