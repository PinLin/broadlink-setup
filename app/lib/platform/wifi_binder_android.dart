import 'package:flutter/services.dart';

import 'platform_exception_codes.dart';
import 'wifi_binder.dart';

class WifiBinderAndroid implements WifiBinder {
  WifiBinderAndroid({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  static const String channelName = 'broadlink_setup/wifi';

  final MethodChannel _channel;

  WifiBinderException _wrap(PlatformException e) => WifiBinderException(
        WifiBinderErrorCode.fromWire(e.code),
        e.message ?? 'platform error',
        e.details,
      );

  @override
  Future<void> joinOpenAp(
    String ssid, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    try {
      await _channel.invokeMethod<String>('joinOpenAp', {
        'ssid': ssid,
        'timeoutMs': timeout.inMilliseconds,
      }).timeout(timeout + const Duration(seconds: 2));
    } on PlatformException catch (e) {
      throw _wrap(e);
    }
  }

  @override
  Future<void> leave() async {
    try {
      await _channel.invokeMethod<void>('leave');
    } on PlatformException {
      // best-effort cleanup
    } on MissingPluginException {
      // not registered (e.g. widget test) — ignore
    }
  }

  @override
  Future<String?> currentBoundSsid() async {
    try {
      return await _channel.invokeMethod<String>('currentBoundSsid');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<List<String>> scanBroadlinkApSsids() async {
    try {
      final result = await _channel.invokeMethod<List<Object?>>(
        'scanBroadlinkApSsids',
      );
      return (result ?? const <Object?>[]).cast<String>();
    } on PlatformException {
      return const [];
    } on MissingPluginException {
      return const [];
    }
  }

  @override
  Future<List<WifiNetwork>> scan24GhzNetworks() async {
    try {
      final result = await _channel.invokeMethod<List<Object?>>(
        'scan24GhzNetworks',
      );
      return (result ?? const <Object?>[])
          .map((e) => WifiNetwork.fromMap((e as Map).cast<String, dynamic>()))
          .toList(growable: false);
    } on PlatformException {
      return const [];
    } on MissingPluginException {
      return const [];
    }
  }

  @override
  Future<String> bindToCurrentApIfBroadlink() async {
    try {
      final ssid = await _channel.invokeMethod<String>(
        'bindToCurrentApIfBroadlink',
      );
      return ssid ?? '';
    } on PlatformException catch (e) {
      throw _wrap(e);
    }
  }

  @override
  Future<void> openWifiSettings() async {
    try {
      await _channel.invokeMethod<void>('openWifiSettings');
    } on PlatformException {
      // best-effort
    } on MissingPluginException {
      // best-effort
    }
  }

  @override
  Future<Map<String, Object?>> deviceInfo() async {
    try {
      final result = await _channel.invokeMapMethod<String, Object?>(
        'deviceInfo',
      );
      return result ?? const {};
    } on PlatformException {
      return const {};
    } on MissingPluginException {
      return const {};
    }
  }
}
