#!/usr/bin/env node
// Renders the visual-review matrix: every combination worth looking at before a design
// change is called done, in one pass, with an index page to look at them on.
//
//   node tools/screenshot-matrix.mjs [--godot <path>] [--out <dir>] [--only <substring>]
//
// The rule this exists to enforce is "do not approve a change on the 100% screenshot".
// That rule is unenforceable by good intentions: checking eight zooms across five themes
// and four views by hand is twenty-odd Godot launches, so in practice nobody does it and
// the 63% view quietly goes wrong — which is exactly what happened here. One command,
// one Godot process, one directory, one page.
//
// Not a pixel-diff regression suite, deliberately. Committing a few megabytes of PNGs
// that change with every font tweak would produce a check that fails constantly and
// therefore gets ignored; the assertions that *can* be mechanical already are, in
// design_test and editor_test. This is for the judgements that cannot: whether a compact
// node looks designed, whether a theme still reads, whether the piano is legible.

import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const argument = (flag, fallback) => {
  const index = process.argv.indexOf(flag);
  return index >= 0 ? process.argv[index + 1] : fallback;
};

// Same search as tools/export-web.mjs, and for the same reason: "godot" is not the name
// it is installed under on every machine this repository is used from.
const NAMES = ['godot', 'godot4', 'Godot_v4.7.1-stable_win64_console.exe',
  'Godot_v4.7.1-stable_win64.exe'];
const KNOWN = ['C:/Users/danie/Downloads/gofo/Godot_v4.7.1-stable_win64.exe',
  'C:/Users/danie/Downloads/gofo'];

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
  for (const candidate of [argument('--godot', null), process.env.SOUNDGRAPH_GODOT]
      .filter(Boolean)) {
    const found = binaryAt(candidate);
    if (found !== null) return found;
    console.error(`Godot was not found at ${candidate}.`);
    process.exit(1);
  }
  for (const name of NAMES) {
    try {
      execFileSync(name, ['--version'], { stdio: 'ignore' });
      return name;
    } catch { /* not under this name */ }
  }
  for (const candidate of KNOWN) {
    const found = binaryAt(candidate);
    if (found !== null) return found;
  }
  return null;
}

// The UI scale presets, by their index in Design.Scale.
const SCALE = { compact: 0, comfortable: 1, large: 2, xl: 3 };
const SCALE_LABEL = ['Compact 87%', 'Comfortable 100%', 'Large 115%', 'XL 135%'];
const THEMES = ['Lab', 'Night Flight', 'Tape', 'Paper', 'Maximum contrast'];

const shots = [];
const add = (group, name, shot) => shots.push({ group, name, ...shot });

// The zoom ladder, which is the axis the level-of-detail work lives on. 63% is in here
// as its own entry rather than rounded to 65: that is the zoom the compact band was
// silently failing at, and a ladder that steps over the number somebody reported is a
// ladder that will step over the next one too.
for (const zoom of [1.0, 0.75, 0.63, 0.5, 0.3]) {
  add('Zoom ladder', `graph ${Math.round(zoom * 100)}%`,
    { zoom, ui_scale: SCALE.comfortable });
}

// UI scale against graph zoom, which are the two settings the design brief insists are
// independent. The pairs are the ones where that independence is easiest to break: a
// large preference at a small zoom, where a screen-space floor can quietly erase it.
for (const scale of [SCALE.large, SCALE.xl]) {
  for (const zoom of [1.0, 0.63]) {
    add('UI scale', `${SCALE_LABEL[scale]} · graph ${Math.round(zoom * 100)}%`,
      { zoom, ui_scale: scale });
  }
}

// Every theme at the two zooms that matter: full detail, and the compact band where the
// words are being drawn by the overlay rather than by the labels themselves.
THEMES.forEach((theme, index) => {
  for (const zoom of [1.0, 0.63]) {
    add('Themes', `${theme} · graph ${Math.round(zoom * 100)}%`,
      { zoom, palette: index, ui_scale: SCALE.comfortable });
  }
});

// The other views, which have their own type and their own layout and are not covered by
// any amount of looking at the graph.
for (const view of ['Rack', 'Sandbox', 'Outline']) {
  add('Views', view, { view, ui_scale: SCALE.comfortable });
}

// The inspector in both of its states, and the piano in both of its.
add('Inspector', 'nothing selected', { zoom: 1.0, ui_scale: SCALE.comfortable });
add('Inspector', 'node selected', { zoom: 1.0, ui_scale: SCALE.comfortable,
  select: 'filter' });
add('Piano', 'idle', { zoom: 1.0, ui_scale: SCALE.comfortable });
add('Piano', 'note held', { zoom: 1.0, ui_scale: SCALE.comfortable, play: true });

// A big patch as well as a small one: the layout questions that only appear when there
// is enough graph to run out of room.
for (const zoom of [1.0, 0.63]) {
  add('Large patch', `DX7 algorithm 1 · graph ${Math.round(zoom * 100)}%`,
    { zoom, ui_scale: SCALE.comfortable, example: 'DX7: algo-01' });
}

const only = argument('--only', null);
const selected = only === null ? shots
  : shots.filter((shot) => `${shot.group} ${shot.name}`.toLowerCase()
      .includes(only.toLowerCase()));
if (selected.length === 0) {
  console.error(`No shots match "${only}".`);
  process.exit(1);
}

const godot = resolveGodot();
if (godot === null) {
  console.error('Could not find Godot.\n'
    + '  Set SOUNDGRAPH_GODOT to the binary, or pass --godot <path>.');
  process.exit(1);
}

const out = resolve(argument('--out', join(root, 'build-screenshots')));
rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });

const slug = (text) => text.toLowerCase().replace(/[^a-z0-9]+/g, '-')
  .replace(/^-|-$/g, '');
selected.forEach((shot, index) => {
  shot.file = `${String(index).padStart(2, '0')}-${slug(shot.group)}-${slug(shot.name)}.png`;
  shot.path = join(out, shot.file);
});

const spec = join(out, 'matrix.json');
writeFileSync(spec, JSON.stringify({ width: 1600, height: 1000, shots: selected }, null, 2));

console.log(`rendering ${selected.length} shots…`);
try {
  execFileSync(godot, ['--path', join(root, 'editor-godot'),
    '--script', 'res://screenshot.gd', '--', '--matrix', spec], { stdio: 'inherit' });
} catch (error) {
  console.error(`\nMatrix failed (${godot} exited ${error.status ?? 'abnormally'}).`);
  process.exit(1);
}

// An index rather than a folder of numbered files, because a matrix nobody can scan is
// a matrix nobody reads. Plain HTML with the images inline: no dependencies, opens in a
// browser, and the groups are the review order.
const groups = [];
for (const shot of selected) {
  let group = groups.find((entry) => entry.name === shot.group);
  if (group === undefined) {
    group = { name: shot.group, shots: [] };
    groups.push(group);
  }
  group.shots.push(shot);
}
const escape = (text) => text.replace(/&/g, '&amp;').replace(/</g, '&lt;');
const page = `<!doctype html>
<meta charset="utf-8">
<title>SoundGraph visual matrix</title>
<style>
  body { background: #0f1318; color: #f4f7fa; margin: 0 auto; max-width: 1700px;
         padding: 24px; font: 16px/1.5 "Atkinson Hyperlegible Next", system-ui, sans-serif; }
  h1 { font-size: 21px; } h2 { font-size: 17px; margin: 32px 0 8px; color: #b7c0cc; }
  figure { margin: 0 0 24px; }
  figcaption { font-size: 15px; padding: 8px 0; color: #f4f7fa; }
  img { width: 100%; display: block; border: 1px solid #3a4351; border-radius: 6px; }
  p { color: #b7c0cc; font-size: 15px; }
</style>
<h1>SoundGraph visual matrix</h1>
<p>${selected.length} shots, rendered ${new Date().toISOString().replace(/\.\d+Z$/, 'Z')}.
Scroll the whole page before approving a design change: the 100% view is the one least
likely to be wrong.</p>
${groups.map((group) => `<h2>${escape(group.name)}</h2>\n`
  + group.shots.map((shot) => `<figure><img src="${shot.file}" alt="${escape(shot.name)}">`
    + `<figcaption>${escape(shot.name)}</figcaption></figure>`).join('\n')).join('\n')}
`;
writeFileSync(join(out, 'index.html'), page);
console.log(`open ${join(out, 'index.html')}`);
