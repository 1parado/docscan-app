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

  test('a soft outline the gradient bar cannot separate from ink still crops', () {
    // White paper on a pale desk: 8 levels across the page edge, against dark
    // text inside the page that is far stronger. A fixed gradient threshold
    // tuned for the text loses the outline entirely.
    final photo = img.Image(width: 900, height: 1200, numChannels: 3);
    img.fill(photo, color: img.ColorUint8.rgb(236, 235, 233));
    final doc = img.Image(width: 560, height: 760, numChannels: 3);
    img.fill(doc, color: img.ColorUint8.rgb(246, 245, 243));
    final rnd = math.Random(11);
    for (var i = 0; i < 30; i++) {
      img.drawLine(
        doc,
        x1: 40 + rnd.nextInt(460), y1: 60 + rnd.nextInt(660),
        x2: 40 + rnd.nextInt(460), y2: 60 + rnd.nextInt(660),
        color: img.ColorUint8.rgb(60, 60, 64),
        thickness: 3,
      );
    }
    img.compositeImage(photo, doc, dstX: 170, dstY: 220);

    final corners = findDocumentCorners(photo);
    expect(corners, isNotNull, reason: 'no quad found in a low-contrast frame');
    final xs = corners!.map((p) => p[0]).toList();
    final ys = corners.map((p) => p[1]).toList();
    final w = xs.reduce((a, b) => math.max(a, b)) - xs.reduce((a, b) => math.min(a, b));
    final h = ys.reduce((a, b) => math.max(a, b)) - ys.reduce((a, b) => math.min(a, b));
    expect(w, closeTo(560, 60), reason: 'wrong width: $w at $xs');
    expect(h, closeTo(760, 60), reason: 'wrong height: $h at $ys');
  });

  test('a textured desk with no page on it is not a document', () {
    final photo = img.Image(width: 900, height: 1200, numChannels: 3);
    final rnd = math.Random(3);
    for (var y = 0; y < photo.height; y++) {
      for (var x = 0; x < photo.width; x++) {
        final grain = 118 + rnd.nextInt(26);
        photo.setPixelRgb(x, y, grain, grain - 4, grain - 10);
      }
    }
    for (var i = 0; i < 60; i++) {
      img.drawLine(
        photo,
        x1: rnd.nextInt(900), y1: rnd.nextInt(1200),
        x2: rnd.nextInt(900), y2: rnd.nextInt(1200),
        color: img.ColorUint8.rgb(80, 76, 70),
      );
    }
    expect(findDocumentCorners(photo), isNull, reason: 'the desk became a page');
  });

  test('corners land on the page corner, not on its bounding box', () {
    const true0 = [220.0, 300.0]; // TL
    const true1 = [880.0, 360.0]; // TR
    const true2 = [840.0, 1240.0]; // BR
    const true3 = [180.0, 1180.0]; // BL
    final photo = img.Image(width: 1200, height: 1600, numChannels: 3);
    img.fill(photo, color: img.ColorUint8.rgb(110, 108, 104));
    img.fillPolygon(
      photo,
      vertices: [true0, true1, true2, true3]
          .map((p) => img.Point(p[0].round(), p[1].round()))
          .toList(),
      color: img.ColorUint8.rgb(245, 244, 240),
    );
    for (var i = 0; i < 24; i++) {
      img.drawLine(
        photo,
        x1: 300, y1: 420 + i * 32, x2: 760, y2: 430 + i * 32,
        color: img.ColorUint8.rgb(64, 64, 70),
      );
    }

    final corners = findDocumentCorners(photo)!;
    final want = [true0, true1, true2, true3];
    for (var i = 0; i < 4; i++) {
      final dx = (corners[i][0] - want[i][0]).abs();
      final dy = (corners[i][1] - want[i][1]).abs();
      expect(math.max(dx, dy), lessThan(5),
          reason: 'corner $i at ${corners[i]}, should be ${want[i]}');
    }
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

  test('toA4 writes the tier the page can actually fill', () {
    img.Image sized(int w, int h) => img.Image(width: w, height: h, numChannels: 3);
    expect(a4DpiFor(sized(1200, 1600)), 200);
    expect(a4DpiFor(sized(2200, 3000)), 250);
    expect(a4DpiFor(sized(2600, 3600)), 300);
    expect(toA4(sized(1200, 1600), dpi: 300).width, a4Tiers[300]!.$1);
    expect(toA4(sized(2600, 3600)).height, a4Tiers[300]!.$2);
  });

  test('a small page still lands on an A4 sheet', () {
    final photo = makePhoto();
    final (page, _) = processPage(photo, mode: ScanMode.color);
    final a4 = toA4(page);
    final (w, h) = a4Tiers[a4DpiFor(page)]!;
    expect((a4.width, a4.height), (w, h));
    expect(a4.width / a4.height, closeTo(210 / 297, 0.01));
  });

  test('fourPointTransform bounds the sheet and pre-filters the source', () {
    final photo = img.Image(width: 2000, height: 1500, numChannels: 3);
    img.fill(photo, color: img.ColorUint8.rgb(200, 198, 194));
    final warped = fourPointTransform(
      photo,
      [
        [100, 100], [1900, 100], [1900, 1400], [100, 1400],
      ],
      maxSide: 800,
    );
    expect(math.max(warped.width, warped.height), lessThanOrEqualTo(800));
    // The pre-filter has to survive the shrink: a flat grey page stays grey.
    var sum = 0, n = 0;
    for (var y = 4; y < warped.height; y += 8) {
      for (var x = 4; x < warped.width; x += 8) {
        sum += warped.getPixel(x, y).luminance.toInt();
        n++;
      }
    }
    expect(sum / n, closeTo(199, 8));
  });

  test('removeShadow flattens a shaded, tinted page', () {
    img.Image shaded() {
      final page = img.Image(width: 400, height: 500, numChannels: 3);
      for (var y = 0; y < page.height; y++) {
        // A lamp falling off down the page, from a bulb that is not white.
        final light = 1.0 - 0.45 * (y / page.height);
        for (var x = 0; x < page.width; x++) {
          page.setPixelRgb(x, y, (232 * light).round(), (228 * light).round(), (196 * light).round());
        }
      }
      for (final y in [120, 250, 400]) {
        img.drawLine(page, x1: 40, y1: y, x2: 360, y2: y, color: img.ColorUint8.rgb(38, 38, 42));
      }
      return page;
    }

    final flat = removeShadow(shaded());
    int meanAt(int y, {required bool paper}) {
      var sum = 0, n = 0;
      for (var x = 40; x < 360; x++) {
        final v = flat.getPixel(x, y).r.toInt();
        if (v > 128 == paper) {
          sum += v;
          n++;
        }
      }
      expect(n, greaterThan(80), reason: 'row $y has too few ${paper ? 'paper' : 'ink'} pixels');
      return (sum / n).round();
    }

    final topPaper = meanAt(60, paper: true);
    final bottomPaper = meanAt(460, paper: true);
    expect((topPaper - bottomPaper).abs(), lessThan(14), reason: 'the lamp gradient survived');
    // The cast was 36 levels of red over blue; dividing by the background
    // estimate has to take it out rather than just brightening the page.
    var r = 0, b = 0, n = 0;
    for (var y = 0; y < flat.height; y += 7) {
      for (var x = 0; x < flat.width; x += 7) {
        final p = flat.getPixel(x, y);
        if (p.r > 128) {
          r += p.r.toInt();
          b += p.b.toInt();
          n++;
        }
      }
    }
    expect(((r - b) / n).abs(), lessThan(12), reason: 'the page is still tinted');
    expect(meanAt(250, paper: false), lessThan(90), reason: 'the ink washed out with the shadow');
  });

  test('auto-levels ignore the desk that slipped into the crop', () {
    final page = img.Image(width: 300, height: 300, numChannels: 3);
    img.fill(page, color: img.ColorUint8.rgb(238, 236, 232));
    for (var y = 286; y < 300; y++) {
      for (var x = 0; x < 300; x++) {
        page.setPixelRgb(x, y, 8, 8, 8); // a black band along the bottom edge
      }
    }
    final flat = removeShadow(page);
    var sum = 0, n = 0;
    for (var y = 0; y < 280; y += 2) {
      for (var x = 0; x < 300; x += 2) {
        sum += flat.getPixel(x, y).r.toInt();
        n++;
      }
    }
    // Four percent of the page is near-black. Stretching to global min/max maps
    // that to 0 and drags the paper down with it; a percentile band does not.
    expect(sum / n, greaterThan(220));
  });

  test('color mode sharpens edges without crisp-ifying the noise floor', () {
    // A two-level dither is the worst case for an ungated 3x3 sharpen: every
    // pixel looks like an edge to the kernel, so ±2 levels of sensor noise come
    // back as a visible cross-hatch on what should be blank paper.
    img.Image noisy() {
      final page = img.Image(width: 300, height: 200, numChannels: 3);
      for (var y = 0; y < page.height; y++) {
        for (var x = 0; x < page.width; x++) {
          final v = ((x + y) & 1) == 0 ? 232 : 228;
          page.setPixelRgb(x, y, v, v, v);
        }
      }
      img.fillRect(page, x1: 40, y1: 60, x2: 260, y2: 90, color: img.ColorUint8.rgb(40, 40, 40));
      return page;
    }

    final out = enhanceDocument(noisy(), mode: ScanMode.color);
    var min = 255, max = 0;
    for (var x = 10; x < 30; x++) {
      for (var y = 10; y < 50; y++) {
        final v = out.getPixel(x, y).r.toInt();
        if (v < min) min = v;
        if (v > max) max = v;
      }
    }
    expect(max - min, lessThan(9), reason: 'the sharpen amplified the dither into a pattern');
    expect(out.getPixel(150, 75).r.toInt(), lessThan(90), reason: 'the ink got washed out');
  });

  test('bw mode closes speckle and pinholes but keeps the stroke', () {
    final page = img.Image(width: 300, height: 200, numChannels: 3);
    img.fill(page, color: img.ColorUint8.rgb(240, 238, 234));
    img.fillRect(page, x1: 30, y1: 100, x2: 270, y2: 106, color: img.ColorUint8.rgb(30, 30, 30));
    for (final (x, y) in [(60, 40), (200, 60), (140, 160)]) {
      page.setPixelRgb(x, y, 20, 20, 20); // lone specks on blank paper
    }
    page.setPixelRgb(150, 103, 245, 245, 245); // a pinhole inside the stroke

    final out = enhanceDocument(page, mode: ScanMode.bw);
    int ink(int x, int y) => out.getPixel(x, y).r.toInt() < 128 ? 0 : 255;

    var specks = 0;
    for (var y = 1; y < out.height - 1; y++) {
      for (var x = 1; x < out.width - 1; x++) {
        if (ink(x, y) != 0) continue;
        var neighbours = 0;
        for (var dy = -1; dy <= 1; dy++) {
          for (var dx = -1; dx <= 1; dx++) {
            if (dx != 0 || dy != 0) neighbours += ink(x + dx, y + dy) == 0 ? 1 : 0;
          }
        }
        if (neighbours == 0) specks++;
      }
    }
    expect(specks, 0, reason: 'lone dark pixels survived the binarise');
    expect(ink(150, 103), 0, reason: 'the pinhole stayed open');
    var stroke = 0;
    for (var x = 40; x < 260; x++) {
      if (ink(x, 103) == 0) stroke++;
    }
    expect(stroke, greaterThan(180), reason: 'the stroke broke up');
  });

  test('grey mode lifts faint pencil off the paper', () {
    final page = img.Image(width: 300, height: 200, numChannels: 3);
    img.fill(page, color: img.ColorUint8.rgb(236, 235, 232));
    // Two blocks of graphite so light the global stretch alone cannot find them.
    for (var y = 40; y < 70; y++) {
      for (var x = 40; x < 130; x++) {
        page.setPixel(x, y, img.ColorUint8.rgb(226, 225, 222));
      }
    }
    for (var y = 120; y < 150; y++) {
      for (var x = 40; x < 130; x++) {
        page.setPixel(x, y, img.ColorUint8.rgb(218, 217, 214));
      }
    }

    final out = enhanceDocument(page, mode: ScanMode.gray);
    int luma(int x, int y) => out.getPixel(x, y).r.toInt();
    final paper = luma(250, 100);
    final faint = luma(85, 55);
    final darker = luma(85, 135);
    expect(paper - faint, greaterThan(18), reason: 'the faint block is still invisible');
    expect(paper - darker, greaterThan(paper - faint), reason: 'the two blocks inverted');
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
