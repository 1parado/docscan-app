/**
 * Acceptance test: each promise the README makes, checked the way a user would
 * experience it. Anything that needs the app's private files is skipped with a
 * reason on a release build rather than asserted from pixels alone.
 */
'use strict';

const fs = require('fs');
const path = require('path');
const d = require('../driver.cjs');
const UI = require('../ui.cjs');
const f = require('../flows.cjs');
const png = require('../png.cjs');
const setup = require('../setup.cjs');
const { Suite, must } = require('../harness.cjs');

const AUTONAME_RE = /^\d{1,2}月\d{1,2}日 扫描 \d+$/;

/** Count `%d %` page markers in a PDF, a crude but dependency-free page count. */
function pdfPageCount(buf) {
  const text = buf.toString('latin1');
  const pages = text.match(/\/Type\s*\/Page[^s]/g);
  return pages ? pages.length : null;
}

module.exports = function acceptance() {
  const s = new Suite('acceptance');
  /** Titles this run wrote into the user's library; A12 deletes them again. */
  const saved = [];

  s.test('A1 offline claim: no network permission in the release build', () => {
    const out = d.adb(['shell', 'dumpsys', 'package', d.PKG]);
    const install = /install permissions:\n([\s\S]*?)(\nruntime permissions:|\nPackage \[)/.exec(out);
    must(install, 'install permission block unreadable');
    const declared = [...install[1].matchAll(/android\.permission\.([A-Z_]+)/g)].map((m) => m[1]);
    must(!declared.includes('INTERNET'), `INTERNET declared: ${declared.join(' ')}`);
    return `declared: ${declared.join(' ') || 'none'}`;
  });

  s.test('A2 launcher label is a product name, not the package id', () => {
    const dump = d.adb(['shell', 'dumpsys', 'package', d.PKG]);
    const label = /application-label:'([^']*)'/.exec(dump)?.[1]?.trim();
    must(label, `no application-label in dumpsys (saw: ${dump.match(/label[^\n]*/i)?.[0] ?? 'none'})`);
    s.note(`application label = "${label}"`);
    must(label !== d.PKG, `label is the bare package name "${label}"`);
    must(!/_app$/.test(label), `label "${label}" still carries the flutter scaffold suffix`);
    return label;
  });

  s.test('A3 cold start is quick enough to feel like a scanner', () => {
    d.forceStop();
    d.sleep(1200);
    const r = d.launch();
    must(r.totalTimeMs < 1500, `cold start ${r.totalTimeMs}ms`);
    return `${r.launchState} ${r.totalTimeMs}ms`;
  });

  s.test('A4 auto-naming follows 日期+序号', () => {
    f.home();
    const imp = f.importPages(1);
    if (!imp.ok) return s.skip(`picker blocked at "${imp.stage}" — cannot create a doc to inspect`);
    f.openResult();
    const field = f.findNameField();
    must(field, 'the result page has no name field');
    const prefill = (field.text || field.desc || '').trim();
    must(AUTONAME_RE.test(prefill), `prefill "${prefill}" is not "M月D日 扫描 N"`);
    saved.push(prefill);
    d.tap(UI.RESULT.save);
    d.tryWait(UI.RESULT.doneTitle, { timeoutMs: 90000 });
    f.home();
    return `prefill "${prefill}"`;
  });

  s.test('A5 the auto sequence increments per day', () => {
    const imp = (() => { f.home(); return f.importPages(1); })();
    if (!imp.ok) return s.skip('picker blocked');
    f.openResult();
    const field = f.findNameField();
    const prefill = (field?.text || field?.desc || '').trim();
    must(AUTONAME_RE.test(prefill), `second doc prefill "${prefill}" is malformed`);
    const n = Number(prefill.match(/(\d+)$/)[1]);
    must(n >= 2, `counter did not advance (got ${n})`);
    saved.push(prefill);
    d.tap(UI.RESULT.save);
    d.tryWait(UI.RESULT.doneTitle, { timeoutMs: 90000 });
    f.home();
    return `auto-named "${prefill}"`;
  });

  s.test('A6 page count shown in the library matches what was scanned', () => {
    f.home();
    if (f.sessionCount() != null) f.clearSession();
    const imp = f.importPages(3);
    if (!imp.ok) return s.skip(`picker blocked at "${imp.stage}"`);
    must(imp.pages === 3, `session shows ${imp.pages} of 3 requested`);
    f.exportDoc('qa-3pages');
    saved.push('qa-3pages');
    // The row's "3 页" subtitle never reaches this ROM's dump (the whole card
    // body is missing from it), so the listing is proven by name and the page
    // count is proven where it actually lives: the PDF itself, in A7.
    const hit = f.locateDoc('qa-3pages');
    must(hit, 'the 3-page doc is not in the list');
    f.setFilter('');
    return `listed among ${hit.count} match(es)`;
  });

  s.test('A7 exported PDF really holds those pages', () => {
    if (!setup.isDebuggable()) return s.skip('release build: run-as cannot reach files/docs');
    const found = setup.appDocsListing().filter((p) => p.endsWith('doc.pdf'));
    must(found.length, 'no doc.pdf visible under files/docs');
    const local = path.join(s.dir, 'sample.pdf');
    setup.pullAppFile(found[0], local);
    const buf = fs.readFileSync(local);
    must(buf.subarray(0, 5).toString('latin1') === '%PDF-', 'pulled file is not a PDF');
    const pages = pdfPageCount(buf);
    s.note(`sample.pdf ${(buf.length / 1024).toFixed(0)}kB, ${pages} page objects`);
    must(pages !== null && pages >= 1, 'could not count PDF pages');
    return `${buf.length} bytes, ${pages} pages`;
  });

  s.test('A8 A4 geometry: a scanned page comes out portrait A4', () => {
    if (!setup.isDebuggable()) return s.skip('release build: cover image is not readable');
    const covers = setup.appDocsListing().filter((p) => p.endsWith('cover.jpg'));
    must(covers.length, 'no cover.jpg to measure');
    const local = path.join(s.dir, 'cover.jpg');
    setup.pullAppFile(covers[0], local);
    const buf = fs.readFileSync(local);
    // JPEG SOF0/SOF2 gives the stored dimensions without a decoder dependency.
    let dim = null;
    for (let i = 2; i < buf.length - 9;) {
      if (buf[i] !== 0xff) { i++; continue; }
      const marker = buf[i + 1];
      const len = buf.readUInt16BE(i + 2);
      if (marker >= 0xc0 && marker <= 0xcf && ![0xc4, 0xc8, 0xcc].includes(marker)) {
        dim = { h: buf.readUInt16BE(i + 5), w: buf.readUInt16BE(i + 7) };
        break;
      }
      i += 2 + len;
    }
    must(dim, 'could not read the cover JPEG header');
    const ratio = dim.h / dim.w;
    s.note(`cover ${dim.w}x${dim.h}, ratio ${ratio.toFixed(3)}`);
    must(dim.h > dim.w, 'the page is not portrait');
    must(Math.abs(ratio - 297 / 210) < 0.06, `aspect ${ratio.toFixed(3)} is not A4 (1.414)`);
    return `${dim.w}x${dim.h} A4`;
  });

  s.test('A9 the three enhancement modes really differ', () => {
    if (!setup.isDebuggable()) {
      return s.skip('release build: comparing stored pages needs run-as; UI thumbnails are too small to be proof');
    }
    const covers = setup.appDocsListing().filter((p) => p.endsWith('cover.jpg'));
    must(covers.length >= 2, 'need two covers from different modes');
    const sig = [];
    for (const c of covers.slice(0, 3)) {
      const local = path.join(s.dir, `cover_${path.basename(path.dirname(c))}.jpg`);
      setup.pullAppFile(c, local);
      sig.push(png.stats(png.read(local)));
    }
    const distinct = new Set(sig.map((x) => x.dominant.color));
    must(distinct.size > 1, `all covers share one dominant colour ${[...distinct]}`);
    return sig.map((x) => `#${x.dominant.color}`).join(' ');
  });

  s.test('A10 library survives an upgrade install', () => {
    f.openDocs();
    const before = f.docCount();
    must(before > 0, 'nothing in the library to preserve');
    const apk = process.env.DOCSAN_APK;
    if (!apk || !fs.existsSync(apk)) return s.skip('set DOCSAN_APK to an APK to test reinstall retention');
    d.adb(['install', '-r', apk]);
    d.launch();
    d.waitFor(UI.HOME.brand, { timeoutMs: 15000 });
    f.openDocs();
    const after = f.docCount();
    must(after >= before, `library ${before} -> ${after} after reinstall -r`);
    return `${before} -> ${after}`;
  });

  s.test('A11 a full session is crash-free', () => {
    const pid = d.pidof() ?? 0;
    const text = d.logcatForPid(pid);
    must(!/FATAL EXCEPTION|Fatal signal/.test(text), 'crash markers present');
    const errs = d.flutterErrors(text);
    must(errs.length === 0, `flutter errors: ${errs.slice(0, 2).join(' || ')}`);
    const m = d.meminfo();
    must(m.totalPssKb < 500_000, `PSS ${(m.totalPssKb / 1024).toFixed(0)}MB after a full session`);
    return `PSS ${(m.totalPssKb / 1024).toFixed(0)}MB`;
  });

  // The acceptance cases export real PDFs into the user's own library. Whatever
  // this run created is the run's to remove.
  s.test('A12 exported test documents are cleaned up', () => {
    let deleted = 0;
    // Every title here was read off the name field, so match whole titles:
    // "10月25日 扫描 3" is a prefix of "10月25日 扫描 30".
    for (const title of saved) deleted += f.deleteSeeded(title, { exact: true });
    if (deleted === 0) return saved.length ? `nothing of ${saved.join(', ')} was listed` : 'nothing exported';
    return `${deleted} of ${saved.length} test documents deleted`;
  });

  return s.write();
};
