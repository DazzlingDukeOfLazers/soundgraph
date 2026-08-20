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
import { readFileSync, readdirSync, mkdtempSync, rmSync } from 'node:fs';
import { readWav, held, scoreAt, fundamental as sharedFundamental, sharePeriodicity,
  octaveFolded, rms } from './lib/audio-compare.mjs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const instruments = join(root, 'tools', 'opl2', 'instruments');
const patches = join(root, 'examples', 'patches', 'fm');
const bin = join(root, 'build', 'bin');
const scratch = mkdtempSync(join(tmpdir(), 'opl2-compare-'));
// The scratch dir dies with the process: two thousand of these
// leaked across a day of gate runs once filled the disk to zero.
process.on('exit', () => rmSync(scratch, { recursive: true, force: true }));
const verbose = process.argv.includes('--verbose');

// 220 Hz = MIDI 57. The oracle takes hertz and sg-render takes note numbers; these two
// constants are the same statement in both languages.
const FREQUENCY = 220;
const NOTE = 57;

// Measurement lives in tools/lib/audio-compare.mjs now, receipts and all, shared
// with the DX7 comparator. The 110 Hz floor is this comparator's physics: at A3 every
// OPL operator multiple is k*0.5, so nothing true lives lower.
const fundamental = (wav) => sharedFundamental(wav, 100);

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
