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
  voice[112] = 35;                 // LFO speed — recorded, not yet imported
  voice[113] = 0;
  voice[114] = 0;
  voice[115] = 0;
  voice[116] = 0;
  voice[117] = 24;                 // transpose: C3, i.e. none
  const name = `ALGO ${String(algorithm + 1).padStart(2, '0')}   `.slice(0, 10);
  for (let i = 0; i < 10; ++i) voice[118 + i] = name.charCodeAt(i);
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
