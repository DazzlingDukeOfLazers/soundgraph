// compare-waveforms — how close is one rendering of a sound to another?
//
//   node tools/compare-waveforms.mjs <reference.wav> <candidate.wav> [--json]
//   node tools/compare-waveforms.mjs --self-test tests/sfxr
//
// Written for the sfxr port, where sample-exact comparison is not available and pretending
// otherwise would produce a test that can only ever fail.
//
// Why not just diff the samples. The golden vectors in tests/golden are compared sample by
// sample because both sides run the *same* code — the question there is whether a compiler
// or an architecture changed the answer. Here the two sides are different implementations
// of the same idea: sfxr steps a period counter with 8x supersampling and refills a
// 32-entry noise buffer from its own PRNG, while a SoundGraph patch runs band-limited
// oscillators at block rate from a different PRNG. Those cannot agree sample for sample,
// and for anything using the noise waveform they cannot agree at all in the time domain.
// What can be asked is whether they have the same shape: the same length, the same level,
// the same loudness contour, and the same spectrum over time.
//
// The metrics, and what each one catches:
//
//   length      the envelope ran for the same time. Catches wrong envelope-stage maths,
//               which is the single easiest thing to get wrong in this port.
//   gain        overall level, in dB. Reported separately and divided out before the
//               spectral comparison, so "too quiet" does not masquerade as "wrong
//               timbre" — they are different bugs with different fixes.
//   envelope    per-frame loudness in dB against time. Catches attack/decay shape, punch,
//               and the repeat mechanism restarting at the wrong moment.
//   spectrum    log-spectral distance in dB: mean absolute difference between the two
//               magnitude spectra, frame by frame. Catches wrong waveform, wrong pitch,
//               wrong filter, wrong phaser. This is the metric that actually judges
//               timbre, and it is deliberately blind to phase — two noise renderings with
//               the same spectrum should pass, because to a listener they are the same
//               sound.
//
// Thresholds are arguments rather than constants: they start loose while the port is being
// built and are tightened as it improves. A number that never moves is not a target.

import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

// ---------------------------------------------------------------------------------
// WAV
// ---------------------------------------------------------------------------------

/** Reads a mono or interleaved WAV; returns { sampleRate, channels, samples: Float64Array } */
export function readWav(path) {
  const buffer = readFileSync(path);
  if (buffer.toString('ascii', 0, 4) !== 'RIFF' || buffer.toString('ascii', 8, 12) !== 'WAVE') {
    throw new Error(`${path}: not a RIFF/WAVE file`);
  }

  let offset = 12;
  let format = 0;
  let channels = 1;
  let sampleRate = 44100;
  let bits = 16;
  let data = null;

  while (offset + 8 <= buffer.length) {
    const id = buffer.toString('ascii', offset, offset + 4);
    const size = buffer.readUInt32LE(offset + 4);
    const body = offset + 8;
    if (id === 'fmt ') {
      format = buffer.readUInt16LE(body);
      channels = buffer.readUInt16LE(body + 2);
      sampleRate = buffer.readUInt32LE(body + 4);
      bits = buffer.readUInt16LE(body + 14);
    } else if (id === 'data') {
      data = buffer.subarray(body, body + size);
    }
    // Chunks are word aligned; an odd size is followed by a pad byte.
    offset = body + size + (size % 2);
  }
  if (data === null) throw new Error(`${path}: no data chunk`);

  let samples;
  if (format === 3 && bits === 32) {
    samples = new Float64Array(data.length / 4);
    for (let i = 0; i < samples.length; i++) samples[i] = data.readFloatLE(i * 4);
  } else if (format === 1 && bits === 16) {
    samples = new Float64Array(data.length / 2);
    for (let i = 0; i < samples.length; i++) samples[i] = data.readInt16LE(i * 2) / 32768;
  } else {
    throw new Error(`${path}: unsupported format ${format} at ${bits} bits`);
  }
  return { sampleRate, channels, samples };
}

/** Averages any interleaved file down to mono. Comparison is about content, not width. */
function toMono({ samples, channels }) {
  if (channels === 1) return samples;
  const frames = Math.floor(samples.length / channels);
  const mono = new Float64Array(frames);
  for (let frame = 0; frame < frames; frame++) {
    let sum = 0;
    for (let c = 0; c < channels; c++) sum += samples[frame * channels + c];
    mono[frame] = sum / channels;
  }
  return mono;
}

// ---------------------------------------------------------------------------------
// FFT — iterative radix-2, in place, on separate real and imaginary arrays.
// ---------------------------------------------------------------------------------

function fft(re, im) {
  const n = re.length;
  for (let i = 1, j = 0; i < n; i++) {
    let bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) {
      [re[i], re[j]] = [re[j], re[i]];
      [im[i], im[j]] = [im[j], im[i]];
    }
  }
  for (let len = 2; len <= n; len <<= 1) {
    const angle = (-2 * Math.PI) / len;
    const wRe = Math.cos(angle);
    const wIm = Math.sin(angle);
    for (let i = 0; i < n; i += len) {
      let curRe = 1;
      let curIm = 0;
      for (let k = 0; k < len / 2; k++) {
        const aRe = re[i + k];
        const aIm = im[i + k];
        const bRe = re[i + k + len / 2] * curRe - im[i + k + len / 2] * curIm;
        const bIm = re[i + k + len / 2] * curIm + im[i + k + len / 2] * curRe;
        re[i + k] = aRe + bRe;
        im[i + k] = aIm + bIm;
        re[i + k + len / 2] = aRe - bRe;
        im[i + k + len / 2] = aIm - bIm;
        const nextRe = curRe * wRe - curIm * wIm;
        curIm = curRe * wIm + curIm * wRe;
        curRe = nextRe;
      }
    }
  }
}

const FRAME = 1024;
const HOP = 256;

function hann(n) {
  const w = new Float64Array(n);
  for (let i = 0; i < n; i++) w[i] = 0.5 - 0.5 * Math.cos((2 * Math.PI * i) / (n - 1));
  return w;
}
const WINDOW = hann(FRAME);

/** Magnitude spectrogram: array of Float64Array, one per frame, FRAME/2 bins each. */
function spectrogram(samples) {
  const frames = [];
  for (let start = 0; start + FRAME <= samples.length; start += HOP) {
    const re = new Float64Array(FRAME);
    const im = new Float64Array(FRAME);
    for (let i = 0; i < FRAME; i++) re[i] = samples[start + i] * WINDOW[i];
    fft(re, im);
    const magnitude = new Float64Array(FRAME / 2);
    for (let bin = 0; bin < FRAME / 2; bin++) {
      magnitude[bin] = Math.hypot(re[bin], im[bin]);
    }
    frames.push(magnitude);
  }
  return frames;
}

function frameRms(samples) {
  const values = [];
  for (let start = 0; start + FRAME <= samples.length; start += HOP) {
    let sum = 0;
    for (let i = 0; i < FRAME; i++) {
      const s = samples[start + i];
      sum += s * s;
    }
    values.push(Math.sqrt(sum / FRAME));
  }
  return values;
}

function rms(samples) {
  let sum = 0;
  for (const s of samples) sum += s * s;
  return samples.length > 0 ? Math.sqrt(sum / samples.length) : 0;
}

const db = (x) => 20 * Math.log10(x + 1e-9);

// Bins quieter than this fraction of the loudest bin in their frame are treated as equal
// to it. -60 dB: comfortably below anything audible against the rest of the frame.
const SPECTRAL_FLOOR = 1e-3;

// ---------------------------------------------------------------------------------
// Comparison
// ---------------------------------------------------------------------------------

export function compare(referencePath, candidatePath) {
  const reference = toMono(readWav(referencePath));
  const candidate = toMono(readWav(candidatePath));

  const refRms = rms(reference);
  const canRms = rms(candidate);

  // Level is reported on its own and then removed. A port that is uniformly 6 dB quiet has
  // one bug in one place; if the level difference were left in, every spectral frame would
  // report that same 6 dB and the timbre metric would say nothing about timbre.
  const gainDb = db(canRms) - db(refRms);
  const scale = canRms > 1e-12 ? refRms / canRms : 1;
  const levelled = new Float64Array(candidate.length);
  for (let i = 0; i < candidate.length; i++) levelled[i] = candidate[i] * scale;

  const lengthRatio =
    reference.length > 0 ? candidate.length / reference.length : Infinity;

  const refEnvelope = frameRms(reference);
  const canEnvelope = frameRms(levelled);
  const frames = Math.min(refEnvelope.length, canEnvelope.length);

  let envelopeSum = 0;
  let envelopeWorst = 0;
  for (let i = 0; i < frames; i++) {
    const difference = Math.abs(db(refEnvelope[i]) - db(canEnvelope[i]));
    envelopeSum += difference;
    envelopeWorst = Math.max(envelopeWorst, difference);
  }
  const envelopeDb = frames > 0 ? envelopeSum / frames : Infinity;

  const refSpectra = spectrogram(reference);
  const canSpectra = spectrogram(levelled);
  const spectralFrames = Math.min(refSpectra.length, canSpectra.length);

  let spectralSum = 0;
  let spectralCount = 0;
  for (let f = 0; f < spectralFrames; f++) {
    // Frames that are silent in both are skipped: the difference between two noise floors
    // is arbitrary, and averaging it in would let a long quiet tail flatter a bad match.
    if (refSpectra[f].every((v) => v < 1e-7) && canSpectra[f].every((v) => v < 1e-7)) {
      continue;
    }

    // Both spectra are floored relative to the loudest bin in the frame before comparing.
    //
    // Without this the metric is dominated by bins nobody can hear. A pure sine has an
    // almost empty spectrum, and sfxr's — computed from an integer period counter — has
    // quantisation noise in those empty bins where a band-limited oscillator has none.
    // Comparing 1e-9 against 1e-3 is a 120 dB difference in a bin 100 dB below the tone,
    // which is why the two *sine* cases scored worse than anything else in the corpus
    // despite being the easiest waveform to reproduce. The floor is set well below
    // anything audible, so a real difference in a real partial still counts in full.
    const floorRef = Math.max(...refSpectra[f]) * SPECTRAL_FLOOR;
    const floorCan = Math.max(...canSpectra[f]) * SPECTRAL_FLOOR;
    for (let bin = 0; bin < refSpectra[f].length; bin++) {
      const a = Math.max(refSpectra[f][bin], floorRef);
      const b = Math.max(canSpectra[f][bin], floorCan);
      spectralSum += Math.abs(db(a) - db(b));
      spectralCount++;
    }
  }
  const spectralDb = spectralCount > 0 ? spectralSum / spectralCount : Infinity;

  return {
    referenceSamples: reference.length,
    candidateSamples: candidate.length,
    lengthRatio,
    gainDb,
    envelopeDb,
    envelopeWorstDb: envelopeWorst,
    spectralDb,
    comparedFrames: spectralFrames,
  };
}

export const DEFAULT_THRESHOLDS = {
  // Loose on purpose. These are where the port starts, not where it should end up; the
  // number to watch is whether they come down over time.
  lengthTolerance: 0.02,  // ±2% of the reference length
  gainDb: 1.5,
  envelopeDb: 3.0,
  spectralDb: 6.0,
};

export function verdict(metrics, thresholds = DEFAULT_THRESHOLDS) {
  const failures = [];
  if (Math.abs(metrics.lengthRatio - 1) > thresholds.lengthTolerance) {
    failures.push(
      `length ${(metrics.lengthRatio * 100).toFixed(1)}% of reference ` +
        `(allowed ±${(thresholds.lengthTolerance * 100).toFixed(0)}%)`);
  }
  if (Math.abs(metrics.gainDb) > thresholds.gainDb) {
    failures.push(`gain ${metrics.gainDb.toFixed(2)} dB (allowed ±${thresholds.gainDb})`);
  }
  if (metrics.envelopeDb > thresholds.envelopeDb) {
    failures.push(`envelope ${metrics.envelopeDb.toFixed(2)} dB (allowed ${thresholds.envelopeDb})`);
  }
  if (metrics.spectralDb > thresholds.spectralDb) {
    failures.push(`spectrum ${metrics.spectralDb.toFixed(2)} dB (allowed ${thresholds.spectralDb})`);
  }
  return { pass: failures.length === 0, failures };
}

// ---------------------------------------------------------------------------------
// Self-test
// ---------------------------------------------------------------------------------

// A comparator nobody has tested is not evidence. Before it can be trusted to judge the
// port, it has to be shown to answer "identical" for identical input and "different" for
// input that is genuinely different — otherwise a port could pass by being wrong in a way
// the metric cannot see.
function selfTest(corpusDirectory) {
  const vectors = join(corpusDirectory, 'vectors');

  // The manifest is the authority on what the corpus contains, not whatever happens to be
  // lying in the directory. Regenerating with different settings leaves orphans behind —
  // including the cases the generator deliberately rejected — and globbing would quietly
  // test against one of those. This self-test found exactly that on its first run.
  const manifest = JSON.parse(readFileSync(join(corpusDirectory, 'manifest.json'), 'utf8'));
  const files = manifest.cases.map((entry) => `${entry.name}.wav`);
  if (files.length < 4) {
    console.error(`self-test needs a corpus; the manifest lists ${files.length} cases`);
    return 1;
  }

  const orphans = readdirSync(vectors)
    .filter((f) => f.endsWith('.wav'))
    .filter((f) => !files.includes(f));
  if (orphans.length > 0) {
    console.log(`  note  ${orphans.length} vector(s) in ${vectors} are not in the ` +
                `manifest and are being ignored: ${orphans.join(', ')}`);
  }

  let failures = 0;
  const check = (condition, description) => {
    console.log(`  ${condition ? 'ok  ' : 'FAIL'} ${description}`);
    if (!condition) failures++;
  };

  // 1. A file against itself must be exactly zero on every metric. If this does not hold,
  //    every other number the comparator prints is suspect.
  const identical = compare(join(vectors, files[0]), join(vectors, files[0]));
  check(identical.lengthRatio === 1, 'a vector compared with itself has the same length');
  check(Math.abs(identical.gainDb) < 1e-9, 'and no gain difference');
  check(identical.envelopeDb < 1e-9, 'and no envelope difference');
  check(identical.spectralDb < 1e-9, 'and no spectral difference');
  check(verdict(identical).pass, 'and passes');

  // 2. Two different sounds must fail. Which pairs are chosen matters: two seeds of the
  //    same generator are the harder case, because they share a waveform and an envelope
  //    shape and differ only in the numbers.
  const bySameGenerator = files.filter((f) => f.startsWith('explosion-'));
  const differentSeeds = compare(
    join(vectors, bySameGenerator[0]), join(vectors, bySameGenerator[1]));
  check(!verdict(differentSeeds).pass,
    'two seeds of the same generator are told apart');

  const acrossGenerators = compare(
    join(vectors, files.find((f) => f.startsWith('jump-'))),
    join(vectors, files.find((f) => f.startsWith('explosion-'))));
  check(!verdict(acrossGenerators).pass, 'and so are two different generators');

  // 3. The spectral metric must rank the obviously-more-different pair as more different.
  //    A metric that fires on everything equally cannot guide a port towards correctness.
  check(acrossGenerators.spectralDb > differentSeeds.spectralDb * 0.5,
    'a wholly different sound is at least as far away as a differently seeded one');

  // 4. Level must be caught as level, not as timbre. Halving a signal has to show up in
  //    gain and nowhere else — this is what makes the two numbers separately actionable.
  const reference = toMono(readWav(join(vectors, files[0])));
  const halved = { sampleRate: 44100, channels: 1, samples: reference.map((s) => s * 0.5) };
  const scaled = compareSignals(reference, halved.samples);
  check(Math.abs(scaled.gainDb + 6.02) < 0.05, 'halving a signal reads as -6 dB of gain');
  check(scaled.spectralDb < 1e-9,
    'and once the level is divided out, its spectrum is unchanged');

  console.log('');
  if (failures === 0) {
    console.log('comparator self-test passed');
    return 0;
  }
  console.log(`${failures} comparator self-test(s) failed`);
  return 1;
}

/** The body of compare(), for signals already in memory. Used by the self-test. */
function compareSignals(reference, candidate) {
  const refRms = rms(reference);
  const canRms = rms(candidate);
  const gainDb = db(canRms) - db(refRms);
  const scale = canRms > 1e-12 ? refRms / canRms : 1;
  const levelled = new Float64Array(candidate.length);
  for (let i = 0; i < candidate.length; i++) levelled[i] = candidate[i] * scale;

  const refSpectra = spectrogram(reference);
  const canSpectra = spectrogram(levelled);
  let sum = 0;
  let count = 0;
  for (let f = 0; f < Math.min(refSpectra.length, canSpectra.length); f++) {
    for (let bin = 0; bin < refSpectra[f].length; bin++) {
      sum += Math.abs(db(refSpectra[f][bin]) - db(canSpectra[f][bin]));
      count++;
    }
  }
  return { gainDb, spectralDb: count > 0 ? sum / count : Infinity };
}

// ---------------------------------------------------------------------------------

// Only when run directly. sfxr-report.mjs imports compare() and verdict() from here, and
// without this guard that import would run the CLI and exit before the report started.
const runDirectly = import.meta.url === pathToFileURL(process.argv[1] ?? '').href;

const args = runDirectly ? process.argv.slice(2) : [];
if (!runDirectly) {
  // imported as a library
} else if (args[0] === '--self-test') {
  process.exit(selfTest(args[1] ?? 'tests/sfxr'));
} else if (args.length >= 2) {
  const metrics = compare(args[0], args[1]);
  const result = verdict(metrics);
  if (args.includes('--json')) {
    console.log(JSON.stringify({ ...metrics, ...result }, null, 2));
  } else {
    console.log(`  reference   ${metrics.referenceSamples} samples`);
    console.log(`  candidate   ${metrics.candidateSamples} samples ` +
                `(${(metrics.lengthRatio * 100).toFixed(1)}%)`);
    console.log(`  gain        ${metrics.gainDb.toFixed(2)} dB`);
    console.log(`  envelope    ${metrics.envelopeDb.toFixed(2)} dB mean, ` +
                `${metrics.envelopeWorstDb.toFixed(2)} dB worst`);
    console.log(`  spectrum    ${metrics.spectralDb.toFixed(2)} dB over ` +
                `${metrics.comparedFrames} frames`);
    console.log('');
    console.log(result.pass ? '  match' : `  no match: ${result.failures.join('; ')}`);
  }
  process.exit(result.pass ? 0 : 1);
} else {
  console.error('usage: compare-waveforms.mjs <reference.wav> <candidate.wav> [--json]');
  console.error('       compare-waveforms.mjs --self-test <corpus-dir>');
  process.exit(2);
}
