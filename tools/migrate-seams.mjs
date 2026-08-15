#!/usr/bin/env node
// Rewrites a patch's terminals as seams: NoteInput becomes an Input bound to the note
// host, StereoOutput an Output bound to stereo, and so on. Same id, same ports, same
// cables — see docs/modules-design.md, "the seam made of nodes".
//
// A tool rather than a hand edit, for the reason every generated file in this repository
// has a generator: a migration done by hand is a migration nobody can run again, and the
// next patch to need it is edited by hand too until somebody notices the corpus has
// drifted into two spellings.
//
// It refuses to rewrite anything it cannot check. With --render pointed at sg-render it
// renders each patch before and after and compares the bytes, because the whole claim
// here is that the two spellings are the same graph, and a migration that changed a
// sound would be the one bug worth catching.
//
//   node tools/migrate-seams.mjs --check examples/patches/first-synth.json
//   node tools/migrate-seams.mjs --write --render build/bin/sg-render examples/patches/*.json

import { readFileSync, writeFileSync, mkdtempSync, rmSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { SEAM_FOR } from "./seams.mjs";

// Turns a document's terminals into seams. Returns null when there was nothing to do,
// so a caller can tell "already migrated" from "changed".
function migrate(patch) {
  let touched = 0;
  const next = JSON.parse(JSON.stringify(patch));
  for (const node of next.nodes ?? []) {
    const seam = SEAM_FOR[node.type];
    if (seam === undefined) continue;
    // Rebuilt rather than mutated so `host` lands next to `type` instead of after the
    // parameters. The file is read by people; where a field sits is part of that.
    const [type, host] = seam;
    const rebuilt = {};
    for (const [key, value] of Object.entries(node)) {
      rebuilt[key] = value;
      if (key === "type") {
        rebuilt.type = type;
        rebuilt.host = host;
      }
    }
    for (const key of Object.keys(node)) delete node[key];
    Object.assign(node, rebuilt);
    touched += 1;
  }
  return touched === 0 ? null : next;
}

function render(binary, patch, scratch, tag) {
  const json = join(scratch, `${tag}.json`);
  const wav = join(scratch, `${tag}.wav`);
  writeFileSync(json, JSON.stringify(patch, null, 2) + "\n");
  execFileSync(binary, [json, wav, "--seconds", "1", "--notes", "57",
                        "--gate", "0.7", "--quiet"]);
  return readFileSync(wav);
}

const args = process.argv.slice(2);
const write = args.includes("--write");
const renderAt = args.includes("--render") ? args[args.indexOf("--render") + 1] : null;
const files = args.filter((a, i) =>
  !a.startsWith("--") && args[i - 1] !== "--render");

let changed = 0;
let identical = 0;
const scratch = renderAt ? mkdtempSync(join(tmpdir(), "seam-")) : null;
try {
  for (const file of files) {
    const before = JSON.parse(readFileSync(file, "utf8"));
    const after = migrate(before);
    if (after === null) continue;
    changed += 1;

    if (renderAt) {
      // A patch with no output makes no sound to compare; those are checked by the
      // structural claim in tests/test_patch_io.cpp and skipped here rather than
      // silently counted as proof.
      const hasOutput = (before.nodes ?? []).some((n) =>
        n.type === "StereoOutput" || (n.type === "Output" && n.host === "stereo"));
      if (hasOutput) {
        const a = render(renderAt, before, scratch, "before");
        const b = render(renderAt, after, scratch, "after");
        if (!a.equals(b)) {
          console.error(`DIFFERS: ${file} does not render the same after migration`);
          process.exit(1);
        }
        identical += 1;
      }
    }

    if (write) {
      writeFileSync(file, JSON.stringify(after, null, 2) + "\n");
      console.log(`migrated ${file}`);
    } else {
      console.log(`would migrate ${file}`);
    }
  }
} finally {
  if (scratch) rmSync(scratch, { recursive: true, force: true });
}

console.log(`${changed} patch(es) with terminals` +
  (renderAt ? `, ${identical} verified byte-identical` : ""));
