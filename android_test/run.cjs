/**
 * Entry point: `node android_test/run.js smoke system` — runs the named suites
 * in order and exits non-zero if anything failed, so CI or a pre-release check
 * can gate on it.
 */
'use strict';

const SUITES = {
  smoke: './suites/smoke.cjs',
  system: './suites/system.cjs',
  acceptance: './suites/acceptance.cjs',
  scale: './suites/scale.cjs',
};

const wanted = process.argv.slice(2).filter((a) => !a.startsWith('-'));
const names = wanted.length ? wanted : Object.keys(SUITES);

const unknown = names.filter((n) => !SUITES[n]);
if (unknown.length) {
  console.error(`unknown suite(s): ${unknown.join(', ')}\navailable: ${Object.keys(SUITES).join(', ')}`);
  process.exit(2);
}

const totals = { pass: 0, fail: 0 };
for (const n of names) {
  const json = require(SUITES[n])();
  totals.pass += json.counts.pass;
  totals.fail += json.counts.fail;
}

console.log(
  `\n${totals.fail === 0 ? 'ALL GREEN' : 'FAILURES'} — ${totals.pass}/${totals.pass + totals.fail} cases passed`
);
process.exit(totals.fail === 0 ? 0 : 1);
