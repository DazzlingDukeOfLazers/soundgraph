#!/usr/bin/env node
// Holds the modulation-index scale to the msfa oracle *spectrally*.
//
//   node tools/dx7-index-check.mjs [--verbose]
//
// The index scale is derived, not fitted: dx7-import.mjs carries the closed form
// (peak index = 2^(units/8 - 14.875) cycles, INDEX_FULL = 2.0 at the top). But a
// derivation can be misread — the OPL and DX7 envelope clocks were both "derived"
// once too, from the wrong clock — so this tool checks the claim where it is
// audible: in the sidebands. FM at index m spreads energy across harmonics by
// Bessel amplitudes, so if our index tracked msfa's ladder wrongly, the harmonic
// pattern would disagree long before anyone measured phase directly.
//
// Synthetic voices, built here and imported through the real import path
// (DX7_SOURCE/DX7_TARGET point the importer at a scratch directory):
//   - a 2:1 modulator->carrier pair with the modulator swept over output levels
//     covering indices ~0.07 to 2.0 cycles
//   - a lone carrier with operator feedback swept 3..7 (feedback got the same
//     derivation: 2^(fb-7) of the op's amplitude — the old 2^(fb-6) was exactly
//     twice msfa's, which this tool is what caught)
// Each voice renders through dx7-ref and through sg-render; the first twelve
// harmonics are measured with a Hann-windowed DFT over the sustain, normalised to
// each render's loudest harmonic, and every harmonic above the -30 dB floor must
// agree within TOLERANCE_DB.

import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { readWav, fundamental } from './lib/audio-compare.mjs';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const bin = join(root, 'build', 'bin');
const verbose = process.argv.includes('--verbose');

const NOTE = 57;                 // A3, the repository's reference note
const HARMONICS = 12;
const FLOOR_DB = -30;            // harmonics quieter than this (re: loudest) are noise
const TOLERANCE_DB = 2.0;

// ---------------------------------------------------------------------------------
// The synthetic bank: packed 128-byte voices, the same format the demo bank uses.
// Envelopes are flat (instant attack, sustain at full) so the whole sustain window
// is steady state and the DFT sees only the index, not the envelope shape.
// ---------------------------------------------------------------------------------

const FLAT = { rates: [99, 99, 99, 99], levels: [99, 99, 99, 0] };

function packOperator(bytes, at, coarse, level) {
  bytes.set(FLAT.rates, at);
  bytes.set(FLAT.levels, at + 4);
  bytes[at + 8] = 39;              // break point C3, depths 0 — no key scaling
  bytes[at + 12] = 7 << 3;         // detune centred, rate scaling 0
  bytes[at + 14] = level;
  bytes[at + 15] = coarse << 1;    // ratio mode
}

function packVoice(bank, index, { algorithm, feedback, ops, name }) {
  const voice = bank.subarray(index * 128, (index + 1) * 128);
  for (let slot = 0; slot < 6; ++slot) {
    const op = 6 - slot;
    const { coarse = 1, level = 0 } = ops[op] ?? {};
    packOperator(voice, slot * 17, coarse, level);
  }
  voice.fill(50, 102, 110);        // pitch EG neutral
  voice[110] = algorithm;
  voice[111] = feedback;
  voice[117] = 24;                 // transpose: none
  const padded = `${name}          `.slice(0, 10);
  for (let i = 0; i < 10; ++i) voice[118 + i] = padded.charCodeAt(i);
}

// Modulator levels chosen to sweep the index ladder: units 88..127, indices
// 2^(units/8 - 14.875) of roughly 0.07, 0.30, 0.55, 1.09 and 2.00 cycles.
const MOD_LEVELS = [60, 77, 85, 92, 99];
const FEEDBACKS = [3, 5, 7];

// Carriers sit at level 80, not 99: dx7-ref writes buf/2^24 with no headroom, and
// a full-level carrier is gain 2^25 — the oracle's own WAV hard-clips at +-1.0,
// which showed up here as strong odd harmonics that looked like an index
// disagreement (fb-3's H3 at -14 dB was the giveaway: near-zero feedback cannot
// make that; a clipper can). The index under test rides the *modulator*, which
// never reaches the WAV, so the sweep loses nothing. Feedback scales with the op's
// own amplitude on both sides, so those cases still exercise the 2^(fb-7) claim.
const CARRIER_LEVEL = 80;

const cases = [];
for (const level of MOD_LEVELS) {
  // Algorithm 1: op2 modulates op1. Everything else sits at output level 0,
  // which on the msfa ladder is genuinely negligible (index 2^-14.875).
  cases.push({ algorithm: 0, feedback: 0, name: `IDX L${level}`,
    ops: { 1: { coarse: 1, level: CARRIER_LEVEL }, 2: { coarse: 2, level } } });
}
for (const feedback of FEEDBACKS) {
  // Algorithm 32: six parallel carriers, feedback on op6 — so the only audible
  // operator is the one feeding itself back.
  cases.push({ algorithm: 31, feedback, name: `FB ${feedback}`,
    ops: { 6: { coarse: 1, level: CARRIER_LEVEL } } });
}

const scratch = mkdtempSync(join(tmpdir(), 'dx7-index-'));
const bankDir = join(scratch, 'banks');
const patchDir = join(scratch, 'patches');
mkdirSync(bankDir);

const bank = new Uint8Array(4096);
cases.forEach((c, i) => packVoice(bank, i, c));
let sum = 0;
for (const byte of bank) sum += byte;
const bankPath = join(bankDir, 'index-check.syx');
writeFileSync(bankPath, Buffer.concat([
  Buffer.from([0xf0, 0x43, 0x00, 0x09, 0x20, 0x00]),
  Buffer.from(bank),
  Buffer.from([(128 - (sum & 127)) & 127, 0xf7]),
]));

execFileSync(process.execPath, [join(root, 'tools', 'dx7-import.mjs')], {
  env: { ...process.env, DX7_SOURCE: bankDir, DX7_TARGET: patchDir },
  stdio: 'ignore',
});

// ---------------------------------------------------------------------------------
// Measurement: Hann-windowed DFT at each render's own harmonic lattice. Correlating
// against each engine's measured f0 (they differ by under a cent, float tuning vs
// Freqlut) keeps the comparison about sideband *amplitudes*, not tuning.
// ---------------------------------------------------------------------------------

function harmonicsDb(wav, f0) {
  const { samples, rate } = wav;
  const start = Math.floor(0.4 * rate);
  const end = Math.min(samples.length, Math.floor(1.2 * rate));
  const length = end - start;
  const magnitudes = [];
  for (let h = 1; h <= HARMONICS; ++h) {
    const w = (2 * Math.PI * f0 * h) / rate;
    let re = 0;
    let im = 0;
    for (let n = 0; n < length; ++n) {
      const hann = 0.5 - 0.5 * Math.cos((2 * Math.PI * n) / (length - 1));
      const s = samples[start + n] * hann;
      re += s * Math.cos(w * n);
      im -= s * Math.sin(w * n);
    }
    magnitudes.push(Math.hypot(re, im));
  }
  const peak = Math.max(...magnitudes, 1e-12);
  return magnitudes.map((m) => 20 * Math.log10(Math.max(m, 1e-12) / peak));
}

const slug = (name) => name.toLowerCase().replace(/[^a-z0-9]+/g, '-')
  .replace(/^-|-$/g, '');

let failures = 0;
for (const c of cases) {
  const id = slug(c.name);
  const oracleWav = join(scratch, `${id}-oracle.wav`);
  const oursWav = join(scratch, `${id}-ours.wav`);
  execFileSync(join(bin, 'dx7-ref'), [bankPath, String(cases.indexOf(c)), oracleWav,
    '--seconds', '2', '--note', String(NOTE), '--gate', '0.7']);
  execFileSync(join(bin, 'sg-render'), [join(patchDir, `${id}.json`), oursWav,
    '--seconds', '2', '--notes', String(NOTE), '--gate', '0.7', '--quiet']);

  const oracle = readWav(oracleWav);
  const ours = readWav(oursWav);
  const oracleDb = harmonicsDb(oracle, fundamental(oracle, 100));
  const oursDb = harmonicsDb(ours, fundamental(ours, 100));

  let worst = 0;
  let worstAt = 0;
  for (let h = 0; h < HARMONICS; ++h) {
    if (oracleDb[h] < FLOOR_DB && oursDb[h] < FLOOR_DB) continue;
    const diff = Math.abs(oracleDb[h] - oursDb[h]);
    if (diff > worst) { worst = diff; worstAt = h + 1; }
  }
  const ok = worst <= TOLERANCE_DB;
  if (!ok) failures += 1;
  console.log(`  ${ok ? 'ok  ' : 'FAIL'} ${id.padEnd(10)} worst harmonic `
    + `disagreement ${worst.toFixed(2)} dB (H${worstAt})`);
  if (verbose || !ok) {
    console.log(`       oracle ${oracleDb.map((d) => d.toFixed(1)).join(' ')}`);
    console.log(`       ours   ${oursDb.map((d) => d.toFixed(1)).join(' ')}`);
  }
}

if (failures > 0) {
  console.error(`\n${failures} case(s) disagree with the oracle's index scale.`);
  process.exit(1);
}
console.log(`All ${cases.length} index/feedback cases agree with the oracle within `
  + `${TOLERANCE_DB} dB per harmonic.`);
