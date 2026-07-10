import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:gbk_codec/gbk_codec.dart';

const int _helloPacketSize = 0x30;
const int _helloChecksumSeed = 0xbeaf;
const int _helloResponseMinSize = 0x80;

class DiscoveredDevice {
  const DiscoveredDevice({
    required this.ip,
    required this.mac,
    required this.deviceType,
    required this.name,
    required this.isLocked,
  });

  final String ip;
  final List<int> mac;
  final int deviceType;
  final String name;
  final bool isLocked;

  String get macHex =>
      mac.map((b) => b.toRadixString(16).padLeft(2, '0')).join(':');
}

Uint8List buildHelloPacket({
  required String localIp,
  required int port,
  required DateTime when,
  required int utcOffsetHours,
}) {
  if (port < 0 || port > 0xffff) {
    throw ArgumentError.value(port, 'port', 'must fit in uint16');
  }
  final ipBytes = _parseIPv4(localIp);

  final packet = Uint8List(_helloPacketSize);
  final view = ByteData.view(packet.buffer);

  // Datetime block at offset 0x08..0x13.
  view.setInt32(0x08, utcOffsetHours, Endian.little);
  view.setUint16(0x0c, when.year, Endian.little);
  packet[0x0e] = when.minute;
  packet[0x0f] = when.hour;
  packet[0x10] = when.year % 100;
  packet[0x11] = _isoWeekday(when);
  packet[0x12] = when.day;
  packet[0x13] = when.month;

  // Reversed IP at 0x18..0x1b.
  packet[0x18] = ipBytes[3];
  packet[0x19] = ipBytes[2];
  packet[0x1a] = ipBytes[1];
  packet[0x1b] = ipBytes[0];

  view.setUint16(0x1c, port, Endian.little);
  packet[0x26] = 0x06;

  var checksum = _helloChecksumSeed;
  for (final b in packet) {
    checksum = (checksum + b) & 0xffff;
  }
  view.setUint16(0x20, checksum, Endian.little);
  return packet;
}

DiscoveredDevice parseHelloResponse(Uint8List packet, String sourceIp) {
  if (packet.length < _helloResponseMinSize) {
    throw ArgumentError.value(
      packet.length,
      'packet',
      'response shorter than $_helloResponseMinSize bytes',
    );
  }
  final deviceType = packet[0x34] | (packet[0x35] << 8);
  final mac = List<int>.unmodifiable([
    packet[0x3f],
    packet[0x3e],
    packet[0x3d],
    packet[0x3c],
    packet[0x3b],
    packet[0x3a],
  ]);
  final nameBytes = packet.sublist(0x40);
  final nullIndex = nameBytes.indexOf(0);
  final nameSlice =
      nullIndex >= 0 ? nameBytes.sublist(0, nullIndex) : nameBytes;
  final name = _decodeDeviceName(nameSlice);
  final isLocked = packet[0x7f] != 0;

  return DiscoveredDevice(
    ip: sourceIp,
    mac: mac,
    deviceType: deviceType,
    name: name,
    isLocked: isLocked,
  );
}

List<int> _parseIPv4(String ip) {
  final parts = ip.split('.');
  if (parts.length != 4) {
    throw ArgumentError.value(ip, 'ip', 'must be IPv4 dotted-quad');
  }
  return parts.map((p) {
    final n = int.parse(p);
    if (n < 0 || n > 255) {
      throw ArgumentError.value(ip, 'ip', 'IPv4 octet out of range');
    }
    return n;
  }).toList();
}

int _isoWeekday(DateTime when) {
  // Dart: Monday = 1 ... Sunday = 7. Matches Python isoweekday.
  return when.weekday;
}

/// Devices factory-shipped with Chinese default names (e.g. `智能遥控`) send
/// the name as UTF-8. python-broadlink uses `bytes.decode()` (UTF-8 default).
/// Some older firmware revisions may have used GB2312; we try GBK as a fallback
/// before degrading to raw bytes so the user at least sees something.
String _decodeDeviceName(List<int> bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    try {
      return gbk_bytes.decode(bytes);
    } catch (_) {
      return String.fromCharCodes(bytes);
    }
  }
}

class LanListener {
  LanListener({
    Duration broadcastInterval = const Duration(seconds: 5),
    int discoveryPort = 80,
    int utcOffsetHours = 0,
    String targetAddress = '255.255.255.255',
  })  : _broadcastInterval = broadcastInterval,
        _discoveryPort = discoveryPort,
        _utcOffsetHours = utcOffsetHours,
        _targetAddress = targetAddress;

  final Duration _broadcastInterval;
  final int _discoveryPort;
  final int _utcOffsetHours;

  /// Destination address for hello packets. Defaults to the LAN broadcast
  /// address; overridable so tests can point discovery at a loopback fake
  /// device instead of a real broadcast domain.
  final String _targetAddress;

  Stream<DiscoveredDevice> listen({
    required Duration timeout,
    required String localIp,
  }) async* {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    socket.broadcastEnabled = true;
    final boundPort = socket.port;
    final seen = <String>{};
    final deadline = DateTime.now().add(timeout);

    Future<void> sendHello() async {
      final packet = buildHelloPacket(
        localIp: localIp,
        port: boundPort,
        when: DateTime.now(),
        utcOffsetHours: _utcOffsetHours,
      );
      socket.send(
        packet,
        InternetAddress(_targetAddress),
        _discoveryPort,
      );
    }

    await sendHello();
    final ticker = Stream<void>.periodic(_broadcastInterval).listen(
      (_) => sendHello(),
    );
    // RawDatagramSocket's event stream is edge-triggered: with no incoming
    // traffic at all it only ever fires one initial `write` event and then
    // goes silent, so a deadline check that only runs inside the `await for`
    // body would never re-evaluate and the stream would hang forever when no
    // device responds. Force the stream to end at the deadline by closing
    // the socket, which reliably emits a terminal `closed` event.
    final deadlineTimer = Timer(timeout, socket.close);

    try {
      await for (final event in socket) {
        if (DateTime.now().isAfter(deadline)) break;
        if (event != RawSocketEvent.read) continue;
        final datagram = socket.receive();
        if (datagram == null) continue;
        final raw = Uint8List.fromList(datagram.data);
        if (raw.length < _helloResponseMinSize) continue;
        final device = parseHelloResponse(raw, datagram.address.address);
        final key = '${device.ip}|${device.macHex}|${device.deviceType}';
        if (!seen.add(key)) continue;
        yield device;
      }
    } finally {
      deadlineTimer.cancel();
      await ticker.cancel();
      socket.close();
    }
  }
}
