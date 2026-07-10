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
import android.os.Handler
import android.os.Looper
import android.provider.Settings

/**
 * Joins the Broadlink provisioning AP via [WifiNetworkSpecifier] and binds the
 * whole process to that network so Dart-side UDP sockets route through the AP
 * interface (and not, e.g., back over cellular when Android decides the AP
 * "has no internet"). UDP send/receive itself lives on the Dart side; this
 * class only manages the network binding lifecycle.
 *
 * Reverses on [leave], releasing the network back to the OS so the user's
 * preferred home Wi-Fi takes over. [WifiBinderPlugin] calls [leave] from
 * `onDetachedFromEngine`, which fires on Flutter hot-restart too — without
 * that call, hot-restarting mid-provisioning would leave the phone stranded
 * on the device AP.
 *
 * Error code strings returned via the `onResult`/`code` params below are part
 * of the wire contract — they must match `WifiBinderErrorCode` in
 * `platform_exception_codes.dart` on the Dart side.
 */
class WifiBinder(private val ctx: Context) {

    private val cm: ConnectivityManager =
        ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private val wifi: WifiManager =
        ctx.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
    private val main = Handler(Looper.getMainLooper())

    private var currentCallback: ConnectivityManager.NetworkCallback? = null

    /**
     * Join [ssid] (exact match — caller already scanned and picked it) and
     * bind the process to it once available. Reports through [onResult]
     * exactly once, on the main thread.
     */
    fun joinOpenAp(
        ssid: String,
        timeoutMs: Long,
        onResult: (ok: Boolean, code: String, msg: String) -> Unit
    ) {
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
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                if (done) return
                done = true
                cm.bindProcessToNetwork(network)
                main.post { onResult(true, "", ssid) } // msg carries the ssid on success
            }

            override fun onUnavailable() {
                if (done) return
                done = true
                main.post {
                    onResult(false, "AP_UNAVAILABLE", "AP not available within ${timeoutMs}ms")
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
            cm.requestNetwork(request, cb, timeoutMs.toInt().coerceAtLeast(5_000))
        } catch (t: Throwable) {
            done = true
            currentCallback = null
            onResult(false, "UNKNOWN", t.message ?: t.javaClass.simpleName)
            return
        }

        // Soft timeout in case the OS never invokes onUnavailable.
        main.postDelayed({
            if (!done) {
                done = true
                try { cm.unregisterNetworkCallback(cb) } catch (_: Throwable) {}
                currentCallback = null
                onResult(false, "AP_UNAVAILABLE", "Timed out joining $ssid")
            }
        }, timeoutMs)
    }

    /** Always unbinds the process, even if the join never succeeded — idempotent. */
    fun leave() = leaveInternal()

    private fun leaveInternal() {
        cm.bindProcessToNetwork(null)
        currentCallback?.let {
            try { cm.unregisterNetworkCallback(it) } catch (_: Throwable) {}
        }
        currentCallback = null
    }

    fun currentBoundSsid(): String? {
        @Suppress("DEPRECATION")
        val info = wifi.connectionInfo ?: return null
        @Suppress("DEPRECATION")
        val raw = info.ssid ?: return null
        val cleaned = raw.trim('"')
        return cleaned.takeIf { it.isNotBlank() && it != "<unknown ssid>" }
    }

    /**
     * If the phone is already connected to a Broadlink device AP (because the
     * user joined it manually in Android Settings, for example), bind the
     * process to that Wi-Fi network so socket I/O routes through it — without
     * invoking `WifiNetworkSpecifier`, which would re-prompt the user.
     *
     * Reports success only when the current Wi-Fi SSID matches a Broadlink
     * pattern.
     */
    fun bindToCurrentApIfBroadlink(
        onResult: (ok: Boolean, code: String, msg: String) -> Unit
    ) {
        val ssid = currentBoundSsid()
        if (ssid == null) {
            onResult(false, "NO_WIFI", "Phone is not on a Wi-Fi network.")
            return
        }
        if (!looksLikeBroadlinkAp(ssid)) {
            onResult(false, "NOT_BROADLINK", ssid)
            return
        }
        val wifiNet = cm.allNetworks.firstOrNull { net ->
            val caps = cm.getNetworkCapabilities(net) ?: return@firstOrNull false
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
        }
        if (wifiNet == null) {
            onResult(false, "NO_NETWORK", "Wi-Fi network not enumerable.")
            return
        }
        cm.bindProcessToNetwork(wifiNet)
        onResult(true, "", ssid)
    }

    fun scanBroadlinkApSsids(onResult: (List<String>) -> Unit) {
        scanWifi(::filterBroadlinkSsids, onResult)
    }

    private fun filterBroadlinkSsids(): List<String> {
        @Suppress("DEPRECATION")
        val results = try { wifi.scanResults ?: emptyList() } catch (_: SecurityException) { emptyList() }
        return results
            .mapNotNull { it.SSID }
            .filter { looksLikeBroadlinkAp(it) }
            .distinct()
    }

    /**
     * Scan nearby 2.4 GHz APs (excluding Broadlink device APs) and return a
     * list of `{ssid, signal, secured}` maps sorted by signal strength. Used
     * to populate the home Wi-Fi SSID picker so the user doesn't have to type
     * it.
     */
    fun scan24GhzNetworks(onResult: (List<Map<String, Any?>>) -> Unit) {
        scanWifi(::filter24GhzNetworks, onResult)
    }

    private fun filter24GhzNetworks(): List<Map<String, Any?>> {
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

    /**
     * Run a single Wi-Fi scan and dispatch results through [extract] exactly
     * once — even if both the broadcast receiver and the hard timeout fire.
     * Double-dispatch causes `Reply already submitted` on the MethodChannel.
     */
    private fun <T> scanWifi(extract: () -> T, onResult: (T) -> Unit) {
        var done = false
        val safe: () -> Unit = {
            if (!done) {
                done = true
                main.post { onResult(extract()) }
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

        // Hard timeout in case the scan-results broadcast never arrives.
        main.postDelayed({
            try { ctx.unregisterReceiver(receiver) } catch (_: Exception) {}
            safe()
        }, 8_000)
    }

    /** Open the Android system Wi-Fi settings page so the user can manually
     *  join the device's open AP. Returns immediately. */
    fun openWifiSettings() {
        val intent = Intent(Settings.ACTION_WIFI_SETTINGS)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        ctx.startActivity(intent)
    }

    private fun looksLikeBroadlinkAp(ssid: String): Boolean {
        val s = ssid.lowercase()
        return s.startsWith("broadlinkprov") || s.startsWith("broadlink_wifi_device")
    }
}
