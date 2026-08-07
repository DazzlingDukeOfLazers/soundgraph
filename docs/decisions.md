# Decision Log

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
