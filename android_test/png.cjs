/**
 * Minimal PNG reader (8-bit, non-interlaced) so a screenshot becomes data
 * rather than an attachment: blank-screen detection and colour assertions both
 * need pixels. Android's `screencap -p` always emits RGBA8, which is what this
 * covers; anything else throws instead of guessing.
 */
'use strict';

const zlib = require('zlib');
const fs = require('fs');

const SIG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

function decode(buf) {
  if (buf.subarray(0, 8).compare(SIG) !== 0) throw new Error('not a PNG');
  let off = 8;
  let ihdr = null;
  const idat = [];
  while (off < buf.length) {
    const len = buf.readUInt32BE(off);
    const type = buf.toString('ascii', off + 4, off + 8);
    const data = buf.subarray(off + 8, off + 8 + len);
    if (type === 'IHDR') {
      ihdr = {
        width: data.readUInt32BE(0),
        height: data.readUInt32BE(4),
        bitDepth: data[8],
        colorType: data[9],
        interlace: data[12],
      };
    } else if (type === 'IDAT') idat.push(Buffer.from(data));
    else if (type === 'IEND') break;
    off += 12 + len;
  }
  if (!ihdr) throw new Error('PNG without IHDR');
  if (ihdr.bitDepth !== 8 || ihdr.interlace !== 0) {
    throw new Error(`unsupported PNG (bitDepth=${ihdr.bitDepth} interlace=${ihdr.interlace})`);
  }
  const channels = { 0: 1, 2: 3, 4: 2, 6: 4 }[ihdr.colorType];
  if (!channels) throw new Error(`unsupported colour type ${ihdr.colorType}`);

  const { width: w, height: h } = ihdr;
  const raw = zlib.inflateSync(Buffer.concat(idat));
  const stride = w * channels;
  const out = Buffer.alloc(h * stride);
  const bpp = channels;

  let p = 0;
  for (var y = 0; y < h; y++) {
    const filter = raw[p++];
    const row = out.subarray(y * stride, y * stride + stride);
    const prev = y > 0 ? out.subarray((y - 1) * stride, (y - 1) * stride + stride) : null;
    for (var x = 0; x < stride; x++) {
      const v = raw[p + x];
      const a = x >= bpp ? row[x - bpp] : 0;
      const b = prev ? prev[x] : 0;
      const c = prev && x >= bpp ? prev[x - bpp] : 0;
      let value;
      switch (filter) {
        case 0: value = v; break;
        case 1: value = v + a; break;
        case 2: value = v + b; break;
        case 3: value = v + ((a + b) >> 1); break;
        case 4: {
          const pp = a + b - c;
          const pa = Math.abs(pp - a), pb = Math.abs(pp - b), pc = Math.abs(pp - c);
          value = v + (pa <= pb && pa <= pc ? a : pb <= pc ? b : c);
          break;
        }
        default: throw new Error(`bad filter ${filter}`);
      }
      row[x] = value & 0xff;
    }
    p += stride;
  }
  return { width: w, height: h, channels, data: out };
}

const read = (file) => decode(fs.readFileSync(file));

/** Normalise any channel layout to RGBA for callers. */
function toRgba(img) {
  const { width: w, height: h, channels, data } = img;
  if (channels === 4) return { width: w, height: h, data };
  const out = Buffer.alloc(w * h * 4);
  for (let i = 0, o = 0; i < w * h; i++, o += 4) {
    if (channels === 1) { out[o] = out[o + 1] = out[o + 2] = data[i]; out[o + 3] = 255; }
    else if (channels === 2) { out[o] = out[o + 1] = out[o + 2] = data[i * 2]; out[o + 3] = data[i * 2 + 1]; }
    else { out[o] = data[i * 3]; out[o + 1] = data[i * 3 + 1]; out[o + 2] = data[i * 3 + 2]; out[o + 3] = 255; }
  }
  return { width: w, height: h, data: out };
}

const hex = (r, g, b) => ((r << 16) | (g << 8) | b).toString(16).padStart(6, '0');

/** Sampled stats: cheap uniformity check that still catches a flat screen. */
function stats(img) {
  const { width: w, height: h, data } = toRgba(img);
  const counts = new Map();
  let n = 0;
  const step = Math.max(1, Math.floor(Math.sqrt((w * h) / 60000)));
  for (let y = 0; y < h; y += step) {
    for (let x = 0; x < w; x += step) {
      const i = (y * w + x) * 4;
      const key = hex(data[i], data[i + 1], data[i + 2]);
      counts.set(key, (counts.get(key) ?? 0) + 1);
      n++;
    }
  }
  const top = [...counts.entries()].sort((a, b) => b[1] - a[1]);
  return {
    sampled: n,
    distinct: counts.size,
    dominant: top[0] ? { color: top[0][0], share: top[0][1] / n } : null,
    top5: top.slice(0, 5).map(([c, k]) => ({ color: c, share: k / n })),
  };
}

/** Fraction of sampled pixels within `tol` of the target colour. */
function colorShare(img, targetHex, tol = 26) {
  const { width: w, height: h, data } = toRgba(img);
  const t = [0, 2, 4].map((i) => parseInt(targetHex.slice(i, i + 2), 16));
  let hit = 0;
  let n = 0;
  const step = Math.max(1, Math.floor(Math.sqrt((w * h) / 60000)));
  for (let y = 0; y < h; y += step) {
    for (let x = 0; x < w; x += step) {
      const i = (y * w + x) * 4;
      n++;
      if (
        Math.abs(data[i] - t[0]) <= tol &&
        Math.abs(data[i + 1] - t[1]) <= tol &&
        Math.abs(data[i + 2] - t[2]) <= tol
      ) hit++;
    }
  }
  return n ? hit / n : 0;
}

/**
 * Fraction of sampled pixels in `region` that changed between two shots.
 * Lets a suite prove a control did something without hard-coding the colour
 * or glyph the current design happens to use.
 */
function diffRatio(before, after, region) {
  const a = toRgba(before);
  const b = toRgba(after);
  if (a.width !== b.width || a.height !== b.height) throw new Error('diff: size mismatch');
  const r = region ?? { x1: 0, y1: 0, x2: a.width, y2: a.height };
  let changed = 0;
  let n = 0;
  for (let y = r.y1; y < r.y2; y += 2) {
    for (let x = r.x1; x < r.x2; x += 2) {
      const i = (y * a.width + x) * 4;
      n++;
      if (
        Math.abs(a.data[i] - b.data[i]) > 6 ||
        Math.abs(a.data[i + 1] - b.data[i + 1]) > 6 ||
        Math.abs(a.data[i + 2] - b.data[i + 2]) > 6
      ) changed++;
    }
  }
  return n ? changed / n : 0;
}

module.exports = { read, decode, stats, colorShare, diffRatio, toRgba, hex };
