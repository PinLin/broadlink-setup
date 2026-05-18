import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'diagnostics.dart';
import 'platform/platform_exception_codes.dart';
import 'platform/wifi_binder.dart';
import 'platform/wifi_binder_factory.dart';
import 'protocol/ap_packet.dart';
import 'protocol/encoding_strategy.dart';
import 'protocol/lan_listener.dart';
import 'protocol/security_mode.dart';

void main() => runApp(const ProvisionerApp());

class ProvisionerApp extends StatelessWidget {
  const ProvisionerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BroadLink RM mini 3 Setup',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.indigo,
      ),
      themeMode: ThemeMode.system,
      home: const SetupScreen(),
    );
  }
}

enum SetupStep {
  intro,
  awaitDevice,
  pickHomeWifi,
  sendingCredentials,
  waitingForJoin,
  discoveringOnHomeWifi,
  done,
  error,
}

class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key})
      : debugInitialStep = null,
        debugApSsid = null,
        debugHomeNetworks = const [],
        debugDiscovered = null,
        debugError = null;

  @visibleForTesting
  const SetupScreen.preview({
    super.key,
    required SetupStep this.debugInitialStep,
    this.debugApSsid,
    this.debugHomeNetworks = const [],
    this.debugDiscovered,
    this.debugError,
  });

  final SetupStep? debugInitialStep;
  final String? debugApSsid;
  final List<WifiNetwork> debugHomeNetworks;
  final DiscoveredDevice? debugDiscovered;
  final String? debugError;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  late SetupStep _step;
  String? _errorMessage;

  WifiBinder get _binder => _wifiBinder ??= createWifiBinder();
  WifiBinder? _wifiBinder;

  // awaitDevice: nearby BroadLink APs we've scanned for.
  List<String> _broadlinkAps = const [];
  bool _scanningAps = false;
  String? _joiningAp;
  String? _joinError;
  Timer? _apPoller;

  // After successful join, the SSID we are on.
  String? _apSsid;

  // The SSID the phone is currently bound to (polled while in awaitDevice).
  // Surfaced as a grey footer so the user has an escape-hatch signal when
  // they join manually via Wi-Fi Settings.
  String? _currentBoundSsid;

  // pickHomeWifi: nearby 2.4 GHz networks for the user to pick.
  List<WifiNetwork> _homeNetworks = const [];
  bool _scanningHomeNetworks = false;
  WifiNetwork? _selectedHomeNetwork;
  bool _manualSsidMode = false;
  bool _autoSwitchedToManual = false;
  final _manualSsidCtl = TextEditingController();
  final _passwordCtl = TextEditingController();
  SecurityMode _manualSecurity = SecurityMode.wpa2;
  bool _showPassword = false;

  DiscoveredDevice? _discovered;

  @override
  void initState() {
    super.initState();
    _step = widget.debugInitialStep ?? SetupStep.intro;
    _homeNetworks = widget.debugHomeNetworks;
    _apSsid = widget.debugApSsid;
    _discovered = widget.debugDiscovered;
    _errorMessage = widget.debugError;
    unawaited(_loadDeviceInfo());
  }

  Future<void> _loadDeviceInfo() async {
    try {
      Diagnostics.instance.setDeviceInfo(await _binder.deviceInfo());
    } catch (_) {
      // best-effort; diagnostic still useful without it
    }
  }

  @override
  void dispose() {
    _manualSsidCtl.dispose();
    _passwordCtl.dispose();
    _apPoller?.cancel();
    _binder.leave();
    super.dispose();
  }

  // ---- transitions ---------------------------------------------------------

  Future<void> _start() async {
    Diagnostics.instance.event('flow', 'user pressed Next on intro');
    if (!await _ensurePermissions()) {
      Diagnostics.instance.event(
        'permission',
        'location or nearbyWifiDevices was denied',
        level: DiagLevel.error,
      );
      _showError(
        'Location and/or Nearby Wi-Fi Devices permission was denied. Both are '
        'needed because Samsung\'s WifiService rejects scan results without '
        'location permission, even on Android 13+. Open Settings → Apps → '
        'BroadLink RM mini 3 Setup → Permissions, allow both, then tap Start over.',
      );
      return;
    }
    Diagnostics.instance.event('permission', 'all required permissions granted');
    unawaited(_refreshHomeNetworks());
    setState(() => _step = SetupStep.awaitDevice);
    _startApPolling();
    unawaited(_scanBroadlinkAps());
  }

  Future<bool> _ensurePermissions() async {
    // Both are required in practice — Samsung's WifiService enforces a
    // location check even on Android 13+ where Google's docs claim
    // NEARBY_WIFI_DEVICES alone is enough. See logcat:
    //   "Permission violation - startScan not allowed ... no location permission".
    final loc = await Permission.locationWhenInUse.request();
    final near = await Permission.nearbyWifiDevices.request();
    final locOk = loc.isGranted || loc.isLimited;
    // nearbyWifiDevices is meaningless on Android 12-, returns permanentlyDenied;
    // accept either granted or limited or permanentlyDenied-on-old-Android.
    final nearOk =
        near.isGranted || near.isLimited || near.isPermanentlyDenied;
    return locOk && nearOk;
  }

  void _startApPolling() {
    _apPoller?.cancel();
    // Poll ONLY the currently-bound SSID, not the AP list. Re-scanning the AP
    // list every tick wastes battery, flickers the candidate list between
    // "Scanning..." and the results, and can race the explicit user join.
    // The initial AP scan still fires once in _start, and the explicit
    // "Re-scan" button is the only path to re-scan the list.
    _apPoller = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _checkCurrentBoundSsid(),
    );
  }

  Future<void> _checkCurrentBoundSsid() async {
    if (!mounted || _step != SetupStep.awaitDevice) return;
    final ssid = await _binder.currentBoundSsid();
    if (!mounted) return;
    setState(() => _currentBoundSsid = ssid);
  }

  Future<void> _scanBroadlinkAps() async {
    if (!mounted || _step != SetupStep.awaitDevice) return;
    if (_joiningAp != null) return;
    setState(() => _scanningAps = true);
    try {
      final found = await _binder.scanBroadlinkApSsids();
      if (!mounted) return;
      Diagnostics.instance.event(
        'scan.ap',
        'broadlink APs visible: ${found.length}',
      );
      setState(() => _broadlinkAps = found);
      // Exactly one match → auto-join. Android still shows its own one-tap
      // consent dialog, but the user doesn't have to pick from a list.
      if (found.length == 1 &&
          _joiningAp == null &&
          _step == SetupStep.awaitDevice) {
        await _joinAp(found.first);
      }
    } finally {
      if (mounted) setState(() => _scanningAps = false);
    }
  }

  Future<void> _joinAp(String ssid) async {
    if (!mounted) return;
    Diagnostics.instance.event('join.ap', 'joining "$ssid"');
    setState(() {
      _joiningAp = ssid;
      _joinError = null;
    });
    try {
      await _binder.joinOpenAp(ssid);
      if (!mounted) return;
      Diagnostics.instance.event('join.ap', 'joined "$ssid", process bound');
      _apPoller?.cancel();
      unawaited(_refreshHomeNetworks());
      setState(() {
        _apSsid = ssid;
        _joiningAp = null;
        _step = SetupStep.pickHomeWifi;
      });
    } on WifiBinderException catch (e) {
      if (!mounted) return;
      Diagnostics.instance.event(
        'join.ap',
        'failed: ${e.code.name}: ${e.message}',
        level: DiagLevel.error,
      );
      setState(() {
        _joiningAp = null;
        _joinError = _describeError(e);
      });
    }
  }

  Future<void> _refreshHomeNetworks() async {
    if (!mounted) return;
    setState(() => _scanningHomeNetworks = true);
    try {
      final found = await _binder.scan24GhzNetworks();
      if (!mounted) return;
      Diagnostics.instance.event(
        'scan.home',
        '2.4 GHz networks visible: ${found.length}',
      );
      setState(() {
        _homeNetworks = found;
        // Drop the user straight into manual SSID mode if the scan returned
        // zero 2.4 GHz networks — there is nothing to pick and the only
        // useful action is typing the SSID. The banner explains why.
        if (found.isEmpty && !_manualSsidMode && !_autoSwitchedToManual) {
          _manualSsidMode = true;
          _autoSwitchedToManual = true;
          Diagnostics.instance.event(
            'scan.home',
            'no 2.4 GHz APs visible — auto-switched to manual SSID entry',
            level: DiagLevel.warn,
          );
        }
      });
    } finally {
      if (mounted) setState(() => _scanningHomeNetworks = false);
    }
  }

  String _homeSsid() {
    if (_manualSsidMode) return _manualSsidCtl.text.trim();
    return _selectedHomeNetwork?.ssid ?? '';
  }

  SecurityMode _homeSecurity() {
    if (_manualSsidMode) return _manualSecurity;
    final secured = _selectedHomeNetwork?.secured ?? true;
    return secured ? SecurityMode.wpa2 : SecurityMode.none;
  }

  bool _canProvision() {
    if (_homeSsid().isEmpty) return false;
    if (_homeSecurity() != SecurityMode.none && _passwordCtl.text.isEmpty) {
      return false;
    }
    return true;
  }

  Future<void> _provision() async {
    final ssid = _homeSsid();
    final security = _homeSecurity();
    final password = _passwordCtl.text;
    Diagnostics.instance.event(
      'provision',
      'starting — security=${security.name} ssidLen(utf8)=${byteLengthForDisplay(ssid).utf8}B '
      'passwordLen(utf8)=${byteLengthForDisplay(password).utf8}B '
      '(values themselves redacted)',
    );

    try {
      // Attempt 0 = UTF-8, attempt 1 = GBK fallback.
      DiscoveredDevice? device;
      for (var attempt = 0; attempt < attemptCount; attempt++) {
        final Uint8List ssidBytes;
        final Uint8List passwordBytes;
        try {
          ssidBytes = Uint8List.fromList(encodeAttempt(ssid, attempt));
          passwordBytes = Uint8List.fromList(encodeAttempt(password, attempt));
        } on FormatException {
          continue;
        }
        if (ssidBytes.length > 32 || passwordBytes.length > 32) {
          // Try the other encoding before giving up.
          continue;
        }
        final payload = buildApPacket(
          ssid: ssidBytes,
          password: passwordBytes,
          security: security,
        );
        Diagnostics.instance.packetSummary(
          'provision.payload',
          payload,
          attempt: attempt,
        );

        setState(() => _step = SetupStep.sendingCredentials);
        await _sendPayload(payload);

        setState(() => _step = SetupStep.waitingForJoin);
        await _binder.leave();
        Diagnostics.instance.event(
          'provision',
          'sent payload, left AP, waiting 12 s for device reboot',
        );
        // RM mini 3 reboots out of AP mode, joins home Wi-Fi, then announces.
        // Give phone + device ~12 s before scanning.
        await Future<void>.delayed(const Duration(seconds: 12));

        setState(() => _step = SetupStep.discoveringOnHomeWifi);
        device = await _findOnHomeWifi();
        if (device != null) {
          Diagnostics.instance.event(
            'discover',
            'device announced: devtype=0x${device.deviceType.toRadixString(16).padLeft(4, '0')} '
            'ip=${device.ip} mac=${device.macHex} locked=${device.isLocked}',
          );
          break;
        }
        Diagnostics.instance.event(
          'discover',
          'no device on LAN after attempt $attempt',
          level: DiagLevel.warn,
        );
        // Failed — re-join the AP for the next encoding attempt.
        if (attempt < attemptCount - 1) {
          await _binder.joinOpenAp(_apSsid!);
        }
      }

      if (device == null) {
        _showError(
          'The RM mini 3 did not announce itself on your Wi-Fi. Most likely causes:\n'
          '  • Wrong home Wi-Fi password.\n'
          '  • Your home network is 5 GHz only — RM mini 3 cannot join 5 GHz.\n'
          '  • Your router blocks UDP broadcasts on the home subnet.\n'
          'Factory-reset the RM mini 3 (long-press the reset pinhole until the LED '
          'slow-blinks) and tap Start over.',
        );
        return;
      }

      setState(() {
        _discovered = device;
        _step = SetupStep.done;
      });
    } on WifiBinderException catch (e) {
      Diagnostics.instance.event(
        'provision',
        'wifibinder error ${e.code.name}: ${e.message}',
        level: DiagLevel.error,
      );
      _showError(_describeError(e));
      await _binder.leave();
    } catch (e, st) {
      Diagnostics.instance.event(
        'provision',
        'unexpected: $e\n$st',
        level: DiagLevel.error,
      );
      _showError(e.toString());
      await _binder.leave();
    }
  }

  Future<void> _sendPayload(Uint8List payload) async {
    // We're bound to the BroadlinkProv network — RawDatagramSocket sourced
    // here will route via Wi-Fi. Send 8x with 500 ms gap; the device usually
    // accepts after 1 and reboots out of AP mode, so later sends may raise
    // OS errors which we swallow.
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    socket.broadcastEnabled = true;
    try {
      for (var i = 0; i < 8; i++) {
        try {
          socket.send(payload, InternetAddress('255.255.255.255'), 80);
          socket.send(payload, InternetAddress('192.168.10.1'), 80);
        } on SocketException {
          // AP went away — RM mini 3 accepted credentials and rebooted. Done.
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    } finally {
      socket.close();
    }
  }

  Future<DiscoveredDevice?> _findOnHomeWifi() async {
    final localIp = await _findHomeIp();
    if (localIp == null) return null;
    final listener = LanListener(
      utcOffsetHours: DateTime.now().timeZoneOffset.inHours,
    );
    final completer = Completer<DiscoveredDevice?>();
    final sub = listener
        .listen(timeout: const Duration(seconds: 30), localIp: localIp)
        .listen(
      (d) {
        if (!completer.isCompleted) completer.complete(d);
      },
      onError: (_) {
        if (!completer.isCompleted) completer.complete(null);
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete(null);
      },
    );
    final result = await completer.future;
    await sub.cancel();
    return result;
  }

  Future<String?> _findHomeIp() async {
    final ifaces = await NetworkInterface.list(
      includeLinkLocal: false,
      includeLoopback: false,
      type: InternetAddressType.IPv4,
    );
    for (final iface in ifaces) {
      for (final addr in iface.addresses) {
        // Skip the BroadlinkProv subnet — we want the phone's home Wi-Fi IP.
        if (addr.address.startsWith('192.168.10.')) continue;
        return addr.address;
      }
    }
    return null;
  }

  String _describeError(WifiBinderException e) {
    switch (e.code) {
      case WifiBinderErrorCode.apUnavailable:
        return 'Could not join the device hotspot — make sure the RM mini 3 LED is '
            'slow-blinking and the AP is visible.';
      case WifiBinderErrorCode.unsupported:
        return 'This device runs Android ${Platform.operatingSystemVersion}, '
            'which is too old. Android 10+ required.';
      case WifiBinderErrorCode.busy:
        return 'Another connect attempt is already running. Wait a moment.';
      case WifiBinderErrorCode.notBroadlink:
        return 'You are on Wi-Fi "${e.message}", which is not a BroadLink AP.';
      case WifiBinderErrorCode.noWifi:
        return 'Your phone is not on any Wi-Fi network.';
      case WifiBinderErrorCode.unimplemented:
        return e.message;
      default:
        return '${e.code.name}: ${e.message}';
    }
  }

  void _showError(String msg) {
    _apPoller?.cancel();
    setState(() {
      _step = SetupStep.error;
      _errorMessage = msg;
    });
  }

  void _restart() {
    _apPoller?.cancel();
    Diagnostics.instance.clear();
    setState(() {
      _step = SetupStep.intro;
      _errorMessage = null;
      _apSsid = null;
      _broadlinkAps = const [];
      _joiningAp = null;
      _joinError = null;
      _currentBoundSsid = null;
      _selectedHomeNetwork = null;
      _manualSsidMode = false;
      _autoSwitchedToManual = false;
      _manualSsidCtl.clear();
      _passwordCtl.clear();
      _manualSecurity = SecurityMode.wpa2;
      _showPassword = false;
      _discovered = null;
    });
  }

  // ---- views ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    // Intercept the system Back gesture so the user rewinds through the
    // flow instead of crashing out of the app on first press. Back at intro
    // still exits; back anywhere else returns to intro via _restart() (which
    // cancels timers, releases the WifiBinder, and clears credentials).
    return PopScope(
      canPop: _step == SetupStep.intro,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _step != SetupStep.intro) _restart();
      },
      child: Scaffold(
      appBar: AppBar(
        title: const Text('BroadLink RM mini 3 Setup'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: switch (_step) {
            SetupStep.intro => _introView(),
            SetupStep.awaitDevice => _awaitDeviceView(),
            SetupStep.pickHomeWifi => _pickHomeWifiView(),
            SetupStep.sendingCredentials =>
              _busyView('Sending Wi-Fi credentials to the RM mini 3…'),
            SetupStep.waitingForJoin =>
              _busyView('Waiting for the RM mini 3 to join your Wi-Fi…'),
            SetupStep.discoveringOnHomeWifi =>
              _busyView('Looking for the RM mini 3 on your home Wi-Fi…'),
            SetupStep.done => _doneView(),
            SetupStep.error => _errorView(),
          },
        ),
      ),
      ),
    );
  }

  Widget _introView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Set up a BroadLink RM mini 3 without a BroadLink account.',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 16),
        const Text('How it works:', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        const _Step(
          n: 1,
          text: 'Factory-reset the RM mini 3 — long-press the reset pinhole until the '
              'LED is slow-blinking (about every 1 s).',
        ),
        const _Step(
          n: 2,
          text: 'The app finds the device hotspot and joins it for you. '
              'Android shows a one-tap consent dialog.',
        ),
        const _Step(
          n: 3,
          text: 'Pick your home 2.4 GHz Wi-Fi from the list — or enter it '
              'manually if it\'s hidden.',
        ),
        const _Step(
          n: 4,
          text: 'The RM mini 3 joins your home Wi-Fi in ~15 seconds.',
        ),
        const Spacer(),
        FilledButton(onPressed: _start, child: const Text('Next')),
      ],
    );
  }

  Widget _awaitDeviceView() {
    // Wrapped in SingleChildScrollView to prevent a ~2 px bottom overflow on
    // ~360x800 viewports when the grey "Phone is currently on..." footer is
    // shown together with the AP list and the action-buttons row. Outer
    // padding from the parent Scaffold is preserved; this scroll view only
    // adds its own padding when no parent padding is in effect.
    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
        const Text(
          'Connect to the RM mini 3 hotspot',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        if (_joiningAp != null)
          _statusCard(
            spinning: true,
            text: 'Joining "$_joiningAp"…\n'
                'Tap "Connect" if Android asks for confirmation.',
          )
        else if (_scanningAps && _broadlinkAps.isEmpty)
          _statusCard(
            spinning: true,
            text: 'Scanning for nearby BroadLink hotspots…\n'
                'Make sure the RM mini 3 is factory-reset (LED slow-blinking).',
          )
        else if (_broadlinkAps.isEmpty)
          _statusCard(
            spinning: false,
            text: 'No BroadLink hotspots found nearby.\n'
                'Long-press the reset pinhole until the LED is slow-blinking '
                'and stay within 2 m.',
          )
        else
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Pick a hotspot to join:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              ..._broadlinkAps.map(
                (s) => Card(
                  margin: const EdgeInsets.symmetric(vertical: 2),
                  child: ListTile(
                    leading: const Icon(Icons.wifi_tethering),
                    title: Text(s),
                    onTap: () => _joinAp(s),
                  ),
                ),
              ),
            ],
          ),
        if (_joinError != null) ...[
          const SizedBox(height: 12),
          Card(
            color: Theme.of(context).colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                'Auto-join failed: $_joinError\n'
                'Tap a hotspot to retry, or use Wi-Fi Settings below.',
              ),
            ),
          ),
        ],
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('Re-scan'),
                onPressed: _scanningAps ? null : _scanBroadlinkAps,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.settings),
                label: const Text('Wi-Fi Settings'),
                onPressed: _binder.openWifiSettings,
              ),
            ),
          ],
        ),
        if (_currentBoundSsid != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              'Phone is currently on "$_currentBoundSsid".',
              style: TextStyle(
                color: Theme.of(context).colorScheme.outline,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _pickHomeWifiView() {
    final ap = _apSsid ?? 'the RM mini 3';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Pick the Wi-Fi for "$ap" to join',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        Text(
          'Only 2.4 GHz networks are listed — RM mini 3 does not support 5 GHz.',
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.outline,
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: _manualSsidMode ? _manualSsidForm() : _homeNetworkList(),
        ),
        if (_manualSsidMode) ...[
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _canProvision() ? _provision : null,
            child: const Text('Provision'),
          ),
        ],
      ],
    );
  }

  Widget _homeNetworkList() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Text('Nearby networks',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const Spacer(),
            if (_scanningHomeNetworks)
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              IconButton(
                icon: const Icon(Icons.refresh, size: 18),
                tooltip: 'Re-scan',
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                onPressed: _refreshHomeNetworks,
              ),
          ],
        ),
        Expanded(
          child: ListView(
            children: [
              if (!_scanningHomeNetworks) ..._homeNetworks.map(_homeNetworkTile),
              if (_homeNetworks.isEmpty && !_scanningHomeNetworks)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Text(
                    'No 2.4 GHz networks found nearby.\n'
                    'Try "Enter SSID manually" below.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.edit),
                label: const Text('Enter SSID manually (hidden network)'),
                onPressed: () {
                  setState(() {
                    _manualSsidMode = true;
                    _selectedHomeNetwork = null;
                    _passwordCtl.clear();
                  });
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _homeNetworkTile(WifiNetwork n) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 2),
      child: ListTile(
        leading: Icon(n.secured ? Icons.lock : Icons.lock_open),
        title: Text(n.ssid),
        trailing: Text(
          _signalBars(n.signalDbm),
          style: const TextStyle(fontFamily: 'monospace'),
        ),
        onTap: () => _promptAndProvisionForNetwork(n),
      ),
    );
  }

  /// Picker flow: collect the password (or confirm an open network) in a
  /// modal dialog, then start provisioning. The persistent credentials form
  /// is reserved for the manual-SSID branch where the user still types the
  /// hidden SSID + security mode before the password.
  Future<void> _promptAndProvisionForNetwork(WifiNetwork n) async {
    if (!n.secured) {
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Use "${n.ssid}"?'),
          content: const Text(
            'This is an open Wi-Fi network — no password will be sent.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Provision'),
            ),
          ],
        ),
      );
      if (go != true || !mounted) return;
      setState(() {
        _selectedHomeNetwork = n;
        _passwordCtl.clear();
        _showPassword = false;
      });
      await _provision();
      return;
    }

    final ctl = TextEditingController();
    var show = false;
    final password = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text('Password for "${n.ssid}"'),
          content: TextField(
            controller: ctl,
            autofocus: true,
            obscureText: !show,
            decoration: InputDecoration(
              labelText: 'Wi-Fi Password',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(show ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setLocal(() => show = !show),
              ),
            ),
            onSubmitted: (v) =>
                v.isEmpty ? null : Navigator.pop(ctx, v),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => ctl.text.isEmpty
                  ? null
                  : Navigator.pop(ctx, ctl.text),
              child: const Text('Provision'),
            ),
          ],
        ),
      ),
    );
    ctl.dispose();
    if (password == null || password.isEmpty || !mounted) return;
    setState(() {
      _selectedHomeNetwork = n;
      _passwordCtl.text = password;
      _showPassword = false;
    });
    await _provision();
  }

  Widget _manualSsidForm() {
    return ListView(
      children: [
        if (_autoSwitchedToManual)
          Card(
            color: Theme.of(context).colorScheme.errorContainer,
            margin: const EdgeInsets.only(bottom: 12),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.warning_amber_outlined, size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'No 2.4 GHz Wi-Fi networks were visible from this phone. '
                      'RM mini 3 cannot join 5 GHz. Either:\n'
                      '  • your home router has 2.4 GHz disabled (turn it back on), or\n'
                      '  • your home Wi-Fi is hidden — enter the SSID below.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          )
        else
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.arrow_back, size: 18),
              label: const Text('Back to network list'),
              onPressed: () {
                setState(() {
                  _manualSsidMode = false;
                  _manualSsidCtl.clear();
                  _passwordCtl.clear();
                });
              },
            ),
          ),
        const SizedBox(height: 8),
        TextField(
          controller: _manualSsidCtl,
          decoration: const InputDecoration(
            labelText: 'Wi-Fi SSID (2.4 GHz)',
            border: OutlineInputBorder(),
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<SecurityMode>(
          initialValue: _manualSecurity,
          decoration: const InputDecoration(
            labelText: 'Security',
            border: OutlineInputBorder(),
          ),
          items: const [
            DropdownMenuItem(
              value: SecurityMode.wpa2,
              child: Text('WPA2 (most common)'),
            ),
            DropdownMenuItem(
              value: SecurityMode.wpa12,
              child: Text('WPA / WPA2 mixed'),
            ),
            DropdownMenuItem(
              value: SecurityMode.wpa1,
              child: Text('WPA1'),
            ),
            DropdownMenuItem(
              value: SecurityMode.wep,
              child: Text('WEP (legacy)'),
            ),
            DropdownMenuItem(
              value: SecurityMode.none,
              child: Text('Open / no password'),
            ),
          ],
          onChanged: (v) =>
              setState(() => _manualSecurity = v ?? SecurityMode.wpa2),
        ),
        if (_manualSecurity != SecurityMode.none) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _passwordCtl,
            decoration: InputDecoration(
              labelText: 'Wi-Fi Password',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(
                  _showPassword ? Icons.visibility_off : Icons.visibility,
                ),
                onPressed: () =>
                    setState(() => _showPassword = !_showPassword),
              ),
            ),
            obscureText: !_showPassword,
          ),
        ],
      ],
    );
  }

  static String _signalBars(int dbm) {
    if (dbm >= -55) return '████';
    if (dbm >= -65) return '███░';
    if (dbm >= -75) return '██░░';
    return '█░░░';
  }

  Widget _statusCard({required bool spinning, required String text}) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            if (spinning)
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              const Icon(Icons.info_outline),
            const SizedBox(width: 12),
            Expanded(child: Text(text)),
          ],
        ),
      ),
    );
  }

  Widget _busyView(String message) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(message, textAlign: TextAlign.center),
        ],
      ),
    );
  }

  Widget _doneView() {
    final d = _discovered;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Center(
                  child: Icon(Icons.check_circle, size: 64, color: Colors.green),
                ),
                const SizedBox(height: 12),
                const Center(
                  child: Text('Provisioning succeeded.',
                      style: TextStyle(fontSize: 20)),
                ),
                const SizedBox(height: 16),
                if (d != null) ...[
                  _row('IP', d.ip),
                  _row('MAC', d.macHex),
                  _row('devtype',
                      '0x${d.deviceType.toRadixString(16).padLeft(4, '0')}'),
                  _row('Name', d.name.isEmpty ? '(unset)' : d.name),
                  _row('Locked', d.isLocked ? 'yes' : 'no'),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        OutlinedButton(
          onPressed: _restart,
          child: const Text('Set up another'),
        ),
      ],
    );
  }

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            SizedBox(
              width: 80,
              child: Text(k,
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
            Expanded(
              child: SelectableText(v,
                  style: const TextStyle(fontFamily: 'monospace')),
            ),
          ],
        ),
      );

  Widget _errorView() {
    final platformHint = Platform.isAndroid
        ? ''
        : '\n\nThis app currently only supports Android. iOS support is planned for v2.';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Center(
                  child: Icon(Icons.error_outline, size: 64, color: Colors.red),
                ),
                const SizedBox(height: 16),
                Text(
                  _errorMessage ?? 'Unknown error.$platformHint',
                  style: const TextStyle(fontSize: 14),
                  textAlign: TextAlign.left,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _restart,
          child: const Text('Start over'),
        ),
      ],
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.n, required this.text});
  final int n;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 24,
            child: Text(
              '$n.',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}
