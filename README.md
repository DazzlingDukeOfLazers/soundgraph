# SoundGraph

An open visual audio-programming platform from Mutant Factory.

The central artifact is a portable **sound graph** — not a UI, plugin format, operating
system, or piece of hardware. The same graph should run in a browser, a desktop app, a
DAW plugin, and on cheap embedded hardware.

> One graph behaves consistently in multiple radically different execution environments.

## Layout

```text
docs/            plan, architecture, roadmap, decisions, current phase
schema/          canonical patch / board / control JSON schemas
dsp-core/        portable C++ DSP nodes, graph validation, scheduler (no UI, no JSON, no OS)
patch-io/        patch JSON <-> dsp-core graph description
runtime-native/  native live-audio host
runtime-wasm/    WebAssembly binding, plus the native/browser comparison runner
runtime-godot/   GDExtension binding for the Godot editor
editor-web/      zero-install browser frontend, DSP in an AudioWorklet
editor-godot/    primary visual editor, DSP in the same core via GDExtension
tools/           sg-validate, sg-render command line tools
examples/        example patches and reference audio
tests/           golden vectors and integration tests
```

`dsp-core` owns graph semantics. Everything else is an edge.

## Build

Requires CMake 3.20+ and a C++17 compiler.

```bash
cmake -S . -B build
cmake --build build --config Release
ctest --test-dir build -C Release --output-on-failure
```

## Try it

Validate and render the first example synth patch to a WAV file:

```bash
./build/tools/sg-validate examples/patches/first-synth.json
./build/tools/sg-render examples/patches/first-synth.json out.wav --seconds 3
```

Play it live through your default audio device:

```bash
./build/runtime-native/sg-play examples/patches/first-synth.json
```

## In the browser

The same core, compiled to WebAssembly and run in an AudioWorklet. There is no DSP in
JavaScript.

```bash
emcmake cmake -S . -B build-wasm -DCMAKE_BUILD_TYPE=Release && cmake --build build-wasm
python -m http.server 8177
```

Then open <http://127.0.0.1:8177/editor-web/>. See [editor-web/README.md](editor-web/README.md).

To check that the browser build still sounds like the native one:

```bash
node runtime-wasm/verify-goldens.mjs
```

## In Godot

The visual editor. Same core again, this time through a GDExtension — there is no DSP in
GDScript, and no second copy of the node vocabulary.

```bash
cmake -S runtime-godot -B runtime-godot/build -DCMAKE_BUILD_TYPE=Release
cmake --build runtime-godot/build
```

Then open `editor-godot/` in Godot 4.7. See [editor-godot/README.md](editor-godot/README.md).
Opening the project once registers the extension; from a script, run
`godot --headless --path editor-godot --import` first.

To check that a patch survives a trip through the editor unchanged:

```bash
node tools/verify-roundtrip.mjs
```

## On hardware

The same core again, as ESP-IDF firmware. A board plays its patch from power-on with no
host attached, and a patch deployed over serial survives power cycles.

```bash
C:\Users\danie\esp-idf\export.bat
cd embedded/esp32-s3 && idf.py -DSG_BOARD=esp32-s3-audio-board build flash monitor
```

See [embedded/README.md](embedded/README.md).

## Status

Milestones A, B, C and F are complete. **One graph model behaves identically, within
declared tolerances, under four compilers on four architectures** — MSVC/x64, Clang/WASM,
GCC/Godot and Xtensa/ESP32-S3 — judged by one shared manifest against one set of recorded
vectors.

| target | worst difference from the native vectors |
|---|---|
| WebAssembly | 2.09e-7 (tolerance 1e-5) |
| ESP32-S3 | 1.90e-5 (tolerance 1e-4) |

Now in Knobcon hardening. See [docs/current-phase.md](docs/current-phase.md).
