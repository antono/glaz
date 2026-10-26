package dev.glaz.glaz

import android.app.Activity
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.companion.AssociationInfo
import android.companion.AssociationRequest
import android.companion.BluetoothLeDeviceFilter
import android.companion.CompanionDeviceManager
import android.companion.DeviceNotAssociatedException
import android.companion.ObservingDevicePresenceRequest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.IntentSender
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

/**
 * "glaz/companion": the Flipper's Glaz app paired through Android's
 * Companion Device Manager (lib/flipper/companion.dart). The chooser
 * lists only what advertises the glaz service, and needs no location
 * permission; the association it leaves keeps the Flipper's address.
 *
 *   associate()      the chooser, then pairing, the PIN on both sides:
 *                    {address, name, bonded}; null when cancelled
 *   associated()     this app's Flipper(s): [{address, name}]
 *   forget(address)  drops the association; the pairing stays
 *   observe(on)      whether Android wakes glaz as the Flipper comes near
 *
 * Android 13 on answers onAssociationPending and onAssociationCreated;
 * before that onDeviceFound, and the device comes back in the chooser's
 * result, onActivityResult in MainActivity. Addresses are upper case, as
 * flutter_blue_plus has them.
 */
class Companion(private val context: Context, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler {

    /** The activity on screen, for the chooser; none, no pairing. */
    var activity: Activity? = null

    private val channel = MethodChannel(messenger, "glaz/companion")
    private val cdm: CompanionDeviceManager? =
        context.getSystemService(CompanionDeviceManager::class.java)
    private val main = Handler(Looper.getMainLooper())

    // the one associate() under way
    private var pending: MethodChannel.Result? = null
    private var bonding: BroadcastReceiver? = null
    private var timeout: Runnable? = null

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val cdm = cdm ?: return result.error("unavailable", "no companion devices here", null)
        try {
            when (call.method) {
                "associate" -> associate(cdm, result)
                "associated" -> result.success(associated(cdm))
                "forget" -> {
                    forget(cdm, call.arguments as String)
                    result.success(null)
                }
                "observe" -> {
                    observe(cdm, call.arguments as Boolean)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            Log.w(TAG, "${call.method}: $e")
            result.error("failed", e.toString(), null)
        }
    }

    private fun associate(cdm: CompanionDeviceManager, result: MethodChannel.Result) {
        if (pending != null) return result.error("busy", "already pairing", null)
        if (activity == null) return result.error("no_screen", "open glaz to pair", null)
        pending = result
        val filter = BluetoothLeDeviceFilter.Builder()
            .setScanFilter(ScanFilter.Builder().setServiceUuid(ParcelUuid(GLAZ)).build())
            .build()
        val request = AssociationRequest.Builder()
            .addDeviceFilter(filter)
            .setSingleDevice(true)
            .build()
        val callback = object : CompanionDeviceManager.Callback() {
            // Android 13 on
            override fun onAssociationPending(chooser: IntentSender) = choose(chooser)
            override fun onAssociationCreated(info: AssociationInfo) = created(info)

            // before Android 13
            @Deprecated("Android 13 has onAssociationPending")
            override fun onDeviceFound(chooser: IntentSender) = choose(chooser)

            // Android 13 on tells of a cancel here too ("canceled",
            // "user_rejected"), as well as in the chooser's result
            override fun onFailure(error: CharSequence?) {
                val why = "$error"
                if (CANCELS.any { why.contains(it, ignoreCase = true) }) finish(null)
                else failed(why)
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            cdm.associate(request, context.mainExecutor, callback)
        } else {
            @Suppress("DEPRECATION")
            cdm.associate(request, callback, main)
        }
    }

    private fun choose(chooser: IntentSender) {
        if (pending == null) return
        try {
            val a = activity ?: return failed("chooser: no screen")
            a.startIntentSenderForResult(chooser, REQUEST, null, 0, 0, 0)
        } catch (e: Exception) {
            failed("chooser: $e")
        }
    }

    /**
     * The chooser's result, from MainActivity. True if it was ours.
     * Cancelled: null. Before Android 13 the device chosen is here only.
     */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST) return false
        if (pending == null) return true
        if (resultCode != Activity.RESULT_OK) {
            finish(null)
            return true
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val info = data?.getParcelableExtra(
                CompanionDeviceManager.EXTRA_ASSOCIATION, AssociationInfo::class.java,
            )
            // else onAssociationCreated brings it
            if (info != null) created(info)
            return true
        }
        @Suppress("DEPRECATION")
        when (val chosen = data?.getParcelableExtra<android.os.Parcelable>(
            CompanionDeviceManager.EXTRA_DEVICE,
        )) {
            is ScanResult -> bond(chosen.device, chosen.scanRecord?.deviceName)
            is BluetoothDevice -> bond(chosen, null)
            else -> failed("no device chosen")
        }
        return true
    }

    private fun created(info: AssociationInfo) {
        if (pending == null || bonding != null) return
        val mac = info.deviceMacAddress ?: return failed("no address")
        val device = adapter().getRemoteDevice(mac.toString().uppercase())
        bond(device, info.displayName?.toString())
    }

    /**
     * Pairs with the device chosen and waits until Android settles it:
     * bonded, or not after all (PIN refused, timed out on the Flipper).
     */
    private fun bond(device: BluetoothDevice, name: String?) {
        val address = device.address.uppercase()
        val known = name ?: nameOf(device)
        fun done(bonded: Boolean) =
            finish(mapOf("address" to address, "name" to known, "bonded" to bonded))
        try {
            if (device.bondState == BluetoothDevice.BOND_BONDED) return done(true)
            val r = object : BroadcastReceiver() {
                override fun onReceive(c: Context?, i: Intent?) {
                    @Suppress("DEPRECATION")
                    val d = i?.getParcelableExtra<BluetoothDevice>(BluetoothDevice.EXTRA_DEVICE)
                    if (d?.address?.uppercase() != address) return
                    when (i.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, -1)) {
                        BluetoothDevice.BOND_BONDED -> done(true)
                        BluetoothDevice.BOND_NONE -> done(false)
                    }
                }
            }
            bonding = r
            context.registerReceiver(r, IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED))
            val t = Runnable {
                Log.w(TAG, "pairing with $address timed out")
                done(device.bondState == BluetoothDevice.BOND_BONDED)
            }
            timeout = t
            main.postDelayed(t, BOND_TIMEOUT_MS)
            if (!device.createBond() && device.bondState != BluetoothDevice.BOND_BONDING) {
                done(device.bondState == BluetoothDevice.BOND_BONDED)
            }
        } catch (e: SecurityException) {
            // no BLUETOOTH_CONNECT: associated all the same, not paired
            Log.w(TAG, "pairing with $address: $e")
            done(false)
        }
    }

    private fun associated(cdm: CompanionDeviceManager): List<Map<String, String?>> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            cdm.myAssociations.mapNotNull { info ->
                val mac = info.deviceMacAddress ?: return@mapNotNull null
                val address = mac.toString().uppercase()
                mapOf(
                    "address" to address,
                    "name" to (info.displayName?.toString() ?: nameOf(address)),
                )
            }
        } else {
            @Suppress("DEPRECATION")
            cdm.associations.map { mapOf("address" to it.uppercase(), "name" to nameOf(it)) }
        }

    private fun forget(cdm: CompanionDeviceManager, address: String) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            cdm.myAssociations
                .filter { it.deviceMacAddress?.toString().equals(address, ignoreCase = true) }
                .forEach {
                    watch(cdm, it, false)
                    cdm.disassociate(it.id)
                }
        } else {
            // Android keeps them as it was given them
            @Suppress("DEPRECATION")
            cdm.associations
                .filter { it.equals(address, ignoreCase = true) }
                .forEach {
                    watch(cdm, it, false)
                    cdm.disassociate(it)
                }
        }
    }

    private fun adapter() = context.getSystemService(BluetoothManager::class.java).adapter

    private fun nameOf(address: String): String? = try {
        nameOf(adapter().getRemoteDevice(address.uppercase()))
    } catch (e: Exception) {
        null
    }

    /** The device's name, if Android knows it and lets us read it. */
    private fun nameOf(device: BluetoothDevice): String? = try {
        device.name
    } catch (e: SecurityException) {
        null
    }

    private fun failed(why: String) {
        val r = pending ?: return
        Log.w(TAG, "associate: $why")
        stopBonding()
        pending = null
        r.error("failed", why, null)
    }

    private fun finish(value: Any?) {
        val r = pending ?: return
        stopBonding()
        pending = null
        r.success(value)
    }

    private fun stopBonding() {
        timeout?.let { main.removeCallbacks(it) }
        timeout = null
        bonding?.let {
            try {
                context.unregisterReceiver(it)
            } catch (_: Exception) {
            }
        }
        bonding = null
    }

    fun close() {
        stopBonding()
        pending = null
        channel.setMethodCallHandler(null)
    }

    companion object {
        private const val TAG = "GlazCompanion"
        private const val REQUEST = 137

        /** Long enough to read the PIN on the Flipper and confirm it. */
        private const val BOND_TIMEOUT_MS = 60_000L

        /** onFailure's words for the chooser closed or declined. */
        private val CANCELS = listOf("cancel", "reject")

        // observe() said once that this Android has no presence to watch
        private var told = false

        /**
         * Android tells FlipperPresence when the Flipper comes and goes, even
         * with glaz not running, for as long as [on]. Android keeps it across
         * restarts; a force stop pauses it until glaz is opened by hand.
         */
        fun observe(cdm: CompanionDeviceManager, on: Boolean) {
            when {
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU ->
                    cdm.myAssociations.forEach { watch(cdm, it, on) }
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.S ->
                    @Suppress("DEPRECATION")
                    cdm.associations.forEach { watch(cdm, it, on) }
                else -> if (!told) {
                    told = true
                    Log.i(TAG, "observe: Android ${Build.VERSION.SDK_INT} has no presence")
                }
            }
        }

        /** One association watched or not: by its id on 16, its address before. */
        private fun watch(cdm: CompanionDeviceManager, info: AssociationInfo, on: Boolean) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.BAKLAVA) {
                try {
                    val request = ObservingDevicePresenceRequest.Builder()
                        .setAssociationId(info.id)
                        .build()
                    if (on) cdm.startObservingDevicePresence(request)
                    else cdm.stopObservingDevicePresence(request)
                    Log.i(TAG, "observe ${info.id}: $on")
                } catch (e: Exception) {
                    Log.w(TAG, "observe ${info.id}: $e")
                }
                return
            }
            val mac = info.deviceMacAddress ?: return
            watch(cdm, mac.toString(), on)
        }

        /** Android 12 to 15: by the address Android keeps. */
        private fun watch(cdm: CompanionDeviceManager, address: String, on: Boolean) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
            try {
                @Suppress("DEPRECATION")
                if (on) cdm.startObservingDevicePresence(address)
                else cdm.stopObservingDevicePresence(address)
                Log.i(TAG, "observe $address: $on")
            } catch (e: DeviceNotAssociatedException) {
                Log.w(TAG, "observe $address: $e")
            } catch (e: SecurityException) {
                Log.w(TAG, "observe $address: $e")
            } catch (e: IllegalStateException) {
                Log.w(TAG, "observe $address: $e")
            }
        }

        /** The glaz service, flipper-glaz/src/link.rs. */
        private val GLAZ = UUID.fromString("a96fe95e-083f-402e-8be1-a9d5235813ca")
    }
}
