# Known Issues

Open problems, ordered by how much they threaten the Knobcon demo.

## Open

- **Neither editor has been looked at.** Both are verified headlessly — 30 checks on the
  Godot editor, functional element-by-element checks on the web page — but nobody has
  opened either one and seen it render, dragged a wire, or heard it through a real device.
  Do that before showing either to anyone.
- **A Godot project must be imported before its extension registers.** `--headless --quit`
  does not scan the filesystem, so `SoundGraphEngine` appears missing and the editor shows
  its "build the extension first" message even when the DLL is present. Run
  `godot --headless --path editor-godot --import` once. Noted here because the symptom
  points at the wrong cause.
- **The web page has never been looked at.** Every element was verified functionally, but
  the browser pane used during development did not composite frames, so nobody has seen
  the layout render. Open `editor-web/` and check it before showing it to anyone.
- **Only Chrome has run the browser build.** Safari and Firefox are untested. Safari is
  the one to worry about: its AudioWorklet implementation has historically been the
  fussiest, and it matters for the "open a URL on a phone" story.
- **No `getUserMedia` in the browser.** `AudioInput` nodes schedule correctly but receive
  silence, so `delay-echo.json` loads and validates in the browser without doing anything
  audible. Live input is second-vertical-slice work.

- **`set_audio_input` assumes the host's frame count lines up with block boundaries.**
  The graph runs whole 64-frame blocks; if a host delivers input in a size that is not a
  multiple of 64, the tail of a period is read as silence rather than being carried into
  the next block. Generated audio is unaffected (an output FIFO handles that). Fixing it
  properly means an input FIFO too, which is Milestone B / second-slice work.
- **Filter cutoff modulation is sampled once per block.** At 64 frames that is a 750 Hz
  update rate, which is smooth for any LFO but rules out audio-rate filter FM. Deliberate
  — it keeps `tan()` out of the inner loop, which is the thing that would hurt on ESP32.

## Accepted limitations (Milestone A)

- **Control-rate signals are computed per sample, not per block.** Correct but wasteful.
  Revisit only if ESP32-S3 profiling says so; premature optimisation would complicate the
  scheduler before the browser target exists.
- **`NoteInput` is monophonic, last-note-priority.** Polyphony is not on the Knobcon
  critical path; the patch format does not preclude adding it (voice count would be a
  node parameter, not a schema change).
- **No parameter smoothing on `set_parameter`.** Immediate sets can zipper on large
  jumps. Smoothed set is a Milestone D concern; `Gain` and filter cutoff are the ones
  likely to need it first.
- **No denormal protection.** Not observable on x64 with SSE flush-to-zero defaults, but
  the `Delay` feedback path is the place it would bite on other targets.
