import 'dart:io' show Platform;

import 'wifi_binder.dart';
import 'wifi_binder_android.dart';
import 'wifi_binder_ios.dart';

/// Picks the right [WifiBinder] for the current platform.
///
/// Kept as a top-level function so tests can pass in a mock.
WifiBinder createWifiBinder() {
  if (Platform.isAndroid) return WifiBinderAndroid();
  if (Platform.isIOS) return WifiBinderIos();
  throw UnsupportedError(
    'Unsupported platform: ${Platform.operatingSystem}. '
    'broadlink_provisioner supports Android (v1) and iOS (v2 stub).',
  );
}
