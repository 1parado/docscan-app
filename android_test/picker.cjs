/**
 * Driving the system photo picker.
 *
 * On this device `pickMultiImage` is served by com.android.documentsui in
 * `picker.PickActivity`, and it is NOT multi-select: one tap on one row commits
 * that single image and closes the picker. So "import N pages" means opening
 * the picker N times.
 *
 * The grid view gives thumbnails no labels at all, which makes "tap cell 3"
 * unprovable. List view (`列表视图`) exposes each filename as a real node, so we
 * switch to it and select by fixture name — that is what lets a suite pick the
 * tilted or the no-document image on purpose instead of whatever is top-left.
 *
 * Every entry point returns a verdict object rather than throwing on a miss, so
 * a suite reports BLOCKED instead of a false pass when the ROM differs.
 */
'use strict';

const d = require('./driver.cjs');

const PICKER_HINT = /documentsui|mediapicker|photopicker|gallery|provider/i;

const isPicker = () => PICKER_HINT.test(d.foregroundPackage());

const waitForPicker = (timeoutMs = 15000) => {
  const end = Date.now() + timeoutMs;
  while (Date.now() < end) {
    if (isPicker()) return true;
    d.sleep(300);
  }
  return false;
};

const waitForApp = (timeoutMs = 60000) => {
  const end = Date.now() + timeoutMs;
  while (Date.now() < end) {
    if (d.isForeground()) return true;
    d.sleep(400);
  }
  return false;
};

/** Tap 相册 and confirm the picker window actually took focus. */
function open(albumLabel, { attempts = 3, waitMs = 15000 } = {}) {
  if (isPicker()) return { opened: true, pkg: d.foregroundPackage(), already: true };
  let last = null;
  for (let i = 0; i < attempts; i++) {
    // The home view ignores 相册 while the previous import is still in flight
    // (`if (_busy) return`), so a single tap can legitimately do nothing.
    d.tap(albumLabel);
    if (waitForPicker(waitMs)) return { opened: true, pkg: d.foregroundPackage(), tries: i + 1 };
    last = (peek() ?? d.visibleLabels()).map((n) => n.desc || n.text).filter(Boolean);
    d.sleep(4000);
  }
  return {
    opened: false,
    pkg: d.foregroundPackage(),
    tries: attempts,
    visible: last,
    reason: 'tapped 相册 without the picker taking focus (app may still be busy)',
  };
}

/** Accept the runtime permission prompt if it is the thing on screen. */
function grant() {
  const nodes = d.dump();
  for (const label of ['始终允许', '允许', 'ALLOW', 'While using the app']) {
    const n = d.find(label, nodes);
    if (n) {
      d.tapPoint(n.center.x, n.center.y);
      d.sleep(1200);
      return label;
    }
  }
  return null;
}

/**
 * Switch to list view so rows carry filenames. Idempotent: 列表视图 means we are
 * in grid mode, 网格视图 means list mode is already on.
 */
function ensureList() {
  for (let i = 0; i < 5; i++) {
    const nodes = peek();
    if (!nodes) continue;
    if (d.find('网格视图', nodes)) return { list: true };
    const toList = d.find('列表视图', nodes);
    if (!toList) return { list: false, reason: 'no view-mode toggle on this picker' };
    d.tapPoint(toList.center.x, toList.center.y);
    d.sleep(1200);
  }
  return { list: false, reason: 'view mode did not settle on list' };
}

const rows = (nodes) =>
  nodes
    .filter((n) => /(^|\/)title$/.test(n.resource) && /\.(jpe?g|png)/i.test(n.text))
    .map((n) => ({ name: n.text, y: n.center.y }));

/**
 * Read the tree, but give up quietly. The picker window is briefly undumpable
 * while it animates, and `d.dump()` throws on purpose so that an assertion
 * cannot read an empty tree as "that label is absent" — here a missed read is
 * just a missed read, and the loop tries again.
 */
function peek({ retries = 3 } = {}) {
  try {
    return d.dump({ retries });
  } catch (_) {
    d.sleep(1200);
    return null;
  }
}

/**
 * Rows are only tappable between the toolbar and the gesture bar. uiautomator
 * reports a row that has fallen off either edge of the list viewport with a
 * degenerate centre (y = 0), so matching on name alone lets a tap be aimed at
 * the status bar — which the ROM swallows and the picker just stays open.
 */
const band = () => {
  const { h } = d.screenSize();
  return { top: 160, bottom: h - 260 };
};

const inBand = (y) => {
  const b = band();
  return y >= b.top && y <= b.bottom;
};

/** The match for `re` that can actually be tapped, out of every node that names it. */
function tappableRow(nodes, re) {
  const matches = rows(nodes).filter((r) => re.test(r.name));
  return matches.find((r) => inBand(r.y)) ?? null;
}

/**
 * Two rows at a time: a full-screen fling moves ~4 rows, and that is how a
 * target jumps from just below the fold to above the header without ever being
 * inside the band. A small step can never skip an 8-row window.
 */
const nudge = (dir) => {
  const { w, h } = d.screenSize();
  const y = Math.round(h * 0.55);
  d.swipe(Math.round(w / 2), y, Math.round(w / 2), y - (dir === 'up' ? 440 : -440), 320);
};

const rowSignature = (nodes) => rows(nodes).map((r) => `${r.name}:${r.y}`).join('|');

/**
 * Scroll the list until a row whose name matches `re` sits inside the tappable
 * band, capped so a missing fixture says "nudged N times and still no match"
 * instead of hanging. Which way to scroll is decided by the list, not by the
 * clipped row: y = 0 does not say which edge it fell off, and the recent group
 * cannot scroll up at all, so the direction flips whenever a nudge moves
 * nothing.
 */
function findRow(re, { nudges = 14 } = {}) {
  let dir = 'up';
  let prev = null;
  for (let i = 0; i <= nudges; i++) {
    const nodes = peek();
    if (!nodes) continue;
    const hit = tappableRow(nodes, re);
    if (hit) return hit;
    const stray = rows(nodes).find((r) => re.test(r.name));
    const sig = rowSignature(nodes);
    if (stray && stray.y > 0 && stray.y < band().top) dir = 'down';
    else if (prev !== null && sig === prev) dir = dir === 'up' ? 'down' : 'up';
    else dir = 'up';
    prev = sig;
    nudge(dir);
    d.sleep(700);
  }
  return null;
}

/**
 * The list can still be gliding from the last findRow scroll when the tap is
 * issued, and a tap that lands on a gap or on another row leaves the picker
 * open with focus nowhere near the app. So only tap once the same row sits at
 * the same y in two consecutive dumps.
 */
function steadyRow(re, { tries = 8 } = {}) {
  let prev = null;
  for (let i = 0; i < tries; i++) {
    d.sleep(450);
    const nodes = peek();
    if (!nodes) continue;
    const hit = tappableRow(nodes, re);
    if (!hit) return null;
    if (prev && Math.abs(hit.y - prev) <= 4) return hit;
    prev = hit.y;
  }
  return null;
}

/**
 * The row whose name matches `re` in a dump taken right now — a y saved
 * earlier is stale the moment the list glides.
 */
const rowNow = (re) => {
  const nodes = peek();
  return nodes ? tappableRow(nodes, re) : null;
};

/**
 * The clickable row container that `y` falls inside. Tapping the title text's
 * own centre sometimes lands on the divider between two rows, and a tap there
 * is silently swallowed: the picker keeps focus and nothing is committed.
 */
function clickableRow(nodes, y) {
  return (
    nodes
      .filter((n) => {
        const h = n.bounds.y2 - n.bounds.y1;
        return n.clickable && h >= 48 && h <= 260 && n.bounds.y1 <= y && n.bounds.y2 >= y;
      })
      .sort((a, b) => a.bounds.y2 - a.bounds.y1 - (b.bounds.y2 - b.bounds.y1))[0] ?? null
  );
}

/**
 * Commit one tap: locate the fixture row, wait for the list to stop moving,
 * then tap the centre of the clickable row read from that same dump.
 */
function tapRow(re) {
  if (!findRow(re)) return null;
  const found = steadyRow(re) ?? rowNow(re);
  if (!found) return null;
  const screen = d.screenSize();
  const nodes = peek() ?? [];
  const hit = clickableRow(nodes, found.y);
  d.tapPoint(hit ? hit.center.x : Math.round(screen.w / 2), hit ? hit.center.y : found.y);
  return { name: found.name, y: found.y, container: hit ? hit.center.y : null };
}

/** Open the picker and get it into list view — the state every tap needs. */
function openPicker(album) {
  const opened = open(album);
  if (!opened.opened) return { ok: false, stage: 'open', detail: opened };
  grant();
  const mode = ensureList();
  return mode.list ? { ok: true } : { ok: false, stage: 'list-view', detail: mode.reason };
}

/** The app is back and the pipeline has reached a screen we can name. */
function finish(picked, attempts, settleMs) {
  const t0 = Date.now();
  while (Date.now() - t0 < settleMs) {
    const nodes = peek();
    if (nodes) {
      const labels = nodes.map((n) => n.desc || n.text).filter(Boolean);
      if (labels.some((l) => /保存到文档|导出 PDF|未检测到边缘|已拍/.test(l))) {
        return { ok: true, picked: picked?.name ?? null, attempts, ms: Date.now() - t0, labels };
      }
    }
    d.sleep(1000);
  }
  return { ok: false, stage: 'settle', detail: `no app screen within ${settleMs}ms` };
}

/**
 * Commit exactly one image to the app.
 * A swallowed tap does not end the trip: `taps` attempts each re-read the row
 * before tapping, which is the only way to tell "this ROM ignores that tap"
 * from "the row had moved by then".
 */
function takeOne(re, { album = '相册', settleMs = 90000, taps = 3 } = {}) {
  const ready = openPicker(album);
  if (!ready.ok) return ready;

  let tapped = null;
  for (let attempt = 1; attempt <= taps; attempt++) {
    if (isPicker()) {
      tapped = tapRow(re);
      if (!tapped) {
        d.back();
        return { ok: false, stage: 'find', detail: `no visible row matching ${re}` };
      }
    }
    // either we just tapped, or the picker closed between attempts
    if (waitForApp(30000) || d.isForeground()) return finish(tapped, attempt, settleMs);
  }
  return {
    ok: false,
    stage: 'handback',
    detail: `${taps} taps on ${tapped?.name ?? re} left the picker in focus (y=${tapped?.y})`,
    labels: (peek() ?? []).map((n) => n.desc || n.text).filter(Boolean),
  };
}

const cancel = () => {
  if (isPicker()) d.back();
};

/** Manual entry point: `node android_test/picker.cjs docscan_fixture_03` */
if (require.main === module) {
  const want = process.argv[2];
  if (!want) {
    console.log('usage: node android_test/picker.cjs <fixture-name-substring>');
  } else {
    console.log(JSON.stringify(takeOne(new RegExp(want)), null, 2));
  }
}

module.exports = {
  open,
  grant,
  ensureList,
  findRow,
  rows,
  rowNow,
  tappableRow,
  inBand,
  clickableRow,
  tapRow,
  takeOne,
  cancel,
  isPicker,
};
