import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// Loads the real Flutter SDK fonts (Roboto + MaterialIcons) before running
/// any test in this directory, so golden-file comparisons render actual
/// glyphs instead of the default Ahem placeholder boxes.
///
/// Mirrors the kasa-setup sibling project's test config so both apps'
/// goldens are produced under the same rendering conditions.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  await _loadFlutterSdkFonts();
  await testMain();
}

Future<void> _loadFlutterSdkFonts() async {
  final flutterRoot = _resolveFlutterRoot();
  if (flutterRoot == null) return;

  final fontDir = '$flutterRoot/bin/cache/artifacts/material_fonts';
  final candidates = <String, List<String>>{
    'Roboto': [
      '$fontDir/Roboto-Regular.ttf',
      '$fontDir/Roboto-Medium.ttf',
      '$fontDir/Roboto-Light.ttf',
      '$fontDir/Roboto-Bold.ttf',
    ],
    'MaterialIcons': ['$fontDir/MaterialIcons-Regular.otf'],
  };

  for (final entry in candidates.entries) {
    final loader = FontLoader(entry.key);
    var addedAny = false;
    for (final path in entry.value) {
      final file = File(path);
      if (!file.existsSync()) continue;
      final bytes = file.readAsBytesSync();
      loader.addFont(Future.value(ByteData.sublistView(bytes)));
      addedAny = true;
    }
    if (addedAny) {
      await loader.load();
    }
  }
}

String? _resolveFlutterRoot() {
  final envRoot = Platform.environment['FLUTTER_ROOT'];
  if (envRoot != null && Directory(envRoot).existsSync()) {
    return envRoot;
  }
  final home = Platform.environment['HOME'] ?? '';
  final candidates = <String>[
    '/opt/homebrew/share/flutter',
    '/usr/local/share/flutter',
    if (home.isNotEmpty) '$home/development/flutter',
    if (home.isNotEmpty) '$home/flutter',
  ];
  for (final path in candidates) {
    if (Directory(path).existsSync()) return path;
  }
  return null;
}
