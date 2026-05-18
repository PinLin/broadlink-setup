import 'dart:typed_data';

import 'security_mode.dart';

const int _packetSize = 0x88;
const int _ssidStart = 0x44;
const int _passwordStart = 0x64;
const int _ssidLengthOffset = 0x84;
const int _passwordLengthOffset = 0x85;
const int _securityOffset = 0x86;
const int _checksumLowOffset = 0x20;
const int _checksumHighOffset = 0x21;
const int _checksumSeed = 0xbeaf;
const int _maxFieldLength = 32;

Uint8List buildApPacket({
  required Uint8List ssid,
  required Uint8List password,
  required SecurityMode security,
}) {
  if (ssid.length > _maxFieldLength) {
    throw ArgumentError.value(
      ssid.length,
      'ssid',
      'must be <= $_maxFieldLength bytes',
    );
  }
  if (password.length > _maxFieldLength) {
    throw ArgumentError.value(
      password.length,
      'password',
      'must be <= $_maxFieldLength bytes',
    );
  }

  final packet = Uint8List(_packetSize);
  packet[0x26] = 0x14;
  packet.setRange(_ssidStart, _ssidStart + ssid.length, ssid);
  packet.setRange(_passwordStart, _passwordStart + password.length, password);
  packet[_ssidLengthOffset] = ssid.length;
  packet[_passwordLengthOffset] = password.length;
  packet[_securityOffset] = security.code;

  var checksum = _checksumSeed;
  for (final b in packet) {
    checksum = (checksum + b) & 0xffff;
  }
  packet[_checksumLowOffset] = checksum & 0xff;
  packet[_checksumHighOffset] = (checksum >> 8) & 0xff;
  return packet;
}
