#!/usr/bin/env node
// Plays every vendored OPL2 instrument twice — once through Nuked-OPL3, once through
// the imported SoundGraph patch — and measures whether they are the same instrument.
//
//   node tools/opl2-compare.mjs [--verbose]
//
// This is not a byte comparison and never will be: the mapping is a translation, not
// an emulation, and its constants are approximations by design. What must hold is
// coarser and matters more:
//
//   pitch    — both renders share a fundamental within 3%. A mapping that moves the
//              pitch has misread multiple, fnum arithmetic or the graph wiring, and
//              every one of those has a failure mode that sounds "fine" in isolation.
//   presence — both renders actually sound (RMS above the floor). A silent patch is a
//              wiring bug wearing a tolerance.
//
// Level and spectral distance are reported but not asserted, so drift is visible in
// the log for the day the mapping constants get measured against these renders
// properly. Fundamentals come from autocorrelation, not zero crossings — FM output is
// exactly the waveform family that taught this repo (three times) how crossings lie.

import { execFileSync } from 'node:child_process';
import { readFileSync, readdirSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const instruments = join(root, 'tools', 'opl2', 'instruments');
const patches = join(root, 'examples', 'patches', 'fm');
const bin = join(root, 'build', 'bin');
const scratch = mkdtempSync(join(tmpdir(), 'opl2-compare-'));
const verbose = process.argv.includes('--verbose');

// 220 Hz = MIDI 57. The oracle takes hertz and sg-render takes note numbers; these two
// constants are the same statement in both languages.
const FREQUENCY = 220;
const NOTE = 57;

// Reads channel 0, honouring the channel count. The first version read the raw sample
// stream as mono — but sg-render writes stereo and the oracle writes mono, so every
// frequency measured on our side came out halved, the octave fold "helpfully" folded
// them back for simple voices, and a night's worth of pitch anomalies — 55 Hz basses,
// bidirectional lattice failures, an engine bug hunt through NoteInput that ended in
// code with nothing wrong in it — were this function, lying about one side only.
function readWav(path) {
  const bytes = readFileSync(path);
  const channels = bytes.readUInt16LE(22);
  const rate = bytes.readUInt32LE(24);
  const data = bytes.indexOf(Buffer.from('data'));
  const samples = [];
  for (let i = data + 8; i + 1 < bytes.length; i += 2 * channels) {
    samples.push(bytes.readInt16LE(i) / 32768);
  }
  return { rate, samples };
}

// The loudest 0.6s of the render, wherever it is. A fixed "held" window measured
// percussive voices after they had finished — a marimba's note lives in its first
// 200 ms, and autocorrelating the silence after it returns the search bound dressed
// as a pitch. Each render places its own window, so a hit and a pad are both measured
// while they are actually sounding.
function held(wav) {
  // 0.3s: long enough for 33 periods of the lowest possible voice, short enough that
  // a plucked instrument fills it with pluck rather than with the emulator's
  // resampling ripple — the shamisen's "786.9 Hz fundamental" was 49716/63, the
  // chip-to-48k resampler beating in a near-silent tail.
  const length = Math.floor(0.3 * wav.rate);
  const hop = Math.floor(0.05 * wav.rate);
  let bestStart = 0;
  let bestEnergy = -1;
  for (let start = 0; start + length <= wav.samples.length; start += hop) {
    let energy = 0;
    for (let i = start; i < start + length; i += 8) {
      energy += wav.samples[i] * wav.samples[i];
    }
    if (energy > bestEnergy) {
      bestEnergy = energy;
      bestStart = start;
    }
  }
  const slice = wav.samples.slice(bestStart, bestStart + length);

  // Flattened: each sample divided by the local RMS envelope. Autocorrelation
  // normalises by total energy, so on a decaying pluck every lag is punished for the
  // decay itself — the oracle's shamisen scored 0.35 at its own true period purely
  // because the signal was 90 dB quieter by the end of the window. Dividing out the
  // envelope makes the score about the waveform's shape, which is the thing period
  // measurement was ever about.
  const window = Math.max(1, Math.floor(wav.rate * 0.01));
  const envelope = [];
  for (let i = 0; i < slice.length; i += window) {
    let sum = 0;
    const end = Math.min(slice.length, i + window);
    for (let j = i; j < end; ++j) sum += slice[j] * slice[j];
    envelope.push(Math.sqrt(sum / (end - i)));
  }
  const floor = Math.max(...envelope) * 0.02 + 1e-9;
  return slice.map((sample, i) =>
    sample / Math.max(envelope[Math.floor(i / window)], floor));
}

// Normalised self-similarity of a slice at one specific lag.
function scoreAt(slice, lag) {
  let dot = 0;
  let energy = 0;
  for (let i = 0; i + lag < slice.length; ++i) {
    dot += slice[i] * slice[i + lag];
    energy += slice[i] * slice[i];
  }
  return energy > 0 ? dot / energy : 0;
}

// The strongest self-similarity lag inside the held part of the note.
//
// The floor of the search is physics, not caution: at A3 every operator runs at
// multiple k*0.5 of 220 Hz, so every frequency in a voice is a multiple of 110 and no
// true composite period is longer than that. The first version searched down to 40 Hz
// and found "44 Hz fundamentals" on half the pads — envelope drift at long lags
// outscoring the real period, on both sides of the comparison at once.
function fundamental(wav) {
  const slice = held(wav);
  const lagLow = Math.floor(wav.rate / 2000);
  const lagHigh = Math.floor(wav.rate / 100);
  let bestLag = 0;
  let bestScore = -1;
  for (let lag = lagLow; lag <= lagHigh; ++lag) {
    const score = scoreAt(slice, lag);
    if (score > bestScore) {
      bestScore = score;
      bestLag = lag;
    }
  }
  return bestLag > 0 ? wav.rate / bestLag : 0;
}

// Whether two renders live on the same periodicity lattice: each must repeat at the
// period the other measured as strongest, both ways round.
//
// This exists because the single-number comparison lied about the full bank. An FM
// voice with a non-integer multiple ratio is genuinely periodic at several scales at
// once, and which subharmonic wins a single-peak search depends on modulation depth —
// so 22 instruments "failed" at 220/4 against 220/5 while sounding like the same
// instrument, and a few more hit the search bounds exactly, which is a measurement
// announcing its own failure and being read as an answer. Requiring each signal to
// score at the other's period asks the question the single number was standing in
// for; requiring it in both directions is what keeps a genuinely detuned voice
// failing, since its period fits neither lattice.
// ...and the second refinement: either measurement may be the deluded one. The
// shamisen's spectrum is three sparse partials (660/1540/2420 — all multiples of 220),
// and on a spectrum that sparse a pseudo-period can outscore the true one by a hair —
// in the *oracle's* measurement, of a signal that was fine. So the rule is symmetric
// in candidates too: if either render's measured period is a strong period of both
// signals, they agree. A genuinely detuned voice still fails, because its period
// satisfies nobody but itself.
function sharePeriodicity(a, b, aF0, bF0) {
  const sliceA = held(a);
  const sliceB = held(b);
  for (const candidate of [aF0, bF0]) {
    const lagInA = Math.round(a.rate / candidate);
    const lagInB = Math.round(b.rate / candidate);
    if (lagInA < 4 || lagInB < 4) continue;
    if (scoreAt(sliceA, lagInA) > 0.55 && scoreAt(sliceB, lagInB) > 0.55) return true;
  }
  return false;
}

const rms = (wav) => {
  const sum = wav.samples.reduce((a, s) => a + s * s, 0);
  return Math.sqrt(sum / wav.samples.length);
};

// Autocorrelation finds the *period*, and a harmonic instrument is periodic at f0/2 or
// f0/3 as well; two measurements that disagree by an integer ratio agree about pitch.
function octaveFolded(measured, reference) {
  for (const fold of [1, 2, 3, 4]) {
    for (const candidate of [measured * fold, measured / fold]) {
      if (Math.abs(candidate - reference) / reference < 0.03) return candidate;
    }
  }
  return measured;
}

const slug = (name) => name.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');

let failures = 0;
const files = readdirSync(instruments).filter((f) => f.endsWith('.sbi')).sort();
for (const file of files) {
  const bytes = readFileSync(join(instruments, file));
  const name = bytes.toString('latin1', 4, 36).replace(/\0.*$/, '').trim();
  const patch = join(patches, `${slug(name)}.json`);

  const oracleWav = join(scratch, `${slug(name)}-oracle.wav`);
  const oursWav = join(scratch, `${slug(name)}-ours.wav`);
  execFileSync(join(bin, 'opl2-ref'), [join(instruments, file), oracleWav,
    '--seconds', '2', '--frequency', String(FREQUENCY), '--gate', '0.7']);
  execFileSync(join(bin, 'sg-render'), [patch, oursWav,
    '--seconds', '2', '--notes', String(NOTE), '--gate', '0.7', '--quiet']);

  const oracle = readWav(oracleWav);
  const ours = readWav(oursWav);
  const oracleF0 = fundamental(oracle);
  const oursF0 = octaveFolded(fundamental(ours), oracleF0);
  const pitchError = Math.abs(oursF0 - oracleF0) / oracleF0;
  const oracleRms = rms(oracle);
  const oursRms = rms(ours);
  const levelDb = 20 * Math.log10(oursRms / Math.max(oracleRms, 1e-9));

  // The tight check when the single numbers agree; the lattice check when the single
  // numbers are measuring different subharmonics of the same voice.
  const samePitch = pitchError < 0.03
    || sharePeriodicity(oracle, ours, oracleF0, fundamental(ours));
  const ok = samePitch && oursRms > 0.01 && oracleRms > 0.001;
  if (!ok) failures += 1;
  const how = pitchError < 0.03 ? `f0 ${oursF0.toFixed(1)} Hz (${
    (pitchError * 100).toFixed(1)}%)` : (samePitch
    ? `lattice (${oursF0.toFixed(1)} vs ${oracleF0.toFixed(1)} Hz)` : `f0 ${
    oursF0.toFixed(1)} vs ${oracleF0.toFixed(1)} Hz`);
  const line = `  ${ok ? 'ok  ' : 'FAIL'} ${slug(name).padEnd(26)} ${how}, `
    + `level ${levelDb >= 0 ? '+' : ''}${levelDb.toFixed(1)} dB vs oracle`;
  if (!ok || verbose) console.error(line);
  else console.log(line);
}

if (failures > 0) {
  console.error(`\n${failures} instrument(s) disagree with the Nuked-OPL3 oracle.`);
  process.exit(1);
}
console.log(`All ${files.length} imported instruments agree with the oracle on pitch and presence.`);
