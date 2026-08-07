# Current Phase

**Milestone F — Hardware Escape (Knobcon critical path)**
Knobcon week 4 (Aug 28–Sep 3, 2026). Branch `milestone-f-esp32`.

## Goal

One ESP32-S3 board: board profile, I2S HAL, patch loader, runtime, deployment, physical
audio. Exit: the same first-synth graph makes sound on real S3 hardware, and the golden
cases rendered on device match the native vectors within 1e-4.

Milestone D (automation) is a roadmap item but not on the Knobcon path; it waits.

## Board

`esp32-s3-devkitc-pcm5102` — a generic DevKitC wired to a PCM5102 I2S DAC (Daniel's
hardware, chosen 2026-08-28). Wiring table in embedded/README.md.

## Done

- [x] ESP-IDF v5.5 installed at `C:\Users\danie\esp-idf` (S3 toolchain)
- [x] `schema/board.schema.json` — boards as manifests, never as forks
- [x] `tools/board-generator` — board.json → generated C header
- [x] `embedded/components/soundgraph-core` — the same dsp-core + patch-io sources as an
      IDF component, `SOUNDGRAPH_NO_FILE_IO`, no embedded fork
- [x] `embedded/esp32-s3` generic firmware: I2S out, boot-to-sound arpeggiator, serial
      console (notes, parameters, `load` → NVS deployment surviving power cycles,
      `render` streaming for verification)
- [x] `tools/esp32/sg-serial.py` — deploy, play, and `verify-goldens` driving the shared
      cases.json manifest against the native vectors

## In progress / blocked

- [ ] **Firmware compiles** — first `idf.py build` is running; everything above is
      written against IDF v5.5 but not yet compiled. One configure-time bug already
      found and fixed (include dir must exist before `idf_component_register`).
- [ ] **Nothing has touched hardware.** Flash, physical audio, and the on-device golden
      run all need the DevKit + PCM5102 wired and plugged in — see the wiring table in
      embedded/README.md.

## Next phase

Sep 4 is feature freeze; Sep 5–10 hardening and demo prep (see KNOBCon_2026.md). After
the board makes sound, the remaining critical-path item is demo reliability — "can this
work thirty consecutive times in front of strangers".

## Invariants being protected

- `dsp-core` depends on nothing but the C++ standard library — the IDF component compiles
  the identical sources, it does not copy them.
- The board profile alters pins and peripherals, never graph semantics.
- The golden manifest is the single definition of correctness for native, WASM and
  embedded; the device stays too dumb to have its own copy.
