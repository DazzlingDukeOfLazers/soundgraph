# Known Issues

Open problems, ordered by how much they threaten the Knobcon demo.

## Open

- **The Web Serial deploy button has never been clicked.** The web editor can push a patch
  straight into the board's NVS, and everything around it is verified, but the serial port
  chooser is gesture-gated by design so a human has to try it. This is step 7–9 of the
  90-second demo, so it should be the next thing anyone tests.
- **The web editor has never been looked at.** Every element was verified from a script,
  but nobody has opened the page and used it. The Godot editor has now had several rounds
  of real use; the browser one has had none.
- **Only Chrome has run the browser build.** Safari is the one to worry about — its
  AudioWorklet implementation has historically been the fussiest, and it matters for the
  "open a URL on a phone" story.
- **Linux has never been compiled.** CMake and miniaudio cover it; nothing has exercised
  it. macOS arm64 now has: the tree builds warning-free, `sg-play` opens CoreAudio through
  miniaudio, the CLI tools work, and the Godot editor loads the extension and passes all
  250 of its checks. Two macOS defects found doing it are fixed; one remains, below.
- **The sfxr corpus is not bit-reproducible where `sin` differs.** `sfxr_corpus_is_repro-
  ducible` regenerates the corpus and compares it byte for byte, which is the right test
  and the reason the reference substitutes its own PRNG. Two of the 41 vectors —
  `laser-shoot-4` and `laser-shoot-5`, the only two with `wave_type == 2` — still differ
  on macOS, because the sine wave type calls the platform's `sin` and Apple's differs from
  the one that generated the committed corpus by about one ULP. The low-pass filter's
  feedback then grows that to roughly eight float ULPs (3e-8 absolute) by the end of a
  render, which is inaudible and still not byte-identical.

  Fixing it properly means substituting a deterministic sine the same way the PRNG was
  substituted, which regenerates those two vectors. That changes the oracle, so it is a
  decision rather than a bug fix and is left open deliberately. A candidate implementation
  (Cody-Waite reduction, Taylor kernels) measures within 2.2e-16 of libm across the range
  sfxr uses.
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
- **`NoteInput` is monophonic, last-note priority.** Polyphony is not on the Knobcon
  critical path; the patch format does not preclude adding it, since voice count would be
  a node parameter rather than a schema change.
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
