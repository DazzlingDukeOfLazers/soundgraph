#!/usr/bin/env node
// Builds examples/patches/nodes/ — one small playable patch per node type.
//
// A node's description says what it is for. A demo shows it. Every one of these is the
// smallest patch where you can hear that node and hear what happens when you change it:
// open it, press a key, drag the parameter the comment points at.
//
// They are generated rather than hand-written for the reason the game sounds are: a
// directory of near-identical JSON files drifts the moment anything about the format
// changes, and regenerating twenty-three files by hand is how a patch ends up wired to a
// port that no longer exists. What is hand-written is the table below — the wiring and
// the choice of what to demonstrate, which is the part that needs judgement.
//
//   node tools/node-demos.mjs [--check]
//
// --check rebuilds into memory and fails if the committed files differ; that runs in the
// test suite, alongside a test that every registered node type has an entry here at all.

import { execFileSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const target = join(root, 'examples', 'patches', 'nodes');

// Grid spacing, matching the mapper, so a generated patch opens laid out rather than
// piled at the origin.
//
// 560 rather than 400, and deliberately not "the editor's column pitch" any more. The
// editor's arrange takes whichever is larger of that pitch and the widest node in the
// column plus a gutter, so it spreads to fit whatever it is laying out; a generator
// writing coordinates once has no such feedback, and 400 stopped clearing a node when the
// node grew. Stored positions are honoured rather than re-laid, so the result was a saved
// patch opening with its panels drawn through each other. Keep this a whole number of
// 40px grid cells, and keep it in step with kColumnPitch in tools/sfxr-ref/to_patch.cpp.
const COLUMN = 560;
// And 360 rather than 200, for the same reason on the other axis. Both are whole numbers
// of 40px grid cells chosen to clear the largest node the editor draws, measured rather
// than guessed: 429 wide and 329 tall across the shipped corpus.
const LANE = 360;

const node = (id, type, parameters = {}, column = 0, lane = 0) =>
  ({ id, type, parameters, column, lane });
// A graph's edge, written as a node. The demos are keyed by registry type — the entry
// showing NoteInput is still called NoteInput — but the node inside the patch is spelled
// the way the corpus spells it, because a demo that teaches an older spelling teaches the
// older spelling. See docs/modules-design.md.
const seam = (id, type, host, parameters = {}, column = 0, lane = 0) =>
  ({ id, type, host, parameters, column, lane });
const wire = (fromNode, fromPort, toNode, toPort) =>
  ({ from: { node: fromNode, port: fromPort }, to: { node: toNode, port: toPort } });

// The parts nearly every demo shares: a keyboard, an envelope so a keypress is a note
// rather than a drone, and an output. Kept in one place so the demos differ only where
// they are meant to — the node being shown.
const keyboard = (column = 0, lane = 1) => seam('kb', 'Input', 'note', {}, column, lane);
const envelope = (column, lane = 1) =>
  node('env', 'AhdEnvelope', { attack: 0.005, hold: 0.15, decay: 0.35 }, column, lane);
const amp = (column) => node('amp', 'Gain', { gain: 0.7 }, column, 0);
const out = (column) =>
  seam('out', 'Output', 'stereo', { level: 0.8, safety_limit: 1 }, column, 0);

/** Wires an envelope to an amplifier and the amplifier to the output. */
const tail = (source, sourcePort = 'out') => [
  wire('kb', 'trigger', 'env', 'gate'),
  wire('env', 'out', 'amp', 'gain'),
  wire(source, sourcePort, 'amp', 'in'),
  wire('amp', 'out', 'out', 'left'),
  wire('amp', 'out', 'out', 'right'),
];

// A source, the node under demonstration, and the tail. Covers the majority.
function throughEffect(type, parameters, extraNodes = [], extraWires = []) {
  return {
    nodes: [
      keyboard(),
      node('osc', 'SawOscillator', { frequency: 220 }, 1, 0),
      node('demo', type, parameters, 2, 0),
      envelope(2),
      amp(3),
      out(4),
      ...extraNodes,
    ],
    connections: [
      wire('kb', 'frequency', 'osc', 'frequency'),
      wire('osc', 'out', 'demo', 'in'),
      ...tail('demo'),
      ...extraWires,
    ],
  };
}

// An oscillator is its own source, so it takes the keyboard's pitch directly.
function asSource(type, parameters, pitched = true) {
  return {
    nodes: [keyboard(), node('demo', type, parameters, 1, 0), envelope(1), amp(2), out(3)],
    connections: [
      ...(pitched ? [wire('kb', 'frequency', 'demo', 'frequency')] : []),
      ...tail('demo'),
    ],
  };
}

/**
 * One entry per registered node type. `try` is the sentence shown in the patch
 * description — the thing to change to hear what the node does.
 */
const DEMOS = {
  // ---- terminals ----------------------------------------------------------------
  NoteInput: {
    summary: 'Playing the keyboard: pitch, loudness and a pulse on every note.',
    try: 'Hold one key and press another without letting go — the trigger fires again, '
      + 'the gate never falls. Then raise glide and play a run.',
    build: () => ({
      nodes: [
        // Spelled out rather than defaulted, because this is the demo *of* the keyboard:
        // a parameter left implicit is a parameter with no control to drag.
        seam('kb', 'Input', 'note', { glide: 0, transpose: 0 }, 0, 0),
        node('osc', 'SawOscillator', {}, 1, 0),
        // Velocity into the amplifier is the whole reason a keyboard has it.
        node('vel', 'Multiply', {}, 2, 1),
        envelope(1, 2),
        amp(3),
        out(4),
      ],
      connections: [
        wire('kb', 'frequency', 'osc', 'frequency'),
        wire('kb', 'trigger', 'env', 'gate'),
        wire('env', 'out', 'vel', 'a'),
        wire('kb', 'velocity', 'vel', 'b'),
        wire('vel', 'out', 'amp', 'gain'),
        wire('osc', 'out', 'amp', 'in'),
        wire('amp', 'out', 'out', 'left'),
        wire('amp', 'out', 'out', 'right'),
      ],
    }),
  },
  NoteTriggers: {
    summary: 'Eight chromatic notes become eight triggers: the keyboard as drum pads.',
    try: 'Strike the base note for the first trigger and walk up by semitones for the '
      + 'rest. Notes outside the eight lanes are simply not for this node — wire each '
      + 'outlet to a different drum and the bottom of the keyboard is a kit.',
    build: () => ({
      nodes: [
        keyboard(0),
        // Based at middle C so the demo render's own strikes land on the first pad.
        node('pads', 'NoteTriggers', { base: 60 }, 1, 1),
        node('tone', 'SineOscillator', { frequency: 220 }, 1, 0),
        envelope(2),
        amp(3),
        out(4),
      ],
      connections: [
        wire('pads', 't1', 'env', 'gate'),
        wire('env', 'out', 'amp', 'gain'),
        wire('tone', 'out', 'amp', 'in'),
        wire('amp', 'out', 'out', 'left'),
      ],
    }),
  },
  TriggerBus: {
    summary: 'One wire in, eight pads out: the far end of a trigger ribbon cable.',
    try: 'Strike middle C: the router puts lane one on the bus, the bus rides one '
      + 'wire, and this splits it back out to gate the envelope. Probe the bus with '
      + 'the scope — pulse height says which pad fired.',
    build: () => ({
      nodes: [
        keyboard(0),
        node('pads', 'NoteTriggers', { base: 60 }, 1, 1),
        node('demo', 'TriggerBus', { shift: 0 }, 2, 1),
        node('tone', 'SineOscillator', { frequency: 220 }, 1, 0),
        envelope(3),
        amp(4),
        out(5),
      ],
      connections: [
        wire('pads', 'bus', 'demo', 'bus'),
        wire('demo', 't1', 'env', 'gate'),
        wire('env', 'out', 'amp', 'gain'),
        wire('tone', 'out', 'amp', 'in'),
        wire('amp', 'out', 'out', 'left'),
      ],
    }),
  },
  Drive: {
    summary: 'A tanh soft clip: warmth low, growl high. The acid pedal.',
    try: 'Turn drive up and the saw grows teeth without getting louder — the '
      + 'clip is normalised, so the Level knob after it keeps its one job.',
    build: () => ({
      nodes: [
        keyboard(0),
        node('osc', 'SawOscillator', { frequency: 110 }, 1, 0),
        node('demo', 'Drive', { drive: 6 }, 2, 0),
        envelope(1, 1),
        amp(3),
        out(4),
      ],
      connections: [
        wire('kb', 'frequency', 'osc', 'frequency'),
        wire('kb', 'gate', 'env', 'gate'),
        wire('osc', 'out', 'demo', 'in'),
        wire('demo', 'out', 'amp', 'in'),
        wire('env', 'out', 'amp', 'gain'),
        wire('amp', 'out', 'out', 'left'),
      ],
    }),
  },
  AudioInput: {
    summary: 'Live audio from the host — a microphone, an instrument, a DAW track.',
    // The one demo that is silent when rendered offline, and correctly so.
    silentOffline: true,
    try: 'Play it somewhere with an input. In a browser there is no getUserMedia here, so '
      + 'it stays silent — that is the node waiting, not the patch being broken.',
    build: () => ({
      nodes: [
        seam('demo', 'Input', 'audio', { gain: 1 }, 0, 0),
        node('filter', 'StateVariableFilter', { cutoff: 2000, resonance: 0.2 }, 1, 0),
        out(2),
      ],
      connections: [
        wire('demo', 'left', 'filter', 'in'),
        wire('filter', 'out', 'out', 'left'),
        wire('demo', 'right', 'out', 'right'),
      ],
    }),
  },
  StereoOutput: {
    summary: 'Where a patch leaves the graph, and the limiter that stops it hurting.',
    try: 'Turn safety_limit off with the oscillators stacked this loudly, then on again. '
      + 'That is what it is protecting you from.',
    build: () => ({
      nodes: [
        keyboard(),
        node('osc1', 'SawOscillator', { frequency: 220 }, 1, 0),
        node('osc2', 'SawOscillator', { frequency: 221.5 }, 1, 1),
        node('mix', 'Mixer', { level1: 1.6, level2: 1.6 }, 2, 0),
        envelope(2, 2),
        amp(3),
        seam('demo', 'Output', 'stereo', { level: 1.4, safety_limit: 1 }, 4, 0),
      ],
      connections: [
        wire('kb', 'frequency', 'osc1', 'frequency'),
        wire('kb', 'frequency', 'osc2', 'frequency'),
        wire('osc1', 'out', 'mix', 'in1'),
        wire('osc2', 'out', 'mix', 'in2'),
        wire('kb', 'trigger', 'env', 'gate'),
        wire('env', 'out', 'amp', 'gain'),
        wire('mix', 'out', 'amp', 'in'),
        wire('amp', 'out', 'demo', 'left'),
        wire('amp', 'out', 'demo', 'right'),
      ],
    }),
  },

  // ---- sources ------------------------------------------------------------------
  SineOscillator: {
    summary: 'A pure tone: one frequency, no harmonics, nothing to filter.',
    try: 'Compare it with the saw demo on the same key. Everything a filter does, it does '
      + 'to the harmonics this one has not got.',
    build: () => asSource('SineOscillator', { frequency: 440 }),
  },
  SawOscillator: {
    summary: 'Every harmonic at once — the bright, buzzy synth starting point.',
    try: 'Play it, then open the StateVariableFilter demo. This is what that is carving.',
    build: () => asSource('SawOscillator', { frequency: 220 }),
  },
  SquareOscillator: {
    summary: 'Hollow and woody, and thinner the narrower you make the pulse.',
    try: 'Move pulse_width from 0.5 down to 0.1 while holding a key. Then set '
      + 'pulse_width_sweep to 2 and let it move on its own.',
    build: () => asSource('SquareOscillator', { frequency: 220, pulse_width: 0.5 }),
  },
  Noise: {
    summary: 'Unpitched noise, for percussion, wind and breath.',
    try: 'Take colour from 0 to 1. White is a hiss, pink is a rush — the same energy, '
      + 'weighted towards the bottom.',
    build: () => asSource('Noise', { colour: 0.0 }, false),
  },
  NoiseOscillator: {
    summary: 'Noise with a pitch — the rasp of a retro sound chip, not a hiss.',
    try: 'Play it up the keyboard: it is noise, and it still has a note. Then drop steps '
      + 'to 4 for the coarse, metallic version.',
    build: () => asSource('NoiseOscillator', { frequency: 220, steps: 32 }),
  },

  // ---- filters ------------------------------------------------------------------
  StateVariableFilter: {
    summary: 'The classic filter: cutoff, resonance, and four ways to use them.',
    try: 'Sweep cutoff with resonance at 0.8 — that whistle at the corner is what makes a '
      + 'filter sound like a filter. mode 1 is highpass, 2 bandpass, 3 notch.',
    build: () => throughEffect('StateVariableFilter',
      { cutoff: 900, resonance: 0.7, mode: 0 },
      [node('sweep', 'LFO', { rate: 0.4, shape: 0, amount: 2, offset: 0 }, 1, 2)],
      [wire('sweep', 'out', 'demo', 'cutoff_mod')]),
  },
  OnePoleFilter: {
    summary: 'A gentler filter, half the slope. Warms or thins without carving.',
    try: 'Set the same cutoff on both filter demos and listen an octave below it. This one '
      + 'lets far more through, which is the entire reason it exists.',
    build: () => throughEffect('OnePoleFilter', { cutoff: 800, mode: 0 }),
  },

  // ---- time ---------------------------------------------------------------------
  Delay: {
    summary: 'Repeats the signal after a set time. Feed it back for echoes.',
    try: 'Raise feedback towards 0.9 for a long tail, then drop time under 0.02 s — short '
      + 'enough and the echoes stop being echoes and become a pitch.',
    build: () => throughEffect('Delay', { time: 0.22, feedback: 0.55, mix: 0.45 }),
  },
  Phaser: {
    summary: 'A short swept delay mixed back in. The whoosh on an explosion.',
    try: 'Set sweep to 0 and move offset by hand — the notches sit still. Put sweep back '
      + 'and they move, which is the whole effect.',
    build: () => throughEffect('Phaser', { offset: 2, sweep: 40, depth: 1 }),
  },

  // ---- amplitude ----------------------------------------------------------------
  Gain: {
    summary: 'Louder or quieter — and the thing an envelope is usually connected to.',
    try: 'Disconnect the envelope from gain. The note stops having a shape and becomes a '
      + 'switch, which is what an amplifier is without one.',
    build: () => ({
      nodes: [
        keyboard(),
        node('osc', 'SawOscillator', { frequency: 220 }, 1, 0),
        node('demo', 'Gain', { gain: 0.7 }, 2, 0),
        envelope(2),
        out(3),
      ],
      connections: [
        wire('kb', 'frequency', 'osc', 'frequency'),
        wire('osc', 'out', 'demo', 'in'),
        wire('kb', 'trigger', 'env', 'gate'),
        wire('env', 'out', 'demo', 'gain'),
        wire('demo', 'out', 'out', 'left'),
        wire('demo', 'out', 'out', 'right'),
      ],
    }),
  },
  Level: {
    summary: "A fixed trim -- what a port's own level becomes in the flat graph.",
    try: 'Pull level down and back. Nothing else about the sound changes, which is the '
      + 'point: this is the trim pot on a jack, not an amplifier stage.',
    build: () => ({
      nodes: [
        keyboard(),
        node('osc', 'SawOscillator', { frequency: 220 }, 1, 0),
        envelope(1, 1),
        amp(2),
        node('demo', 'Level', { level: 0.7 }, 3, 0),
        out(4),
      ],
      connections: [
        wire('kb', 'frequency', 'osc', 'frequency'),
        wire('osc', 'out', 'amp', 'in'),
        wire('kb', 'trigger', 'env', 'gate'),
        wire('env', 'out', 'amp', 'gain'),
        wire('amp', 'out', 'demo', 'in'),
        wire('demo', 'out', 'out', 'left'),
        wire('demo', 'out', 'out', 'right'),
      ],
    }),
  },
  StereoLevel: {
    summary: 'One trim for a stereo pair, channels kept apart.',
    try: 'Pull level down and back. Both channels follow one knob, and neither leaks '
      + 'into the other.',
    build: () => ({
      nodes: [
        keyboard(),
        node('osc', 'SawOscillator', { frequency: 220 }, 1, 0),
        envelope(1, 1),
        amp(2),
        node('demo', 'StereoLevel', { level: 0.7 }, 3, 0),
        out(4),
      ],
      connections: [
        wire('kb', 'frequency', 'osc', 'frequency'),
        wire('osc', 'out', 'amp', 'in'),
        wire('kb', 'trigger', 'env', 'gate'),
        wire('env', 'out', 'amp', 'gain'),
        wire('amp', 'out', 'demo', 'left'),
        wire('amp', 'out', 'demo', 'right'),
        wire('demo', 'left', 'out', 'left'),
        wire('demo', 'right', 'out', 'right'),
      ],
    }),
  },
  Mixer: {
    summary: 'Four signals at independent levels.',
    try: 'The three oscillators are detuned by a few hertz. Pull level2 and level3 to zero '
      + 'and back — the beating between them is the whole sound.',
    build: () => ({
      nodes: [
        keyboard(),
        node('osc1', 'SawOscillator', { frequency: 220 }, 1, 0),
        node('osc2', 'SawOscillator', { frequency: 221.5 }, 1, 1),
        node('osc3', 'SawOscillator', { frequency: 218.5 }, 1, 2),
        node('demo', 'Mixer', { level1: 0.5, level2: 0.5, level3: 0.5, level4: 0 }, 2, 0),
        envelope(2, 3),
        amp(3),
        out(4),
      ],
      connections: [
        wire('kb', 'frequency', 'osc1', 'frequency'),
        wire('osc1', 'out', 'demo', 'in1'),
        wire('osc2', 'out', 'demo', 'in2'),
        wire('osc3', 'out', 'demo', 'in3'),
        ...tail('demo'),
      ],
    }),
  },

  // ---- modulation ---------------------------------------------------------------
  ADSR: {
    summary: 'The shape of a note that sustains: attack, decay, sustain, release.',
    try: 'Hold a key. Attack rises, decay falls to the sustain level, and it waits there '
      + 'until you let go — that waiting is what makes this one different from AhdEnvelope.',
    build: () => ({
      nodes: [
        keyboard(),
        node('osc', 'SawOscillator', { frequency: 220 }, 1, 0),
        // The gate, not the trigger: this envelope's whole point is that it holds while
        // the key is down.
        node('demo', 'ADSR', { attack: 0.15, decay: 0.25, sustain: 0.5, release: 0.6 }, 1, 1),
        amp(2),
        out(3),
      ],
      connections: [
        wire('kb', 'frequency', 'osc', 'frequency'),
        wire('kb', 'gate', 'demo', 'gate'),
        wire('demo', 'out', 'amp', 'gain'),
        wire('osc', 'out', 'amp', 'in'),
        wire('amp', 'out', 'out', 'left'),
        wire('amp', 'out', 'out', 'right'),
      ],
    }),
  },
  AhdEnvelope: {
    summary: 'A one-shot: over before you let go. Hits, coins, jumps.',
    try: 'Hold a key for as long as you like — it makes no difference, which is the point. '
      + 'Raise punch for the sharp crack at the front.',
    build: () => ({
      nodes: [
        keyboard(),
        node('osc', 'SquareOscillator', { frequency: 220 }, 1, 0),
        node('demo', 'AhdEnvelope', { attack: 0, hold: 0.05, decay: 0.25, punch: 0.4 }, 1, 1),
        amp(2),
        out(3),
      ],
      connections: [
        wire('kb', 'frequency', 'osc', 'frequency'),
        wire('kb', 'trigger', 'demo', 'gate'),
        wire('demo', 'out', 'amp', 'gain'),
        wire('osc', 'out', 'amp', 'in'),
        wire('amp', 'out', 'out', 'left'),
        wire('amp', 'out', 'out', 'right'),
      ],
    }),
  },
  Slide: {
    summary: 'Bends a frequency over time. Falling makes a laser, rising a powerup.',
    try: 'slide is negative here, so it falls. Make it +600 and it is a powerup instead. '
      + 'limit is the floor it stops at.',
    build: () => ({
      nodes: [
        keyboard(),
        node('demo', 'Slide', { slide: -900, acceleration: 0, limit: 80, frequency: 880 }, 1, 0),
        node('osc', 'SquareOscillator', { frequency: 220 }, 2, 0),
        envelope(2, 1),
        amp(3),
        out(4),
      ],
      connections: [
        wire('kb', 'frequency', 'demo', 'frequency'),
        wire('kb', 'trigger', 'demo', 'gate'),
        wire('demo', 'frequency', 'osc', 'frequency'),
        ...tail('osc'),
      ],
    }),
  },
  Arpeggio: {
    summary: 'One jump in pitch, once, part-way through. The chirp on a pickup.',
    try: 'interval 7 is the fifth you hear; 12 is an octave and sounds like a coin. time '
      + 'is how far into the note it jumps.',
    build: () => ({
      nodes: [
        keyboard(),
        node('demo', 'Arpeggio', { time: 0.06, interval: 7, frequency: 660 }, 1, 0),
        node('osc', 'SquareOscillator', { frequency: 220 }, 2, 0),
        envelope(2, 1),
        amp(3),
        out(4),
      ],
      connections: [
        wire('kb', 'frequency', 'demo', 'frequency'),
        wire('kb', 'trigger', 'demo', 'gate'),
        wire('demo', 'frequency', 'osc', 'frequency'),
        ...tail('osc'),
      ],
    }),
  },
  Retrigger: {
    summary: 'A pulse on a timer, to restart anything with a gate.',
    try: 'This one plays on its own — the timer is the performer. Take rate from 8 Hz down '
      + 'to 2 and the machine gun becomes a pulse.',
    build: () => ({
      nodes: [
        node('demo', 'Retrigger', { rate: 8, width: 1 }, 0, 0),
        node('osc', 'SquareOscillator', { frequency: 330 }, 1, 0),
        node('env', 'AhdEnvelope', { attack: 0, hold: 0.01, decay: 0.08, punch: 0.5 }, 1, 1),
        amp(2),
        out(3),
      ],
      connections: [
        wire('demo', 'gate', 'env', 'gate'),
        wire('env', 'out', 'amp', 'gain'),
        wire('osc', 'out', 'amp', 'in'),
        wire('amp', 'out', 'out', 'left'),
        wire('amp', 'out', 'out', 'right'),
      ],
    }),
  },
  LFO: {
    summary: 'A slow wave for moving other controls: vibrato, tremolo, filter sweeps.',
    try: 'It is on the oscillator\'s fm here, which makes vibrato. Move the same cable to '
      + 'the filter\'s cutoff_mod and the identical node becomes a sweep.',
    build: () => ({
      nodes: [
        keyboard(),
        node('demo', 'LFO', { rate: 5.5, shape: 0, amount: 0.03, offset: 0 }, 1, 1),
        node('osc', 'SawOscillator', { frequency: 220 }, 2, 0),
        envelope(2, 2),
        amp(3),
        out(4),
      ],
      connections: [
        wire('kb', 'frequency', 'osc', 'frequency'),
        wire('demo', 'out', 'osc', 'fm'),
        ...tail('osc'),
      ],
    }),
  },
  Constant: {
    summary: 'A fixed value — the thing you reach for to offset or scale a modulation.',
    try: 'The LFO swings either side of zero; adding this constant lifts it so the filter '
      + 'sweeps around 1 rather than through zero. Change the value and hear the centre move.',
    build: () => ({
      nodes: [
        keyboard(),
        node('lfo', 'LFO', { rate: 0.8, shape: 0, amount: 1, offset: 0 }, 1, 2),
        node('demo', 'Constant', { value: 1.5 }, 1, 3),
        node('sum', 'Add', {}, 2, 2),
        node('osc', 'SawOscillator', { frequency: 220 }, 1, 0),
        node('filter', 'StateVariableFilter', { cutoff: 700, resonance: 0.6, mode: 0 }, 3, 0),
        envelope(2, 1),
        amp(4),
        out(5),
      ],
      connections: [
        wire('kb', 'frequency', 'osc', 'frequency'),
        wire('lfo', 'out', 'sum', 'a'),
        wire('demo', 'out', 'sum', 'b'),
        wire('sum', 'out', 'filter', 'cutoff_mod'),
        wire('osc', 'out', 'filter', 'in'),
        ...tail('filter'),
      ],
    }),
  },

  // ---- maths --------------------------------------------------------------------
  Add: {
    summary: 'Adds two control signals. Shifts a modulation without changing its size.',
    try: 'Change offset. The vibrato keeps its depth and moves to a different pitch — '
      + 'adding shifts, it does not scale. Multiply is the one that scales.',
    build: () => ({
      nodes: [
        keyboard(),
        node('lfo', 'LFO', { rate: 5, shape: 0, amount: 0.02, offset: 0 }, 1, 2),
        node('demo', 'Add', { offset: 0.08 }, 2, 2),
        node('osc', 'SawOscillator', { frequency: 220 }, 2, 0),
        envelope(2, 1),
        amp(3),
        out(4),
      ],
      connections: [
        wire('kb', 'frequency', 'osc', 'frequency'),
        wire('lfo', 'out', 'demo', 'a'),
        wire('demo', 'out', 'osc', 'fm'),
        ...tail('osc'),
      ],
    }),
  },
  Multiply: {
    summary: 'Multiplies two control signals. The way to scale a modulation depth.',
    try: 'Take factor from 1 to 0. The vibrato gets shallower and finally stops, and the '
      + 'pitch it is centred on never moves — which is what makes this different from Add.',
    build: () => ({
      nodes: [
        keyboard(),
        node('lfo', 'LFO', { rate: 5, shape: 0, amount: 0.06, offset: 0 }, 1, 2),
        node('demo', 'Multiply', { factor: 0.6 }, 2, 2),
        node('osc', 'SawOscillator', { frequency: 220 }, 2, 0),
        envelope(2, 1),
        amp(3),
        out(4),
      ],
      connections: [
        wire('kb', 'frequency', 'osc', 'frequency'),
        wire('lfo', 'out', 'demo', 'a'),
        wire('demo', 'out', 'osc', 'fm'),
        ...tail('osc'),
      ],
    }),
  },
  Compressor: {
    summary: 'Holds the loud parts down. Wire a kick to the sidechain and everything '
      + 'through it pumps.',
    try: 'The pad is a steady drone; the kick never touches it except through the '
      + 'sidechain — every hit, the pad breathes out of its way and swells back. '
      + 'Slow release deepens the pump; ratio 1 switches it off entirely.',
    build: () => ({
      nodes: [
        node('clock', 'Clock', { bpm: 124, division: 2, swing: 0, width: 5 }, 0, 0),
        node('kickosc', 'SineOscillator', { frequency: 60 }, 0, 1),
        node('kickenv', 'AhdEnvelope', { attack: 0, hold: 0.02, decay: 0.12, punch: 1 }, 1, 0),
        node('kick', 'Gain', { gain: 1 }, 1, 1),
        node('pad1', 'SawOscillator', { frequency: 110 }, 0, 2),
        node('pad2', 'SawOscillator', { frequency: 110.7 }, 0, 3),
        node('pads', 'Gain', { gain: 0.3 }, 1, 2),
        node('demo', 'Compressor',
          { threshold: 0.1, ratio: 8, attack: 0.002, release: 0.25, makeup: 1.2 }, 2, 2),
        node('mix', 'Mixer', { level1: 1, level2: 0.9 }, 3, 0),
        out(4),
      ],
      connections: [
        wire('clock', 'gate', 'kickenv', 'gate'),
        wire('kickenv', 'out', 'kick', 'gain'),
        wire('kickosc', 'out', 'kick', 'in'),
        wire('pad1', 'out', 'pads', 'in'),
        wire('pad2', 'out', 'pads', 'in'),
        wire('pads', 'out', 'demo', 'in'),
        wire('kick', 'out', 'demo', 'sidechain'),
        wire('kick', 'out', 'mix', 'in1'),
        wire('demo', 'out', 'mix', 'in2'),
        wire('mix', 'out', 'out', 'left'),
        wire('mix', 'out', 'out', 'right'),
      ],
    }),
  },
  Comb: {
    summary: 'A feedback delay with damping in the loop: the piece reverbs are built from.',
    try: 'One comb alone is a flutter echo with a metallic pitch. Shorten time and the '
      + 'flutter becomes a tone of its own; raise damp and each pass comes back darker. '
      + 'Eight of these in parallel are a room — open the Warehouse patch to hear that.',
    build: () => ({
      nodes: [
        keyboard(),
        node('osc', 'SawOscillator', { frequency: 220 }, 1, 0),
        envelope(1, 1),
        node('vca', 'Gain', { gain: 0.7 }, 2, 0),
        node('demo', 'Comb', { time: 0.03, feedback: 0.7, damp: 0.2 }, 3, 0),
        node('mix', 'Mixer', { level1: 0.8, level2: 0.5 }, 4, 0),
        out(5),
      ],
      connections: [
        wire('kb', 'frequency', 'osc', 'frequency'),
        wire('kb', 'trigger', 'env', 'gate'),
        wire('env', 'out', 'vca', 'gain'),
        wire('osc', 'out', 'vca', 'in'),
        wire('vca', 'out', 'mix', 'in1'),
        wire('vca', 'out', 'demo', 'in'),
        wire('demo', 'out', 'mix', 'in2'),
        wire('mix', 'out', 'out', 'left'),
        wire('mix', 'out', 'out', 'right'),
      ],
    }),
  },
  Allpass: {
    summary: 'Smears time without touching the spectrum: the diffuser inside every reverb.',
    try: 'The retrigger fires bare clicks. Through the allpass each click comes out a '
      + 'small "tsh" — same spectrum, smeared time. Take gain to 0 and it is a plain '
      + 'delay again: the clicks return to being clicks.',
    build: () => ({
      nodes: [
        node('trig', 'Retrigger', { rate: 3, width: 1 }, 0, 0),
        node('click', 'AhdEnvelope', { attack: 0, hold: 0.001, decay: 0.002 }, 1, 0),
        node('noise', 'Noise', {}, 0, 1),
        node('vca', 'Gain', { gain: 0.8 }, 2, 0),
        node('demo', 'Allpass', { time: 0.02, gain: 0.6 }, 3, 0),
        amp(4),
        out(5),
      ],
      connections: [
        wire('trig', 'gate', 'click', 'gate'),
        wire('click', 'out', 'vca', 'gain'),
        wire('noise', 'out', 'vca', 'in'),
        wire('vca', 'out', 'demo', 'in'),
        wire('demo', 'out', 'amp', 'in'),
        wire('amp', 'out', 'out', 'left'),
        wire('amp', 'out', 'out', 'right'),
      ],
    }),
  },
  Crush: {
    summary: 'Bit depth and sample rate, reduced on purpose. The 12-bit sampler as an effect.',
    try: 'Play up the keyboard: as notes rise, the held-down sample rate stops keeping '
      + 'up and aliased partials fold back down — the sound this node is for. Lower '
      + 'bits and the quiet tail of each note turns to gravel first.',
    build: () => ({
      nodes: [
        keyboard(),
        node('osc', 'SawOscillator', { frequency: 220 }, 1, 0),
        node('demo', 'Crush', { bits: 8, rate: 6000 }, 2, 0),
        envelope(2, 1),
        amp(3),
        out(4),
      ],
      connections: [
        wire('kb', 'frequency', 'osc', 'frequency'),
        wire('osc', 'out', 'demo', 'in'),
        ...tail('demo'),
      ],
    }),
  },
  Clip: {
    summary: 'Keeps a signal between a floor and a ceiling. The hard limit as a building block.',
    try: 'The vibrato is wide, but the clip holds its top at a semitone above centre. '
      + 'Raise ceiling and the upward swings come back; lower it to zero and the pitch '
      + 'can only dip.',
    build: () => ({
      nodes: [
        keyboard(),
        node('lfo', 'LFO', { rate: 4, shape: 0, amount: 0.12, offset: 0 }, 1, 2),
        node('demo', 'Clip', { floor: -0.12, ceiling: 0.02 }, 2, 2),
        node('osc', 'SawOscillator', { frequency: 220 }, 2, 0),
        envelope(2, 1),
        amp(3),
        out(4),
      ],
      connections: [
        wire('kb', 'frequency', 'osc', 'frequency'),
        wire('lfo', 'out', 'demo', 'in'),
        wire('demo', 'out', 'osc', 'fm'),
        ...tail('osc'),
      ],
    }),
  },
  Abs: {
    summary: 'Folds a signal upward: negative parts become positive.',
    try: 'The LFO swings both ways, but the pitch only ever rises — twice per cycle, '
      + 'because the fold turns each downward swing into another upward one. Move the '
      + 'cable straight from the LFO to the fm input to hear the difference the fold makes.',
    build: () => ({
      nodes: [
        keyboard(),
        node('lfo', 'LFO', { rate: 1.5, shape: 0, amount: 0.15, offset: 0 }, 1, 2),
        node('demo', 'Abs', {}, 2, 2),
        node('osc', 'SawOscillator', { frequency: 220 }, 2, 0),
        envelope(2, 1),
        amp(3),
        out(4),
      ],
      connections: [
        wire('kb', 'frequency', 'osc', 'frequency'),
        wire('lfo', 'out', 'demo', 'in'),
        wire('demo', 'out', 'osc', 'fm'),
        ...tail('osc'),
      ],
    }),
  },
  MinMax: {
    summary: 'Passes the smaller or the larger of two signals.',
    try: 'Set to maximum against zero, it passes only the vibrato\'s upward half: the '
      + 'pitch lifts, rests, lifts. Flip mode to minimum and the same wave can only dip.',
    build: () => ({
      nodes: [
        keyboard(),
        node('lfo', 'LFO', { rate: 1.2, shape: 0, amount: 0.2, offset: 0 }, 1, 2),
        node('demo', 'MinMax', { mode: 1, other: 0 }, 2, 2),
        node('osc', 'SawOscillator', { frequency: 220 }, 2, 0),
        envelope(2, 1),
        amp(3),
        out(4),
      ],
      connections: [
        wire('kb', 'frequency', 'osc', 'frequency'),
        wire('lfo', 'out', 'demo', 'a'),
        wire('demo', 'out', 'osc', 'fm'),
        ...tail('osc'),
      ],
    }),
  },
  Compare: {
    summary: 'Outputs a gate: 1 while the input is at or above the threshold, 0 below.',
    try: 'The LFO is invisible until the compare turns it into a rhythm: open above the '
      + 'threshold, shut below. Raise threshold towards 1 and the note shrinks to clicks '
      + 'at the very peaks.',
    build: () => ({
      nodes: [
        keyboard(),
        node('lfo', 'LFO', { rate: 3, shape: 0, amount: 1, offset: 0 }, 1, 2),
        node('demo', 'Compare', { threshold: 0 }, 2, 2),
        node('osc', 'SawOscillator', { frequency: 220 }, 2, 0),
        envelope(2, 1),
        node('gate', 'Gain', { gain: 1 }, 3, 1),
        amp(3),
        out(5),
      ],
      connections: [
        wire('kb', 'frequency', 'osc', 'frequency'),
        wire('kb', 'trigger', 'env', 'gate'),
        wire('env', 'out', 'amp', 'gain'),
        wire('osc', 'out', 'amp', 'in'),
        wire('lfo', 'out', 'demo', 'a'),
        wire('amp', 'out', 'gate', 'in'),
        wire('demo', 'out', 'gate', 'gain'),
        wire('gate', 'out', 'out', 'left'),
        wire('gate', 'out', 'out', 'right'),
      ],
    }),
  },
  Clock: {
    summary: 'Musical time: pulses at a bpm and note division, with swing and a bar downbeat.',
    try: 'This one plays on its own — sixteenths up top, the bar output thumping the '
      + 'downbeat below. Raise swing and the sixteenths shuffle; change bpm and both '
      + 'lines move together, because they are the same clock.',
    build: () => ({
      nodes: [
        node('demo', 'Clock', { bpm: 128, division: 4, swing: 0, width: 5 }, 0, 0),
        node('osc', 'SquareOscillator', { frequency: 660 }, 1, 0),
        node('env', 'AhdEnvelope', { attack: 0, hold: 0.01, decay: 0.06, punch: 0.5 }, 1, 1),
        node('blip', 'Gain', { gain: 0.5 }, 2, 0),
        node('bass', 'SineOscillator', { frequency: 82.5 }, 1, 2),
        node('benv', 'AhdEnvelope', { attack: 0, hold: 0.02, decay: 0.25, punch: 1 }, 1, 3),
        node('thump', 'Gain', { gain: 0.9 }, 2, 2),
        node('mix', 'Mixer', { level1: 0.7, level2: 1 }, 3, 0),
        out(4),
      ],
      connections: [
        wire('demo', 'gate', 'env', 'gate'),
        wire('env', 'out', 'blip', 'gain'),
        wire('osc', 'out', 'blip', 'in'),
        wire('demo', 'bar', 'benv', 'gate'),
        wire('benv', 'out', 'thump', 'gain'),
        wire('bass', 'out', 'thump', 'in'),
        wire('blip', 'out', 'mix', 'in1'),
        wire('thump', 'out', 'mix', 'in2'),
        wire('mix', 'out', 'out', 'left'),
        wire('mix', 'out', 'out', 'right'),
      ],
    }),
  },
  ScaleQuantizer: {
    summary: 'Snaps a pitch signal to the nearest note of a scale. Random in, melody out.',
    try: 'Nothing here chooses notes — noise does, sampled on the eighths — yet every '
      + 'one lands in minor pentatonic. Set scale to chromatic to hear what the '
      + 'quantizer was saving you from, or change root to move the whole melody.',
    build: () => ({
      nodes: [
        node('clock', 'Clock', { bpm: 120, division: 3, swing: 0, width: 5 }, 0, 0),
        node('noise', 'Noise', {}, 0, 2),
        node('snh', 'SampleHold', {}, 1, 2),
        node('demo', 'ScaleQuantizer', { scale: 7, root: 0 }, 2, 2),
        node('osc', 'SawOscillator', { frequency: 220 }, 2, 0),
        node('env', 'AhdEnvelope', { attack: 0.002, hold: 0.03, decay: 0.18 }, 1, 1),
        amp(3),
        out(4),
      ],
      connections: [
        wire('clock', 'gate', 'snh', 'trigger'),
        wire('noise', 'out', 'snh', 'in'),
        wire('snh', 'out', 'demo', 'in'),
        wire('demo', 'out', 'osc', 'fm'),
        wire('clock', 'gate', 'env', 'gate'),
        wire('env', 'out', 'amp', 'gain'),
        wire('osc', 'out', 'amp', 'in'),
        wire('amp', 'out', 'out', 'left'),
        wire('amp', 'out', 'out', 'right'),
      ],
    }),
  },
  StepSequencer: {
    summary: 'One lane of a step sequencer: sixteen values walked by a clock. A second '
      + 'lane on the same clock locks any knob per step.',
    try: 'Two lanes, one clock. The first walks the pitch through the quantizer; the '
      + 'second locks the filter per step — steps 3, 6 and 8 snap it open. Turn any '
      + 'step knob on either lane and only that step changes. That is a parameter lock.',
    build: () => ({
      nodes: [
        node('clock', 'Clock', { bpm: 132, division: 4, swing: 0, width: 5 }, 0, 0),
        node('osc', 'SawOscillator', { frequency: 110 }, 0, 2),
        // Each lane gets a column to itself: seventeen knobs make a tall node, and
        // nothing should sit underneath one in a generated layout.
        node('demo', 'StepSequencer', {
          length: 8, step2: 0, step3: 0.25, step4: 0.58,
          step6: 0.83, step7: 0.25, step8: 1.0,
        }, 1, 0),
        node('locks', 'StepSequencer', {
          length: 8, step3: 1.6, step5: 0, step6: 1.0, step8: 2.0,
        }, 2, 0),
        node('quant', 'ScaleQuantizer', { scale: 7, root: 0 }, 3, 0),
        node('env', 'AhdEnvelope', { attack: 0.001, hold: 0.02, decay: 0.14, punch: 0.3 }, 3, 1),
        node('filter', 'StateVariableFilter', { cutoff: 400, resonance: 0.7, mode: 0 }, 4, 0),
        amp(5),
        out(6),
      ],
      connections: [
        wire('clock', 'gate', 'demo', 'clock'),
        wire('clock', 'gate', 'locks', 'clock'),
        wire('clock', 'bar', 'demo', 'reset'),
        wire('clock', 'bar', 'locks', 'reset'),
        wire('demo', 'out', 'quant', 'in'),
        wire('quant', 'out', 'osc', 'fm'),
        wire('locks', 'out', 'filter', 'cutoff_mod'),
        wire('clock', 'gate', 'env', 'gate'),
        wire('env', 'out', 'amp', 'gain'),
        wire('osc', 'out', 'filter', 'in'),
        wire('filter', 'out', 'amp', 'in'),
        wire('amp', 'out', 'out', 'left'),
        wire('amp', 'out', 'out', 'right'),
      ],
    }),
  },
  SampleHold: {
    summary: 'Freezes its input each time the trigger fires, and holds it until the next.',
    try: 'A smooth slow wave, sampled six times a second, comes out as a staircase of '
      + 'pitches. Slow the clock LFO\'s rate and the steps stretch; swap the source for '
      + 'a Noise node and the staircase turns random.',
    build: () => ({
      nodes: [
        keyboard(),
        node('source', 'LFO', { rate: 0.4, shape: 0, amount: 0.5, offset: 0 }, 1, 2),
        node('clock', 'LFO', { rate: 6, shape: 3, amount: 1, offset: 0 }, 1, 3),
        node('demo', 'SampleHold', {}, 2, 2),
        node('osc', 'SawOscillator', { frequency: 220 }, 2, 0),
        envelope(2, 1),
        amp(3),
        out(4),
      ],
      connections: [
        wire('kb', 'frequency', 'osc', 'frequency'),
        wire('source', 'out', 'demo', 'in'),
        wire('clock', 'out', 'demo', 'trigger'),
        wire('demo', 'out', 'osc', 'fm'),
        ...tail('osc'),
      ],
    }),
  },
};

// The `try` sentence above, written so a machine can check it is true.
//
// Every demo renders to something audible, and that turns out to prove very little: a saw
// through a bypassed filter has the same RMS as a saw, so a demo whose node did nothing at
// all would pass. So each demo also names the one change its `try` text asks for, and
// `--verify` renders the patch with and without it and requires the audio to differ. A
// demo that says "drag this" and means it is a demo; one that doesn't is decoration.
//
// `probeless` is the way to say there is nothing to drag, and it has to give a reason —
// so that a node nobody thought about is distinguishable from one somebody did.
const PROBES = {
  NoteInput: { node: 'kb', parameter: 'transpose', value: 12 },
  // Moving the base one semitone makes every strike miss its pad: silence, total.
  NoteTriggers: { node: 'pads', parameter: 'base', value: 61 },
  TriggerBus: { parameter: 'shift', value: 8 },  // the wrong bank hears nothing
  Drive: { parameter: 'drive', value: 30 },
  AudioInput: { probeless: 'silent offline; there is no host input to change the sound of' },
  StereoOutput: { parameter: 'level', value: 0.25 },

  SineOscillator: { probeless: 'its only parameter is pitch, and the keyboard drives that' },
  SawOscillator: { probeless: 'its only parameter is pitch, and the keyboard drives that' },
  SquareOscillator: { parameter: 'pulse_width', value: 0.1 },
  Noise: { parameter: 'colour', value: 1 },
  NoiseOscillator: { parameter: 'steps', value: 4 },

  StateVariableFilter: { parameter: 'cutoff', value: 5000 },
  OnePoleFilter: { parameter: 'cutoff', value: 6000 },

  Delay: { parameter: 'feedback', value: 0.05 },
  Phaser: { parameter: 'sweep', value: 0 },
  Compressor: { parameter: 'ratio', value: 1 },
  Comb: { parameter: 'time', value: 0.004 },
  Allpass: { parameter: 'gain', value: 0 },
  Crush: { parameter: 'bits', value: 2 },

  Gain: { parameter: 'gain', value: 0.15 },
  Level: { parameter: 'level', value: 0.15 },
  StereoLevel: { parameter: 'level', value: 0.15 },
  Mixer: { parameter: 'level2', value: 0 },

  ADSR: { parameter: 'attack', value: 2.0 },
  AhdEnvelope: { parameter: 'decay', value: 1.5 },
  Slide: { parameter: 'slide', value: 600 },
  Arpeggio: { parameter: 'interval', value: 12 },
  Retrigger: { parameter: 'rate', value: 2 },
  LFO: { parameter: 'amount', value: 0.5 },
  Constant: { parameter: 'value', value: -1.0 },

  Add: { parameter: 'offset', value: 1.0 },
  Multiply: { parameter: 'factor', value: 0 },

  Clip: { parameter: 'ceiling', value: 0.12 },
  Abs: { probeless: 'it has no parameters; the demo asks you to move its cable instead' },
  MinMax: { parameter: 'mode', value: 0 },
  Compare: { parameter: 'threshold', value: 0.9 },
  SampleHold: { node: 'clock', parameter: 'rate', value: 1.5 },
  Clock: { parameter: 'bpm', value: 40 },
  ScaleQuantizer: { parameter: 'scale', value: 0 },
  // A lock appearing where there was none: step 5 of the filter lane opens up.
  StepSequencer: { node: 'locks', parameter: 'step5', value: 2 },
};

function render(type, demo) {
  const { nodes, connections } = demo.build();
  return `${JSON.stringify({
    schema_version: 1,
    metadata: {
      name: type,
      description: `${demo.summary} Try: ${demo.try} `
        + 'Generated by tools/node-demos.mjs. Do not edit by hand.',
      tags: ['demo', 'node'],
    },
    nodes: nodes.map((n) => ({
      id: n.id,
      type: n.type,
      ...(n.host ? { host: n.host } : {}),
      position: { x: n.column * COLUMN, y: n.lane * LANE },
      ...(Object.keys(n.parameters).length > 0 ? { parameters: n.parameters } : {}),
    })),
    connections,
  }, null, 2)}\n`;
}

// ---- verification ------------------------------------------------------------------

function readWav(path) {
  const bytes = readFileSync(path);
  let offset = 12;
  while (bytes.toString('ascii', offset, offset + 4) !== 'data') {
    offset += 8 + bytes.readUInt32LE(offset + 4);
  }
  const start = offset + 8;
  const frames = Math.floor((bytes.length - start) / 4);
  const samples = new Float64Array(frames);
  for (let i = 0; i < frames; i++) samples[i] = bytes.readInt16LE(start + i * 4) / 32768;
  return samples;
}

const rms = (samples) => Math.sqrt(
  samples.reduce((total, s) => total + s * s, 0) / Math.max(1, samples.length));

function verify(renderTool) {
  const scratch = mkdtempSync(join(tmpdir(), 'sg-demos-'));
  const RENDER = ['--seconds', '2', '--notes', '60,64', '--gate', '0.4', '--quiet'];
  let failures = 0;

  const renderTo = (patch, name) => {
    const wav = join(scratch, `${name}.wav`);
    const json = join(scratch, `${name}.json`);
    writeFileSync(json, JSON.stringify(patch));
    execFileSync(renderTool, [json, wav, ...RENDER], { stdio: 'pipe' });
    return readWav(wav);
  };

  for (const [type, demo] of Object.entries(DEMOS)) {
    const patch = JSON.parse(built.get(`${type}.json`));
    const probe = PROBES[type];
    if (!probe) {
      console.error(`  ${type}: no entry in PROBES`);
      failures++;
      continue;
    }

    const base = renderTo(patch, `${type}-base`);
    const level = rms(base);

    if (demo.silentOffline) {
      // Declared silent, so silence is the pass and sound is the failure — a demo that
      // started making noise here would mean it had stopped depending on the host input.
      if (level > 0.001) {
        console.error(`  ${type}: declared silent offline but rendered at ${level.toFixed(4)} rms`);
        failures++;
      } else {
        console.log(`  ${type.padEnd(20)} silent, as declared`);
      }
      continue;
    }

    if (level < 0.005) {
      console.error(`  ${type}: renders at ${level.toFixed(5)} rms — effectively silent`);
      failures++;
      continue;
    }

    if (probe.probeless) {
      console.log(`  ${type.padEnd(20)} rms ${level.toFixed(3)}  (no probe: ${probe.probeless})`);
      continue;
    }

    const targetId = probe.node ?? 'demo';
    const target = patch.nodes.find((n) => n.id === targetId);
    if (!target || !(probe.parameter in (target.parameters ?? {}))) {
      console.error(`  ${type}: probe names ${targetId}.${probe.parameter}, which the demo has not got`);
      failures++;
      continue;
    }
    target.parameters[probe.parameter] = probe.value;
    const probed = renderTo(patch, `${type}-probed`);

    // Difference relative to the signal, so a quiet demo is held to the same standard as
    // a loud one. 2% is far below "you would notice" and far above rounding.
    let difference = 0;
    for (let i = 0; i < Math.min(base.length, probed.length); i++) {
      difference += (base[i] - probed[i]) ** 2;
    }
    const relative = Math.sqrt(difference / Math.min(base.length, probed.length)) / level;
    if (relative < 0.02) {
      console.error(`  ${type}: changing ${targetId}.${probe.parameter} to ${probe.value} `
        + `moved the audio by ${(relative * 100).toFixed(2)}% — the demo does not do what it says`);
      failures++;
    } else {
      console.log(`  ${type.padEnd(20)} rms ${level.toFixed(3)}  `
        + `${probe.parameter} -> ${probe.value} moves it ${(relative * 100).toFixed(0)}%`);
    }
  }

  rmSync(scratch, { recursive: true, force: true });
  if (failures > 0) {
    console.error(`\n${failures} node demo(s) failed verification.`);
    process.exit(1);
  }
  console.log(`\nAll ${Object.keys(DEMOS).length} node demos sound, and do what they say.`);
}

const check = process.argv.includes('--check');
const built = new Map();
for (const [type, demo] of Object.entries(DEMOS)) {
  built.set(`${type}.json`, render(type, demo));
}

let differences = 0;
if (check) {
  for (const [name, contents] of built) {
    let committed = null;
    try {
      committed = readFileSync(join(target, name), 'utf8');
    } catch {
      committed = null;
    }
    if (committed !== contents) {
      console.error(`  stale: examples/patches/nodes/${name}`);
      differences++;
    }
  }
  // A demo for a node that no longer exists is as wrong as a missing one, and only this
  // direction catches a node being renamed.
  let onDisk = [];
  try {
    onDisk = readdirSync(target);
  } catch {
    onDisk = [];
  }
  for (const name of onDisk) {
    if (!built.has(name)) {
      console.error(`  orphan: examples/patches/nodes/${name} has no entry in node-demos.mjs`);
      differences++;
    }
  }
  // And the question the file listing cannot answer: is there a demo for every node that
  // exists? The registry is the authority on that, so ask it rather than keeping a count
  // here that would be one more thing to forget.
  const validateIndex = process.argv.indexOf('--nodes');
  if (validateIndex >= 0) {
    const listing = execFileSync(process.argv[validateIndex + 1], ['--list-nodes'],
      { encoding: 'utf8' });
    const registered = [...listing.matchAll(/^(\w+)\s+\(/gm)].map((m) => m[1]);
    for (const type of registered) {
      if (!(type in DEMOS)) {
        console.error(`  missing: ${type} is a registered node type with no demo`);
        differences++;
      }
    }
    for (const type of Object.keys(DEMOS)) {
      if (!registered.includes(type)) {
        console.error(`  unknown: ${type} has a demo but is not a registered node type`);
        differences++;
      }
    }
  }

  if (differences > 0) {
    console.error(`\n${differences} node demo(s) out of date.`);
    console.error('Run: node tools/node-demos.mjs');
    process.exit(1);
  }
  console.log(`${built.size} node demos match.`);
} else {
  rmSync(target, { recursive: true, force: true });
  mkdirSync(target, { recursive: true });
  for (const [name, contents] of built) {
    writeFileSync(join(target, name), contents);
  }
  console.log(`${built.size} node demos written to examples/patches/nodes.`);
}

const verifyIndex = process.argv.indexOf('--verify');
if (verifyIndex >= 0) {
  const renderTool = process.argv[verifyIndex + 1];
  if (!renderTool) {
    console.error('--verify needs the path to sg-render');
    process.exit(2);
  }
  verify(renderTool);
}
