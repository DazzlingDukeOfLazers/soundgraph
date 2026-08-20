#!/usr/bin/env node
// Measures the DX7 envelope clock against the msfa oracle, the same way
// opl2-calibrate.mjs measured OPL against Nuked: synthetic single-purpose voices,
// rendered through the reference, timed off the amplitude envelope.
//
//   node tools/dx7-calibrate.mjs
//
// Each probe bank is one voice on algorithm 32 with only OP1 audible, so the
// envelope under test is the only thing moving. Attack is time to 90% of peak;
// decay and release are time to fall 20 dB. The report fits t = A * 2^(-rate / B)
// and prints A and B per family — if the doubling-per-B-steps law holds, the fit
// residuals stay small and two numbers capture the family. The output is meant to be
// pasted into tools/dx7-import.mjs by a person, with this script named in the
// comment.

import { execFileSync } from 'node:child_process';
import { writeFileSync, readFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const bin = join(root, 'build', 'bin');
const scratch = mkdtempSync(join(tmpdir(), 'dx7-calibrate-'));
// The scratch dir dies with the process: two thousand of these
// leaked across a day of gate runs once filled the disk to zero.
process.on('exit', () => rmSync(scratch, { recursive: true, force: true }));

function probeBank({ rates, levels }) {
  const bank = new Uint8Array(4096);
  const voice = bank.subarray(0, 128);
  for (let slot = 0; slot < 6; ++slot) {
    const at = slot * 17;
    voice.set([99, 99, 99, 99], at);       // instant everything by default
    voice.set([0, 0, 0, 0], at + 4);       // and silent
    voice[at + 8] = 39;
    voice[at + 12] = 7 << 3;               // detune centred
    voice[at + 14] = 0;                    // output level 0
    voice[at + 15] = 1 << 1;               // ratio mode, coarse 1
  }
  const op1 = 5 * 17;                      // OP1 is stored last
  voice.set(rates, op1);
  voice.set(levels, op1 + 4);
  voice[op1 + 14] = 99;                    // full output
  voice[110] = 31;                         // algorithm 32: OP1 is a carrier
  voice[111] = 0;                          // no feedback
  voice[117] = 24;                         // no transpose
  for (let i = 0; i < 10; ++i) voice[118 + i] = 0x20;
  let sum = 0;
  for (const byte of bank) sum += byte;
  const message = Buffer.concat([
    Buffer.from([0xf0, 0x43, 0x00, 0x09, 0x20, 0x00]),
    Buffer.from(bank),
    Buffer.from([(128 - (sum & 127)) & 127, 0xf7]),
  ]);
  const path = join(scratch, 'probe.syx');
  writeFileSync(path, message);
  return path;
}

function render(bankPath, seconds, gate) {
  const wavPath = join(scratch, 'probe.wav');
  execFileSync(join(bin, 'dx7-ref'), [bankPath, '0', wavPath,
    '--seconds', String(seconds), '--note', '57', '--gate', String(gate)]);
  const bytes = readFileSync(wavPath);
  const rate = bytes.readUInt32LE(24);
  const data = bytes.indexOf(Buffer.from('data'));
  const samples = [];
  for (let i = data + 8; i + 1 < bytes.length; i += 2) {
    samples.push(bytes.readInt16LE(i) / 32768);
  }
  return { rate, samples };
}

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

// Least-squares fit of log2(t) = log2(A) - rate/B.
function fit(pairs) {
  const n = pairs.length;
  const sx = pairs.reduce((a, [r]) => a + r, 0);
  const sy = pairs.reduce((a, [, t]) => a + Math.log2(t), 0);
  const sxx = pairs.reduce((a, [r]) => a + r * r, 0);
  const sxy = pairs.reduce((a, [r, t]) => a + r * Math.log2(t), 0);
  const slope = (n * sxy - sx * sy) / (n * sxx - sx * sx);
  const intercept = (sy - slope * sx) / n;
  let worst = 0;
  for (const [r, t] of pairs) {
    worst = Math.max(worst, Math.abs(intercept + slope * r - Math.log2(t)));
  }
  return { A: Math.pow(2, intercept), B: -1 / slope, worstLog2: worst };
}

console.log('attack: time to 90% of peak');
{
  const pairs = [];
  for (const rate of [40, 50, 60, 70, 80]) {
    const bank = probeBank({ rates: [rate, 99, 99, 60], levels: [99, 99, 99, 0] });
    const wav = render(bank, 6, 0.95);
    const env = envelope(wav);
    const peak = Math.max(...env.points);
    const reached = env.points.findIndex((p) => p >= 0.9 * peak);
    const seconds = Math.max(reached * env.step, env.step);
    pairs.push([rate, seconds]);
    console.log(`  rate ${rate}: ${seconds.toFixed(3)}s`);
  }
  const { A, B, worstLog2 } = fit(pairs);
  console.log(`  fit: t = ${A.toFixed(2)} * 2^(-rate/${B.toFixed(2)})  `
    + `(worst residual ${worstLog2.toFixed(2)} octaves)`);
}

console.log('decay: time to fall 20 dB toward L2=0');
{
  const pairs = [];
  for (const rate of [30, 40, 50, 60, 70]) {
    const bank = probeBank({ rates: [99, rate, 99, 60], levels: [99, 0, 0, 0] });
    const wav = render(bank, 8, 0.95);
    const env = envelope(wav);
    const peak = Math.max(...env.points);
    const peakAt = env.points.indexOf(peak);
    const fallen = env.points.findIndex((p, i) => i > peakAt && p <= peak * 0.1);
    if (fallen < 0) { console.log(`  rate ${rate}: no fall inside the render`); continue; }
    const seconds = (fallen - peakAt) * env.step;
    pairs.push([rate, seconds]);
    console.log(`  rate ${rate}: ${seconds.toFixed(3)}s`);
  }
  const { A, B, worstLog2 } = fit(pairs);
  console.log(`  fit: t = ${A.toFixed(2)} * 2^(-rate/${B.toFixed(2)})  `
    + `(worst residual ${worstLog2.toFixed(2)} octaves)`);
}
