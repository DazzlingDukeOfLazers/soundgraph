# Current Phase

**Milestone C — Two Editors** — complete.
Knobcon week 3 (Aug 21–27, 2026). Branch `milestone-c-editors`.

## Goal

A simple web reference editor and a Godot primary editor, both opening and saving the same
graph and preserving semantics. The web editor landed in Milestone B; this phase is the
Godot editor and the proof that the two agree.

## Exit condition: met

A patch edited in the web editor opens in Godot and vice versa.

```text
node tools/verify-roundtrip.mjs
  ok  first-synth.json   identical audio, 7 nodes, controls 7/7, metadata 5/5
  ok  delay-echo.json    identical audio, 6 nodes, controls 4/4, metadata 5/5
```

Checked by rendering rather than by diffing text: each patch goes through the Godot
editor's real load-and-save path, then the original and the result are rendered with
`sg-render` and required to be identical sample for sample.

Closed the other way too — a patch written by Godot was fed back to the native validator
and to the browser WebAssembly engine, and all three produce the same execution order
(`note → lfo → osc → env → filter → amp → out`) and the same cost estimate.

## Done

- [x] `dsp-core`: `Graph::port_signal` — read-only access to the buffers that already
      exist, so an editor shows what is on a wire instead of re-deriving it
- [x] `runtime-godot`: `SoundGraphEngine` GDExtension over the same core — registry,
      intent search, validation, notes, parameters, audio, scope, per-port signal
- [x] `editor-godot`: GraphEdit view generated from the registry, typed ports with units
      written out, parameter widgets from declared ranges and enums, progressive
      disclosure of advanced parameters, live audio, computer-keyboard playing
- [x] Intent search using the core's ranking, spatial diagnostics, signal scope
- [x] `editor-godot/editor_test.gd` — 30 headless checks on the editor itself
- [x] `tools/verify-roundtrip.mjs` — the exit condition

All four suites pass:

```text
ctest --test-dir build                  4/4 suites
node runtime-wasm/verify-goldens.mjs    10/10 cases within 1e-5
godot --script res://editor_test.gd     30/30 checks
node tools/verify-roundtrip.mjs         2/2 patches, identical audio
```

## Not yet exercised

- **The Godot editor has never been looked at either.** Everything is verified headlessly;
  nobody has opened the project and seen the graph render, dragged a wire, or heard it
  through a real device. The same is still true of the web page.
- Godot on macOS and Linux. The extension builds only on Windows so far.
- Deleting nodes, dragging connections, and the search popup are implemented and unit
  covered at the model level, but no human has clicked them.

## Next phase

Per KNOBCon_2026.md, **Aug 28–Sep 3 is the hardware escape** — one ESP32-S3 board, board
profile, codec/I2S HAL, patch loader, deployment. That is the critical path. Milestone D
(automation) is on the roadmap but not on the Knobcon path.

The groundwork that matters for embedded is already in place: the golden cases are
ordinary patches driven by a shared manifest, so an ESP32 runner compares against exactly
the vectors native and WebAssembly already agree on.

## Invariants being protected

- `dsp-core` depends on nothing but the C++ standard library.
- JSON never enters `dsp-core`; `patch-io` translates at the edge.
- No allocation, locks, or I/O in steady-state `process()`.
- No DSP in JavaScript and none in GDScript. Both editors are hosts.
- Neither editor keeps its own copy of the node vocabulary, the search ranking, or the
  validator. There is nothing for them to drift from.
