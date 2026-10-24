/**
 * Tiny synchronous test runner for the ADB suites: records pass/fail per
 * case, keeps the screenshots a failing case produced, and writes a markdown
 * + JSON report next to them so a run is reviewable after the fact.
 */
'use strict';

const fs = require('fs');
const path = require('path');
const d = require('./driver.cjs');

const REPORTS = path.join(__dirname, 'reports');
const LOCK = path.join(__dirname, '.device-lock');

/**
 * One suite per phone.
 *
 * Two concurrent runs do not merely race the screenshots: suite A's BACK or
 * force-stop moves suite B's foreground window out from under it, and every
 * label assertion B makes is then about A's screen. Refuse to start instead of
 * reporting a fabricated failure.
 */
function acquireLock(suiteName) {
  const stale = (who) => {
    try {
      process.kill(Number(who), 0);
      return false; // a live process really is holding the phone
    } catch (_) {
      return true;
    }
  };
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      fs.writeFileSync(LOCK, `${process.pid} ${suiteName} ${new Date().toISOString()}\n`, { flag: 'wx' });
      const release = () => {
        try {
          if (fs.readFileSync(LOCK, 'utf8').startsWith(`${process.pid} `)) fs.unlinkSync(LOCK);
        } catch (_) {
          /* already gone */
        }
      };
      process.on('exit', release);
      return;
    } catch (err) {
      if (err.code !== 'EEXIST') throw err;
      const holder = (fs.readFileSync(LOCK, 'utf8').trim().split(' ')[0]) || '?';
      if (!stale(holder)) {
        throw new Error(
          `device is busy: suite held by pid ${holder} (${fs.readFileSync(LOCK, 'utf8').trim()}). ` +
            'Two runs on one phone invalidate every assertion, so this one refused to start.'
        );
      }
      try {
        fs.unlinkSync(LOCK); // previous run died without releasing
      } catch (_) {
        /* someone else took it */
      }
    }
  }
  throw new Error(`could not acquire ${LOCK}`);
}

class Skip {
  constructor(reason) {
    this.reason = reason;
  }
}

const C = {
  reset: '\x1b[0m',
  green: '\x1b[32m',
  red: '\x1b[31m',
  yellow: '\x1b[33m',
  dim: '\x1b[2m',
  bold: '\x1b[1m',
};

class Suite {
  constructor(name) {
    this.name = name;
    this.results = [];
    this.startedAt = new Date();
    this.dir = path.join(
      REPORTS,
      `${this.startedAt.toISOString().replace(/[:.]/g, '-')}-${name}`
    );
    this.seq = 0;
    this.shots = [];
    this.aborted = null;
    this.info = d.deviceInfo();
    // Lock before mkdir, so a refused duplicate run leaves no empty report folder.
    acquireLock(name);
    fs.mkdirSync(this.dir, { recursive: true });
    d.resetToApp();
  }

  /** One test case. It fails on a throw; `note` records a finding without failing. */
  test(title, fn) {
    if (this.aborted) {
      const rec = {
        id: `${this.name}-${String(this.results.length + 1).padStart(2, '0')}`,
        title,
        status: 'SKIP',
        detail: `not run: ${this.aborted}`,
        ms: 0,
      };
      this.results.push(rec);
      this.log(`${C.yellow}   - ${title} skipped (suite aborted)${C.reset}`);
      return rec;
    }
    const rec = { id: `${this.name}-${String(this.results.length + 1).padStart(2, '0')}`, title, status: 'PASS' };
    const t0 = Date.now();
    this.log(`\n${C.bold}▶ ${title}${C.reset}`);
    try {
      const out = fn();
      if (out instanceof Skip) {
        rec.status = 'SKIP';
        rec.detail = out.reason;
        this.log(`${C.yellow}   - skipped: ${out.reason}${C.reset}`);
      } else {
        if (typeof out === 'string') rec.detail = out;
        rec.status = 'PASS';
      }
    } catch (e) {
      rec.status = 'FAIL';
      rec.detail = String(e && e.message ? e.message : e);
      this.log(`${C.red}   ✗ ${rec.detail}${C.reset}`);
    }
    rec.ms = Date.now() - t0;
    this.results.push(rec);
    if (rec.status === 'PASS') this.log(`${C.green}   ✓ ${C.dim}(${rec.ms}ms)${C.reset}`);
    return rec;
  }

  /** Throw this from a test body to record an honest skip instead of a false pass. */
  skip(reason) {
    return new Skip(reason);
  }

  /** Record an observation that is not a test verdict (measurements, caveats). */
  note(text) {
    this.results.push({ id: `${this.name}-n${this.results.length}`, title: 'note', status: 'NOTE', detail: text });
    this.log(`${C.dim}   · ${text}${C.reset}`);
  }

  /** Screenshot into this run's folder, numbered in order. Returns the path. */
  shot(label) {
    const file = d.screenshot(`${String(this.seq++).padStart(2, '0')}_${label}`, this.dir);
    this.shots.push(file);
    return file;
  }

  log(line) {
    process.stdout.write(line + '\n');
  }

  summary() {
    const count = (st) => this.results.filter((r) => r.status === st).length;
    const pass = count('PASS');
    const fail = count('FAIL');
    return { pass, fail, skip: count('SKIP'), total: pass + fail };
  }

  /** True when the app process vanished: every later case is meaningless. */
  abort(message) {
    this.aborted = message;
    this.log(`${C.red}!! aborting suite: ${message}${C.reset}`);
  }

  write() {
    const s = this.summary();
    const json = {
      suite: this.name,
      startedAt: this.startedAt.toISOString(),
      durationMs: Date.now() - this.startedAt.getTime(),
      device: this.info,
      counts: s,
      results: this.results,
    };
    fs.writeFileSync(path.join(this.dir, 'report.json'), JSON.stringify(json, null, 2));

    const lines = [
      `# ${this.name} — ${s.fail === 0 ? 'PASS' : 'FAIL'} (${s.pass}/${s.total}${s.skip ? `, ${s.skip} skipped` : ''})`,
      '',
      `- device: ${this.info.model} · Android ${this.info.android} (sdk ${this.info.sdk}) · ${this.info.screen} @${this.info.density}`,
      `- run: ${json.startedAt} · ${Math.round(json.durationMs / 1000)}s`,
      '',
      '| # | case | result | detail |',
      '| --- | --- | --- | --- |',
    ];
    for (const r of this.results) {
      if (r.status === 'NOTE') continue;
      lines.push(`| ${r.id} | ${esc(r.title)} | ${r.status} | ${esc(r.detail ?? '')} |`);
    }
    const notes = this.results.filter((r) => r.status === 'NOTE');
    if (notes.length) {
      lines.push('', '## Notes', ...notes.map((n) => `- ${esc(n.detail)}`));
    }
    lines.push('', '## Screenshots', ...this.shots.map((f) => `- ${path.basename(f)}`));
    fs.writeFileSync(path.join(this.dir, 'report.md'), lines.join('\n'));

    this.log(
      `\n${C.bold}${s.fail === 0 ? C.green : C.red}${this.name}: ${s.pass}/${s.total} passed` +
        (s.skip ? `, ${s.skip} skipped` : '') +
        `${C.reset}  ${C.dim}${path.relative(d.ROOT, this.dir)}${C.reset}`
    );
    return json;
  }
}

const esc = (s) => String(s).replace(/\|/g, '\\|').replace(/\n/g, ' ');

/** Assert helpers that throw with the on-screen labels attached. */
function must(cond, msg) {
  if (!cond) {
    let visible = '';
    try {
      visible = `[${d.visibleLabels().join(' | ')}]`;
    } catch (_) {
      /* dump may already be failing */
    }
    throw new Error(`${msg} — visible: ${visible}`);
  }
}

const eq = (actual, expected, what) =>
  must(actual === expected, `${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);

const ok = (actual, what) => must(actual, `${what}: falsy (${JSON.stringify(actual)})`);

module.exports = { Suite, must, eq, ok, Skip, REPORTS, acquireLock };
