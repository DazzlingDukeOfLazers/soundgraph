# Decision Log

## 2026-08-25 — Three surfaces, one patch, and the light one is the front door

Decision:
SoundGraph is presented as three surfaces rather than merged into one program:
`/soundgraph` (this page — marketing and onboarding, ~400 KB), `/soundgraph/editor` (the
Godot editor exported to WebAssembly, ~10 MB gzipped), and `/soundgraph/desktop` (the
application). They are declared in `editor-web/surfaces.js` with URLs that default to
null; an unconfigured surface is announced but not linked. The patch travels between them
through `soundgraph.handoff.v1` in localStorage, and `/soundgraph` now leads with the pitch
and the graph, with the JSON source collapsed below.

Reason:
They cannot be one bundle. A Godot web export is one engine plus one `.pck`; there is no
way to lazy-load half of Godot. But they are already one *product*, because the patch is
the canonical artifact and both surfaces get every answer about it from the same
`dsp-core` — so "open this there" needs no protocol beyond leaving the document somewhere
both can read. Same origin makes localStorage that somewhere.

The light page stays the front door because the gap is 400 KB against 10 MB, and by
`editor-godot/README.md` the export is cached from the *second* visit, not the first.
Putting ten megabytes in front of the first sound is exactly what the two-minute
introduction exists to prevent.

**The full editor must be hosted BELOW this page.** The export ships a service worker whose
scope is the directory it is served from, cache-first with no revalidation, updates landing
a visit late. At or above `/soundgraph` it would take control of the marketing page and
make it one that cannot be reliably updated. `verify-onboarding.mjs` fails a configured URL
that is absolute or escapes upwards.

Alternatives:
Replace the light page with the export — rejected: kills the zero-install doorway. Bring
the editing features into `editor-web` — rejected by the architecture rule against a second
program with opinions about what a graph means. One shell swapping the two in iframes —
rejected for now: two audio engines in one document is the failure mode that produced two
graphs both connected to the destination, and it took a day to find.

Consequences:
Nothing is deployed yet, so all three URLs are null and the page currently says "not yet"
twice, honestly. The prefetch that warms the full editor after the golden moment is written
but its file list is empty on purpose — the names come from the Godot export, and guessing
them would produce a prefetch that fetches nothing while appearing to work.

Moving the pitch onto the page also fixed a real bug it uncovered: controls drive the
engine, not the document, so saving, downloading or handing off a patch carried the values
it loaded with and silently discarded every knob the visitor had moved — including the one
the golden moment is built on.

## 2026-08-25 — The web editor draws the graph, and still does not edit it

Decision:
`editor-web/graph-view.js` renders the patch as nodes and typed cables, above the JSON
pane. Read-only: selecting a node finds it in the text, moving a control lights the node it
drives, and nothing adds, removes or rewires anything. Layout uses the patch's own
`position` hints; cable weight and dash come from the registry's port types.

Reason:
The onboarding has to be able to say "the filter" and point at something. Before this, the
page knew every fact about a graph and could not show one — execution order was a line of
text and a control was labelled `filter.cutoff` without saying where that was. The claim
the whole project is built on is that SoundGraph exposes relationships, and the zero-install
doorway was the one surface that did not.

Alternatives:
Put the onboarding in the Godot editor instead, which already draws graphs — rejected for
now: it is a 46 MB first load, it is already Knobcon-critical, and the About copy says the
dedicated graph editor is still in development. Point the coach marks at the controls panel
only — rejected: the golden moment's second half is *understanding where the change
happened*, and that needs a picture.

Consequences:
Two programs now draw a graph. This one is deliberately the lesser: no editing, no palette,
no layout engine, and it reads the registry rather than keeping its own vocabulary, so a
node added to the core appears here without JavaScript changing. If it ever grows an edit
affordance, that is the moment to stop and ask whether it should exist at all.

## 2026-08-25 — The introduction earns the email, and the funnel is one row per visit

Decision:
The mailing-list panel cannot appear until the golden moment is complete and the visitor
has chosen to continue — the only exception is the "Join the mailing list" button, which is
somebody asking. Signups and the ten measurement milestones both go to the Mutant Factory
feedback service (`schema/envelope.v1.md`), the signup as one report carrying the address in
its own field, the funnel as **one** report per visit, updated in place via a stable
`report_id`, keyed `element_key: onboarding/funnel`.

Reason:
The plan's rule was "never ask for an email before the first sound", and the cheapest way to
keep a rule like that is to make it structural rather than remembered: `offerMailingList()`
is reachable from exactly one place in the state machine. Reusing the feedback service means
no second backend and no new privacy surface — the envelope was written so a second
application could conform to it without sharing code, and this is that.

Alternatives:
A dedicated mailing provider — rejected for now: none is chosen (the website's AGENTS.md
still lists it open), and inventing one would be a commitment made by a tour. One report per
event — rejected: ten rows per visitor would swamp a store a human reads daily.

Consequences:
Machine-written rows now live in a store built for words people wrote. `triage.py --app`
keeps other products' reads clean and `groups` buckets these into two rows, but the default
`new` view will carry them. `FUNNEL_REPORTS` in `editor-web/reporting.js` turns them off
without touching signups. A funnel row from a loopback or private-LAN origin carries
`test: true`, so the whole path runs while working on the page and the server stores none of
it — the two people who read the store would otherwise have been the ones filling it. That
guard is on the funnel only: a signup from a dev origin is still a person asking to join,
and the origin test is anchored at both ends, because `localhost.example.com` is a domain
anybody can register. Whatever origin serves the page must be added to the service's
`ALLOWED_ORIGINS`; `localhost` and `private` are already on it. The page also mints a random
`install_id` in localStorage — the About panel says so, in those words, because "no
tracking" would be a claim and this is a description.

## 2026-08-25 — The tutorial patch is seven nodes, and the tour teaches four things

Decision:
`examples/patches/start-here.json` is Clock, StepSequencer, AhdEnvelope, SawOscillator,
StateVariableFilter, Gain, Output. The tour's four sentences group them —
sequence/oscillator/filter/output — rather than the patch being cut down to four nodes.

Reason:
The plan asked for three or four visible nodes. Reaching that meant dropping the envelope
and the amplifier, which turns the demo from a plucked eight-step line into a continuous saw
whose pitch steps. The filter is the thing being taught, and a resonant filter opening on
each note is dramatically more legible than one opening on a drone. The count was a proxy
for readability; the grouping keeps the readability and pays for it with two more boxes.

Alternatives:
Group the nodes in the picture too, so four cards are drawn over seven nodes — rejected: a
graph view that lies about how many nodes there are, in a project whose whole claim is
exposing relationships, is the wrong thing to be clever about.

Consequences:
`editor-web/verify-onboarding.mjs` asserts every node in the patch is named by some
sentence, so adding an eighth node to the tutorial patch fails the suite rather than
quietly leaving something drawn but unexplained.

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

## Schema-level modules: designed, reversing an earlier stance — 2026-08-10

module_import.gd's header declared there would never be a sub-graph in the patch
format, for two reasons that still bind: one file must run everywhere, and opening a
patch must never resolve external links. docs/modules-design.md reverses the
conclusion while keeping both reasons: definitions are inline (no links, ever) and
patch-io flattens instances before dsp-core sees them (every target links the same
patch-io, so "a second thing every target must understand" is one function in the one
shared loader). What changed was measurement: the DX7 import made 33-node documents,
the modular layout recovered readability up to its packing floor (~68%), and the
repetition the layout has to rediscover geometrically is knowledge the importer had
and the format could not hold. A module is a notation, like a loop is to its unrolled
body — schema_version 2 only when used, byte-identical flattened audio as the stage-1
exit test.

## 2026-08-24 — Plugins are CLAP-first, wrapped by clap-wrapper

Decision:
`runtime-clap` implements exactly one plugin: the SoundGraph player, written against
the CLAP C ABI over `Graph` + `patch-io`. free-audio's clap-wrapper (MIT) compiles that
one implementation into the VST3, the AUv2 and (with Xcode present) a standalone app.
The plugin's saved state is the patch JSON itself, knob positions written back into the
node parameters they drive. Patch selection is a stepped "Patch" parameter listing the
built-in patch plus every .json under $SOUNDGRAPH_PATCHES and
~/Documents/SoundGraph/Patches, so a host's generic parameter UI is enough — no plugin
GUI yet. Switching patches goes through clap_host.request_restart(), keeping every
allocation on the main thread while deactivated. Opt-in (-DSOUNDGRAPH_CLAP=ON) after a
one-time tools/get-plugin-sdks.sh; the default build touches no network and no SDKs.

Reason:
Steinberg relicensed the VST3 SDK to MIT in October 2025 (SDK 3.8), so the entire stack
— CLAP headers, clap-wrapper, VST3 SDK, Apple's AudioUnitSDK — is now permissive, which
ARCHITECTURE.md required. One seam instead of three: the AU that auval validates is the
same implementation the VST3 and CLAP ship. dsp-core was already plugin-shaped
(allocation only in build(), lock-free events, host-buffer-size independence), so the
whole edge is one file, in the same spirit as sg-play.

Alternatives:
JUCE 8 (AGPL or paid — fails the permissive rule and would be the repo's biggest
dependency); iPlug2 (permissive and mature but a whole framework with its own
scaffolding); hand-rolled VST3 + AUv2 (licensing-clean since the MIT change, but two
wrappers of grim boilerplate for no architectural gain).

Consequences:
Windows and Linux get VST3 + CLAP from the same target with no additional code; the Mac
additionally gets the AU that Logic and GarageBand require. Two wrapper quirks are
patched in runtime-clap/CMakeLists.txt: Ninja needs the generated AudioComponents
Info.plist restored POST_BUILD (clap-wrapper's PRE_BUILD copy is clobbered by CMake's
generic bundle plist), and the standalone app steps aside when only Command Line Tools
are installed (its menu nib needs Xcode's ibtool). Automation ids are FNV-1a of the
control's id string, so they survive reload; controls inside modules persist through
the authored/flattened index parallelism patch-io guarantees.

## 2026-08-24 — The plugin's parameter surface is fixed slots; patches swap live

Decision:
Revises this morning's entry. The player exposes a fixed surface — the patch selector
plus 32 normalised slots (ids 1000+i), slot i driving control i of the loaded patch —
instead of one hashed parameter per control. Switching patches no longer requests a
host restart: the selector event asks for a main-thread callback, the callback builds a
whole new GraphInstance (graph + per-graph slot bindings) and hands it over through one
atomic; the audio thread adopts it at the top of process() and pushes the old instance
onto a graveyard stack the main thread frees. Slot renames ride
CLAP_PARAM_RESCAN_INFO, which takes effect immediately without deactivation.

Reason:
Headless Reaper testing showed the restart design silently failing: the plugin's
request_restart became restartComponent(kIoChanged|kLatencyChanged), which Reaper
answered without ever deactivating, so CLAP_PARAM_RESCAN_ALL — legal only while
deactivated — never got its window and the patch never swapped. VST3 also cannot add
or remove parameters at runtime at all, so a per-control surface could never survive a
patch switch in any VST3 host. Fixed slots with normalised ranges are what patch-player
plugins (samplers, wavetables) have always done; ranges never change, so no rescan
needs permission. The slot's control scaling (linear/exponential) maps the normalised
value, so automation curves still feel right.

Alternatives:
Keeping restart-based swaps and documenting "works where hosts honour restarts" (fails
in Reaper, the first DAW tried); per-patch hashed parameter ids (automation stable per
patch, dead on VST3 dynamics).

Consequences:
Automation lanes bind to slot positions, not control identities — repurposed when the
patch changes, as in every sampler. A patch's controls beyond 32 have no host knob
(current corpus maximum is 12). Two host-facing lessons are recorded in the seam: never
call clap_host_params.rescan from inside clap_plugin.init (Reaper's scanner rejects the
plugin), and SOUNDGRAPH_CLAP_TRACE=file traces the host's actual callback sequence,
which is how the Reaper behaviour was diagnosed. Verified end to end: ctest
clap_plugin_plays_and_swaps_patches drives the bare CLAP, auval revalidates the AU, and
a scripted headless Reaper session loads the VST3, switches First Synth to acid-bass by
automation, and renders audibly different audio.

## 2026-08-24 — Patches live in the Audio Presets folder, and the panel names its patch

Decision:
On macOS the plugin scans ~/Library/Audio/Presets/SoundGraph/Patches (plus
$SOUNDGRAPH_PATCHES); tools/install-patches.sh fills it from examples/. Every bound
slot reports the loaded patch's name as its CLAP `module`, so a host's generic panel
shows the patch as the group header and two instances are tellable apart at a glance.
Branding: vendor/manufacturer is "MutantFactory.net", plugin name "SoundGraph"; the
AUv2 manufacturer code stays SnGr — identity, not branding.

Reason:
The first patch-folder choice, ~/Documents/SoundGraph/Patches, was a macOS trap twice
over: scanning it from inside a host triggers a TCC consent prompt per host, and inside
GarageBand's sandboxed AU service — which cannot show a prompt — the denied directory
iterator THREW, the exception escaped clap_plugin.init, and GarageBand showed a warning
triangle instead of a synth. The Audio Presets folder is the platform convention for
exactly this and is not permission-gated. The iterator now uses the error_code forms of
every operation; unreadable directories are an ordinary condition for a plugin, never an
exception.

Alternatives:
Keeping ~/Documents and documenting the prompt (breaks sandboxed hosts outright);
bundling patches inside the .component/.vst3 resources (immutable, defeats "drop a
JSON in a folder"); per-host allowlisting (not a thing).

Consequences:
GarageBand shows: a Patch selector slider whose min/max labels render as patch names,
the patch-name group header over the slot parameters, live re-labeling of Smart
Controls knobs on a patch switch, and correct state restore from a saved project.
Verified end to end on 2026-08-24 by driving GarageBand itself. Windows keeps
Documents\SoundGraph\Patches until a native convention argues otherwise.

## 2026-08-24 — The plugin GUI is one webview, drawn by the plugin itself

Decision:
The plugin implements clap_plugin_gui with a single webview rendering an embedded,
network-free panel.html: the SoundGraph wordmark "by MutantFactory.net", the patch
selector, the loaded patch's name, and one styled slider per bound control. choc
(Tracktion, ISC, v1.0.15) drives the platform webview — WKWebView through the
Objective-C runtime from plain C++ on macOS, WebView2 on Windows — vendored as the 16
headers choc_WebView.h transitively needs (1.3 MB) under runtime-clap/third_party/choc,
the miniaudio pattern. clap-wrapper bridges the same GUI into the VST3 IPlugView and
the AU's Cocoa view, so one panel serves every format. GUI changes ride a lock-free
queue that process()/flush() drains into the graph and into the host's output event
queue as gesture+value events, so automation records and projects mark dirty; the page
polls a state version and re-renders itself when a patch switch or state load changes
the surface, and a state-loaded patch re-syncs the selector by matching its name
against the discovered list.

Reason:
GarageBand's Smart Controls prove the point: a host's own panel shows knob names and
nothing else — branding, patch identity and layout only exist where the plugin draws
them. A webview keeps the panel one HTML file that any web-literate person can restyle,
and it is the staging area for hosting the real web editor inside the plugin later.
JUCE-style native widgets would contradict the framework decision already made.

Alternatives:
Native NSView/Win32 drawing (two platform code paths for a panel that will become the
web editor anyway); shipping the GUI-less generic view forever (fails the "whose knobs
are these" test); a floating window (hosts treat embedded views as first-class,
floating as an afterthought).

Consequences:
16 vendored headers and two OS frameworks (WebKit/Cocoa) on the link line. The AU, the
VST3 and the CLAP all show the identical panel; verified in GarageBand — panel loads
in the AU view with state restored, slider drags reach the graph and the host, patch
switches re-render the surface live. Windows uses the same code path via WebView2,
unverified until the PC build. The panel is fixed at 560×460 until resizing earns its
complexity.

## 2026-08-24 — The plugin panel wears the rack's face

Decision:
panel.html renders the rack's visual language rather than a generic web form: the
rack.gd palette (panel/rail/knob-body/track colours, the mint SELECTED arc), real
knobs — 270° travel from 135°, track arc, value arc, cap and pointer — the rack's
gestures (vertical drag, shift for a fine hand, double-click home to default), and the
rack's type hierarchy (the value larger than the name, tabular numerals). The build
injects the editor's Atkinson Hyperlegible Next as a data URI
(runtime-clap/cmake/inject_font.py, python3; without python3 the panel falls back to
the system stack), so the plugin is set in the same face as the editor.

Reason:
The plugin panel is SoundGraph's face in other people's software; it should look like
SoundGraph, and the rack view already decided what that looks like — including the
reasoning about value-over-name emphasis, which transfers unchanged.

Consequences:
The embedded panel grows to ~160 KB, almost all typeface. The palette and knob
geometry are duplicated from rack.gd into panel.html as CSS/SVG — a divergence risk
noted and accepted until the panel hosts the web editor outright. Verified in
GarageBand: knobs render, drag and answer with the arc and the host in step.

## 2026-08-25 — Axoloti tests speak the USB protocol directly, no patcher

Decision:
Hardware tests for the Axoloti Core (`embedded/axoloti/`) implement the board's
vendor bulk USB protocol in Python and hand-write test patches in C++ against a
self-declared ABI (`axo_abi.h`), linked with `--just-symbols` against the stock
1.0.12-2 firmware elf fetched pinned-by-sha256 from the official release. The
board keeps its stock firmware; nothing is reflashed.

Reason:
The Java patcher is a heavy, aging dependency and its toolchain (gcc 4.9 era)
does not run cleanly on arm64 macOS. The protocol is ~10 commands and the patch
ABI is one struct and one entry point; declaring them ourselves removes the whole
ChibiOS header tree from the build. The board's reported firmware CRC matches the
release image byte-for-byte, so patches built with modern gcc 16 link against
exact symbol addresses — verified live: uploaded patches run at the expected
3000 cycles/s and restart cleanly.

Alternatives:
Ksoloti's maintained fork (would still be a full patcher stack); building and
reflashing our own firmware (invasive, and unnecessary while stock symbols
match); USB-protocol-only tests without patch execution (could not measure
realtime limits).

Consequences:
GPL upstream artifacts stay out of the repo (fetched into gitignored `sdk/`).
The ABI declarations must not drift from firmware 1.0.12-2 — the fwid gate in
every patch refuses to run under any other firmware build. If a board with
different firmware appears, the SDK fetch and the link symbols must change
together.

## 2026-08-25 — The Axoloti becomes a compiled soundgraph target (sgaxo)

Decision:
Soundgraph patches reach the Axoloti by compilation, not interpretation:
`embedded/axoloti/sgaxo/` validates a patch against a declared node subset,
generates C++ over a kernel library restating dsp-core's inner loops, links
against the stock 1.0.12-2 firmware, and programs the board over USB. The
generated graph runs at dsp-core's 64-frame block size behind a FIFO, and all
parameter-derived transcendentals are precomputed host-side in double
precision and baked as literals.

Reason:
It preserves the workflow the Axoloti audience already owns (a patcher program
that compiles and uploads), reuses the proven rig unchanged, and makes the
compatibility claim testable: the board renders the shared golden vectors and
the host compares raw samples over USB. Measured: sine bit-exact, first-synth
within 2e-6 — tighter than the ESP32's own native agreement. Partial
compatibility priced honestly is a subset list with test evidence per node.

Alternatives:
A player-patch interpreter (patches as data, instant switching) — deferred,
not rejected; it would consume the same kernel library. Full dsp-core on the
board — blocked by the 44 KB patch window and the libc-less toolchain.
Curated fixed banks only — needless, given how cheap the codegen proved.

Consequences:
The kernel library must not drift from dsp-core; the golden comparison on
hardware is the tripwire. Nodes with per-block schedules that depend on
history (cutoff_sweep) stay refused until replicated. Patch switching remains
stop/load/start. The subset grows kernel by kernel, each landing with its
golden case.
