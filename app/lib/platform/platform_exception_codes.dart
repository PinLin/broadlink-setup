/// Error codes shared between Dart and platform plugins.
///
/// String values must match the codes raised by the Kotlin / Swift plugin
/// implementations. Keep them in sync with `WifiBinderPlugin.kt`.
enum WifiBinderErrorCode {
  /// AP was not found / not joinable within the configured timeout.
  apUnavailable('AP_UNAVAILABLE'),

  /// User cancelled the system Wi-Fi consent dialog.
  apConsentDenied('AP_CONSENT_DENIED'),

  /// Connect was requested while another session is still active.
  busy('BUSY'),

  /// Phone is not connected to any Wi-Fi network.
  noWifi('NO_WIFI'),

  /// Phone is on Wi-Fi but the SSID does not look like a Broadlink AP.
  notBroadlink('NOT_BROADLINK'),

  /// Wi-Fi network could not be enumerated via ConnectivityManager.
  noNetwork('NO_NETWORK'),

  /// Android < 10 — we require WifiNetworkSpecifier.
  unsupported('UNSUPPORTED'),

  /// Platform does not implement this method (iOS v1 stub).
  unimplemented('UNIMPLEMENTED'),

  /// Anything we did not classify.
  unknown('UNKNOWN');

  const WifiBinderErrorCode(this.wireCode);
  final String wireCode;

  static WifiBinderErrorCode fromWire(String code) {
    for (final v in WifiBinderErrorCode.values) {
      if (v.wireCode == code) return v;
    }
    return WifiBinderErrorCode.unknown;
  }
}
