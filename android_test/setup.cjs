/**
 * Device-side test data: synthetic document photos, and access to the app's own
 * files when (and only when) the installed build allows it.
 *
 * Photos go into DCIM so the system picker can see them; a media broadcast
 * makes them appear without a reboot. Reading the app's internal docs directory
 * needs `run-as`, which a release build refuses — callers must turn that into a
 * skip rather than a pass.
 */
'use strict';

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const d = require('./driver.cjs');

const FIXTURE_DIR = path.join(__dirname, 'fixtures');
const REMOTE_DIR = '/sdcard/DCIM/DocScanTest';

function generateFixtures(count) {
  execFileSync(
    process.env.DART_PATH ?? 'dart',
    ['run', 'tool/make_scan_fixtures.dart', String(count), path.relative(d.ROOT, FIXTURE_DIR)],
    { cwd: d.ROOT, stdio: 'inherit' }
  );
  return listFixtures();
}

const listFixtures = () =>
  fs.existsSync(FIXTURE_DIR)
    ? fs.readdirSync(FIXTURE_DIR).filter((f) => /\.jpe?g$/i.test(f)).sort().map((f) => path.join(FIXTURE_DIR, f))
    : [];

function pushFixtures(files = listFixtures()) {
  if (!files.length) throw new Error('no fixtures on disk; run `node android_test/setup.cjs gen`');
  d.adb(['shell', 'mkdir', '-p', REMOTE_DIR]);
  for (const f of files) d.adb(['push', f, `${REMOTE_DIR}/${path.basename(f)}`]);
  for (const f of files) d.mediaScanFile(`${REMOTE_DIR}/${path.basename(f)}`);
  d.sleep(2500);
  return files.length;
}

const wipeFixtures = () => d.adb(['shell', 'rm', '-rf', REMOTE_DIR]);

const remoteListing = () => d.adb(['shell', 'ls', REMOTE_DIR]).split('\n').filter(Boolean);

/** True when the installed build lets us use run-as to inspect its files. */
function isDebuggable() {
  const flags = d.adb(['shell', 'dumpsys', 'package', d.PKG]).match(/flags=\[([^\]]*)\]/)?.[1] ?? '';
  return /DEBUGGABLE/.test(flags);
}

function runAs(cmd) {
  if (!isDebuggable()) throw new Error('SKIP: installed build is not debuggable, run-as needs a debug APK');
  return d.adb(['shell', 'run-as', d.PKG, ...cmd]);
}

/** Where the library really lives: path_provider gives Android `app_flutter`, not `files`. */
const DOCS_ROOTS = ['app_flutter/docs', 'files/docs'];

/** Paths under the app's private docs dir, when the build permits it. */
function appDocsListing() {
  for (const root of DOCS_ROOTS) {
    const found = runAs(['find', root, '-maxdepth', '2', '-type', 'f']).split('\n').filter(Boolean);
    if (found.length) return found;
  }
  return [];
}

function pullAppFile(remoteRel, local) {
  if (!isDebuggable()) throw new Error('SKIP: run-as unavailable on a release build');
  const tmp = '/sdcard/docscan_pull.tmp';
  runAs(['cp', remoteRel, tmp]);
  d.adb(['shell', 'chmod', '644', tmp]);
  d.pull(tmp, local);
  d.adb(['shell', 'rm', '-f', tmp]);
  return local;
}

module.exports = {
  FIXTURE_DIR,
  REMOTE_DIR,
  generateFixtures,
  listFixtures,
  pushFixtures,
  wipeFixtures,
  remoteListing,
  isDebuggable,
  runAs,
  appDocsListing,
  pullAppFile,
};

// Direct invocation: node android_test/setup.cjs <gen [n]|push|ls|wipe|debuggable>
if (require.main === module) {
  const [cmd, arg] = process.argv.slice(2);
  if (cmd === 'gen') console.log(`generated ${generateFixtures(Number(arg) || 6).length} fixtures`);
  else if (cmd === 'push') console.log(`pushed ${pushFixtures()} fixtures to ${REMOTE_DIR}`);
  else if (cmd === 'ls') console.log(remoteListing().join('\n') || '(none on device)');
  else if (cmd === 'wipe') { wipeFixtures(); console.log('removed', REMOTE_DIR); }
  else if (cmd === 'debuggable') console.log(isDebuggable() ? 'debuggable: yes' : 'debuggable: no');
  else console.log('usage: node android_test/setup.cjs <gen [n]|push|ls|wipe|debuggable>');
}
