# Schema-level modules — design

A module is a named subgraph with declared ports, defined once inside a patch and
instantiated as an ordinary node. This document is the design: what changes in the
schema, where expansion happens, what every target sees, and the staged plan with an
exit test per stage. Stage 1 is implemented; see the staged plan below.

## Why now, and why not before

`module_import.gd` records the standing decision: *"There is no sub-graph in the patch
format and there deliberately is not going to be one: a nested graph is a second thing
every target has to understand, and the promise is that one file runs everywhere."*
That decision was right when it was made, and its two concerns still bind:

1. one file must run on every target unchanged, and
2. opening a patch must never mean resolving links to files you may not have.

What changed is measured, not felt. The DX7 import produces 33-node documents whose
readability sits at the packing-density floor — the modular *layout* recovered what
layout can (three rows of emergent tiles at ~68% packing efficiency) and its ceiling is
now known. The repetition is not visual: a DX7 voice **is** six instances of one
subcircuit, the importer knows it at generation time, and the document format is the
only place that knowledge cannot currently be written down. Meanwhile the "second thing
every target has to understand" objection turns out to name one function in one place:
**every target — native, WASM, the Godot extension, the ESP32 firmware — links the same
patch-io** (`embedded/components/soundgraph-core` compiles it verbatim). Expansion
implemented in patch-io's loader is implemented everywhere, once.

So the design keeps both original concerns intact:

- **Definitions are inline.** A module lives in the same file that uses it. No
  external references, no resolution, no registry. Concern 2 holds by construction.
- **dsp-core never learns.** patch-io flattens instances into plain nodes before
  `Graph::build` runs. The engine, the scheduler, the golden manifest, the firmware's
  steady state: all unchanged. Concern 1 holds because the runtime document model is
  exactly what it is today.

A module is therefore a **notation**, not a runtime object — the same relationship a
`for` loop has to its unrolled body. That is deliberately modest, and it is enough:
notation is what the 33-node problem is made of.

## The schema

Two additions, both illustrated with the real DX7 operator:

```json
{
  "schema_version": 2,
  "modules": {
    "operator": {
      "description": "One DX7 operator: pitch ratio, sine, envelope, VCA.",
      "nodes": [
        { "id": "pitch", "type": "Multiply", "parameters": { "factor": 1.0 } },
        { "id": "osc",   "type": "SineOscillator", "parameters": {} },
        { "id": "env",   "type": "ADSR", "parameters": { "attack": 0.01 } },
        { "id": "vca",   "type": "Multiply", "parameters": {} }
      ],
      "connections": [
        { "from": { "node": "pitch", "port": "out" }, "to": { "node": "osc", "port": "frequency" } },
        { "from": { "node": "osc",   "port": "out" }, "to": { "node": "vca", "port": "a" } },
        { "from": { "node": "env",   "port": "out" }, "to": { "node": "vca", "port": "b" } }
      ],
      "inputs": [
        { "name": "note",  "node": "pitch", "port": "a" },
        { "name": "gate",  "node": "env",   "port": "gate" },
        { "name": "pm",    "node": "osc",   "port": "pm" }
      ],
      "outputs": [
        { "name": "out", "node": "vca", "port": "out" }
      ],
      "parameters": [
        { "name": "ratio",    "node": "pitch", "parameter": "factor" },
        { "name": "feedback", "node": "osc",   "parameter": "feedback" }
      ]
    }
  },
  "nodes": [
    { "id": "note", "type": "NoteInput", "parameters": {} },
    { "id": "op1", "type": "module", "module": "operator",
      "parameters": { "ratio": 1.0 } },
    { "id": "op2", "type": "module", "module": "operator",
      "parameters": { "ratio": 3.0, "feedback": 0.4 } }
  ],
  "connections": [
    { "from": { "node": "note", "port": "frequency" }, "to": { "node": "op1", "port": "note" } },
    { "from": { "node": "op2",  "port": "out" },       "to": { "node": "op1", "port": "pm" } }
  ]
}
```

Rules, each one a validator check:

- **`type: "module"` + `module: <name>`** — an instance is an ordinary entry in
  `nodes`, connected by its declared port names. Everything downstream of validation
  (controls, automation, arrangement) refers to instances like any node.
- **Declared surface only.** An instance exposes the module's `inputs`, `outputs` and
  `parameters` — nothing else. Reaching into `op1.osc` from outside the definition is
  invalid. The facade is the point: six knobs a voice actually wants, not thirty.
- **Exported parameters** behave exactly like node parameters: an instance's
  `parameters` values override the definition's inner defaults, per instance. Controls
  and automation may target them.
- **No modules inside modules** in this version. Definitions instantiate node types
  only. This removes recursion, makes the expansion bound `instances × definition
  size`, and postpones a real question (below) rather than answering it badly.
- **`schema_version: 2` iff the document contains modules.** A module-free document
  is byte-for-byte a v1 document, forever. Version is a capability floor, and the
  existing contract — "a runtime must refuse a patch whose schema_version it does not
  implement" — gives old runtimes a loud, clean refusal instead of a silent
  misreading. `patch.schema.json` grows the `modules` section and conditionally
  permits `"module"` type, so conforming validators agree with ours (the slash-in-ids
  lesson: our parser must never be the lenient one).

## Expansion

In patch-io, at parse time, before `GraphDescription` reaches `Graph::build`:

- Instance `op1` of `operator` becomes nodes `op1.pitch`, `op1.osc`, … — the dot
  separator is `ModuleImport.SEPARATOR`, already legal in the id charset and already
  the convention the import feature established.
- Inner connections are copied per instance. Boundary connections re-target through
  the port declarations (`op1`/`note` → `op1.pitch`/`a`).
- Exported parameter values overwrite the inner node's parameter in that instance.
- Diagnostics and `get_info` speak flattened ids. `op1.osc` is self-explanatory to a
  person, and the editor can fold anything left of the dot back onto the instance.

`GraphDescription` carries the hierarchy (definitions + instance nodes) and exposes a
flattened view for building; `write_patch` writes the hierarchy back. **Round-trip
preserves the module structure** — flattening is for the engine, never for the file.

Device note: expansion allocates during *load*, which is where allocation already
lives. The steady-state invariant (no allocation, locks, or I/O in `process()`) is
untouched. The abuse suite gains: unknown module name, undeclared port, duplicate
export names, module-typed node inside a definition, and an expansion-size bomb
(instances × nodes over the existing engine cap must refuse, not exhaust the heap).

## What the editor does with it

- **Stage A (with stage 1 below):** an instance renders as one GraphNode with the
  declared ports and exported parameters — the tiles the modular layout discovers
  today become real, collapsible objects. The layout treats instances as nodes; the
  18-node threshold suddenly means "big patches get modularized by their *author*."
- **Collapse selection into module:** the editor's inverse operation — selected nodes
  become a definition, their boundary edges become declared ports, the selection
  becomes an instance. `ModuleImport` stays as-is (import-by-copy is still right for
  *foreign* patches) and gains a sibling: import as definition.
- **Editing a definition** edits every instance; the undo model is already
  document-snapshot-based, so this costs nothing new. Entering a definition
  (double-click) to edit it in place is a later stage; the first editing surface is
  the inspector on the instance plus expand-in-place read-only.

## Staged plan, with exit tests

> **Stage 1 landed.** parse/validate/expand/write in patch-io; schema updated; the
> documented abuses refuse with named diagnostics; all 32 demo voices render
> byte-identical flat vs modular (in ctest as modules_flatten_to_identical_audio);
> and a schema-v2 modular document deployed to the ESP32-S3 over serial expanded
> on-device — every target speaks modules because every target links the loader.

1. **patch-io + schema:** parse, validate, expand, write. *Exit:* the DX7 importer
   emits `algo-01` as one `operator` definition + six instances, and its flattened
   render is **byte-identical** to today's flat document's render — the golden
   comparison is the proof that notation changed and sound did not. Abuse cases
   above. All targets re-verified (same patch-io everywhere; ESP32 flashed).
2. **Editor rendering:** instances as single nodes; layout consumes them; round-trip
   through the editor preserves definitions. *Exit:* editor_test loads the modular
   algo-01, sees ~10 top-level nodes, saves, and the file still has its `modules`
   section; fit lands materially above the measured 23% floor.
3. **Authoring:** collapse-selection, import-as-definition, exported-parameter
   editing in the inspector. *Exit:* a round trip of collapse → save → load → expand
   reproduces the original wiring.
4. **DX7/OPL importers emit modules by default** once 1–2 are proven.

## Deferred, deliberately

- **Cross-file module libraries** — reintroduces concern 2; if it ever comes, it
  comes as *vendoring on import* (copy the definition in), never as live links.
- **Nested modules** — wanted eventually (a DX7 voice inside a performance patch);
  needs a recursion budget and better diagnostics; not worth designing until stage 3
  usage exists.
- **Runtime modules** (dynamic voice allocation, per-instance bypass) — a different
  feature wearing the same name; nothing in this design blocks it, nothing requires
  it.
