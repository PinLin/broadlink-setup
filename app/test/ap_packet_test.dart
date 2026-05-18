import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:broadlink_provisioner/protocol/ap_packet.dart';
import 'package:broadlink_provisioner/protocol/encoding_strategy.dart';
import 'package:broadlink_provisioner/protocol/security_mode.dart';

Uint8List _readFixture(String name) =>
    File('test/fixtures/$name').readAsBytesSync();

void main() {
  group('buildApPacket', () {
    test('ASCII SSID + password + WPA2 matches python-broadlink fixture', () {
      final ssid = Uint8List.fromList('MyHome'.codeUnits);
      final password = Uint8List.fromList('passwd1234'.codeUnits);

      final packet = buildApPacket(
        ssid: ssid,
        password: password,
        security: SecurityMode.wpa2,
      );

      expect(packet, equals(_readFixture('ascii_wpa2.bin')));
    });

    test('Chinese SSID + password UTF-8 + WPA2 matches fixture', () {
      final ssid = Uint8List.fromList(utf8.encode('家里WiFi'));
      final password = Uint8List.fromList(utf8.encode('密码1234'));

      final packet = buildApPacket(
        ssid: ssid,
        password: password,
        security: SecurityMode.wpa2,
      );

      expect(packet, equals(_readFixture('chinese_utf8_wpa2.bin')));
    });

    test('Chinese SSID + password GBK fallback matches fixture', () {
      final ssid = Uint8List.fromList(encodeAttempt('家里WiFi', 1));
      final password = Uint8List.fromList(encodeAttempt('密码1234', 1));

      final packet = buildApPacket(
        ssid: ssid,
        password: password,
        security: SecurityMode.wpa2,
      );

      expect(packet, equals(_readFixture('chinese_gb2312_wpa2.bin')));
    });

    test('rejects SSID > 32 bytes', () {
      final ssid = Uint8List(33);
      final password = Uint8List.fromList('p'.codeUnits);

      expect(
        () => buildApPacket(
          ssid: ssid,
          password: password,
          security: SecurityMode.wpa2,
        ),
        throwsArgumentError,
      );
    });

    test('rejects password > 32 bytes', () {
      final ssid = Uint8List.fromList('s'.codeUnits);
      final password = Uint8List(33);

      expect(
        () => buildApPacket(
          ssid: ssid,
          password: password,
          security: SecurityMode.wpa2,
        ),
        throwsArgumentError,
      );
    });

    test('zero-length SSID and password produce all-zero credential fields',
        () {
      final packet = buildApPacket(
        ssid: Uint8List(0),
        password: Uint8List(0),
        security: SecurityMode.none,
      );

      expect(packet.length, 0x88);
      expect(packet[0x84], 0);
      expect(packet[0x85], 0);
      expect(packet[0x86], 0);
      expect(packet.sublist(0x44, 0x44 + 32), everyElement(0));
      expect(packet.sublist(0x64, 0x64 + 32), everyElement(0));
    });
  });
}
