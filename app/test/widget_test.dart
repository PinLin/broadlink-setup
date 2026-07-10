import 'package:broadlink_provisioner/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('App boots into intro screen', (tester) async {
    await tester.pumpWidget(const ProvisionerApp());
    await tester.pump();

    expect(
      find.text('Set up a BroadLink RM mini 3 without a BroadLink account.'),
      findsOneWidget,
    );
    expect(find.text('Next'), findsOneWidget);
  });

  testWidgets('Preview constructor renders pickHomeWifi without crashing',
      (tester) async {
    // Bypasses the real _start() flow (needs platform-channel Wi-Fi
    // scanning/joining, unavailable on the test host) by dropping straight
    // into pickHomeWifi via the @visibleForTesting preview constructor.
    await tester.pumpWidget(const MaterialApp(
      home: SetupScreen.preview(debugInitialStep: SetupStep.pickHomeWifi),
    ));
    await tester.pump();

    expect(find.byType(SetupScreen), findsOneWidget);
  });
}
