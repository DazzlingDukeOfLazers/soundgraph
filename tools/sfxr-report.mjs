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
const referenceTool = option('--ref', 'build/bin/sfxr-ref');
const asJson = args.includes('--json');

// --floor answers a question the report cannot: how close could *any* port get?
//
// sfxr's noise waveform is a random draw. Two runs of sfxr itself, on the same sound with
// a different draw, do not have the same spectrum — so there is a distance below which no
// implementation can score, and it is a property of the metric and the material rather
// than of the port. Measuring it is the difference between "the port is 20 dB off" and
// "the port is 20 dB off and so is sfxr, so that number means nothing".
//
// Anything with a wave_type other than noise should come out at zero here: the rest of
// sfxr is deterministic, so the same parameters with a different noise seed are the same
// samples. That doubles as a check that this mode is measuring what it claims to.
const measureFloor = args.includes('--floor');

// How much worse than sfxr-against-itself a case may be and still count as a match. Small,
// because the floor already absorbs the part that is genuinely impossible.
const FLOOR_MARGIN_DB = 1.5;

const manifest = JSON.parse(readFileSync(join(directory, 'manifest.json'), 'utf8'));
const scratch = mkdtempSync(join(tmpdir(), 'sfxr-report-'));

const rows = [];
const floorFailures = [];
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
      if (measureFloor) {
        // Same parameters, different noise draw: sfxr against itself.
        execFileSync(referenceTool, [
          'render', '--preset', entry.preset,
          '--seed', String(entry.seed),
          '--noise-seed', String(entry.seed + 7),
          '--out', candidate,
        ], { stdio: ['ignore', 'ignore', 'pipe'] });
      } else {
        execFileSync(renderer, [
          patch, candidate,
          '--seconds', String(seconds),
          '--sample-rate', String(manifest.sample_rate),
          '--silent', '--float', '--quiet',
        ], { stdio: ['ignore', 'ignore', 'pipe'] });
      }
    } catch (error) {
      rows.push({ name: entry.name, preset: entry.preset, error: String(error.message).trim() });
      continue;
    }

    const metrics = compare(reference, candidate);

    // The spectral threshold is raised to whatever sfxr scores against *itself* on this
    // case, plus a margin.
    //
    // sfxr's noise is a random draw, so two runs of the same sound do not have the same
    // spectrum: on this corpus that self-distance is 4.7 to 6.1 dB for noise and exactly
    // zero for everything else. A flat 6 dB threshold therefore demands that a noise case
    // be reproduced *better than sfxr reproduces itself*, which no implementation can do.
    //
    // This is measured on every run rather than stored, so it cannot go stale, and it is
    // zero for every deterministic waveform — the threshold only moves where randomness
    // genuinely makes it impossible to do better.
    let floor = 0;
    if (!measureFloor) {
      const alternate = join(scratch, `${entry.name}-floor.wav`);
      try {
        execFileSync(referenceTool, [
          'render', '--preset', entry.preset,
          '--seed', String(entry.seed),
          '--noise-seed', String(entry.seed + 7),
          '--out', alternate,
        ], { stdio: ['ignore', 'ignore', 'pipe'] });
        floor = compare(reference, alternate).spectralDb;
      } catch (error) {
        // Not silent. Swallowing this once already cost an hour: under ctest the working
        // directory differs, the default relative path to sfxr-ref did not resolve, every
        // floor came back as zero, and four noise cases were held to a threshold below
        // what sfxr manages against itself. The report said "regression" and the port had
        // not changed at all.
        floorFailures.push(`${entry.name}: ${String(error.message).split('\n')[0]}`);
        floor = 0;
      }
    }

    const thresholds = {
      ...DEFAULT_THRESHOLDS,
      spectralDb: Math.max(DEFAULT_THRESHOLDS.spectralDb, floor + FLOOR_MARGIN_DB),
    };
    const result = verdict(metrics, thresholds);
    rows.push({ name: entry.name, preset: entry.preset, floorDb: floor, ...metrics, ...result });
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
console.log(`  ${pad('case', 18)} ${pad('gain', 7)} ${pad('env', 7)} ${pad('spec', 7)} ` +
            `${pad('floor', 7)}  verdict`);
console.log(`  ${'-'.repeat(18)} ${'-'.repeat(7)} ${'-'.repeat(7)} ${'-'.repeat(7)} ` +
            `${'-'.repeat(7)}  ${'-'.repeat(20)}`);

const byPreset = new Map();
for (const row of rows) {
  if (row.error) {
    console.log(`  ${pad(row.name, 18)} ${pad('', 7)} ${pad('', 7)} ${pad('', 7)}  ERROR ${row.error}`);
    continue;
  }
  const mark = row.pass ? 'ok' : 'no';
  console.log(`  ${pad(row.name, 18)} ${num(row.gainDb)} ${num(row.envelopeDb)} ` +
              `${num(row.spectralDb)} ${num(row.floorDb)}  ${mark}` +
              `${row.pass ? '' : '   ' + row.failures[0]}`);
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

if (floorFailures.length > 0) {
  console.error(`
  WARNING: could not measure the floor for ${floorFailures.length} ` +
                `case(s); they were held to the flat threshold instead, which is too ` +
                `strict for anything using noise.`);
  console.error(`  first: ${floorFailures[0]}`);
  console.error(`  Check --ref points at sfxr-ref.`);
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
