import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;

import '../design/tokens.dart';
import '../scan/pipeline.dart';
import '../state/scan_state.dart';

/// Camera view with live edge-detection preview.
///
/// Detection runs on low-res frames inside an isolate; the resulting quad is
/// painted over the preview. Frames are dropped while a detection is in
/// flight — we want freshness, not a backlog. A busy/failed camera shows a
/// graceful fallback (album import still works from the home tab).
class CameraPage extends ConsumerStatefulWidget {
  const CameraPage({super.key});

  @override
  ConsumerState<CameraPage> createState() => _CameraPageState();
}

class _CameraPageState extends ConsumerState<CameraPage> {
  CameraController? _controller;
  bool _multiPage = false;
  bool _detecting = false;
  bool _detectEnabled = true;
  List<double>? _quad; // flat normalized TLx,TLy,TRx,TRy,BRx,BRy,BLx,BLy
  bool _capturing = false;
  int _shotCount = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      // A page shot at 1080p carries fewer pixels than the A4 sheet it is
      // written onto, so every scan ends up soft however good the enhancement
      // is. Ask the sensor for its largest still image and step down only when
      // the device refuses.
      const presets = [
        ResolutionPreset.max,
        ResolutionPreset.veryHigh,
        ResolutionPreset.high,
      ];
      Object? lastError;
      for (final preset in presets) {
        final controller = CameraController(
          back,
          preset,
          imageFormatGroup: ImageFormatGroup.jpeg,
          enableAudio: false,
        );
        try {
          await controller.initialize();
          if (!mounted) {
            await controller.dispose();
            return;
          }
          setState(() => _controller = controller);
          if (_detectEnabled) await controller.startImageStream(_onFrame);
          return;
        } catch (e) {
          lastError = e;
          await controller.dispose();
        }
      }
      if (mounted) setState(() => _error = '相机不可用：$lastError');
    } catch (e) {
      if (mounted) setState(() => _error = '相机不可用：$e');
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _onFrame(CameraImage frame) async {
    if (_detecting || _capturing || !_detectEnabled) return;
    _detecting = true;
    try {
      // JPEG-encode the YUV frame down to a small grayscale for detection.
      // camera's YUV420 needs manual conversion; 480p is plenty.
      final gray = _yuvToGray(frame, 480);
      final quad = await Isolate.run(() => detectQuadFromGray(gray));
      if (mounted && quad != _quad) {
        setState(() => _quad = quad);
      }
    } catch (_) {
      // Detection failures are silent; the frame is just skipped.
    } finally {
      _detecting = false;
    }
  }

  /// Convert camera YUV to a grayscale img.Image at reduced size, and run
  /// corner detection in the same isolate (encode+decode across the boundary
  /// would cost more than the conversion).
  static List<double>? detectQuadFromGray(img.Image gray) {
    final corners = findDocumentCorners(gray);
    if (corners == null) return null;
    return [
      for (final p in corners) ...[p[0] / gray.width, p[1] / gray.height],
    ]; // flat TLx,TLy,TRx,... normalized
  }

  /// The Y plane, box-downsampled straight to [targetW]. The old path pushed
  /// every source pixel through the pixel API — 2M calls per frame at 1080p,
  /// twelve times that at full resolution — which is how a viewfinder becomes a
  /// slideshow.
  img.Image _yuvToGray(CameraImage frame, int targetW) {
    final plane = frame.planes.first;
    final bytes = plane.bytes;
    final stride = math.max(1, plane.bytesPerRow);
    final w = frame.width;
    final h = math.min(frame.height, bytes.length ~/ stride);
    final tw = math.min(targetW, w);
    final th = math.max(1, (h * tw / w).round());
    final out = Uint8List(tw * th);
    for (var oy = 0; oy < th; oy++) {
      final y0 = (oy * h / th).floor(), y1 = math.min(h, ((oy + 1) * h / th).ceil());
      for (var ox = 0; ox < tw; ox++) {
        final x0 = (ox * w / tw).floor(), x1 = math.min(w, ((ox + 1) * w / tw).ceil());
        var sum = 0, n = 0;
        for (var y = y0; y < y1; y++) {
          final row = y * stride;
          for (var x = x0; x < x1; x++) {
            sum += bytes[row + x];
            n++;
          }
        }
        out[oy * tw + ox] = n == 0 ? 0 : sum ~/ n;
      }
    }
    return img.Image.fromBytes(width: tw, height: th, bytes: out.buffer, numChannels: 1);
  }

  Future<void> _capture() async {
    final controller = _controller;
    if (controller == null || _capturing) return;
    setState(() => _capturing = true);
    try {
      // Stop the detection stream so the capture doesn't fight it.
      await controller.stopImageStream();
      final file = await controller.takePicture();
      final session = ref.read(sessionProvider.notifier);
      // Queue the shot as taken; the warp and the enhancement run when the
      // session is advanced, so a bad shot can still be thrown away. The marker
      // the user was aiming with travels with it as a hint for that pass.
      session.addPending(File(file.path), hintQuad: _detectEnabled ? _quad : null);

      if (!mounted) return;
      if (_multiPage) {
        setState(() {
          _shotCount++;
          _capturing = false;
        });
        if (_detectEnabled) await controller.startImageStream(_onFrame);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            duration: const Duration(milliseconds: 900),
            behavior: SnackBarBehavior.floating,
            backgroundColor: Ds.glassFill,
            content: Text('第 ${_shotCount + 1} 页就绪 · 继续拍摄或点「完成」',
                style: const TextStyle(color: Ds.text)),
          ));
        }
      } else {
        if (mounted) Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _capturing = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('拍摄失败：$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      backgroundColor: Ds.ink,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Viewfinder
          if (controller != null && controller.value.isInitialized)
            CameraPreviewWithOverlay(
              controller: controller,
              quad: _quad,
            )
          else
            Center(
              child: _error != null
                  ? Padding(
                      padding: const EdgeInsets.all(32),
                      child: Glass(
                        dark: true,
                        child: Padding(
                          padding: const EdgeInsets.all(18),
                          child: Text(_error!, style: const TextStyle(color: Colors.white)),
                        ),
                      ),
                    )
                  : const CircularProgressIndicator(color: Ds.clover),
            ),

          // Top glass bar: everything lives here, nothing floats mid-screen.
          // Positioned gives the bar bounded constraints — without it the
          // BackdropFilter fills the whole Stack and hides the viewfinder.
          Positioned(
            top: 0, left: 0, right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: Glass(
                dark: true,
                radius: Ds.radiusSmall,
                padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
                child: Row(
                  children: [
                    _modeChip('单页', !_multiPage, () => setState(() => _multiPage = false)),
                    _modeChip('多页', _multiPage, () => setState(() => _multiPage = true)),
                    const Spacer(),
                    if (_multiPage && _shotCount > 0)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Text('已拍 $_shotCount 页',
                            style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w600)),
                      ),
                    GestureDetector(
                      onTap: () async {
                        final on = !_detectEnabled;
                        setState(() => _detectEnabled = on);
                        if (on) {
                          await _controller?.startImageStream(_onFrame);
                        } else {
                          await _controller?.stopImageStream();
                          setState(() => _quad = null);
                        }
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(9),
                        child: Icon(Icons.auto_awesome,
                            size: 19,
                            color: _detectEnabled ? Ds.clover : Colors.white.withValues(alpha: 0.5)),
                      ),
                    ),
                    GestureDetector(
                      onTap: () => Navigator.of(context).pop(),
                      child: const Padding(
                        padding: EdgeInsets.all(9),
                        child: Icon(Icons.close, size: 19, color: Colors.white),
                      ),
                    ),
                  ],
                ),
                ),
              ),
            ),
          ),

          // Bottom controls
          SafeArea(
            top: false,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 26),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      // Finish (multi-page only)
                      if (_multiPage)
                        _RoundControl(
                          size: 52,
                          onTap: _shotCount > 0 ? () => Navigator.of(context).pop() : null,
                          child: const Icon(Icons.done, color: Colors.white, size: 26),
                        ),
                      // Shutter
                      GestureDetector(
                        onTap: _capture,
                        child: AnimatedScale(
                          scale: _capturing ? 0.9 : 1.0,
                          duration: Ds.durFast,
                          curve: Ds.curve,
                          child: Container(
                            width: 78, height: 78,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.white,
                              border: Border.all(color: Ds.clover, width: 4),
                              boxShadow: [BoxShadow(color: Ds.clover.withValues(alpha: 0.35), blurRadius: 26)],
                            ),
                            child: _capturing
                                ? const Padding(
                                    padding: EdgeInsets.all(24),
                                    child: CircularProgressIndicator(strokeWidth: 2.6, color: Ds.clover))
                                : const Icon(Icons.crop_free, color: Ds.clover, size: 30),
                          ),
                        ),
                      ),
                      // Placeholder to balance the row
                      if (_multiPage) const SizedBox(width: 52),
                    ],
                  ),
                ),
                if (_multiPage)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 14),
                    child: Text('继续拍下一页', style: TextStyle(color: Colors.white70, fontSize: 13)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _modeChip(String label, bool active, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: Ds.durFast,
        curve: Ds.curve,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: active ? Colors.white.withValues(alpha: 0.18) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(label, style: TextStyle(
          color: active ? Colors.white : Colors.white.withValues(alpha: 0.55),
          fontSize: 13.5,
          fontWeight: active ? FontWeight.w600 : FontWeight.w400,
        )),
      ),
    );
  }
}

/// Camera preview + the detection quad painted on top.
class CameraPreviewWithOverlay extends StatelessWidget {
  const CameraPreviewWithOverlay({
    super.key,
    required this.controller,
    required this.quad,
  });

  final CameraController controller;
  final List<double>? quad; // flat normalized TLx,TLy,TRx,TRy,BRx,BRY,BLx,BLy

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        CameraPreview(controller),
        if (quad != null)
          CustomPaint(
            painter: _QuadPainter(quad!),
          ),
      ],
    );
  }
}

class _QuadPainter extends CustomPainter {
  _QuadPainter(this.quad);

  final List<double> quad;

  @override
  void paint(Canvas canvas, Size size) {
    final points = [
      Offset(quad[0] * size.width, quad[1] * size.height),
      Offset(quad[2] * size.width, quad[3] * size.height),
      Offset(quad[4] * size.width, quad[5] * size.height),
      Offset(quad[6] * size.width, quad[7] * size.height),
    ];
    final path = Path()
      ..addPolygon(points, true);

    // Fill
    canvas.drawPath(path, Paint()..color = Ds.clover.withValues(alpha: 0.14));
    // Edge
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..color = Ds.clover.withValues(alpha: 0.9),
    );
    // Corner handles: glass dots
    final dotFill = Paint()..color = Colors.white;
    final dotRing = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = Ds.clover;
    for (final p in points) {
      canvas.drawCircle(p, 8, dotFill);
      canvas.drawCircle(p, 8, dotRing);
    }
  }

  @override
  bool shouldRepaint(_QuadPainter oldDelegate) => oldDelegate.quad != quad;
}

class _RoundControl extends StatelessWidget {
  const _RoundControl({required this.size, required this.child, this.onTap});

  final double size;
  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Glass(
        dark: true,
        radius: size / 2,
        child: SizedBox(
          width: size, height: size,
          child: Center(child: child),
        ),
      ),
    );
  }
}
