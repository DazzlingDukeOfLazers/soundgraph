#!/usr/bin/env node
// Holds every page of every merged DX7 bank to its own voice file: applying the
// page's values through the bank's controls and rendering must give the same
// bytes as rendering the voice's exact import. The bank is a re-filing of the
// cartridge, not an arrangement of it — and this is the check that keeps the
// word "re-filing" honest. It can only hold for banks whose families differ in
// nothing the face's controls miss, which the shipped family-demos bank is
// authored to guarantee; a user's cartridge may morph between pages that also
// differ in detune or LFO, and those land close rather than exact.
//
//   node tools/dx7-bank-check.mjs

import { execFileSync } from 'node:child_process';
import { readdirSync, readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const patches = join(root, 'examples', 'patches', 'dx7');
const bin = join(root, 'build', 'bin');
const scratch = mkdtempSync(join(tmpdir(), 'dx7-bank-'));
// The scratch dir dies with the process: two thousand of these
// leaked across a day of gate runs once filled the disk to zero.
process.on('exit', () => rmSync(scratch, { recursive: true, force: true }));

const slug = (name) => name.toLowerCase().replace(/[^a-z0-9]+/g, '-')
  .replace(/^-|-$/g, '') || 'unnamed';

const render = (patchPath, wavPath) => execFileSync(join(bin, 'sg-render'),
  [patchPath, wavPath, '--seconds', '1', '--notes', '57', '--gate', '0.7', '--quiet']);

let banks = 0;
let pages = 0;
let failures = 0;
for (const file of readdirSync(patches).filter((f) => f.endsWith('.json')).sort()) {
  const bank = JSON.parse(readFileSync(join(patches, file), 'utf8'));
  if (!Array.isArray(bank.presets) || bank.presets.length < 2) continue;
  banks += 1;
  const controls = new Map((bank.controls ?? []).map((c) => [c.id, c]));
  for (const page of bank.presets) {
    pages += 1;
    const applied = JSON.parse(JSON.stringify(bank));
    delete applied.presets;
    const nodes = new Map(applied.nodes.map((n) => [n.id, n]));
    for (const [id, value] of Object.entries(page.values ?? {})) {
      const control = controls.get(id);
      const node = control ? nodes.get(control.target.node) : null;
      if (!node) continue;
      (node.parameters ??= {})[control.target.parameter] = value;
    }
    const id = slug(page.name);
    const appliedPath = join(scratch, `${id}-page.json`);
    writeFileSync(appliedPath, JSON.stringify(applied));
    const pageWav = join(scratch, `${id}-page.wav`);
    const voiceWav = join(scratch, `${id}-voice.wav`);
    render(appliedPath, pageWav);
    render(join(patches, `${id}.json`), voiceWav);
    if (!readFileSync(pageWav).equals(readFileSync(voiceWav))) {
      console.error(`  differs: ${file} page "${page.name}" vs ${id}.json`);
      failures += 1;
    }
  }
}

if (failures > 0) {
  console.error(`${failures} page(s) do not render as their own voice.`);
  process.exit(1);
}
if (banks === 0) {
  console.error('no merged banks found — the importer stopped merging families.');
  process.exit(1);
}
console.log(`${pages} pages across ${banks} merged banks render byte-identical `
  + 'to their voice files.');
