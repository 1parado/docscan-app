// Generates deterministic synthetic "documents" for the on-device test suites.
//
// A test that depends on pointing a phone at paper is not repeatable, so these
// fixtures are a dark desk with a white page ruled with text lines. Each one is
// fed back through the real pipeline before it is accepted, so a suite can never
// quietly test nothing.
//
// Two families are produced on purpose:
//   * docscan_fixture_NN.jpg    square to the frame, the detector accepts these
//   * docscan_fixture_tilt.jpg  rotated a few degrees, the realistic case for a
//                               hand-held shot. Whether the detector accepts it
//                               is reported, not asserted, because the current
//                               side-coverage heuristic only passes for
//                               axis-aligned quads.
//
// Usage: dart run tool/make_scan_fixtures.dart [count] [outDir]
import 'dart:io';
import 'dart:math' as math;

import 'package:docscan_app/scan/pipeline.dart';
import 'package:image/image.dart' as img;

const deskColor = 52;
const pageLight = 243;
const inkColor = 34;
/// Override with TILT_DEG to sweep how far off-axis the detector still works.
final tiltDegrees = double.tryParse(Platform.environment['TILT_DEG'] ?? '') ?? 3.0;

void main(List<String> args) {
  final count = int.tryParse(args.length > 0 ? args[0] : '6') ?? 6;
  final outDir = Directory(args.length > 1 ? args[1] : 'android_test/fixtures')
    ..createSync(recursive: true);

  // Seeded so every contributor gets byte-identical fixtures.
  final rnd = math.Random(42);
  final written = <String, String>{}; // path -> family

  for (var i = 0; i < count; i++) {
    // A little per-image jitter in size and placement, still square to the frame.
    final inset = 0.10 + rnd.nextInt(4) / 100;
    final image = _page(1280, 1706, inset: inset, degrees: 0);
    final path = '${outDir.path}/docscan_fixture_${(i + 1).toString().padLeft(2, '0')}.jpg';
    File(path).writeAsBytesSync(img.encodeJpg(image, quality: 92));
    written[path] = 'upright';
  }

  final tilted = _page(1280, 1706, inset: 0.12, degrees: tiltDegrees);
  final tiltPath = '${outDir.path}/docscan_fixture_tilt.jpg';
  File(tiltPath).writeAsBytesSync(img.encodeJpg(tilted, quality: 92));
  written[tiltPath] = 'tilt';

  final flat = img.Image(width: 1280, height: 1706, numChannels: 3);
  _fill(flat, img.ColorUint8.rgb(120, 128, 124));
  for (var i = 0; i < 900; i++) {
    flat.setPixel(rnd.nextInt(flat.width), rnd.nextInt(flat.height),
        img.ColorUint8.rgb(rnd.nextInt(255), rnd.nextInt(255), rnd.nextInt(255)));
  }
  final flatPath = '${outDir.path}/docscan_fixture_nodoc.jpg';
  File(flatPath).writeAsBytesSync(img.encodeJpg(flat, quality: 92));
  written[flatPath] = 'nodoc';

  var failures = 0;
  for (final e in written.entries) {
    final decoded = decodeImage(File(e.key).readAsBytesSync())!;
    final (page, status) = processPage(decoded, mode: ScanMode.color, autoCrop: true);
    final name = e.key.split(Platform.pathSeparator).last;
    switch (e.value) {
      case 'upright':
        if (status != 'cropped') {
          failures++;
          stdout.writeln('FAIL $name status=$status (expected cropped)');
        } else {
          stdout.writeln('ok   $name status=$status a4=${page.width}x${page.height}');
        }
      case 'nodoc':
        if (status != 'not_found') {
          failures++;
          stdout.writeln('FAIL $name status=$status (expected not_found)');
        } else {
          stdout.writeln('ok   $name status=$status');
        }
      case 'tilt':
        // Asserted since the coverage band in findQuads scaled with the shape:
        // a page square to the frame was not the real case, and a detector that
        // only fires at 0° sends every photographed document to manual cropping.
        if (status != 'cropped') {
          failures++;
          stdout.writeln('FAIL $name (${tiltDegrees}°) status=$status (expected cropped)');
        } else {
          stdout.writeln('ok   $name (${tiltDegrees}°) status=$status');
        }
    }
  }
  stdout.writeln('${written.length} fixtures written, $failures failed the pipeline check');
  if (failures > 0) exitCode = 1;
}

/// A white page with text rules, rotated `degrees` about the image centre.
img.Image _page(int w, int h, {required double inset, required double degrees}) {
  final image = img.Image(width: w, height: h, numChannels: 3);
  _fill(image, img.ColorUint8.rgb(deskColor, deskColor, deskColor + 3));

  final cx = w / 2, cy = h / 2;
  final hw = w * (0.5 - inset), hh = h * (0.5 - inset * 1.2);
  final corners = <List<double>>[
    [cx - hw, cy - hh], // TL
    [cx + hw, cy - hh], // TR
    [cx + hw, cy + hh], // BR
    [cx - hw, cy + hh], // BL
  ];
  final a = degrees * math.pi / 180;
  final quad = [
    for (final p in corners)
      [
        cx + (p[0] - cx) * math.cos(a) - (p[1] - cy) * math.sin(a),
        cy + (p[0] - cx) * math.sin(a) + (p[1] - cy) * math.cos(a),
      ]
  ];

  _fillQuad(image, quad, img.ColorUint8.rgb(pageLight, pageLight, pageLight - 3));
  for (var line = 0; line < 22; line++) {
    final t = 0.18 + line * 0.032;
    if (t > 0.86) break;
    _drawRule(image, quad, t, 0.14, 0.86, img.ColorUint8.rgb(inkColor, inkColor, inkColor + 4));
  }
  return image;
}

void _fill(img.Image image, img.ColorUint8 color) {
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      image.setPixel(x, y, color);
    }
  }
}

/// Scanline rasterisation of a convex quad.
void _fillQuad(img.Image image, List<List<double>> q, img.ColorUint8 color) {
  final ys = q.map((p) => p[1]).toList();
  final top = ys.reduce(math.min).ceil();
  final bottom = ys.reduce(math.max).floor();
  for (var y = top; y <= bottom; y++) {
    final xs = <double>[];
    for (var i = 0; i < 4; i++) {
      final a = q[i], b = q[(i + 1) % 4];
      if ((a[1] <= y && b[1] >= y) || (b[1] <= y && a[1] >= y)) {
        final t = (b[1] - a[1]).abs() < 1e-6 ? 0.0 : (y - a[1]) / (b[1] - a[1]);
        xs.add(a[0] + (b[0] - a[0]) * t);
      }
    }
    if (xs.length < 2) continue;
    xs.sort();
    for (var x = xs[0].ceil(); x <= xs[1].floor(); x++) {
      if (x >= 0 && x < image.width) image.setPixel(x, y, color);
    }
  }
}

/// A horizontal rule between two fractional left/right positions, at vertical
/// fraction `t`, interpolated across the quad so it follows the page.
void _drawRule(
  img.Image image,
  List<List<double>> q,
  double t,
  double from,
  double to,
  img.ColorUint8 color,
) {
  final leftTop = q[0], leftBottom = q[3], rightTop = q[1], rightBottom = q[2];
  double xOf(List<double> a, List<double> b, double f) => a[0] + (b[0] - a[0]) * f;
  double yOf(List<double> a, List<double> b, double f) => a[1] + (b[1] - a[1]) * f;
  final lx = xOf(leftTop, leftBottom, t);
  final rx = xOf(rightTop, rightBottom, t);
  final yy = ((yOf(leftTop, leftBottom, t) + yOf(rightTop, rightBottom, t)) / 2).round();
  final x0 = (lx + (rx - lx) * from).round();
  final x1 = (lx + (rx - lx) * to).round();
  for (var x = math.min(x0, x1); x <= math.max(x0, x1); x++) {
    if (x >= 0 && x < image.width && yy >= 0 && yy < image.height) image.setPixel(x, yy, color);
  }
}
