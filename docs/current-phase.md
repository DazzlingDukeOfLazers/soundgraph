# Current Phase

**Knobcon hardening and editor polish.** Branch `knobcon-hardening`, 8 commits ahead of
`main`. Feature freeze Sep 4, show Sep 11.

Milestones A, B, C and F are all on `main` and all complete. What remains before the show
is reliability and presentation, not features.

## Where the project stands

One graph model runs, within declared tolerances, under four compilers on four
architectures:

| target | how it runs | verified by |
|---|---|---|
| Windows x64 | `sg-play`, `sg-render`, `sg-validate` | 7 ctest suites, 18 golden vectors |
| Browser | WebAssembly in an AudioWorklet | `verify-goldens.mjs`, 18 cases, worst 2.09e-7 |
| Godot 4.7 | GDExtension | 89 editor checks, 18 layout checks |
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

- **The sandbox leaks a variable number of `AudioStreamGeneratorPlayback` objects at exit** —
  11, 2 and 0 across three runs of identical code. Not new and not growing, but it is the
  same class of thing that caused the 0xC0000005 shutdown crash, so a leak count from a
  single run is not evidence about anything.
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
gates. The bigger items from the original
audit — the sampler and its buffer schema, tempo-synced delay times, a stereo field —
deserve their own planning conversation after the show.

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

## Invariants

- `dsp-core` depends on nothing but the C++ standard library.
- JSON never enters `dsp-core`; `patch-io` translates at the edge.
- No allocation, locks, or I/O in steady-state `process()`.
- No DSP in JavaScript and none in GDScript. Both editors are hosts.
- Neither editor keeps its own copy of the node vocabulary, the ranking, or the validator.
- The golden manifest is the single definition of correctness for every target.
