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

//   ALGO 27 — tremolo: AMD 60 through sensitivity 2 on both carriers (about a
//             3.4 dB wobble), sine wave. Not oracle-held — the vendored msfa has
//             no amplitude modulation — but it keeps the code path exercised by
//             --check, --modular-check and the comparator's presence floor.
const tremolo = voiceAt(26);
tremolo[115] = 60;                     // AMD
tremolo[116] = 4 << 1;                 // sine wave, no pitch-mod, sync off
for (const slot of [4, 5]) {           // slots 4-5 are OP2 and OP1, the carriers
  tremolo[slot * 17 + 13] = 2;         // amp-mod sensitivity 2, velocity 0
}

const vibrato = voiceAt(27);
vibrato[113] = 55;                     // LFO delay: 0.38 s hold + 0.67 s ramp
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

function writeSyx(fileName, bytes, label) {
  let sum = 0;
  for (const byte of bytes) sum += byte;
  const checksum = (128 - (sum & 127)) & 127;
  const message = Buffer.concat([
    Buffer.from([0xf0, 0x43, 0x00, 0x09, 0x20, 0x00]),
    Buffer.from(bytes),
    Buffer.from([checksum, 0xf7]),
  ]);
  const out = join(target, fileName);
  writeFileSync(out, message);
  console.log(`wrote ${out} (${message.length} bytes, ${label})`);
}

writeSyx('algorithm-demos.syx', bank, '32 voices, one per algorithm');

// ---------------------------------------------------------------------------------
// family-demos.syx: the second original bank, written to exercise the importer's
// cartridge-as-bank path. Four families of eight voices — EP, ORGAN, BASS, BELL —
// each family on one algorithm, its voices differing ONLY in what the imported
// face's controls cover: coarse ratios, output levels, envelopes and feedback.
// That restriction is the point: it makes every page of the merged bank provably
// byte-identical to its own voice file (tools/dx7-bank-check.mjs holds it there),
// where a real cartridge's pages may also differ in detune or LFO and land close
// rather than exact. Same public-domain dedication as the algorithm demos.
// ---------------------------------------------------------------------------------

const family = new Uint8Array(4096);

// One voice: explicit per-slot coarse ratios and levels (slot order OP6..OP1),
// per-slot envelopes chosen by role, one feedback setting for the whole voice.
function packVoice(index, algorithmIndex, feedback, roles, ratios, levels,
    carrierEnv, modulatorEnv, name) {
  const voice = family.subarray(index * 128, (index + 1) * 128);
  for (let slot = 0; slot < 6; ++slot) {
    const envelope = roles[slot] === 'C' ? carrierEnv : modulatorEnv;
    packOperator(voice, slot * 17, envelope, ratios[slot], levels[slot]);
  }
  voice.fill(50, 102, 106);
  voice.fill(50, 106, 110);
  voice[110] = algorithmIndex;
  voice[111] = feedback;
  voice[112] = 35;
  voice[117] = 24;
  const padded = `${name}          `.slice(0, 10);
  for (let i = 0; i < 10; ++i) voice[118 + i] = padded.charCodeAt(i);
}

// EP — algorithm 5 (three modulator/carrier pairs): a tine on the top pair, body
// on the other two. Brightness is the modulator levels; hardness the feedback.
const EP_ROLES = ['M', 'C', 'M', 'C', 'M', 'C'];
const epCarrier = (decay) => ({ rates: [95, decay, 25, 55], levels: [99, 92, 0, 0] });
const EP_MOD = { rates: [95, 32, 25, 50], levels: [99, 88, 0, 0] };
const EP = [
  ['EP GLASS', [14, 1, 1, 1, 1, 1], [70, 99, 62, 99, 58, 99], 5, 38],
  ['EP MELLOW', [14, 1, 1, 1, 1, 1], [52, 99, 48, 99, 45, 99], 3, 34],
  ['EP BELLS', [14, 1, 7, 1, 1, 1], [78, 99, 55, 99, 50, 99], 5, 40],
  ['EP HARD', [14, 1, 1, 1, 2, 1], [82, 99, 70, 99, 66, 99], 6, 42],
  ['EP DUSK', [7, 1, 1, 1, 1, 1], [48, 99, 42, 99, 40, 99], 2, 30],
  ['EP CHIME', [14, 2, 1, 1, 1, 1], [75, 99, 52, 99, 47, 99], 5, 36],
  ['EP FELT', [14, 1, 1, 1, 1, 1], [38, 99, 35, 99, 33, 99], 1, 28],
  ['EP ROAD', [14, 1, 3, 1, 1, 1], [65, 99, 58, 99, 54, 99], 4, 37],
];
EP.forEach(([name, ratios, levels, feedback, decay], at) =>
  packVoice(at, 4, feedback, EP_ROLES, ratios, levels,
    epCarrier(decay), EP_MOD, name));

// ORGAN — algorithm 32 (six carriers): the levels are drawbars, the ratios the
// harmonic series, the envelope a held tone.
const ORGAN_ROLES = ['C', 'C', 'C', 'C', 'C', 'C'];
const ORGAN_ENV = { rates: [95, 50, 20, 60], levels: [99, 99, 99, 0] };
const ORGAN_RATIOS = [8, 6, 4, 3, 2, 1];
const ORGAN = [
  ['ORGAN FULL', [70, 75, 80, 85, 92, 99]],
  ['ORGAN SOFT', [30, 40, 50, 60, 80, 99]],
  ['ORGAN 5TH', [40, 45, 50, 88, 60, 99]],
  ['ORGAN JAZZ', [20, 25, 85, 30, 90, 99]],
  ['ORGAN PIPE', [55, 35, 45, 40, 85, 99]],
  ['ORGAN THIN', [65, 70, 40, 35, 30, 99]],
  ['ORGAN HUSH', [15, 20, 25, 30, 55, 99]],
  ['ORGAN HIGH', [90, 85, 75, 60, 50, 99]],
];
ORGAN.forEach(([name, levels], at) =>
  packVoice(8 + at, 31, 0, ORGAN_ROLES, ORGAN_RATIOS, levels,
    ORGAN_ENV, ORGAN_ENV, name));

// BASS — algorithm 1 (a pair and a three-deep stack): ratio 0 is the DX7's 0.5x,
// which is where the SUB lives.
const BASS_ROLES = ['M', 'M', 'M', 'C', 'M', 'C'];
const bassCarrier = (decay) => ({ rates: [97, decay, 28, 60], levels: [99, 90, 0, 0] });
const BASS_MOD = { rates: [96, 40, 30, 55], levels: [99, 80, 0, 0] };
const BASS = [
  ['BASS ROUND', [1, 1, 1, 1, 1, 1], [45, 50, 60, 99, 70, 99], 3, 40],
  ['BASS WIRE', [3, 1, 1, 1, 2, 1], [70, 60, 68, 99, 78, 99], 6, 44],
  ['BASS PICK', [1, 1, 2, 1, 1, 1], [62, 58, 64, 99, 80, 99], 5, 48],
  ['BASS SUB', [1, 1, 1, 0, 1, 0], [35, 40, 45, 99, 55, 99], 2, 36],
  ['BASS GRIT', [2, 1, 1, 1, 3, 1], [75, 68, 70, 99, 82, 99], 7, 45],
  ['BASS SOFT', [1, 1, 1, 1, 1, 1], [30, 35, 42, 99, 52, 99], 1, 32],
  ['BASS KNOCK', [5, 1, 1, 1, 1, 1], [68, 55, 60, 99, 72, 99], 4, 50],
  ['BASS PLUCK', [1, 2, 1, 1, 1, 1], [58, 62, 66, 99, 76, 99], 5, 52],
];
BASS.forEach(([name, ratios, levels, feedback, decay], at) =>
  packVoice(16 + at, 0, feedback, BASS_ROLES, ratios, levels,
    bassCarrier(decay), BASS_MOD, name));

// BELL — algorithm 3 (two three-deep stacks): inharmonic coarse ratios, long
// carrier decays, and the size of the bell is mostly which ratios ring.
const BELL_ROLES = ['M', 'M', 'C', 'M', 'M', 'C'];
const bellCarrier = (decay) => ({ rates: [96, decay, 20, 45], levels: [99, 88, 0, 0] });
const BELL_MOD = { rates: [95, 35, 22, 45], levels: [99, 82, 0, 0] };
const BELL = [
  ['BELL SMALL', [14, 3, 1, 7, 2, 1], [60, 55, 99, 65, 58, 99], 5, 26],
  ['BELL DEEP', [9, 2, 1, 5, 3, 1], [55, 50, 99, 60, 52, 99], 4, 22],
  ['BELL GLASS', [14, 5, 2, 9, 2, 1], [68, 60, 99, 70, 60, 99], 6, 28],
  ['BELL FAR', [11, 3, 1, 7, 2, 1], [40, 38, 99, 45, 40, 99], 3, 20],
  ['BELL NEAR', [13, 4, 1, 9, 3, 1], [72, 64, 99, 74, 63, 99], 6, 30],
  ['BELL DARK', [7, 2, 1, 5, 2, 1], [50, 45, 99, 52, 46, 99], 3, 21],
  ['BELL TINY', [14, 7, 3, 10, 5, 2], [62, 58, 99, 66, 60, 99], 5, 34],
  ['BELL LONG', [10, 3, 1, 6, 2, 1], [58, 52, 99, 62, 54, 99], 4, 18],
];
BELL.forEach(([name, ratios, levels, feedback, decay], at) =>
  packVoice(24 + at, 2, feedback, BELL_ROLES, ratios, levels,
    bellCarrier(decay), BELL_MOD, name));

writeSyx('family-demos.syx', family, '32 voices in four families');
