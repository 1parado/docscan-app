/**
 * Smoke test: is the build on this phone even alive? Cheap, binary checks that
 * gate every other suite. No business flow here on purpose — if smoke fails,
 * nothing below it is meaningful.
 */
'use strict';

const d = require('../driver.cjs');
const { Suite, must, eq } = require('../harness.cjs');
const png = require('../png.cjs');

const COLD_START_BUDGET_MS = Number(process.env.COLD_START_BUDGET_MS || 2500);

module.exports = function smoke() {
  const s = new Suite('smoke');

  s.test('adb device online', () => {
    const i = s.info;
    return `${i.model} · Android ${i.android} · ${i.screen} @${i.density}`;
  });

  s.test('DocScan is the only app under test and it is installed', () => {
    const listed = d.adb(['shell', 'pm', 'list', 'packages', d.PKG]);
    must(listed.includes(d.PKG), `package ${d.PKG} not installed`);
    const v = d.adb(['shell', 'dumpsys', 'package', d.PKG]).match(/versionName=(\S+)/);
    const code = d.adb(['shell', 'dumpsys', 'package', d.PKG]).match(/versionCode=(\d+)/);
    return `versionName=${v?.[1]} versionCode=${code?.[1]}`;
  });

  s.test('cold start succeeds', () => {
    d.forceStop();
    d.sleep(1200);
    d.logcatClear();
    const r = d.launch();
    eq(r.status, 'ok', 'am start status');
    must(r.totalTimeMs != null, 'no TotalTime reported');
    must(r.totalTimeMs < COLD_START_BUDGET_MS, `cold start ${r.totalTimeMs}ms over budget ${COLD_START_BUDGET_MS}ms`);
    s.note(`cold start TotalTime=${r.totalTimeMs}ms (${r.launchState})`);
    return `${r.launchState} in ${r.totalTimeMs}ms`;
  });

  s.test('app owns the foreground', () => {
    d.waitFor('DocScan', { timeoutMs: 12000 });
    must(d.isForeground(), `mCurrentFocus is ${d.currentFocus()}`);
    return d.currentFocus();
  });

  s.test('home screen exposes its core controls', () => {
    const labels = d.visibleLabels();
    for (const need of ['DocScan', '扫描', '文档', '彩色', '裁边', '拍摄', '相册']) {
      must(labels.some((l) => l.includes(need)), `missing "${need}"`);
    }
    return labels.join(' | ');
  });

  s.test('first frame is rendered, not a blank/black surface', () => {
    const file = s.shot('home');
    const st = png.stats(png.read(file));
    must(st.distinct > 40, `only ${st.distinct} distinct colours — looks blank`);
    must(st.dominant.share < 0.93, `93%+ of pixels are #${st.dominant.color} — looks blank`);
    return `${st.distinct} colours, dominant #${st.dominant.color} ${(st.dominant.share * 100).toFixed(0)}%`;
  });

  s.test('no process crash during start-up', () => {
    d.sleep(2500);
    const pid = d.pidof();
    must(pid != null, 'app process died after start');
    const text = d.logcatForPid(pid);
    const crash = text
      .split('\n')
      .filter((l) => /FATAL EXCEPTION|Fatal signal|E AndroidRuntime|A\/libc/.test(l));
    must(crash.length === 0, `crash lines for pid ${pid}: ${crash.slice(0, 3).join(' || ')}`);
    return `pid=${pid}, ${text.split('\n').filter(Boolean).length} log lines clean`;
  });

  s.test('no Flutter framework errors', () => {
    const errs = d.flutterErrors(d.logcatForPid(d.pidof()));
    must(errs.length === 0, `flutter errors: ${errs.slice(0, 3).join(' || ')}`);
    return 'clean';
  });

  s.test('release build declares no network permission', () => {
    const out = d.adb(['shell', 'dumpsys', 'package', d.PKG]);
    const install = /install permissions:\n([\s\S]*?)(\n\s*\S+ permissions:|\nruntime permissions:)/.exec(out);
    must(install, 'could not isolate the install-permission block');
    const declared = [...install[1].matchAll(/android\.permission\.([A-Z_]+)/g)].map((m) => m[1]);
    must(!declared.includes('INTERNET'), `INTERNET is declared — the "offline" claim is false: ${declared.join(' ')}`);
    return `declared: ${declared.join(' ')}`;
  });

  s.test('idle memory footprint is sane', () => {
    const m = d.meminfo();
    must(m.totalPssKb != null, `unparsable meminfo`);
    must(m.totalPssKb < 420_000, `PSS ${m.totalPssKb}kB after cold start on an empty screen`);
    return `PSS=${(m.totalPssKb / 1024).toFixed(0)}MB java=${(m.javaHeapKb / 1024).toFixed(0)}MB native=${(m.nativeHeapKb / 1024).toFixed(0)}MB`;
  });

  s.test('warm start after backgrounding is fast', () => {
    d.homeKey();
    d.sleep(1500);
    const r = d.launch();
    must(r.totalTimeMs < 900, `warm start ${r.totalTimeMs}ms`);
    d.waitFor('拍摄', { timeoutMs: 8000 });
    return `${r.launchState} in ${r.totalTimeMs}ms`;
  });

  return s.write();
};
