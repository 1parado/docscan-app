import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Scan pipeline — a faithful Dart port of the web project's
/// pipeline/detect.py + warp.py + enhance.py. Parameters are identical; only
/// the API surface changed (image package instead of OpenCV).
///
/// All functions are pure and synchronous; callers run them inside an
/// [Isolate] to keep the UI at 60fps.

/// The A4 sheets the pipeline writes, keyed by dpi as (width, height) in px.
const Map<int, (int, int)> a4Tiers = {
  300: (2480, 3508),
  250: (2067, 2922),
  200: (1654, 2339),
};

/// The finest A4 tier a page can fill with real pixels. Below a tier's own
/// long edge the sheet would be an upscale, so the page drops to the next one.
int a4DpiFor(img.Image page) {
  final long = math.max(page.width, page.height);
  if (long >= 3400) return 300;
  if (long >= 2800) return 250;
  return 200;
}

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

double _dist(List<double> a, List<double> b) =>
    math.sqrt((a[0] - b[0]) * (a[0] - b[0]) + (a[1] - b[1]) * (a[1] - b[1]));

/// The packed bytes of an 8-bit image and its row stride.
///
/// Every filter in this file ran through `getPixel`/`setPixelRgb`, which
/// allocates a Color per call — eight million of them per page, and the reason
/// one full-resolution page spent ten seconds in enhancement instead of one.
/// 8-bit planes are stored tightly (`rowStride == width * numChannels`).
(Uint8List, int) _plane(img.Image im) {
  final d = im.data!;
  assert(d.format == img.Format.uint8);
  return (d.buffer.asUint8List(), d.rowStride);
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
///
/// [maxSide] bounds the output: a longer edge than the finest A4 sheet is
/// pixels the phone pays for at every later stage and the PDF throws away.
img.Image fourPointTransform(img.Image src, List<List<double>> quad, {int maxSide = 3600}) {
  final ordered = orderPoints(quad);

  final widthTop = _dist(ordered[0], ordered[1]);
  final widthBot = _dist(ordered[3], ordered[2]);
  final heightL = _dist(ordered[0], ordered[3]);
  final heightR = _dist(ordered[1], ordered[2]);
  var maxW = math.max(widthTop, widthBot).round().clamp(1, 1 << 14);
  var maxH = math.max(heightL, heightR).round().clamp(1, 1 << 14);
  if (math.max(maxW, maxH) > maxSide) {
    final s = maxSide / math.max(maxW, maxH);
    maxW = (maxW * s).round().clamp(1, maxSide);
    maxH = (maxH * s).round().clamp(1, maxSide);
  }

  // Sampling a much larger photo straight through bilinear taps decimates
  // source pixels — that is how text turns into sparkle. Shrink the source
  // first with an area filter, then warp close to 1:1.
  var work = src;
  var corners = ordered;
  final srcLong = math.max(math.max(widthTop, widthBot), math.max(heightL, heightR));
  if (srcLong / math.max(maxW, maxH) > 1.6) {
    final f = math.max(maxW, maxH) / srcLong;
    work = img.copyResize(
      src,
      width: math.max(1, (src.width * f).round()),
      height: math.max(1, (src.height * f).round()),
      interpolation: img.Interpolation.average,
    );
    corners = [for (final p in ordered) [p[0] * f, p[1] * f]];
  }
  final (tl, tr, br, bl) = (corners[0], corners[1], corners[2], corners[3]);

  final dst = img.Image(width: maxW, height: maxH, numChannels: 3);
  final s = work.data!;
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
      if (x0 < 0 || y0 < 0 || x0 >= work.width - 1 || y0 >= work.height - 1) {
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

/// Max-filter (dilate) over a square kernel, per channel — the image package
/// has none built in.
///
/// Per channel is the point: this runs on the background estimate, which the
/// white balance later divides by. Writing every channel from the red plane
/// flattened the estimate to grey, so the light's *colour* survived the whole
/// shadow pass and the page came out tinted.
void dilateMax(img.Image im, int r) {
  final (o, stride) = _plane(im);
  final copy = Uint8List.fromList(o);
  final w = im.width, h = im.height, nc = im.data!.numChannels;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final y0 = math.max(0, y - r), y1 = math.min(h - 1, y + r);
      final x0 = math.max(0, x - r), x1 = math.min(w - 1, x + r);
      for (var ch = 0; ch < nc; ch++) {
        var best = 0;
        for (var yy = y0; yy <= y1; yy++) {
          var p = yy * stride + x0 * nc + ch;
          for (var xx = x0; xx <= x1; xx++, p += nc) {
            if (copy[p] > best) best = copy[p];
          }
        }
        o[y * stride + x * nc + ch] = best;
      }
    }
  }
}

/// Flatten the illumination and take the light's colour out of the page, so a
/// scan reads as paper instead of as a photo of paper in a dim room.
///
/// The background is low-frequency, so it is estimated on a quarter-scale copy
/// (per-channel max filter, then a blur with median-21's footprint) and upscaled
/// once. Each pixel is then *divided* by that estimate: the same operation drops
/// a shadow's level and its tint, which the old `255 - |plane - bg|` could not
/// do — an absolute difference is symmetric, so it brightened ink exactly as
/// much as it brightened paper.
img.Image removeShadow(img.Image rgb, {double gainLimit = 3.0}) {
  final w = rgb.width, h = rgb.height;
  final sw = math.max(1, w ~/ 4), sh = math.max(1, h ~/ 4);
  final small = img.copyResize(rgb, width: sw, height: sh, interpolation: img.Interpolation.average);
  dilateMax(small, 4);
  final bg = img.gaussianBlur(img.Image.from(small), radius: 10);
  final bgUp = img.copyResize(bg, width: w, height: h, interpolation: img.Interpolation.linear);

  final (src, sStride) = _plane(rgb);
  final (b, bStride) = _plane(bgUp);
  final norm = Uint8List(w * h * 3);
  final hist = Uint32List(256);
  final limit = (255 * gainLimit).round();

  for (var y = 0; y < h; y++) {
    final row = y * sStride;
    final brow = y * bStride;
    for (var x = 0; x < w; x++) {
      final p = row + x * 3;
      for (var ch = 0; ch < 3; ch++) {
        // A gain ceiling keeps a genuinely dark patch from having its sensor
        // noise multiplied into confetti.
        final gain = math.min(limit, 255 * 255 ~/ math.max(1, b[brow + x * 3 + ch]));
        final v = (src[p + ch] * gain) ~/ 255;
        norm[p + ch] = v > 255 ? 255 : v;
      }
      hist[(norm[p] * 77 + norm[p + 1] * 150 + norm[p + 2] * 29) >> 8]++;
    }
  }

  // One band, taken from luminance, drives all three channels: stretching each
  // channel to its own extremes is what painted a yellow cast over white paper
  // whenever the desk under the page was not neutral.
  final (lo, hi) = _percentileBand(hist, w * h);
  final out = img.Image(width: w, height: h, numChannels: 3);
  final (o, oStride) = _plane(out);
  final span = hi - lo;
  if (span < 2) {
    // Nothing to gain: every pixel already carries the same value, and a
    // stretch would only invent contrast out of the noise floor.
    for (var p = 0, end = w * h * 3; p < end; p++) {
      o[p] = norm[p];
    }
    return out;
  }
  // Anchor at the top so paper lands on white, and cap how much the band may be
  // multiplied. A page with 90 levels of spread stretches 255/90 and fills the
  // range; a faint pencil mark on a lit page only spans a dozen, and pushing it
  // to 255 would lift the paper grain along with it. Under the cap the blacks
  // stay partly black instead of the highlights going grey.
  final scale = math.min(255 / span, gainLimit);
  for (var y = 0; y < h; y++) {
    final row = y * oStride;
    for (var x = 0; x < w; x++) {
      final p = row + x * 3;
      for (var ch = 0; ch < 3; ch++) {
        final v = 255 - ((hi - norm[p + ch]) * scale).round();
        o[p + ch] = v < 0 ? 0 : (v > 255 ? 255 : v);
      }
    }
  }
  return out;
}

/// The value band that holds the middle 98% of the mass, for auto-levels.
/// Global min/max — what this used to do — let one dark desk corner or one
/// specular highlight collapse the contrast of the whole page.
(int, int) _percentileBand(Uint32List hist, int total) {
  int at(double q) {
    final target = (total * q).ceil();
    var acc = 0;
    for (var v = 0; v < 256; v++) {
      acc += hist[v];
      if (acc >= target) return v;
    }
    return 255;
  }

  final lo = at(0.01);
  var hi = at(0.99);
  if (hi <= lo) hi = 255;
  return (lo, hi);
}

enum ScanMode { color, gray, bw }

/// Port of enhance.enhance_document.
img.Image enhanceDocument(img.Image bgr, {ScanMode mode = ScanMode.color}) {
  final cleaned = removeShadow(bgr);
  switch (mode) {
    case ScanMode.color:
      // Gated, so the extra push lands on ink edges rather than on the noise
      // floor of the paper.
      return _sharpen(cleaned, 0.5);
    case ScanMode.gray:
      final g = img.grayscale(cleaned).convert(numChannels: 3);
      _clahe(g);
      return g;
    case ScanMode.bw:
      final g = img.grayscale(cleaned).convert(numChannels: 3);
      // Wide enough to see paper around a stroke at any page size, capped so a
      // 300dpi page does not spend its whole budget on the local mean.
      final win = math.max(21, math.min(101, (g.width / 16).round())) | 1;
      _adaptiveThreshold(g, win, 8);
      return g;
  }
}

/// Unsharp with a gate: only pixels that are already leaving their local
/// neighbourhood get pushed further.
///
/// A plain 3x3 sharpen amplifies the paper's noise floor along with the ink,
/// which is what makes an "enhanced" phone scan look crunchier than the page
/// actually is. [minDeviation] is the distance from the local mean, in levels,
/// a pixel has to be before it counts as an edge.
img.Image _sharpen(img.Image src, double amount, {int minDeviation = 6}) {
  final w = src.width, h = src.height;
  final (s, stride) = _plane(src);
  final out = img.Image(width: w, height: h, numChannels: 3);
  final o = _plane(out).$1;
  final gate = minDeviation * 4;
  for (var y = 0; y < h; y++) {
    final row = y * stride;
    final up = (y > 0 ? y - 1 : y) * stride;
    final down = (y < h - 1 ? y + 1 : y) * stride;
    for (var x = 0; x < w; x++) {
      final p = row + x * 3, u = up + x * 3, d = down + x * 3;
      final xl = x > 0 ? p - 3 : p, xr = x < w - 1 ? p + 3 : p;
      for (var ch = 0; ch < 3; ch++) {
        final c = s[p + ch];
        final lap = 4 * c - (s[u + ch] + s[d + ch] + s[xl + ch] + s[xr + ch]);
        o[p + ch] = lap.abs() < gate ? c : (c + amount * lap).round().clamp(0, 255);
      }
    }
  }
  return out;
}

/// Contrast-Limited Adaptive Histogram Equalization on [grid] x [grid] tiles.
///
/// The substitute this replaces divided the page by a blurred copy of itself:
/// that haloes every thick stroke and does nothing for a region whose local
/// contrast is genuinely low — faint pencil, a thermal fax, the corner still in
/// shadow. The clip limit is what stops a near-blank tile (all its pixels in one
/// bin) from being equalised into a slab of white noise.
void _clahe(img.Image g, {int grid = 8, double clipLimit = 2.5}) {
  final (o, stride) = _plane(g);
  final w = g.width, h = g.height;
  final tileW = math.max(1, (w / grid).ceil());
  final tileH = math.max(1, (h / grid).ceil());
  final nx = (w + tileW - 1) ~/ tileW;
  final ny = (h + tileH - 1) ~/ tileH;

  final luts = <Uint8List>[];
  for (var ty = 0; ty < ny; ty++) {
    for (var tx = 0; tx < nx; tx++) {
      final hist = Uint32List(256);
      final y1 = math.min(h, (ty + 1) * tileH), x1 = math.min(w, (tx + 1) * tileW);
      for (var y = ty * tileH; y < y1; y++) {
        var p = y * stride + tx * tileW * 3;
        for (var x = tx * tileW; x < x1; x++, p += 3) {
          hist[o[p]]++;
        }
      }
      luts.add(_clipEqualize(hist, clipLimit));
    }
  }

  for (var y = 0; y < h; y++) {
    final gy = (y - tileH / 2) / tileH;
    final j0 = gy.floor().clamp(0, ny - 1), j1 = math.min(j0 + 1, ny - 1);
    final fy = (gy - j0).clamp(0.0, 1.0);
    final row = y * stride;
    for (var x = 0; x < w; x++) {
      final gx = (x - tileW / 2) / tileW;
      final i0 = gx.floor().clamp(0, nx - 1), i1 = math.min(i0 + 1, nx - 1);
      final fx = (gx - i0).clamp(0.0, 1.0);
      final p = row + x * 3;
      final v = o[p];
      final a = luts[j0 * nx + i0], b = luts[j0 * nx + i1];
      final c = luts[j1 * nx + i0], d = luts[j1 * nx + i1];
      final top = a[v] + (b[v] - a[v]) * fx;
      final bottom = c[v] + (d[v] - c[v]) * fx;
      final level = (top + (bottom - top) * fy).round().clamp(0, 255);
      o[p] = level;
      o[p + 1] = level;
      o[p + 2] = level;
    }
  }
}

/// Clip the tall bins to [clipLimit] times their fair share, fold the excess
/// back over the whole tile, and turn what is left into an equalising table.
Uint8List _clipEqualize(Uint32List hist, double clipLimit) {
  const bins = 256;
  final total = hist.fold(0, (a, b) => a + b);
  final limit = math.max(1, (clipLimit * total / bins).round());
  var excess = 0;
  for (var v = 0; v < bins; v++) {
    if (hist[v] > limit) {
      excess += hist[v] - limit;
      hist[v] = limit;
    }
  }
  final share = excess ~/ bins;
  for (var v = 0; v < bins; v++) {
    hist[v] += share;
  }
  var rest = excess - share * bins;
  final step = math.max(1, bins ~/ math.max(1, rest));
  for (var v = 0; rest > 0; v = (v + step) % bins) {
    hist[v]++;
    rest--;
  }

  final lut = Uint8List(bins);
  final denom = math.max(1, total);
  var cdf = 0;
  for (var v = 0; v < bins; v++) {
    cdf += hist[v];
    lut[v] = (cdf * 255 ~/ denom).clamp(0, 255);
  }
  return lut;
}

/// Adaptive threshold on a summed-area box mean, CamScanner-style bw.
///
/// The local mean used to come from a gaussian the width of a sixteenth of the
/// page. At 300dpi that is a 135-tap kernel across eight million pixels —
/// minutes for one page — and a box mean off an integral image costs the same
/// whatever the window, so the window can stay as wide as the page wants.
/// (The SAT holds 255 times the pixel count, which stays inside uint32 because
/// the warp caps a page at one A4 long edge.)
///
/// Thin strokes survive `v > mean - c`, but the interior of a wide dark stroke
/// doesn't (local mean == pixel value). Subtracting the local *contrast* — the
/// mean absolute deviation over the same window — keeps thick-ink interiors
/// dark while paper still clears the bar.
void _adaptiveThreshold(img.Image g, int win, int c) {
  final (o, stride) = _plane(g);
  final w = g.width, h = g.height;
  final n = w * h;
  final gray = Uint8List(n);
  for (var y = 0; y < h; y++) {
    final row = y * stride;
    for (var x = 0; x < w; x++) {
      gray[y * w + x] = o[row + x * 3];
    }
  }

  final sat = Uint32List((w + 1) * (h + 1));
  void fillSat(Uint8List values) {
    for (var y = 0; y < h; y++) {
      var rowSum = 0;
      final above = y * (w + 1), here = above + w + 1;
      for (var x = 0; x < w; x++) {
        rowSum += values[y * w + x];
        sat[here + x + 1] = sat[above + x + 1] + rowSum;
      }
    }
  }

  final half = win ~/ 2;
  void boxMean(Uint8List values, Uint8List out) {
    for (var y = 0; y < h; y++) {
      final y0 = math.max(0, y - half), y1 = math.min(h - 1, y + half) + 1;
      final top = y0 * (w + 1), bottom = y1 * (w + 1);
      for (var x = 0; x < w; x++) {
        final x0 = math.max(0, x - half), x1 = math.min(w - 1, x + half) + 1;
        final area = (y1 - y0) * (x1 - x0);
        final sum = sat[bottom + x1] - sat[top + x1] - sat[bottom + x0] + sat[top + x0];
        out[y * w + x] = sum ~/ area;
      }
    }
  }

  final mean = Uint8List(n);
  fillSat(gray);
  boxMean(gray, mean);

  final dev = Uint8List(n);
  for (var i = 0; i < n; i++) {
    dev[i] = (gray[i] - mean[i]).abs();
  }
  final contrast = Uint8List(n);
  fillSat(dev);
  boxMean(dev, contrast);

  final bin = Uint8List(n);
  for (var i = 0; i < n; i++) {
    bin[i] = gray[i] > mean[i] - c - contrast[i] ? 255 : 0;
  }
  _cleanBins(bin, w, h);
  for (var y = 0; y < h; y++) {
    final row = y * stride;
    for (var x = 0; x < w; x++) {
      final v = bin[y * w + x];
      o[row + x * 3] = v;
      o[row + x * 3 + 1] = v;
      o[row + x * 3 + 2] = v;
    }
  }
}

/// Neighbourhood voting on both sides of the threshold.
///
/// Thresholding a phone photo leaves single-pixel speckle on the paper and
/// pinholes inside the strokes; either one reads as "bad scan" at a glance even
/// when the page geometry is right. A stroke pixel has four or more dark
/// neighbours, so asking for two costs nothing there, while a lone speck has
/// none.
void _cleanBins(Uint8List bin, int w, int h) {
  Uint8List darkCount(Uint8List src) {
    final counts = Uint8List(w * h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        var n = 0;
        for (var dy = -1; dy <= 1; dy++) {
          final yy = y + dy;
          if (yy < 0 || yy >= h) continue;
          for (var dx = -1; dx <= 1; dx++) {
            if (dx == 0 && dy == 0) continue;
            final xx = x + dx;
            if (xx < 0 || xx >= w) continue;
            if (src[yy * w + xx] == 0) n++;
          }
        }
        counts[y * w + x] = n;
      }
    }
    return counts;
  }

  final counts = darkCount(bin);
  for (var i = 0; i < bin.length; i++) {
    if (bin[i] == 0 && counts[i] < 2) bin[i] = 255;
  }
  final holes = darkCount(bin);
  for (var i = 0; i < bin.length; i++) {
    if (bin[i] == 255 && holes[i] >= 7) bin[i] = 0;
  }
}

/// Scale a page onto a centered white A4 canvas.
///
/// [a4Tiers] is why the sheet is not one fixed size: writing 300dpi over a
/// page that only carries 200dpi of real detail costs the phone four times
/// the pixels and comes out softer, not sharper.
img.Image toA4(img.Image page, {int? dpi}) {
  final (a4W, a4H) = a4Tiers[dpi ?? a4DpiFor(page)]!;
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
