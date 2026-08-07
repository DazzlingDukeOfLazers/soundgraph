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

## Status

Milestone A — *Graph Makes Sound*. See [docs/current-phase.md](docs/current-phase.md).
