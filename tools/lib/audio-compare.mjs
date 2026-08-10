// Shared measurement for the oracle comparators (OPL2, DX7). Every function here was
// paid for with a specific mistake in tools/opl2-compare.mjs — the comments carry the
// receipts, because these are exactly the mistakes a rewrite would make again.

import { readFileSync } from 'node:fs';

// Reads channel 0, honouring the channel count. The first version read the raw stream
// as mono; sg-render writes stereo and the oracles write mono, so every frequency on
// one side came out halved — and an octave-tolerant fold upstream masked it, sending
// a night's bug hunt through engine code that had nothing wrong in it.
export function readWav(path) {
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

// The loudest 0.3s, envelope-flattened.
//
// Loudest, because a fixed window measures percussive voices after they have finished.
// 0.3s, because a plucked note should fill the window with pluck, not with the
// emulator's resampling ripple. Flattened — each sample divided by the local RMS —
// because normalised autocorrelation punishes a decaying note for decaying: the
// OPL shamisen scored 0.35 at its own true period before this.
export function held(wav) {
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

// Normalised self-similarity at one lag.
export function scoreAt(slice, lag) {
  let dot = 0;
  let energy = 0;
  for (let i = 0; i + lag < slice.length; ++i) {
    dot += slice[i] * slice[i + lag];
    energy += slice[i] * slice[i];
  }
  return energy > 0 ? dot / energy : 0;
}

// Strongest period between floorHz and 2000 Hz. The floor is the caller's physics —
// for OPL at A3 nothing true lives below 110 Hz; searching lower found "44 Hz
// fundamentals" that were envelope drift outscoring the real period.
export function fundamental(wav, floorHz) {
  const slice = held(wav);
  const lagLow = Math.floor(wav.rate / 2000);
  const lagHigh = Math.floor(wav.rate / floorHz);
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

// Do the two renders agree about pitch? Either measured period may vouch for both —
// a sparse three-partial spectrum can fool a single-peak search on either side — and
// a genuinely detuned voice still fails, because its period satisfies nobody but
// itself.
export function sharePeriodicity(a, b, aF0, bF0) {
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

// Harmonic instruments are periodic at f0/2 and f0/3 too; integer-ratio disagreement
// is agreement about pitch.
export function octaveFolded(measured, reference) {
  for (const fold of [1, 2, 3, 4]) {
    for (const candidate of [measured * fold, measured / fold]) {
      if (Math.abs(candidate - reference) / reference < 0.03) return candidate;
    }
  }
  return measured;
}

export const rms = (wav) => {
  const sum = wav.samples.reduce((a, s) => a + s * s, 0);
  return Math.sqrt(sum / wav.samples.length);
};
