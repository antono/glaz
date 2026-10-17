package dev.glaz.glaz

import android.os.Handler
import android.os.Looper
import android.util.Log
import android.os.ParcelFileDescriptor
import com.google.mlkit.genai.common.DownloadStatus
import com.google.mlkit.genai.common.FeatureStatus
import com.google.mlkit.genai.common.audio.AudioSource
import com.google.mlkit.genai.speechrecognition.SpeechRecognition
import com.google.mlkit.genai.speechrecognition.SpeechRecognizer
import com.google.mlkit.genai.speechrecognition.SpeechRecognizerOptions
import com.google.mlkit.genai.speechrecognition.SpeechRecognizerResponse
import com.google.mlkit.genai.speechrecognition.speechRecognizerOptions
import com.google.mlkit.genai.speechrecognition.speechRecognizerRequest
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.OutputStream
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.takeWhile
import kotlinx.coroutines.launch

/**
 * "glaz/speech": speech to text on the phone itself, ML Kit GenAI Speech
 * Recognition in its Basic mode (lib/services/speech.dart). Dart sends
 * 16 kHz mono 16-bit PCM, what the recognizer takes from a pipe; what it
 * hears comes back on "glaz/speech/events" as maps:
 *
 *     {id, kind: partial | final | error | done, text}
 *     {id: 0, kind: download, got, total}
 *
 * A partial text is replaced by the next one; a final one stays.
 */
class Speech(messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private class Session(
        val recognizer: SpeechRecognizer,
        val read: ParcelFileDescriptor,
        val out: OutputStream,
        // writes to the pipe block while the recognizer is behind
        val writer: ExecutorService,
    ) {
        var job: Job? = null
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val main = Handler(Looper.getMainLooper())
    private val sessions = ConcurrentHashMap<Int, Session>()
    private var sink: EventChannel.EventSink? = null

    init {
        MethodChannel(messenger, "glaz/speech").setMethodCallHandler(this)
        EventChannel(messenger, "glaz/speech/events").setStreamHandler(this)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    private fun send(event: Map<String, Any?>) {
        if (event["kind"] != "partial" && event["kind"] != "download") Log.i(TAG, "$event")
        main.post { sink?.success(event) }
    }

    private fun reply(result: MethodChannel.Result, value: Any?) =
        main.post { result.success(value) }

    private fun fail(result: MethodChannel.Result, e: Throwable) {
        Log.w(TAG, "failed", e)
        main.post { result.error("speech", e.message ?: e.toString(), null) }
    }

    /** A BCP 47 tag, 'ru-RU'; empty or 'auto' is the phone's language. */
    private fun client(tag: String?): SpeechRecognizer =
        SpeechRecognition.getClient(
            speechRecognizerOptions {
                locale = if (tag.isNullOrEmpty() || tag == "auto") {
                    // without extensions: en-US-u-mu-celsius is no language
                    Locale.getDefault().let { Locale.forLanguageTag("${it.language}-${it.country}") }
                } else {
                    Locale.forLanguageTag(tag)
                }
                preferredMode = SpeechRecognizerOptions.Mode.MODE_BASIC
            },
        )

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<Int>("id") ?: 0
        when (call.method) {
            "status" -> scope.launch {
                try {
                    client(call.argument("language")).use {
                        val status = statusName(it.checkStatus())
                        Log.i(TAG, "status ${call.argument<String>("language")}: $status")
                        reply(result, status)
                    }
                } catch (e: Throwable) {
                    fail(result, e)
                }
            }
            "download" -> scope.launch {
                try {
                    client(call.argument("language")).use { recognizer ->
                        var total = 0L
                        var failed: Throwable? = null
                        Log.i(TAG, "download ${call.argument<String>("language")}")
                        recognizer.download().collect { s ->
                            if (s !is DownloadStatus.DownloadProgress) Log.i(TAG, "download: $s")
                            when (s) {
                                is DownloadStatus.DownloadStarted -> total = s.bytesToDownload
                                is DownloadStatus.DownloadProgress -> send(
                                    mapOf(
                                        "id" to 0,
                                        "kind" to "download",
                                        "got" to s.totalBytesDownloaded,
                                        "total" to total,
                                    ),
                                )
                                is DownloadStatus.DownloadFailed -> failed = s.e
                                else -> {}
                            }
                        }
                        failed?.let { throw it }
                        reply(result, null)
                    }
                } catch (e: Throwable) {
                    fail(result, e)
                }
            }
            "start" -> start(id, call.argument("language"), result)
            "feed" -> {
                val s = sessions[id] ?: return result.success(false)
                val data = call.argument<ByteArray>("data") ?: ByteArray(0)
                // answered once written: Dart waits, so a long file is not
                // all in memory at once
                if (!later(s) {
                        try {
                            s.out.write(data)
                            reply(result, true)
                        } catch (e: Throwable) {
                            reply(result, false)
                        }
                    }
                ) {
                    result.success(false)
                }
            }
            "finish" -> {
                // the end of the pipe is the end of the speech
                Log.i(TAG, "finish $id")
                sessions[id]?.let { s -> later(s) { closeQuietly(s.out) } }
                result.success(null)
            }
            "cancel" -> {
                sessions[id]?.let { s ->
                    s.job?.cancel()
                    end(id)
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun start(id: Int, language: String?, result: MethodChannel.Result) {
        Log.i(TAG, "start $id $language")
        val (read, write) = ParcelFileDescriptor.createPipe()
        val s = Session(
            client(language),
            read,
            ParcelFileDescriptor.AutoCloseOutputStream(write),
            Executors.newSingleThreadExecutor(),
        )
        sessions[id] = s
        s.job = scope.launch {
            try {
                val request = speechRecognizerRequest {
                    audioSource = AudioSource.fromPfd(read)
                }
                s.recognizer.startRecognition(request)
                    .takeWhile { it !is SpeechRecognizerResponse.CompletedResponse }
                    .collect { r ->
                        when (r) {
                            is SpeechRecognizerResponse.PartialTextResponse ->
                                send(mapOf("id" to id, "kind" to "partial", "text" to r.text))
                            is SpeechRecognizerResponse.FinalTextResponse ->
                                send(mapOf("id" to id, "kind" to "final", "text" to r.text))
                            is SpeechRecognizerResponse.ErrorResponse ->
                                send(mapOf("id" to id, "kind" to "error", "text" to r.e.message))
                            else -> {}
                        }
                    }
            } catch (e: Throwable) {
                Log.w(TAG, "recognition $id", e)
                send(mapOf("id" to id, "kind" to "error", "text" to (e.message ?: e.toString())))
            } finally {
                send(mapOf("id" to id, "kind" to "done"))
                end(id)
            }
        }
        result.success(null)
    }

    /** On the session's writer; false once the session has ended. */
    private fun later(s: Session, f: () -> Unit) = try {
        s.writer.execute(f)
        true
    } catch (_: RejectedExecutionException) {
        false
    }

    private fun end(id: Int) {
        val s = sessions.remove(id) ?: return
        s.writer.execute {
            closeQuietly(s.out)
            closeQuietly(s.read)
            closeQuietly(s.recognizer)
        }
        s.writer.shutdown()
    }

    private fun closeQuietly(c: AutoCloseable) {
        try {
            c.close()
        } catch (_: Throwable) {}
    }

    private fun statusName(status: Int) = when (status) {
        FeatureStatus.AVAILABLE -> "available"
        FeatureStatus.DOWNLOADABLE -> "downloadable"
        FeatureStatus.DOWNLOADING -> "downloading"
        else -> "unavailable"
    }

    companion object {
        private const val TAG = "GlazSpeech"
    }

    fun close() {
        for (id in sessions.keys.toList()) end(id)
        scope.cancel()
    }
}
