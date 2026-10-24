import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:image/image.dart' as img;

import 'package:docscan_app/scan/pipeline.dart';

void main() {
  // Synthetic "photo": light desk with a tilted white document on it.
  img.Image makePhoto({int w = 900, int h = 1200}) {
    final photo = img.Image(width: w, height: h, numChannels: 3);
    img.fill(photo, color: img.ColorUint8.rgb(120, 118, 112)); // desk
    // document quad, slightly rotated
    final doc = img.Image(width: 600, height: 800, numChannels: 3);
    img.fill(doc, color: img.ColorUint8.rgb(245, 244, 240));
    final rnd = math.Random(7);
    for (var i = 0; i < 40; i++) {
      img.drawLine(
        doc,
        x1: 40 + rnd.nextInt(500), y1: 60 + rnd.nextInt(700),
        x2: 40 + rnd.nextInt(500), y2: 60 + rnd.nextInt(700),
        color: img.ColorUint8.rgb(70, 70, 75),
      );
    }
    final rotated = img.copyRotate(doc, angle: 4);
    img.compositeImage(photo, rotated, dstX: 150, dstY: 200);
    return photo;
  }

  test('findDocumentCorners locates a tilted document', () {
    final photo = makePhoto();
    final corners = findDocumentCorners(photo);
    expect(corners, isNotNull);
    final xs = corners!.map((p) => p[0]);
    final ys = corners.map((p) => p[1]);
    // Quad should cover roughly the pasted document region, not the frame.
    expect(xs.reduce((a, b) => math.max(a, b)) - xs.reduce((a, b) => math.min(a, b)),
        greaterThan(300));
    expect(ys.reduce((a, b) => math.max(a, b)) - ys.reduce((a, b) => math.min(a, b)),
        greaterThan(400));
  });

  test('processPage crops, enhances and reports status', () {
    final photo = makePhoto();
    final (page, status) = processPage(photo, mode: ScanMode.gray);
    expect(status, anyOf('cropped', 'kept'));
    expect(page.width, greaterThan(0));
    // Gray-mode page should be near-neutral: R≈G≈B on average.
    var dr = 0, db = 0, n = 0;
    for (var y = 0; y < page.height; y += 40) {
      for (var x = 0; x < page.width; x += 40) {
        final p = page.getPixel(x, y);
        dr += p.r.toInt(); db += p.b.toInt();
        n++;
      }
    }
    final avgR = dr / n, avgB = db / n;
    expect((avgR - avgB).abs(), lessThan(40));
  });

  test('bw mode binarizes to extremes', () {
    final photo = makePhoto();
    final (page, _) = processPage(photo, mode: ScanMode.bw);
    var dark = 0, light = 0, total = 0;
    for (var y = 0; y < page.height; y += 4) {
      for (var x = 0; x < page.width; x += 4) {
        final p = page.getPixel(x, y);
        final l = (p.r + p.g + p.b) / 3;
        if (l < 64) dark++;
        if (l > 192) light++;
        total++;
      }
    }
    // A document scan is mostly paper (light) with some ink (dark).
    expect(light / total, greaterThan(0.5));
    expect(dark, greaterThan(0));
  });

  test('toA4 produces the 200dpi canvas', () {
    final photo = makePhoto();
    final (page, _) = processPage(photo, mode: ScanMode.color);
    final a4 = toA4(page);
    expect(a4.width, 1654);
    expect(a4.height, 2339);
  });

  test('jpeg round-trip keeps an image', () {
    final photo = makePhoto();
    final (page, _) = processPage(photo, mode: ScanMode.gray);
    final bytes = encodeJpeg(page);
    expect(bytes.length, greaterThan(1000));
    final back = decodeImage(bytes);
    expect(back.width, page.width);
  });
}
