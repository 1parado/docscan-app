import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;

import '../design/tokens.dart';
import '../scan/pipeline.dart';
import '../state/scan_state.dart';

/// Manual four-corner crop editor. Shows the RAW photo (re-decoded from the
/// processed page's source is impossible — the raw was discarded — so the
/// editor works on the processed A4 page and maps corners through the A4
/// placement; good enough visually because the page is centered and scaled
/// deterministically).
///
/// Returns the corner quad in *processed page pixel coordinates* via
/// Navigator.pop, or null on cancel.
class AdjustPage extends ConsumerStatefulWidget {
  const AdjustPage({super.key, required this.pageIndex});

  final int pageIndex;

  @override
  ConsumerState<AdjustPage> createState() => _AdjustPageState();
}

class _AdjustPageState extends ConsumerState<AdjustPage> {
  final _quad = <Offset>[]; // display coords
  Size _imgSize = const Size(1, 1);
  int _dragging = -1;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    final pages = ref.read(sessionProvider);
    final page = pages[widget.pageIndex];
    // init with an 85% centered quad; will be overridden after image loads
    WidgetsBinding.instance.addPostFrameCallback((_) => _initQuad());
    // Decode dims asynchronously (file must exist; it does)
    img.Image? decoded;
    () async {
      final bytes = await page.file.readAsBytes();
      decoded = decodeImage(bytes);
      if (mounted && decoded != null) {
        setState(() => _imgSize = Size(decoded!.width.toDouble(), decoded!.height.toDouble()));
        _initQuad();
      }
    }();
  }

  void _initQuad() {
    if (!mounted || _loaded) return;
    final size = _imgSize;
    setState(() {
      _quad
        ..clear()
        ..addAll([
          Offset(size.width * 0.08, size.height * 0.08),
          Offset(size.width * 0.92, size.height * 0.08),
          Offset(size.width * 0.92, size.height * 0.92),
          Offset(size.width * 0.08, size.height * 0.92),
        ]);
      _loaded = true;
    });
  }

  void _onDrag(Offset local, Offset imgTopLeft, double scale) {
    if (_dragging < 0) return;
    final x = ((local.dx - imgTopLeft.dx) / scale).clamp(0.0, _imgSize.width);
    final y = ((local.dy - imgTopLeft.dy) / scale).clamp(0.0, _imgSize.height);
    setState(() => _quad[_dragging] = Offset(x, y));
  }

  @override
  Widget build(BuildContext context) {
    final pages = ref.watch(sessionProvider);
    final page = pages[widget.pageIndex];

    return Scaffold(
      backgroundColor: Ds.ink,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const Text('调整裁剪',
                      style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600)),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消', style: TextStyle(color: Colors.white70)),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: LayoutBuilder(builder: (context, constraints) {
                  final scale = (constraints.maxWidth / _imgSize.width)
                      .clamp(0.0, (constraints.maxHeight / _imgSize.height));
                  final dispW = _imgSize.width * scale;
                  final dispH = _imgSize.height * scale;
                  final topLeft = Offset(
                    (constraints.maxWidth - dispW) / 2,
                    (constraints.maxHeight - dispH) / 2,
                  );
                  return GestureDetector(
                    onPanStart: (d) {
                      final local = d.localPosition - topLeft;
                      for (var i = 0; i < 4; i++) {
                        final handleDisp = Offset(_quad[i].dx * scale, _quad[i].dy * scale);
                        if ((local - handleDisp).distance < 30) {
                          setState(() => _dragging = i);
                          break;
                        }
                      }
                    },
                    onPanUpdate: (d) => _onDrag(d.localPosition, topLeft, scale),
                    onPanEnd: (_) => setState(() => _dragging = -1),
                    child: Stack(
                      children: [
                        Positioned(
                          left: topLeft.dx, top: topLeft.dy,
                          child: SizedBox(
                            width: dispW, height: dispH,
                            child: Image.file(page.file, fit: BoxFit.contain),
                          ),
                        ),
                        if (_loaded)
                          Positioned(
                            left: topLeft.dx, top: topLeft.dy,
                            child: CustomPaint(
                              size: Size(dispW, dispH),
                              painter: _CropQuadPainter(
                                _quad.map((p) => Offset(p.dx * scale, p.dy * scale)).toList(),
                              ),
                            ),
                          ),
                      ],
                    ),
                  );
                }),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('取消', style: TextStyle(color: Colors.white70)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: GestureDetector(
                      onTap: () => Navigator.of(context).pop(
                        _quad.map((p) => [p.dx, p.dy]).toList(),
                      ),
                      child: Glass(
                        radius: Ds.radiusSmall,
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 13),
                          decoration: BoxDecoration(
                            color: Ds.clover,
                            borderRadius: BorderRadius.circular(Ds.radiusSmall),
                          ),
                          child: const Center(
                            child: Text('应用并重扫',
                                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CropQuadPainter extends CustomPainter {
  _CropQuadPainter(this.points);

  final List<Offset> points;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()..addPolygon(points, true);
    canvas.drawPath(path, Paint()..color = Ds.clover.withValues(alpha: 0.14));
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..color = Ds.clover,
    );
    for (final p in points) {
      canvas.drawCircle(p, 9, Paint()..color = Colors.white);
      canvas.drawCircle(
        p, 9,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = Ds.clover,
      );
    }
  }

  @override
  bool shouldRepaint(_CropQuadPainter oldDelegate) => oldDelegate.points != points;
}
