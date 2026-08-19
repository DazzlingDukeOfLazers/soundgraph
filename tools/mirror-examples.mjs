#!/usr/bin/env node
// Mirrors examples/patches into editor-godot/examples-mirror.
//
// Godot cannot read outside res://, so the editor project needs its own copy. That is two
// copies of the same files, which is a thing that goes wrong — and has, repeatedly:
//
//   1. The copy was a POST_BUILD step on the extension, so it only ran when the extension
//      relinked. Regenerating a patch left the editor showing the previous one.
//   2. Making it an always-run CMake target fixed that, in the Godot build directory —
//      which is a separate build nobody runs when only a patch has changed. Changing the
//      mapper and regenerating the corpus left the mirror stale all over again.
//
// So the sync lives here, out of any one build, and `--check` runs in the main test suite
// where a stale mirror will actually be noticed. It walks the tree rather than listing
// files, because a hand-maintained list is the same bug wearing a different hat.
//
//   node tools/mirror-examples.mjs [--check]

import { mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const source = join(root, 'examples', 'patches');
const target = join(root, 'editor-godot', 'examples-mirror');

function walk(directory) {
  const found = [];
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) found.push(...walk(path));
    else if (entry.name.endsWith('.json')) found.push(path);
  }
  return found;
}

const check = process.argv.includes('--check');
const files = walk(source);
let differences = 0;

for (const file of files) {
  const suffix = relative(source, file);
  const destination = join(target, suffix);
  const contents = readFileSync(file);

  if (check) {
    let mirrored = null;
    try {
      mirrored = readFileSync(destination);
    } catch {
      mirrored = null;
    }
    if (mirrored === null || !mirrored.equals(contents)) {
      console.error(`  stale: editor-godot/examples-mirror/${suffix.replace(/\\/g, '/')}`);
      differences++;
    }
  } else {
    mkdirSync(dirname(destination), { recursive: true });
    writeFileSync(destination, contents);
  }
}

// A file the editor still ships that the examples no longer have is the same problem
// pointing the other way, and a plain copy would never notice it.
const stragglers = walk(target)
  .map((file) => relative(target, file))
  .filter((suffix) => !files.some((file) => relative(source, file) === suffix));
for (const suffix of stragglers) {
  console.error(`  orphan: editor-godot/examples-mirror/${suffix.replace(/\\/g, '/')} ` +
    'has no source in examples/patches');
  differences++;
}

if (check) {
  if (differences > 0) {
    console.error(`\n${differences} mirrored example(s) out of date.`);
    console.error('Run: node tools/mirror-examples.mjs');
    process.exit(1);
  }
  console.log(`${files.length} examples mirrored correctly.`);
} else {
  if (stragglers.length > 0) process.exit(1);
  console.log(`${files.length} examples mirrored into editor-godot/examples-mirror.`);
}
