import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Scan pipeline — a faithful Dart port of the web project's
/// pipeline/detect.py + warp.py + enhance.py. Parameters are identical; only
/// the API surface changed (image package instead of OpenCV).
///
/// All functions are pure and synchronous; callers run them inside an
/// [Isolate] to keep the UI at 60fps.

/// Order four points as TL, TR, BR, BL.
List<List<double>> orderPoints(List<List<double>> pts) {
  final sums = pts.map((p) => p[0] + p[1]).toList();
  final diffs = pts.map((p) => p[1] - p[0]).toList();
  final tl = pts[_indexOfMin(sums)];
  final br = pts[_indexOfMax(sums)];
  final tr = pts[_indexOfMin(diffs)];
  final bl = pts[_indexOfMax(diffs)];
  return [tl, tr, br, bl];
}

int _indexOfMin(List<num> xs) {
  var best = 0;
  for (var i = 1; i < xs.length; i++) {
    if (xs[i] < xs[best]) best = i;
  }
  return best;
}

int _indexOfMax(List<num> xs) {
  var best = 0;
  for (var i = 1; i < xs.length; i++) {
    if (xs[i] > xs[best]) best = i;
  }
  return best;
}

/// Find the document quad in a grayscale-or-RGB image.
/// Returns [TL, TR, BR, BL] each [x, y] in source pixels, or null.
///
/// Port of find_document_corners: downscale to 800px tall, Canny-equivalent
/// gradient edges, contour search via connected border following, and a
/// four-point convex check.
List<List<double>>? findDocumentCorners(img.Image image) {
  const targetH = 800;
  final ratio = targetH / image.height;
  final small = img.copyResize(
    image,
    width: (image.width * ratio).round(),
    height: targetH,
    interpolation: img.Interpolation.linear,
  );

  final gray = img.grayscale(small);
  final blurred = img.gaussianBlur(gray, radius: 2);
  final edges = gradientEdges(blurred);
  dilateEdges(edges, 1);

  final quads = findQuads(edges, minAreaRatio: 0.15, maxShapes: 15);
  for (final quad in quads) {
    return quad
        .map((p) => [p[0] / ratio, p[1] / ratio])
        .toList(); // first (largest) convex quad wins, like contourArea sort
  }
  return null;
}

/// Simple Canny substitute: Sobel magnitude + hysteresis-free threshold.
/// OpenCV's Canny is stricter; the quad search below tolerates the noisier
/// edges because it filters by shape and area.
img.Image gradientEdges(img.Image gray) {
  final w = gray.width, h = gray.height;
  final out = img.Image(width: w, height: h, numChannels: 1);
  final l = gray.data!;
  final o = out.data!;

  int g(int x, int y) => l.getPixel(x, y).luminance.toInt();

  for (var y = 1; y < h - 1; y++) {
    for (var x = 1; x < w - 1; x++) {
      final gx = -g(x - 1, y - 1) - 2 * g(x - 1, y) - g(x - 1, y + 1) +
          g(x + 1, y - 1) + 2 * g(x + 1, y) + g(x + 1, y + 1);
      final gy = -g(x - 1, y - 1) - 2 * g(x, y - 1) - g(x + 1, y - 1) +
          g(x - 1, y + 1) + 2 * g(x, y + 1) + g(x + 1, y + 1);
      final mag = math.sqrt(gx * gx + gy * gy).clamp(0, 255).toInt();
      o.setPixelR(x, y, mag > 60 ? 255 : 0);
    }
  }
  return out;
}

void dilateEdges(img.Image bin, int iterations) {
  for (var it = 0; it < iterations; it++) {
    final copy = img.Image.from(bin);
    final c = copy.data!;
    final o = bin.data!;
    for (var y = 1; y < bin.height - 1; y++) {
      for (var x = 1; x < bin.width - 1; x++) {
        var v = 0;
        for (var dy = -1; dy <= 1 && v == 0; dy++) {
          for (var dx = -1; dx <= 1 && v == 0; dx++) {
            if (c.getPixel(x + dx, y + dy).luminance > 0) v = 255;
          }
        }
        o.setPixelR(x, y, v);
      }
    }
  }
}

/// Find quadrilaterals in a binary edge image, largest-area first.
///
/// Substitute for findContours + approxPolyDP: each connected edge blob is
/// flood-filled; its axis-aligned bounding box is then validated as the
/// document quad by checking that the blob hugs all four bbox sides (an
/// open rectangle outline does; a straight line or a blob hugging one side
/// does not). Corner positions come from the blob's extreme points along the
/// two diagonals plus the four bbox corners projected onto the blob.
List<List<List<double>>> findQuads(
  img.Image bin, {
  required double minAreaRatio,
  required int maxShapes,
}) {
  final w = bin.width, h = bin.height;
  final imgArea = (w * h).toDouble();
  final visited = List<bool>.filled(w * h, false);
  final b = bin.data!;

  bool edge(int x, int y) => b.getPixel(x, y).luminance > 0;

  final results = <(double, List<List<double>>)>[];

  for (var y0 = 0; y0 < h; y0++) {
    for (var x0 = 0; x0 < w; x0++) {
      if (visited[y0 * w + x0] || !edge(x0, y0)) continue;
      final stack = <int>[y0 * w + x0];
      visited[y0 * w + x0] = true;
      var minX = x0, maxX = x0, minY = y0, maxY = y0, count = 0;
      final blob = <int>[];
      while (stack.isNotEmpty) {
        final idx = stack.removeLast();
        blob.add(idx);
        count++;
        final px = idx % w, py = idx ~/ w;
        if (px < minX) minX = px;
        if (px > maxX) maxX = px;
        if (py < minY) minY = py;
        if (py > maxY) maxY = py;
        for (final (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)]) {
          final nx = px + dx, ny = py + dy;
          if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
          final nIdx = ny * w + nx;
          if (visited[nIdx] || !edge(nx, ny)) continue;
          visited[nIdx] = true;
          stack.add(nIdx);
        }
      }

      final bw = maxX - minX, bh = maxY - minY;
      final area = (bw * bh).toDouble();
      if (area < imgArea * minAreaRatio || count < 200) continue;

      // Coverage per side: a page outline runs along all four sides of its
      // bbox. The band has to scale with the shape, because a tilted rectangle
      // leans away from the bbox edge — with a fixed ±2px band only a page
      // square to the frame ever passes (a 3° tilt on a 400px side drifts ~21px).
      final band = 2 + (0.08 * (bw < bh ? bw : bh)).round();
      var top = 0, bottom = 0, left = 0, right = 0;
      for (final idx in blob) {
        final px = idx % w, py = idx ~/ w;
        if (py <= minY + band) top++;
        if (py >= maxY - band) bottom++;
        if (px <= minX + band) left++;
        if (px >= maxX - band) right++;
      }
      final okTop = top > bw * 0.25;
      final okBottom = bottom > bw * 0.25;
      final okLeft = left > bh * 0.25;
      final okRight = right > bh * 0.25;
      if (!(okTop && okBottom && okLeft && okRight)) continue;

      // Corners: extreme points toward each bbox corner. For every blob
      // pixel take the one minimizing distance to each bbox corner — the
      // document's rounded/straight corners land there.
      List<double> cornerNear(int cx, int cy) {
        var best = 1 << 30;
        var bestP = [minX.toDouble(), minY.toDouble()];
        for (final idx in blob) {
          final px = idx % w, py = idx ~/ w;
          final d = (px - cx) * (px - cx) + (py - cy) * (py - cy);
          if (d < best) {
            best = d;
            bestP = [px.toDouble(), py.toDouble()];
          }
        }
        return bestP;
      }

      final raw = [
        cornerNear(minX, minY), // TL
        cornerNear(maxX, minY), // TR
        cornerNear(maxX, maxY), // BR
        cornerNear(minX, maxY), // BL
      ];
      if (_isConvexQuad(raw)) {
        results.add((area, orderPoints(raw)));
      }
      if (results.length >= maxShapes) break;
    }
    if (results.length >= maxShapes) break;
  }
  results.sort((a, b) => b.$1.compareTo(a.$1));
  return results.map((r) => r.$2).toList();
}

bool _isConvexQuad(List<List<double>> q) {
  final ordered = orderPoints(q);
  var sign = 0.0;
  for (var i = 0; i < 4; i++) {
    final a = ordered[i], b = ordered[(i + 1) % 4], c = ordered[(i + 2) % 4];
    final cross = (b[0] - a[0]) * (c[1] - b[1]) - (b[1] - a[1]) * (c[0] - b[0]);
    if (cross.abs() < 1e-9) return false;
    if (sign == 0) {
      sign = cross;
    } else if (cross.sign != sign.sign) {
      return false;
    }
  }
  return true;
}

/// Perspective-warp the quad to an upright rectangle.
/// Port of warp.four_point_transform.
img.Image fourPointTransform(img.Image src, List<List<double>> quad) {
  final ordered = orderPoints(quad);
  final (tl, tr, br, bl) = (ordered[0], ordered[1], ordered[2], ordered[3]);

  final widthTop = math.sqrt(math.pow(tr[0] - tl[0], 2) + math.pow(tr[1] - tl[1], 2));
  final widthBot = math.sqrt(math.pow(br[0] - bl[0], 2) + math.pow(br[1] - bl[1], 2));
  final heightL = math.sqrt(math.pow(bl[0] - tl[0], 2) + math.pow(bl[1] - tl[1], 2));
  final heightR = math.sqrt(math.pow(br[0] - tr[0], 2) + math.pow(br[1] - tr[1], 2));
  final maxW = math.max(widthTop, widthBot).round().clamp(1, 1 << 14);
  final maxH = math.max(heightL, heightR).round().clamp(1, 1 << 14);

  final dst = img.Image(width: maxW, height: maxH, numChannels: 3);
  final s = src.data!;
  final d = dst.data!;

  // Inverse bilinear mapping: for each dst pixel, solve the homography that
  // sends the unit square to the quad, then sample bilinearly.
  final coeffs = _homography(
    [0, 0], [maxW.toDouble(), 0], [maxW.toDouble(), maxH.toDouble()], [0, maxH.toDouble()],
    tl, tr, br, bl,
  );

  for (var y = 0; y < maxH; y++) {
    for (var x = 0; x < maxW; x++) {
      final denom = coeffs[6] * x + coeffs[7] * y + 1;
      final sx = (coeffs[0] * x + coeffs[1] * y + coeffs[2]) / denom;
      final sy = (coeffs[3] * x + coeffs[4] * y + coeffs[5]) / denom;
      final x0 = sx.floor(), y0 = sy.floor();
      if (x0 < 0 || y0 < 0 || x0 >= src.width - 1 || y0 >= src.height - 1) {
        d.setPixelRgb(x, y, 255, 255, 255);
        continue;
      }
      final fx = sx - x0, fy = sy - y0;
      // bilinear per channel
      final c00 = s.getPixel(x0, y0), c10 = s.getPixel(x0 + 1, y0);
      final c01 = s.getPixel(x0, y0 + 1), c11 = s.getPixel(x0 + 1, y0 + 1);
      num mix(num a, num b, num c, num d) =>
          a * (1 - fx) * (1 - fy) + b * fx * (1 - fy) + c * (1 - fx) * fy + d * fx * fy;
      final rr = mix(c00.r, c10.r, c01.r, c11.r).toInt().clamp(0, 255);
      final gg = mix(c00.g, c10.g, c01.g, c11.g).toInt().clamp(0, 255);
      final bb = mix(c00.b, c10.b, c01.b, c11.b).toInt().clamp(0, 255);
      d.setPixelRgb(x, y, rr, gg, bb);
    }
  }
  return dst;
}

/// 8-coefficient homography mapping dst unit corners -> src quad.
List<double> _homography(
  List<double> d0, List<double> d1, List<double> d2, List<double> d3,
  List<double> s0, List<double> s1, List<double> s2, List<double> s3,
) {
  // Solve the 8x8 linear system by Gaussian elimination (tiny, once per page).
  // Build the 8x9 augmented matrix and solve by Gaussian elimination.
  final m = List.generate(8, (_) => List<double>.filled(9, 0));
  for (var i = 0; i < 4; i++) {
    final dp = [d0, d1, d2, d3][i];
    final sp = [s0, s1, s2, s3][i];
    m[2 * i] = [dp[0], dp[1], 1, 0, 0, 0, -sp[0] * dp[0], -sp[0] * dp[1], sp[0]];
    m[2 * i + 1] = [0, 0, 0, dp[0], dp[1], 1, -sp[1] * dp[0], -sp[1] * dp[1], sp[1]];
  }
  for (var col = 0; col < 8; col++) {
    var pivot = col;
    for (var row = col + 1; row < 8; row++) {
      if (m[row][col].abs() > m[pivot][col].abs()) pivot = row;
    }
    final tmp = m[col];
    m[col] = m[pivot];
    m[pivot] = tmp;
    for (var row = 0; row < 8; row++) {
      if (row == col) continue;
      final factor = m[row][col] / m[col][col];
      for (var k = col; k < 9; k++) {
        m[row][k] -= factor * m[col][k];
      }
    }
  }
  return [for (var i = 0; i < 8; i++) m[i][8] / m[i][i]];
}

/// Grayscale max-filter (dilate) over a square kernel — the image package
/// has none built in.
void dilateMax(img.Image im, int r) {
  final copy = img.Image.from(im);
  final c = copy.data!;
  final o = im.data!;
  for (var y = 0; y < im.height; y++) {
    for (var x = 0; x < im.width; x++) {
      var best = -1;
      for (var dy = -r; dy <= r; dy++) {
        final yy = (y + dy).clamp(0, im.height - 1);
        for (var dx = -r; dx <= r; dx++) {
          final xx = (x + dx).clamp(0, im.width - 1);
          final v = c.getPixel(xx, yy).r.toInt();
          if (v > best) best = v;
        }
      }
      o.setPixelRgb(x, y, best, best, best);
    }
  }
}

/// Port of enhance.remove_shadow: background is low-frequency, so the dilate
/// + median chain runs on a quarter-scale copy and is upscaled once.
img.Image removeShadow(img.Image rgb) {
  final w = rgb.width, h = rgb.height;
  final sw = math.max(1, w ~/ 4), sh = math.max(1, h ~/ 4);
  final small = img.copyResize(rgb, width: sw, height: sh, interpolation: img.Interpolation.average);
  // Background estimate = dilate(7) then median(21) on the web. The image
  // package has no median filter, so: dilate (max filter — this is what
  // brightens paper out of the shadow; skipping it was why app output kept
  // the gray cast), then a blur wide enough to match median-21's footprint
  // (sigma ~7 ≈ 2/3·10 → radius 10).
  dilateMax(small, 4);
  final bg = img.gaussianBlur(img.Image.from(small), radius: 10);
  final bgUp = img.copyResize(bg, width: w, height: h, interpolation: img.Interpolation.linear);

  final out = img.Image.from(rgb);
  final s = rgb.data!;
  final bgu = bgUp.data!;
  final o = out.data!;

  // Per-channel normalization: diff = 255 - |plane - bg|, then stretch.
  final minV = [255, 255, 255], maxV = [0, 0, 0];
  final diffs = Uint8List(w * h * 3);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final sp = s.getPixel(x, y);
      final bp = bgu.getPixel(x, y);
      for (var ch = 0; ch < 3; ch++) {
        final plane = [sp.r, sp.g, sp.b][ch].toInt();
        final bgv = [bp.r, bp.g, bp.b][ch].toInt();
        final d = (255 - (plane - bgv).abs()).clamp(0, 255);
        diffs[(y * w + x) * 3 + ch] = d;
        if (d < minV[ch]) minV[ch] = d;
        if (d > maxV[ch]) maxV[ch] = d;
      }
    }
  }
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final idx = (y * w + x) * 3;
      final r = _stretch(diffs[idx], minV[0], maxV[0]);
      final g = _stretch(diffs[idx + 1], minV[1], maxV[1]);
      final b = _stretch(diffs[idx + 2], minV[2], maxV[2]);
      o.setPixelRgb(x, y, r, g, b);
    }
  }
  return out;
}

int _stretch(int v, int min, int max) {
  if (max <= min) return v;
  return ((v - min) * 255 ~/ (max - min)).clamp(0, 255);
}

enum ScanMode { color, gray, bw }

/// Port of enhance.enhance_document.
img.Image enhanceDocument(img.Image bgr, {ScanMode mode = ScanMode.color}) {
  final cleaned = removeShadow(bgr);
  switch (mode) {
    case ScanMode.color:
      // Mild 3x3 unsharp (kernel [0,-1,0;-1,5,-1;0,-1,0]) like the web port.
      return _sharpen(cleaned, 0.4);
    case ScanMode.gray:
      final g = img.grayscale(cleaned).convert(numChannels: 3);
      _claheLite(g);
      return g;
    case ScanMode.bw:
      final g = img.grayscale(cleaned).convert(numChannels: 3);
      // Window ~1/16 of page width, like a 15px window on a 240px preview.
      final win = math.max(15, g.width ~/ 16 | 1);
      _adaptiveThreshold(g, win, 8);
      return g;
  }
}

/// 3x3 unsharp with adjustable amount (kernel center 1+4a, sides -a).
img.Image _sharpen(img.Image src, double amount) {
  final out = img.Image.from(src);
  final s = src.data!;
  final o = out.data!;
  final w = src.width, h = src.height;
  num px(int x, int y, int ch) {
    final p = s.getPixel(x.clamp(0, w - 1), y.clamp(0, h - 1));
    return [p.r, p.g, p.b][ch];
  }
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final chans = <int>[];
      for (var ch = 0; ch < 3; ch++) {
        final c = px(x, y, ch).toDouble();
        final sides = px(x - 1, y, ch) + px(x + 1, y, ch) + px(x, y - 1, ch) + px(x, y + 1, ch);
        chans.add((c * (1 + 4 * amount) - amount * sides).toInt().clamp(0, 255));
      }
      o.setPixelRgb(x, y, chans[0], chans[1], chans[2]);
    }
  }
  return out;
}

/// CLAHE substitute: local contrast via blurred-background division.
void _claheLite(img.Image g) {
  // Web uses CLAHE(clip 2.0, 8x8 tiles) ≈ background window of page/8.
  final bg = img.gaussianBlur(img.Image.from(g), radius: math.max(4, g.width ~/ 16));
  final s = g.data!;
  final b = bg.data!;
  for (var y = 0; y < g.height; y++) {
    for (var x = 0; x < g.width; x++) {
      final v = s.getPixel(x, y).luminance.toInt();
      final bgV = b.getPixel(x, y).luminance.toInt();
      // Divide by background, rescale — flattens illumination like CLAHE.
      final norm = (v * 255 / math.max(1, bgV)).clamp(0, 255).toInt();
      s.setPixelRgb(x, y, norm, norm, norm);
    }
  }
}

/// Adaptive threshold (gaussian window), CamScanner-style bw.
///
/// Thin strokes survive plain `v > mean - c`, but the interior of wide dark
/// strokes doesn't (local mean == pixel value). Subtracting the local
/// *contrast* (mean absolute deviation) keeps thick-ink interiors dark while
/// paper still clears the bar.
void _adaptiveThreshold(img.Image g, int win, int c) {
  final blurred = img.gaussianBlur(img.Image.from(g), radius: win ~/ 2);
  final s = g.data!;
  final b = blurred.data!;
  // Local mean absolute deviation, itself blurred so it varies smoothly.
  final dev = img.Image(width: g.width, height: g.height, numChannels: 1);
  final d = dev.data!;
  for (var y = 0; y < g.height; y++) {
    for (var x = 0; x < g.width; x++) {
      final v = s.getPixel(x, y).r.toInt();
      final m = b.getPixel(x, y).r.toInt();
      d.setPixelR(x, y, (v - m).abs());
    }
  }
  final devSmooth = img.gaussianBlur(dev, radius: win ~/ 2); // dev is owned
  final ds = devSmooth.data!;
  for (var y = 0; y < g.height; y++) {
    for (var x = 0; x < g.width; x++) {
      final v = s.getPixel(x, y).r.toInt();
      final mean = b.getPixel(x, y).r.toInt();
      final contrast = ds.getPixel(x, y).r.toInt();
      // Inside a wide stroke: contrast is high, so the bar drops further and
      // the pixel stays dark. On paper: contrast ~0, plain mean rule applies.
      final threshold = mean - c - contrast;
      final bin = v > threshold ? 255 : 0;
      s.setPixelRgb(x, y, bin, bin, bin);
    }
  }
}

/// Scale a page onto a centered white A4 canvas at 200dpi.
/// Port of pipeline.to_a4.
img.Image toA4(img.Image page) {
  const a4W = 1654, a4H = 2339;
  final scale = math.min(a4W / page.width, a4H / page.height);
  final nw = math.max(1, (page.width * scale).round());
  final nh = math.max(1, (page.height * scale).round());
  final resized = img.copyResize(
    page,
    width: nw,
    height: nh,
    interpolation: scale < 1 ? img.Interpolation.average : img.Interpolation.cubic,
  );
  final canvas = img.Image(width: a4W, height: a4H, numChannels: 3);
  img.fill(canvas, color: img.ColorUint8.rgb(255, 255, 255));
  final x0 = (a4W - nw) ~/ 2, y0 = (a4H - nh) ~/ 2;
  img.compositeImage(canvas, resized, dstX: x0, dstY: y0);
  return canvas;
}

/// One-stop page processing used by both camera capture and album import.
/// Returns (processedPage, cropStatus) where cropStatus is
/// "cropped" / "kept" / "not_found" / "manual".
(img.Image, String) processPage(
  img.Image photo, {
  ScanMode mode = ScanMode.color,
  bool autoCrop = true,
  List<List<double>>? manualCorners,
}) {
  if (manualCorners != null) {
    final warped = fourPointTransform(photo, manualCorners);
    return (enhanceDocument(warped, mode: mode), 'manual');
  }
  var status = autoCrop ? 'not_found' : 'kept';
  var page = photo;
  if (autoCrop) {
    final corners = findDocumentCorners(photo);
    if (corners != null) {
      status = 'kept';
      // skip_cover: a quad covering most of the frame means the photo is
      // already a full-page shot; warping only adds distortion.
      final xs = corners.map((p) => p[0]).toList();
      final ys = corners.map((p) => p[1]).toList();
      final cover = ((xs.reduce(math.max) - xs.reduce(math.min)) *
              (ys.reduce(math.max) - ys.reduce(math.min))) /
          (photo.width * photo.height);
      if (cover <= 0.82) {
        final expanded = _expandCorners(corners, photo.width, photo.height, 0.08);
        page = fourPointTransform(photo, expanded);
        status = 'cropped';
      }
    }
  }
  return (enhanceDocument(page, mode: mode), status);
}

List<List<double>> _expandCorners(
  List<List<double>> pts, int w, int h, double marginRatio,
) {
  final cx = pts.map((p) => p[0]).reduce((a, b) => a + b) / 4;
  final cy = pts.map((p) => p[1]).reduce((a, b) => a + b) / 4;
  return pts
      .map((p) => [
            (cx + (p[0] - cx) * (1 + marginRatio)).clamp(0.0, w - 1.0),
            (cy + (p[1] - cy) * (1 + marginRatio)).clamp(0.0, h - 1.0),
          ])
      .map(orderSingle)
      .toList();
}

List<double> orderSingle(List<double> p) => p;

/// Encode as JPEG for storage/PDF. `quality` 88 matches the web project.
Uint8List encodeJpeg(img.Image image, {int quality = 88}) =>
    Uint8List.fromList(img.encodeJpg(image, quality: quality));

img.Image decodeImage(Uint8List bytes) => img.decodeImage(bytes)!;
