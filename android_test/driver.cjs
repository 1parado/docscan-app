/**
 * Thin, dependency-free ADB driver for driving the DocScan app on a real
 * device. Assertions are made against the Flutter semantics tree, which
 * `uiautomator dump` exposes as content-desc + bounds, so a test says
 * `tap('相册')` instead of hard-coding pixels.
 *
 * Every helper is synchronous on purpose: the suites read like a script of
 * taps and checks, and timing is handled by explicit `wait*` calls.
 */
'use strict';

const { execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const PKG = process.env.DOCSAN_PKG || 'com.docscan.docscan_app';
const ACTIVITY = `${PKG}/.MainActivity`;
const ROOT = path.resolve(__dirname, '..');

function findAdb() {
  const candidates = [
    process.env.ADB_PATH,
    process.env.LOCALAPPDATA &&
      path.join(process.env.LOCALAPPDATA, 'Android', 'Sdk', 'platform-tools', 'adb.exe'),
    process.env.ANDROID_HOME && path.join(process.env.ANDROID_HOME, 'platform-tools', 'adb.exe'),
    'adb',
  ].filter(Boolean);
  for (const c of candidates) {
    try {
      execFileSync(c, ['version'], { stdio: 'pipe' });
      return c;
    } catch (_) {
      /* try next */
    }
  }
  throw new Error('adb not found. Set ADB_PATH or ANDROID_HOME.');
}

const ADB = findAdb();

function adb(args, opts = {}) {
  const out = execFileSync(ADB, args, {
    encoding: 'utf8',
    maxBuffer: 64 * 1024 * 1024,
    // Git Bash on Windows rewrites "/sdcard/x" into a Windows path unless told
    // not to; device paths would silently break without this.
    env: { ...process.env, MSYS_NO_PATHCONV: '1', MSYS2_ARG_CONV_EXCL: '*' },
    ...opts,
  });
  return out.replace(/\r/g, '');
}

const sleep = (ms) => {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    /* blocking wait keeps the suites synchronous and linear */
  }
};

// ------------------------------------------------------------------ device

function assertDevice() {
  const lines = adb(['devices']).trim().split('\n').slice(1);
  const online = lines.filter((l) => l.endsWith('\tdevice'));
  if (online.length === 0) throw new Error('no online adb device');
  if (online.length > 1) {
    throw new Error(`multiple devices online; set ANDROID_SERIAL:\n${online.join('\n')}`);
  }
  return online[0].split(/\s+/)[0];
}

const deviceInfo = () => ({
  serial: assertDevice(),
  model: adb(['shell', 'getprop', 'ro.product.model']).trim(),
  android: adb(['shell', 'getprop', 'ro.build.version.release']).trim(),
  sdk: adb(['shell', 'getprop', 'ro.build.version.sdk']).trim(),
  screen: adb(['shell', 'wm', 'size']).trim().replace('Physical size: ', ''),
  density: adb(['shell', 'wm', 'density']).trim().replace('Physical density: ', ''),
});

const screenSize = () => {
  const [w, h] = adb(['shell', 'wm', 'size'])
    .replace(/[^0-9x]/g, '')
    .split('x')
    .map(Number);
  return { w, h };
};

// ------------------------------------------------------------------- lifecycle

const forceStop = () => adb(['shell', 'am', 'force-stop', PKG]);

/**
 * Put the device back into a state where `launch()` actually starts the app.
 *
 * A picker opened from our task and never dismissed stays stacked *inside* that
 * task, so `am start` re-raises the picker, MainActivity never resumes, and the
 * process goes away — which reads as "app crashed" if you don't clear it first.
 */
function resetToApp() {
  forceStop();
  for (let i = 0; i < 6 && /documentsui|mediapicker|photo/i.test(foregroundPackage()); i++) {
    back();
    sleep(700);
  }
  homeKey();
  sleep(600);
  // Leave the app in the foreground: on this ROM uiautomator cannot dump the
  // launcher at all, so ending on the home screen would look like a dead app.
  launch();
  for (let i = 0; i < 12 && !isForeground(); i++) sleep(500);
  sleep(1500);
}

/** Cold start. Returns the measured start-up cost in ms from both sources. */
function launch() {
  const out = adb(['shell', 'am', 'start', '-W', '-n', ACTIVITY]);
  const total = /TotalTime:\s*(\d+)/.exec(out);
  const status = /Status:\s*(\w+)/.exec(out);
  return {
    status: status ? status[1] : 'unknown',
    totalTimeMs: total ? Number(total[1]) : null,
    launchState: /LaunchState:\s*(\w+)/.exec(out)?.[1] ?? 'unknown',
  };
}

// `dumpsys window windows` prints nothing on this Huawei build; the bare
// service dump is the one that carries mCurrentFocus.
const currentFocus = () =>
  adb(['shell', 'dumpsys', 'window']).match(/mCurrentFocus=Window\{[^}]*?\s(\S+\/\S+?)\}/)?.[1] ?? '';

const isForeground = () => currentFocus().startsWith(PKG);

/** Package that currently owns the window — the system picker is not ours. */
const foregroundPackage = () => currentFocus().split('/')[0];

const inPicker = () => isForeground() === false && foregroundPackage() !== '';

const pidof = () => {
  let p;
  try {
    // `pidof` exits 1 when the process is gone, which is an answer, not an error.
    p = adb(['shell', 'pidof', PKG]).trim();
  } catch (_) {
    return null;
  }
  return p ? Number(p.split(/\s+/)[0]) : null;
};

/** Poll until the app process is gone, i.e. confirm a real crash, not a hang. */
function waitProcessGone(timeoutMs = 6000) {
  const end = Date.now() + timeoutMs;
  while (Date.now() < end) {
    if (pidof() == null) return true;
    sleep(250);
  }
  return false;
}

// ---------------------------------------------------------------- semantics

/** Parse the uiautomator XML into flat nodes with numeric bounds. */
function parseNodes(xml) {
  const nodes = [];
  for (const tag of xml.match(/<node\b[^>]*\/>/g) ?? []) {
    const attr = (name) => {
      const m = new RegExp(`${name}="([^"]*)"`).exec(tag);
      return m ? m[1] : '';
    };
    const bounds = attr('bounds');
    const nums = bounds.match(/-?\d+/g);
    if (!nums || nums.length !== 4) continue;
    const [x1, y1, x2, y2] = nums.map(Number);
    nodes.push({
      text: unescapeXml(attr('text')),
      desc: unescapeXml(attr('content-desc')),
      resource: attr('resource-id'),
      class: attr('class'),
      clickable: attr('clickable') === 'true',
      scrollable: attr('scrollable') === 'true',
      longClickable: attr('long-clickable') === 'true',
      bounds: { x1, y1, x2, y2 },
      center: { x: Math.round((x1 + x2) / 2), y: Math.round((y1 + y2) / 2) },
    });
  }
  return nodes;
}

const unescapeXml = (s) =>
  s.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&amp;/g, '&').replace(/&apos;/g, "'");

const BINARY_DUMP = '/sdcard/docscan_ui.xml';

/**
 * Dump the semantics tree. Retries because uiautomator refuses to dump while
 * the window is still animating, which is routine right after a transition, and
 * because it is single-instance on the device: an instrumentation left behind by
 * an interrupted run makes the next dump exit 137 (killed), so the wait between
 * attempts grows rather than staying flat.
 *
 * A failed dump throws instead of returning an empty list — an empty tree makes
 * "is this label absent?" assertions pass for the wrong reason.
 */
function dump({ retries = 6 } = {}) {
  let lastErr = null;
  for (let i = 0; i < retries; i++) {
    adb(['shell', 'rm', '-f', BINARY_DUMP]);
    try {
      const out = adb(['shell', 'uiautomator', 'dump', BINARY_DUMP]);
      if (out.includes('dumped to')) {
        const xml = adb(['shell', 'cat', BINARY_DUMP]);
        if (xml.includes('<node')) return parseNodes(xml);
        lastErr = new Error('dump produced no node tree');
      } else {
        lastErr = new Error(`uiautomator refused: ${out.trim() || 'no output'}`);
      }
    } catch (err) {
      lastErr = err;
    }
    sleep(400 * (i + 1));
  }
  throw new Error(`uiautomator dump failed after ${retries} tries: ${lastErr && lastErr.message}`);
}

const visibleLabels = () =>
  dump()
    .map((n) => n.desc || n.text)
    .filter(Boolean);

/** Match by content-desc or text: exact first, then substring. */
function find(label, nodes = dump()) {
  const key = String(label).trim();
  return (
    nodes.find((n) => (n.desc === key || n.text === key) && (n.desc || n.text)) ??
    nodes.find((n) => (n.desc && n.desc.includes(key)) || (n.text && n.text.includes(key)))
  );
}

function findIndex(prefix, nodes) {
  // Numeric page badges ("1", "2", ...) repeat, so allow ordinal selection.
  return nodes.filter((n) => (n.desc || n.text) === prefix);
}

// ------------------------------------------------------------------- input

function tapPoint(x, y) {
  adb(['shell', 'input', 'tap', String(x), String(y)]);
}

/** Tap the centre of the node whose label matches. Throws if absent. */
function tap(label) {
  const n = find(label);
  if (!n) throw new Error(`tap: no UI element matching "${label}"`);
  tapPoint(n.center.x, n.center.y);
  return n;
}

function longPress(label, ms = 900) {
  const n = find(label);
  if (!n) throw new Error(`longPress: no UI element matching "${label}"`);
  adb(['shell', 'input', 'swipe', String(n.center.x), String(n.center.y), String(n.center.x), String(n.center.y), String(ms)]);
  return n;
}

const back = () => adb(['shell', 'input', 'keyevent', '4']);
const homeKey = () => adb(['shell', 'input', 'keyevent', '3']);

function swipe(x1, y1, x2, y2, ms = 300) {
  adb(['shell', 'input', 'swipe', String(x1), String(y1), String(x2), String(y2), String(ms)]);
}

/** Horizontal fling inside a widget band, e.g. a thumbnail strip. */
function swipeIn(node, dir = 1, ms = 260) {
  const y = node.center.y;
  const span = Math.max(80, Math.round((node.bounds.x2 - node.bounds.x1) * 0.7));
  const cx = node.center.x;
  swipe(cx - (dir > 0 ? -span / 2 : span / 2), y, cx + (dir > 0 ? span / 2 : -span / 2), y, ms);
}

/** Scroll a whole screen vertically — list rows live below the fold. */
function scrollScreen(dir = 'up', ms = 320) {
  const { w, h } = screenSize();
  const from = Math.round(h * (dir === 'up' ? 0.7 : 0.35));
  const to = Math.round(h * (dir === 'up' ? 0.32 : 0.7));
  swipe(Math.round(w / 2), from, Math.round(w / 2), to, ms);
}

/** `adb shell input text` cannot emit CJK; suites use it for ASCII names. */
function typeText(text) {
  adb(['shell', 'input', 'text', text.replace(/ /g, '%s')]);
}

/** Move to end of the field then backspace, i.e. clear what the app prefilled. */
const clearField = (times = 60) => {
  adb(['shell', 'input', 'keyevent', 'KEYCODE_MOVE_END']);
  for (let i = 0; i < times; i++) adb(['shell', 'input', 'keyevent', '67']);
};

// -------------------------------------------------------------- screenshots

/** Poll the semantics tree until `label` appears (or disappears). */
function waitFor(label, { timeoutMs = 8000, absent = false } = {}) {
  const end = Date.now() + timeoutMs;
  let nodes = [];
  do {
    nodes = dump();
    const hit = find(label, nodes);
    if (absent ? !hit : hit) return hit ?? { absentConfirmed: true, nodes };
    sleep(350);
  } while (Date.now() < end);
  throw new Error(
    `waitFor${absent ? ' absent' : ''}: "${label}" ${absent ? 'still present' : 'not found'} after ${timeoutMs}ms. ` +
      `visible: [${nodes.map((n) => n.desc || n.text).filter(Boolean).join(' | ')}]`
  );
}

/** Non-throwing form of waitFor, for steps where absence is a real outcome. */
function tryWait(label, { timeoutMs = 8000, absent = false } = {}) {
  try {
    waitFor(label, { timeoutMs, absent });
    return true;
  } catch (_) {
    return false;
  }
}

/** `adb exec-out screencap -p` emits PNG bytes, so it bypasses utf8 decoding. */
function adbBin(args) {
  return execFileSync(ADB, args, {
    maxBuffer: 128 * 1024 * 1024,
    encoding: 'buffer',
    env: { ...process.env, MSYS_NO_PATHCONV: '1', MSYS2_ARG_CONV_EXCL: '*' },
  });
}

function screenshot(name, dir) {
  fs.mkdirSync(dir, { recursive: true });
  const local = path.join(dir, `${sanitize(name)}.png`);
  fs.writeFileSync(local, adbBin(['exec-out', 'screencap', '-p']));
  return local;
}

const sanitize = (s) => String(s).replace(/[^\w.\u4e00-\u9fff-]/g, '_');

// ------------------------------------------------------------------- logcat

function logcatClear() {
  adb(['logcat', '-b', 'all', '-c']);
}

/**
 * Logcat scoped to the app's own pid. An unscoped dump also replays other
 * processes' old SIGSEGVs, which reads as a false crash.
 */
function logcatForPid(pid, { includeCrashBuffer = true } = {}) {
  const args = ['logcat', '-d', '--pid', String(pid)];
  if (includeCrashBuffer) args.splice(1, 0, '-b', 'crash');
  return adb(args);
}

function logcatDump(filter = '') {
  const args = ['logcat', '-d', '-v', 'brief'];
  if (filter) args.push('-e', filter);
  return adb(args);
}

/** Flutter framework errors surface as logcat lines, not process death. */
function flutterErrors(text) {
  return (text.match(/^E flutter .*/gm) ?? []).filter(
    (l) => !/Observatory|Dart VM|devtools|ws:\/\/|wss:\/\//.test(l)
  );
}

// -------------------------------------------------------------------- misc

const meminfo = () => {
  const out = adb(['shell', 'dumpsys', 'meminfo', PKG]);
  const num = (re) => {
    const m = re.exec(out);
    return m ? Number(m[1]) : null;
  };
  return {
    totalPssKb: num(/TOTAL PSS:\s*(\d+)/),
    javaHeapKb: num(/Java Heap:\s*(\d+)/),
    nativeHeapKb: num(/Native Heap:\s*(\d+)/),
    graphicsKb: num(/Graphics:\s*(\d+)/),
  };
};

const grantAllPermissions = () => {
  const granted = [];
  for (const p of ['android.permission.CAMERA', 'android.permission.READ_MEDIA_IMAGES', 'android.permission.READ_EXTERNAL_STORAGE']) {
    try {
      adb(['shell', 'pm', 'grant', PKG, p]);
      granted.push(p.split('.').pop());
    } catch (_) {
      /* some ROMs refuse a permission the app does not declare */
    }
  }
  return granted;
};

const revokePermissions = (list = ['android.permission.CAMERA']) => {
  for (const p of list) {
    try {
      adb(['shell', 'pm', 'revoke', PKG, p]);
    } catch (_) {
      /* already revoked */
    }
  }
};

const clearAppData = () => adb(['shell', 'pm', 'clear', PKG]);

const push = (local, remote) => adb(['push', local, remote]);

/** Make pushed photos visible to the system picker without a reboot. */
const mediaScanFile = (remotePath) =>
  adb(['shell', 'am', 'broadcast', '-a', 'android.intent.action.MEDIA_SCANNER_SCAN_FILE', '-d', `file://${remotePath}`]);

const pull = (remote, local) => {
  fs.mkdirSync(path.dirname(local), { recursive: true });
  adb(['pull', remote, local]);
  return local;
};

module.exports = {
  PKG,
  ACTIVITY,
  ROOT,
  ADB,
  adb,
  adbBin,
  sleep,
  deviceInfo,
  screenSize,
  assertDevice,
  forceStop,
  resetToApp,
  launch,
  currentFocus,
  isForeground,
  foregroundPackage,
  inPicker,
  pidof,
  waitProcessGone,
  dump,
  visibleLabels,
  find,
  findIndex,
  waitFor,
  tryWait,
  tap,
  tapPoint,
  longPress,
  back,
  homeKey,
  swipe,
  swipeIn,
  scrollScreen,
  typeText,
  clearField,
  screenshot,
  logcatClear,
  logcatForPid,
  logcatDump,
  flutterErrors,
  meminfo,
  grantAllPermissions,
  revokePermissions,
  clearAppData,
  push,
  mediaScanFile,
  pull,
  BINARY_DUMP,
};
