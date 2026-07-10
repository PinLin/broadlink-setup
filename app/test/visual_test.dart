// Golden (visual regression) tests: one screenshot per SetupStep enum value,
// pumped via the @visibleForTesting SetupScreen.preview constructor so no
// real UDP scanning / Wi-Fi binding ever runs. Mirrors the kasa-setup
// sibling project's visual_test.dart structure (fixed surface size, real
// fonts via flutter_test_config.dart, matchesGoldenFile per step).
//
// Regenerate goldens after an intentional UI change with:
//   flutter test --update-goldens test/visual_test.dart
import 'package:broadlink_provisioner/main.dart';
import 'package:broadlink_provisioner/platform/wifi_binder.dart';
import 'package:broadlink_provisioner/protocol/lan_listener.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pumpAt(WidgetTester tester, Widget widget,
    {bool settle = true}) async {
  await tester.binding.setSurfaceSize(const Size(411, 914));
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
    home: widget,
  ));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    // _busyView / spinning _statusCard contain a CircularProgressIndicator,
    // which animates forever - pumpAndSettle would time out on those.
    await tester.pump();
  }
}

DiscoveredDevice _fakeDevice() => const DiscoveredDevice(
      ip: '192.168.1.42',
      mac: [0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff],
      deviceType: 0x2737,
      name: 'RM mini 3',
      isLocked: false,
    );

const _fakeHomeNetworks = [
  WifiNetwork(ssid: 'MyHome', signalDbm: -45, secured: true),
  WifiNetwork(ssid: 'Neighbor 5G', signalDbm: -70, secured: true),
];

void main() {
  testWidgets('01 intro', (tester) async {
    await _pumpAt(
        tester, const SetupScreen.preview(debugInitialStep: SetupStep.intro));
    await expectLater(
        find.byType(MaterialApp), matchesGoldenFile('goldens/01_intro.png'));
  });

  testWidgets('02 await device', (tester) async {
    await _pumpAt(tester,
        const SetupScreen.preview(debugInitialStep: SetupStep.awaitDevice));
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/02_await_device.png'));
  });

  testWidgets('03 pick home wifi', (tester) async {
    await _pumpAt(
        tester,
        const SetupScreen.preview(
          debugInitialStep: SetupStep.pickHomeWifi,
          debugHomeNetworks: _fakeHomeNetworks,
        ));
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/03_pick_home_wifi.png'));
  });

  testWidgets('04 sending credentials', (tester) async {
    await _pumpAt(
        tester,
        const SetupScreen.preview(
            debugInitialStep: SetupStep.sendingCredentials),
        settle: false);
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/04_sending_credentials.png'));
  });

  testWidgets('05 waiting for join', (tester) async {
    await _pumpAt(
        tester,
        const SetupScreen.preview(debugInitialStep: SetupStep.waitingForJoin),
        settle: false);
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/05_waiting_for_join.png'));
  });

  testWidgets('06 discovering on home wifi', (tester) async {
    await _pumpAt(
        tester,
        const SetupScreen.preview(
            debugInitialStep: SetupStep.discoveringOnHomeWifi),
        settle: false);
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/06_discovering_on_home_wifi.png'));
  });

  testWidgets('07 done', (tester) async {
    await _pumpAt(
        tester,
        SetupScreen.preview(
          debugInitialStep: SetupStep.done,
          debugDiscovered: _fakeDevice(),
        ));
    await expectLater(
        find.byType(MaterialApp), matchesGoldenFile('goldens/07_done.png'));
  });

  testWidgets('08 error', (tester) async {
    await _pumpAt(
        tester,
        const SetupScreen.preview(
          debugInitialStep: SetupStep.error,
          debugError: 'Could not reach the device on your home Wi-Fi.',
        ));
    await expectLater(
        find.byType(MaterialApp), matchesGoldenFile('goldens/08_error.png'));
  });
}
