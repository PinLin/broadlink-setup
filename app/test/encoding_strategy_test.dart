import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:broadlink_provisioner/protocol/encoding_strategy.dart';

void main() {
  group('encodeAttempt', () {
    test('attempt 0 returns UTF-8 bytes for ASCII', () {
      final out = encodeAttempt('MyHome', 0);
      expect(out, equals(utf8.encode('MyHome')));
    });

    test('attempt 0 returns UTF-8 bytes for Chinese', () {
      final out = encodeAttempt('家里WiFi', 0);
      expect(out, equals(utf8.encode('家里WiFi')));
    });

    test('attempt 1 returns GBK bytes for Chinese', () {
      final out = encodeAttempt('家里WiFi', 1);
      expect(out, equals([0xbc, 0xd2, 0xc0, 0xef, 0x57, 0x69, 0x46, 0x69]));
    });

    test('attempt 1 leaves ASCII unchanged', () {
      final out = encodeAttempt('MyHome', 1);
      expect(out, equals('MyHome'.codeUnits));
    });

    test('attempt out of range throws', () {
      expect(() => encodeAttempt('x', 2), throwsRangeError);
      expect(() => encodeAttempt('x', -1), throwsRangeError);
    });

    test('attemptCount reports total fallbacks', () {
      expect(attemptCount, 2);
    });
  });

  group('byteLengthForDisplay', () {
    test('reports UTF-8 and GBK byte lengths', () {
      final lengths = byteLengthForDisplay('家里WiFi');
      expect(lengths.utf8, 10); // 3 + 3 + 4
      expect(lengths.gbk, 8); //  2 + 2 + 4
    });

    test('GBK length is null when string is not GBK-encodable', () {
      final lengths = byteLengthForDisplay('🚀');
      expect(lengths.utf8, 4);
      expect(lengths.gbk, isNull);
    });

    test('ASCII has equal lengths', () {
      final lengths = byteLengthForDisplay('hello');
      expect(lengths.utf8, 5);
      expect(lengths.gbk, 5);
    });
  });
}
