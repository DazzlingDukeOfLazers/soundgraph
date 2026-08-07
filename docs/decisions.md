# Decision Log

## 2026-08-14 — Golden vectors are patches, not test code

Decision:
Every golden case is an ordinary patch under `tests/golden/cases/`, listed in
`tests/golden/cases.json` with its frame count and note events. The native test, the
WebAssembly verifier and eventually the embedded runner all read that one manifest.

Reason:
Milestone B's exit condition is "native and browser behave the same". That is only
checkable if both are rendering provably the same thing. When the cases lived in C++ test
code, a WASM runner would have had to reimplement them, and the reimplementation is
exactly where a discrepancy would hide.

Alternatives:
Exporting a test harness from the wasm module (ships test code in the shipped binary);
comparing only end-to-end patches (would not cover individual nodes).

Consequences:
Node-level cases need a patch that routes the node to a `StereoOutput` at unity level with
the limiter off, so the recording is the raw node output. Converting the existing vectors
this way reproduced nine of ten bit-for-bit, which was itself a useful check.

## 2026-08-14 — The browser build ships no JavaScript glue

Decision:
`runtime-wasm` builds a bare `.wasm` with `-sSTANDALONE_WASM --no-entry` and a flat
`extern "C"` API. There is no emscripten glue file; the worklet instantiates the module
by hand. The module has zero imports and is about 180 KB.

Reason:
The DSP has to run inside an `AudioWorklet`, and `AudioWorkletGlobalScope` has no `fetch`,
no module imports and no dependable `TextDecoder`. Emscripten's glue assumes several of
those. Hand-instantiating a module with no imports is less code than working around the
glue, and it fails in obvious ways instead of subtle ones.

Alternatives:
`-sMODULARIZE -sSINGLE_FILE` concatenated ahead of the processor (fragile, and the glue
still probes for environment features that a worklet lacks); emscripten's `-sAUDIO_WORKLET`
integration (ties the architecture to emscripten's audio abstractions, which we do not
want on the critical path to ESP32).

Consequences:
JavaScript does its own string marshalling. All text crosses the worklet port as bytes,
encoded and decoded on the main thread.

## 2026-08-14 — A WebAssembly.Module cannot be sent to an AudioWorklet

Decision:
The main thread posts the wasm **bytes** to the worklet, which compiles its own copy at
start-up, rather than compiling once and posting the `WebAssembly.Module`.

Reason:
An `AudioWorkletGlobalScope` is a separate agent cluster, so a `Module` fails to
structured-clone into it — and it fails silently. `postMessage` does not throw, no error
event fires, and the message simply never arrives; the processor sits there looking dead.
This cost real debugging time, which is why it is written down.

Alternatives:
Compiling on the main thread and transferring (does not work, as above); fetching inside
the worklet (there is no `fetch` there).

Consequences:
A one-off compile of ~180 KB on the audio thread at start-up, before any rendering block.
Synchronous compilation is permitted off the main thread, so this is legal and quick.

## 2026-08-14 — Fixed WebAssembly heap, and controls bound to integer handles

Decision:
The module is built with `ALLOW_MEMORY_GROWTH=0` and a 32 MB heap. Control surfaces are
resolved to an integer handle once when a patch loads; moving a knob sends only that
handle and a float.

Reason:
A growing heap detaches every `Float32Array` view the worklet holds, and re-deriving those
views on the audio thread is a bug waiting to happen. Binding controls once keeps string
marshalling off the audio thread entirely. 32 MB leaves room for roughly eighty
maximum-length delay lines.

Alternatives:
Growable memory with view invalidation on every call (more moving parts in the one place
that must not fail); passing parameter names on every knob event (allocation and encoding
per frame of a drag).

Consequences:
A patch needing more than 32 MB will fail to load rather than growing. If that ever
happens the number moves; it is one line.

## 2026-08-07 — Monorepo with `dsp-core` as the semantic authority

Decision:
Single repository laid out as in ARCHITECTURE.md. `dsp-core` is a standalone C++17 static
library that depends on nothing but the standard library. Every other component
(`patch-io`, `runtime-native`, tools, later WASM/Godot/embedded) is a consumer.

Reason:
The core success condition is that one graph behaves the same in radically different
environments. That only holds if exactly one component decides what a graph means.

Alternatives:
Separate repos per component (premature — no stable API yet); letting the native host own
the scheduler (would fork semantics per target immediately).

Consequences:
`dsp-core` cannot use JSON, filesystem, threads, or logging. Anything requiring those
lives in a wrapper. Adding a node means touching the registry in one place.

## 2026-08-07 — JSON stays out of `dsp-core`; `patch-io` translates at the edge

Decision:
`dsp-core` consumes a plain-struct `GraphDescription`. A separate `patch-io` library
parses patch JSON into that struct and serialises it back.

Reason:
Embedded targets will likely receive a pre-compiled/serialised graph rather than parsing
JSON on device, and the WASM build should not pay for a JSON parser it does not need.
Keeping the boundary explicit means the embedded path is a new `GraphDescription`
producer rather than a fork of the runtime.

Alternatives:
Load JSON directly in the runtime (simpler now, couples the core to a text format and a
third-party parser forever).

Consequences:
Two representations to keep in sync. The schema file is the contract between them; a
round-trip test guards it.

## 2026-08-07 — Hand-written JSON reader/writer instead of a third-party parser

Decision:
`patch-io` ships a small self-contained JSON parser (`json.hpp`, ~400 lines) rather than
vendoring nlohmann/json or fetching a dependency at configure time.

Reason:
Zero network requirement at build time, no submodule, and it compiles unmodified for
ESP32 and WASM. The patch format is small and fully specified by us, so the parser only
needs to be correct, not general-purpose-fast.

Alternatives:
nlohmann/json (MIT, excellent, but ~900 KB header and heavy for embedded); ArduinoJson
(embedded-friendly, awkward on host); CMake FetchContent (needs network during configure,
which breaks offline demo prep before Knobcon).

Consequences:
We own JSON bugs. Mitigated by round-trip and malformed-input tests. The parser is
confined to `patch-io` and can be swapped without touching `dsp-core`.

## 2026-08-07 — Fixed 64-frame internal block size, buffers owned by the scheduler

Decision:
The graph processes in fixed blocks of 64 frames internally. The scheduler pre-allocates
one buffer per connection-carrying output port at `prepare()` time; hosts with a different
callback size are adapted by an outer loop in the host, not by reallocating.

Reason:
Guarantees no allocation in steady state, keeps control-rate/audio-rate interaction
predictable, and gives embedded targets a small, known working set. A block size that
divides typical host buffers (128/256/512) avoids partial-block edge cases in practice,
and the host adapter handles the rest.

Alternatives:
Per-sample processing (simple, far too slow on ESP32); variable block size matching the
host (couples buffer sizing to the host and complicates golden tests).

Consequences:
Golden tests are deterministic regardless of host buffer size. Delay lines and modulation
smoothing are specified in samples, not blocks, so block size does not alter semantics.

## 2026-08-07 — miniaudio for the native host, vendored not fetched

Decision:
`runtime-native` uses miniaudio (v0.11.25), vendored as a single header under
`runtime-native/third_party/miniaudio/`. It is compiled in its own translation unit with
warnings off.

Reason:
It is a single file, dual licensed public domain / MIT-0 (so no attribution obligation
and no licence contamination), and it covers WASAPI, CoreAudio and ALSA — which is
exactly the desktop set the roadmap asks for. Vendoring rather than fetching means the
repo builds with no network, which matters for demo prep the week of Knobcon.

Alternatives:
RtAudio (more dependencies, GPL-adjacent history); PortAudio (build system baggage);
writing a WASAPI host directly (fast to a Windows demo, no macOS path).

Consequences:
4 MB of vendored header in the repo. It is confined to `runtime-native` — `dsp-core` and
`patch-io` do not see it, and the browser and embedded targets will not use it at all.

## 2026-08-07 — The graph always runs whole blocks, behind an output FIFO

Decision:
`Graph::render` never processes a partial block. It runs whole `kBlockSize` blocks and
serves the host out of a small FIFO.

Reason:
Anything decided at block rate — filter coefficients today, more later — would otherwise
shift depending on the host's buffer size, and two hosts would render the same patch
differently. That would quietly destroy the ability to compare native, WASM and ESP32
output against one golden vector.

Alternatives:
Processing short final blocks (simpler, but makes output host-dependent); requiring hosts
to use a multiple of 64 (not something we can require of a DAW or an AudioWorklet).

Consequences:
Up to one block of latency between the host asking and the graph running. A test asserts
that rendering in 4800, 64 and 37 frame chunks produces byte-identical output.

## 2026-08-07 — Feedback requires an explicit delay element

Decision:
Zero-delay cycles are a validation error. A cycle is legal only if it passes through a
node that declares a one-block latency break (currently `Delay`). The error names every
node in the offending loop and suggests inserting a delay.

Reason:
ARCHITECTURE.md requires it, and silently accepting cycles would make output depend on
node evaluation order — which would differ per target and destroy the core promise.

Alternatives:
Implicit unit-delay insertion (hides a real design decision from the user and changes
timing invisibly); solving cycles numerically (out of scope).

Consequences:
The second vertical slice (delay with feedback) must route feedback through the `Delay`
node, which is the intended design anyway.
