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
import { existsSync, mkdirSync, statSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const argument = (flag, fallback) => {
  const index = process.argv.indexOf(flag);
  return index >= 0 ? process.argv[index + 1] : fallback;
};

// Godot is on the PATH on some of the machines this repository is used from and in a
// folder in Downloads on others, so the search is the same one tests/CMakeLists.txt
// already does rather than a second, different opinion about where Godot lives.
const NAMES = [
  'godot',
  'godot4',
  'Godot_v4.7.1-stable_win64_console.exe',
  'Godot_v4.7.1-stable_win64.exe',
];
const KNOWN = [
  'C:/Users/danie/Downloads/gofo/Godot_v4.7.1-stable_win64.exe',
  'C:/Users/danie/Downloads/gofo',
];

// A candidate can be a file, or — on the Windows box — a *directory* named like an
// executable with the real binaries inside it, which is how the download unpacked.
function binaryAt(candidate) {
  if (!existsSync(candidate)) return null;
  if (!statSync(candidate).isDirectory()) return candidate;
  for (const name of NAMES) {
    const inside = join(candidate, name);
    if (existsSync(inside) && !statSync(inside).isDirectory()) return inside;
  }
  return null;
}

function resolveGodot() {
  const explicit = [argument('--godot', null), process.env.SOUNDGRAPH_GODOT]
    .filter(Boolean);
  for (const candidate of explicit) {
    const found = binaryAt(candidate);
    if (found !== null) return found;
    console.error(`Godot was not found at ${candidate}.`);
    process.exit(1);
  }
  for (const name of NAMES) {
    try {
      execFileSync(name, ['--version'], { stdio: 'ignore' });
      return name;
    } catch { /* not on the PATH under this name */ }
  }
  for (const candidate of KNOWN) {
    const found = binaryAt(candidate);
    if (found !== null) return found;
  }
  return null;
}

// Resolved *before* stamping, on purpose. The first version stamped and then failed to
// find Godot, which left a stamp saying "web" behind on a machine where no web export
// had happened — a small version of the exact lie this whole feature exists to stop.
const godot = resolveGodot();
if (godot === null) {
  console.error('Could not find Godot.\n'
    + '  Set SOUNDGRAPH_GODOT to the binary, or pass --godot <path>.\n'
    + `  Tried on the PATH: ${NAMES.join(', ')}`);
  process.exit(1);
}

// The folder, not `out` itself — `out` is the index.html path, and a directory by that
// name would block the very file the export is trying to write.
const out = resolve(argument('--out', join(root, 'build-godot-web')), 'index.html');
mkdirSync(dirname(out), { recursive: true });

execFileSync(process.execPath, [join(root, 'tools', 'stamp-build.mjs'),
  '--target', 'web'], { stdio: 'inherit' });

try {
  execFileSync(godot, ['--headless', '--path', join(root, 'editor-godot'),
    '--export-release', 'Web', out], { stdio: 'inherit' });
} catch (error) {
  // A failed export with a Node stack trace on top of it tells you about child_process
  // rather than about the export, and the Godot output above already said what broke.
  console.error(`\nExport failed (${godot} exited ${error.status ?? 'abnormally'}).`);
  process.exit(1);
}

console.log(`exported to ${out}`);
