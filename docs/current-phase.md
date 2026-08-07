# Current Phase

**Milestone B — Browser Runtime**
Knobcon week 2 (Aug 14–20, 2026). Branch `milestone-b-browser`.

## Goal

```text
same dsp-core -> WASM -> AudioWorklet -> live browser audio
```

Exit condition: native and browser behaviour match within declared tolerances.

## Done

- [x] Emscripten 6.0.6 installed at `C:\Users\danie\emsdk` (no permanent PATH changes)
- [x] `runtime-wasm` — flat `extern "C"` API over `dsp-core` + `patch-io`, no JS glue,
      zero imports, ~180 KB
- [x] `patch-io` file entry points excluded from targets without a filesystem
- [x] `write_registry` / `write_diagnostics` — the node vocabulary and validation results
      as JSON, so frontends reuse the core instead of reimplementing it
- [x] Golden cases converted to ordinary patches driven by a shared manifest
- [x] AudioWorklet processor, DSP entirely off the main thread
- [x] Web host page: load/save patch, live controls generated from the patch's own control
      surfaces, on-screen and computer keyboard, Web MIDI, peak meter, execution-order and
      cost readout
- [x] `runtime-wasm/verify-goldens.mjs` — the exit condition, runnable headlessly

## Exit condition: met

All 10 golden cases match the native vectors within 1e-5:

```text
exact  saw, square, noise, noise-pink, lfo, adsr, delay-feedback
ok     sine          5.96e-8
ok     filter-sweep  1.79e-7
ok     first-synth   2.09e-7
```

Seven of ten are bit-identical between MSVC/x64 and Clang/WASM. The three that differ all
use `sin` or `tan`, where the two libms disagree in the last mantissa bits — five orders
of magnitude inside tolerance.

Verified in the browser: execution order, feedback-edge detection and cost estimate are
identical to what `sg-validate --explain` reports natively, for both example patches; the
note lifecycle produces silence → attack → release → exact silence; and a zero-delay cycle
surfaces the same spatial, actionable diagnostic the native validator produces.

## Not yet exercised

- **Visual inspection of the page.** The browser pane in this environment does not
  composite frames, so the layout was verified functionally (element by element) rather
  than by looking at it. Someone should open it and actually look.
- Safari and Firefox. Only one engine has run this.
- Web MIDI with real hardware.
- `AudioInput` in the browser — `getUserMedia` is not wired up, so `delay-echo.json` loads
  and schedules correctly but has nothing to process.

## Next phase

**Milestone C — Two Editors** (Aug 21–27): the Godot graph editor, checked against this
web frontend. Both open the same file and must preserve semantics. `write_registry` is
what Godot should build its palette from.

## Invariants being protected

- `dsp-core` depends on nothing but the C++ standard library.
- JSON never enters `dsp-core`; `patch-io` translates at the edge.
- No allocation, locks, or I/O in steady-state `process()`.
- No DSP in JavaScript. The browser is a host, not a second implementation.
