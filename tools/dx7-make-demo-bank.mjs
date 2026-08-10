#!/usr/bin/env node
// Writes tools/dx7/banks/algorithm-demos.syx: an original 32-voice DX7 bank, one
// voice per algorithm.
//
//   node tools/dx7-make-demo-bank.mjs
//
// It exists because no third-party DX7 bank has a licence worth vendoring: the
// community pools are tolerated, not licensed, and the factory ROMs are Yamaha's.
// So the repository ships a bank it authored — every voice original, dedicated to the
// public domain in tools/dx7/README.md — which exercises all 32 topologies through
// the same import path a user's own .syx will take. Voice design is deliberately
// plain: carriers at full level, modulators stepped down, ratios from the small
// integers, an envelope that speaks and gets out of the way. These are algorithm
// portraits, not preset-competition entries.

import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const target = join(root, 'tools', 'dx7', 'banks');
mkdirSync(target, { recursive: true });

// A carrier speaks quickly and holds; a modulator moves a little so the timbre does.
const CARRIER = { rates: [95, 40, 30, 55], levels: [99, 95, 90, 0] };
const MODULATOR = { rates: [90, 45, 25, 50], levels: [99, 85, 75, 0] };

// Ratio sets cycled across algorithms so neighbouring demos differ in flavour.
const RATIOS = [
  [1, 2, 1, 3, 1, 14],
  [1, 1, 2, 5, 1, 7],
  [1, 3, 1, 2, 2, 9],
  [2, 1, 1, 4, 1, 11],
];

function packOperator(bytes, at, envelope, coarse, level) {
  const { rates, levels } = envelope;
  bytes.set(rates, at);
  bytes.set(levels, at + 4);
  bytes[at + 8] = 39;              // scale break point C3 — unused by the importer
  bytes[at + 9] = 0;               // left depth
  bytes[at + 10] = 0;              // right depth
  bytes[at + 11] = 0;              // curves
  bytes[at + 12] = 7 << 3;         // detune centred, rate scaling 0
  bytes[at + 13] = 0;              // velocity and amp-mod sensitivity
  bytes[at + 14] = level;          // output level
  bytes[at + 15] = coarse << 1;    // ratio mode
  bytes[at + 16] = 0;              // fine 0
}

const bank = new Uint8Array(4096);
for (let algorithm = 0; algorithm < 32; ++algorithm) {
  const voice = bank.subarray(algorithm * 128, (algorithm + 1) * 128);
  const ratios = RATIOS[algorithm % RATIOS.length];
  for (let slot = 0; slot < 6; ++slot) {
    const op = 6 - slot;
    // Ops 1 and 2 lean carrier-ish in most algorithms; the rest modulate. The
    // importer reads the algorithm's own routing, so this only shapes envelopes.
    const envelope = op <= 2 ? CARRIER : MODULATOR;
    const level = op <= 2 ? 99 : 82 - slot * 2;
    packOperator(voice, slot * 17, envelope, ratios[6 - op], level);
  }
  voice.fill(50, 102, 106);        // pitch EG rates: neutral
  voice.fill(50, 106, 110);        // pitch EG levels: neutral
  voice[110] = algorithm;
  voice[111] = 5;                  // feedback 5, oscillator sync off
  voice[112] = 35;                 // LFO speed — inert while PMD stays 0
  voice[113] = 0;
  voice[114] = 0;
  voice[115] = 0;
  voice[116] = 0;
  voice[117] = 24;                 // transpose: C3, i.e. none
  const name = `ALGO ${String(algorithm + 1).padStart(2, '0')}   `.slice(0, 10);
  for (let i = 0; i < 10; ++i) voice[118 + i] = name.charCodeAt(i);
}

// Four of the portraits also exercise the stage-2 fidelity features, so the oracle
// comparator and the modular check hold the importer to more than topology. Gentle
// settings on purpose: the comparator's pitch check reads a 0.3 s window, and a
// two-semitone vibrato would wobble the measurement more than it proves.
//   ALGO 28 — vibrato: PMD 15 through sensitivity 2 (about ±14 cents), sine. Depth
//             30/3 (±half a semitone) failed the comparator: both renders wobble,
//             but the loudest-window measurement catches different LFO phases and
//             read 224 vs 216 Hz — the vibrato has to stay inside the pitch check's
//             3% for the check to stay meaningful.
//   ALGO 29 — pitch envelope: a fast +1/4-octave blip settling +1/16 octave sharp
//   ALGO 30 — key scaling: rate scaling 4, -LIN right depth 60 from a low break point
//             (A3 must sit inside the scaled zone or the depth does nothing at the
//             reference note)
//   ALGO 31 — velocity sensitivity 7 on the modulators
const voiceAt = (index) => bank.subarray(index * 128, (index + 1) * 128);

const vibrato = voiceAt(27);
vibrato[114] = 15;                     // PMD
vibrato[116] = (2 << 4) | (4 << 1);    // pitch-mod sensitivity 2, sine wave, sync off

const pitchEnv = voiceAt(28);
pitchEnv.set([90, 70, 60, 70], 102);   // rates: transient over in a tenth of a second
pitchEnv.set([58, 54, 52, 50], 106);   // levels, 50 = neutral

const keyScaled = voiceAt(29);
for (let slot = 0; slot < 6; ++slot) {
  const at = slot * 17;
  keyScaled[at + 8] = 27;              // break point A1, well below the played A3
  keyScaled[at + 10] = 60;             // right depth
  keyScaled[at + 11] = 0;              // -LIN both curves: quieter above the break
  keyScaled[at + 12] = (7 << 3) | 4;   // detune centred, rate scaling 4
}

const velocity = voiceAt(30);
for (let slot = 0; slot < 4; ++slot) { // slots 0-3 are OP6..OP3, the modulators
  velocity[slot * 17 + 13] = 7 << 2;   // velocity sensitivity 7, amp-mod 0
}

let sum = 0;
for (const byte of bank) sum += byte;
const checksum = (128 - (sum & 127)) & 127;

const message = Buffer.concat([
  Buffer.from([0xf0, 0x43, 0x00, 0x09, 0x20, 0x00]),
  Buffer.from(bank),
  Buffer.from([checksum, 0xf7]),
]);
const out = join(target, 'algorithm-demos.syx');
writeFileSync(out, message);
console.log(`wrote ${out} (${message.length} bytes, 32 voices, one per algorithm)`);
