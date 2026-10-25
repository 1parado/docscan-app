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
 * On this ROM the picker commits a single image per tap. An import only queues
 * the raw photo — the edge warp runs later, at 下一步 — so a page can be deleted
 * or moved before the app spends an isolate on it, and the session view stays up
 * between trips. Collecting N pages means pick → settle, N times. The picker is
 * driven by fixture *name* (see picker.cjs) so a suite can deliberately feed the
 * tilted or the edgeless photo.
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
 * The app is ready for another capture when the idle view (拍摄) or a session
 * (已拍 N 页) is on screen. Queueing is instant, so this is about being on the
 * right screen rather than about the pipeline being busy.
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

/**
 * One album trip, verified. The picker closing is not evidence that a page
 * arrived: a tap issued while the list is still gliding lands on a gap and the
 * picker just stays open. So the trip only counts once the session grows by one,
 * and the whole picker is cancelled and retried until that happens.
 */
function importOnePage(want, { perPageMs = 90000, attempts = 3 } = {}) {
  for (let attempt = 1; attempt <= attempts; attempt++) {
    if (!ensureHome()) return { ok: false, stage: 'home', detail: `cannot reach home before importing ${want}` };
    if (!waitSettled()) return { ok: false, stage: 'busy', detail: `app never went idle before ${want}` };
    const before = sessionCount() ?? 0;
    // takeOne already re-taps once when the picker keeps focus; the second
    // layer here is for the case where the picker opened against a list that
    // had not settled, which needs closing and re-opening rather than another tap.
    const r = picker.takeOne(new RegExp(want), { album: UI.HOME.album, settleMs: perPageMs, taps: 2 });
    if (r.ok) {
      const end = Date.now() + Math.max(perPageMs, 60000);
      while (Date.now() < end) {
        const now = sessionCount();
        if (now != null && now > before) return { ok: true, pages: now, attempt, taken: r };
        d.sleep(900);
      }
    }
    picker.cancel();
    d.sleep(800);
  }
  return {
    ok: false,
    stage: 'verify',
    detail: `${want} never added a page in ${attempts} attempts`,
  };
}

function importPages(pages, { fixtures = DEFAULT_FIXTURES, perPageMs = 90000 } = {}) {
  if (pages > fixtures.length) {
    return { ok: false, stage: 'fixtures', detail: `asked for ${pages} pages, only ${fixtures.length} fixtures available` };
  }
  const taken = [];
  for (const want of fixtures.slice(0, pages)) {
    const r = importOnePage(want, { perPageMs });
    if (!r.ok) return { ok: false, stage: `import:${want}`, detail: r };
    taken.push({ name: r.taken.picked, ms: r.taken.ms, attempt: r.attempt });
  }
  if (!ensureHome()) return { ok: false, stage: 'home', detail: 'cannot return to the session view' };
  return { ok: true, pages: sessionCount(), taken };
}

function resultPages(nodes = d.dump()) {
  return readInt(/(\d+)\s*页\s*·\s*A4/, nodes);
}

/**
 * Press 下一步 and wait for the export screen. The button runs every queued
 * capture through the pipeline — one isolate per page, back to back — so the
 * screen only appears after the last page has landed and the 处理中 counter has
 * counted all the way up.
 */
function openResult({ timeoutMs = 300000 } = {}) {
  if (UI.onScreen(d.dump()) === 'result') return d.waitFor(UI.RESULT.save, { timeoutMs });
  d.tap(UI.HOME.next);
  d.tryWait(UI.HOME.workingPrefix, { timeoutMs: 4000 });
  return d.waitFor(UI.RESULT.save, { timeoutMs });
}

/**
 * Edit mode for the page strip: a long-press on a page's own badge brings up
 * the ◀ × ▶ row for that page, and the hint line says 排序中 while it is up.
 * The badge sits inside the thumbnail's gesture area, so it is the one node on
 * every page that identifies which page a tap will land on.
 */
function longPressPage(index, nodes = d.dump()) {
  const badge = nodes.find((n) => (n.desc || n.text) === String(index + 1));
  if (!badge) return null;
  d.longPressPoint(badge.center.x, badge.center.y);
  d.sleep(900);
  return badge;
}

/** Tap one of a page's handles by the label the app gives it. */
function tapPageAction(label) {
  const n = d.find(label);
  if (!n) return null;
  d.tapPoint(n.center.x, n.center.y);
  d.sleep(800);
  return n;
}

/** x of each page badge in the strip — which slot a thumbnail is in. */
function stripSlots(count = 3, nodes = d.dump()) {
  return Array.from({ length: count }, (_, i) =>
    nodes.find((n) => (n.desc || n.text) === String(i + 1))?.center.x ?? null
  );
}

/**
 * The strip as the user sees it: page badge x per slot, plus the x of every
 * 待裁剪 marker. A page that moved shows up as the marker changing column —
 * thumbnails are pixels, but the marker's slot is a number the dump can prove.
 */
function stripState(nodes = d.dump()) {
  const slots = stripSlots(3, nodes);
  const marked = nodes
    .filter((n) => (n.desc || n.text) === UI.RESULT.cropBadge)
    .map((n) => slots.findIndex((x) => x != null && Math.abs(x - n.center.x) < 60));
  return { slots, marked, pages: resultPages(nodes) };
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
 * Row geometry on the Docs tab.
 *
 * A card's own text never reaches this ROM's uiautomator tree — the whole
 * library screen dumps 9 nodes and none of them is a title — but its two action
 * buttons do, and there is exactly one pair per visible row, so the 删除 button
 * is the only reliable anchor for "the row at this y".
 */
function rowAnchors(nodes = d.dump()) {
  const shares = nodes.filter((n) => (n.desc || '') === UI.DOCS.share);
  return nodes
    .filter((n) => (n.desc || '') === UI.DOCS.delete)
    .map((del) => ({
      y: del.center.y,
      delete: del,
      share: shares.find((s) => Math.abs(s.center.y - del.center.y) < 10) ?? null,
    }))
    .sort((a, b) => a.y - b.y);
}

/** The IME covers the lower rows; only press BACK when it is actually up. */
function hideKeyboard() {
  if (!/mIsInputViewShown=true/.test(d.adb(['shell', 'dumpsys', 'input_method']))) return false;
  d.back();
  d.sleep(600);
  return true;
}

/** Type `query` into the name filter ('' clears it) and report the count shown. */
function setFilter(query) {
  const field = d.dump().find((n) => /EditText/i.test(n.class));
  if (!field) throw new Error('setFilter: no name filter on this screen');
  if (query && /[^\x20-\x7e]/.test(query)) throw new Error(`setFilter: non-ASCII query "${query}"`);
  d.tapPoint(field.center.x, field.center.y);
  d.sleep(700);
  d.clearField(60);
  if (query) d.typeText(query);
  d.sleep(1600);
  hideKeyboard();
  return docCount();
}

/**
 * Which document a row holds, read back from the rename sheet's prefilled
 * field. The sheet is a dialog, and dialog text *does* reach the dump, so this
 * is the only way to name a row on this device. It cancels rather than saves.
 */
function rowTitle(index) {
  const row = rowAnchors()[index];
  if (!row) return null;
  const { w } = d.screenSize();
  d.longPressPoint(Math.round(w * 0.28), row.y);
  d.sleep(1700);
  const nodes = d.dump();
  if (!nodes.some((n) => (n.desc || n.text) === UI.DOCS.renameSheet)) {
    d.back();
    d.sleep(700);
    return null;
  }
  const field = nodes.find((n) => /EditText/i.test(n.class));
  const title = field ? (field.text || field.desc || '').trim() : null;
  const cancel = nodes.find((n) => (n.desc || n.text) === UI.DOCS.cancel);
  if (cancel) d.tapPoint(cancel.center.x, cancel.center.y);
  else d.back();
  d.sleep(900);
  return title;
}

/**
 * The one row that holds document `title`, proved twice over: the app's own
 * name filter narrows the list to it, and the rename sheet reads the exact
 * title back. Returns `{row, count}` or null — never a guess, because the
 * caller is about to delete whatever this points at.
 */
function locateDoc(title) {
  openDocs();
  const count = setFilter(title);
  if (!count) return null;
  const rows = rowAnchors();
  for (let i = 0; i < rows.length; i++) {
    if (rowTitle(i) !== title) continue;
    // The sheet closed; re-read the anchors rather than trusting stale bounds.
    return { row: rowAnchors()[i], count };
  }
  return null;
}

/**
 * Delete the row that reads back as `title`, gated on the app repeating that
 * title in its own confirmation: a row that moved between the dump and the tap
 * is caught here, before anything of the user's is lost, rather than after.
 */
function deleteRowAt(row, title) {
  const before = docCount();
  d.tapPoint(row.delete.center.x, row.delete.center.y);
  d.sleep(1300);
  const nodes = d.dump();
  const ask = nodes.find((n) => /删除「/.test(`${n.desc || ''}${n.text || ''}`));
  const named = ask && /删除「(.+)」/.exec(`${ask.desc || ''}${ask.text || ''}`);
  if (!named || named[1] !== title) {
    d.back();
    throw new Error(`delete dialog names "${named ? named[1] : null}", expected "${title}"`);
  }
  // The dialog repeats 删除 on its confirm button, so aim below the question.
  const confirm = nodes
    .filter((n) => (n.desc || n.text) === UI.DOCS.delete && n.bounds.y1 > ask.bounds.y2)
    .sort((a, b) => a.bounds.y1 - b.bounds.y1)[0];
  if (!confirm) {
    d.back();
    throw new Error(`no confirm button in the delete dialog for "${title}"`);
  }
  d.tapPoint(confirm.center.x, confirm.center.y);
  d.sleep(1600);
  const after = docCount();
  if (after == null || before == null || after !== before - 1) {
    throw new Error(`library went ${before} -> ${after} after deleting one "${title}"`);
  }
  return after;
}

/** Find `title` by name and delete exactly that one document. */
function deleteDoc(title) {
  const hit = locateDoc(title);
  if (!hit) throw new Error(`deleteDoc: no row reads back as "${title}"`);
  const after = deleteRowAt(hit.row, title);
  setFilter('');
  return after;
}

/** True when `input text` can type the string at all — Chinese cannot. */
const typable = (s) => /^[\x20-\x7e]*$/.test(s);

/**
 * The first row whose read-back title satisfies `matches`, as `{index, title}`.
 * This is the only identification available for a title that cannot be typed
 * into the name filter, so it stops at the first hit rather than reading the
 * whole screen back.
 */
function findRow(matches) {
  const rows = rowAnchors();
  for (let i = 0; i < rows.length; i++) {
    const title = rowTitle(i);
    if (title != null && matches(title)) return { i, title };
  }
  return null;
}

/**
 * Delete every document titled `prefix`, one at a time, through the Docs tab's
 * own per-row delete. Suites that create documents have to remove them again —
 * the library is the user's, not the test's.
 *
 * `exact` matters for auto-generated names: "10月25日 扫描 3" is a prefix of
 * "10月25日 扫描 30", so a prefix match here would delete the user's own
 * document. Callers that know the whole title pass `{exact: true}`.
 *
 * An auto-generated name is Chinese, and `input text` cannot type Chinese, so
 * for those the filter is unavailable and every visible row is read back
 * instead. That still reaches the run's own documents and only those: the list
 * is newest-first, so what this run created is on the first page and whatever
 * the user had is not.
 */
function deleteSeeded(prefix, { rounds = 8, exact = false } = {}) {
  const matches = (t) => (exact ? t === prefix : t.startsWith(prefix));
  const filtered = typable(prefix);
  let deleted = 0;
  for (let round = 0; round < rounds; round++) {
    openDocs();
    d.sleep(900);
    if (filtered && !setFilter(prefix)) break;
    // The filter is a substring match, so confirm each candidate's title from
    // its own rename sheet before pointing a delete at it.
    const target = findRow(matches);
    if (!target) {
      if (filtered) setFilter('');
      break;
    }
    deleteRowAt(rowAnchors()[target.i], target.title);
    deleted++;
  }
  if (filtered) setFilter('');
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
  importOnePage,
  openResult,
  resultPages,
  longPressPage,
  tapPageAction,
  stripState,
  exportDoc,
  makeDoc,
  clearSession,
  deleteSeeded,
  tapSessionThumb,
  rowAnchors,
  rowTitle,
  setFilter,
  locateDoc,
  deleteDoc,
  deleteRowAt,
  findRow,
  hideKeyboard,
  settled,
  waitSettled,
  ensureHome,
};
