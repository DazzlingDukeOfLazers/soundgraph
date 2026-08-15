#!/usr/bin/env node
// Imports DX7 voices: every .syx bank under tools/dx7/banks/ becomes SoundGraph
// patches in examples/patches/dx7/.
//
//   node tools/dx7-import.mjs [--check]
//
// This is the import the whole FM effort was aimed at, because a DX7 algorithm IS a
// signal-flow graph: six operators and a routing chart. Importing a voice does not
// approximate a synth architecture onto ours — it *generates the graph the algorithm
// always was*, six sines with pm connections, which is the SoundGraph thesis made
// audible.
//
// The algorithm table is transcribed from Dexed's msfa engine (fm_core.cc, Apache
// 2.0, music-synthesizer-for-android) rather than from a redrawn panel chart, and it
// is not a table of pictures: each byte drives a little bus machine — operators run
// OP6 down to OP1, each reading a bus, computing, and writing or adding to a bus.
// This importer runs that same machine symbolically to recover the modulation edges,
// so the 32 topologies come from executing the canonical data, not from my reading of
// 32 diagrams.
//
// Fidelity (stages 1 and 2 of the doc's plan):
//   applied    — topology, ratio and fixed frequency modes, detune, output levels,
//                feedback (on the op the algorithm marks), rate/level envelopes onto
//                the ADSR, transpose; key scaling (rate and level) and the velocity
//                curve, both evaluated exactly at the reference note and velocity;
//                vibrato as an LFO into the oscillators' fm inputs; the pitch
//                envelope as an ADSR in octaves; the LFO delay as a fade on both
//                LFO destinations; tremolo per Dexed's fork (the vendored oracle
//                has no amplitude modulation, so tremolo alone is not oracle-held);
//                live velocity as a squared-affine curve off NoteInput's velocity
//                output, exact at the reference so nothing baked moved; the
//                algorithm 4/6 multi-op feedback loops run open, exactly as the
//                oracle runs them (its own todo — the real chip's per-sample
//                cross-operator path is representable in neither engine); the
//                feedback loop's bite follows the envelope, tremolo and velocity
//                through the sine's feedback input (the operator module's fbscale
//                multiplies them into one signal)
//   pending    — feedback 7 on a near-full-level op period-doubles in msfa's
//                fixed-point loop where our float loop stays period-1 (see
//                dx7-index-check.mjs)
//   measured   — the rate->seconds curves, against the vendored msfa oracle
//   by ear     — the modulation index scale (INDEX_FULL)
// Every voice records what was dropped in its own metadata.

import { readFileSync, writeFileSync, readdirSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
// Overridable so verification tools (dx7-index-check.mjs) can run the same import
// path on synthetic banks in a scratch directory without touching the library.
const source = process.env.DX7_SOURCE ?? join(root, 'tools', 'dx7', 'banks');
const target = process.env.DX7_TARGET ?? join(root, 'examples', 'patches', 'dx7');

// msfa's FmCore::algorithms, verbatim — including algorithms 4 and 6, this time.
// Byte layout: in-bus = (b>>4)&3, out-bus = b&3, 0x04 = add to the bus (out-bus 0
// with add = a carrier), 0x40 = FB_IN, 0x80 = FB_OUT; only both together (0xc0)
// is an op feeding itself back. Algorithms 4 and 6 are the two where the chip
// loops feedback *through* other operators (OP4->OP6, OP5->OP6): msfa leaves that
// loop open — fm_core.cc line 129, "todo: more than one op in a feedback loop",
// FB_IN alone takes the pure path — and this table used to carry Dexed's edit
// (0xc1 in place of 0x41), which bends the loop into self-feedback on OP6. That
// made the import quietly disagree with the very oracle everything else here is
// held to — by 22 dB in the upper harmonics at feedback 7 — so the verbatim bytes
// are back and the open loop is pinned by dx7-index-check's loop cases.
const ALGORITHMS = [
  [0xc1, 0x11, 0x11, 0x14, 0x01, 0x14], [0x01, 0x11, 0x11, 0x14, 0xc1, 0x14],
  [0xc1, 0x11, 0x14, 0x01, 0x11, 0x14], [0x41, 0x11, 0x94, 0x01, 0x11, 0x14],
  [0xc1, 0x14, 0x01, 0x14, 0x01, 0x14], [0x41, 0x94, 0x01, 0x14, 0x01, 0x14],
  [0xc1, 0x11, 0x05, 0x14, 0x01, 0x14], [0x01, 0x11, 0xc5, 0x14, 0x01, 0x14],
  [0x01, 0x11, 0x05, 0x14, 0xc1, 0x14], [0x01, 0x05, 0x14, 0xc1, 0x11, 0x14],
  [0xc1, 0x05, 0x14, 0x01, 0x11, 0x14], [0x01, 0x05, 0x05, 0x14, 0xc1, 0x14],
  [0xc1, 0x05, 0x05, 0x14, 0x01, 0x14], [0xc1, 0x05, 0x11, 0x14, 0x01, 0x14],
  [0x01, 0x05, 0x11, 0x14, 0xc1, 0x14], [0xc1, 0x11, 0x02, 0x25, 0x05, 0x14],
  [0x01, 0x11, 0x02, 0x25, 0xc5, 0x14], [0x01, 0x11, 0x11, 0xc5, 0x05, 0x14],
  [0xc1, 0x14, 0x14, 0x01, 0x11, 0x14], [0x01, 0x05, 0x14, 0xc1, 0x14, 0x14],
  [0x01, 0x14, 0x14, 0xc1, 0x14, 0x14], [0xc1, 0x14, 0x14, 0x14, 0x01, 0x14],
  [0xc1, 0x14, 0x14, 0x01, 0x14, 0x04], [0xc1, 0x14, 0x14, 0x14, 0x04, 0x04],
  [0xc1, 0x14, 0x14, 0x04, 0x04, 0x04], [0xc1, 0x05, 0x14, 0x01, 0x14, 0x04],
  [0x01, 0x05, 0x14, 0xc1, 0x14, 0x04], [0x04, 0xc1, 0x11, 0x14, 0x01, 0x14],
  [0xc1, 0x14, 0x01, 0x14, 0x04, 0x04], [0x04, 0xc1, 0x11, 0x14, 0x04, 0x04],
  [0xc1, 0x14, 0x04, 0x04, 0x04, 0x04], [0xc4, 0x04, 0x04, 0x04, 0x04, 0x04],
];

// Runs the bus machine symbolically. Returns, in DX7 numbering (op 1..6):
//   edges     — [from, to] modulation connections
//   carriers  — ops that reach the output
//   feedback  — the op the algorithm feeds back on itself (0xc0: both FB bits)
//   loop      — a multi-op feedback path {from, to} (FB_OUT on one op, FB_IN on
//               another), which the oracle and therefore this import run open
// ops[0] is OP6 and ops[5] is OP1, matching both msfa and the wire format.
function decodeAlgorithm(bytes) {
  const buses = { 1: [], 2: [] };
  const carriers = [];
  const edges = [];
  let feedback = 0;
  let loopIn = 0;
  let loopOut = 0;
  for (let index = 0; index < 6; ++index) {
    const op = 6 - index;
    const flags = bytes[index];
    const inBus = (flags >> 4) & 3;
    const outBus = flags & 3;
    const add = (flags & 0x04) !== 0;
    if ((flags & 0xc0) === 0xc0) feedback = op;
    else if ((flags & 0xc0) === 0x40) loopIn = op;
    else if ((flags & 0xc0) === 0x80) loopOut = op;
    if (inBus !== 0) {
      for (const from of buses[inBus]) edges.push([from, op]);
    }
    if (outBus === 0) {
      carriers.push(op);
    } else if (add) {
      buses[outBus].push(op);
    } else {
      buses[outBus] = [op];
    }
  }
  return { edges, carriers, feedback,
    loop: loopIn > 0 && loopOut > 0 ? { from: loopOut, to: loopIn } : null };
}

// ---------------------------------------------------------------------------------
// Voice parameters, from the packed 128-byte bank format.
// ---------------------------------------------------------------------------------

function decodeVoice(bytes) {
  const ops = [];
  for (let slot = 0; slot < 6; ++slot) {
    const at = slot * 17;
    ops.push({
      op: 6 - slot,  // stored OP6 first, like everything else in this format
      rates: [bytes[at], bytes[at + 1], bytes[at + 2], bytes[at + 3]],
      levels: [bytes[at + 4], bytes[at + 5], bytes[at + 6], bytes[at + 7]],
      breakPoint: bytes[at + 8],
      leftDepth: bytes[at + 9],
      rightDepth: bytes[at + 10],
      leftCurve: bytes[at + 11] & 0x03,
      rightCurve: (bytes[at + 11] >> 2) & 0x03,
      rateScaling: bytes[at + 12] & 0x07,
      detune: ((bytes[at + 12] >> 3) & 0x0f) - 7,
      velocitySens: (bytes[at + 13] >> 2) & 0x07,
      ampModSens: bytes[at + 13] & 0x03,
      outputLevel: bytes[at + 14],
      fixed: (bytes[at + 15] & 0x01) !== 0,
      coarse: (bytes[at + 15] >> 1) & 0x1f,
      fine: bytes[at + 16],
    });
  }
  return {
    ops,
    pitchRates: [bytes[102], bytes[103], bytes[104], bytes[105]],
    pitchLevels: [bytes[106], bytes[107], bytes[108], bytes[109]],
    algorithm: bytes[110] & 0x1f,
    feedbackLevel: bytes[111] & 0x07,
    lfoSpeed: bytes[112],
    lfoDelay: bytes[113],
    lfoPmd: bytes[114],
    lfoAmd: bytes[115],
    lfoSync: bytes[116] & 0x01,
    lfoWave: (bytes[116] >> 1) & 0x07,
    pitchModSens: (bytes[116] >> 4) & 0x07,
    transpose: bytes[117] - 24,
    name: String.fromCharCode(...bytes.subarray(118, 128))
      .replace(/[^\x20-\x7e]/g, ' ').trim(),
  };
}

// ---------------------------------------------------------------------------------
// Parameter mappings — the stage-1 approximations, each named and bounded.
// ---------------------------------------------------------------------------------

// ---------------------------------------------------------------------------------
// msfa's own arithmetic, translated exactly — not fitted, not calibrated, copied.
// The vendored oracle carries these tables and formulas (dx7note.cc, env.cc,
// pitchenv.cc, lfo.cc); evaluating them here at the reference note and velocity
// makes the import match the oracle by construction, not by tuning. One env level
// unit is 2^21/2^24 octaves = 6.0206/8 dB, which also retires the approximate 0.75.
// ---------------------------------------------------------------------------------

const LEVEL_LUT = [0, 5, 9, 13, 17, 20, 23, 25, 27, 29, 31, 33, 35, 37, 39, 41,
  42, 43, 45, 46];
const scaleOutLevel = (level) => (level >= 20 ? 28 + level : LEVEL_LUT[level]);

const EXP_SCALE_DATA = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 14, 16, 19, 23, 27, 33,
  39, 47, 56, 66, 80, 94, 110, 126, 142, 158, 174, 190, 206, 222, 238, 250];

function scaleCurve(group, depth, curve) {
  let scale;
  if (curve === 0 || curve === 3) {
    scale = (group * depth * 329) >> 12;
  } else {
    const raw = EXP_SCALE_DATA[Math.min(group, EXP_SCALE_DATA.length - 1)];
    scale = (raw * depth * 329) >> 15;
  }
  return curve < 2 ? -scale : scale;
}

function scaleLevel(midinote, breakPoint, leftDepth, rightDepth, leftCurve, rightCurve) {
  const offset = midinote - breakPoint - 17;
  if (offset >= 0) return scaleCurve(Math.floor(offset / 3), rightDepth, rightCurve);
  return scaleCurve(Math.floor(-offset / 3), leftDepth, leftCurve);
}

const scaleRate = (midinote, sensitivity) =>
  (sensitivity * Math.min(31, Math.max(0, Math.floor(midinote / 3) - 7))) >> 3;

const VELOCITY_DATA = [0, 70, 86, 97, 106, 114, 121, 126, 132, 138, 142, 148, 152,
  156, 160, 163, 166, 170, 173, 174, 178, 181, 184, 186, 189, 190, 194, 196, 198,
  200, 202, 205, 206, 209, 211, 214, 216, 218, 220, 222, 224, 225, 227, 229, 230,
  232, 233, 235, 237, 238, 240, 241, 242, 243, 244, 246, 246, 248, 249, 250, 251,
  252, 253, 254];

// Velocity delta in env Q units; /32 puts it on the outlevel-127 ladder.
function scaleVelocity(velocity, sensitivity) {
  const clamped = Math.max(0, Math.min(127, velocity));
  const value = VELOCITY_DATA[clamped >> 1] - 239;
  return ((sensitivity * value + 7) >> 3) << 4;
}

// Live velocity as a graph the engine can run. The true response relative to the
// baked reference is g(v) = 2^((sv(v) - sv(100))/256) — a table through an
// exponential, which the node vocabulary cannot spell. It can spell a squared
// affine, (alpha + beta*v01)^2, and that is a genuinely good fit because the DX7
// curve is close to a square law in MIDI velocity: anchored exact at velocities
// 100 (g = 1, so every reference render is untouched) and 127, it lands within
// ~0.5 dB across the playing range at full sensitivity (checked against the table
// at 50 and 80: 0.1 and 0.5 dB). Below MIDI ~20 the parabola bottoms out and
// rises again where the chip keeps fading — the notes say so. v01 is the engine's
// NoteInput velocity, MIDI/127.
function velocityCurve(sensitivity) {
  const g127 = Math.pow(2,
    (scaleVelocity(127, sensitivity) - scaleVelocity(100, sensitivity)) / 256);
  const anchor = 100 / 127;
  const beta = (Math.sqrt(g127) - 1) / (1 - anchor);
  return { alpha: 1 - beta * anchor, beta };
}

const PITCH_MOD_SENS = [0, 10, 20, 33, 55, 92, 153, 255];

// Pitch envelope levels in octaves: pitchtab << 19 against 2^24 per octave.
const PITCH_TAB = [-128, -116, -104, -95, -85, -76, -68, -61, -56, -52, -49, -46,
  -43, -41, -39, -37, -35, -33, -32, -31, -30, -29, -28, -27, -26, -25, -24, -23,
  -22, -21, -20, -19, -18, -17, -16, -15, -14, -13, -12, -11, -10, -9, -8, -7, -6,
  -5, -4, -3, -2, -1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17,
  18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 38, 40,
  43, 46, 49, 53, 58, 65, 73, 82, 92, 103, 115, 127];
const pitchOctaves = (level) => PITCH_TAB[Math.max(0, Math.min(99, level))] / 32;

// The pitch envelope's clock, from pitchenv.cc: the level slides *linearly* at
// ratetab[rate]/21.3 octaves per second (inc = ratetab*unit per sample, unit =
// 2^24/(21.3*sr), 2^24 per octave). Traversal time falls out in closed form. The
// ADSR's decay and release are exponential, not linear — a shape approximation the
// per-voice notes record; the attack segment is linear on both sides.
const PITCH_RATE_TAB = [1, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11,
  11, 12, 12, 13, 13, 14, 14, 15, 16, 16, 17, 18, 18, 19, 20, 21, 22, 23, 24, 25,
  26, 27, 28, 30, 31, 33, 34, 36, 37, 38, 39, 41, 42, 44, 46, 47, 49, 51, 53, 54,
  56, 58, 60, 62, 64, 66, 68, 70, 72, 74, 76, 79, 82, 85, 88, 91, 94, 98, 102, 106,
  110, 115, 120, 125, 130, 135, 141, 147, 153, 159, 165, 171, 178, 185, 193, 202,
  211, 232, 243, 254, 255];
const pitchSlewSeconds = (octaves, rate) => Math.min(10,
  (Math.abs(octaves) * 21.3) / PITCH_RATE_TAB[Math.max(0, Math.min(99, rate))]);

// The DX7 LFO's frequency, closed form from lfo.cc: unit = 25190424/2^32 Hz.
function lfoHz(rate) {
  let sr = rate === 0 ? 1 : (165 * rate) >> 6;
  sr *= sr < 160 ? 11 : 11 + ((sr - 160) >> 4);
  return (25190424 / Math.pow(2, 32)) * sr;
}

// DX7 LFO waveform -> the engine LFO's shape enum. Saw-down has no exact match and
// arrives as saw (rising) — the pitch contour inverts, which a fidelity note records.
const LFO_SHAPE = [1, 2, 2, 3, 0, 4];

// The LFO delay, from lfo.cc: not one ramp but a *hold* (getdelay returns 0 while
// the accumulator climbs to 2^31 at unit*a per sample) and then a linear ramp to
// full (at unit*a2). unit*sr = 25190424/s, so both durations come in closed form.
function lfoDelayTimes(delay) {
  const raw = 99 - Math.max(0, Math.min(99, delay));
  if (raw === 99) return null;  // delay 0: instantly full
  const a = (16 + (raw & 15)) << (1 + (raw >> 4));
  const a2 = Math.max(0x80, a & 0xff80);
  return { hold: 2 ** 31 / (25190424 * a), ramp: 2 ** 31 / (25190424 * a2) };
}

// Tremolo. The vendored msfa has no amplitude modulation at all — Dexed's fork
// added it — so unlike everything else in this block there is no oracle to hold it
// to; the arithmetic below is Dexed's (dx7note.cc in asb2m10/dexed), translated:
//   amod  = ((AMD*165)>>6 * lfo_delay) >> 8, modulated by the *inverted* LFO
//   sens  = ampmodsenstab[0..3] = {0, 4342338, 7171437, 2^24}
//   pt    = exp(0.07 * sensamp/2^18 + 12.2)   (their fitted float hack, verbatim)
//   ldiff = level * pt / 2^24, subtracted in the log domain
// One env-level unit is 2^-24 octaves *256, so the trough dip in octaves is the
// op's log2 level times pt/2^24. The dip is evaluated at the envelope's peak and
// swung linearly in amplitude — the chip swings it exponentially — and Dexed's
// small constant bias at zero modulation (pt(0) = e^12.2) is deliberately not
// reproduced.
const AMP_MOD_SENS_TAB = [0, 4342338, 7171437, 16777216];

function tremoloDip(op, amd) {
  const depth = (amd * 165) >> 6;
  const sensamp = (depth * 65536 * AMP_MOD_SENS_TAB[op.ampModSens & 3]) / 2 ** 24;
  const pt = Math.exp((sensamp / 262144) * 0.07 + 12.2);
  const peak = ((scaleOutLevel(op.levels[0]) >> 1) << 6)
    + operatorUnits(op) * 32 - 4256;
  return (Math.max(16, peak) / 256) * (pt / 2 ** 24);
}

// The note and velocity every render in this repository plays: MIDI 57 through
// sg-render, velocity 100 through the oracle. The scaling functions above are exact
// at this point and approximations elsewhere on the keyboard, which the metadata
// says per voice.
const REFERENCE_NOTE = 57;
const REFERENCE_VELOCITY = 100;

// One outlevel-127 unit in amplitude. 2^(x/8) per unit: msfa's ladder, exactly.
const levelAmp127 = (units) => Math.pow(2, (units - 127) / 8);

// DX7 levels 0-99 through the same ladder the oracle uses.
const levelAmp = (level) => levelAmp127(scaleOutLevel(level));

// Rate 0-99 to seconds — MEASURED against the msfa oracle by tools/dx7-calibrate.mjs
// (attack read at 90% of peak, falls at -20 dB, fit residuals under a tenth of an
// octave, so the doubling law genuinely holds). The guessed curve these replaced was
// about four times too slow at the mid rates — a better guess than OPL's, which had
// been fourteen — and the pattern stands: every fitted constant this project has ever
// put in front of an oracle has been wrong in the same direction.
const attackSeconds = (rate) =>
  Math.min(10, 26.81 * Math.pow(2, -rate / 6.47));
const fallSeconds = (rate) =>
  Math.min(10, 20.65 * Math.pow(2, -rate / 7.2));

// The modulation index scale, derived from the oracle rather than fitted: msfa's
// sine table peaks at 2^24 (sin.cc), an operator's output is (sin*gain)>>24 with
// gain = 2^(10 + level/2^24) (dx7note.cc), and that output is added *directly* to
// the carrier's Q24 phase where 2^24 is one cycle (fm_op_kernel.cc). The envelope
// peak for outlevel units u is level = (32u - 224) << 16 (env.cc), so the peak
// index is 2^(u/8 - 14.875) cycles — exactly 2.0 at u = 127, and exactly
// INDEX_FULL * levelAmp127(u) for every other level. The old by-ear 2.0 happened
// to be the true value; what changed is that it now has a derivation, and
// tools/dx7-index-check.mjs holds both renders to it spectrally.
const INDEX_FULL = 2.0;

// Feedback through the same derivation: compute_fb displaces phase by the two-sample
// average of the op's *gain-scaled* output, shifted by fb_shift = 8 - fb. In engine
// terms (feedback param times the raw +-1 sine average) that is
// operatorAmp * 2^(fb-8) * INDEX_FULL = operatorAmp * 2^(fb-7). The previous
// 2^(fb-1)/32 was exactly twice msfa's — the one constant in this file the oracle
// caught being wrong in the *loud* direction.
const feedbackCycles = (fb) => (fb <= 0 ? 0 : Math.pow(2, fb - 1) / 64);

function envelopeParameters(op) {
  // Rate scaling, msfa's own arithmetic: the qrate delta at the reference note,
  // converted back to the 0-99 rate domain (qrate = rate*41/64). Exact at A3,
  // an approximation elsewhere on the keyboard — the engine's ADSR has no key
  // tracking yet, and pretending otherwise would be worse than saying so.
  const rateDelta = (scaleRate(REFERENCE_NOTE, op.rateScaling) * 64) / 41;
  const [r1, r2, r3, r4] = op.rates.map((r) => Math.min(99, r + rateDelta));
  const [l1, l2, l3] = op.levels;
  // Attack to L1 at R1; the fall through L2 to the held L3 is two segments folded
  // into one decay knob; release at R4. L4 is assumed to be silence, which nearly
  // every voice honours — one that does not will sound, just not identically.
  return {
    attack: Number(attackSeconds(r1).toFixed(4)),
    decay: Number(Math.min(10, fallSeconds(r2) + fallSeconds(r3)).toFixed(4)),
    sustain: Number((levelAmp(l3) * Math.min(1, l1 / 99)).toFixed(4)),
    release: Number(fallSeconds(r4).toFixed(4)),
  };
}

// The operator's effective output amplitude: its level through the oracle's ladder,
// key-level scaling and the velocity curve applied exactly at the reference point.
function operatorUnits(op) {
  // Clamp order is msfa's (dx7note.cc): level plus key scaling caps at 127 *before*
  // velocity is added, and velocity is only floored at 0 after — a hot velocity on a
  // full-level op genuinely pushes past the ladder's top on the real engine.
  let units = scaleOutLevel(op.outputLevel);
  units += scaleLevel(REFERENCE_NOTE, op.breakPoint, op.leftDepth, op.rightDepth,
    op.leftCurve, op.rightCurve);
  units = Math.min(127, units);
  return Math.max(0, units + scaleVelocity(REFERENCE_VELOCITY, op.velocitySens) / 32);
}

const operatorAmp = (op) => levelAmp127(operatorUnits(op));

function operatorRatio(op) {
  const base = op.fixed
    ? Math.pow(10, (op.coarse % 4)) * (1 + op.fine / 100)
    : (op.coarse === 0 ? 0.5 : op.coarse) * (1 + op.fine / 100);
  // Detune is ±7 around centre, a few cents each step.
  return base * Math.pow(2, (op.detune * 2) / 1200);
}

// ---------------------------------------------------------------------------------
// The patch: one node cluster per operator, wired by the decoded algorithm.
// ---------------------------------------------------------------------------------

function buildPatch(voice, bankName, voiceIndex) {
  const topology = decodeAlgorithm(ALGORITHMS[voice.algorithm]);
  const notes = [];
  if (topology.feedback === 0 && topology.loop === null) {
    notes.push('no feedback op in algorithm decode');
  }
  if (topology.loop !== null && voice.feedbackLevel > 0) {
    // The chip loops feedback through other operators here; a per-sample
    // cross-node path is representable neither in this graph nor in the oracle
    // (msfa's own todo), so the loop runs open on both. Dexed instead bends its
    // algorithm table to self-feedback on the driving op — anyone wanting that
    // growl can turn the operator module's exported feedback knob by hand.
    notes.push(`the chip loops feedback OP${topology.loop.from}->OP`
      + `${topology.loop.to}; runs open here, matching the oracle`);
  }

  // The voice's global pitch story: vibrato depth from PMD through the sensitivity
  // table, and the pitch envelope's four levels in octaves. L4 is where the envelope
  // starts, sustains relative to, and returns — a constant everything else rides on,
  // so it folds into the operator frequencies and only the excursion needs nodes.
  const pitchEg = voice.pitchLevels.map(pitchOctaves);
  const egBase = pitchEg[3];
  const egSpread = Math.max(...pitchEg.map((o) => Math.abs(o - egBase)));
  const hasPitchEnvelope = egSpread > 0.001;
  const vibratoDepth = (((voice.lfoPmd * 165) >> 6)
    * PITCH_MOD_SENS[voice.pitchModSens]) / 65536;
  const hasVibrato = vibratoDepth > 0.0005;

  // What each operator is *for*, in the words a DX7 manual uses. Six nodes all called
  // "Operator" is what the editor showed before this: the ids knew which was which and
  // the canvas did not, so an algorithm — the entire subject of the patch — could only
  // be read by tracing cables. A carrier is heard; a modulator is only felt.
  const roleOf = (op) => {
    const parts = [`OP${op}`];
    parts.push(topology.carriers.includes(op) ? 'carrier' : 'modulator');
    if (topology.feedback === op && voice.feedbackLevel > 0) parts.push('· feedback');
    return parts.join(' ');
  };

  const nodes = [{ id: 'note', type: 'Input', host: 'note', name: 'Keyboard',
    parameters: voice.transpose !== 0 ? { transpose: voice.transpose } : {} }];
  const connections = [];
  const wire = (fromNode, fromPort, toNode, toPort) => connections.push({
    from: { node: fromNode, port: fromPort },
    to: { node: toNode, port: toPort },
  });

  // Which ops actually sound: carriers, and any op with a path to one. The bus
  // machine already dropped dead branches, so every edge and carrier is live.
  const modulatorTargets = new Map();
  for (const [from, to] of topology.edges) {
    if (!modulatorTargets.has(to)) modulatorTargets.set(to, []);
    modulatorTargets.get(to).push(from);
  }
  const live = new Set(topology.carriers);
  let grew = true;
  while (grew) {
    grew = false;
    for (const [from, to] of topology.edges) {
      if (live.has(to) && !live.has(from)) { live.add(from); grew = true; }
    }
  }

  for (const op of voice.ops) {
    if (!live.has(op.op)) continue;
    const id = `op${op.op}`;
    const oscParameters = {};
    if (topology.feedback === op.op && voice.feedbackLevel > 0) {
      // Like OPL, the chip feeds back the *attenuated* output; scale by level.
      oscParameters.feedback = Number((feedbackCycles(voice.feedbackLevel)
        * operatorAmp(op)).toFixed(5));
    }
    if (op.fixed) {
      oscParameters.frequency = Number((operatorRatio(op)
        * Math.pow(2, egBase)).toFixed(3));
      nodes.push({ id: `${id}_osc`, type: 'SineOscillator', name: roleOf(op.op),
        parameters: oscParameters });
    } else {
      nodes.push({ id: `${id}_pitch`, type: 'Multiply', name: roleOf(op.op),
        parameters: { factor: Number((operatorRatio(op)
          * Math.pow(2, egBase)).toFixed(5)) } });
      wire('note', 'frequency', `${id}_pitch`, 'a');
      nodes.push({ id: `${id}_osc`, type: 'SineOscillator', parameters: oscParameters });
      wire(`${id}_pitch`, 'out', `${id}_osc`, 'frequency');
    }
    nodes.push({ id: `${id}_env`, type: 'ADSR', parameters: envelopeParameters(op) });
    wire('note', 'gate', `${id}_env`, 'gate');
    nodes.push({ id: `${id}_vca`, type: 'Multiply', parameters: {} });
    wire(`${id}_osc`, 'out', `${id}_vca`, 'a');
    wire(`${id}_env`, 'out', `${id}_vca`, 'b');
    // The envelope scales the feedback bite (see OPERATOR_MODULE's fbscale);
    // emitted for every op so flat and modular stay structurally identical —
    // inert wherever the feedback parameter is 0.
    nodes.push({ id: `${id}_fbscale`, type: 'Multiply', parameters: {} });
    wire(`${id}_env`, 'out', `${id}_fbscale`, 'a');
    wire(`${id}_fbscale`, 'out', `${id}_osc`, 'feedback');
  }

  const liveOps = voice.ops.filter((o) => live.has(o.op));
  const tremoloOps = voice.lfoAmd > 0
    ? liveOps.filter((o) => o.ampModSens > 0) : [];

  // The LFO fade (lfo.cc): the chip holds the LFO silent, then ramps it in
  // linearly. The ADSR's single linear attack cannot hold, so the ramp runs over
  // the combined time and is squared — a shape that starts slow and lands the
  // endpoints exactly. The chip's delay also survives note-off (only key-on resets
  // it); the closest the ADSR gets is the slowest release it has.
  const fade = (hasVibrato || tremoloOps.length > 0)
    ? lfoDelayTimes(voice.lfoDelay) : null;
  let fadeSource = '';
  if (fade !== null) {
    nodes.push({ id: 'lfo_fade', type: 'ADSR', parameters: {
      attack: Number((fade.hold + fade.ramp).toFixed(4)),
      decay: 0, sustain: 1, release: 10 } });
    wire('note', 'gate', 'lfo_fade', 'gate');
    nodes.push({ id: 'lfo_fade_sq', type: 'Multiply', parameters: {} });
    wire('lfo_fade', 'out', 'lfo_fade_sq', 'a');
    wire('lfo_fade', 'out', 'lfo_fade_sq', 'b');
    fadeSource = 'lfo_fade_sq';
    notes.push('LFO delay hold-then-ramp approximated as a squared ramp '
      + 'that sags slowly after note-off instead of holding');
  }

  // Global pitch modulation: vibrato and the pitch envelope, both in octaves, summed
  // if both exist and fed to every sounding oscillator's fm input — on the chip the
  // pitch is one number the whole voice shares, fixed-frequency operators included.
  let pitchModSource = '';
  if (hasVibrato) {
    nodes.push({ id: 'vibrato', type: 'LFO', parameters: {
      rate: Number(lfoHz(voice.lfoSpeed).toFixed(4)),
      shape: LFO_SHAPE[voice.lfoWave],
      amount: Number(vibratoDepth.toFixed(5)),
    } });
    pitchModSource = 'vibrato';
    if (fadeSource !== '') {
      nodes.push({ id: 'vibrato_faded', type: 'Multiply', parameters: {} });
      wire('vibrato', 'out', 'vibrato_faded', 'a');
      wire(fadeSource, 'out', 'vibrato_faded', 'b');
      pitchModSource = 'vibrato_faded';
    }
    if (voice.lfoWave === 1) notes.push('saw-down LFO rendered as rising saw');
  }
  if (hasPitchEnvelope) {
    // The ADSR runs 0..1; a Multiply stretches it to the excursion above L4. Sustain
    // sits at (L3-L4)/(L1-L4) of the peak; a voice whose peak equals its floor but
    // still moves (L1 == L4, L3 elsewhere) scales to the sustain excursion instead.
    let egScale = pitchEg[0] - egBase;
    let egSustain = 1;
    if (Math.abs(egScale) < 0.001) {
      egScale = pitchEg[2] - egBase;
      notes.push('pitch envelope attack peak flattened to its sustain level');
    } else {
      egSustain = Math.max(0, Math.min(1, (pitchEg[2] - egBase) / egScale));
    }
    const [pr1, pr2, pr3, pr4] = voice.pitchRates;
    nodes.push({ id: 'pitch_env', type: 'ADSR', parameters: {
      attack: Number(pitchSlewSeconds(pitchEg[0] - egBase, pr1).toFixed(4)),
      decay: Number(Math.min(10, pitchSlewSeconds(pitchEg[1] - pitchEg[0], pr2)
        + pitchSlewSeconds(pitchEg[2] - pitchEg[1], pr3)).toFixed(4)),
      sustain: Number(egSustain.toFixed(4)),
      release: Number(pitchSlewSeconds(egBase - pitchEg[2], pr4).toFixed(4)),
    } });
    wire('note', 'gate', 'pitch_env', 'gate');
    nodes.push({ id: 'pitch_scale', type: 'Multiply',
      parameters: { factor: Number(egScale.toFixed(5)) } });
    wire('pitch_env', 'out', 'pitch_scale', 'a');
    notes.push('pitch envelope L2 folded into the decay, exponential not linear');
    if (pitchModSource === '') {
      pitchModSource = 'pitch_scale';
    } else {
      nodes.push({ id: 'pitch_mod', type: 'Add', parameters: {} });
      wire(pitchModSource, 'out', 'pitch_mod', 'a');
      wire('pitch_scale', 'out', 'pitch_mod', 'b');
      pitchModSource = 'pitch_mod';
    }
  }
  if (pitchModSource !== '') {
    for (const op of voice.ops) {
      if (live.has(op.op)) wire(pitchModSource, 'out', `op${op.op}_osc`, 'fm');
    }
  }

  // Tremolo: a second LFO at the same rate and phase emits the unipolar dip drive
  // (1 - shape)/2 — zero at the LFO's peak, one at its trough, matching the chip's
  // inverted-LFO convention — faded by the delay, then each sensitive operator gets
  // its own affine map to an amplitude factor 1 - swing*x and a multiply after its
  // VCA, so modulators wobble their index and carriers wobble the mix, exactly
  // where msfa applies the level subtraction.
  const tremolo = new Map();
  if (tremoloOps.length > 0) {
    nodes.push({ id: 'tremolo', type: 'LFO', parameters: {
      rate: Number(lfoHz(voice.lfoSpeed).toFixed(4)),
      shape: LFO_SHAPE[voice.lfoWave],
      amount: -0.5, offset: 0.5 } });
    let dipDrive = 'tremolo';
    if (fadeSource !== '') {
      nodes.push({ id: 'tremolo_faded', type: 'Multiply', parameters: {} });
      wire('tremolo', 'out', 'tremolo_faded', 'a');
      wire(fadeSource, 'out', 'tremolo_faded', 'b');
      dipDrive = 'tremolo_faded';
    }
    for (const op of tremoloOps) {
      const swing = 1 - Math.pow(2, -tremoloDip(op, voice.lfoAmd));
      const id = `op${op.op}`;
      nodes.push({ id: `${id}_trem_depth`, type: 'Multiply',
        parameters: { factor: Number((-swing).toFixed(5)) } });
      wire(dipDrive, 'out', `${id}_trem_depth`, 'a');
      nodes.push({ id: `${id}_trem_bias`, type: 'Add', parameters: { offset: 1 } });
      wire(`${id}_trem_depth`, 'out', `${id}_trem_bias`, 'a');
      nodes.push({ id: `${id}_trem`, type: 'Multiply', parameters: {} });
      wire(`${id}_vca`, 'out', `${id}_trem`, 'a');
      wire(`${id}_trem_bias`, 'out', `${id}_trem`, 'b');
      tremolo.set(op.op, `${id}_trem`);
    }
    notes.push("tremolo per Dexed's formula (the vendored oracle has none), "
      + 'swung linearly in amplitude between the log-domain extremes');
  }
  const postVca = new Map(tremolo);

  // Live velocity: the static amplitudes above stay baked at the reference
  // velocity (so nothing else in this file moved), and each sensitive operator is
  // multiplied by the squared-affine response — see velocityCurve() for why that
  // shape and what it costs. One curve chain per distinct sensitivity, shared;
  // one multiply per operator, composed after tremolo so both wobbles reach the
  // modulator index and the carrier mix alike.
  const velocityOps = liveOps.filter((o) => o.velocitySens > 0);
  const velCurveOf = new Map();
  if (velocityOps.length > 0) {
    const curves = new Map();
    for (const op of velocityOps) {
      const sens = op.velocitySens;
      if (!curves.has(sens)) {
        const { alpha, beta } = velocityCurve(sens);
        nodes.push({ id: `vel${sens}_scale`, type: 'Multiply',
          parameters: { factor: Number(beta.toFixed(5)) } });
        wire('note', 'velocity', `vel${sens}_scale`, 'a');
        nodes.push({ id: `vel${sens}_bias`, type: 'Add',
          parameters: { offset: Number(alpha.toFixed(5)) } });
        wire(`vel${sens}_scale`, 'out', `vel${sens}_bias`, 'a');
        nodes.push({ id: `vel${sens}_curve`, type: 'Multiply', parameters: {} });
        wire(`vel${sens}_bias`, 'out', `vel${sens}_curve`, 'a');
        wire(`vel${sens}_bias`, 'out', `vel${sens}_curve`, 'b');
        curves.set(sens, `vel${sens}_curve`);
      }
      const id = `op${op.op}`;
      nodes.push({ id: `${id}_vel`, type: 'Multiply', parameters: {} });
      wire(postVca.get(op.op) ?? `${id}_vca`, 'out', `${id}_vel`, 'a');
      wire(curves.get(sens), 'out', `${id}_vel`, 'b');
      postVca.set(op.op, `${id}_vel`);
      velCurveOf.set(op.op, curves.get(sens));
    }
    notes.push('live velocity as a squared-affine curve, exact at velocities '
      + '100 and 127, overstating below about 20');
  }
  const opOut = (n) => postVca.get(n) ?? `op${n}_vca`;

  // On the chip the feedback displacement is the op's *gain-scaled* output, so
  // whatever moves the feedback op's level moves the bite of its loop. The
  // envelope already rides fbscale's a input; tremolo and velocity multiply in
  // through its b input, which the operator module declares as fb_mod.
  if (topology.feedback > 0 && voice.feedbackLevel > 0) {
    const factors = [];
    if (tremolo.has(topology.feedback)) {
      factors.push(`op${topology.feedback}_trem_bias`);
    }
    if (velCurveOf.has(topology.feedback)) {
      factors.push(velCurveOf.get(topology.feedback));
    }
    const scaleId = `op${topology.feedback}_fbscale`;
    if (factors.length === 2) {
      nodes.push({ id: `op${topology.feedback}_fb_mod`, type: 'Multiply',
        parameters: {} });
      wire(factors[0], 'out', `op${topology.feedback}_fb_mod`, 'a');
      wire(factors[1], 'out', `op${topology.feedback}_fb_mod`, 'b');
      wire(`op${topology.feedback}_fb_mod`, 'out', scaleId, 'b');
    } else if (factors.length === 1) {
      wire(factors[0], 'out', scaleId, 'b');
    }
  }

  // What the scaling arithmetic above silently fixed at the reference point.
  if (liveOps.some((o) => o.rateScaling > 0 || o.leftDepth > 0 || o.rightDepth > 0)) {
    notes.push('key scaling evaluated at MIDI 57 only');
  }

  // Modulation inputs: each modulated op sums its sources through Add nodes into pm.
  // Modulators carry the index scale; carriers carry their level into the mix.
  for (const op of voice.ops) {
    if (!live.has(op.op)) continue;
    const sources = modulatorTargets.get(op.op) || [];
    if (sources.length === 0) continue;
    let feed = '';
    for (let i = 0; i < sources.length; ++i) {
      const from = sources[i];
      const fromOp = voice.ops.find((o) => o.op === from);
      const gainId = `op${from}_index_${op.op}`;
      nodes.push({ id: gainId, type: 'Gain',
        name: `OP${from} → OP${op.op}`, parameters: {
          gain: Number((INDEX_FULL * operatorAmp(fromOp)).toFixed(4)) } });
      wire(opOut(from), 'out', gainId, 'in');
      if (i === 0) {
        feed = gainId;
      } else {
        const addId = `op${op.op}_pm_sum_${i}`;
        nodes.push({ id: addId, type: 'Add',
          name: `OP${op.op} modulation sum`, parameters: {} });
        wire(feed, 'out', addId, 'a');
        wire(gainId, 'out', addId, 'b');
        feed = addId;
      }
    }
    wire(feed, 'out', `op${op.op}_osc`, 'pm');
  }

  // Carriers sum into the output, normalised so a six-carrier organ cannot clip.
  let carrierAmpSum = 0;
  for (const c of topology.carriers) {
    carrierAmpSum += operatorAmp(voice.ops.find((o) => o.op === c));
  }
  let mix = '';
  topology.carriers.forEach((c, i) => {
    const levelId = `op${c}_level`;
    const carrierOp = voice.ops.find((o) => o.op === c);
    nodes.push({ id: levelId, type: 'Gain', name: `OP${c} level`, parameters: {
      gain: Number(operatorAmp(carrierOp).toFixed(4)) } });
    wire(opOut(c), 'out', levelId, 'in');
    if (i === 0) {
      mix = levelId;
    } else {
      const addId = `carrier_sum_${i}`;
      nodes.push({ id: addId, type: 'Add', name: 'Carrier mix', parameters: {} });
      wire(mix, 'out', addId, 'a');
      wire(levelId, 'out', addId, 'b');
      mix = addId;
    }
  });
  nodes.push({ id: 'out', type: 'Output', host: 'stereo', parameters: {
    level: Number((0.8 / Math.max(1, carrierAmpSum)).toFixed(4)) } });
  wire(mix, 'out', 'out', 'left');
  wire(mix, 'out', 'out', 'right');

  return {
    schema_version: 1,
    metadata: {
      name: voice.name || `Voice ${voiceIndex + 1}`,
      description: `${voice.name} — DX7 voice, algorithm ${voice.algorithm + 1}, `
        + `imported by tools/dx7-import.mjs from ${bankName}.`
        + (notes.length > 0 ? ` Approximated: ${notes.join('; ')}.` : ''),
      author: 'SoundGraph dx7-import (mapping)',
      tags: ['fm', 'dx7', 'imported', `algorithm-${voice.algorithm + 1}`],
      source: `tools/dx7/banks/${bankName}`,
    },
    nodes,
    connections,
  };
}

// ---------------------------------------------------------------------------------
// Bank walking: 4104-byte 32-voice SysEx (F0 43 0n 09 20 00 ... checksum F7).
// ---------------------------------------------------------------------------------

function readBank(path) {
  const bytes = readFileSync(path);
  const start = bytes.indexOf(0xf0);
  if (start < 0 || bytes[start + 1] !== 0x43 || bytes[start + 3] !== 0x09) {
    throw new Error(`${path} is not a DX7 32-voice bank`);
  }
  const data = bytes.subarray(start + 6, start + 6 + 4096);
  const voices = [];
  for (let i = 0; i < 32; ++i) {
    voices.push(decodeVoice(data.subarray(i * 128, (i + 1) * 128)));
  }
  return voices;
}

const slug = (name) => name.toLowerCase().replace(/[^a-z0-9]+/g, '-')
  .replace(/^-|-$/g, '') || 'unnamed';

// ---------------------------------------------------------------------------------
// Modular form — docs/modules-design.md stage 1.
//
// Not a second builder: modularize() *factors* the flat patch, replacing each
// standard ratio-mode operator cluster (opN_pitch/osc/env/vca with the canonical
// internal wiring) with one instance of an "operator" module whose exported
// parameters carry that op's values. Expansion in patch-io inverts this exactly,
// which is what --modular-check proves with rendered bytes: same voice, two
// notations, one sound. Fixed-frequency ops stay flat — a mixed document is legal.
// ---------------------------------------------------------------------------------

// Named for the chip, not for the concept. Both importers used to call this "operator",
// so a DX7 voice and an OPL2 instrument claimed the same module name for two genuinely
// different things — six-operator phase modulation and a two-operator pair — and a
// document holding both would have had them collide. The editor turns the model number
// back into capitals for display.
const OPERATOR_MODULE_NAME = 'dx7_operator';

const OPERATOR_MODULE = {
  description: 'One DX7 operator: pitch ratio, sine, envelope, VCA.',
  nodes: [
    { id: 'pitch', type: 'Multiply', parameters: { factor: 1 } },
    { id: 'osc', type: 'SineOscillator', parameters: {} },
    { id: 'env', type: 'ADSR', parameters: {} },
    { id: 'vca', type: 'Multiply', parameters: {} },
    // The chip's feedback bite is the op's *gain-scaled* output, so the envelope
    // scales the oscillator's feedback here — env times fb_mod (which falls back
    // to factor 1 while unconnected). On the five ops per voice with feedback
    // parameter 0 this whole path is inert by the oscillator's own gate.
    { id: 'fbscale', type: 'Multiply', parameters: {} },
  ],
  connections: [
    { from: { node: 'pitch', port: 'out' }, to: { node: 'osc', port: 'frequency' } },
    { from: { node: 'osc', port: 'out' }, to: { node: 'vca', port: 'a' } },
    { from: { node: 'env', port: 'out' }, to: { node: 'vca', port: 'b' } },
    { from: { node: 'env', port: 'out' }, to: { node: 'fbscale', port: 'a' } },
    { from: { node: 'fbscale', port: 'out' }, to: { node: 'osc', port: 'feedback' } },
  ],
  inputs: [
    { name: 'note', node: 'pitch', port: 'a' },
    { name: 'gate', node: 'env', port: 'gate' },
    { name: 'pm', node: 'osc', port: 'pm' },
    { name: 'fm', node: 'osc', port: 'fm' },
    // Named fb_mod, not feedback: the module already exports a *parameter* called
    // feedback, and one word meaning two things on one surface is how patches get
    // miswired. It lands on fbscale's b input so external factors (tremolo,
    // velocity) multiply with the envelope rather than displacing it.
    { name: 'fb_mod', node: 'fbscale', port: 'b' },
  ],
  outputs: [{ name: 'out', node: 'vca', port: 'out' }],
  parameters: [
    { name: 'ratio', node: 'pitch', parameter: 'factor' },
    { name: 'feedback', node: 'osc', parameter: 'feedback' },
    { name: 'attack', node: 'env', parameter: 'attack' },
    { name: 'decay', node: 'env', parameter: 'decay' },
    { name: 'sustain', node: 'env', parameter: 'sustain' },
    { name: 'release', node: 'env', parameter: 'release' },
  ],
};

function modularize(flat) {
  const byId = new Map(flat.nodes.map((n) => [n.id, n]));
  const clusters = [];
  for (const node of flat.nodes) {
    const m = /^op(\d)_pitch$/.exec(node.id);
    if (!m) continue;
    const op = m[1];
    if (byId.has(`op${op}_osc`) && byId.has(`op${op}_env`) && byId.has(`op${op}_vca`)
        && byId.has(`op${op}_fbscale`)) {
      clusters.push(op);
    }
  }
  if (clusters.length === 0) return null;

  const inner = new Set();
  for (const op of clusters) {
    for (const part of ['pitch', 'osc', 'env', 'vca', 'fbscale']) {
      inner.add(`op${op}_${part}`);
    }
  }

  const nodes = [];
  for (const node of flat.nodes) {
    const m = /^op(\d)_pitch$/.exec(node.id);
    if (m && clusters.includes(m[1])) {
      const op = m[1];
      const osc = byId.get(`op${op}_osc`);
      const env = byId.get(`op${op}_env`);
      const parameters = {
        ratio: node.parameters.factor,
        attack: env.parameters.attack,
        decay: env.parameters.decay,
        sustain: env.parameters.sustain,
        release: env.parameters.release,
      };
      if (osc.parameters.feedback !== undefined) {
        parameters.feedback = osc.parameters.feedback;
      }
      nodes.push({ id: `op${op}`, type: 'module', module: OPERATOR_MODULE_NAME,
        name: node.name ?? `OP${op}`, parameters });
      continue;
    }
    if (inner.has(node.id)) continue;
    nodes.push(node);
  }

  const port = (id, fallbackPort) => {
    const m = /^op(\d)_(pitch|osc|env|vca|fbscale)$/.exec(id);
    if (!m || !clusters.includes(m[1])) return null;
    return { instance: `op${m[1]}`, part: m[2] };
  };
  const connections = [];
  for (const connection of flat.connections) {
    const from = port(connection.from.node);
    const to = port(connection.to.node);
    const fromInside = from !== null;
    const toInside = to !== null;
    if (fromInside && toInside && from.instance === to.instance) {
      continue;  // internal wiring lives in the definition now
    }
    const rewritten = { from: { ...connection.from }, to: { ...connection.to } };
    if (fromInside) {
      rewritten.from = { node: from.instance, port: 'out' };
    }
    if (toInside) {
      // Boundary ports: pm carries operator FM, fm the voice's pitch modulation
      // in octaves, and fbscale's b input the loop's external amplitude factors —
      // declared as fb_mod because the module's parameter list already owns the
      // word "feedback".
      const name = to.part === 'pitch' ? 'note'
        : to.part === 'env' ? 'gate'
        : to.part === 'fbscale' ? 'fb_mod' : connection.to.port;
      rewritten.to = { node: to.instance, port: name };
    }
    connections.push(rewritten);
  }

  return {
    schema_version: 2,
    metadata: flat.metadata,
    modules: { [OPERATOR_MODULE_NAME]: OPERATOR_MODULE },
    nodes,
    connections,
  };
}

// --modular-check: the stage-1 exit test from docs/modules-design.md. Every voice is
// built flat and factored modular, both rendered, and the WAVs must match byte for
// byte: notation changes, sound does not. Runs before anything else and exits.
if (process.argv.includes('--modular-check')) {
  const { execFileSync } = await import('node:child_process');
  const { mkdtempSync } = await import('node:fs');
  const { tmpdir } = await import('node:os');
  const scratch = mkdtempSync(join(tmpdir(), 'dx7-modular-'));
  const bin = join(root, 'build', 'bin');
  let differing = 0;
  let factored = 0;
  for (const bank of readdirSync(source).filter((f) => f.endsWith('.syx')).sort()) {
    const voices = readBank(join(source, bank));
    voices.forEach((voice, index) => {
      const flat = buildPatch(voice, bank, index);
      const modular = modularize(flat);
      if (modular === null) return;  // all-fixed voices have nothing to factor
      factored += 1;
      const flatPath = join(scratch, `v${index}-flat.json`);
      const modularPath = join(scratch, `v${index}-modular.json`);
      writeFileSync(flatPath, JSON.stringify(flat));
      writeFileSync(modularPath, JSON.stringify(modular));
      const flatWav = join(scratch, `v${index}-flat.wav`);
      const modularWav = join(scratch, `v${index}-modular.wav`);
      execFileSync(join(bin, 'sg-render'), [flatPath, flatWav,
        '--seconds', '1', '--notes', '57', '--gate', '0.7', '--quiet']);
      execFileSync(join(bin, 'sg-render'), [modularPath, modularWav,
        '--seconds', '1', '--notes', '57', '--gate', '0.7', '--quiet']);
      if (!readFileSync(flatWav).equals(readFileSync(modularWav))) {
        console.error(`  differs: voice ${index} (${voice.name})`);
        differing += 1;
      }
    });
  }
  if (differing > 0 || factored === 0) {
    console.error(`${differing} voice(s) render differently modular vs flat `
      + `(${factored} factored).`);
    process.exit(1);
  }
  console.log(`All ${factored} voices render byte-identical audio, modular and flat.`);
  process.exit(0);
}

const check = process.argv.includes('--check');
let differences = 0;
mkdirSync(target, { recursive: true });

const banks = readdirSync(source).filter((f) => f.endsWith('.syx')).sort();
let written = 0;
for (const bank of banks) {
  const voices = readBank(join(source, bank));
  const used = new Set();
  voices.forEach((voice, index) => {
    // Stage 4 of docs/modules-design.md: the importer emits what it knows. A voice is
    // one operator module and six instances, so that is what the file says —
    // modularize() is proven byte-identical against the flat form by --modular-check,
    // which still builds both. A voice with nothing to factor (all fixed-frequency
    // operators) stays flat, which a mixed library is allowed to be.
    const flat = buildPatch(voice, bank, index);
    const patch = modularize(flat) ?? flat;
    let name = slug(voice.name || `voice-${index + 1}`);
    while (used.has(name)) name = `${name}-${index + 1}`;
    used.add(name);
    const text = JSON.stringify(patch, null, 2) + '\n';
    const out = join(target, `${name}.json`);
    written += 1;
    if (check) {
      let committed = '';
      try { committed = readFileSync(out, 'utf8'); } catch { /* different */ }
      if (committed !== text) {
        console.error(`  differs: ${out}`);
        differences += 1;
      }
    } else {
      writeFileSync(out, text);
    }
  });
}

if (check) {
  if (differences > 0) {
    console.error(`${differences} imported patch(es) differ from the importer's output.`);
    process.exit(1);
  }
  console.log(`All ${written} imported DX7 patches match the importer.`);
} else {
  console.log(`${written} voices imported from ${banks.length} bank(s) into examples/patches/dx7/.`);
}
