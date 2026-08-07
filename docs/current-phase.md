# Current Phase

**Milestone A — Graph Makes Sound**
Knobcon week 1 (Aug 7–13, 2026).

## Goal

```text
patch JSON -> validation -> DSP graph -> scheduler -> offline render -> native live audio
```

Exit condition: a saved SoundGraph patch produces deterministic audio with no UI dependency.

## Done

- [x] Monorepo scaffold
- [x] `schema/patch.schema.json` (schema_version 1)
- [x] `dsp-core` types, node API, registry
- [x] Initial node vocabulary — 16 types
- [x] Graph validation + topological scheduler + feedback cutting
- [x] `patch-io` JSON load/save with a self-contained parser
- [x] `sg-validate` and `sg-render`
- [x] 82 unit tests and 10 golden vectors, all passing
- [x] `examples/patches/first-synth.json` renders correct pitches and envelope
- [x] `examples/patches/delay-echo.json` exercises graph-level feedback
- [x] Native live audio (`sg-play`) with an arpeggiator and a typed command console

Milestone A is complete: a saved patch produces deterministic audio with no UI dependency,
offline and through a real device.

## Not yet exercised

- macOS and Linux builds. The CMake and miniaudio setup covers them but nothing has been
  compiled there yet.
- Live audio *input*. `sg-play --capture` de-interleaves and feeds `AudioInput`, but no
  hardware test has been run.

## Next phase

**Milestone B — Browser Runtime** (Aug 14–20): same `dsp-core` compiled to WASM, running
in an AudioWorklet, matching native output within declared tolerances.

## Invariants being protected

- `dsp-core` depends on nothing but the C++ standard library.
- JSON never enters `dsp-core`; `patch-io` translates at the edge.
- No allocation, locks, or I/O in steady-state `process()`.
