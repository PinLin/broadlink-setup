import 'platform_exception_codes.dart';

/// Platform-abstract Wi-Fi binder. Mirrors the Kasa-style approach: programmatically
/// join an open AP via [WifiNetworkSpecifier] (Android) / [NEHotspotConfiguration]
/// (iOS, v2), then `bindProcessToNetwork` so Dart-side `RawDatagramSocket` traffic
/// routes through that AP automatically. UDP send/receive lives in pure Dart.
abstract class WifiBinder {
  /// Connect to an open AP named [ssid]. Throws [WifiBinderException] with
  /// [WifiBinderErrorCode.apUnavailable] on timeout.
  Future<void> joinOpenAp(
    String ssid, {
    Duration timeout = const Duration(seconds: 30),
  });

  /// Release the bound network so the OS returns the phone to its preferred
  /// Wi-Fi. Idempotent.
  Future<void> leave();

  /// SSID the phone reports as its current Wi-Fi network, or `null` if not on
  /// any. Used to verify the join landed where we wanted.
  Future<String?> currentBoundSsid();

  /// Scans for AP SSIDs that look like a factory-reset BroadLink device
  /// (`BroadlinkProv*` / `BroadLink_WiFi_Device*`).
  Future<List<String>> scanBroadlinkApSsids();

  /// Scans 2.4 GHz networks the user could pick as the home Wi-Fi target.
  /// Excludes Broadlink device APs. Sorted by signal strength, descending.
  Future<List<WifiNetwork>> scan24GhzNetworks();

  /// If the phone is already manually connected to a Broadlink AP, bind the
  /// process to that network and return the SSID. Useful when auto-join fails
  /// and the user falls back to system Wi-Fi settings.
  Future<String> bindToCurrentApIfBroadlink();

  /// Open the platform's Wi-Fi settings page (escape hatch).
  Future<void> openWifiSettings();

  /// Returns a map of device info fields (manufacturer, model, OS version, …)
  /// for the diagnostic log.
  Future<Map<String, Object?>> deviceInfo();
}

class WifiNetwork {
  const WifiNetwork({
    required this.ssid,
    required this.signalDbm,
    required this.secured,
  });

  final String ssid;
  final int signalDbm;
  final bool secured;

  factory WifiNetwork.fromMap(Map<String, dynamic> m) => WifiNetwork(
        ssid: (m['ssid'] as String?) ?? '',
        signalDbm: (m['signal'] as int?) ?? -100,
        secured: (m['secured'] as bool?) ?? true,
      );
}

class WifiBinderException implements Exception {
  WifiBinderException(this.code, this.message, [this.details]);
  final WifiBinderErrorCode code;
  final String message;
  final Object? details;

  @override
  String toString() => 'WifiBinderException(${code.name}): $message';
}
