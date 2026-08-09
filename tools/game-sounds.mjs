#!/usr/bin/env node
// Rebuilds examples/patches/game/ from the sfxr corpus.
//
// These eight files are generated, but until now the recipe lived only in the shell
// history of whoever made them. That is the same trap as a hand-copied source list: two
// things that have to agree, and no way to notice when they stop. Changing the mapper
// meant the corpus was regenerated and these were not, so a jump in the sandbox and a
// jump in the test rig were quietly different sounds.
//
// The mapping below is the record. Each game sound is a corpus case picked for how it
// sounds, so this file is the only place a taste decision is stored — which is why it is
// a table and not a search.
//
//   node tools/game-sounds.mjs [--check]
//
// --check regenerates into memory and fails if the committed files differ, which is what
// CI runs.

import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');

/** Game sound -> the corpus case it was chosen from, and what to call it. */
const SOUNDS = [
  { file: 'coin.json', case: 'pickup-coin-0', description: 'Picking something up.' },
  { file: 'explode.json', case: 'explosion-0', description: 'Something blowing up.' },
  { file: 'hurt.json', case: 'hit-hurt-2', description: 'Taking damage.' },
  { file: 'jump.json', case: 'jump-5', description: 'Jumping.' },
  { file: 'jump2.json', case: 'jump-0', description: 'The second jump of a double jump.' },
  { file: 'powerup.json', case: 'powerup-0', description: 'Getting a power-up.' },
  { file: 'select.json', case: 'blip-select-1', description: 'Moving through a menu.' },
  { file: 'shoot.json', case: 'laser-shoot-0', description: 'Firing a shot.' },
];

const check = process.argv.includes('--check');
let differences = 0;

for (const sound of SOUNDS) {
  const source = join(root, 'tests', 'sfxr', 'patches', `${sound.case}.json`);
  const target = join(root, 'examples', 'patches', 'game', sound.file);

  // A text substitution rather than a parse and re-serialise, so every byte outside the
  // metadata block is the mapper's own output. Re-serialising would work too, and would
  // rewrite all eight files whenever anything about JSON.stringify differed from the C++
  // writer — a diff that says everything changed is a diff nobody reads.
  const corpus = readFileSync(source, 'utf8');
  const name = sound.file.replace(/\.json$/, '');
  const description = `${sound.description} Generated from sfxr case ${sound.case} by ` +
    'tools/game-sounds.mjs. Do not edit by hand.';
  const metadata = [
    '  "metadata": {',
    `    "name": "${name}",`,
    `    "description": "${description}",`,
    '    "tags": ["sfxr", "game"]',
    '  },',
  ].join('\n');

  const block = /^ {2}"metadata": \{\n(?: {4}.*\n)+ {2}\},$/m;
  if (!block.test(corpus)) {
    console.error(`  ${sound.case}.json has no metadata block this script recognises.`);
    console.error("  The mapper's output format changed; update tools/game-sounds.mjs.");
    process.exit(1);
  }
  const rendered = corpus.replace(block, metadata);

  if (check) {
    let committed = null;
    try {
      committed = readFileSync(target, 'utf8');
    } catch {
      committed = null;
    }
    if (committed !== rendered) {
      console.error(`  stale: examples/patches/game/${sound.file}`);
      differences++;
    }
  } else {
    writeFileSync(target, rendered);
    console.log(`  ${sound.file}  <- ${sound.case}`);
  }
}

if (check) {
  if (differences > 0) {
    console.error(`\n${differences} game sound(s) do not match the corpus.`);
    console.error('Run: node tools/game-sounds.mjs');
    process.exit(1);
  }
  console.log(`${SOUNDS.length} game sounds match the corpus.`);
} else {
  console.log(`\n${SOUNDS.length} game sounds written.`);
}
