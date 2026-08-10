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
// Stage 1 fidelity (the doc's plan: algorithms and envelopes first):
//   applied    — topology, ratio and fixed frequency modes, detune, output levels,
//                feedback (on the op the algorithm marks), rate/level envelopes onto
//                the ADSR, transpose
//   pending    — LFO, key scaling (rate and level), pitch envelope, velocity curves;
//                multi-op feedback loops (algorithms 4 and 6) fall back to
//                self-feedback on the loop's driving op
//   by ear     — the rate->seconds curve and the modulation index scale, pending a
//                vendored msfa oracle in the sfxr/Nuked pattern
// Every voice records what was dropped in its own metadata.

import { readFileSync, writeFileSync, readdirSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const source = join(root, 'tools', 'dx7', 'banks');
const target = join(root, 'examples', 'patches', 'dx7');

// msfa's FmCore::algorithms, verbatim. Byte layout: in-bus = (b>>4)&3, out-bus = b&3,
// 0x04 = add to the bus (out-bus 0 with add = a carrier), 0xc0 = the feedback op.
const ALGORITHMS = [
  [0xc1, 0x11, 0x11, 0x14, 0x01, 0x14], [0x01, 0x11, 0x11, 0x14, 0xc1, 0x14],
  [0xc1, 0x11, 0x14, 0x01, 0x11, 0x14], [0xc1, 0x11, 0x94, 0x01, 0x11, 0x14],
  [0xc1, 0x14, 0x01, 0x14, 0x01, 0x14], [0xc1, 0x94, 0x01, 0x14, 0x01, 0x14],
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
//   feedback  — the op the algorithm feeds back on itself
// ops[0] is OP6 and ops[5] is OP1, matching both msfa and the wire format.
function decodeAlgorithm(bytes) {
  const buses = { 1: [], 2: [] };
  const carriers = [];
  const edges = [];
  let feedback = 0;
  for (let index = 0; index < 6; ++index) {
    const op = 6 - index;
    const flags = bytes[index];
    const inBus = (flags >> 4) & 3;
    const outBus = flags & 3;
    const add = (flags & 0x04) !== 0;
    if ((flags & 0xc0) === 0xc0) feedback = op;
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
  return { edges, carriers, feedback };
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
      detune: ((bytes[at + 12] >> 3) & 0x0f) - 7,
      outputLevel: bytes[at + 14],
      fixed: (bytes[at + 15] & 0x01) !== 0,
      coarse: (bytes[at + 15] >> 1) & 0x1f,
      fine: bytes[at + 16],
    });
  }
  return {
    ops,
    algorithm: bytes[110] & 0x1f,
    feedbackLevel: bytes[111] & 0x07,
    transpose: bytes[117] - 24,
    name: String.fromCharCode(...bytes.subarray(118, 128))
      .replace(/[^\x20-\x7e]/g, ' ').trim(),
  };
}

// ---------------------------------------------------------------------------------
// Parameter mappings — the stage-1 approximations, each named and bounded.
// ---------------------------------------------------------------------------------

// DX7 levels run 0-99 on a roughly-constant-dB ladder; 99 is full scale.
const levelAmp = (level) => Math.pow(10, (-0.75 * (99 - level)) / 20);

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

// A full-scale DX7 modulator drives about 2 cycles of phase; scaled by output level.
const INDEX_FULL = 2.0;

// Feedback 1-7 on the chip's doubling ladder, the same shape OPL used.
const feedbackCycles = (fb) => (fb <= 0 ? 0 : Math.pow(2, fb - 1) / 32);

function envelopeParameters(op) {
  const [r1, r2, r3, r4] = op.rates;
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
  if ([4, 6].includes(voice.algorithm + 1) === false && topology.feedback === 0) {
    notes.push('no feedback op in algorithm decode');
  }
  if (voice.algorithm + 1 === 4 || voice.algorithm + 1 === 6) {
    notes.push('multi-op feedback loop approximated as self-feedback');
  }
  notes.push('LFO, key scaling, pitch envelope and velocity not applied');

  const nodes = [{ id: 'note', type: 'NoteInput',
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
        * levelAmp(op.outputLevel)).toFixed(5));
    }
    if (op.fixed) {
      oscParameters.frequency = Number(operatorRatio(op).toFixed(3));
      nodes.push({ id: `${id}_osc`, type: 'SineOscillator', parameters: oscParameters });
    } else {
      nodes.push({ id: `${id}_pitch`, type: 'Multiply',
        parameters: { factor: Number(operatorRatio(op).toFixed(5)) } });
      wire('note', 'frequency', `${id}_pitch`, 'a');
      nodes.push({ id: `${id}_osc`, type: 'SineOscillator', parameters: oscParameters });
      wire(`${id}_pitch`, 'out', `${id}_osc`, 'frequency');
    }
    nodes.push({ id: `${id}_env`, type: 'ADSR', parameters: envelopeParameters(op) });
    wire('note', 'gate', `${id}_env`, 'gate');
    nodes.push({ id: `${id}_vca`, type: 'Multiply', parameters: {} });
    wire(`${id}_osc`, 'out', `${id}_vca`, 'a');
    wire(`${id}_env`, 'out', `${id}_vca`, 'b');
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
      nodes.push({ id: gainId, type: 'Gain', parameters: {
        gain: Number((INDEX_FULL * levelAmp(fromOp.outputLevel)).toFixed(4)) } });
      wire(`op${from}_vca`, 'out', gainId, 'in');
      if (i === 0) {
        feed = gainId;
      } else {
        const addId = `op${op.op}_pm_sum_${i}`;
        nodes.push({ id: addId, type: 'Add', parameters: {} });
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
    carrierAmpSum += levelAmp(voice.ops.find((o) => o.op === c).outputLevel);
  }
  let mix = '';
  topology.carriers.forEach((c, i) => {
    const levelId = `op${c}_level`;
    const carrierOp = voice.ops.find((o) => o.op === c);
    nodes.push({ id: levelId, type: 'Gain', parameters: {
      gain: Number(levelAmp(carrierOp.outputLevel).toFixed(4)) } });
    wire(`op${c}_vca`, 'out', levelId, 'in');
    if (i === 0) {
      mix = levelId;
    } else {
      const addId = `carrier_sum_${i}`;
      nodes.push({ id: addId, type: 'Add', parameters: {} });
      wire(mix, 'out', addId, 'a');
      wire(levelId, 'out', addId, 'b');
      mix = addId;
    }
  });
  nodes.push({ id: 'out', type: 'StereoOutput', parameters: {
    level: Number((0.8 / Math.max(1, carrierAmpSum)).toFixed(4)) } });
  wire(mix, 'out', 'out', 'left');
  wire(mix, 'out', 'out', 'right');

  return {
    schema_version: 1,
    metadata: {
      name: voice.name || `Voice ${voiceIndex + 1}`,
      description: `${voice.name} — DX7 voice, algorithm ${voice.algorithm + 1}, `
        + `imported by tools/dx7-import.mjs from ${bankName}. `
        + `Approximated: ${notes.join('; ')}.`,
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

const OPERATOR_MODULE = {
  description: 'One DX7 operator: pitch ratio, sine, envelope, VCA.',
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
    if (byId.has(`op${op}_osc`) && byId.has(`op${op}_env`) && byId.has(`op${op}_vca`)) {
      clusters.push(op);
    }
  }
  if (clusters.length === 0) return null;

  const inner = new Set();
  for (const op of clusters) {
    for (const part of ['pitch', 'osc', 'env', 'vca']) inner.add(`op${op}_${part}`);
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
      nodes.push({ id: `op${op}`, type: 'module', module: 'operator', parameters });
      continue;
    }
    if (inner.has(node.id)) continue;
    nodes.push(node);
  }

  const port = (id, fallbackPort) => {
    const m = /^op(\d)_(pitch|osc|env|vca)$/.exec(id);
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
      const name = to.part === 'pitch' ? 'note'
        : to.part === 'env' ? 'gate' : 'pm';
      rewritten.to = { node: to.instance, port: name };
    }
    connections.push(rewritten);
  }

  return {
    schema_version: 2,
    metadata: flat.metadata,
    modules: { operator: OPERATOR_MODULE },
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
    const patch = buildPatch(voice, bank, index);
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
