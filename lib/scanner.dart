import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'theme.dart';

/// Android only: scans the QR code shown on the other device.
/// Pops with the text of the code, or null if the person goes back.
class ScannerPage extends StatefulWidget {
  const ScannerPage({super.key});

  @override
  State<ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<ScannerPage>
    with SingleTickerProviderStateMixin {
  final MobileScannerController _scanner = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  late final AnimationController _line =
      AnimationController(vsync: this, duration: const Duration(seconds: 2))
        ..repeat(reverse: true);
  bool _done = false;
  bool _torch = false;

  @override
  void dispose() {
    _line.dispose();
    _scanner.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final b in capture.barcodes) {
      final v = b.rawValue;
      if (v != null && v.startsWith('LMW|')) {
        _done = true;
        Navigator.of(context).pop(v);
        return;
      }
    }
  }

  Widget _error(BuildContext context, MobileScannerException e) {
    final denied = e.errorCode == MobileScannerErrorCode.permissionDenied;
    final detail = e.errorDetails?.message ?? '';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Glass(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.no_photography_outlined, size: 40),
            const SizedBox(height: 12),
            Text(
              denied ? 'Camera access is off' : 'The camera could not start',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              denied
                  ? 'Allow the camera for Link my Windows in your phone '
                      'settings, then try again.'
                  : 'Close other apps that use the camera and try again. '
                      'You can also link by typing the IP address and code.'
                      '${detail.isEmpty ? '' : '\n\n($detail)'}',
              textAlign: TextAlign.center,
              style: const TextStyle(color: kMuted, height: 1.4),
            ),
            const SizedBox(height: 18),
            GlassButton(
              label: 'Try again',
              icon: Icons.refresh,
              primary: true,
              onTap: () => _scanner.start(),
            ),
            const SizedBox(height: 10),
            GlassButton(
              label: 'Type the code instead',
              onTap: () => Navigator.of(context).pop(),
            ),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const box = 250.0;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(fit: StackFit.expand, children: [
        MobileScanner(
          controller: _scanner,
          onDetect: _onDetect,
          errorBuilder: (context, error, child) => _error(context, error),
        ),
        // Viewfinder
        IgnorePointer(
          child: Center(
            child: SizedBox(
              width: box,
              height: box,
              child: Stack(children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(34),
                    border: Border.all(color: wh(0.9), width: 3),
                    boxShadow: [
                      BoxShadow(color: kBlue.withAlpha(90), blurRadius: 30),
                    ],
                  ),
                  child: const SizedBox.expand(),
                ),
                AnimatedBuilder(
                  animation: _line,
                  builder: (context, _) => Positioned(
                    left: 22,
                    right: 22,
                    top: 20 + (box - 44) * Curves.easeInOut.transform(_line.value),
                    child: Container(
                      height: 3,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(2),
                        gradient: LinearGradient(
                            colors: [kTeal.withAlpha(0), kTeal, kTeal.withAlpha(0)]),
                      ),
                    ),
                  ),
                ),
              ]),
            ),
          ),
        ),
        // Top bar
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              Pressable(
                onTap: () => Navigator.of(context).pop(),
                child: Glass(
                  radius: 24,
                  blur: 18,
                  padding: const EdgeInsets.all(12),
                  child: const Icon(Icons.arrow_back_ios_new, size: 20),
                ),
              ),
              const Spacer(),
              Pressable(
                onTap: () {
                  _scanner.toggleTorch();
                  setState(() => _torch = !_torch);
                },
                child: Glass(
                  radius: 24,
                  blur: 18,
                  padding: const EdgeInsets.all(12),
                  child: Icon(_torch ? Icons.flash_on : Icons.flash_off,
                      size: 20),
                ),
              ),
            ]),
          ),
        ),
        Positioned(
          left: 24,
          right: 24,
          bottom: 48,
          child: SafeArea(
            child: Glass(
              radius: 28,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              child: const Text(
                'Point your camera at the code shown in Link my Windows on '
                'your PC',
                textAlign: TextAlign.center,
                style: TextStyle(height: 1.4),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}
