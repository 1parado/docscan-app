/**
 * Business-flow layer: named app flows composed from primitives, so the suites
 * read as "make a 3-page doc called X" instead of a wall of taps. Anything a
 * flow could not prove throws or returns a verdict object — it never guesses a
 * success.
 *
 * Titles handed to `exportDoc` must be ASCII: `adb shell input text` cannot
 * type CJK, and a suite that silently skipped the rename would prove nothing.
 */
'use strict';

const d = require('./driver.cjs');
const UI = require('./ui.cjs');
const picker = require('./picker.cjs');

/** Read the leading integer out of the first node whose label matches `re`. */
function readInt(re, nodes = d.dump()) {
  for (const n of nodes) {
    const m = re.exec(n.desc || n.text || '');
    if (m) return Number(m[1]);
  }
  return null;
}

const docCount = (nodes) => readInt(/(\d+)\s*个文档/, nodes);
const sessionCount = (nodes) => readInt(/已拍\s*(\d+)\s*页/, nodes);

/** The prefill looks like "10月24日 扫描 2"; the field itself is an EditText. */
function findNameField(nodes = d.dump()) {
  return (
    nodes.find((n) => /EditText/i.test(n.class)) ??
    nodes.find((n) => /\d+月\d+日\s*扫描/.test(n.text || n.desc || ''))
  );
}

function gotoTab(tab) {
  // Unwind first: from the result page or the PDF viewer the bottom tab bar is
  // not on screen at all, so tapping its label would silently do nothing and
  // every later case would report the screen we never left.
  if (!d.visibleLabels().some((l) => l === UI.TABS.scan || l === UI.TABS.docs)) ensureHome();
  d.tap(tab);
  d.sleep(700);
  const screen = UI.onScreen(d.dump());
  const want = tab === UI.TABS.docs ? 'docs' : 'home';
  if (screen !== want) {
    ensureHome();
    d.tap(tab);
    d.sleep(900);
    const retry = UI.onScreen(d.dump());
    if (retry !== want) throw new Error(`gotoTab(${tab}) landed on "${retry}"`);
  }
  return want;
}

const openDocs = () => gotoTab(UI.TABS.docs);
const openScan = () => gotoTab(UI.TABS.scan);

/** Return to the scan tab from anywhere by unwinding the navigation stack. */
function home() {
  if (ensureHome()) return 'home';
  throw new Error('could not reach the home screen with back navigation');
}

function setMode(mode) {
  d.tap(UI.HOME.modes[mode]);
  d.sleep(400);
}

function toggleCrop() {
  d.tap(UI.HOME.autoCrop);
  d.sleep(400);
}

/**
 * Import `pages` photos, one picker trip per page.
 *
 * On this ROM the picker commits a single image per tap, and the app navigates
 * to the result page after every import — so collecting N pages means
 * pick → settle → back-to-home, N times. The picker is driven by fixture *name*
 * (see picker.cjs) so a suite can deliberately feed the tilted or the
 * edgeless photo.
 *
 * Returns a verdict object: `ok:false` means the harness could not prove the
 * import, and callers turn that into BLOCKED rather than a pass.
 */
const DEFAULT_FIXTURES = ['fixture_01', 'fixture_02', 'fixture_03', 'fixture_04', 'fixture_05', 'fixture_06'];

/** Back to the scan tab's own screen without exiting the app at the idle view. */
function ensureHome(trips = 6, settleMs = 60000) {
  const end = Date.now() + settleMs;
  for (let i = 0; i < trips && Date.now() < end; i++) {
    if (!d.isForeground()) {
      // A BACK at the idle view leaves the app; come back instead of tapping
      // into the launcher, which is undumpable on this ROM.
      d.launch();
      d.sleep(2500);
      continue;
    }
    if (settled()) return true;
    const labels0 = d.visibleLabels();
    if (labels0.some((l) => l === UI.TABS.scan || l === UI.TABS.docs)) {
      // A tab switch, not a BACK: from the library the tab bar is the way home,
      // and BACK there pops the activity instead of the tab.
      d.tap(UI.TABS.scan);
      d.sleep(900);
      continue;
    }
    d.back();
    d.sleep(1200);
  }
  return settled();
}

/**
 * The app is between pipeline runs when the idle view (拍摄) or a session
 * (已拍 N 页) is on screen. While it is processing, 相册 taps are dropped, so
 * waiting here is what makes a multi-page import reliable rather than lucky.
 */
function settled(nodes = d.visibleLabels()) {
  return nodes.some((l) => l === UI.HOME.shoot || l.startsWith(UI.HOME.sessionPrefix));
}

function waitSettled(timeoutMs = 90000) {
  const end = Date.now() + timeoutMs;
  while (Date.now() < end) {
    if (d.isForeground() && settled()) return true;
    d.sleep(1000);
  }
  return false;
}

function importPages(pages, { fixtures = DEFAULT_FIXTURES, perPageMs = 90000 } = {}) {
  if (pages > fixtures.length) {
    return { ok: false, stage: 'fixtures', detail: `asked for ${pages} pages, only ${fixtures.length} fixtures available` };
  }
  const taken = [];
  for (const want of fixtures.slice(0, pages)) {
    if (!ensureHome()) return { ok: false, stage: 'home', detail: `cannot reach home before importing ${want}` };
    if (!waitSettled()) return { ok: false, stage: 'busy', detail: `app never went idle before ${want}` };
    const r = picker.takeOne(new RegExp(want), { album: UI.HOME.album, settleMs: perPageMs });
    if (!r.ok) return { ok: false, stage: `import:${want}`, detail: r };
    taken.push({ name: r.picked, ms: r.ms });
    // The app opens the export screen by itself once the album import is done,
    // and 相册 only exists on the home view — so each trip has to step back out
    // of it before the next page can be added.
    if (UI.onScreen(d.dump()) === 'result') {
      d.back();
      d.sleep(1000);
    }
  }
  if (!ensureHome()) return { ok: false, stage: 'home', detail: 'cannot return to the session view' };
  return { ok: true, pages: sessionCount(), taken };
}

function openResult() {
  // An album import opens the export screen by itself, so the session view (and
  // with it 下一步) may already be gone. Navigate only when it is still up.
  if (UI.onScreen(d.dump()) === 'result') return d.waitFor(UI.RESULT.save, { timeoutMs: 12000 });
  d.tap(UI.HOME.next);
  d.waitFor(UI.RESULT.save, { timeoutMs: 12000 });
}

/**
 * Name the doc, save it, then confirm the library really grew. Pass no title to
 * keep the app's auto-generated name.
 */
function exportDoc(title) {
  openResult();
  const before = docCount(d.dump());

  if (title !== undefined && title !== null) {
    if (/[^\x20-\x7e]/.test(title)) throw new Error(`exportDoc: non-ASCII title "${title}"`);
    const field = findNameField();
    if (!field) throw new Error('exportDoc: name field not found on the result page');
    d.tapPoint(field.center.x, field.center.y);
    d.sleep(700);
    d.clearField(60);
    d.typeText(title);
    d.sleep(500);
  }

  d.tap(UI.RESULT.save);
  if (!d.tryWait(UI.RESULT.doneTitle, { timeoutMs: 120000 })) {
    const errs = d.flutterErrors(d.logcatForPid(d.pidof() ?? 0));
    throw new Error(`export did not reach the done state; flutter errors: ${errs.slice(0, 2).join(' || ') || 'none'}`);
  }

  home();
  openDocs();
  const after = docCount();
  if (after == null) throw new Error('library count unreadable after export');
  if (before != null && after <= before) throw new Error(`library count did not grow (${before} -> ${after})`);
  return { title: title ?? 'auto', count: after };
}

const makeDoc = (title, pages = 1) => {
  home();
  const imp = importPages(pages);
  if (!imp.ok) return imp;
  if (pages > 1 && imp.pages < pages) {
    return { ok: false, stage: 'select', detail: `asked for ${pages} pages, session shows ${imp.pages}` };
  }
  return { exported: exportDoc(title), pages: imp.pages };
};

function clearSession() {
  const n = d.find(UI.HOME.clear);
  if (!n) return false;
  d.tapPoint(n.center.x, n.center.y);
  d.sleep(700);
  return sessionCount() == null;
}

/** Tap the Nth page thumbnail in the horizontal session strip. */
function tapSessionThumb(index) {
  const pages = d.dump();
  const badge = pages.find((n) => n.desc === String(index + 1) || n.text === String(index + 1));
  if (!badge) return null;
  d.tapPoint(badge.center.x, badge.center.y);
  return badge;
}

/**
 * Delete every listed document whose title starts with `prefix`, page by page,
 * through the Docs tab's own multi-select. Suites that create documents have to
 * remove them again — the library is the user's, not the test's.
 */
function deleteSeeded(prefix, { rounds = 8 } = {}) {
  let deleted = 0;
  for (let round = 0; round < rounds; round++) {
    openDocs();
    d.sleep(900);
    const seeds = d.dump().filter((n) => (n.desc || '').startsWith(prefix));
    if (seeds.length === 0) break;
    d.tap(UI.DOCS.multiSelect);
    d.sleep(700);
    for (const card of seeds) d.tapPoint(d.screenSize().w / 2, card.center.y);
    d.sleep(500);
    const before = docCount();
    d.tap(UI.DOCS.delete);
    d.sleep(900);
    // The dialog repeats the word 删除 on its confirm button, so aim at the one
    // below the question rather than the toolbar button above it.
    const ask = d.dump().find((n) => /个文档？/.test(`${n.desc || ''} ${n.text || ''}`));
    if (!ask) throw new Error(`no delete confirmation after selecting ${seeds.length} rows`);
    const confirm = d
      .dump()
      .filter((n) => (n.desc || '') === UI.DOCS.delete && n.bounds.y1 > ask.bounds.y2)
      .sort((a, b) => b.bounds.x1 - a.bounds.x1)[0];
    if (!confirm) throw new Error('confirm button missing from the delete dialog');
    d.tapPoint(confirm.center.x, confirm.center.y);
    d.sleep(1500);
    const after = docCount();
    if (after != null && before != null && after >= before) {
      throw new Error(`library did not shrink (${before} -> ${after})`);
    }
    deleted += seeds.length;
  }
  home();
  return deleted;
}

module.exports = {
  readInt,
  docCount,
  sessionCount,
  findNameField,
  gotoTab,
  openDocs,
  openScan,
  home,
  setMode,
  toggleCrop,
  importPages,
  openResult,
  exportDoc,
  makeDoc,
  clearSession,
  deleteSeeded,
  tapSessionThumb,
  settled,
  waitSettled,
  ensureHome,
};
