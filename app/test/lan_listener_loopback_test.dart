// In-process UDP loopback integration test for LanListener.
//
// Mirrors the "fake device on loopback" pattern used by the kasa-setup
// sibling project's KLAP transport test (test/kasa/klap_test.dart there):
// bind a second UDP socket on 127.0.0.1 to play the role of the physical
// device, inject its address/port into the code under test, and assert on
// real bytes that cross a real (loopback) socket rather than mocking the
// network layer away.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:broadlink_provisioner/protocol/lan_listener.dart';

Uint8List _readFixture(String name) =>
    File('test/fixtures/$name').readAsBytesSync();

void main() {
  group('LanListener (against a loopback fake device)', () {
    test('sends a well-formed hello packet to the injected target address',
        () async {
      final fake = await _FakeBroadlinkDevice.start();
      addTearDown(fake.close);

      final listener = LanListener(
        discoveryPort: fake.port,
        targetAddress: '127.0.0.1',
        // Long enough that a single hello send/receive round trip and the
        // packet capture below can complete, short enough the test doesn't
        // hang if something regresses.
        broadcastInterval: const Duration(seconds: 5),
      );

      final sub = listener
          .listen(timeout: const Duration(milliseconds: 400), localIp: '10.20.30.40')
          .listen((_) {});
      addTearDown(sub.cancel);

      final received = await fake.nextPacket.timeout(const Duration(seconds: 2));

      // Structural checks derived from the already-tested buildHelloPacket
      // encoder (see lan_listener_test.dart's fixture-based test), not from
      // literals guessed for this test.
      final reference = buildHelloPacket(
        localIp: '0.0.0.0',
        port: 1,
        when: DateTime(2000, 1, 1),
        utcOffsetHours: 0,
      );
      expect(received.data.length, reference.length,
          reason: 'hello packet must be the fixed hello-packet size');

      // Magic "hello" opcode byte, cross-checked against a reference
      // encode rather than hard-coded.
      expect(received.data[0x26], reference[0x26]);

      // Reversed source-IP field (0x18..0x1b) must encode localIp.
      expect(
        received.data.sublist(0x18, 0x1c),
        equals([40, 30, 20, 10]),
      );

      // Source-port field (0x1c..0x1d, little-endian) must equal the actual
      // UDP source port the datagram arrived from - i.e. the listener really
      // bound and reported its own ephemeral port truthfully.
      final encodedPort = received.data[0x1c] | (received.data[0x1d] << 8);
      expect(encodedPort, received.sourcePort);

      // Checksum: seed 0xbeaf + sum of all bytes with the checksum field
      // itself zeroed, matching the algorithm read directly from
      // lib/protocol/lan_listener.dart's buildHelloPacket implementation.
      final withChecksumZeroed = Uint8List.fromList(received.data);
      withChecksumZeroed[0x20] = 0;
      withChecksumZeroed[0x21] = 0;
      var sum = 0xbeaf;
      for (final b in withChecksumZeroed) {
        sum = (sum + b) & 0xffff;
      }
      final encodedChecksum = received.data[0x20] | (received.data[0x21] << 8);
      expect(encodedChecksum, sum);
    });

    test('collects and parses a device that answers the hello', () async {
      final fake = await _FakeBroadlinkDevice.start();
      addTearDown(fake.close);
      fake.autoReplyWith(_readFixture('hello_response_rm3mini_2737_locked0.bin'));

      final listener = LanListener(
        discoveryPort: fake.port,
        targetAddress: '127.0.0.1',
        broadcastInterval: const Duration(seconds: 5),
      );

      final devices = await listener
          .listen(timeout: const Duration(milliseconds: 500), localIp: '10.20.30.40')
          .toList();

      expect(devices, hasLength(1));
      final device = devices.single;
      expect(device.deviceType, 0x2737);
      expect(device.macHex, 'aa:bb:cc:dd:ee:ff');
      expect(device.name, 'MyRM3Mini');
      expect(device.isLocked, isFalse);
      expect(device.ip, '127.0.0.1');
    });

    test('times out and completes with no devices when the fake device stays silent',
        () async {
      final fake = await _FakeBroadlinkDevice.start();
      addTearDown(fake.close);
      // Deliberately not calling autoReplyWith - the fake device never answers.

      final listener = LanListener(
        discoveryPort: fake.port,
        targetAddress: '127.0.0.1',
        // Longer than the listen timeout below, so only the very first hello
        // is sent; this proves the stream ends on its own deadline rather
        // than merely because the ticker stopped producing hellos.
        broadcastInterval: const Duration(seconds: 10),
      );

      final stopwatch = Stopwatch()..start();
      final devices = await listener
          .listen(timeout: const Duration(milliseconds: 300), localIp: '10.20.30.40')
          .toList()
          .timeout(
            const Duration(seconds: 3),
            onTimeout: () => throw TimeoutException(
              'listen() did not honor its timeout and complete on its own',
            ),
          );
      stopwatch.stop();

      expect(devices, isEmpty);
      // Should finish close to the requested timeout, not hang until the
      // outer safety timeout above.
      expect(stopwatch.elapsedMilliseconds, lessThan(2000));
    });
  });
}

// ---------------------------------------------------------------------------
// Test helpers

/// A datagram captured by the fake device, including which UDP source port
/// it actually arrived from (as reported by the OS, independent of whatever
/// port value is encoded inside the packet payload itself).
class _CapturedPacket {
  _CapturedPacket(this.data, this.sourcePort);
  final Uint8List data;
  final int sourcePort;
}

/// Minimal in-process fake Broadlink device. Binds a UDP socket on loopback,
/// records every packet it receives, and can optionally auto-reply with a
/// fixed response payload (e.g. a captured hello-response fixture) to
/// whichever address/port sent the packet.
class _FakeBroadlinkDevice {
  _FakeBroadlinkDevice(this._socket);

  final RawDatagramSocket _socket;
  final StreamController<_CapturedPacket> _packets =
      StreamController<_CapturedPacket>.broadcast();
  Uint8List? _autoReply;

  int get port => _socket.port;

  /// Completes with the next packet received by the fake device.
  Future<_CapturedPacket> get nextPacket => _packets.stream.first;

  void autoReplyWith(Uint8List payload) {
    _autoReply = payload;
  }

  static Future<_FakeBroadlinkDevice> start() async {
    final socket =
        await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final fake = _FakeBroadlinkDevice(socket);
    socket.listen(fake._handleEvent);
    return fake;
  }

  void _handleEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final datagram = _socket.receive();
    if (datagram == null) return;
    final data = Uint8List.fromList(datagram.data);
    _packets.add(_CapturedPacket(data, datagram.port));
    final reply = _autoReply;
    if (reply != null) {
      _socket.send(reply, datagram.address, datagram.port);
    }
  }

  Future<void> close() async {
    await _packets.close();
    _socket.close();
  }
}
