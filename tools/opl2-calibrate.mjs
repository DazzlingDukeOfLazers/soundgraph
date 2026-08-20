#!/usr/bin/env node
// Measures the OPL envelope clock against Nuked-OPL3, so the importer's rate→time
// curve is a measurement instead of a fit.
//
//   node tools/opl2-calibrate.mjs
//
// Method: synthesise single-purpose SBI instruments — a bare carrier, modulator
// silenced — with one envelope rate under test, render each through the oracle at
// A3, and read the time off the amplitude envelope. Attack is time to 90% of peak;
// decay and release are time to fall 20 dB. Each family is measured at several rates
// and reported as the per-rate constant k in t = k * 2^(15 - rate), which is the
// doubling law the chip's own clock follows; if k is stable across rates, the law
// holds and one number captures it.
//
// KSR is measured the same way rather than reasoned about: the chip adds a pitch-
// derived offset to the effective rate when the bit is set, so the same register
// value runs faster at A3 with KSR on. The report gives the offset in rate steps.
//
// The output is meant to be pasted into tools/opl2-import.mjs by a person, with this
// script named in the comment — the constants change only when the oracle does.

import { execFileSync } from 'node:child_process';
import { writeFileSync, readFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const bin = join(root, 'build', 'bin');
const scratch = mkdtempSync(join(tmpdir(), 'opl2-calibrate-'));
// The scratch dir dies with the process: two thousand of these
// leaked across a day of gate runs once filled the disk to zero.
process.on('exit', () => rmSync(scratch, { recursive: true, force: true }));

function sbi({ carAttack = 15, carDecay = 15, carSustain = 0, carRelease = 15,
    ksr = false }) {
  const bytes = Buffer.alloc(52);
  bytes.write('SBI\x1a', 0, 'latin1');
  bytes.write('calibration', 4, 'latin1');
  const character = 0x20 | (ksr ? 0x10 : 0) | 0x01;  // sustaining, mult 1
  bytes[36] = character;              // modulator
  bytes[37] = character;              // carrier
  bytes[38] = 0x3f;                   // modulator TL 63: silent
  bytes[39] = 0x00;                   // carrier TL 0: full
  bytes[40] = 0xff;                   // modulator AD: instant
  bytes[41] = (carAttack << 4) | carDecay;
  bytes[42] = 0xf0;                   // modulator SR: sustain silent-ish, release slow
  bytes[43] = (carSustain << 4) | carRelease;
  bytes[46] = 0x00;                   // feedback 0, FM connection (silent mod = bare sine)
  return bytes;
}

function render(instrument, seconds, gate) {
  const sbiPath = join(scratch, 'case.sbi');
  const wavPath = join(scratch, 'case.wav');
  writeFileSync(sbiPath, instrument);
  execFileSync(join(bin, 'opl2-ref'), [sbiPath, wavPath,
    '--seconds', String(seconds), '--frequency', '220', '--gate', String(gate)]);
  const bytes = readFileSync(wavPath);
  const data = bytes.indexOf(Buffer.from('data'));
  const rate = bytes.readUInt32LE(24);
  const samples = [];
  for (let i = data + 8; i + 1 < bytes.length; i += 2) {
    samples.push(bytes.readInt16LE(i) / 32768);
  }
  return { rate, samples };
}

// Amplitude envelope: RMS over 5 ms windows.
function envelope(wav) {
  const window = Math.floor(wav.rate * 0.005);
  const points = [];
  for (let start = 0; start + window <= wav.samples.length; start += window) {
    let sum = 0;
    for (let i = start; i < start + window; ++i) sum += wav.samples[i] ** 2;
    points.push(Math.sqrt(sum / window));
  }
  return { step: window / wav.rate, points };
}

const law = (seconds, rate) => seconds / Math.pow(2, 15 - rate);

console.log('attack: time to 90% of peak, k = t / 2^(15-rate)');
for (const ksr of [false, true]) {
  const ks = [];
  for (const rate of [6, 7, 8, 9, 10]) {
    const wav = render(sbi({ carAttack: rate, ksr }), 6, 0.95);
    const env = envelope(wav);
    const peak = Math.max(...env.points);
    const reached = env.points.findIndex((p) => p >= 0.9 * peak);
    const seconds = reached * env.step;
    ks.push(law(seconds, rate));
    console.log(`  ksr=${ksr ? 'on ' : 'off'} rate ${rate}: ${
      seconds.toFixed(3)}s  k=${law(seconds, rate).toExponential(3)}`);
  }
  ks.sort((a, b) => a - b);
  console.log(`  median k (ksr ${ksr ? 'on' : 'off'}): ${
    ks[Math.floor(ks.length / 2)].toExponential(3)}`);
}

console.log('decay: time to fall 20 dB from peak toward SL=15, same law');
for (const ksr of [false, true]) {
  const ks = [];
  for (const rate of [6, 7, 8, 9, 10]) {
    const wav = render(sbi({ carDecay: rate, carSustain: 15, ksr }), 6, 0.95);
    const env = envelope(wav);
    const peak = Math.max(...env.points);
    const peakAt = env.points.indexOf(peak);
    const fallen = env.points.findIndex(
      (p, i) => i > peakAt && p <= peak * 0.1);
    if (fallen < 0) { console.log(`  ksr=${ksr} rate ${rate}: no fall`); continue; }
    const seconds = (fallen - peakAt) * env.step;
    ks.push(law(seconds, rate));
    console.log(`  ksr=${ksr ? 'on ' : 'off'} rate ${rate}: ${
      seconds.toFixed(3)}s  k=${law(seconds, rate).toExponential(3)}`);
  }
  ks.sort((a, b) => a - b);
  if (ks.length > 0) {
    console.log(`  median k (ksr ${ksr ? 'on' : 'off'}): ${
      ks[Math.floor(ks.length / 2)].toExponential(3)}`);
  }
}
