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
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { readWav, fundamental, rms } from './lib/audio-compare.mjs';

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

function packOperator(bytes, at, coarse, level, vel, envLevels) {
  bytes.set(FLAT.rates, at);
  bytes.set(envLevels ?? FLAT.levels, at + 4);
  bytes[at + 8] = 39;              // break point C3, depths 0 — no key scaling
  bytes[at + 12] = 7 << 3;         // detune centred, rate scaling 0
  bytes[at + 13] = vel << 2;       // velocity sensitivity, amp-mod 0
  bytes[at + 14] = level;
  bytes[at + 15] = coarse << 1;    // ratio mode
}

function packVoice(bank, index, { algorithm, feedback, ops, name, lfo }) {
  const voice = bank.subarray(index * 128, (index + 1) * 128);
  for (let slot = 0; slot < 6; ++slot) {
    const op = 6 - slot;
    const { coarse = 1, level = 0, vel = 0, envLevels } = ops[op] ?? {};
    packOperator(voice, slot * 17, coarse, level, vel, envLevels);
  }
  voice.fill(50, 102, 110);        // pitch EG neutral
  voice[110] = algorithm;
  voice[111] = feedback;
  if (lfo) {
    voice[112] = lfo.speed;
    voice[113] = lfo.delay;
    voice[114] = lfo.pmd;
    voice[116] = (lfo.pms << 4) | (4 << 1);  // sine wave, sync off
  }
  voice[117] = 24;                 // transpose: none
  const padded = `${name}          `.slice(0, 10);
  for (let i = 0; i < 10; ++i) voice[118 + i] = padded.charCodeAt(i);
}

// Modulator levels chosen to sweep the index ladder: units 88..127, indices
// 2^(units/8 - 14.875) of roughly 0.07, 0.30, 0.55, 1.09 and 2.00 cycles.
const MOD_LEVELS = [60, 77, 85, 92, 99];
const FEEDBACKS = [3, 5, 7];

// The index carriers run at full level, which is the top of the very ladder under
// test. That was not always possible: dx7-ref originally wrote buf/2^24 with no
// headroom, and a full-level carrier is gain 2^25 — the oracle's own WAV
// hard-clipped at +-1.0, which showed up here as strong odd harmonics that looked
// like an index disagreement (fb-3's H3 at -14 dB was the giveaway: near-zero
// feedback cannot make that; a clipper can). dx7-ref now renders at /2^27, and
// this constant is the regression trap: if the headroom ever regresses, the
// clipping harmonics come straight back into these spectra.
const CARRIER_LEVEL = 99;

// The feedback carriers sit lower, and that limit is real, not caution: at fb 7 a
// full-level op displaces its own phase by a full cycle, and there msfa's
// fixed-point loop falls into a period-doubled attractor (H2 dominant, H1 at
// -38 dB) that our float loop does not share. The boundary is not even monotonic —
// probing the oracle found L95 subharmonic but L99 borderline-locked, L91 and
// below clean. Level 91 is amplitude 0.5, so fb 7 still swings half a cycle:
// strong enough that the old 2x feedback constant fails by tens of dB, safely
// inside the region where both engines agree on what feedback *is*. Deep-feedback
// chaos parity is a fidelity note, not something a scale check can hold.
const FEEDBACK_CARRIER_LEVEL = 91;

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
    ops: { 6: { coarse: 1, level: FEEDBACK_CARRIER_LEVEL } } });
}

// The LFO delay, held in the time domain instead of the spectrum: a lone sine
// carrier with a huge vibrato (PMD 99 through sensitivity 7, about +-1 octave, at
// 1.6 Hz — slow enough that pitch is quasi-stable inside a 0.1 s window) behind
// delay 55, which lfo.cc decodes to a 0.38 s hold and a 0.67 s ramp. Both engines'
// pitch trajectories are measured window by window; they share the LFO's exact
// rate and phase (sine starts at zero, rising, on both), so the only allowed
// disagreement is the documented fade-shape approximation — the squared ramp
// reaches 13% where the chip still holds zero, which is why the tolerance is
// 0.2 octaves pointwise and not less.
cases.push({ algorithm: 0, feedback: 0, name: 'DLY', kind: 'fade',
  ops: { 1: { coarse: 1, level: CARRIER_LEVEL } },
  lfo: { speed: 10, delay: 55, pmd: 99, pms: 7 } });

// Algorithms 4 and 6 loop feedback *through* other operators (OP4->OP6 and
// OP5->OP6). The oracle runs those loops open — fm_core.cc's "todo: more than one
// op in a feedback loop"; FB_IN alone takes the pure path — and the import now
// carries msfa's verbatim table so it runs them open too. These voices set
// feedback 7, the loudest possible loop: under the old Dexed-style table edit
// (self-feedback on OP6) they disagree with the oracle by tens of dB in the upper
// harmonics, which is exactly the drift these cases exist to catch.
cases.push({ algorithm: 3, feedback: 7, name: 'LOOP4',
  ops: { 4: { coarse: 1, level: 80 }, 5: { coarse: 1, level: 85 },
    6: { coarse: 1, level: 85 } } });
cases.push({ algorithm: 5, feedback: 7, name: 'LOOP6',
  ops: { 5: { coarse: 1, level: 80 }, 6: { coarse: 1, level: 85 } } });

// Velocity reaching the feedback loop, held spectrally: a feedback-7 carrier with
// full velocity sensitivity, struck softly. On the chip the loop displaces by the
// gain-scaled output, so a soft strike thins the feedback bite along with the
// level; the import routes its velocity curve into the sine's feedback input to
// match. Without that wire the harmonic ladder renders at full-velocity bite and
// disagrees by tens of dB — this is the oracle-held proxy for the whole
// feedback-input path, tremolo included (tremolo rides the identical wire but has
// no oracle to answer to). Struck at 50, not 60: the squared-affine velocity
// curve is 11% hot at 60 (its documented worst spot), and feedback compounds that
// up the ladder to 2.85 dB at H6; at 50 the curve crosses the table almost
// exactly (0.156 vs 0.155), so this case measures the wire, not the known fit
// error the VEL case already bounds.
cases.push({ algorithm: 31, feedback: 7, name: 'FBVEL', velocity: 50,
  ops: { 6: { coarse: 1, level: FEEDBACK_CARRIER_LEVEL, vel: 7 } } });

// The envelope reaching the feedback loop, held spectrally: a feedback-7 carrier
// whose envelope *sustains below its peak* (L3 77 against L1 99). On the chip the
// loop displaces by the gain-scaled output, so the bite thins as the envelope
// falls; the import's fbscale multiplies the envelope into the sine's feedback
// input to match, and the sustain window here measures exactly that thinned bite.
// Without the wire the ladder renders at peak bite (0.5 cycles instead of 0.074)
// and misses by tens of dB. Sustain level 77 on purpose: msfa's envelope target
// is (scaleoutlevel>>1)<<6, which drops the odd bit — the peak's 127 loses it,
// and a sustain level whose scaleoutlevel is odd too (28+77 = 105) loses the same
// half-unit, so the sustain/peak ratio the wire carries matches the oracle's
// exactly instead of inheriting a 0.75 dB offset.
cases.push({ algorithm: 31, feedback: 7, name: 'FBENV',
  ops: { 6: { coarse: 1, level: FEEDBACK_CARRIER_LEVEL,
    envLevels: [99, 88, 77, 0] } } });

// Live velocity, held as a response curve: a lone full-sensitivity carrier struck
// at four velocities, each engine's loudness taken relative to its own strike at
// 100 (so absolute level scales cancel), and the responses must agree within
// 1.5 dB. The import's squared-affine curve is exact at 100 and 127 by
// construction; 50 and 80 are where the fit is being held to the chip's table
// (predicted errors 0.1 and 0.5 dB — the tolerance leaves room for the envelope's
// attack shifting slightly with level, not for a wrong curve). Level 80, not
// full: a full-level carrier struck at 127 gains 1.76x past the importer's
// 0.8-normalised output and clips *our* WAV — the first run of this case read
// +2.3 dB where the curve says +4.9, and that was the writer's clamp, not the
// curve. Ordinary mixing headroom, but not what this case measures.
cases.push({ algorithm: 31, feedback: 0, name: 'VEL', kind: 'velocity',
  ops: { 6: { coarse: 1, level: 80, vel: 7 } } });

const scratch = mkdtempSync(join(tmpdir(), 'dx7-index-'));
// The scratch dir dies with the process: two thousand of these
// leaked across a day of gate runs once filled the disk to zero.
process.on('exit', () => rmSync(scratch, { recursive: true, force: true }));
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

// Pitch per 0.1 s window by plain autocorrelation — fundamental() from the shared
// lib wants its own 0.3 s loudest window, too long for a trajectory. Lag
// quantisation at these frequencies is ~0.003 octaves, far under the tolerance.
function windowF0(wav, startSeconds) {
  const { samples, rate } = wav;
  const start = Math.floor(startSeconds * rate);
  const seg = samples.slice(start, start + Math.floor(0.1 * rate));
  const minLag = Math.floor(rate / 500);
  const maxLag = Math.floor(rate / 100);
  let best = 0;
  let bestLag = 0;
  for (let lag = minLag; lag <= maxLag; ++lag) {
    let c = 0;
    for (let i = 0; i + lag < seg.length; ++i) c += seg[i] * seg[i + lag];
    if (c > best) { best = c; bestLag = lag; }
  }
  return bestLag > 0 ? rate / bestLag : 0;
}

// The vibrato trajectory: |octaves from the carrier| in each window.
const deviations = (wav) => {
  const out = [];
  for (let t = 0.1; t <= 1.25; t += 0.1) {
    out.push(Math.abs(Math.log2(Math.max(1, windowF0(wav, t)) / 220)));
  }
  return out;
};

const slug = (name) => name.toLowerCase().replace(/[^a-z0-9]+/g, '-')
  .replace(/^-|-$/g, '');

let failures = 0;
for (const c of cases) {
  const id = slug(c.name);

  // Both engines must be struck equally hard now that the imports respond to
  // velocity live: the oracle plays MIDI units, sg-render plays fractions.
  const renderPair = (oracleWav, oursWav, velocity) => {
    execFileSync(join(bin, 'dx7-ref'), [bankPath, String(cases.indexOf(c)),
      oracleWav, '--seconds', '2', '--note', String(NOTE), '--gate', '0.7',
      '--velocity', String(velocity)]);
    execFileSync(join(bin, 'sg-render'), [join(patchDir, `${id}.json`), oursWav,
      '--seconds', '2', '--notes', String(NOTE), '--gate', '0.7',
      '--velocity', String(velocity / 127), '--quiet']);
  };

  if (c.kind === 'velocity') {
    const rmsPair = (velocity) => {
      const o = join(scratch, `${id}-o${velocity}.wav`);
      const u = join(scratch, `${id}-u${velocity}.wav`);
      renderPair(o, u, velocity);
      return { oracle: rms(readWav(o)), ours: rms(readWav(u)) };
    };
    const base = rmsPair(100);
    let worst = 0;
    let worstAt = 0;
    const readings = [];
    for (const velocity of [50, 80, 127]) {
      const r = rmsPair(velocity);
      const oracleDb = 20 * Math.log10(r.oracle / Math.max(base.oracle, 1e-9));
      const oursDb = 20 * Math.log10(r.ours / Math.max(base.ours, 1e-9));
      readings.push(`v${velocity} ${oracleDb.toFixed(1)}/${oursDb.toFixed(1)}`);
      const diff = Math.abs(oracleDb - oursDb);
      if (diff > worst) { worst = diff; worstAt = velocity; }
    }
    const ok = worst <= 1.5;
    if (!ok) failures += 1;
    console.log(`  ${ok ? 'ok  ' : 'FAIL'} ${id.padEnd(10)} velocity response `
      + `(oracle/ours dB re 100): ${readings.join(', ')} — worst gap `
      + `${worst.toFixed(2)} dB at v${worstAt}`);
    continue;
  }

  const oracleWav = join(scratch, `${id}-oracle.wav`);
  const oursWav = join(scratch, `${id}-ours.wav`);
  renderPair(oracleWav, oursWav, c.velocity ?? 100);

  const oracle = readWav(oracleWav);
  const ours = readWav(oursWav);

  if (c.kind === 'fade') {
    // Region-wise, not pointwise: at full depth the pitch sweeps up to an octave
    // *inside* a measurement window, so both trajectories sample the wobble
    // noisily and pointwise gaps there measure the jitter, not the fade. The fade
    // lives where the assertions look — near-zero through the hold, matching
    // average depth through the ramp, and full depth once the fade is done. A
    // missing fade fails the ramp average (it would read ~0.6, the mean of a
    // full-depth |sin|); a missing LFO fails the late depth on one side.
    const oracleDev = deviations(oracle);
    const oursDev = deviations(ours);
    const at = (t) => Math.round((t - 0.1) / 0.1);
    const early = (dev) => Math.max(...dev.slice(0, at(0.35)));
    const rampMean = (dev) => {
      const region = dev.slice(at(0.4), at(1.0));
      return region.reduce((s, d) => s + d, 0) / region.length;
    };
    const late = (dev) => Math.max(...dev.slice(at(1.0)));
    const rampGap = Math.abs(rampMean(oracleDev) - rampMean(oursDev));
    const ok = early(oracleDev) <= 0.1 && early(oursDev) <= 0.1
      && rampGap <= 0.1 && late(oracleDev) > 0.5 && late(oursDev) > 0.5;
    if (!ok) failures += 1;
    console.log(`  ${ok ? 'ok  ' : 'FAIL'} ${id.padEnd(10)} fade: hold `
      + `${early(oracleDev).toFixed(2)}/${early(oursDev).toFixed(2)} oct, ramp mean `
      + `gap ${rampGap.toFixed(3)} oct, late depth `
      + `${late(oracleDev).toFixed(2)}/${late(oursDev).toFixed(2)} oct`);
    if (verbose || !ok) {
      console.log(`       oracle ${oracleDev.map((d) => d.toFixed(2)).join(' ')}`);
      console.log(`       ours   ${oursDev.map((d) => d.toFixed(2)).join(' ')}`);
    }
    continue;
  }

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
console.log(`All ${cases.length} index, feedback and fade cases agree with the oracle.`);
