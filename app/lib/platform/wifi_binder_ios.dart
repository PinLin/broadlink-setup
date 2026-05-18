import 'platform_exception_codes.dart';
import 'wifi_binder.dart';

/// iOS support is planned for v2 (Apple Developer Program + `NEHotspotConfiguration`).
/// For v1 every method throws so the app surfaces a clear "iOS not supported"
/// banner instead of pretending to work.
class WifiBinderIos implements WifiBinder {
  static const _msg =
      'iOS provisioning is not implemented in v1. See plan §6.';

  Never _unimplemented() =>
      throw WifiBinderException(WifiBinderErrorCode.unimplemented, _msg);

  @override
  Future<void> joinOpenAp(
    String ssid, {
    Duration timeout = const Duration(seconds: 30),
  }) async =>
      _unimplemented();

  @override
  Future<void> leave() async {
    // safe no-op so callers can put it in finally{}
  }

  @override
  Future<String?> currentBoundSsid() async => null;

  @override
  Future<List<String>> scanBroadlinkApSsids() async => const [];

  @override
  Future<List<WifiNetwork>> scan24GhzNetworks() async => const [];

  @override
  Future<String> bindToCurrentApIfBroadlink() async => _unimplemented();

  @override
  Future<void> openWifiSettings() async => _unimplemented();

  @override
  Future<Map<String, Object?>> deviceInfo() async => const {'platform': 'ios'};
}
