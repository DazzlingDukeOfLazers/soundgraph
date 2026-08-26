#!/usr/bin/env node
// Turns a WAV into words the Speech node can say.
//
//   node tools/lpc-encode.mjs voice.wav            # base64 for a patch buffer
//   node tools/lpc-encode.mjs voice.wav --stats    # what the encoder heard
//
// TMS5220-style LPC-10 analysis: 25 ms frames at 8 kHz, ten reflection coefficients
// by Levinson-Durbin, energy and pitch by autocorrelation, everything quantized to
// the chip's own coefficient ROM (the same tables the Speech node carries). The
// output is the node's buffer format — one bitstream byte per pcm16 sample,
// LSB-first — as base64 ready to paste into a patch's "buffers" section.
//
// This is a hobby-grade encoder on purpose. The chip's charm is the artifact, and a
// better analysis would only make it sound less like the toy everyone remembers.

import { readFileSync } from 'node:fs';

// ---- the chip's ROM, shared with dsp-core/src/nodes/speech.cpp -------------------
// Two copies by design: this tool must run without a native build, and the tables
// are decap-verified constants that have not changed since 1983. If they ever look
// different from speech.cpp, one of the copies has been vandalised.
const ENERGY = [0, 1, 2, 3, 4, 6, 8, 11, 16, 23, 33, 47, 63, 85, 114, 0];
const PITCH = [
  0, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29,
  30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 44, 46, 48,
  50, 52, 53, 56, 58, 60, 62, 65, 68, 70, 72, 76, 78, 80, 84, 86,
  91, 94, 98, 101, 105, 109, 114, 118, 122, 127, 132, 137, 142, 148, 153, 159];
const K_TABLES = [
  [-501, -498, -497, -495, -493, -491, -488, -482, -478, -474, -469, -464, -459, -452,
   -445, -437, -412, -380, -339, -288, -227, -158, -81, -1, 80, 157, 226, 287,
   337, 379, 411, 436],
  [-328, -303, -274, -244, -211, -175, -138, -99, -59, -18, 24, 64, 105, 143,
   180, 215, 248, 278, 306, 331, 354, 374, 392, 408, 422, 435, 445, 455,
   463, 470, 476, 506],
  [-441, -387, -333, -279, -225, -171, -117, -63, -9, 45, 98, 152, 206, 260, 314, 368],
  [-328, -273, -217, -161, -106, -50, 5, 61, 116, 172, 228, 283, 339, 394, 450, 506],
  [-328, -282, -235, -189, -142, -96, -50, -3, 43, 90, 136, 182, 229, 275, 322, 368],
  [-256, -212, -168, -123, -79, -35, 10, 54, 98, 143, 187, 232, 276, 320, 365, 409],
  [-308, -260, -212, -164, -117, -69, -21, 27, 75, 122, 170, 218, 266, 314, 361, 409],
  [-256, -161, -66, 29, 124, 219, 314, 409],
  [-256, -176, -96, -15, 65, 146, 226, 307],
  [-205, -132, -59, 14, 87, 160, 234, 307]];
const K_BITS = [5, 5, 4, 4, 4, 4, 4, 3, 3, 3];

const RATE = 8000;
const FRAME = 200;
// Maps a frame's RMS onto the chip's energy scale; set by ear against the node's
// own excitation scaling, which is the only authority that matters here.
const ENERGY_CALIBRATION = 700;

// ---- wav in ----------------------------------------------------------------------
function readWav(path) {
  const bytes = readFileSync(path);
  if (bytes.toString('ascii', 0, 4) !== 'RIFF') throw new Error('not a wav');
  let offset = 12;
  let format = null;
  let data = null;
  while (offset + 8 <= bytes.length) {
    const id = bytes.toString('ascii', offset, offset + 4);
    const size = bytes.readUInt32LE(offset + 4);
    if (id === 'fmt ') {
      format = {
        channels: bytes.readUInt16LE(offset + 10),
        rate: bytes.readUInt32LE(offset + 12),
        bits: bytes.readUInt16LE(offset + 22),
      };
    } else if (id === 'data') {
      data = bytes.subarray(offset + 8, offset + 8 + size);
    }
    offset += 8 + size + (size & 1);
  }
  if (!format || !data || format.bits !== 16) throw new Error('need 16-bit pcm');
  const frames = Math.floor(data.length / 2 / format.channels);
  const mono = new Float64Array(frames);
  for (let i = 0; i < frames; i++) {
    let sum = 0;
    for (let c = 0; c < format.channels; c++) {
      sum += data.readInt16LE((i * format.channels + c) * 2) / 32768;
    }
    mono[i] = sum / format.channels;
  }
  return { samples: mono, rate: format.rate };
}

function resampleTo8k(samples, rate) {
  const out = new Float64Array(Math.floor((samples.length * RATE) / rate));
  for (let i = 0; i < out.length; i++) {
    const at = (i * rate) / RATE;
    const low = Math.floor(at);
    const frac = at - low;
    out[i] = samples[low] * (1 - frac) + (samples[low + 1] ?? samples[low]) * frac;
  }
  return out;
}

// ---- analysis --------------------------------------------------------------------
function nearest(table, value) {
  let best = 0;
  for (let i = 1; i < table.length; i++) {
    if (Math.abs(table[i] - value) < Math.abs(table[best] - value)) best = i;
  }
  return best;
}

function analyseFrame(chunk, plain) {
  // Hamming window over the pre-emphasized frame, autocorrelation to order 10.
  const windowed = chunk.map((s, i) =>
    s * (0.54 - 0.46 * Math.cos((2 * Math.PI * i) / (chunk.length - 1))));
  const r = [];
  for (let lag = 0; lag <= 10; lag++) {
    let sum = 0;
    for (let i = lag; i < windowed.length; i++) sum += windowed[i] * windowed[i - lag];
    r.push(sum);
  }

  let rms = 0;
  for (const s of plain) rms += s * s;
  rms = Math.sqrt(rms / plain.length);
  const energyIndex = nearest(ENERGY.slice(0, 15), rms * ENERGY_CALIBRATION);
  if (energyIndex === 0 || r[0] <= 0) return { energy: 0 };

  // Levinson-Durbin, keeping the reflection coefficients it produces.
  const ks = [];
  const a = new Float64Array(11);
  let error = r[0];
  for (let m = 1; m <= 10; m++) {
    let acc = r[m];
    for (let j = 1; j < m; j++) acc -= a[j] * r[m - j];
    let k = error > 1e-12 ? acc / error : 0;
    k = Math.max(-0.98, Math.min(0.98, k));
    ks.push(k);
    const next = Float64Array.from(a);
    next[m] = k;
    for (let j = 1; j < m; j++) next[j] = a[j] - k * a[m - j];
    a.set(next);
    error *= 1 - k * k;
  }

  // Pitch from the plain frame's autocorrelation, and a voicing decision from how
  // periodic the frame actually is.
  let r0 = 0;
  for (const s of plain) r0 += s * s;
  let bestLag = 0;
  let bestScore = 0;
  for (let lag = 15; lag <= 159 && lag < plain.length; lag++) {
    let sum = 0;
    for (let i = lag; i < plain.length; i++) sum += plain[i] * plain[i - lag];
    if (sum > bestScore) {
      bestScore = sum;
      bestLag = lag;
    }
  }
  const voiced = r0 > 0 && bestScore / r0 > 0.3;
  // Sign convention: Levinson-Durbin's reflection coefficients land opposite the
  // chip's lattice, whose K tables are applied subtracting. Flip once, here.
  const quantized = ks.map((k, i) => nearest(K_TABLES[i], -k * 512));
  return {
    energy: energyIndex,
    voiced,
    pitch: voiced ? nearest(PITCH.slice(1), bestLag) + 1 : 0,
    ks: quantized,
  };
}

// ---- bitstream out ---------------------------------------------------------------
class BitWriter {
  constructor() { this.bytes = []; this.bit = 0; }
  put(value, count) {
    for (let b = 0; b < count; b++) {
      if (this.bit % 8 === 0) this.bytes.push(0);
      this.bytes[this.bytes.length - 1] |= ((value >> b) & 1) << (this.bit % 8);
      this.bit++;
    }
  }
}

function encode(samples) {
  const emphasized = Float64Array.from(samples);
  for (let i = emphasized.length - 1; i > 0; i--) {
    emphasized[i] -= 0.9375 * emphasized[i - 1];
  }
  const writer = new BitWriter();
  const stats = { frames: 0, voiced: 0, silent: 0 };
  for (let start = 0; start + FRAME <= samples.length; start += FRAME) {
    const frame = analyseFrame(
      Array.from(emphasized.subarray(start, start + FRAME)),
      Array.from(samples.subarray(start, start + FRAME)));
    stats.frames++;
    writer.put(frame.energy, 4);
    if (frame.energy === 0) {
      stats.silent++;
      continue;
    }
    stats.voiced += frame.voiced ? 1 : 0;
    writer.put(0, 1);                       // never a repeat frame: bits are cheap here
    writer.put(frame.voiced ? frame.pitch : 0, 6);
    const stages = frame.voiced ? 10 : 4;
    for (let i = 0; i < stages; i++) writer.put(frame.ks[i], K_BITS[i]);
  }
  writer.put(15, 4);                        // stop
  return { bytes: writer.bytes, stats };
}

// Each bitstream byte becomes one pcm16 sample holding that byte's value — exact
// through the fixed-point round trip, and no new buffer format for the schema.
function toBufferBase64(bytes) {
  const packed = Buffer.alloc(bytes.length * 2);
  for (let i = 0; i < bytes.length; i++) packed.writeInt16LE(bytes[i], i * 2);
  return packed.toString('base64');
}

const args = process.argv.slice(2);
const wantStats = args.includes('--stats');
const wavPaths = args.filter((a) => a !== '--stats');
if (wavPaths.length === 0) {
  console.error('usage: node tools/lpc-encode.mjs voice.wav [more.wav ...] [--stats]');
  console.error('  several WAVs become one bank: each file is a stop-delimited phrase,');
  console.error("  and the Speech node's note input picks one.");
  process.exit(2);
}
const bytes = [];
for (const wavPath of wavPaths) {
  const { samples, rate } = readWav(wavPath);
  const at8k = rate === RATE ? samples : resampleTo8k(samples, rate);
  const { bytes: phrase, stats } = encode(at8k);
  bytes.push(...phrase);
  if (wantStats) {
    console.error(`${wavPath}: ${stats.frames} frames (${stats.voiced} voiced, `
      + `${stats.silent} silent), ${phrase.length} bytes from `
      + `${(at8k.length / RATE).toFixed(2)} s`);
  }
}
console.log(JSON.stringify({
  sample_rate: RATE,
  channels: 1,
  format: 'pcm16',
  data: toBufferBase64(bytes),
}));
