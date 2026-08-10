#!/usr/bin/env node
// Stamps the build and exports the Godot editor for the web, in that order.
//
//   node tools/export-web.mjs [--godot <path>] [--out <dir>]
//
// One command rather than two, because the two-command version has a failure mode that
// is exactly the thing the stamp exists to prevent: export without stamping and the
// bundle carries whatever stamp was lying around, which is a build claiming to be a
// different build. The recipe lives in a tool for the same reason the game sounds' does
// — a recipe that lives in somebody's shell history is a recipe that goes stale.

import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const argument = (flag, fallback) => {
  const index = process.argv.indexOf(flag);
  return index >= 0 ? process.argv[index + 1] : fallback;
};

// Godot is not on PATH on every machine this repository is used from; the Windows one
// keeps it in Downloads. Env first, then --godot, then the plain name.
const candidates = [
  process.env.SOUNDGRAPH_GODOT,
  argument('--godot', null),
  'godot',
].filter(Boolean);
const godot = candidates.find((path) => path === 'godot' || existsSync(path))
  ?? 'godot';

const out = resolve(argument('--out', join(root, 'build-godot-web')), 'index.html');

execFileSync(process.execPath, [join(root, 'tools', 'stamp-build.mjs'),
  '--target', 'web'], { stdio: 'inherit' });

// Relative to the project, because Godot resolves export paths from --path.
execFileSync(godot, ['--headless', '--path', join(root, 'editor-godot'),
  '--export-release', 'Web', out], { stdio: 'inherit' });

console.log(`exported to ${out}`);
