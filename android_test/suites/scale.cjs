/**
 * Scale test: what happens when the library stops being three documents.
 *
 * The README promises a document library, so the interesting failure mode is
 * the one that only appears at 100+ docs: the overview strip, the paginated
 * list, memory while decoding thumbnails, and how long the tab takes to come
 * back. Seeding goes through the real export path, so it is slow and resumable
 * by design — run it once, then re-run to measure.
 *
 * Knobs: DOCS_TARGET (default 20 — one seeded document costs about a minute of
 * real album import plus export, so 60 would be an hour), FIXTURE_PAGES for the
 * big-session test. Whatever gets seeded is deleted again by S11.
 */
'use strict';

const d = require('../driver.cjs');
const UI = require('../ui.cjs');
const f = require('../flows.cjs');
const { Suite, must } = require('../harness.cjs');

const TARGET = Number(process.env.DOCS_TARGET || 20);
const OVERFLOW_RE = /overflowed by [\d.]+ pixels|RenderFlex overflow/i;

/** Every on-screen page-number button, so geometry can be judged. */
function pageButtons(nodes, screen) {
  return nodes
    .filter((n) => /^\d{1,3}$/.test(n.desc || '') && n.bounds.y1 > screen.h * 0.6 && n.bounds.y2 < screen.h)
    .sort((a, b) => a.bounds.x1 - b.bounds.x1);
}

function jank() {
  const out = d.adb(['shell', 'dumpsys', 'gfxinfo', d.PKG]);
  const j = /Janky frames:\s*(\d+)\s*\(([\d.]+)%\)/.exec(out);
  const total = /Total frames rendered:\s*(\d+)/.exec(out);
  return {
    janky: j ? Number(j[1]) : null,
    pct: j ? Number(j[2]) : null,
    total: total ? Number(total[1]) : null,
  };
}

const resetGfx = () => d.adb(['shell', 'dumpsys', 'gfxinfo', d.PKG, 'reset']);

module.exports = function scale() {
  const s = new Suite('scale');
  const screen = d.screenSize();

  s.test('S1 baseline library size', () => {
    f.openDocs();
    const n = f.docCount();
    must(n != null, 'the Docs tab does not report a document count');
    s.note(`starting library: ${n} documents, target ${TARGET}`);
    return `${n} docs present`;
  });

  s.test('S2 seed the library up to the target', () => {
    let count = (() => { f.openDocs(); return f.docCount(); })();
    if (count >= TARGET) return `already at ${count} >= ${TARGET}`;
    if (!f.importPages(1).ok) return s.skip(`picker is untuned; cannot seed ${TARGET - count} docs automatically`);
    f.clearSession();
    const t0 = Date.now();
    for (let i = count; i < TARGET; i++) {
      f.home();
      const imp = f.importPages(1);
      if (!imp.ok) {
        s.note(`stopped seeding at ${i} docs: blocked at "${imp.stage}"`);
        break;
      }
      f.exportDoc(`qa-scale-${String(i + 1).padStart(3, '0')}`);
      if (i % 10 === 0) s.note(`seeded ${i + 1}/${TARGET} in ${((Date.now() - t0) / 1000).toFixed(0)}s`);
    }
    f.openDocs();
    count = f.docCount();
    return `library now ${count} docs`;
  });

  s.test('S3 the paginated list does not overflow its row', () => {
    const before = d.logcatForPid(d.pidof() ?? 0);
    f.openDocs();
    d.sleep(1200);
    const nodes = d.dump();
    const btns = pageButtons(nodes, screen);
    if (btns.length === 0) {
      const count = f.docCount();
      must(count <= 10, `${count} docs but no pagination controls at all`);
      return s.skip(`fewer than ${11} documents — pagination never engages`);
    }
    const right = btns[btns.length - 1].bounds.x2;
    must(right <= screen.w, `last page button ends at x=${right} on a ${screen.w}px-wide screen — clipped`);
    const overlap = btns.some((b, i) => i > 0 && b.bounds.x1 < btns[i - 1].bounds.x2);
    must(!overlap, 'page buttons overlap each other');
    s.shot(`pagination_${f.docCount()}docs`);
    const after = d.logcatForPid(d.pidof() ?? 0);
    const fresh = after.split('\n').filter((l) => !before.includes(l));
    const overflow = fresh.filter((l) => OVERFLOW_RE.test(l));
    must(overflow.length === 0, `RenderFlex overflow at ${btns.length} page buttons: ${overflow[0].slice(0, 160)}`);
    return `${btns.length} page buttons fit`;
  });

  s.test('S4 jumping to the last page works at scale', () => {
    const btns = pageButtons(d.dump(), screen);
    if (btns.length < 2) return s.skip('only one page of results');
    const last = btns[btns.length - 1];
    d.tapPoint(last.center.x, last.center.y);
    d.sleep(1400);
    const nodes = d.dump();
    const shown = nodes.filter((n) => (n.desc || '').startsWith('qa-scale-'));
    must(shown.length > 0, `page ${last.desc} shows no documents`);
    s.shot('last_page');
    return `page ${last.desc} shows ${shown.length} docs`;
  });

  s.test('S5 name filter stays usable with a full library', () => {
    const field = d.dump().find((n) => /EditText/i.test(n.class));
    must(field, 'filter field not found');
    const t0 = Date.now();
    d.tapPoint(field.center.x, field.center.y);
    d.sleep(500);
    d.clearField(40);
    d.typeText('qa-scale-005');
    d.sleep(1500);
    const shown = d.dump().filter((n) => (n.desc || '').startsWith('qa-scale-'));
    const ms = Date.now() - t0;
    must(shown.length === 1, `filter "qa-scale-005" matched ${shown.length} rows`);
    s.note(`filter round-trip took ${ms}ms with ${f.docCount()} documents`);
    d.back();
    d.clearField(40);
    d.sleep(800);
    return `1 match in ${ms}ms`;
  });

  s.test('S6 scrolling a long list stays smooth', () => {
    const list = d.dump().find((n) => n.scrollable);
    must(list, 'the document list is not reported as scrollable');
    resetGfx();
    const before = d.meminfo();
    for (let i = 0; i < 14; i++) {
      d.swipe(list.center.x, list.bounds.y2 - 80, list.center.x, list.bounds.y1 + 80, 160);
      d.sleep(220);
    }
    d.sleep(800);
    const j = jank();
    const after = d.meminfo();
    s.shot('scrolled_list');
    s.note(`jank ${j.janky}/${j.total} frames (${j.pct}%), PSS ${(before.totalPssKb / 1024).toFixed(0)} -> ${(after.totalPssKb / 1024).toFixed(0)}MB`);
    must(j.total == null || j.janky / j.total < 0.35, `${j.pct}% of frames janky while scrolling`);
    must(after.totalPssKb < 620_000, `PSS grew to ${(after.totalPssKb / 1024).toFixed(0)}MB while scrolling thumbnails`);
    return `jank ${j.pct}%`;
  });

  s.test('S7 switching to the Docs tab is not visibly blocking', () => {
    f.home();
    d.sleep(600);
    resetGfx();
    const t0 = Date.now();
    d.tap(UI.TABS.docs);
    d.waitFor(UI.DOCS.countPrefix, { timeoutMs: 10000 });
    const ms = Date.now() - t0;
    const j = jank();
    s.note(`tab switch ${ms}ms, janky ${j.janky}/${j.total}`);
    must(ms < 4000, `Docs tab took ${ms}ms to paint with ${f.docCount()} documents`);
    return `${ms}ms to first paint`;
  });

  s.test('S8 the home overview stays bounded as the library grows', () => {
    f.openScan();
    d.sleep(1200);
    const nodes = d.dump();
    const recentsTitle = nodes.find((n) => (n.desc || '').includes(UI.HOME.recents));
    if (!recentsTitle) return s.skip('no "最近的文档" header on the home screen');
    const cards = nodes.filter(
      (n) => n.desc && n.bounds.y1 >= recentsTitle.bounds.y1 && n.bounds.y1 < recentsTitle.bounds.y1 + 480 &&
        !/扫描|文档|彩色|灰度|黑白|裁边|DocScan|最近的文档/.test(n.desc)
    );
    s.shot('home_with_full_library');
    must(cards.length <= 8, `the home overview renders ${cards.length} cards — it is not bounded`);
    const overflow = d.logcatForPid(d.pidof() ?? 0).split('\n').filter((l) => OVERFLOW_RE.test(l));
    must(overflow.length === 0, `home overview overflowed: ${overflow[0]?.slice(0, 160)}`);
    return `${cards.length} cards shown of ${f.docCount()}`;
  });

  s.test('S9 a large single session does not exhaust memory', () => {
    f.home();
    if (f.sessionCount() != null) f.clearSession();
    const imp = f.importPages(Number(process.env.FIXTURE_PAGES || 6));
    if (!imp.ok) return s.skip(`picker blocked at "${imp.stage}"`);
    const m = d.meminfo();
    s.shot(`session_${imp.pages}p`);
    must(m.totalPssKb < 700_000, `${imp.pages} page thumbnails pushed PSS to ${(m.totalPssKb / 1024).toFixed(0)}MB`);
    f.clearSession();
    return `${imp.pages} pages, PSS ${(m.totalPssKb / 1024).toFixed(0)}MB`;
  });

  s.test('S10 no overflow or framework errors at scale', () => {
    const text = d.logcatForPid(d.pidof() ?? 0);
    const overflow = text.split('\n').filter((l) => OVERFLOW_RE.test(l));
    must(overflow.length === 0, `overflow logged: ${overflow[0]?.slice(0, 180)}`);
    const errs = d.flutterErrors(text);
    must(errs.length === 0, `flutter errors: ${errs.slice(0, 3).join(' || ')}`);
    return 'clean';
  });

  // Seeding writes real files into the user's own library, so the suite that
  // creates them has to remove them again — batch delete is the only path a
  // user has, and it is the same path this test then gets to prove at scale.
  s.test('S11 seeded test documents are cleaned up', () => {
    const removed = [];
    for (let round = 0; round < 8; round++) {
      f.openDocs();
      d.sleep(900);
      const seeds = d.dump().filter((n) => (n.desc || '').startsWith('qa-scale-'));
      if (seeds.length === 0) break;
      d.tap(UI.DOCS.multiSelect);
      d.sleep(700);
      for (const card of seeds) d.tapPoint(screen.w / 2, card.center.y);
      d.sleep(500);
      const before = f.docCount();
      d.tap(UI.DOCS.delete);
      d.sleep(900);
      // The dialog repeats the word 删除 on its confirm button, so aim at the
      // one that sits under the question instead of the toolbar button.
      const ask = d.dump().find((n) => /个文档？/.test(n.desc || n.text || ''));
      must(ask, `no delete confirmation after selecting ${seeds.length} rows`);
      const confirm = d
        .dump()
        .filter((n) => (n.desc || '') === UI.DOCS.delete && n.bounds.y1 > ask.bounds.y2)
        .sort((a, b) => b.bounds.x1 - a.bounds.x1)[0];
      must(confirm, 'confirm button missing from the delete dialog');
      d.tapPoint(confirm.center.x, confirm.center.y);
      d.sleep(1500);
      removed.push(seeds.length);
      const after = f.docCount();
      must(after < before, `library did not shrink (${before} -> ${after})`);
    }
    f.home();
    if (removed.length === 0) return 'nothing to clean up';
    return `${removed.reduce((a, b) => a + b, 0)} seeded docs deleted in ${removed.length} round(s)`;
  });

  return s.write();
};
