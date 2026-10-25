/**
 * System test: does every advertised flow actually work on a real phone?
 *
 * Covers navigation, the capture controls, the album import path, cropping,
 * export and the whole Docs tab. The camera is exercised as far as the
 * viewfinder because nobody is holding paper over the lens; the album path runs
 * the same pipeline and is what a repeatable suite can drive.
 *
 * Control state is verified by pixel change inside the control's own bounds,
 * not by a hard-coded colour, so a redesign does not automatically mean a false
 * failure.
 */
'use strict';

const d = require('../driver.cjs');
const UI = require('../ui.cjs');
const f = require('../flows.cjs');
const png = require('../png.cjs');
const setup = require('../setup.cjs');
const { Suite, must } = require('../harness.cjs');

const bandOf = (chip) => ({
  x1: Math.max(0, chip.bounds.x1 - 80),
  y1: Math.max(0, chip.bounds.y1 - 8),
  x2: Math.min(chip.bounds.x2 + 140, 10000),
  y2: chip.bounds.y2 + 8,
});

module.exports = function system() {
  const s = new Suite('system');
  const modeRefs = {};
  let band = null;
  let pickerBlocked = null;

  /** Everything after the first album import depends on the picker working. */
  const gated = (title, fn) =>
    s.test(title, () => {
      if (pickerBlocked) return s.skip(`blocked earlier: ${pickerBlocked}`);
      try {
        return fn();
      } catch (e) {
        if (/picker|stage/.test(String(e.message))) pickerBlocked = String(e.message);
        throw e;
      }
    });

  s.test('preflight: fixtures generated and pushed', () => {
    let files = setup.listFixtures();
    if (files.length === 0) files = setup.generateFixtures(6);
    must(files.length >= 2, `only ${files.length} fixtures generated`);
    const pushed = setup.pushFixtures(files);
    return `${pushed} fixtures in ${setup.REMOTE_DIR}`;
  });

  s.test('tabs switch between 扫描 and 文档', () => {
    f.openScan();
    must(UI.onScreen(d.dump()) === 'home', 'scan tab is not the home screen');
    f.openDocs();
    must(UI.onScreen(d.dump()) === 'docs', 'docs tab did not render the library');
    f.openScan();
    return 'both tabs reachable';
  });

  s.test('empty session offers no export path', () => {
    f.home();
    if (f.sessionCount() != null) f.clearSession();
    const nodes = d.dump();
    must(!nodes.some((n) => (n.desc || '').includes(UI.HOME.next)), '"下一步" is offered with zero pages');
    return 'no 下一步 without pages';
  });

  for (const mode of ['color', 'gray', 'bw']) {
    s.test(`mode chip "${UI.HOME.modes[mode]}" responds`, () => {
      f.home();
      // Tapping the chip that is already selected is a no-op by design, so
      // start from a different mode: only then does "it responded" mean
      // something. Whichever of the two is active, the tested tap changes it.
      const other = mode === 'gray' ? 'color' : 'gray';
      f.setMode(other);
      d.sleep(600);
      const chip = d.waitFor(UI.HOME.modes[mode]);
      band = bandOf(chip);
      const before = s.shot(`before_mode_${mode}`);
      d.tapPoint(chip.center.x, chip.center.y);
      d.sleep(700);
      const after = s.shot(`after_mode_${mode}`);
      const change = png.diffRatio(png.read(before), png.read(after), band);
      must(change > 0.005, `tapping "${UI.HOME.modes[mode]}" from "${UI.HOME.modes[other]}" changed ${(change * 100).toFixed(1)}% of its band`);
      modeRefs[mode] = after;
      return `band changed ${(change * 100).toFixed(1)}%`;
    });
  }

  s.test('auto-crop toggle repaints', () => {
    f.home();
    const chip = d.waitFor(UI.HOME.autoCrop);
    const before = s.shot('before_autocrop');
    d.tapPoint(chip.center.x, chip.center.y);
    d.sleep(700);
    const after = s.shot('after_autocrop');
    const change = png.diffRatio(png.read(before), png.read(after), bandOf(chip));
    must(change > 0.005, `"${UI.HOME.autoCrop}" did not visibly change (${(change * 100).toFixed(1)}%)`);
    d.tapPoint(chip.center.x, chip.center.y);
    d.sleep(400);
    return 'toggle repaints';
  });

  gated('album import produces a session', () => {
    f.home();
    if (f.sessionCount() != null) f.clearSession();
    const r = f.importPages(1);
    if (!r.ok) throw new Error(`picker failed at stage "${r.stage}": ${JSON.stringify(r.detail)}`);
    must(r.pages >= 1, `session shows ${r.pages} pages after importing 1 photo`);
    s.shot('session_1p');
    return `session has ${r.pages} page(s)`;
  });

  gated('multi-page import accumulates pages', () => {
    f.home();
    f.clearSession();
    const r = f.importPages(3);
    if (!r.ok) throw new Error(`picker failed at stage "${r.stage}": ${JSON.stringify(r.detail)}`);
    must(r.pages === 3, `asked for 3 pages, session shows ${r.pages}`);
    const strip = d.waitFor(UI.HOME.sessionPrefix);
    d.swipe(strip.bounds.x2 - 60, strip.center.y + 130, strip.bounds.x1 + 60, strip.center.y + 130, 250);
    d.sleep(600);
    s.shot('session_strip_scrolled');
    return '3 pages in the strip';
  });

  gated('clear wipes the session', () => {
    f.home();
    must(f.sessionCount() != null, 'nothing to clear — the earlier import did not stick');
    must(f.clearSession(), '清空 did not empty the session');
    return 'session cleared';
  });

  // A queued capture keeps its raw photo until 下一步 runs the pipeline, so an
  // edgeless page is only known after processing. The export screen has to say
  // so — a hint line and a marker on the page itself — instead of quietly
  // exporting a PDF with one un-warped sheet in it.
  gated('a page with no edge is marked on the export screen', () => {
    f.home();
    if (f.sessionCount() != null) f.clearSession();
    const r = f.importOnePage('fixture_nodoc', { perPageMs: 120000 });
    if (!r.ok) throw new Error(`import failed at stage "${r.stage}": ${JSON.stringify(r.detail)}`);
    must(UI.onScreen(d.dump()) === 'home', 'the session view should still be up: a queued page is not processed yet');
    f.openResult();
    const nodes = d.dump();
    must(d.find(UI.RESULT.cropWarning, nodes), `no crop warning; visible: ${d.visibleLabels().join(' | ')}`);
    must(d.find(UI.RESULT.cropBadge, nodes), 'the page itself carries no 待裁剪 marker');
    s.shot('crop_warning');
    d.back();
    f.home();
    f.clearSession();
    return 'export page names the edgeless page and marks it';
  });

  gated('page thumbnail opens the crop editor and cancels back', () => {
    f.home();
    const r = f.importPages(1);
    if (!r.ok) throw new Error(`picker failed at stage "${r.stage}"`);
    must(f.tapSessionThumb(0) != null, 'page badge "1" not found in the session strip');
    d.sleep(1600);
    const nodes = d.dump();
    s.shot('adjust');
    const screen = UI.onScreen(nodes);
    must(screen === 'adjust', `tapping a thumbnail opened "${screen}", expected the crop editor`);
    d.tap(UI.ADJUST.cancel);
    d.sleep(1000);
    must(UI.onScreen(d.dump()) === 'home', 'cancel did not return to the session');
    return 'crop editor opens and cancels';
  });

  gated('a long-pressed page gets move and delete handles', () => {
    f.home();
    if (f.sessionCount() != null) f.clearSession();
    const r = f.importPages(3);
    if (!r.ok) throw new Error(`picker failed at stage "${r.stage}": ${JSON.stringify(r.detail)}`);
    must(f.longPressPage(1) != null, 'page badge "2" not found in the session strip');
    d.sleep(800);
    const nodes = d.dump();
    must(d.find(UI.HOME.editingHint, nodes), `no 排序中 hint; visible: ${d.visibleLabels().join(' | ')}`);
    for (const label of [UI.PAGES.prev(2), UI.PAGES.delete(2), UI.PAGES.next(2)]) {
      must(d.find(label, nodes), `handle "${label}" is not on screen`);
    }
    s.shot('page_handles');
    return '◀ × ▶ all addressable on the pressed page';
  });

  gated('the delete handle drops exactly the page it sits on', () => {
    const before = f.sessionCount();
    must(before === 3, `expected the 3-page session from the case above, saw ${before}`);
    must(f.longPressPage(1) != null, 'page badge "2" not found in the session strip');
    must(f.tapPageAction(UI.PAGES.delete(2)), 'the × handle for page 2 was not tappable');
    const after = f.sessionCount();
    must(after === 2, `删除第 2 页 left ${after} pages instead of 2`);
    must(d.find(UI.PAGES.delete(3)) == null, 'a handle is still offered for a page that is gone');
    return '3 -> 2 pages, nothing else dropped';
  });

  // Thumbnails are pixels, so the dump cannot tell one page from another — but
  // the edgeless fixture carries a 待裁剪 marker, and a marker that shifted by one
  // slot pitch is arithmetic. The move is measured, not eyeballed.
  gated('the front arrow moves a page one slot', () => {
    f.home();
    if (f.sessionCount() != null) f.clearSession();
    const r = f.importPages(2, { fixtures: ['fixture_nodoc', 'fixture_01'] });
    if (!r.ok) throw new Error(`picker failed at stage "${r.stage}": ${JSON.stringify(r.detail)}`);
    f.openResult();
    const before = f.stripState();
    must(before.markers.length === 1, `expected one marked page, saw ${JSON.stringify(before.markers)}`);
    must(before.badges.length === 2, `the export strip should show two badges, saw ${before.badges.length}`);
    must(before.pitch > 0, 'both page badges report the same x — the strip did not lay out');
    must(before.markers[0] < before.badges[1], 'the edgeless page is not in the first slot');
    must(f.longPressPage(1) != null, 'page badge "2" not found on the export strip');
    must(f.tapPageAction(UI.PAGES.prev(2)), 'the ◀ handle for page 2 was not tappable');
    const after = f.stripState();
    const shift = after.markers[0] - before.markers[0];
    must(after.markers.length === 1, `the move left ${after.markers.length} markers on screen`);
    must(Math.abs(shift - before.pitch) < 12, `the marker moved ${shift}px, one slot is ${before.pitch}px`);
    must(after.pages === before.pages, `the move changed the page count to ${after.pages}`);
    s.shot('page_moved');
    d.back();
    f.home();
    f.clearSession();
    return `marker shifted ${shift}px across a ${before.pitch}px slot`;
  });

  gated('export saves the doc and empties the session', () => {
    f.home();
    if (f.sessionCount() == null) {
      const r = f.importPages(2);
      if (!r.ok) throw new Error(`picker failed at stage "${r.stage}"`);
    }
    f.openDocs();
    const before = f.docCount();
    f.openScan();
    const out = f.exportDoc('qa-export-01');
    must(out.count > before, `library ${before} -> ${out.count}`);
    f.home();
    must(f.sessionCount() == null, 'session still holds pages after export');
    return `library ${before} -> ${out.count}`;
  });

  gated('exported doc is listed in the library', () => {
    const hit = f.locateDoc('qa-export-01');
    must(hit, '"qa-export-01" is not listed');
    s.shot('docs_after_export');
    f.setFilter('');
    return `row at y=${hit.row.y} of ${hit.count} match(es)`;
  });

  gated('long-press renames a document', () => {
    const hit = f.locateDoc('qa-export-01');
    must(hit, 'the doc under rename vanished');
    const { w } = d.screenSize();
    d.longPressPoint(Math.round(w * 0.28), hit.row.y);
    d.sleep(1700);
    let nodes = d.dump();
    must(nodes.some((n) => (n.desc || n.text) === UI.DOCS.renameSheet), 'rename sheet did not open');
    s.shot('rename_sheet');
    const field = nodes.find((n) => /EditText/i.test(n.class));
    must(field, 'rename sheet has no text field');
    must(field.text === 'qa-export-01', `sheet prefilled "${field.text}", not the row we opened`);
    d.tapPoint(field.center.x, field.center.y);
    d.sleep(600);
    d.clearField(60);
    d.typeText('qa-renamed-01');
    d.sleep(400);
    f.hideKeyboard();
    nodes = d.dump();
    const save = nodes.find((n) => /保存|SAVE/.test(n.desc || n.text));
    must(save, 'rename sheet has no save button');
    d.tapPoint(save.center.x, save.center.y);
    d.sleep(2000);
    must(f.locateDoc('qa-renamed-01'), 'rename did not take effect');
    f.setFilter('');
    return 'renamed and persisted';
  });

  gated('name filter narrows the list', () => {
    f.openDocs();
    const all = f.docCount();
    must(all != null && all > 0, `nothing to filter — the library holds ${all}`);
    const shown = f.setFilter('qa-renamed');
    must(shown === 1, `a filter for a unique title leaves ${shown} document(s)`);
    must(f.rowTitle(0) === 'qa-renamed-01', 'the row behind that filter is another document');
    s.shot('docs_filtered');
    const cleared = f.setFilter('');
    must(cleared === all, `clearing the filter shows ${cleared} of ${all}`);
    return `1 of ${all} matches "qa-renamed"`;
  });

  s.test('date filter opens a range picker', () => {
    f.openDocs();
    const node = d.find(UI.DOCS.dateFilter);
    must(node, 'date filter chip missing');
    d.tapPoint(node.center.x, node.center.y);
    d.sleep(1600);
    const text = d.dump().map((n) => `${n.desc} ${n.text}`).join(' | ');
    must(/\d{4}|年|月|OK|取消|确定/.test(text), `date picker did not appear (${text.slice(0, 160)})`);
    s.shot('date_picker');
    d.back();
    d.sleep(800);
    return 'range picker opens';
  });

  gated('multi-select tracks the selection count', () => {
    // Filtering to the one row keeps the tap target unambiguous: in selection
    // mode the per-row buttons are replaced by a checkbox, so nothing else can
    // say which row is which.
    const hit = f.locateDoc('qa-renamed-01');
    must(hit, 'no row to select');
    const multi = d.find(UI.DOCS.multiSelect);
    must(multi, 'multi-select entry point missing');
    d.tapPoint(multi.center.x, multi.center.y);
    d.sleep(900);
    must(d.dump().some((n) => (n.desc || '').includes(UI.DOCS.selectedPrefix)), 'the header did not switch to selection');
    const { w } = d.screenSize();
    d.tapPoint(Math.round(w * 0.28), hit.row.y);
    d.sleep(700);
    const sel = f.readInt(/已选\s*(\d+)/, d.dump());
    must(sel === 1, `header shows 已选 ${sel}, expected 1`);
    s.shot('docs_multiselect');
    const done = d.dump().find((n) => (n.desc || '') === UI.DOCS.done);
    must(done, 'no way to leave selection mode');
    d.tapPoint(done.center.x, done.center.y);
    d.sleep(600);
    f.setFilter('');
    return `selection count ${sel}`;
  });

  gated('PDF viewer renders the document', () => {
    const hit = f.locateDoc('qa-renamed-01');
    must(hit, 'the doc under view vanished');
    const { w } = d.screenSize();
    d.tapPoint(Math.round(w * 0.28), hit.row.y);
    d.sleep(6000);
    const nodes = d.dump();
    const file = s.shot('pdf_viewer');
    const st = png.stats(png.read(file));
    must(st.distinct > 60, `viewer looks blank: ${st.distinct} colours, dominant #${st.dominant.color}`);
    must(nodes.some((n) => (n.desc || n.text) === 'qa-renamed-01'), 'viewer did not title itself with the doc');
    d.back();
    d.sleep(1200);
    f.setFilter('');
    return `viewer rendered ${st.distinct} colours`;
  });

  gated('share hands the PDF to a system target', () => {
    const hit = f.locateDoc('qa-renamed-01');
    must(hit, 'the doc to share vanished');
    must(hit.row.share, 'per-row share action missing');
    d.tapPoint(hit.row.share.center.x, hit.row.share.center.y);
    d.sleep(4000);
    s.shot('share_chooser');
    must(!d.isForeground(), `no chooser took the foreground (focus=${d.currentFocus()})`);
    d.back();
    d.sleep(1500);
    f.home();
    return 'chooser appeared and backed out';
  });

  s.test('library survives a force-stop', () => {
    d.forceStop();
    d.sleep(1300);
    d.launch();
    d.waitFor(UI.HOME.brand, { timeoutMs: 15000 });
    const still = f.locateDoc('qa-renamed-01');
    must(still, 'exported document lost after a restart');
    f.setFilter('');
    return `still ${f.docCount()} documents`;
  });

  gated('single delete removes exactly one document', () => {
    const hit = f.locateDoc('qa-renamed-01');
    must(hit, 'the doc to delete vanished');
    must(hit.row.delete, 'per-row delete action missing');
    const before = f.docCount();
    f.deleteRowAt(hit.row, 'qa-renamed-01');
    f.setFilter('');
    const after = f.docCount();
    must(after === before - 1, `library ${before} -> ${after} after deleting one document`);
    return `library ${before} -> ${after}`;
  });

  gated('mode choice survives an app restart', () => {
    f.home();
    d.tap(UI.HOME.modes.bw);
    d.sleep(600);
    if (!modeRefs.bw) throw new Error('no mode reference captured — the chip tests did not run');
    d.forceStop();
    d.sleep(1100);
    d.launch();
    d.waitFor(UI.HOME.modes.color, { timeoutMs: 15000 });
    const after = s.shot('after_restart_modes');
    const score = Object.fromEntries(
      Object.entries(modeRefs).map(([m, file]) => [m, png.diffRatio(png.read(file), png.read(after), band)])
    );
    const best = Object.entries(score).sort((a, b) => a[1] - b[1])[0];
    s.note(`restart similarity to each mode reference: ${JSON.stringify(score)}`);
    d.tap(UI.HOME.modes.color);
    d.sleep(400);
    must(best[0] === 'bw', `restart reverted the mode: the UI matches "${best[0]}" (${best[1].toFixed(4)})`);
    return `restored to ${best[0]}`;
  });

  s.test('camera opens the viewfinder and closes cleanly', () => {
    d.grantAllPermissions();
    f.home();
    d.tap(UI.HOME.shoot);
    d.sleep(4500);
    const nodes = d.dump();
    s.shot('camera');
    const screen = UI.onScreen(nodes);
    if (screen !== 'camera') {
      must(nodes.some((n) => (n.desc || '').includes(UI.CAMERA.unavailable)),
        `拍摄 opened neither the camera nor a stated error (screen="${screen}")`);
      s.note('camera reported unavailable; the fallback path was exercised');
    }
    d.back();
    d.sleep(1500);
    must(UI.onScreen(d.dump()) === 'home', 'back from the camera did not return home');
    return screen;
  });

  s.test('camera without permission degrades gracefully', () => {
    d.revokePermissions(['android.permission.CAMERA']);
    d.forceStop();
    d.sleep(900);
    d.launch();
    d.waitFor(UI.HOME.shoot, { timeoutMs: 15000 });
    d.tap(UI.HOME.shoot);
    d.sleep(5000);
    const nodes = d.dump();
    s.shot('camera_denied');
    const text = nodes.map((n) => `${n.desc} ${n.text}`).join(' | ');
    const handled =
      text.includes(UI.CAMERA.unavailable) || text.includes('允许') ||
      UI.onScreen(nodes) === 'camera' || UI.onScreen(nodes) === 'home';
    must(handled, `no permission prompt, no fallback, no camera (labels: ${text.slice(0, 200)})`);
    d.back();
    d.sleep(800);
    d.grantAllPermissions();
    return text.includes(UI.CAMERA.unavailable) ? 'fallback shown' : 'prompt or preview handled';
  });

  // The export cases write real documents into the user's library, so the run
  // that created them removes them again — but only the ones it named.
  s.test('test documents created by this run are cleaned up', () => {
    const deleted = f.deleteSeeded('qa-');
    if (deleted === 0) return 'nothing to clean up';
    return `${deleted} qa- documents deleted`;
  });

  s.test('no defect markers surfaced during the run', () => {
    const pid = d.pidof() ?? 0;
    const text = d.logcatForPid(pid);
    const hits = UI.DEFECT_MARKERS.filter((m) => text.includes(m));
    must(hits.length === 0, `logcat contains: ${hits.join(', ')}`);
    const errs = d.flutterErrors(text);
    must(errs.length === 0, `flutter errors: ${errs.slice(0, 3).join(' || ')}`);
    return 'clean';
  });

  return s.write();
};
