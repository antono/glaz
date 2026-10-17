package dev.glaz.glaz

import android.bluetooth.BluetoothClass
import android.bluetooth.BluetoothManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

/**
 * "glaz/voice": the assistant's answers read aloud -- into headphones only,
 * never the phone's loudspeaker or a Bluetooth speaker everyone around
 * hears (lib/services/voice.dart).
 *
 *   headphones()           where speech would go: {ok, name, why}
 *   speak(text, language)  says it if it would go to headphones: true;
 *                          false and nothing said otherwise
 *   stop()
 *
 * Where it would go is asked of Android for these very audio attributes
 * (getAudioDevicesForAttributes, Android 13+); before that, guessed from
 * the outputs connected. A Bluetooth output counts only when its device
 * class says headphones or a headset: a speaker or a car does not. Should
 * the headphones go mid-sentence, Android says the sound is about to come
 * out of the phone (ACTION_AUDIO_BECOMING_NOISY) and speech stops.
 */
class Voice(private val context: Context, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler {

    private val audio = context.getSystemService(AudioManager::class.java)
    private val attributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_ASSISTANT)
        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
        .build()

    private var tts: TextToSpeech? = null
    private var ready = false
    private val pending = mutableListOf<() -> Unit>()
    private var noisy: BroadcastReceiver? = null

    init {
        MethodChannel(messenger, "glaz/voice").setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "headphones" -> {
                val (ok, name, why) = headphones()
                result.success(mapOf("ok" to ok, "name" to name, "why" to why))
            }
            "speak" -> {
                val text = call.argument<String>("text") ?: ""
                val language = call.argument<String>("language") ?: "auto"
                val (ok, _, why) = headphones()
                if (!ok || text.isBlank()) {
                    Log.i(TAG, "not spoken: $why")
                    result.success(false)
                    return
                }
                withTts { speak(text, language) }
                result.success(true)
            }
            "stop" -> {
                tts?.stop()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /** Whether speech would go to headphones, their name, and why not. */
    private fun headphones(): Triple<Boolean, String?, String?> {
        val routed = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            try {
                audio.getAudioDevicesForAttributes(attributes)
            } catch (e: Exception) {
                Log.w(TAG, "where speech goes: $e")
                null
            }
        } else {
            null
        }
        // else: media goes to the newest connected output there is, the
        // loudspeaker last of all
        val devices = routed ?: audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            .filter { it.type in MEDIA_OUTPUTS }
            .ifEmpty { audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS).toList() }
        if (devices.isEmpty()) return Triple(false, null, "no audio output")
        for (d in devices) {
            val name = d.productName?.toString()
            val why = notHeadphones(d)
            if (why != null) return Triple(false, name, why)
        }
        return Triple(true, devices.first().productName?.toString(), null)
    }

    /** Null for headphones; else what they are instead. */
    private fun notHeadphones(d: AudioDeviceInfo): String? = when (d.type) {
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
        AudioDeviceInfo.TYPE_WIRED_HEADSET,
        AudioDeviceInfo.TYPE_USB_HEADSET,
        AudioDeviceInfo.TYPE_HEARING_AID -> null
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
        AUDIO_DEVICE_BLE_HEADSET -> bluetoothKind(d)
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER,
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER_SAFE -> "the phone's loudspeaker"
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "the phone's earpiece"
        else -> "not headphones (audio device type ${d.type})"
    }

    /** A Bluetooth output by its device class: headphones or a headset. */
    private fun bluetoothKind(d: AudioDeviceInfo): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) {
            return "a Bluetooth device that cannot be checked before Android 9"
        }
        val major: Int
        val device: Int
        try {
            val manager = context.getSystemService(BluetoothManager::class.java)
            val cls = manager.adapter.getRemoteDevice(d.address).bluetoothClass
                ?: return "a Bluetooth device of no known kind"
            major = cls.majorDeviceClass
            device = cls.deviceClass
        } catch (e: Exception) {
            // without BLUETOOTH_CONNECT, or no address: it cannot be told
            return "a Bluetooth device that cannot be checked ($e)"
        }
        if (major != BluetoothClass.Device.Major.AUDIO_VIDEO) {
            return "a Bluetooth device that is not audio"
        }
        return when (device) {
            BluetoothClass.Device.AUDIO_VIDEO_HEADPHONES,
            BluetoothClass.Device.AUDIO_VIDEO_WEARABLE_HEADSET,
            BluetoothClass.Device.AUDIO_VIDEO_HANDSFREE -> null
            BluetoothClass.Device.AUDIO_VIDEO_LOUDSPEAKER -> "a Bluetooth speaker"
            BluetoothClass.Device.AUDIO_VIDEO_CAR_AUDIO -> "a car"
            else -> "Bluetooth audio that does not say it is headphones"
        }
    }

    private fun withTts(then: TextToSpeech.() -> Unit) {
        val t = tts
        if (t != null && ready) return t.then()
        pending.add { tts?.then() }
        if (t != null) return
        tts = TextToSpeech(context) { status ->
            ready = status == TextToSpeech.SUCCESS
            if (!ready) Log.w(TAG, "text to speech failed to start: $status")
            val run = pending.toList()
            pending.clear()
            if (ready) run.forEach { it() }
        }.apply {
            setAudioAttributes(attributes)
            setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                override fun onStart(id: String?) = listenNoisy(true)
                override fun onDone(id: String?) = listenNoisy(false)
                @Deprecated("old API")
                override fun onError(id: String?) = listenNoisy(false)
                override fun onStop(id: String?, interrupted: Boolean) = listenNoisy(false)
            })
        }
    }

    private fun TextToSpeech.speak(text: String, language: String) {
        if (language != "auto") {
            setLanguage(Locale.forLanguageTag(language))
        } else {
            setLanguage(Locale.getDefault())
        }
        speak(text, TextToSpeech.QUEUE_FLUSH, Bundle(), "glaz")
    }

    /** While speaking: headphones gone, speech stops at once. */
    private fun listenNoisy(on: Boolean) {
        if (on && noisy == null) {
            val r = object : BroadcastReceiver() {
                override fun onReceive(c: Context?, i: Intent?) {
                    Log.i(TAG, "headphones gone: stopped")
                    tts?.stop()
                }
            }
            noisy = r
            context.registerReceiver(
                r, IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY),
            )
        } else if (!on) {
            noisy?.let {
                try {
                    context.unregisterReceiver(it)
                } catch (_: Exception) {
                }
            }
            noisy = null
        }
    }

    fun close() {
        listenNoisy(false)
        tts?.shutdown()
        tts = null
    }

    companion object {
        private const val TAG = "GlazVoice"
        private const val AUDIO_DEVICE_BLE_HEADSET = 26 // TYPE_BLE_HEADSET, API 31

        // where media may go before Android 13, the loudspeaker left out
        private val MEDIA_OUTPUTS = setOf(
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
            AudioDeviceInfo.TYPE_WIRED_HEADSET,
            AudioDeviceInfo.TYPE_USB_HEADSET,
            AudioDeviceInfo.TYPE_HEARING_AID,
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
            AUDIO_DEVICE_BLE_HEADSET,
            27, // TYPE_BLE_SPEAKER: a speaker, refused by notHeadphones
        )
    }
}
