# Current Phase

**Features until the show.** Work happens on `dev` and merges to `main` at milestones —
the two are in sync as of the `spoken-roll` tag (2026-08-23). Knobcon is Sep 11; the
Sep 4 feature freeze was deliberately relaxed ("it's a great marketing tool and we don't
need hardware to make it spread itself"), so features keep landing: since the freeze
decision the vocabulary grew from 25 to 44 node types (through the maths family, Clock,
ScaleQuantizer, StepSequencer, Euclid, Comb/Allpass, Compressor, Sampler, Formant and
the TMS5220 Speech node), the editor's top row, roll, rack, shelves and feedback dialog
were reworked, and every one of the 280 examples is load-verified.

Milestones A, B, C and F are all complete. Each feature lands with its tests, rides the
full gate (`tools/pre-push.sh`, enforced on every push including tags), and gets a tag
named for itself — the tag list is the changelog.

## Where the project stands

One graph model runs, within declared tolerances, under four compilers on four
architectures:

| target | how it runs | verified by |
|---|---|---|
| Windows x64 | `sg-play`, `sg-render`, `sg-validate` | 24 ctest suites, 18 golden vectors |
| Browser | WebAssembly in an AudioWorklet | `verify-goldens.mjs`, 18 cases, worst 2.09e-7 |
| Godot 4.7 | GDExtension | ~1170 editor checks, plus design and layout suites |
| ESP32-S3 | generic firmware, Waveshare audio board | `sg-serial.py verify-goldens`, all 18 cases, worst 9.16e-5 |

`dsp-core` still depends on nothing but the C++ standard library, and no editor or host
holds a second copy of the node vocabulary, the search ranking or the validator.

## Run everything

```bash
# native
cmake -S . -B build && cmake --build build && ctest --test-dir build --output-on-failure

# browser
emcmake cmake -S . -B build-wasm -DCMAKE_BUILD_TYPE=Release && cmake --build build-wasm
node runtime-wasm/verify-goldens.mjs
python -m http.server 8177          # then open /editor-web/

# godot
cmake -S runtime-godot -B runtime-godot/build -DCMAKE_BUILD_TYPE=Release
cmake --build runtime-godot/build
godot --headless --path editor-godot --script res://editor_test.gd
godot --headless --path editor-godot --script res://layout_test.gd
node tools/verify-roundtrip.mjs

# hardware (board on COM3)
.venv/Scripts/python tools/esp32/sg-serial.py --port COM3 verify-goldens
.venv/Scripts/python tools/esp32/sg-serial.py --port COM3 abuse
.venv/Scripts/python tools/esp32/sg-serial.py --port COM3 soak --cycles 30
```

Toolchains live outside the repository: ESP-IDF v5.5 at `C:\Users\danie\esp-idf`,
Emscripten at `C:\Users\danie\emsdk`, Godot 4.7.1 under `C:\Users\danie\Downloads\gofo\`,
and a repo-local `.venv` with pyserial and esptool.

The native `build/` directory on the Windows machine is **Ninja + MSVC**, so `cmake
--build build` only works from a shell that has the VS environment loaded — run it from a
"x64 Native Tools" prompt, or wrap it:

```bash
cmd /c '"C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" >nul && cmake --build build'
```

The trap is that it does not fail immediately: already-built targets keep running and
ctest stays green, so a plain shell looks fine right up until a pull adds a new source
file — then `cl.exe` can't find `<string>` and the errors point at the code instead of at
the environment. That is exactly how the macos-support merge first presented on Windows.

## Done in this phase

- Device reliability: malformed-patch abuse suite, thirty-cycle power soak with **0 bytes**
  of heap drift, and a truncated upload no longer wedges the console. Both re-run against
  the firmware carrying all eighteen embedded golden patches — the earlier numbers were a
  different binary, so they were not evidence about this one.
- One-click deploy from the web editor over Web Serial (written, never clicked — see below).
- `NoteInput.trigger`, and every generated patch rewired to it, so a one-shot fires on every
  note instead of only on the first of an overlapping run. Four notes that used to make one
  burst now make four.
- Every generated sound is playable up the keyboard. `Slide` and `Arpeggio` gained the
  frequency parameter the oscillator always had, so the head of a patch's pitch chain holds
  its own pitch and the keyboard is connected to it as well: played standalone the note
  wins and the sound transposes, imported as a module the NoteInput is dropped and the
  parameter is what remains. The mapper offsets `transpose` so middle C is the pitch sfxr
  chose — 0.0045 cents off, and the port report is unchanged at 32 of 41.
- A jig for every node type, and a check that says so. `NodeHarness` records what it builds,
  and `test_nodes` compares that against the registry after the suite runs — so a new node
  cannot ship without one. It found `AudioInput`, which had never been driven because it is
  the only node whose input arrives through its *outputs*.
- A demo patch for every node type, in `examples/patches/nodes/`: the smallest playable
  patch where you can hear that node and hear what changes when you drag it. Each one also
  declares the change its own description tells you to try, and the suite renders the patch
  with and without it — because "does it make a sound" passes even when the node is
  bypassed, and a demo that doesn't demonstrate anything is decoration.
- The editor's examples menu is built by scanning rather than from a list, which is what
  made 33 entries practical.
- Two generated-file drift traps closed with scripts that both sync and `--check`, wired
  into the main suite: `tools/game-sounds.mjs` (the eight game sounds, whose recipe used to
  live only in a shell history) and `tools/mirror-examples.mjs` (`editor-godot/examples`).
- Godot editor: undo/redo, layered layout with crossing reduction and straightening,
  PCB-style cable routing with draggable waypoints, grid tiers that mean something,
  intent search with per-row Add buttons, Atkinson Hyperlegible throughout.

## Resolved: the demo surface is the Godot editor, in the browser

The 90-second script in `KNOBCon_2026.md` assumed a browser that patches visually, and the
`editor-web` page cannot do that — it is the "simple web reference editor" the roadmap
asked for, a JSON pane plus generated controls, so connecting a node there means typing
JSON in front of an audience. That looked like a fork: rebuild the web editor, or drop the
browser from the demo.

It was neither. The Godot editor now **exports to WebAssembly and runs as a static page**,
extension and all. Same program, same layout engine, same `dsp-core` — reached by a URL.
The script's "play the browser synth" and "connect LFO to filter modulation" are the same
nine steps that already work, and the QR code points at the real editor rather than a
lesser one.

```bash
godot --headless --path editor-godot --import
node tools/export-web.mjs            # stamps the build, then exports
python -m http.server 8178 --directory build-godot-web
```

`export-web.mjs` wraps the export rather than replacing a one-line command for its own
sake: it stamps first, and an export that skipped the stamp would ship a bundle carrying
whatever stamp happened to be on disk — a build claiming to be a different build, which
is worse than no stamp at all. It finds Godot from `SOUNDGRAPH_GODOT`, `--godot`, then the PATH under
each of the names it actually ships as — `godot` is not one of them on the Windows
box, where it is on the PATH as `Godot_v4.7.1-stable_win64_console.exe` — and
finally the folder `tests/CMakeLists.txt` already knows about. The stamp is what View's last menu item and the browser tab title read back, so a
reload that served a cached bundle says so instead of looking identical to a fresh one.

Two things that build depends on, both easy to get wrong and both documented in
`docs/decisions.md`: the extension must be compiled with hidden visibility, and against the
same Emscripten as the export template (4.0.20 for Godot 4.7.1). Either one wrong aborts
the engine with `function signature mismatch`, which names neither cause.

**Audio out of the exported editor is confirmed by ear**: playing the computer keyboard in
Chrome sounds the synth. That closes the last question about this surface — it is a demo,
not a visual demo.

Two things had to be true for it. Godot's `default_playback_type.web` is *Sample*, which
pre-bakes a stream into a buffer and cannot work for a generator, so every player now asks
for `PLAYBACK_TYPE_STREAM` explicitly. And Godot starts no audio driver at all — no
`AudioContext`, not even a request for its worklets — until the page has had a real user
gesture. Synthetic events do not lift that; only a person clicking does.

## Open

- **The Web Serial deploy button has never been clicked.** It is gesture-gated by design,
  so it needs a human. Everything around it is verified; the button itself is not.
- **The web editor has never been looked at.** The Godot editor now has, repeatedly; the
  browser page has only ever been checked element by element from a script. It matters less
  than it did, now that the Godot editor is itself reachable from a URL.
- The **sandbox's** sounds have not been heard in a browser. They use the same generator and
  the same `playback_type` as the editor's synth, which is confirmed audible, so this is a
  reasonable inference rather than a verified fact — pressing Space in the Sandbox tab would
  settle it in ten seconds.
- The exported editor is ~46 MB uncompressed, ~10 MB gzipped. It is a PWA, so that cost is
  paid once and later visits are offline — but the *first* load is still the one an audience
  watches, so whatever hosts it must serve compressed, over HTTPS (service workers need a
  secure context). Caching begins on the second visit; see `editor-godot/README.md`.
- The editor can now be **rendered to a PNG** and looked at:
  `godot --path editor-godot --script res://screenshot.gd -- shot.png 1400 900`. Not
  `--headless` — headless has no rendering server, so there is nothing to capture. Worth
  knowing why it exists: the design work had been running entirely on measurement, and the
  first time anybody rendered it, the inspector turned out to be off the right-hand edge of
  the window with its text cut in half. Every automated check had passed, because measuring
  a widget cannot tell you the widget is outside the window.
- **Resolved: the shutdown crash was a race with the audio thread.** It is worth keeping
  the whole story, because the debugging was worse than the bug.

  The round trip began failing about one run in five with 0xC0000005, *after* the work had
  succeeded. I assumed it was the flake documented earlier in this file, spent three fixes
  on the teardown path, and only then measured the commit before the design pass: 20 of 20
  clean. The regression was mine and I had spent an hour proving things about the wrong
  code.

  Two measurements found it. Under `--verbose` it never reproduced in 30 runs — a race
  announcing itself, since the only thing verbose changes is timing. And a clean run leaks
  an `AudioStreamGeneratorPlayback` with a reference count of exactly 1, which is
  AudioServer still holding it.

  AudioServer mixes on its own thread and keeps a reference to the generator playback the
  editor fills every frame. `_exit_tree` runs *inside* `free()`, so there were no frames
  between stopping the player and destroying the GDExtension engine — and if that thread
  was mid-mix, the process died. `shutdown_audio()` is now separate and public: stop the
  player, free it, drop the engine, then let two frames pass before anything is freed.
  36 consecutive clean runs, against a rate that was failing one in five.

  The design work did not cause it so much as expose it: more per-frame work across the
  extension boundary widened a window that had always been there.

  One real bug did come out of the wrong-headed search. The glow overlay reordered
  GraphEdit's children every frame, because GraphEdit keeps internal children of its own
  and puts them back on top, so the two fought sixty times a second. `z_index` does the
  same job without touching the tree.

- **The shutdown flake is fixed where it was ours, and named where it is not.** The gate
  failures ("editor_test did not report success") were the audio thread mid-mix in a
  player being freed during the suite's own teardown — before the verdict could print.
  Every teardown now stops players under `AudioServer.lock()`, and the game sounds shut
  down deliberately instead of trusting tree order; fifty instrumented runs since show
  zero verdictless exits. What remains is a crash *after* `quit()`, inside Godot 4.7's
  own audio cleanup — same fault offset every time, invisible to the gate because the
  verdict has always flushed by then, and out of script's reach. `quit_test.gd` is the
  instrument that isolated it: boot, load the sandbox voices, tear down, quit — about
  seven seconds a run, with Windows Error Reporting as the witness stdout cannot be.
  Two measurement traps paid for on the way: WER batches its reports (event times are
  reporting times, not crash times), and the console wrapper exe swallows the child's
  exit code — the inner binary tells the truth.
- The sandbox still leaks a variable number of `AudioStreamGeneratorPlayback` objects at
  exit (refcount exactly 1 — AudioServer's own hold), which is the residue of that same
  engine bug rather than a defect of the teardown.
- Safari and Firefox are untested. Only Chrome has run the browser build.
- macOS and Linux have never been compiled — CMake and miniaudio cover them, unexercised.
- `AudioInput` in the browser has no `getUserMedia`, so `delay-echo.json` loads and
  schedules correctly but has nothing to process.
- The Waveshare board's ES7210 microphone array is described in its board profile but not
  driven by the firmware.

## Next features, in order (agreed 2026-08-20)

The vocabulary audit against Max/Pure Data settled a shortlist, ranked by leverage.
Landed so far from it: the maths family (Clip, Abs, MinMax, Compare, SampleHold — with
Random deliberately rejected as two spellings of things the vocabulary already says),
the Clock node (bpm, note divisions with triplets and dots, MPC-style swing, a bar
downbeat output, and a run gate that rewinds — patches share a tempo by sharing a value,
not through a global transport), and the ScaleQuantizer (twelve scales, twelve roots,
speaking octaves like the fm wire; nearest-semitone-then-nearest-degree, ties resolving
down — its demo is Noise → SampleHold → Quantizer on the Clock's eighths, the generative
melody the shortlist promised), and the StepSequencer (one sixteen-step lane per node —
wire a second lane from the same Clock into any knob's modulation input and every step
locks it, which is the Elektron trick said in cables rather than bolted on; the Clock's
bar output on the reset input keeps odd-length lanes bar-locked polymeters instead of
accidents; kMaxParameters went 8 → 24 to make room for honest one-knob-per-step
parameters).

Also landed: Comb and Allpass primitives with Crush riding along, and the reverb as a
shipped module — `examples/patches/warehouse.json` defines a Schroeder reverb inline
(eight damped combs, four allpasses) with Size and Damp arriving as signals through bus
nodes, because an exported module input reaches one port. Feedback 0.84 over 30 ms
combs measures a 1.2 s t60, and the Size knob reaches 0.97 for six-plus seconds.

And the Compressor closed the list: feed-forward, with a sidechain input that the
detector listens to instead of the input when connected — its demo is a pad that never
meets the kick except through the sidechain, pumping. **The whole audited shortlist has
landed**: the vocabulary went from 25 node types to 40 in one pass, every one with a
jig, a machine-verified demo, and both Godot extensions rebuilt.

The Karplus-Strong experiment ran, and both halves answered. Graph feedback through
Delay works exactly as documented: the cycle validates, rings for seconds, and its
period is the delay plus one 64-sample block, measured within a sample of prediction.
But that route cannot track a keyboard (nothing computes 1/f), so the shipped
instrument uses the Comb instead — whose loop is already Karplus-Strong, sample-exact —
via a new `frequency` input that tunes the loop to one period of the incoming signal.
`examples/patches/plucked-string.json` is the whole 1983 paper as four nodes in a
module: noise burst into a tuned comb, in tune to a tenth of a hertz, with Sustain,
Damp, Pick and Echo knobs.

Euclid landed too: hits spread as evenly as they will go, a gate output for the hits
and a rest output for the offbeats, so a kick and its hats come from one node. On the
bench for a next pass: an editor oscilloscope (editor work, not DSP), and probability
gates. The sampler's stage one is landed — schema buffers, the Sampler node, the chunk-identity
exit test — per its plan:
docs/sampler-design.md — buffers inline like modules, one Sampler node whose slice
input makes it the slicer, generated breaks rather than recorded ones, four stages
with an exit test each, all post-freeze. Tempo-synced delay times and a stereo field
still wait their turn.

## Remaining before the show

Per `KNOBCon_2026.md`, none of it is code: landing page, README pass, QR, getting-started,
architecture diagram, board page, short video, and spare hardware.

## Traps worth knowing

These all cost real time once and are written up in `decisions.md` or the component
READMEs. Collected here because the pattern is the same each time — the symptom pointed
somewhere other than the cause.

- **The 0xC0000005 exit crash is rarer, not gone.** shutdown_audio() plus two frames took
  it from ~1 in 5 to the point where 36 consecutive clean runs looked like zero — and on
  2026-08-09 it fired twice in 11 runs, then 0 in the next 32. A residual few-percent
  flake passes any streak you are patient enough to collect. It still crashes *after* the
  work succeeds; verify-roundtrip labels it CRASHED rather than a refusal. If it climbs
  back toward 1-in-5, suspect the teardown path first and measure against an older
  commit before theorising.
- **Counting redraws does not test a redraw.** The rack's cable dimming needed
  `Rack.select()` to redraw the cable layer, which is a sibling of the modules rather than
  one of them. The test counted `_draw()` calls before and after — and passed with the fix
  taken back out, because something else in the test environment was already redrawing that
  layer every frame. The screenshot was the only thing that had told the truth. What made
  the test real was moving the decision out of `_draw()` into `Rack.cable_related()` and
  asking *that*: which cables are lit, given a selection. A test of a side effect is at the
  mercy of everything else that causes the same side effect; a test of a decision is not.
- A **GDScript type-inference error** leaves a half-built editor, and the headless test
  then awaits a coroutine that never resolves. It *hangs* instead of printing the parse
  error. `editor_test.gd` now bails out early; if a run ever hangs again, look for a parse
  error first.
- **`editor-godot/examples/` is build output** mirrored from `examples/patches/`. It has now
  gone stale twice, by two different routes: first as a POST_BUILD step that only ran when
  the extension relinked, then as an always-run target in the *Godot* build directory —
  which nobody runs when only a patch has changed. `tools/mirror-examples.mjs` does the sync
  now, and `godot_examples_are_mirrored` in the main suite is what notices. The lesson is
  narrower than "mirror carefully": **a guard that lives in one build only guards that
  build.**
- **A gate is not a trigger.** A one-shot patch gated by `NoteInput.gate` fired once and
  then went quiet under rolling key presses, because overlapping notes never let the gate
  fall and an AHD envelope has no edge to find. Worse in the sandbox, where `all_notes_off()`
  followed by `note_on()` in the same frame produced *no* low sample at all — control events
  drain at block boundaries — so it worked or didn't depending on where the block edge fell.
  `NoteInput.trigger` pulses on every note; percussion takes the trigger, anything that
  sustains takes the gate.
- **A patch's pitch cannot live only in a connection.** The keyboard driving a generated
  sound is a `NoteInput`, which is a terminal, which is dropped at the module seam — so a
  patch whose pitch arrived by cable went silent the moment it became a module. The head of
  the pitch chain now carries the pitch as a parameter *and* takes the keyboard, and each
  covers what the other cannot. Related: **parameter ranges clamp on load**, silently. 19 of
  the 41 sfxr cases need a transpose beyond two octaves, and at the old ±24 the file would
  have kept the right number while the sound played at the wrong pitch — the same failure
  that cost time once already on `Slide`'s range.
- A **`WebAssembly.Module` cannot be cloned into an AudioWorklet** — separate agent
  cluster — and it fails silently, with no throw and no error event.
- **RTS-pulse resets are stateful** on the USB-Serial-JTAG bridge; the second pulse parks
  the chip in download mode. Opening the port is the reliable reset.
- **godot-cpp forces the static MSVC runtime**, so our libraries must be created after
  that is set or the link fails on duplicate CRT symbols.
- A Godot project must be **imported once** (`--import`) before its extension registers.
- **The web extension is a second build.** `runtime-godot/build` is the desktop DLL,
  `runtime-godot/build-web` is the wasm. Rebuilding only the first leaves the browser on a
  stale extension, and it fails nowhere near the cause: patches refuse to load because the
  engine "does not know about" a node type that plainly exists.
- **A service worker will serve you an old build for as long as a tab stays open.** Godot's
  worker is cache-first with no `skipWaiting`, so a waiting replacement never activates
  while a client is open. Unregister it before concluding anything about a re-export; check
  which `index.pck` size actually loaded first.
- **A click test's subject must be put on screen first.** The editor suite's synthesized
  clicks are computed from widget geometry, which is correct at any scroll — but the
  *delivery* is not: a press at y = -167 lands on nothing, and a press computed for a
  port that sits under the toolbar hits the toolbar. The face-edit block ran green for
  weeks on whatever scroll fit-on-load happened to choose, then one range widening
  (LFO amount to ±1000) grew every LFO readout's reservation, nudged every bbox, moved
  every fit — and nine checks went red on a pristine checkout, looking exactly like an
  environment failure. Centre the view on the subjects before clicking, aim inside
  child rects rather than by unzoomed pixel offsets, and treat "it fails on a clean
  tree" as "the test depends on something the tree does not pin", not as proof of a
  haunted machine. Related: `zoom_actual` now re-centres deferred with freshly-read
  rects, because the zoom's own detail change re-dresses the nodes a frame later.
- **An autowrap label with no pinned width reports its minimum height as if wrapped at
  zero width.** Inside a popup that sizes to content, one long `AUTOWRAP_WORD_SMART`
  label inflated the feedback dialog to the window's full height on first open — layout
  hadn't run yet, so the label answered "how tall am I?" for a width it would never have.
  Pin `custom_minimum_size.x` on any wrapping label that lives outside a ScrollContainer;
  the search dialog only escapes because its wrapping labels sit inside one.

## Plugins

The player plugin exists: one CLAP implementation in `runtime-clap`, assembled by
clap-wrapper into `SoundGraph.clap`, `SoundGraph.vst3` and `SoundGraph.component`.
State is the patch JSON; a stepped "Patch" parameter loads anything under
`$SOUNDGRAPH_PATCHES` or `~/Documents/SoundGraph/Patches`, driving a fixed surface of
32 normalised slots (see the decision log — VST3 forbids dynamic parameter sets, and
patches swap live through an atomic graph handoff, no host restart involved). Verified
three ways on the Mac: `auval -v aumu SgPl SnGr` passes render tests included, ctest
`clap_plugin_plays_and_swaps_patches` drives the bare CLAP through a patch swap, and a
scripted headless Reaper session (`REAPER -nosplash -new <script.lua>`) loads the VST3,
flips the selector by automation and renders audibly different audio. Opt in with

```bash
tools/get-plugin-sdks.sh        # once per clone
cmake -S . -B build -DSOUNDGRAPH_CLAP=ON && cmake --build build
```

The AU is verified inside GarageBand itself (2026-08-24, driven by screenshot-guided UI
automation): it appears under AU Instruments → SoundGraph, loads as a track instrument,
GarageBand maps the patch's declared controls onto its Smart Controls knobs (Cutoff,
Resonance, Sweep Rate…), plays live from Musical Typing, records, and an Export Song to
Disk render of the recorded region produced correct, non-silent audio.

The plugin has its own GUI (2026-08-24): a webview panel — SoundGraph wordmark "by
MutantFactory.net", patch selector, patch name, sliders for the bound controls — one
embedded panel.html served identically through the CLAP, the VST3 and the AU via choc
(vendored, ISC). Verified in GarageBand: the AU window shows the panel with restored
state, slider drags reach both the graph and host automation, and patch switches
re-render the surface live.

The Windows build of the same target shipped (2026-08-24, branch `dd/clap-host` via
`dd/midi-controller`): the VST3 and CLAP install per-user, and both were verified in
Reaper 7.79 — scanned, loaded, piano-roll sequenced, audible at the OS endpoint, the
selector showing patch names. The survey that led there is its own finding: on Windows
no healthy FOSS DAW hosts VST3 (Zrythm's packaging segfaults, LMMS has no VST3/CLAP and
its bundled Carla bridge crashes, OpenMPT is VST2-only) — Carla 2.5.10 works for rack
hosting but ships a corrupt default VST3 search path (fixed per-user in
`HKCU\Software\falkTX\Carla2\Paths`).

`sg-host` (2026-08-24, `plugin-host/`) is the first brick of SoundGraph-as-host: a
headless host that loads any `.clap` **or `.vst3`** the way a DAW does, walks the
factory, activates, plays notes, applies `--param NAME=VALUE` automation, renders to
WAV, and turns an RMS threshold into an exit code. Unlike `test_clap_plugin` it meets
the *shipped artifact* across the dynamic-loading boundary — a broken export table or
CRT mismatch cannot hide. `main.cpp` knows only `hosted_plugin.h`; the formats live in
`host_clap.cpp` and `host_vst3.cpp`, so a third format would not touch the driver.
Four ctests ride the CLAP build (`sg_host_plays_the_built_clap`,
`…_lists_the_parameter_surface`, `…_plays_the_built_vst3`,
`…_swaps_patches_through_the_vst3`).

Result worth keeping: rendering the same notes through the CLAP and through the VST3
produces **byte-identical WAV files**, so the wrapper is transparent on this path.

sg-host is not ours-only: pointed at Surge XT 1.3.4 (`C:\Users\danie\Tools\surge-xt\`,
plugins-only zip, no installer) it loads and plays both the VST3 and the CLAP, and
`--param "Global Volume=0.05"` takes a foreign synth to near silence. That first
third-party contact immediately found a bug of ours: `HostProcessData` allocates input
buses but does not clear them, so an *effect* — which our own instrument never exercised,
having no audio inputs — was handed uninitialised memory and processed it as audio.
Surge XT Effects roared at peak 2.0 given nothing at all. Inputs are now zeroed and
their `silenceFlags` set every block (in place processing is legal, so once is not
enough), and the same plugin now renders exact silence. No automated test covers this:
the repository cannot depend on a third-party plugin, so the guard is this note and the
comment in `host_vst3.cpp`.

Third-party plugins the host has been proven against, all as loose files under
`C:\Users\danie\Tools\` and none installed system-wide: **Surge XT 1.3.4** (instrument
and effects, VST3 + CLAP), **Dexed 1.0.1** (VST3 + CLAP, identical output through both
— and redundant as a DX7 oracle, since `tools/dx7-ref` already vendors msfa, which is
Dexed's own engine), and **ModulAir 1.3.3** (Full Bucket Music). ModulAir is the one
that matters most: it is hand-written C++ with no plugin framework, where Surge, Dexed
and Vital are all JUCE, so it is the only evidence that the loader is not quietly
JUCE-shaped. It also shows the two formats disagreeing about the same plugin — its VST3
publishes 722 normalised parameters plus a Preset selector, its CLAP 591 in plain units
(0..4, -24..24) and no selector at all.

Two things a headless host learns from strangers. **u-he Podolski**, extracted rather
than installed (its installer demands elevation), renders perfectly well and then
refuses to *end*: unable to find its data directory during teardown it opens a modal
message box, which no console host will ever dismiss. sg-host waited three minutes
before something else noticed. Hence `--timeout` (default 60 seconds, `0` waits
forever), a watchdog thread that exits 3 — distinct from silent (1) and misuse (2) —
and `SetErrorMode` for the system's own dialogs, though that does *not* cover a plugin
calling MessageBox itself, which is precisely what Podolski does. Only the watchdog
answers that. And plugins that ship installers rather than files cannot be added to a
test rig without a human at the UAC prompt.

The watchdog test then found a second bug of ours: `--seconds 200000` overflowed the
int32 frame count, so the render loop never ran and reported perfect silence — a test
rig failing in the one direction it must never fail. Frame counts are 64-bit now, and
audio is only accumulated when a `--wav` is actually going to be written.

Trap the tool found on its first day, and the reason `settle()` exists: on Windows
clap-wrapper services CLAP's `request_callback` from `onIdle`, which it drives from a
20 ms `WM_TIMER` on a message-only window (`detail/os/windows.cpp`). A headless host
pumps no message loop, so `on_main_thread` never ran and **patch switching through the
VST3 silently did nothing** — the render simply kept playing the old patch. Two things
were needed: pump the message queue from the host's main thread, and let real wall
clock pass, because an offline render finishes a second of audio in a few milliseconds
and would outrun a 20 ms timer even with a loop running. Any offline VST3 host of a
clap-wrapper plugin needs both; a live DAW never notices because its loop was always
running. `sg_host_swaps_patches_through_the_vst3` fails if either half is removed
(verified by removing it).

The Windows GUI works too (2026-08-24). It arrived as a black rectangle in both Reaper
and Carla, and the cause was neither host: choc builds a WKWebView synchronously on
macOS but asks WebView2 for an environment *asynchronously* on Windows, and both
`bind()` and `setHTML()` open with `if (! coreWebView) return false;`. Called at
gui_create time on Windows they were therefore not errors — they were silently
discarded, so the window existed and had simply never been told to show anything. The
panel setup now lives in `finish_gui_setup`, which is idempotent, refuses to act until
`isReady()`, and is driven by a registered CLAP host timer (with a bounded message pump
in `gui_set_parent` for hosts that offer no timer extension). One genuine second bug
sat underneath: choc creates its window `WS_POPUP`, and reparenting a popup into a
host's window without restyling it `WS_CHILD` leaves it painting unreliably — the style
has to change with the parentage. Verified in Reaper: both the CLAP and the VST3 show
the panel, the patch dropdown is populated through the JS bindings, and it opens.

Still open: sample-rate golden comparison
through the plugin path, audio input for HostAudioSource patches, VST3 hosting as the
second act of `sg-host`, and growing the panel toward hosting the full web editor.

## Invariants

- `dsp-core` depends on nothing but the C++ standard library.
- JSON never enters `dsp-core`; `patch-io` translates at the edge.
- No allocation, locks, or I/O in steady-state `process()`.
- No DSP in JavaScript and none in GDScript. Both editors are hosts.
- Neither editor keeps its own copy of the node vocabulary, the ranking, or the validator.
- The golden manifest is the single definition of correctness for every target.
