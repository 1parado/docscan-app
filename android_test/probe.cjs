/**
 * Survey the current build instead of asserting on it.
 *
 * Run this first after a new APK lands. It walks each screen, records the real
 * content-desc set and a screenshot, and diffs them against ui.cjs so the
 * label map gets repaired in one pass rather than by hunting through suite
 * failures. `node android_test/probe.cjs`
 */
'use strict';

const fs = require('fs');
const path = require('path');
const d = require('./driver.cjs');
const UI = require('./ui.cjs');

const out = path.join(__dirname, 'reports', `probe-${new Date().toISOString().replace(/[:.]/g, '-')}`);
fs.mkdirSync(out, { recursive: true });

const seen = {};
const shots = [];

function survey(name, nodes) {
  const labels = nodes.map((n) => n.desc || n.text).filter(Boolean);
  seen[name] = labels;
  const file = d.screenshot(name, out);
  shots.push(path.basename(file));
  fs.writeFileSync(path.join(out, `ui-${name}.json`), JSON.stringify(nodes, null, 2));
  process.stdout.write(`\n[${name}] ${labels.length} labels\n  ${labels.join(' · ')}\n`);
}

function step(label, waitMs = 900) {
  try {
    d.tap(label);
    d.sleep(waitMs);
    return true;
  } catch (e) {
    process.stdout.write(`  (could not tap "${label}": ${e.message})\n`);
    return false;
  }
}

d.forceStop();
d.sleep(800);
d.logcatClear();
d.launch();
d.waitFor(UI.HOME.brand, { timeoutMs: 15000 });

survey('home', d.dump());

step(UI.HOME.shoot, 3500);
survey('camera', d.dump());
d.back();
d.sleep(1200);

step(UI.HOME.album, 3500);
survey('album-picker', d.dump());
d.back();
d.sleep(1000);

step(UI.TABS.docs, 1500);
survey('docs', d.dump());

// The PDF viewer and the rename sheet need an existing doc; only probe if one
// is present, otherwise record why the screen was skipped.
const docsNodes = d.dump();
const chrome = new Set(
  [UI.TABS.scan, UI.TABS.docs, UI.DOCS.filterHint, UI.DOCS.dateFilter, UI.DOCS.multiSelect, UI.DOCS.countPrefix]
    .map((s) => String(s))
);
const firstDoc = docsNodes
  .filter((n) => n.desc && !chrome.has(n.desc) && !n.desc.includes(UI.DOCS.countPrefix) && n.bounds.y1 > 420)
  .sort((a, b) => a.bounds.y1 - b.bounds.y1)[0];
if (firstDoc) {
  process.stdout.write(`\n[docs] first card appears to be "${firstDoc.desc}"\n`);
  step(firstDoc.desc, 4000);
  survey('pdf-viewer', d.dump());
  d.back();
  d.sleep(1000);
} else {
  seen['pdf-viewer'] = [];
  process.stdout.write('\n[pdf-viewer] skipped: library is empty\n');
}

const expectations = {
  home: [UI.HOME.brand, UI.HOME.shoot, UI.HOME.album, UI.HOME.modes.color, UI.HOME.autoCrop],
  docs: [UI.DOCS.filterHint, UI.DOCS.countPrefix],
  camera: [UI.CAMERA.single, UI.CAMERA.multi],
};

const drift = [];
for (const [screen, expected] of Object.entries(expectations)) {
  for (const e of expected) {
    if (!(seen[screen] ?? []).some((l) => l.includes(e))) drift.push(`${screen}: "${e}" no longer present`);
  }
}

fs.writeFileSync(
  path.join(out, 'summary.json'),
  JSON.stringify({ device: d.deviceInfo(), screens: seen, drift }, null, 2)
);

process.stdout.write(
  drift.length ? `\n\nDRIFT vs ui.cjs:\n${drift.map((x) => `  - ${x}`).join('\n')}\n` : '\n\nNo label drift detected.\n'
);
process.stdout.write(`artifacts: ${path.relative(process.cwd(), out)}\n`);
