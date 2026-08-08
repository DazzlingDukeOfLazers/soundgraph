// Renders every generated patch and compares it against what sfxr produced.
//
//   node tools/sfxr-report.mjs [--dir tests/sfxr] [--render build/bin/sg-render] [--json]
//
// This is the whole point of the rig: one table, one line per case, saying how far the
// port is from the thing it claims to reproduce. It is expected to have failures in it —
// a report that only ever says "all good" is not measuring anything.

import { execFileSync } from 'node:child_process';
import { readFileSync, mkdtempSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

import { compare, verdict, DEFAULT_THRESHOLDS } from './compare-waveforms.mjs';

const args = process.argv.slice(2);
const option = (name, fallback) => {
  const at = args.indexOf(name);
  return at >= 0 && at + 1 < args.length ? args[at + 1] : fallback;
};

const directory = option('--dir', 'tests/sfxr');
const renderer = option('--render', 'build/bin/sg-render');
const asJson = args.includes('--json');

const manifest = JSON.parse(readFileSync(join(directory, 'manifest.json'), 'utf8'));
const scratch = mkdtempSync(join(tmpdir(), 'sfxr-report-'));

const rows = [];
try {
  for (const entry of manifest.cases) {
    const patch = join(directory, 'patches', `${entry.name}.json`);
    const reference = join(directory, 'vectors', `${entry.name}.wav`);
    const candidate = join(scratch, `${entry.name}.wav`);

    // Rendered to exactly the reference's length: sfxr stops when its envelope finishes,
    // and the graph has no equivalent notion of "the sound is over". Length is still
    // compared, because a mismatch shows up as the tail being silent in one and not the
    // other — it just cannot be read off the file size.
    const seconds = entry.samples / manifest.sample_rate;
    try {
      execFileSync(renderer, [
        patch, candidate,
        '--seconds', String(seconds),
        '--sample-rate', String(manifest.sample_rate),
        '--silent', '--float', '--quiet',
      ], { stdio: ['ignore', 'ignore', 'pipe'] });
    } catch (error) {
      rows.push({ name: entry.name, preset: entry.preset, error: String(error.message).trim() });
      continue;
    }

    const metrics = compare(reference, candidate);
    const result = verdict(metrics, DEFAULT_THRESHOLDS);
    rows.push({ name: entry.name, preset: entry.preset, ...metrics, ...result });
  }
} finally {
  rmSync(scratch, { recursive: true, force: true });
}

if (asJson) {
  console.log(JSON.stringify({ thresholds: DEFAULT_THRESHOLDS, cases: rows }, null, 2));
  process.exit(0);
}

const pad = (s, n) => String(s).padEnd(n);
const num = (v, n = 2) => (Number.isFinite(v) ? v.toFixed(n) : '--').padStart(7);

console.log(`sfxr port report — ${rows.length} cases at ${manifest.sample_rate} Hz`);
console.log(`thresholds: length +/-${(DEFAULT_THRESHOLDS.lengthTolerance * 100).toFixed(0)}%, ` +
            `gain ${DEFAULT_THRESHOLDS.gainDb} dB, envelope ${DEFAULT_THRESHOLDS.envelopeDb} dB, ` +
            `spectrum ${DEFAULT_THRESHOLDS.spectralDb} dB\n`);
console.log(`  ${pad('case', 18)} ${pad('gain', 7)} ${pad('env', 7)} ${pad('spec', 7)}  verdict`);
console.log(`  ${'-'.repeat(18)} ${'-'.repeat(7)} ${'-'.repeat(7)} ${'-'.repeat(7)}  ${'-'.repeat(20)}`);

const byPreset = new Map();
for (const row of rows) {
  if (row.error) {
    console.log(`  ${pad(row.name, 18)} ${pad('', 7)} ${pad('', 7)} ${pad('', 7)}  ERROR ${row.error}`);
    continue;
  }
  const mark = row.pass ? 'ok' : 'no';
  console.log(`  ${pad(row.name, 18)} ${num(row.gainDb)} ${num(row.envelopeDb)} ` +
              `${num(row.spectralDb)}  ${mark}${row.pass ? '' : '   ' + row.failures[0]}`);
  const stats = byPreset.get(row.preset) ?? { pass: 0, total: 0, spectral: [] };
  stats.total++;
  if (row.pass) stats.pass++;
  if (Number.isFinite(row.spectralDb)) stats.spectral.push(row.spectralDb);
  byPreset.set(row.preset, stats);
}

console.log('\n  by generator');
for (const [preset, stats] of [...byPreset].sort()) {
  const median = stats.spectral.sort((a, b) => a - b)[Math.floor(stats.spectral.length / 2)];
  console.log(`  ${pad(preset, 18)} ${stats.pass}/${stats.total} within threshold, ` +
              `median spectral distance ${median === undefined ? '--' : median.toFixed(2)} dB`);
}

const passed = rows.filter((r) => r.pass).length;
console.log(`\n  ${passed} of ${rows.length} cases match sfxr within the current thresholds.`);

// A ratchet rather than a target. The port is not finished and the honest number today is
// not 41; what must not happen is that number quietly going down while something else is
// being changed. Raise it when the port improves — that is the whole point of it.
const minimum = Number(option('--min-pass', 'NaN'));
if (Number.isFinite(minimum)) {
  if (passed < minimum) {
    console.error(`\n  REGRESSION: ${passed} passing, but at least ${minimum} were ` +
                  `passing when this was last measured.`);
    process.exit(1);
  }
  if (passed > minimum) {
    console.log(`  ${passed} > ${minimum}: raise --min-pass in tests/CMakeLists.txt.`);
  }
}
