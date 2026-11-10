import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../link.dart';
import '../theme.dart';

/// Full-screen camera that returns the first GameNight QR it sees.
/// Frames are decoded on the device; nothing is uploaded.
class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key});

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> {
  // The QR is small and far away on a TV across the room. Android's default
  // 640x480 frames leave too few pixels per module, so ask for full HD,
  // check frames often and let Android zoom in on a code it half sees.
  final _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    cameraResolution: const Size(1920, 1080),
    detectionTimeoutMs: 150,
    autoZoom: true,
  );
  String? _hint;
  bool _done = false;
  double _zoom = 0;
  double _pinchStart = 0;

  Future<void> _setZoom(double value) async {
    final zoom = value.clamp(0.0, 1.0);
    setState(() => _zoom = zoom);
    try {
      await _controller.setZoomScale(zoom);
    } catch (_) {/* Not started yet or no zoom on this camera. */}
  }

  Future<void> _focus(TapUpDetails details, Size size) async {
    try {
      await _controller.setFocusPoint(Offset(
          details.localPosition.dx / size.width,
          details.localPosition.dy / size.height));
    } catch (_) {/* Not every camera can focus on a point. */}
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final code in capture.barcodes) {
      final text = code.rawValue;
      if (text == null) continue;
      try {
        parseHostLink(text);
      } on LinkError catch (e) {
        setState(() => _hint = e.message);
        continue;
      }
      _done = true;
      Navigator.of(context).pop(text);
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: const Text('Scan lobby QR'), backgroundColor: GnColors.card),
      body: LayoutBuilder(
        builder: (context, box) => Stack(children: [
          // Pinch to zoom, tap to focus, like the camera app.
          GestureDetector(
            onScaleStart: (_) => _pinchStart = _zoom,
            onScaleUpdate: (d) {
              if (d.pointerCount < 2) return;
              _setZoom(_pinchStart + (d.scale - 1) * 0.5);
            },
            onTapUp: (d) => _focus(d, box.biggest),
            child: MobileScanner(controller: _controller, onDetect: _onDetect),
          ),
          Center(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                border: Border.all(color: GnColors.accent, width: 3),
                borderRadius: BorderRadius.circular(18),
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 24,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: GnColors.card.withValues(alpha: .9),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(
                  _hint ??
                      'Point your camera at the QR code in the Gamepad Party lobby. '
                          'Too small? Zoom in.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 4),
                Row(children: [
                  IconButton(
                    tooltip: 'Zoom out',
                    icon: const Icon(Icons.zoom_out),
                    onPressed: () => _setZoom(_zoom - 0.1),
                  ),
                  Expanded(
                    child: Slider(
                      key: const ValueKey('scanner-zoom'),
                      value: _zoom,
                      onChanged: _setZoom,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Zoom in',
                    icon: const Icon(Icons.zoom_in),
                    onPressed: () => _setZoom(_zoom + 0.1),
                  ),
                ]),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}
