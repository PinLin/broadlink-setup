import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gbk_codec/gbk_codec.dart';
import 'package:broadlink_provisioner/protocol/lan_listener.dart';

Uint8List _readFixture(String name) =>
    File('test/fixtures/$name').readAsBytesSync();

void main() {
  group('buildHelloPacket', () {
    test('matches python-broadlink fixture for fixed timestamp/IP/port', () {
      // Fixture was built with Python: 2026-03-15 14:30 in UTC+8.
      // buildHelloPacket reads year/month/day/hour/minute components directly,
      // so a local DateTime with those components is enough.
      final packet = buildHelloPacket(
        localIp: '192.168.1.42',
        port: 5566,
        when: DateTime(2026, 3, 15, 14, 30),
        utcOffsetHours: 8,
      );

      expect(
        packet,
        equals(
          _readFixture('hello_192_168_1_42_port_5566_2026_03_15_14_30.bin'),
        ),
      );
    });
  });

  group('parseHelloResponse', () {
    test('extracts devtype, MAC, name, lock-status, and source IP', () {
      final raw = _readFixture('hello_response_rm3mini_2737_locked0.bin');

      final device = parseHelloResponse(raw, '192.168.1.42');

      expect(device.deviceType, 0x2737);
      expect(
        device.mac,
        equals([0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff]),
      );
      expect(device.name, 'MyRM3Mini');
      expect(device.isLocked, isFalse);
      expect(device.ip, '192.168.1.42');
    });

    test('rejects packet shorter than 0x80 bytes', () {
      final short = Uint8List(0x40);

      expect(
        () => parseHelloResponse(short, '1.2.3.4'),
        throwsArgumentError,
      );
    });

    test('macHex returns colon-separated lowercase hex', () {
      final raw = _readFixture('hello_response_rm3mini_2737_locked0.bin');
      final device = parseHelloResponse(raw, '10.0.0.1');

      expect(device.macHex, 'aa:bb:cc:dd:ee:ff');
    });

    test('decodes UTF-8 device name (factory Chinese default)', () {
      // Build a hello-response in-memory with the on-wire UTF-8 bytes that the
      // real RM3 mini ships with by default.
      final packet = Uint8List(0x80);
      packet[0x34] = 0xcd;
      packet[0x35] = 0x27; // devtype = 0x27cd (real on-hand device)
      const nameUtf8 = '智能遥控';
      final nameBytes = utf8.encode(nameUtf8);
      packet.setRange(0x40, 0x40 + nameBytes.length, nameBytes);

      final device = parseHelloResponse(packet, '192.168.1.92');

      expect(device.name, '智能遥控');
      expect(device.deviceType, 0x27cd);
    });

    test('falls back to GBK for legacy GB2312-named devices', () {
      // Some pre-2018 firmware shipped names in GB2312. We try UTF-8 first;
      // if it fails, GBK should kick in.
      final packet = Uint8List(0x80);
      const name = '智能遥控';
      final gbkBytes = gbk_bytes.encode(name);
      packet.setRange(0x40, 0x40 + gbkBytes.length, gbkBytes);

      final device = parseHelloResponse(packet, '192.168.1.92');

      expect(device.name, '智能遥控');
    });
  });
}
