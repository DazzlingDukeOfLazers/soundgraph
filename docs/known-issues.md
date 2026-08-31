# Known Issues

Open problems, ordered by how much they threaten the Knobcon demo.

## Open

- **The Web Serial deploy button has never been clicked.** The web editor can push a patch
  straight into the board's NVS, and everything around it is verified, but the serial port
  chooser is gesture-gated by design so a human has to try it. This is step 7–9 of the
  90-second demo, so it should be the next thing anyone tests.
- **The web editor has now been used, on macOS Chromium.** A full session against the
  Mac-built wasm: audio starts clean, the meter follows the envelope and LFO, patch
  switching regenerates the controls, validator messages arrive specific and actionable,
  and a rejected Apply leaves the last good graph running. Two paper cuts found and
  fixed: a freshly loaded patch kept the previous patch's scroll position, and the piano
  keys were divs — invisible to assistive tech. They are buttons with note names now.
  Still true: no human has *heard* it (the session was driven, not listened to), and no
  WebKit browser has run it.
- **Only Chrome has run the browser build.** Safari is the one to worry about — its
  AudioWorklet implementation has historically been the fussiest, and it matters for the
  "open a URL on a phone" story.
- **Linux has never been compiled.** CMake and miniaudio cover it; nothing has exercised
  it. macOS arm64 now has: the tree builds warning-free, `sg-play` opens CoreAudio through
  miniaudio, the CLI tools work, and the Godot editor loads the extension and passes all
  280 of its checks. Four defects found doing it are fixed; see docs/decisions.md for
  the one that needed a decision.
- **No `getUserMedia` in the browser.** `AudioInput` nodes schedule correctly but receive
  silence, so `delay-echo.json` validates and runs in the browser without doing anything
  audible.
- **The Waveshare board's microphone array is not driven.** The ES7210 is recorded in the
  board profile; the firmware only opens the ES8311 output path.
- **`set_audio_input` assumes the host's frame count lines up with block boundaries.** If a
  host delivers input in a size that is not a multiple of 64, the tail of a period is read
  as silence. Generated audio is unaffected — an output FIFO handles that. Fixing it
  properly needs an input FIFO too.
- **Filter cutoff modulation is sampled once per block.** At 64 frames that is a 750 Hz
  update rate, smooth for any LFO but ruling out audio-rate filter FM. Deliberate: it
  keeps `tan()` out of the inner loop, which is what would hurt on ESP32.
- **A Godot project must be imported before its extension registers.** `--headless --quit`
  does not scan the filesystem, so `SoundGraphEngine` appears missing and the editor shows
  its "build the extension first" message even when the DLL is present. Run
  `godot --headless --path editor-godot --import` once. Noted because the symptom points
  at the wrong cause.

## Accepted limitations

- **Control-rate signals are computed per sample, not per block.** Correct but wasteful.
  Revisit only if ESP32-S3 profiling says so.
- **Polyphony replicates the whole note-driven cone.** `NoteInput` carries a `voices`
  parameter (1–16, default 1; engine cap `kMaxVoices`); the graph copies everything
  downstream of the input once per voice, sums the copies at the host sinks, and an
  allocator routes each note (steal longest-held, retrigger on repeat). At 1 voice the
  build is byte-identical to the old mono path — that identity is what keeps every
  golden stable. Two consequences to know: audio from *outside* the cone that joins the
  note path before the sink fans into every voice copy and is heard once per voice
  (route such mixes into a summing jack after the voices instead), and changing
  `voices` takes effect on rebuild, not live — the editor knows this: committing a
  voices knob gesture rebuilds the engine, and undo takes the rebuild path back.
- **No parameter smoothing on `set_parameter`.** Immediate sets can zipper on large jumps.
  `Gain` and filter cutoff are the ones likely to need it first.
- **No denormal protection.** Not observable on x64 with SSE flush-to-zero defaults, but
  the `Delay` feedback path is where it would bite on another target.
- **`esp_codec_dev` is fetched by the component manager at build time.** The one place the
  repository needs the network to build. Vendor it before demo prep if offline builds
  become critical.
- **Cable routing gives up gracefully in a dense patch.** When no clear route exists it
  picks the least-blocked one rather than searching exhaustively, because routing runs per
  cable per frame.
- **A cable's signal type is hue-only between its endpoints.** Found by 15B's grayscale
  render of the dense QA graph: socket shape carries audio against control at both ends and
  survives a monochrome display, and the cable between them does not. Bounded — a reader
  can always recover a cable's type by looking at either end — but tracing one wire through
  a crossing region without looking at its ends needs colour.

  Deliberately not patched during the node pass. Investigate a non-colour secondary cue for
  cable type that stays legible without making dense patches noisy: line treatment, sparse
  inline marks, or something else equally restrained. A "small" dash change applied across
  thirty-five intersecting wires alters the whole graph, so cables want the proof-sheet
  process the nodes have just had rather than a change made in passing.

## Resolved

- White noise ranged `[-1, 3)` — wrong PRNG divisor, caught by inspecting golden vectors
  rather than trusting them.
- A truncated upload wedged the device console forever; `getchar()` under the
  interrupt-driven USB driver blocks with no timeout.
- Mouse controls stole keyboard focus, so the next note played after touching a slider was
  silently eaten.
- Godot saved patches through `JSON.stringify`, which sorted keys alphabetically and
  floated every number; saving now goes through the core's serialiser.
- Auto-place appeared non-deterministic; the algorithm was fine, the button silently
  switched to selection-only mode.
