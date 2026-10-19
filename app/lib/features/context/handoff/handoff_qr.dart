import 'package:material_ui/material_ui.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../design/motion.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets/a11y.dart';
import '../state/format.dart';
import 'handoff_codec.dart';

/// Shows [payload] as a QR code for a phone nearby.
///
/// Dark modules on white with a quiet zone, whatever the theme: scanners
/// expect that contrast, and an inverted code fails on many of them.
Future<void> showHandoffQr(BuildContext context, String payload) => showModalBottomSheet<void>(
      context: context,
      sheetAnimationStyle: motionStyleOf(context),
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheet) {
        final t = SherpaTokens.of(sheet);
        final theme = Theme.of(sheet);
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(t.space.xl, 0, t.space.xl, t.space.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Heading(level: 2, child: Text('Scan to continue', style: theme.textTheme.titleLarge)),
              SizedBox(height: t.space.xs),
              Text(
                'On the other phone, open Sherpa, then Import handoff › Scan a QR code. '
                'Anyone who can see this code can read the handoff.',
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              SizedBox(height: t.space.lg),
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(t.radius.md),
                      ),
                      child: Padding(
                        padding: EdgeInsets.all(t.space.lg),
                        child: QrImageView(
                          data: payload,
                          errorCorrectionLevel: QrErrorCorrectLevel.L,
                          backgroundColor: Colors.white,
                          semanticsLabel: 'QR code with the handoff, ${formatBytes(HandoffCodec.qrBytes(payload))}',
                          errorStateBuilder: (context, _) => const Center(
                            child: Text(
                              'This handoff is too large for a QR code. Share the file instead.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.black),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(height: t.space.md),
              Text(
                'Turn your screen brightness up if the other phone has trouble reading it.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        );
      },
    );

/// Full-screen camera that returns the first Sherpa handoff code it sees
/// (other QR codes are ignored, so a stray code nearby can't be imported).
class HandoffScanPage extends StatefulWidget {
  const HandoffScanPage({super.key});

  static Future<String?> open(BuildContext context) =>
      Navigator.of(context).push<String>(MotionPageRoute(builder: (_) => const HandoffScanPage()));

  @override
  State<HandoffScanPage> createState() => _HandoffScanPageState();
}

class _HandoffScanPageState extends State<HandoffScanPage> {
  final MobileScannerController _controller = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _done = false;
  bool _sawOther = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final b in capture.barcodes) {
      final raw = b.rawValue;
      if (raw == null) continue;
      if (raw.startsWith(HandoffCodec.qrPrefix)) {
        _done = true;
        Navigator.of(context).pop(raw);
        return;
      }
    }
    if (!_sawOther) setState(() => _sawOther = true);
  }

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Heading(level: 1, child: const Text('Scan a handoff code')),
        actions: [
          IconButton(
            tooltip: 'Flashlight',
            icon: const Icon(Icons.flashlight_on_outlined),
            onPressed: _controller.toggleTorch,
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Semantics(
              label: 'Camera view',
              child: MobileScanner(
                controller: _controller,
                onDetect: _onDetect,
                errorBuilder: (context, error) => _ScanError(error: error),
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.all(t.space.lg),
            child: Semantics(
              liveRegion: true,
              child: Text(
                _sawOther
                    ? 'That code is not a Sherpa handoff. Point the camera at the code shown by "Show QR code".'
                    : 'Point the camera at the code on the other phone. Nothing is imported until you review it.',
                style: theme.textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ScanError extends StatelessWidget {
  const _ScanError({required this.error});

  final MobileScannerException error;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final denied = error.errorCode == MobileScannerErrorCode.permissionDenied;
    return ColoredBox(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Center(
        child: Padding(
          padding: EdgeInsets.all(t.space.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ExcludeSemantics(child: Icon(denied ? Icons.no_photography_outlined : Icons.error_outline_rounded, size: 40)),
              SizedBox(height: t.space.md),
              Text(
                denied
                    ? 'Sherpa is not allowed to use the camera. Allow it in your system settings, or go back and '
                        'import the file or paste the text instead.'
                    : "The camera couldn't start. Go back and import the file or paste the text instead.",
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
