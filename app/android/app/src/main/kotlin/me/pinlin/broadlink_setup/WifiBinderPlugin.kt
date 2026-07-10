package me.pinlin.broadlink_setup

import android.content.Context
import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Implements `broadlink_setup/wifi`.
 *
 * Wires the MethodChannel to the [WifiBinder] logic and, critically,
 * releases the active [WifiBinder] reservation from [onDetachedFromEngine].
 * That fires on Flutter hot-restart and on engine teardown — without it,
 * hot-restarting while joined to the provisioning AP leaves the phone
 * stranded on the device hotspot until the user toggles Wi-Fi.
 *
 * Strategy: programmatically join `BroadlinkProv` via `WifiNetworkSpecifier`
 * (see [WifiBinder]), then bind the process to that network so Dart-side UDP
 * sockets route through the AP. UDP send/receive lives on the Dart side;
 * this plugin only manages the network binding lifecycle and method dispatch.
 *
 * Lifecycle:
 *   - One active join at a time (v1 flow is single-device) — enforced by
 *     [joinInProgress].
 *   - `leave` always unbinds the process, even if the join never succeeded —
 *     idempotent.
 *   - `onLost` (inside [WifiBinder]) unbinds automatically so the
 *     device-reboot success path doesn't leave the phone stranded on a dead AP.
 */
class WifiBinderPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware {

    companion object {
        private const val CHANNEL = "broadlink_setup/wifi"

        // Wire error codes — must match WifiBinderErrorCode in platform_exception_codes.dart.
        private const val ERR_BUSY = "BUSY"
        private const val ERR_UNSUPPORTED = "UNSUPPORTED"
        private const val ERR_UNKNOWN = "UNKNOWN"
    }

    private lateinit var channel: MethodChannel
    private var binder: WifiBinder? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var joinInProgress = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val ctx: Context = binding.applicationContext
        binder = WifiBinder(ctx)
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        // Best-effort cleanup — release any active network binding so we
        // don't leave the phone stranded on the provisioning AP after a
        // debug hot-restart.
        channel.setMethodCallHandler(null)
        binder?.leave()
        binder = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        activityBinding = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "joinOpenAp" -> handleJoin(call, result)
            "leave" -> {
                binder?.leave()
                result.success(null)
            }
            "currentBoundSsid" -> result.success(binder?.currentBoundSsid())
            "scanBroadlinkApSsids" -> {
                val b = binder ?: return result.error(ERR_UNKNOWN, "no context", null)
                b.scanBroadlinkApSsids { ssids -> result.success(ssids) }
            }
            "scan24GhzNetworks" -> {
                val b = binder ?: return result.error(ERR_UNKNOWN, "no context", null)
                b.scan24GhzNetworks { networks -> result.success(networks) }
            }
            "bindToCurrentApIfBroadlink" -> handleBindToCurrent(result)
            "openWifiSettings" -> {
                binder?.openWifiSettings()
                result.success(null)
            }
            "deviceInfo" -> result.success(deviceInfo())
            else -> result.notImplemented()
        }
    }

    // region Join / leave
    private fun handleJoin(call: MethodCall, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.error(ERR_UNSUPPORTED, "Android 10+ required", null)
            return
        }
        if (joinInProgress) {
            result.error(ERR_BUSY, "another join is in progress", null)
            return
        }
        val ssid = call.argument<String>("ssid")
        if (ssid.isNullOrEmpty()) {
            result.error(ERR_UNKNOWN, "missing ssid", null)
            return
        }
        val timeoutMs = call.argument<Int>("timeoutMs") ?: 60_000
        val b = binder ?: return result.error(ERR_UNKNOWN, "no context", null)

        joinInProgress = true
        b.joinOpenAp(ssid, timeoutMs.toLong()) { ok, code, msg ->
            joinInProgress = false
            if (ok) result.success(msg) // msg carries the ssid on success
            else result.error(code, msg, null)
        }
    }
    // endregion

    private fun handleBindToCurrent(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.error(ERR_UNSUPPORTED, "Android 10+ required", null)
            return
        }
        val b = binder ?: return result.error(ERR_UNKNOWN, "no context", null)
        b.bindToCurrentApIfBroadlink { ok, code, msg ->
            if (ok) result.success(msg) // msg carries the ssid on success
            else result.error(code, msg, null)
        }
    }

    private fun deviceInfo(): Map<String, Any?> = mapOf(
        "platform" to "android",
        "manufacturer" to Build.MANUFACTURER,
        "brand" to Build.BRAND,
        "model" to Build.MODEL,
        "device" to Build.DEVICE,
        "androidRelease" to Build.VERSION.RELEASE,
        "androidSdk" to Build.VERSION.SDK_INT,
    )
}
