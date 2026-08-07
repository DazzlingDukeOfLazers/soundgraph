# editor-web

The zero-install doorway, and the reference frontend the Godot editor gets checked
against. Both open the same patch file and must mean the same thing by it.

This directory contains **no DSP**. The graph runs as WebAssembly compiled from the same
`dsp-core` that produces the native build.

```text
index.html / app.js        page, controls, keyboard, MIDI      main thread
soundgraph.js              AudioContext + worklet + tooling    main thread
soundgraph-worklet.js      instantiates the module, renders    audio thread
soundgraph.wasm            dsp-core + patch-io                 built, not committed
```

## Build and run

The `.wasm` is a build artifact and is not in the repository. Build it first:

```bash
emcmake cmake -S . -B build-wasm -DCMAKE_BUILD_TYPE=Release && cmake --build build-wasm
```

That writes `editor-web/soundgraph.wasm`. Then serve the **repository root** — the page
loads example patches from `../examples/patches/`:

```bash
python -m http.server 8177
```

and open <http://127.0.0.1:8177/editor-web/>.

A plain `file://` open will not work: the module is fetched, and AudioWorklet modules need
an http origin.

## Verifying it against the native build

```bash
node runtime-wasm/verify-goldens.mjs
```

Renders every case in `tests/golden/cases.json` through the WebAssembly module and
compares it to the vectors the native build recorded. Most cases come out bit-identical;
the ones using `sin`/`tan` differ in the last mantissa bits because the two libms differ.

## Two things worth knowing before editing the worklet

**A `WebAssembly.Module` cannot be posted to an AudioWorklet.** An
`AudioWorkletGlobalScope` is a separate agent cluster, so the structured clone fails — and
it fails *silently*: `postMessage` does not throw and the message simply never arrives.
The bytes are posted instead and compiled in the worklet, which is allowed off the main
thread. If the worklet ever goes quiet with no error, suspect this first.

**Strings are encoded on the main thread.** `TextEncoder` and `TextDecoder` are not
dependable in an `AudioWorkletGlobalScope`, so anything textual crosses the port as bytes.
Control changes avoid strings entirely: each control is bound once to an integer handle at
load time, and knob movement sends only that handle and a float.
