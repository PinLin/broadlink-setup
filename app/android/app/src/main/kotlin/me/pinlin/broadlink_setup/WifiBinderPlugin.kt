package me.pinlin.broadlink_setup

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Implements `broadlink_setup/wifi`.
 *
 * Strategy: programmatically join `BroadlinkProv` via [WifiNetworkSpecifier],
 * then call [ConnectivityManager.bindProcessToNetwork] so Dart-side UDP sockets
 * route through the AP. UDP send/receive lives on the Dart side; this plugin
 * only manages the network binding lifecycle.
 *
 * Lifecycle:
 *   - One active join at a time (v1 flow is single-device).
 *   - [leave] always unbinds the process, even if the join never succeeded —
 *     idempotent.
 *   - [onLost] unbinds automatically so the device-reboot success path doesn't
 *     leave the phone stranded on a dead AP.
 */
class WifiBinderPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware {

    companion object {
        private const val CHANNEL = "broadlink_setup/wifi"

        // Wire error codes — must match WifiBinderErrorCode in platform_exception_codes.dart.
        private const val ERR_AP_UNAVAILABLE = "AP_UNAVAILABLE"
        private const val ERR_BUSY = "BUSY"
        private const val ERR_UNSUPPORTED = "UNSUPPORTED"
        private const val ERR_UNKNOWN = "UNKNOWN"
    }

    private lateinit var channel: MethodChannel
    private var appContext: Context? = null
    private var activityBinding: ActivityPluginBinding? = null
    private val main = Handler(Looper.getMainLooper())
    private var currentCallback: ConnectivityManager.NetworkCallback? = null
    private var pendingJoin: MethodChannel.Result? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
        appContext = binding.applicationContext
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        leaveInternal()
        appContext = null
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
            "leave" -> handleLeave(result)
            "currentBoundSsid" -> result.success(currentSsid())
            "scanBroadlinkApSsids" -> scanWifi(result, ::filterBroadlinkSsids)
            "scan24GhzNetworks" -> scanWifi(result, ::filter24GhzNetworks)
            "bindToCurrentApIfBroadlink" -> handleBindToCurrent(result)
            "openWifiSettings" -> {
                openWifiSettings()
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
        if (pendingJoin != null) {
            result.error(ERR_BUSY, "another join is in progress", null)
            return
        }
        val ssid = call.argument<String>("ssid")
        if (ssid.isNullOrEmpty()) {
            result.error(ERR_UNKNOWN, "missing ssid", null)
            return
        }
        val timeoutMs = call.argument<Int>("timeoutMs") ?: 60_000

        val ctx = appContext ?: return result.error(ERR_UNKNOWN, "no context", null)
        val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

        // Tear down any leftover binding first.
        leaveInternal()

        val specifier = WifiNetworkSpecifier.Builder()
            .setSsid(ssid) // exact match — caller already scanned and picked
            .build()
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_TRUSTED)
            .setNetworkSpecifier(specifier)
            .build()

        var done = false
        pendingJoin = result
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                if (done) return
                done = true
                cm.bindProcessToNetwork(network)
                main.post {
                    pendingJoin = null
                    result.success(ssid)
                }
            }

            override fun onUnavailable() {
                if (done) return
                done = true
                main.post {
                    pendingJoin = null
                    result.error(ERR_AP_UNAVAILABLE, "AP not available within ${timeoutMs}ms", null)
                }
            }

            override fun onLost(network: Network) {
                // RM3 reboots out of AP mode → expected. Unbind so Dart sockets
                // stop routing into the void.
                cm.bindProcessToNetwork(null)
            }
        }
        currentCallback = cb
        try {
            cm.requestNetwork(request, cb, timeoutMs.coerceAtLeast(5_000))
        } catch (t: Throwable) {
            done = true
            pendingJoin = null
            currentCallback = null
            result.error(ERR_UNKNOWN, t.message ?: t.javaClass.simpleName, null)
            return
        }

        // Soft timeout in case the OS never invokes onUnavailable.
        main.postDelayed({
            if (!done) {
                done = true
                pendingJoin = null
                try { cm.unregisterNetworkCallback(cb) } catch (_: Throwable) {}
                currentCallback = null
                result.error(ERR_AP_UNAVAILABLE, "Timed out joining $ssid", null)
            }
        }, timeoutMs.toLong())
    }

    private fun handleLeave(result: MethodChannel.Result) {
        leaveInternal()
        result.success(null)
    }

    private fun leaveInternal() {
        val ctx = appContext ?: return
        val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        cm.bindProcessToNetwork(null)
        currentCallback?.let {
            try { cm.unregisterNetworkCallback(it) } catch (_: Throwable) {}
        }
        currentCallback = null
    }
    // endregion

    // region Wi-Fi state queries
    private fun currentSsid(): String? {
        val ctx = appContext ?: return null
        @Suppress("DEPRECATION")
        val wifi = ctx.getSystemService(Context.WIFI_SERVICE) as WifiManager
        @Suppress("DEPRECATION")
        val info = wifi.connectionInfo ?: return null
        @Suppress("DEPRECATION")
        val raw = info.ssid ?: return null
        val cleaned = raw.trim('"')
        return cleaned.takeIf { it.isNotBlank() && it != "<unknown ssid>" }
    }

    private fun handleBindToCurrent(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.error(ERR_UNSUPPORTED, "Android 10+ required", null)
            return
        }
        val ctx = appContext ?: return result.error(ERR_UNKNOWN, "no context", null)
        val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val ssid = currentSsid()
        if (ssid == null) {
            result.error("NO_WIFI", "Phone is not on a Wi-Fi network.", null)
            return
        }
        if (!looksLikeBroadlinkAp(ssid)) {
            result.error("NOT_BROADLINK", ssid, null)
            return
        }
        val wifiNet = cm.allNetworks.firstOrNull { net ->
            val caps = cm.getNetworkCapabilities(net) ?: return@firstOrNull false
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
        }
        if (wifiNet == null) {
            result.error("NO_NETWORK", "Wi-Fi network not enumerable.", null)
            return
        }
        cm.bindProcessToNetwork(wifiNet)
        result.success(ssid)
    }
    // endregion

    // region Scan helpers
    private fun <T> scanWifi(result: MethodChannel.Result, extract: () -> T) {
        val ctx = appContext ?: return result.error(ERR_UNKNOWN, "no context", null)
        @Suppress("DEPRECATION")
        val wifi = ctx.getSystemService(Context.WIFI_SERVICE) as WifiManager

        var done = false
        val safe: () -> Unit = {
            if (!done) {
                done = true
                main.post { result.success(extract()) }
            }
        }
        val filter = IntentFilter(WifiManager.SCAN_RESULTS_AVAILABLE_ACTION)
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                try { ctx.unregisterReceiver(this) } catch (_: Exception) {}
                safe()
            }
        }
        try {
            ctx.registerReceiver(receiver, filter)
        } catch (_: Exception) {
            safe()
            return
        }

        @Suppress("DEPRECATION")
        val started = wifi.startScan()
        if (!started) {
            // OEM throttling — return whatever's in the cache.
            try { ctx.unregisterReceiver(receiver) } catch (_: Exception) {}
            safe()
            return
        }

        main.postDelayed({
            try { ctx.unregisterReceiver(receiver) } catch (_: Exception) {}
            safe()
        }, 8_000)
    }

    private fun filterBroadlinkSsids(): List<String> {
        val ctx = appContext ?: return emptyList()
        @Suppress("DEPRECATION")
        val wifi = ctx.getSystemService(Context.WIFI_SERVICE) as WifiManager
        @Suppress("DEPRECATION")
        val results = try { wifi.scanResults ?: emptyList() } catch (_: SecurityException) { emptyList() }
        return results
            .mapNotNull { it.SSID }
            .filter { looksLikeBroadlinkAp(it) }
            .distinct()
    }

    private fun filter24GhzNetworks(): List<Map<String, Any?>> {
        val ctx = appContext ?: return emptyList()
        @Suppress("DEPRECATION")
        val wifi = ctx.getSystemService(Context.WIFI_SERVICE) as WifiManager
        @Suppress("DEPRECATION")
        val results = try { wifi.scanResults ?: emptyList() } catch (_: SecurityException) { emptyList() }
        return results
            .filter { it.frequency in 2400..2500 }
            .filter { !it.SSID.isNullOrBlank() && it.SSID != "<unknown ssid>" }
            .filter { !looksLikeBroadlinkAp(it.SSID) }
            .filter {
                // RM mini 3 only speaks WPA / WPA2. Pure-WPA3 networks (no
                // WPA2 transition) advertise `SAE` (WPA3-PSK) or `OWE`
                // (WPA3 Enhanced Open) WITHOUT a `WPA` substring. WPA2/WPA3
                // transition-mode APs advertise both `WPA2` and `SAE`, so
                // we keep those — the device will negotiate down to WPA2.
                val cap = it.capabilities ?: ""
                val pureWpa3 =
                    (cap.contains("SAE") || cap.contains("OWE")) &&
                            !cap.contains("WPA")
                !pureWpa3
            }
            .distinctBy { it.SSID }
            .sortedByDescending { it.level }
            .map { sr ->
                val cap = sr.capabilities ?: ""
                // SAE = WPA3-PSK. Pure-WPA3 networks (no WPA2 transition)
                // announce e.g. `[SAE-CCMP][RSN-CCMP][ESS]` with no "WPA"
                // substring, so without this they show up as open.
                // SAE present here means WPA2/WPA3 transition mode (we
                // filter pure-WPA3 below). Treat as secured.
                val secured = cap.contains("WPA") ||
                        cap.contains("WEP") ||
                        cap.contains("EAP") ||
                        cap.contains("SAE")
                mapOf(
                    "ssid" to sr.SSID,
                    "signal" to sr.level,
                    "secured" to secured,
                )
            }
    }

    private fun looksLikeBroadlinkAp(ssid: String): Boolean {
        val s = ssid.lowercase()
        return s.startsWith("broadlinkprov") || s.startsWith("broadlink_wifi_device")
    }
    // endregion

    private fun deviceInfo(): Map<String, Any?> = mapOf(
        "platform" to "android",
        "manufacturer" to Build.MANUFACTURER,
        "brand" to Build.BRAND,
        "model" to Build.MODEL,
        "device" to Build.DEVICE,
        "androidRelease" to Build.VERSION.RELEASE,
        "androidSdk" to Build.VERSION.SDK_INT,
    )

    private fun openWifiSettings() {
        val ctx = appContext ?: return
        val intent = Intent(Settings.ACTION_WIFI_SETTINGS)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        ctx.startActivity(intent)
    }
}
