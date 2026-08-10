# Decision Log

## 2026-08-09 — The sfxr oracle carries its own sine

Decision:
`sfxr_reference.cpp` calls `portable_sin()` instead of the C library's `sin()`. Cody-Waite
reduction onto [-pi/4, pi/4] with a three-part pi/2, then Taylor kernels to x^17 and x^16.
`laser-shoot-4` and `laser-shoot-5` were regenerated; the manifest did not change.

Reason:
`sfxr_corpus_is_reproducible` regenerates the corpus and compares it byte for byte, which
is what makes it a fixed target rather than a moving one. That promise was already kept
against the C library's PRNG and not against its libm. On Apple silicon the two vectors
with `wave_type == 2` came out different: Apple's `sin` and Microsoft's disagree by about
one ULP, and the low-pass filter's feedback grows that to roughly eight float ULPs over a
render. It is the same defect as `rand()`, one function along, and it has the same fix.

Alternatives:
Allow a tolerance on the vectors — rejected: the test would stop proving byte identity,
and a real one-ULP synthesis bug could then hide behind the allowance. Skip the test on
macOS — rejected: that converts a finding into a silence. Leave it failing — rejected once
the fix was measured, because a permanently red test teaches people to ignore the suite.

Consequences:
The oracle is now bit-identical on every platform, which is what the rig assumed all
along. It is no longer bit-identical to a libm-based sfxr: `portable_sin` is within
2.2e-16 of Apple's libm across the range sfxr uses, and the two regenerated vectors moved
by at most 5.2e-8 — 0.00003% of peak, some twenty-four bits down. Every golden comparison
in the rig is measured in tolerances far larger than that. The cost is roughly forty lines
of numerics in a file whose whole value is being checkable, which is why the series is
Taylor rather than fitted: anyone can re-derive it.

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

## 2026-08-08 — The rack is a second view, not a second editor

Decision:
`editor-godot/rack.gd` draws the current patch as a Eurorack case, in a tab beside the
graph view. It reads the same document, the same registry descriptors and the same
layering, and writes parameter changes back through the same path. Module order comes from
`layout.gd` — the layering the graph view already computed — rather than a second
algorithm, and a module's knobs and jacks are whatever the node's descriptor says it has.

Reason:
A signal-flow graph is the honest picture of what the core does, but a rack is the picture
musicians can already read, and the hunch is that it is the one that stops people walking
past a stand. Both can be true at once, so both are drawn. Making the rack an editor in its
own right would have meant a second place where a patch can be built, and eventually two
places that disagree about what a patch is.

Cables can hang as a catenary or route orthogonally, on a toolbar toggle that both views
honour, so the comparison is between two ways of drawing a cable rather than between two
views that happen to differ. Which one wins is a question for people at Knobcon, not for
argument now — hence the toggle rather than a choice.

The catenary is solved properly (`a·cosh(x/a)`, with `a` found by bisection from the
requested sag) rather than faked with a parabola. The shape is the entire reason the view
exists; a cable that hangs correctly is what makes a rack read as an instrument rather than
a diagram. Between jacks at different heights the curve is sheared to meet both ends, which
is an approximation — the exact answer is a plain catenary with its low point off-centre,
found by a second solve for arc length, for a difference invisible at these spans.

Alternatives:
A rack-only editor (throws away the graph, which is the thing that generalises to DAW and
firmware); a toggle between views rather than tabs (makes it a mode, and modes are the
thing you cannot A/B side by side).

Consequences:
Ten more editor checks, 78 in total. Dragging a cable waypoint is a PCB-mode gesture: a
hanging cable has no corners to grab, which is part of what the A/B is trading. The rack
does not yet repatch — connections are made in the graph view — which is the obvious next
piece if the rack wins.

## 2026-08-08 — Five shaping nodes, in seconds and hertz rather than sfxr's units

Decision:
`AhdEnvelope`, `Slide`, `Arpeggio`, `Phaser` and `Retrigger` join the vocabulary, and
`SquareOscillator` and `StateVariableFilter` gain `pulse_width_sweep` and `cutoff_sweep`.
Twenty-one node types, up from sixteen. Every one is expressed in the units the rest of the
vocabulary already uses; none of them knows that sfxr exists.

Reason:
A graph could not previously say the things a game sound says — "drop the pitch fast",
"jump up a fifth after 40 ms", "do that again every 100 ms". The vocabulary was built for
held notes, where pitch comes from a keyboard and an envelope sustains until the key is
released. A coin sound has no key and no sustain.

Shaping them to sfxr would have been quicker and wrong. sfxr's envelope stage length is
`p² × 100000` in samples at a fixed 44100 Hz; its frequency ramp is a per-sample multiplier
on a period. Those numbers mean nothing to somebody dragging nodes around, and they would
have made the nodes useless for anything but reproducing sfxr. The conversion belongs in
the mapper from a preset to a patch, which is one place, rather than smeared through seven
node implementations.

`AhdEnvelope` sits beside `ADSR` rather than replacing it. ADSR is the wrong shape here,
not a worse one: it is built around a note being let go.

`Retrigger` is a separate node rather than a property of the envelope, because *what*
restarts is a decision per patch — sfxr's repeat restarts the pitch but not the amplitude,
and being able to say that by wiring one gate and not the other is what having a graph is
for.

Alternatives:
An `Sfxr` node that took the twenty-four parameters directly (one node nobody could edit,
and the one sound in the project that is not a graph); reproducing sfxr's units (fast to
write, incomprehensible to use).

Consequences:
Both sweeps default to zero and take the old code path exactly when they are zero, so every
patch already written renders the same samples — the golden vectors check it. Six new golden
cases, sixteen in total, all matching between MSVC/x64 and Clang/WASM. Thirteen new node
tests, 47 in total.

`cutoff_sweep` advances once per block. That is deliberate — it keeps a transcendental out
of the inner loop, which is what would cost on ESP32 — and it stays host-buffer independent
because `graph.cpp` calls every node with exactly `kBlockSize` frames behind the output
FIFO. The rate is correct at any block size; only the granularity follows the block.

The ESP32 has not run the six new vectors yet. It needs the board flashed, and that is a
person with a cable, not a build step.

## 2026-08-08 — A threshold measured against what is possible, not chosen

Decision:
`NoiseOscillator` joins the vocabulary: noise with a pitch, a short random table read once
per cycle. `Slide` widens from +/-240 to +/-9600 semitones per second. And the sfxr
report's spectral threshold is `max(6 dB, floor + 1.5)` per case, where the floor is
measured on every run by rendering sfxr twice with different noise seeds.

Reason:
sfxr's noise is not noise. It is a random *wavetable* played at the oscillator's pitch, and
`Noise` is white and unpitched, so the seven noise cases were not merely inaccurate — they
were a different kind of signal. Building the node took their median spectral distance from
22.6 dB to 7.1 dB. It is also the retro sound-chip noise channel, which is worth having on
its own account.

The `Slide` range was the more embarrassing find. +/-240 semitones per second was chosen as
"surely nobody needs twenty octaves a second". Twelve of the forty-one cases exceeded it and
every hit-hurt case did, and because parameters clamp on load, the patch carried the right
number and the sound came out ten times too slow. A percussive hit lasts a few milliseconds
and its pitch has to collapse inside that; -2000 semitones per second is under an octave in
5 ms, which is an ordinary drum, not an extreme.

The threshold is the part worth defending. Two runs of sfxr itself, on the same sound with a
different noise draw, sit 4.7 to 6.1 dB apart — so a flat 6 dB threshold was demanding that
noise be reproduced better than sfxr reproduces itself. Raising it *because cases were
failing* would be moving the goalposts. Raising it to a separately measured floor is not:
the same measurement returns exactly 0.00 dB for every deterministic waveform, which is what
makes it trustworthy, and the threshold is unchanged at 6 dB for all of them.

Alternatives:
A pitched mode on `Noise` (overloads a node whose whole character is being unpitched);
storing the floor in the manifest (goes stale silently); leaving noise failing (hides real
progress behind a number that could never be reached).

Consequences:
24 -> 32 of 41. Three new node tests, 50 in total; a seventeenth golden vector, matching
between MSVC/x64 and Clang/WASM. The ratchet moves to 32.

It also caught its own wiring: under ctest the working directory differs, the default
relative path to sfxr-ref did not resolve, every floor came back zero, and four cases were
held to a threshold nothing could meet. The report said "regression" when the port had not
changed. That failure is now loud rather than a silent fallback.

Still open: sfxr's highpass is one-pole and `StateVariableFilter` is two-pole, which is
30 dB of difference at the frequency floor and the whole of the remaining error on the two
worst hit-hurt cases.

## 2026-08-08 — A one-pole filter beside the two-pole one

Decision:
`OnePoleFilter` joins the vocabulary: 6 dB per octave, lowpass or highpass, with the same
cutoff sweep as `StateVariableFilter`. The sfxr mapping uses it for the highpass stage.
Twenty-three node types.

Reason:
sfxr's highpass is `fltphp += fltp - pp; fltphp -= fltphp * flthp` — a DC blocker, one
pole. `StateVariableFilter` is two. Near the cutoff the difference is invisible; far from
it, it is everything. sfxr's hit-hurt sounds slide down to a 3.5 Hz floor two hundred times
below their highpass corner, where one pole takes about 32 dB off and two take about 63, so
our rendering was 30 dB quieter than sfxr's for most of the sound. `hit-hurt-5` went from
an envelope distance of 67 dB to 3.1.

A gentler slope is also not a worse filter. It thins or warms without carving a hole, and
blocking DC is what most hardware puts in front of an output — the node earns its place
whatever sfxr does.

Alternatives:
A slope parameter on `StateVariableFilter` (a two-pole topology asked to be one pole is a
special case in the inner loop, and the two have genuinely different state).

Consequences:
Three new node tests, 53 in total, one of which pins the thing that matters: two octaves
below a highpass corner, one pole must be at least three times louder than two. An
eighteenth golden vector, matching between MSVC/x64 and Clang/WASM.

The count stayed at 32 of 41, which is worth stating plainly: the fix moved one case from
catastrophically wrong to 0.19 dB short of passing, and moved the generator's median from
9.6 dB to 6.8, without crossing a threshold. A ratchet that only counts passes would have
recorded nothing.

`hit-hurt-4` is now explained rather than fixed. It differs from sfxr by a fraction of a
cycle after 60 ms of continuous pitch sliding — integer phase accumulation against float —
and below the highpass corner a single square edge landing one window later swings the
envelope metric by more than 20 dB. The pitch trajectories match; the phase does not.

## 2026-08-08 — Compute from a sample count, do not accumulate

Decision:
`Slide` and `Phaser` derive their swept quantity from a sample counter rather than adding a
small step every sample. Both stay in float.

Reason:
The ESP32 disagreed with MSVC on exactly these two of the eighteen golden cases, at 1.03e-4
and 1.42e-4 against a 1e-4 tolerance. Where they failed said why: the slide parted company
at sample 32455 of 36000 while matching at the start, which is accumulated rounding error
growing with the total; the phaser failed at sample 1177, which is not.

Adding `rate * dt` every sample lets the error grow with the number of samples. The closed
form of the same integral — `(slide + acceleration*t/2) * t` — is one multiply-add and its
error is a fixed ulp rather than a growing one. For the phaser it matters more sharply than
that: a swept delay reads its line at a fractional position, so a few ulps can land on the
other side of a sample boundary and interpolate between a different pair, which is a step
rather than a nudge.

Deliberately still float. The ESP32-S3 emulates doubles in software, and buying agreement
with a per-sample double add on the audio path is the wrong trade when a better formula
costs nothing — it is both faster, having no loop-carried dependency, and more accurate.

Alternatives:
Raising the ESP32 tolerance (hides a real defect and makes every future comparison weaker);
double accumulators (real cost on the target that needs the cycles most).

Consequences:
The slide's worst-case device difference fell from 1.03e-4 to 4.77e-6, and the phaser's from
1.42e-4 to 9.16e-5. All eighteen golden cases now agree across MSVC/x64, Clang/WASM and
Xtensa/ESP32-S3. Two vectors were re-recorded; both are unchanged in character.

The phaser remains the worst case by an order of magnitude, and that is inherent: fractional
delay has a discretisation cliff that no amount of precision removes, only makes rarer.

## 2026-08-08 — Web playback must be asked for as a stream

Decision:
Every `AudioStreamPlayer` sets `playback_type = AudioServer.PLAYBACK_TYPE_STREAM`.

Reason:
Godot's project setting `audio/general/default_playback_type.web` is 1, and that enum is
`Stream, Sample` — so the web default is **Sample**, which pre-bakes a stream into a buffer.
An `AudioStreamGenerator` has no samples until something asks for them, so it cannot be
baked. The result is a warning and silence, on the web only; every desktop build sounds
fine, which is what let it survive from the first web export until now.

Setting it on the player rather than flipping the project setting: it is the line that
explains itself at the place that depends on it, and a project setting is invisible from
the code it changes.

Consequences:
The warning is gone from the exported build. That is evidence the sample path is no longer
being taken; it is not yet evidence of sound.

## 2026-08-08 — What "verify the audio" turned out to require

Measured, so the remaining gap is precise rather than vague: in the exported build Godot
creates **no AudioContext at all** and never fetches its audio worklets until the page has
had a real user gesture. Instrumenting `AudioContext` and `AudioNode.prototype.connect`
before the engine loads shows zero contexts, zero connections and no worklet requests after
thirty seconds.

Synthetic events do not lift it. Dispatching pointerdown, mousedown, click, touchstart and
keydown at the canvas, the document and the window changes nothing, and
`navigator.userActivation.hasBeenActive` stays false — which is the actual gate. Notably a
context created from the console *is* immediately `running`, so this is not the browser's
autoplay policy: it is Godot waiting for interaction before starting its driver at all.

So this last step cannot be automated from here. It needs a person to click the page once.
The tap above is the way to read the answer when they do: it reports the peak amplitude
actually reaching the speakers, rather than asking someone whether they think they heard
something.
