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
| ESP32-S3 | generic firmware, Waveshare audio board | `sg-serial.py verify-goldens`, worst 1.90e-5 — **10 of the 18, the eight new ones unflashed** |

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

## Done in this phase

- Device reliability: malformed-patch abuse suite, thirty-cycle power soak with **0 bytes**
  of heap drift, and a truncated upload no longer wedges the console.
- One-click deploy from the web editor over Web Serial (written, never clicked — see below).
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
godot --headless --path editor-godot --export-release Web ../build-godot-web/index.html
python -m http.server 8178 --directory build-godot-web
```

Two things that build depends on, both easy to get wrong and both documented in
`docs/decisions.md`: the extension must be compiled with hidden visibility, and against the
same Emscripten as the export template (4.0.20 for Godot 4.7.1). Either one wrong aborts
the engine with `function signature mismatch`, which names neither cause.

Still unverified: **audio through the exported editor.** It boots and the extension loads,
but Godot warns that `AudioStreamGenerator` cannot be sampled on the web backend, and the
autoplay gesture requirement has not been exercised. Until that is tested with sound, the
browser demo is a visual demo.

## Open

- **The Web Serial deploy button has never been clicked.** It is gesture-gated by design,
  so it needs a human. Everything around it is verified; the button itself is not.
- **The web editor has never been looked at.** The Godot editor now has, repeatedly; the
  browser page has only ever been checked element by element from a script. It matters less
  than it did, now that the Godot editor is itself reachable from a URL.
- **No audio has come out of the exported web editor.** It boots with the extension loaded
  and the UI live; the audio path is untested. See the warning noted above.
- The exported editor is ~46 MB uncompressed, ~10 MB gzipped. It is a PWA, so that cost is
  paid once and later visits are offline — but the *first* load is still the one an audience
  watches, so whatever hosts it must serve compressed, over HTTPS (service workers need a
  secure context). Caching begins on the second visit; see `editor-godot/README.md`.
- Safari and Firefox are untested. Only Chrome has run the browser build.
- macOS and Linux have never been compiled — CMake and miniaudio cover them, unexercised.
- `AudioInput` in the browser has no `getUserMedia`, so `delay-echo.json` loads and
  schedules correctly but has nothing to process.
- The Waveshare board's ES7210 microphone array is described in its board profile but not
  driven by the firmware.

## Remaining before the show

Per `KNOBCon_2026.md`, none of it is code: landing page, README pass, QR, getting-started,
architecture diagram, board page, short video, and spare hardware.

## Traps worth knowing

These all cost real time once and are written up in `decisions.md` or the component
READMEs. Collected here because the pattern is the same each time — the symptom pointed
somewhere other than the cause.

- A **GDScript type-inference error** leaves a half-built editor, and the headless test
  then awaits a coroutine that never resolves. It *hangs* instead of printing the parse
  error. `editor_test.gd` now bails out early; if a run ever hangs again, look for a parse
  error first.
- **`editor-godot/examples/` is build output** mirrored from `examples/patches/`. It goes
  stale the moment an example is edited without rebuilding the extension. The editor now
  prefers the repository copy, but the mirror still exists for exported builds.
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
