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
    last = d.visibleLabels();
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
  for (let i = 0; i < 3; i++) {
    const nodes = d.dump();
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
 * Scroll the list until a row whose name matches `re` is visible.
 * One swipe per iteration, capped, so a missing fixture says "scrolled N times
 * and still no match" instead of hanging.
 */
function findRow(re, { scrolls = 8 } = {}) {
  for (let i = 0; i <= scrolls; i++) {
    const nodes = d.dump();
    const hit = rows(nodes).find((r) => re.test(r.name));
    if (hit) return hit;
    d.scrollScreen('up');
    d.sleep(900);
  }
  return null;
}

/**
 * The list can still be gliding from the last findRow scroll when the tap is
 * issued, and a tap that lands on a gap or on another row leaves the picker
 * open with focus nowhere near the app. So only tap once the same row sits at
 * the same y in two consecutive dumps.
 */
function steadyRow(re, { tries = 6 } = {}) {
  let prev = null;
  for (let i = 0; i < tries; i++) {
    d.sleep(450);
    const hit = rows(d.dump()).find((r) => re.test(r.name));
    if (!hit) return null;
    if (prev && Math.abs(hit.y - prev) <= 4) return hit;
    prev = hit.y;
  }
  return null;
}

/**
 * Commit exactly one image to the app.
 * `settle` waits for the app to come back and for the pipeline to reach a
 * screen we can name, because a picker tap returns long before processing ends.
 */
function takeOne(re, { album = '相册', settleMs = 90000 } = {}) {
  const opened = open(album);
  if (!opened.opened) return { ok: false, stage: 'open', detail: opened };
  grant();

  const mode = ensureList();
  if (!mode.list) return { ok: false, stage: 'list-view', detail: mode.reason };

  let row = findRow(re);
  if (!row) {
    d.back();
    return { ok: false, stage: 'find', detail: `no visible row matching ${re}` };
  }
  row = steadyRow(re) || row;

  const screen = d.screenSize();
  d.tapPoint(Math.round(screen.w / 2), row.y);

  if (!waitForApp(30000)) return { ok: false, stage: 'handback', detail: 'picker kept focus' };

  const t0 = Date.now();
  let landed = null;
  while (Date.now() - t0 < settleMs) {
    const labels = d.visibleLabels();
    if (labels.some((l) => /保存到文档|导出 PDF|未检测到边缘|已拍/.test(l))) {
      landed = labels;
      break;
    }
    d.sleep(1000);
  }
  if (!landed) return { ok: false, stage: 'settle', detail: `no app screen within ${settleMs}ms` };
  return { ok: true, picked: row.name, ms: Date.now() - t0, labels: landed };
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

module.exports = { open, grant, ensureList, findRow, rows, takeOne, cancel, isPicker };
