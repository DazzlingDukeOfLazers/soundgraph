#!/usr/bin/env node
// Plays every voice of every vendored DX7 bank twice — through msfa and through the
// imported SoundGraph patch — and holds them to the same coarse truths as the OPL
// comparator: a shared fundamental, and actual presence.
//
//   node tools/dx7-compare.mjs [--verbose]
//
// Shared measurement lives in tools/lib/audio-compare.mjs, with the receipts for why
// each piece is shaped the way it is. The pitch floor here is 50 Hz: DX7 ratios reach
// 0.5x with fine detune, so at A3 real fundamentals can live near 110 but composite
// periods of detuned pairs can be legitimately longer.

import { execFileSync } from 'node:child_process';
import { readFileSync, readdirSync, mkdtempSync, rmSync } from 'node:fs';
import { readWav, fundamental as sharedFundamental, sharePeriodicity, octaveFolded,
  rms } from './lib/audio-compare.mjs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const banks = join(root, 'tools', 'dx7', 'banks');
const patches = join(root, 'examples', 'patches', 'dx7');
const bin = join(root, 'build', 'bin');
const scratch = mkdtempSync(join(tmpdir(), 'dx7-compare-'));
// The scratch dir dies with the process: two thousand of these
// leaked across a day of gate runs once filled the disk to zero.
process.on('exit', () => rmSync(scratch, { recursive: true, force: true }));
const verbose = process.argv.includes('--verbose');

const NOTE = 57;
const fundamental = (wav) => sharedFundamental(wav, 50);

const slug = (name) => name.toLowerCase().replace(/[^a-z0-9]+/g, '-')
  .replace(/^-|-$/g, '') || 'unnamed';

let failures = 0;
let compared = 0;
for (const bank of readdirSync(banks).filter((f) => f.endsWith('.syx')).sort()) {
  const bytes = readFileSync(join(banks, bank));
  const start = bytes.indexOf(0xf0);
  const data = bytes.subarray(start + 6, start + 6 + 4096);
  const used = new Set();
  for (let voice = 0; voice < 32; ++voice) {
    const name = String.fromCharCode(...data.subarray(voice * 128 + 118, voice * 128 + 128))
      .replace(/[^\x20-\x7e]/g, ' ').trim();
    let id = slug(name || `voice-${voice + 1}`);
    while (used.has(id)) id = `${id}-${voice + 1}`;
    used.add(id);
    const patch = join(patches, `${id}.json`);

    const oracleWav = join(scratch, `${id}-oracle.wav`);
    const oursWav = join(scratch, `${id}-ours.wav`);
    execFileSync(join(bin, 'dx7-ref'), [join(banks, bank), String(voice), oracleWav,
      '--seconds', '2', '--note', String(NOTE), '--gate', '0.7']);
    // The oracle plays MIDI velocity 100; sg-render's default is 0.9 (~114).
    // Since the imports respond to velocity live, both engines must be struck
    // equally hard: 100/127.
    execFileSync(join(bin, 'sg-render'), [patch, oursWav,
      '--seconds', '2', '--notes', String(NOTE), '--gate', '0.7',
      '--velocity', String(100 / 127), '--quiet']);

    const oracle = readWav(oracleWav);
    const ours = readWav(oursWav);
    const oracleF0 = fundamental(oracle);
    const oursF0 = octaveFolded(fundamental(ours), oracleF0);
    const pitchError = Math.abs(oursF0 - oracleF0) / oracleF0;
    const oracleRms = rms(oracle);
    const oursRms = rms(ours);
    const levelDb = 20 * Math.log10(oursRms / Math.max(oracleRms, 1e-9));

    const samePitch = pitchError < 0.03
      || sharePeriodicity(oracle, ours, oracleF0, fundamental(ours));
    const ok = samePitch && oursRms > 0.01 && oracleRms > 0.001;
    if (!ok) failures += 1;
    compared += 1;
    const how = pitchError < 0.03 ? `f0 ${oursF0.toFixed(1)} Hz (${
      (pitchError * 100).toFixed(1)}%)` : (samePitch
      ? `lattice (${oursF0.toFixed(1)} vs ${oracleF0.toFixed(1)} Hz)` : `f0 ${
      oursF0.toFixed(1)} vs ${oracleF0.toFixed(1)} Hz`);
    const line = `  ${ok ? 'ok  ' : 'FAIL'} ${id.padEnd(26)} ${how}, `
      + `level ${levelDb >= 0 ? '+' : ''}${levelDb.toFixed(1)} dB vs oracle`;
    if (!ok || verbose) console.error(line);
    else console.log(line);
  }
}

if (failures > 0) {
  console.error(`\n${failures} voice(s) disagree with the msfa oracle.`);
  process.exit(1);
}
console.log(`All ${compared} imported DX7 voices agree with the oracle on pitch and presence.`);
