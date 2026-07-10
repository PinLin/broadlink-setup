import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'diagnostics.dart';

/// UI entry point for viewing the in-memory diagnostic log.
///
/// Ported back from the kasa-setup sister app to keep the two apps aligned:
/// `Diagnostics.render()` previously had no caller here. This is a minimal,
/// single-purpose page pushed from the setup flow's AppBar: render the log
/// as monospace text, let the user copy it to the clipboard (for pasting
/// into a bug report), and let them clear it. Kept intentionally plain — a
/// full-screen [Scaffold] with a scrollable, selectable text body — to
/// match the rest of the app's un-fancy, functional Material 3 style.
class DiagnosticsView extends StatefulWidget {
  const DiagnosticsView({super.key});

  @override
  State<DiagnosticsView> createState() => _DiagnosticsViewState();
}

class _DiagnosticsViewState extends State<DiagnosticsView> {
  @override
  Widget build(BuildContext context) {
    final report = Diagnostics.instance.render();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Diagnostics'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy_outlined),
            tooltip: 'Copy to clipboard',
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: report));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Diagnostics copied to clipboard')),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Clear log',
            onPressed: () => setState(() => Diagnostics.instance.clear()),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: SingleChildScrollView(
            child: SelectableText(
              report,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ),
      ),
    );
  }
}
