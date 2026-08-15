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
// Now representable and applied: waveforms 0-3 (the sine's shape enum was built to be
// exactly this set), operator feedback (2^(fb-1)/32 cycles, the chip's own ladder up
// to 4pi), and rate key-scaling via constants measured at A3. The envelope clock is
// MEASURED against the Nuked-OPL3 oracle by tools/opl2-calibrate.mjs, not fitted.
//
// Approximations that remain, recorded per-patch in the metadata so nobody has to
// diff bytes to learn them: the modulation index scale (INDEX_FULL) is still by ear;
// feedback is constant-strength where the chip envelopes it; KSL and the
// tremolo/vibrato flags are ignored; non-sustaining envelopes are reshaped onto the
// ADSR. tools/opl2-compare.mjs holds every import to the oracle's pitch and presence
// in ctest, which is what keeps this list honest.

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

// OPL envelope rates double in speed per step: t = k * 2^(15 - rate). The k values are
// MEASURED, by tools/opl2-calibrate.mjs against the Nuked-OPL3 oracle at A3 — attack
// read at 90% of peak, falls at -20 dB — and they convicted the previous fitted
// guesses of being fourteen times too slow, which is why half the slow-attack bank
// failed the oracle comparison: a trumpet that takes two seconds to speak is not a
// trumpet. KSR gets its own measured constants rather than a reasoned-about rate
// offset, because the chip derives the offset from pitch and A3 is where the
// comparison is played.
const ATTACK_K = 1.367e-4;
const ATTACK_KSR_K = 4.883e-5;
const FALL_K = 4.687e-4;
const FALL_KSR_K = 1.563e-4;

const attackSeconds = (rate, ksr) =>
  rate >= 15 ? 0
    : Math.min(10, (ksr ? ATTACK_KSR_K : ATTACK_K) * Math.pow(2, 15 - rate));
const fallSeconds = (rate, ksr) =>
  rate <= 0 ? 10
    : Math.min(10, (ksr ? FALL_KSR_K : FALL_K) * Math.pow(2, 15 - rate));

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
    // Masked to 2 bits, because that is what the chip does: OPL2's wave select is
    // 0-3, and an SBI byte saying 4 plays as sine on real hardware (the first parse
    // here kept 3 bits and dutifully reported "waveform 4 rendered as sine" about an
    // instrument that was sine all along).
    wave: wave & 0x03,
  });
  return {
    name,
    modulator: op(r[0], r[2], r[4], r[6], r[8]),
    carrier: op(r[1], r[3], r[5], r[7], r[9]),
    feedback: (r[10] >> 1) & 0x07,
    additive: (r[10] & 0x01) !== 0,
  };
}

// OPL feedback strength doubles per step; the strongest setting is 4pi radians of
// self-modulation = 2 cycles, which is exactly the sine's parameter ceiling.
const feedbackCycles = (fb) => (fb <= 0 ? 0 : Math.pow(2, fb - 1) / 32);

function fidelityNotes(voice) {
  const notes = [];
  if (voice.feedback > 0) {
    // Representable now, with one honest gap: the chip feeds back the operator's
    // *enveloped* output, while the sine's feedback parameter is constant — so a
    // decaying note keeps its bite slightly longer than the hardware would.
    notes.push(`feedback ${voice.feedback} applied without envelope scaling`);
  }
  for (const [role, op] of [['modulator', voice.modulator], ['carrier', voice.carrier]]) {
    if (op.keyScaleLevel > 0) notes.push(`${role} level key-scaling ignored`);
    if (op.tremolo || op.vibrato) notes.push(`${role} tremolo/vibrato flag ignored`);
    if (!op.sustaining) notes.push(`${role} percussive envelope approximated`);
  }
  return notes;
}

// An operator's oscillator settings: its waveform bend, and — for the modulator —
// the voice's feedback. The shape numbers map one to one onto the sine's shape enum,
// which was built to be exactly this set.
function operatorParameters(op, feedbackCyclesEffective) {
  const parameters = {};
  if (op.wave !== 0) parameters.shape = op.wave;
  if (feedbackCyclesEffective > 0) {
    parameters.feedback = Number(feedbackCyclesEffective.toFixed(5));
  }
  return parameters;
}

function envelopeParameters(op) {
  // The measured constant is "seconds per 20 dB of fall", so each stage's time is that
  // scaled by how many dB the stage actually covers: decay runs from peak to the
  // sustain level, release from there to the chip's -93 dB floor.
  const slDb = op.sustain >= 15 ? 93 : 3 * op.sustain;
  const per20 = (rate) => fallSeconds(rate, op.keyScaleRate);
  const decayStage = per20(op.decay) * Math.max(slDb, 2) / 20;
  const releaseStage = per20(op.release) * Math.max(93 - slDb, 6) / 20;

  if (op.sustaining) {
    return {
      attack: Number(attackSeconds(op.attack, op.keyScaleRate).toFixed(4)),
      decay: Number(Math.min(10, decayStage).toFixed(4)),
      sustain: Number(sustainLevel(op.sustain).toFixed(4)),
      release: Number(Math.min(10, releaseStage).toFixed(4)),
    };
  }

  // Non-sustaining: the chip falls through the sustain level at the decay rate and
  // keeps falling at the *release* rate while the key is still down. One decay knob
  // has to carry both slopes, so it gets their summed time — the first version ran
  // the whole fall at decay speed, and once the clock was calibrated (fast), every
  // percussive voice was silent before the comparison window opened. Marimbas died
  // of accuracy.
  return {
    attack: Number(attackSeconds(op.attack, op.keyScaleRate).toFixed(4)),
    decay: Number(Math.min(10, decayStage + releaseStage).toFixed(4)),
    sustain: 0,
    release: Number(Math.min(10, per20(op.release) * 93 / 20).toFixed(4)),
  };
}

function buildPatch(voice, sourceFile) {
  const notes = fidelityNotes(voice);
  const description =
    `${voice.name} — Freedoom's OPL2 GENMIDI voice, imported by tools/opl2-import.mjs.`
    + (notes.length > 0 ? ` Approximated: ${notes.join('; ')}.` : '');

  // The chip feeds back the operator's output *after* total-level attenuation — the
  // feedback tap in Nuked reads the enveloped, attenuated sample. The sine's feedback
  // parameter self-modulates at full oscillator amplitude, so the register value has
  // to be scaled by the modulator's TL here or a quiet modulator feeds back at full
  // strength. Unscaled, synth-bass-1 (feedback 5, TL 14) drove itself into a DC-shifted
  // equilibrium — mean -0.13, a wave leaning on its own tail — which is how every
  // strong-feedback bass in the bank came back "pitchless": DC autocorrelates equally
  // well at every lag, and the measurement dutifully returned its own search bound.
  const effectiveFeedback =
    feedbackCycles(voice.feedback) * attenuation(voice.modulator.totalLevel);

  const nodes = [
    { id: 'note', type: 'Input', host: 'note', name: 'Keyboard', parameters: {} },
    // An additive voice has two operators that are both heard; an FM one has a
    // modulator that is only felt. Naming them for the job they do in *this* voice
    // beats naming them for their slot on the chip.
    { id: 'mod_pitch', type: 'Multiply',
      name: voice.additive ? 'Operator 1' : 'Modulator',
      parameters: { factor: voice.modulator.multiple } },
    { id: 'car_pitch', type: 'Multiply',
      name: voice.additive ? 'Operator 2' : 'Carrier',
      parameters: { factor: voice.carrier.multiple } },
    { id: 'mod', type: 'SineOscillator', parameters: operatorParameters(
      voice.modulator, effectiveFeedback) },
    { id: 'mod_env', type: 'ADSR', parameters: envelopeParameters(voice.modulator) },
    { id: 'mod_vca', type: 'Multiply', parameters: {} },
    { id: 'car', type: 'SineOscillator', parameters: operatorParameters(voice.carrier, 0) },
    { id: 'car_env', type: 'ADSR', parameters: envelopeParameters(voice.carrier) },
    { id: 'car_vca', type: 'Multiply', parameters: {} },
    // Additive voices are two full operators summed, so they get half the headroom —
    // the drawbar organ clipped at exactly 1.0 before this, which is how it was found.
    { id: 'out', type: 'Output', host: 'stereo',
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
    nodes.push({ id: 'mod_level', type: 'Gain', name: 'Operator 1 level',
      parameters: { gain: Number(attenuation(voice.modulator.totalLevel).toFixed(4)) } });
    nodes.push({ id: 'car_level', type: 'Gain', name: 'Operator 2 level',
      parameters: { gain: Number(attenuation(voice.carrier.totalLevel).toFixed(4)) } });
    nodes.push({ id: 'sum', type: 'Add', name: 'Mix', parameters: {} });
    connections.push(wire('mod_vca', 'out', 'mod_level', 'in'));
    connections.push(wire('car_vca', 'out', 'car_level', 'in'));
    connections.push(wire('mod_level', 'out', 'sum', 'a'));
    connections.push(wire('car_level', 'out', 'sum', 'b'));
    connections.push(wire('sum', 'out', 'out', 'left'));
    connections.push(wire('sum', 'out', 'out', 'right'));
  } else {
    // The FM proper: the modulator's level is a modulation index into the carrier's pm.
    nodes.push({ id: 'index', type: 'Gain', name: 'Modulator → Carrier',
      parameters: { gain: Number(
        (INDEX_FULL * attenuation(voice.modulator.totalLevel)).toFixed(4)) } });
    nodes.push({ id: 'car_level', type: 'Gain', name: 'Carrier level',
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

// ---------------------------------------------------------------------------------
// Modular form — stage 4 of docs/modules-design.md, the OPL2 half.
//
// Same shape as the DX7 importer's: modularize() factors the flat patch, replacing
// each operator cluster (X_pitch, X, X_env, X_vca for X in mod/car) with an instance
// of an "operator" module. The module exports everything an OPL operator varies —
// ratio, waveform shape, feedback, the four envelope times — and --modular-check
// proves the factoring with rendered bytes across all 128 instruments.
// ---------------------------------------------------------------------------------

// Named for the chip: see the matching note in dx7-import.mjs. Two operators here
// mean something different from six there, and one name for both would have been a
// collision waiting for the first document that held one of each.
const OPERATOR_MODULE_NAME = 'opl2_operator';

const OPERATOR_MODULE = {
  description: 'One OPL2 operator: pitch ratio, shaped sine, envelope, VCA.',
  nodes: [
    { id: 'pitch', type: 'Multiply', parameters: { factor: 1 } },
    { id: 'osc', type: 'SineOscillator', parameters: {} },
    { id: 'env', type: 'ADSR', parameters: {} },
    { id: 'vca', type: 'Multiply', parameters: {} },
  ],
  connections: [
    { from: { node: 'pitch', port: 'out' }, to: { node: 'osc', port: 'frequency' } },
    { from: { node: 'osc', port: 'out' }, to: { node: 'vca', port: 'a' } },
    { from: { node: 'env', port: 'out' }, to: { node: 'vca', port: 'b' } },
  ],
  inputs: [
    { name: 'note', node: 'pitch', port: 'a' },
    { name: 'gate', node: 'env', port: 'gate' },
    { name: 'pm', node: 'osc', port: 'pm' },
  ],
  outputs: [{ name: 'out', node: 'vca', port: 'out' }],
  parameters: [
    { name: 'ratio', node: 'pitch', parameter: 'factor' },
    { name: 'shape', node: 'osc', parameter: 'shape' },
    { name: 'feedback', node: 'osc', parameter: 'feedback' },
    { name: 'attack', node: 'env', parameter: 'attack' },
    { name: 'decay', node: 'env', parameter: 'decay' },
    { name: 'sustain', node: 'env', parameter: 'sustain' },
    { name: 'release', node: 'env', parameter: 'release' },
  ],
};

function modularize(flat) {
  const byId = new Map(flat.nodes.map((n) => [n.id, n]));
  const clusters = ['mod', 'car'].filter((x) =>
    byId.has(`${x}_pitch`) && byId.has(x) && byId.has(`${x}_env`) && byId.has(`${x}_vca`));
  if (clusters.length === 0) return null;

  const inner = new Set();
  for (const x of clusters) {
    for (const id of [`${x}_pitch`, x, `${x}_env`, `${x}_vca`]) inner.add(id);
  }

  const nodes = [];
  for (const node of flat.nodes) {
    const cluster = clusters.find((x) => node.id === `${x}_pitch`);
    if (cluster !== undefined) {
      const osc = byId.get(cluster);
      const env = byId.get(`${cluster}_env`);
      const parameters = {
        ratio: node.parameters.factor,
        attack: env.parameters.attack,
        decay: env.parameters.decay,
        sustain: env.parameters.sustain,
        release: env.parameters.release,
      };
      if (osc.parameters.shape !== undefined) parameters.shape = osc.parameters.shape;
      if (osc.parameters.feedback !== undefined) {
        parameters.feedback = osc.parameters.feedback;
      }
      nodes.push({ id: cluster, type: 'module', module: OPERATOR_MODULE_NAME,
        name: node.name, parameters });
      continue;
    }
    if (inner.has(node.id)) continue;
    nodes.push(node);
  }

  const owner = (id) => {
    for (const x of clusters) {
      if (id === `${x}_pitch` || id === x || id === `${x}_env` || id === `${x}_vca`) {
        return { instance: x, part: id === x ? 'osc' : id.slice(x.length + 1) };
      }
    }
    return null;
  };
  const connections = [];
  for (const connection of flat.connections) {
    const from = owner(connection.from.node);
    const to = owner(connection.to.node);
    if (from !== null && to !== null && from.instance === to.instance) continue;
    const rewritten = { from: { ...connection.from }, to: { ...connection.to } };
    if (from !== null) rewritten.from = { node: from.instance, port: 'out' };
    if (to !== null) {
      const port = to.part === 'pitch' ? 'note' : to.part === 'env' ? 'gate' : 'pm';
      rewritten.to = { node: to.instance, port };
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

// --modular-check: every instrument built flat and factored modular, both rendered,
// byte-identical or bust. The same guarantee the DX7 importer carries.
if (process.argv.includes('--modular-check')) {
  const { execFileSync } = await import('node:child_process');
  const { mkdtempSync } = await import('node:fs');
  const { tmpdir } = await import('node:os');
  const scratch = mkdtempSync(join(tmpdir(), 'opl2-modular-'));
  const bin = join(root, 'build', 'bin');
  let differing = 0;
  let factored = 0;
  const newline = String.fromCharCode(10);
  for (const file of readdirSync(source).filter((f) => f.endsWith('.sbi')).sort()) {
    const voice = parseSbi(readFileSync(join(source, file)), file);
    const flat = buildPatch(voice, file);
    const modular = modularize(flat);
    if (modular === null) continue;
    factored += 1;
    const flatPath = join(scratch, `${slug(voice.name)}-flat.json`);
    const modularPath = join(scratch, `${slug(voice.name)}-mod.json`);
    writeFileSync(flatPath, JSON.stringify(flat) + newline);
    writeFileSync(modularPath, JSON.stringify(modular) + newline);
    const flatWav = join(scratch, `${slug(voice.name)}-flat.wav`);
    const modularWav = join(scratch, `${slug(voice.name)}-mod.wav`);
    execFileSync(join(bin, 'sg-render'), [flatPath, flatWav,
      '--seconds', '1', '--notes', '57', '--gate', '0.7', '--quiet']);
    execFileSync(join(bin, 'sg-render'), [modularPath, modularWav,
      '--seconds', '1', '--notes', '57', '--gate', '0.7', '--quiet']);
    if (!readFileSync(flatWav).equals(readFileSync(modularWav))) {
      console.error(`  differs: ${voice.name}`);
      differing += 1;
    }
  }
  if (differing > 0 || factored === 0) {
    console.error(`${differing} instrument(s) render differently modular vs flat `
      + `(${factored} factored).`);
    process.exit(1);
  }
  console.log(`All ${factored} instruments render byte-identical audio, modular and flat.`);
  process.exit(0);
}

const check = process.argv.includes('--check');
let differences = 0;
mkdirSync(target, { recursive: true });

const files = readdirSync(source).filter((f) => f.endsWith('.sbi')).sort();
for (const file of files) {
  const voice = parseSbi(readFileSync(join(source, file)), file);
  // The importer emits what it knows: two operators as two instances of one module.
  const flat = buildPatch(voice, file);
  const patch = modularize(flat) ?? flat;
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
