import 'dart:async';
import 'dart:typed_data';

import 'package:broadlink_provisioner/main.dart';
import 'package:broadlink_provisioner/platform/wifi_binder.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
      'password dialog → Provision does not crash with '
      "InheritedElement _dependents.isEmpty assertion", (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: SetupScreen.preview(
        debugInitialStep: SetupStep.pickHomeWifi,
        debugHomeNetworks: const [
          WifiNetwork(ssid: 'HomeNet', signalDbm: -50, secured: true),
        ],
        // Never completes → pins the provision coroutine at its first await
        // (right after the sendingCredentials tree swap) so the test never
        // reaches real RawDatagramSocket/platform-channel code.
        debugSendPayloadOverride: (Uint8List _) => Completer<void>().future,
      ),
    ));
    await tester.pumpAndSettle();

    // Open the password dialog for the secured network (autofocus TextField).
    await tester.tap(find.text('HomeNet'));
    await tester.pumpAndSettle();
    expect(find.text('Wi-Fi Password'), findsOneWidget);

    // Type a password and submit via the Provision button. This pops the
    // dialog and then synchronously setState()s the body from pickHomeWifi
    // to the sendingCredentials busy view — the tree swap under suspicion.
    await tester.enterText(find.byType(TextField), 'hunter2');
    await tester.tap(find.widgetWithText(FilledButton, 'Provision'));

    // Pump frames to let the dialog route tear down and the body rebuild.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    // The body must have swapped from the picker to the sendingCredentials
    // busy view — proving we actually crossed the dialog-pop → setState →
    // _provision boundary that used to crash (the provision coroutine is now
    // parked on debugSendPayloadOverride, which never completes).
    expect(
      find.text('Sending Wi-Fi credentials to the RM mini 3…'),
      findsOneWidget,
    );

    // Any framework assertion during those pumps is captured here. Before
    // the fix this held the InheritedElement `_dependents.isEmpty` assertion.
    expect(tester.takeException(), isNull);
  });
}
