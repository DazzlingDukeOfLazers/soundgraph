#!/usr/bin/env node
// Rebuilds examples/patches/fm/ from the vendored Freedoom OPL2 instruments.
//
// Same discipline as game-sounds.mjs: the committed patches are generated, this file is
// the recipe, and --check fails when the two stop agreeing. The source instruments are
// SBI files vendored under tools/opl2/instruments/ from the Freedoom project (BSD
// licence alongside them), whose GENMIDI bank is built from original, freely-licensed
// instruments — the reason OPL2 went first in docs/fm-import-sources.md.
//
//   node tools/opl2-import.mjs [--check]
//
// What a faithful OPL2 voice needs and what this mapping does about it:
//
//   linear phase modulation   -> the oscillators' pm input, added for exactly this
//   two operators             -> two SineOscillators, modulator into the carrier's pm
//   multiple (0.5x..15x)      -> a Multiply on the note frequency per operator
//   total level (0.75dB/step) -> Gain, 10^(-0.75*TL/20)
//   ADSR rates                -> ADSR times via the approximation below
//   additive connection       -> both operators through their envelopes into an Add
//
// Approximations, all recorded per-patch in the metadata so nobody has to diff bytes to
// learn them:
//
//   rate -> time is a documented curve, not the chip's envelope generator. OPL rates
//   double in speed per step; the constants below are fitted to the published timings,
//   and the day tools/ grows a Nuked-OPL3 oracle (the plan of record), these become
//   measured instead of fitted.
//
//   the modulation index scale (INDEX_FULL) is chosen by ear pending that oracle.
//
//   waveforms 1..3 (half/abs/quarter sine), operator feedback, key scaling and
//   vibrato/tremolo flags are not representable yet. Instruments that use them import
//   with a fidelity note. Feedback and the bent waveforms are the two that matter most
//   and both are on the list in docs/fm-import-sources.md.

import { readFileSync, writeFileSync, readdirSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const source = join(root, 'tools', 'opl2', 'instruments');
const target = join(root, 'examples', 'patches', 'fm');

// OPL2's frequency-multiple table. Not a straight nibble: 0 halves, and the top of the
// table repeats values because the chip has no 11x, 13x or 14x.
const MULTIPLE = [0.5, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 10, 12, 12, 15, 15];

// A modulator at total level 0 drives the carrier this many cycles of phase. A DX7 at
// full depth is about 2; OPL voices are shallower, and this value keeps the brightest
// Freedoom instruments rich without buzzing. By ear, pending the oracle.
const INDEX_FULL = 0.85;

const attenuation = (level) => Math.pow(10, (-0.75 * level) / 20);

// OPL envelope rates double in speed per step. Zero means "never" for an attack and
// "hangs forever" for a release; both clamp to the ADSR's 10s ceiling.
const attackSeconds = (rate) =>
  rate >= 15 ? 0 : Math.min(10, 0.002 * Math.pow(2, 15 - rate));
const fallSeconds = (rate) =>
  rate <= 0 ? 10 : Math.min(10, 0.006 * Math.pow(2, 15 - rate));

// Sustain level is attenuation in 3dB steps; 15 is the chip's "all the way down".
const sustainLevel = (level) => (level >= 15 ? 0 : Math.pow(10, (-3 * level) / 20));

function parseSbi(bytes, file) {
  if (bytes.length < 51 || bytes.toString('latin1', 0, 4) !== 'SBI\x1a') {
    throw new Error(`${file} is not an SBI instrument`);
  }
  const name = bytes.toString('latin1', 4, 36).replace(/\0.*$/, '').trim();
  const r = bytes.subarray(36);
  const op = (character, level, attackDecay, sustainRelease, wave) => ({
    multiple: MULTIPLE[character & 0x0f],
    sustaining: (character & 0x20) !== 0,
    tremolo: (character & 0x80) !== 0,
    vibrato: (character & 0x40) !== 0,
    keyScaleRate: (character & 0x10) !== 0,
    keyScaleLevel: level >> 6,
    totalLevel: level & 0x3f,
    attack: attackDecay >> 4,
    decay: attackDecay & 0x0f,
    sustain: sustainRelease >> 4,
    release: sustainRelease & 0x0f,
    wave: wave & 0x07,
  });
  return {
    name,
    modulator: op(r[0], r[2], r[4], r[6], r[8]),
    carrier: op(r[1], r[3], r[5], r[7], r[9]),
    feedback: (r[10] >> 1) & 0x07,
    additive: (r[10] & 0x01) !== 0,
  };
}

function fidelityNotes(voice) {
  const notes = [];
  if (voice.feedback > 0) {
    notes.push(`operator feedback ${voice.feedback} not applied`);
  }
  for (const [role, op] of [['modulator', voice.modulator], ['carrier', voice.carrier]]) {
    if (op.wave !== 0) notes.push(`${role} waveform ${op.wave} rendered as sine`);
    if (op.keyScaleLevel > 0 || op.keyScaleRate) notes.push(`${role} key scaling ignored`);
    if (op.tremolo || op.vibrato) notes.push(`${role} tremolo/vibrato flag ignored`);
    if (!op.sustaining) notes.push(`${role} percussive envelope approximated`);
  }
  return notes;
}

function envelopeParameters(op) {
  // A non-sustaining OPL envelope decays through its sustain level to silence while the
  // key is still down. The nearest shape this ADSR makes is sustain-at-zero with the
  // decay carrying the fall; the release keeps its own rate for early key-ups.
  return {
    attack: Number(attackSeconds(op.attack).toFixed(4)),
    decay: Number(fallSeconds(op.decay).toFixed(4)),
    sustain: op.sustaining ? Number(sustainLevel(op.sustain).toFixed(4)) : 0,
    release: Number(fallSeconds(op.release).toFixed(4)),
  };
}

function buildPatch(voice, sourceFile) {
  const notes = fidelityNotes(voice);
  const description =
    `${voice.name} — Freedoom's OPL2 GENMIDI voice, imported by tools/opl2-import.mjs.`
    + (notes.length > 0 ? ` Approximated: ${notes.join('; ')}.` : '');

  const nodes = [
    { id: 'note', type: 'NoteInput', parameters: {} },
    { id: 'mod_pitch', type: 'Multiply',
      parameters: { factor: voice.modulator.multiple } },
    { id: 'car_pitch', type: 'Multiply',
      parameters: { factor: voice.carrier.multiple } },
    { id: 'mod', type: 'SineOscillator', parameters: {} },
    { id: 'mod_env', type: 'ADSR', parameters: envelopeParameters(voice.modulator) },
    { id: 'mod_vca', type: 'Multiply', parameters: {} },
    { id: 'car', type: 'SineOscillator', parameters: {} },
    { id: 'car_env', type: 'ADSR', parameters: envelopeParameters(voice.carrier) },
    { id: 'car_vca', type: 'Multiply', parameters: {} },
    // Additive voices are two full operators summed, so they get half the headroom —
    // the drawbar organ clipped at exactly 1.0 before this, which is how it was found.
    { id: 'out', type: 'StereoOutput',
      parameters: { level: voice.additive ? 0.4 : 0.8 } },
  ];

  const wire = (fromNode, fromPort, toNode, toPort) => ({
    from: { node: fromNode, port: fromPort },
    to: { node: toNode, port: toPort },
  });

  const connections = [
    wire('note', 'frequency', 'mod_pitch', 'a'),
    wire('note', 'frequency', 'car_pitch', 'a'),
    wire('mod_pitch', 'out', 'mod', 'frequency'),
    wire('car_pitch', 'out', 'car', 'frequency'),
    wire('note', 'gate', 'mod_env', 'gate'),
    wire('note', 'gate', 'car_env', 'gate'),
    wire('mod', 'out', 'mod_vca', 'a'),
    wire('mod_env', 'out', 'mod_vca', 'b'),
    wire('car', 'out', 'car_vca', 'a'),
    wire('car_env', 'out', 'car_vca', 'b'),
  ];

  if (voice.additive) {
    // Both operators are voices in their own right; they meet in an Add.
    nodes.push({ id: 'mod_level', type: 'Gain',
      parameters: { gain: Number(attenuation(voice.modulator.totalLevel).toFixed(4)) } });
    nodes.push({ id: 'car_level', type: 'Gain',
      parameters: { gain: Number(attenuation(voice.carrier.totalLevel).toFixed(4)) } });
    nodes.push({ id: 'sum', type: 'Add', parameters: {} });
    connections.push(wire('mod_vca', 'out', 'mod_level', 'in'));
    connections.push(wire('car_vca', 'out', 'car_level', 'in'));
    connections.push(wire('mod_level', 'out', 'sum', 'a'));
    connections.push(wire('car_level', 'out', 'sum', 'b'));
    connections.push(wire('sum', 'out', 'out', 'left'));
    connections.push(wire('sum', 'out', 'out', 'right'));
  } else {
    // The FM proper: the modulator's level is a modulation index into the carrier's pm.
    nodes.push({ id: 'index', type: 'Gain',
      parameters: { gain: Number(
        (INDEX_FULL * attenuation(voice.modulator.totalLevel)).toFixed(4)) } });
    nodes.push({ id: 'car_level', type: 'Gain',
      parameters: { gain: Number(attenuation(voice.carrier.totalLevel).toFixed(4)) } });
    connections.push(wire('mod_vca', 'out', 'index', 'in'));
    connections.push(wire('index', 'out', 'car', 'pm'));
    connections.push(wire('car_vca', 'out', 'car_level', 'in'));
    connections.push(wire('car_level', 'out', 'out', 'left'));
    connections.push(wire('car_level', 'out', 'out', 'right'));
  }

  return {
    schema_version: 1,
    metadata: {
      name: voice.name,
      description,
      author: 'Freedoom contributors (instrument), SoundGraph opl2-import (mapping)',
      tags: ['fm', 'opl2', 'imported'],
      source: `freedoom/lumps/genmidi/instruments/${sourceFile}`,
    },
    nodes,
    connections,
  };
}

const slug = (name) => name.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');

const check = process.argv.includes('--check');
let differences = 0;
mkdirSync(target, { recursive: true });

const files = readdirSync(source).filter((f) => f.endsWith('.sbi')).sort();
for (const file of files) {
  const voice = parseSbi(readFileSync(join(source, file)), file);
  const patch = buildPatch(voice, file);
  const text = JSON.stringify(patch, null, 2) + '\n';
  const out = join(target, `${slug(voice.name)}.json`);

  if (check) {
    let committed = '';
    try { committed = readFileSync(out, 'utf8'); } catch { /* missing counts as different */ }
    if (committed !== text) {
      console.error(`  differs: ${out}`);
      differences += 1;
    }
  } else {
    writeFileSync(out, text);
    console.log(`  wrote ${slug(voice.name)}.json  (${voice.name}${
      voice.additive ? ', additive' : ''})`);
  }
}

if (check) {
  if (differences > 0) {
    console.error(`${differences} imported patch(es) differ from the importer's output.`);
    process.exit(1);
  }
  console.log(`All ${files.length} imported OPL2 patches match the importer.`);
} else {
  console.log(`${files.length} instruments imported into examples/patches/fm/.`);
}
