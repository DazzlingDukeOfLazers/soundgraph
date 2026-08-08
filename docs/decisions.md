# Decision Log

## 2026-08-08 — Auto-place is a pure function of the graph

Decision:
Auto-place arranges the whole graph and depends only on nodes, edges and widget sizes —
never on current positions and never on the selection. Arranging a selection is a separate
action with its own button.

Reason:
It previously switched to selection-only mode whenever two or more nodes were selected,
and a drag leaves what it dragged selected — so pressing the button after moving things
arranged a subset anchored to the rest, giving a different answer each time for reasons
invisible from outside. The layout algorithm itself was already deterministic; the button
was not. A tidy command whose meaning depends on hidden state is worse than no tidy
command.

Alternatives:
A modifier key for selection-only (still hidden state, just harder to trigger by accident);
keeping the automatic switch but announcing it (announcing a surprise is not the same as
removing it).

Consequences:
Two buttons instead of one. Three checks scatter the graph and re-arrange to prove the
answer does not move, and a fourth proves a lingering selection cannot change it.

## 2026-08-08 — The editor is set in Atkinson Hyperlegible

Decision:
The Godot editor uses Atkinson Hyperlegible Next at bold weight throughout, at sizes well
above the usual editor default, with high-contrast colours. The font is vendored under
`editor-godot/fonts/` with its OFL licence.

Reason:
`UX_PRINCIPLES.md` opens with "avoid tiny text, tiny hit targets, cryptic abbreviations,
and maximum-density layouts as the default", and the first pass wrote that down without
following it. Atkinson Hyperlegible exists specifically to keep `I l 1`, `O 0` and `b d`
apart at small sizes and for low vision, which is the same problem a dense patch editor
has for everyone.

Consequences:
Dimmed text is a lighter grey rather than white at reduced opacity — fading alpha costs
contrast twice, against the background and against neighbouring elements. 300 KB of
vendored font, which also has to be imported by Godot before the project will run.

## 2026-08-08 — The canvas draws its own grid

Decision:
GraphEdit's built-in grid is switched off and the canvas draws a three-tier grid whose
tiers are the layout's own pitches: faint at the snap step, medium at the row pitch, heavy
at the column pitch.

Reason:
GraphEdit draws minor lines at the snap distance and major lines at some multiple of it
that has nothing to do with the layout, which leaves you counting minor lines to find the
one you meant to align to. Making the heavy line *be* the column means "line it up with a
major line" and "put it where auto-place would" are the same instruction.

Consequences:
Two constants now have a visual meaning and cannot be changed casually. Loading a patch
also snaps every node and cable waypoint onto the grid, so a file from any source lands
where the grid says.

## 2026-08-28 — ESP-IDF v5.5, not v6.x

Decision:
The embedded target builds against ESP-IDF release/v5.5, installed at
`C:\Users\danie\esp-idf`.

Reason:
v6.0/v6.1 exist, but nearly all ESP32-S3 audio examples, community fixes and I2S
discussion target the v5.x line. Five weeks before a public demo is the wrong time to be
the first person hitting a new major version's I2S regressions.

Alternatives:
v6.1 (newest, least travelled); v5.3/v5.4 (older with no benefit over 5.5).

Consequences:
Revisit after Knobcon. The firmware uses only the std I2S driver, NVS and FreeRTOS tasks,
so a later major-version move should be small.

## 2026-08-28 — First board: generic DevKitC + PCM5102, chosen by Daniel

Decision:
The first embedded target is any ESP32-S3 DevKitC-style board wired to a PCM5102 I2S DAC
module (profile `esp32-s3-devkitc-pcm5102`). Pins and codec details live in `board.json`;
a header is generated from it at build time by `tools/board-generator`.

Reason:
It is the hardware on hand, it is the most common wiring in tutorials (good for the
"board support should create publishable work" goal), and the PCM5102 needs no I2C codec
init — the thinnest possible HAL for the first target.

Consequences:
No audio input on this profile, so the second vertical slice (live input through a delay)
waits for a codec board. The board.schema.json already models codecs and inputs.

## 2026-08-28 — On-device golden verification is host-driven

Decision:
The firmware embeds the golden case patches and exposes one dumb command —
`render <name> <frames> [events]` — streaming float32 samples back as per-line base64.
The host script (`tools/esp32/sg-serial.py verify-goldens`) reads `cases.json`, drives
the device case by case, and compares against `tests/golden/vectors/` at 1e-4.

Reason:
The device should not parse the manifest or store the vectors: that would be a second
copy of the test definition, on the target least convenient to update. Keeping the
device dumb means the manifest stays the single source of truth for native, WASM and
embedded alike.

Alternatives:
Comparing on device against vectors in flash (burns ~400 KB of flash and duplicates the
comparison logic); a fourth bespoke test format (no).

Consequences:
Verification needs a serial link and is slow (~30 s per long case at 115200 baud), which
is fine for a check that runs when the DSP changes, not on every build.

## 2026-08-21 — Godot talks to the core through a GDExtension, not a reimplementation

Decision:
`runtime-godot` is a GDExtension (godot-cpp) exposing a single `SoundGraphEngine` class
over the same `dsp-core` and `patch-io`. The editor asks it for the node vocabulary,
connection legality, validation results, and the signal on any wire. There is no DSP in
GDScript and no second copy of the node table.

Reason:
ARCHITECTURE.md says Godot is a UI and education frontend, not a graph authority. The way
that stops being a slogan is if the editor cannot answer a question about a graph without
asking the core. Adding a node type to `dsp-core` now makes it appear in Godot — ports,
units, ranges, enum labels, tooltips, search ranking — with no GDScript change.

Alternatives:
A pure-GDScript editor reading the schema (would need its own node table, which is the
duplication we are trying to avoid, and could not make sound); driving `sg-play` as a
subprocess (fragile for a live demo, and no signal inspection).

Consequences:
Godot needs a compiled binary per platform, so `editor-godot` cannot run from a fresh
clone until `runtime-godot` is built. The extension binary and the mirrored example
patches are build output, not repository content.

## 2026-08-21 — Cross-editor round trips are checked by rendering, not by diffing text

Decision:
`tools/verify-roundtrip.mjs` pushes each example through the Godot editor's real
load-and-save path, then renders the original and the result with `sg-render` and requires
the audio to be identical sample for sample.

Reason:
Two patch files can differ in key order, number formatting and whitespace while describing
the same graph — Godot writes `240.0` where the file said `240` — and can just as easily
look similar while describing different graphs. A textual comparison would fail on the
first difference and pass on the second, which is exactly backwards. Milestone C's exit
condition is about meaning, so the check has to be about meaning.

Alternatives:
Normalising both files and diffing (needs a canonical form we do not have a reason to
define yet); comparing parsed structures (closer, but still silent about whether a
difference matters).

Consequences:
The round-trip check needs a built `sg-render` and a Godot binary, so it is not part of
`ctest`. It is its own step, alongside `verify-goldens.mjs`.

## 2026-08-21 — Knob movement never rebuilds the graph

Decision:
Parameter changes in the Godot editor go straight to the running engine and are recorded
in the in-memory document. Only structural edits — add, delete, connect, disconnect —
re-serialise and reload the patch.

Reason:
UX_PRINCIPLES.md requires that ordinary edits not require compilation, and a reload
restarts every oscillator and empties every delay line. Turning a filter knob and hearing
the sound restart would undermine the central claim of the demo.

Alternatives:
Reloading on every change (simple, and audibly wrong); debouncing reloads (still audible,
just less often).

Consequences:
Two paths write to the document, so the serialiser reads slider values from the model
rather than the widgets. Widgets are set from the model at build time and never read back,
which also avoids a scaling round trip through the slider's 0..1 position introducing
drift into saved values.

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

## 2026-08-08 — The Godot editor ships as a web export, and the side module hides its symbols

Decision:
The Godot editor is exported to WebAssembly and served as a static page, so the demo
surface and the authoring tool are the same program. Every translation unit that ends up
in the extension is compiled `-fvisibility=hidden -fvisibility-inlines-hidden`.

Reason:
A Godot web export loads a GDExtension as an Emscripten `SIDE_MODULE`. Any symbol left at
default visibility joins the dynamic symbol table, and Emscripten then emits code that is
*statically linked into the module* as an import: the first build asked `env` for
`_ZN10soundgraph16GraphDescriptionD2Ev` and `std::to_string`. Godot cannot supply those, so
the loader substitutes a stub of another arity, and the first indirect call through it
aborts the engine with `function signature mismatch` — a message that names neither the
symbol nor the module. godot-cpp puts `-fvisibility=hidden` in `target_link_options`
(`cmake/web.cmake`), where it has no effect; visibility is fixed when a translation unit is
compiled. A stock GDExtension never trips this because it uses only Godot's own `String`.
This one links the C++ standard library, so it does.

Two further constraints, both load-bearing:
the extension must be built against the *same* Emscripten as the export template
(4.7.1 is 4.0.20 — `Build configuration:` in the browser console states it), and against
godot-cpp's `template_release`, because a release export looks up the `template_release`
feature tag. Mismatching either fails the same way.

Alternatives:
Serving the plain `editor-web` page as the demo (a different, lesser editor, and a second
UI to maintain); a native build behind a download (not a URL, so not zero-install).

Consequences:
Imports dropped from 410 to 64 and the module went from a hard abort to a clean boot. First
load is ~46 MB uncompressed, ~10 MB gzipped — whatever hosts it must serve compressed. The
export is `nothreads`, so no SharedArrayBuffer and no cross-origin isolation headers, which
is what keeps it servable from any static host. Browser audio still needs a user gesture,
and `AudioStreamGenerator` warns that it cannot be sampled on the web path — the audio
route through the exported editor is not yet verified.
