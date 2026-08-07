# Current Phase

**Milestone F — Hardware Escape (Knobcon critical path)** — complete.
Knobcon week 4 (Aug 28–Sep 3, 2026). Branch `milestone-f-esp32`.

## Exit condition: met

The Waveshare ESP32-S3-AUDIO-Board plays `first-synth.json` through its speaker from
power-on, patches deploy over serial into NVS and survive power cycles, and all ten
golden cases rendered on device match the native vectors:

```text
python tools/esp32/sg-serial.py --port COM3 verify-goldens
  worst case  delay-feedback  1.90e-5   (tolerance 1e-4)
  bit-exact   noise, lfo
```

One graph model now behaves identically (within declared tolerances) under four
compilers on four architectures: MSVC/x64, Clang/WASM, GCC/Godot, Xtensa/ESP32-S3.

## Board

Planned: `esp32-s3-devkitc-pcm5102`. Actually shipped first: `esp32-s3-audio-board`
(Waveshare smart-speaker kit, Daniel's hardware) — which exercised the codec path, an
amp-enable behind an I/O expander, and proved the board-as-manifest promise: the swap
cost one board.json and one codec-init module, no firmware fork. The DevKitC+PCM5102
profile remains and is untested on hardware.

Milestone D (automation) is a roadmap item but not on the Knobcon path; it waits.

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

## Verified on hardware

- Boot-to-sound: the arpeggio (8-note pattern, runtime-settable, `bpm`/`vol` commands)
  plays from power-on with no host attached.
- Serial console bidirectional over the board's USB port; patch deploy to NVS works.
- All ten golden cases within 1e-4 of the native vectors (worst 1.9e-5).
- Host tooling is self-contained: the repo's `.venv` (pyserial + esptool) can flash the
  firmware and drive the board with no ESP-IDF environment.

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
