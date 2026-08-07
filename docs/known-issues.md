# Known Issues

Open problems, ordered by how much they threaten the Knobcon demo.

## Open

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
