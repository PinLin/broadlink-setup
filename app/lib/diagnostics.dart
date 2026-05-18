import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Event stream the UI collects so a stuck user can copy a sharable log to
/// paste into an issue. Privacy bar: SSID and password bytes never enter
/// events — we record sizes/security/checksum but not the bytes themselves.
class Diagnostics {
  Diagnostics._();
  static final Diagnostics instance = Diagnostics._();

  final List<DiagEvent> _events = [];
  Map<String, Object?>? _deviceInfo;

  List<DiagEvent> get events => List.unmodifiable(_events);
  Map<String, Object?>? get deviceInfo => _deviceInfo;

  void setDeviceInfo(Map<String, Object?> info) {
    _deviceInfo = info;
  }

  void event(String tag, String message, {DiagLevel level = DiagLevel.info}) {
    _events.add(DiagEvent(DateTime.now(), level, tag, message));
  }

  void packetSummary(String tag, Uint8List payload, {required int attempt}) {
    final ssidLen = payload[0x84];
    final passLen = payload[0x85];
    final security = payload[0x86];
    final checksum =
        '${payload[0x20].toRadixString(16).padLeft(2, '0')}'
        '${payload[0x21].toRadixString(16).padLeft(2, '0')}';
    final shortHash = sha256.convert(payload).toString().substring(0, 8);
    event(
      tag,
      'attempt=$attempt size=${payload.length}B '
      'ssidLen=${ssidLen}B passLen=${passLen}B '
      'security=$security checksum=$checksum sha256[:8]=$shortHash '
      '(SSID/password bytes redacted)',
    );
  }

  void clear() {
    _events.clear();
  }

  String render() {
    final sb = StringBuffer();
    sb.writeln('=== BroadLink Provisioner Diagnostics ===');
    sb.writeln('generated: ${DateTime.now().toIso8601String()}');
    sb.writeln();
    sb.writeln('Device:');
    final info = _deviceInfo ?? const {};
    if (info.isEmpty) {
      sb.writeln('  (unknown — platform plugin not reachable)');
    } else {
      for (final entry in info.entries) {
        sb.writeln('  ${entry.key}: ${entry.value}');
      }
    }
    sb.writeln();
    sb.writeln('Events (${_events.length}):');
    if (_events.isEmpty) {
      sb.writeln('  (none)');
    }
    for (final e in _events) {
      sb.writeln('  ${_fmt(e.timestamp)} '
          '[${e.level.name.padRight(5)}] ${e.tag}: ${e.message}');
    }
    return sb.toString();
  }

  static String _fmt(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    String three(int n) => n.toString().padLeft(3, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.${three(t.millisecond)}';
  }
}

enum DiagLevel { info, warn, error }

class DiagEvent {
  const DiagEvent(this.timestamp, this.level, this.tag, this.message);
  final DateTime timestamp;
  final DiagLevel level;
  final String tag;
  final String message;
}
