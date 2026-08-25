# editor-web

The zero-install doorway, and the reference frontend the Godot editor gets checked
against. Both open the same patch file and must mean the same thing by it.

This directory contains **no DSP**. The graph runs as WebAssembly compiled from the same
`dsp-core` that produces the native build.

```text
index.html / app.js        page, controls, keyboard, MIDI      main thread
graph-view.js              the patch, drawn: nodes and cables  main thread
onboarding.js / .css       the first two minutes               main thread
local-store.js             the four things this page remembers main thread
reporting.js               the only code here that posts       main thread
soundgraph.js              AudioContext + worklet + tooling    main thread
soundgraph-worklet.js      instantiates the module, renders    audio thread
soundgraph.wasm            dsp-core + patch-io                 built, not committed
```

## The picture

`graph-view.js` draws the patch above the JSON: nodes where the patch's own `position`
hints put them, cables weighted and dashed by the signal type the registry declares.
Selecting a node finds it in the text; moving a control lights the node it drives.

It is **read-only on purpose**. Rewiring belongs to the Godot editor, and a second program
with opinions about what a graph means is the thing this repository is arranged to avoid.
Without the WebAssembly module it still draws — it just cannot tell an audio cable from a
control one, and says so by drawing them all the same.

## The introduction

A first-time visitor gets `examples/patches/start-here.json` and a six-step tour: hear the
patch, read it left to right, drag the filter cutoff, hear the difference, decide what to
keep. Only the first screen is a modal — the rest are coach marks over a page that stays
usable. Progress lives in localStorage, **Help → Restart introduction** runs it again, and
the mailing-list panel cannot appear before the golden moment.

`node editor-web/verify-onboarding.mjs` holds the tour, the patch it teaches and the
measurement plan's ten event names against each other. It runs in the main ctest suite as
`web_onboarding_matches_its_patch`, and it exists because renaming a node in the patch would
otherwise leave the tour highlighting an empty set with no error anywhere.

## What leaves this page

Two POSTs, both to the Mutant Factory feedback service, both described in `reporting.js`:
one report per visit carrying how far the introduction got, and one when somebody joins the
mailing list. No patch contents, no audio, and no device data beyond a browser family.
Whatever origin serves this page must be named in that service's `ALLOWED_ORIGINS` —
`localhost` and `private` are already there, so a dev server works untouched.
`FUNNEL_REPORTS` turns the first one off; signups are separate.

Reports carry a build stamp, so write one before serving a build anybody will use:

```bash
node tools/stamp-build.mjs --target web-editor
```

Without it the page reports `development`, which is the truth when running from source.

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

## Deploying to hardware

In Chrome (Web Serial), a **Deploy to board** button appears next to Save. It validates
the patch, opens the serial port you pick, speaks the same `load` protocol as
`tools/esp32/sg-serial.py`, and stores the patch in the board's NVS — where it survives
power cycles. If the board rejects the patch, the board's own diagnostics render in the
problems panel, and they look identical to local ones because they come from the same
core. The button does not exist in browsers without Web Serial.

Close any serial monitor first; one process owns the port at a time.

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
