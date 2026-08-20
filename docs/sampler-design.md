# The sampler and the slicer — design

A buffer of recorded audio, played by a node, chopped by the sequencer. This is the
largest absence the Max/Pure Data audit found, and the one that waits for its own plan
rather than riding along in a batch: it is the first feature that adds a *data* concept
to a format that has only ever carried structure. Post-Knobcon work; nothing here lands
before the freeze lifts.

## The one decision everything else follows from

**Buffers are inline in the patch, like modules are.** The modules design already
answered the philosophical half: opening a patch must never mean resolving links to
files you may not have, so a module lives in the file that uses it. A sample is the
same case with more bytes. A patch that plays a break carries the break.

The bytes are the new problem, and they get a budget rather than a workaround: a
`buffers` block holds 16-bit PCM as base64, the validator warns at 1 MB decoded and
errors at 4 MB, and the resource estimate that already answers "does this patch fit on
that board" grows a heap line per buffer. A patch stays one self-contained file that
runs on four targets, or it says clearly why it will not fit on one of them.

## The schema

```json
{
  "schema_version": 3,
  "buffers": {
    "break": { "sample_rate": 48000, "channels": 1, "format": "pcm16",
               "data": "<base64>" }
  },
  "nodes": [
    { "id": "play", "type": "Sampler", "buffer": "break",
      "parameters": { "root": 261.63, "slices": 8 } }
  ]
}
```

Rules, each one a validator check:

- A node's `buffer` must name an entry in `buffers`; an unreferenced buffer is a
  warning (dead weight travels), a missing one is an error.
- `buffers` requires `schema_version` 3. Version 2 files are untouched — the loader
  gains a table, not a migration.
- Formats start and stay at `pcm16` mono until a measured need says otherwise. Stereo
  and compression (ADPCM would suit the ESP32) are listed as open, not promised.

**dsp-core still depends on nothing.** patch-io decodes base64 and hands the graph a
table of float arrays; the Sampler receives a `Slice<const float>` through
`PrepareContext`, the same way it receives a sample rate. No file I/O, no format
knowledge, no allocation outside `prepare()` — the engine's promises are unchanged.

## One node, not two

The Sampler plays a piece of a buffer; the slicer is the same sentence with a shorter
piece. One node with a `slices` parameter (1 to 16) and a `slice` input covers both:

- **Ports**: `gate` (rising edge restarts the playhead), `frequency` (Control,
  optional — repitches relative to `root`, so the keyboard wires straight in, the
  ScaleQuantizer precedent), `slice` (Control, optional — which piece, sampled on the
  gate edge, so a StepSequencer lane chops the break and every step can lock a
  different slice). Output: `out`, mono audio.
- **Parameters**: `root` (Hz — the pitch the recording is considered to be),
  `slices`, `start` and `length` (fractions of the slice), `loop` (off | loop),
  `level`.
- **Playback**: linear interpolation on the read head. The golden vectors define the
  truth of it per target, the same discipline as everything else.

A StepSequencer lane into `slice` with the Clock on both is the entire jungle
workflow — chopping, reordering, p-locking a break — using three nodes that already
exist plus this one. That composition is why the slicer is not a second node.

## Sound sources ship generated, not recorded

The corpus must not carry recordings anyone owns. The breaks and hits the examples
ship are rendered from the drum patches already in the repository — the 909, the 606,
the gated kit — by a `tools/` script that both syncs and `--check`s, the established
pattern for generated files. A "make your own break" pipeline is more on-brand than a
grey-area Amen, and it keeps every golden vector reproducible from source.

## Staged plan, an exit test per stage

Stage 1 landed 2026-08-20: `buffers` in patch-io with the budget enforced, the Sampler
with gate-triggered resampling playback, the engine binding buffers through
PrepareContext with the graph owning the storage, and the exit test passing — a
buffer-carrying patch renders byte-identical in 4800, 64 and 37 frame chunks. The
demo's drum hit is synthesized by the generator itself, so the first shipped buffer is
already owned the way every golden is.

1. **Schema and playback.** `buffers` in patch-io, the Sampler with `gate`/`root`
   only, a generated test buffer small enough to embed in a golden. Exit: a
   buffer-carrying patch renders byte-identical in 4800, 64 and 37 frame chunks, and
   the node has its jig and its machine-verified demo.
2. **Pitch and slices.** The `frequency` and `slice` inputs, and a shipped chop patch:
   a lane driving slices of a self-rendered break. Exit: repitch lands within a cent
   across two octaves; the chop demo's probe reorders a step and the audio moves.
3. **The editor.** Import a wav (converted to `pcm16` mono at import), waveform on the
   node face, slice markers at the divisions. Exit: import, save, reopen, re-render —
   byte-identical to the pre-save render.
4. **The board.** Buffer budget against real memory (the Waveshare's PSRAM measured,
   not assumed), goldens with a buffer patch over serial. Exit: `sg-serial
   verify-goldens` passes with the new cases; the abuse suite covers a truncated
   buffer upload.

## Open questions, deliberately

Stereo buffers; streaming longer audio from flash rather than resident in RAM;
whether patches store at 48 kHz always or carry their rate and resample at load;
compression. Each waits for a measurement or a real need, in a file that will still be
here when one arrives.
