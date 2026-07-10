// Regenerates every binary fixture in this directory from first principles.
//
// Run from the app/ directory with:
//   dart run test/fixtures/generate_fixtures.dart
//
// This exists to prove (and let anyone re-derive) the exact byte layout
// behind each fixture - AP-provisioning packets built via buildApPacket()
// with different SSID/password encodings, a hello discovery packet built
// via buildHelloPacket(), and a hand-crafted hello RESPONSE packet (no
// builder exists for responses in lib/, only a parser, so this reconstructs
// it field-by-field from what parseHelloResponse() reads). Output must be
// byte-for-byte identical to the checked-in fixtures - verify with:
//   dart run test/fixtures/generate_fixtures.dart --out /tmp/regen
//   cmp test/fixtures/<name> /tmp/regen/<name>   (for each of the 5 files)
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:broadlink_provisioner/protocol/ap_packet.dart';
import 'package:broadlink_provisioner/protocol/encoding_strategy.dart';
import 'package:broadlink_provisioner/protocol/lan_listener.dart';
import 'package:broadlink_provisioner/protocol/security_mode.dart';

void main(List<String> args) {
  // Optional `--out <dir>` so the script can be pointed at a scratch
  // directory for a non-destructive round-trip check against the
  // checked-in fixtures, instead of overwriting them in place.
  var outDir = 'test/fixtures';
  final outFlagIndex = args.indexOf('--out');
  if (outFlagIndex != -1 && outFlagIndex + 1 < args.length) {
    outDir = args[outFlagIndex + 1];
  }
  Directory(outDir).createSync(recursive: true);

  if (!Directory('test/fixtures').existsSync()) {
    stderr.writeln(
        'Run this from the app/ directory (test/fixtures not found).');
    exit(1);
  }

  // ascii_wpa2.bin: plain ASCII SSID/password, WPA2.
  _write(
    outDir,
    'ascii_wpa2.bin',
    buildApPacket(
      ssid: Uint8List.fromList('MyHome'.codeUnits),
      password: Uint8List.fromList('passwd1234'.codeUnits),
      security: SecurityMode.wpa2,
    ),
  );

  // chinese_utf8_wpa2.bin: Chinese SSID/password encoded as UTF-8, WPA2.
  _write(
    outDir,
    'chinese_utf8_wpa2.bin',
    buildApPacket(
      ssid: Uint8List.fromList(utf8.encode('家里WiFi')),
      password: Uint8List.fromList(utf8.encode('密码1234')),
      security: SecurityMode.wpa2,
    ),
  );

  // chinese_gb2312_wpa2.bin: same Chinese text, but GBK-encoded (legacy
  // firmware fallback path), WPA2. encodeAttempt(text, 1) is the app's own
  // "attempt #1 = GBK" encoding strategy used by the manual-SSID form.
  _write(
    outDir,
    'chinese_gb2312_wpa2.bin',
    buildApPacket(
      ssid: Uint8List.fromList(encodeAttempt('家里WiFi', 1)),
      password: Uint8List.fromList(encodeAttempt('密码1234', 1)),
      security: SecurityMode.wpa2,
    ),
  );

  // hello_192_168_1_42_port_5566_2026_03_15_14_30.bin: UDP discovery
  // broadcast packet. Filename encodes the exact inputs used to build it.
  _write(
    outDir,
    'hello_192_168_1_42_port_5566_2026_03_15_14_30.bin',
    buildHelloPacket(
      localIp: '192.168.1.42',
      port: 5566,
      when: DateTime(2026, 3, 15, 14, 30),
      utcOffsetHours: 8,
    ),
  );

  // hello_response_rm3mini_2737_locked0.bin: a device's reply to the hello
  // broadcast above. There is no builder for this direction in lib/ (only
  // parseHelloResponse() reads it), so it is reconstructed field-by-field
  // from what that parser extracts:
  //   - devtype  0x2737           -> bytes 0x34-0x35, little-endian
  //   - MAC      aa:bb:cc:dd:ee:ff -> bytes 0x3a-0x3f, stored REVERSED
  //   - name     "MyRM3Mini"      -> bytes 0x40.., null-terminated (rest
  //                                   of the 128-byte packet is zero-padded)
  //   - locked   false            -> byte 0x7f == 0x00
  // All other bytes are zero (confirmed against the checked-in fixture via
  // `hexdump -C` - there is no header/checksum outside these fields).
  final response = Uint8List(0x80);
  response[0x34] = 0x37;
  response[0x35] = 0x27;
  const mac = [0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff];
  for (var i = 0; i < mac.length; i++) {
    response[0x3f - i] = mac[i];
  }
  final nameBytes = utf8.encode('MyRM3Mini');
  response.setRange(0x40, 0x40 + nameBytes.length, nameBytes);
  response[0x7f] = 0x00; // locked = false
  _write(outDir, 'hello_response_rm3mini_2737_locked0.bin', response);

  stdout.writeln('Regenerated 5 fixtures in $outDir/.');
}

void _write(String outDir, String name, Uint8List bytes) {
  File('$outDir/$name').writeAsBytesSync(bytes);
  stdout.writeln('  wrote $name (${bytes.length} bytes)');
}
