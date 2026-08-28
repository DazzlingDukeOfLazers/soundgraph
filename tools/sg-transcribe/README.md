# sg-transcribe

A recording becomes notes: always a MIDI file, and on request the piano roll of a patch.

```
sg-transcribe hummed.wav
sg-transcribe hummed.wav --patch ../../examples/patches/first-synth.json --tempo 96
```

## What it is

Spotify's Basic Pitch model — polyphonic, instrument-agnostic — run natively. The model
is `model/nmp.onnx`, 230 KB, Apache-2.0 (`model/LICENSE`), taken from basic-pitch 0.4.0.
Everything around it is here: the windowing that feeds it, the note-picking that reads
its three output heads, a resampler, and a MIDI writer.

The whole deployed thing is about 16 MB, nearly all of it ONNX Runtime's DLL. The
Python tool this replaced needed 1831 MB installed, 1176 MB of which was TensorFlow.
The model was never the heavy part.

Nothing depends on this. dsp-core is std-only C++ and the sole authority on graph
semantics; recognising notes in a recording is neither, so this is a tool that reads a
file and writes two others, and the engine, the editor and the firmware are unaware of it.

## Building it

It needs a prebuilt ONNX Runtime, which is 15 MB of platform-specific binary and not a
thing to vendor into git. So it is optional, in the same way the Godot suites are:

```
git config soundgraph.onnxruntime /path/to/onnxruntime-win-x64-1.29.0
```

Then configure and build as usual. Point it at the directory containing `include/` and
`lib/`, from the plain CPU archive at
[the ONNX Runtime releases](https://github.com/microsoft/onnxruntime/releases) — not the
GPU one. **A checkout that has never set this configures, builds and passes the gate
exactly as before**; the target and its test appear and disappear together.

The build copies the model, and on Windows the DLL, next to the executable.

## Formats it reads

**WAV, FLAC and MP3**, decoded through miniaudio — already vendored for the native
runtime, though not the translation unit built there: that one defines `MA_NO_DECODING`,
because over there miniaudio is a sound card. `audio_load.cpp` is the mirror image,
decoders on and device IO off, sharing only the header.

Every WAV bit depth, which matters more than it sounds. The minimal reader in
`tools/common` takes 16-bit PCM and 32-bit float and refuses everything else — including
24-bit, which is what most recorders and DAWs actually write. This tool used that reader
at first and would have turned away a large share of real recordings.

**Not Ogg Vorbis**, despite miniaudio advertising it: `MA_HAS_VORBIS` is defined only
`#ifdef STB_VORBIS_INCLUDE_STB_VORBIS_H`, and stb_vorbis is not bundled with the header.
One more vendored file would do it, if it were ever wanted.

**Not AAC**, so not `.m4a` or `.mp4`. miniaudio has no AAC decoder at all, and adding one
means a platform codec or another dependency. Convert to WAV first.

Verified by transcribing the same six-note melody from each: 16-bit WAV, 24-bit WAV,
32-bit float WAV, FLAC and MP3 all return `[60, 64, 67, 72, 67, 64]`, and Ogg is refused
with a message naming what is understood.

## Output

**MIDI, always.** Written before anything else can fail, because it is the format every
other program understands. `File > Import MIDI…` in the editor takes it straight into
the roll.

**A patch `sequence`, on request.** `--patch` writes the roll directly, going through
patch-io so what comes out is a real patch rather than JSON that resembles one. Worth
doing, because the MIDI importer quantises to sixteenths and keeps the first sixteen
bars — right for importing a *tune*, lossy for a transcription. `--out` writes a copy
instead of editing in place.

## Knobs

| Flag | For |
|---|---|
| `--onset` | 0..1, default 0.5. Raise it when room noise is heard as notes; lower it when quiet playing goes missing |
| `--frame` | 0..1, default 0.3. How much confidence keeps a note sounding |
| `--min-ms` | Drop notes shorter than this, default 127.7 |
| `--min-pitch` / `--max-pitch` | Ignore everything outside a register — how a bass line comes out of a mix |
| `--tempo` / `--division` | How the roll is laid out |
| `--no-melodia` | Skip the pass that sweeps up sustained energy with no clear onset |
| `--dump` | Raw activations, for comparing against the Python reference |

`--tempo` is the one to think about. The model reports when notes happened, not what
they were played against. Transcribing unmetered playing will look untidy in the roll at
any tempo, and that is honest: the alternative is inventing a beat nobody played to.

## Checking it

`ctest -R transcriber` renders a known melody with sg-render, transcribes it, and
compares. Ground truth is not a guess — sg-render was told which notes to play. The
melody leaps an octave on purpose, because octave errors are the classic failure of
every pitch tracker ever written and a scale would hide them.

Measured against the Python reference on the same audio, after the head-assignment bug
below was fixed:

```
activations  mean |difference|   note 0.0000   onset 0.0001
notes        six of six identical, worst onset difference 1 ms
```

Which is closer than it had any right to be, given the two resample 48 kHz to 22.05 kHz
with different kernels.

The test has a second leg: the same melody as `fixtures/melody.mp3`, which guards the
build rather than the decoder. Decoding is miniaudio's job; what could plausibly go
wrong here is a stray `MA_NO_MP3` or the decode-only translation unit going missing, and
either would take MP3 support away without anything else noticing. The fixture is
committed because there is no MP3 encoder anywhere in this tree — which is also why it
is mono and short.

## The bug worth knowing about

Two of the model's three outputs are 88 wide, so width cannot tell the note head from
the onset head, and they are exported as `StatefulPartitionedCall:2`, `:1` and `:0` —
declared in that order, meaning nothing.

The first version guessed, guessed wrong, and sent both 88-wide heads into `note` while
leaving `onset` zero-filled. It still produced six notes of roughly the right pitches.
They were in the wrong order and 1.6 seconds late, but nothing crashed and no threshold
complained — the kind of wrong that looks like a quality problem and is actually a
wiring problem.

Settled by asking the model: fed a sustained tone, the onset head is above 0.5 in 1% of
frames and the note head in 95%, because one marks a beginning and the other a
continuing. Declaration order is **0 = onset, 1 = note, 2 = contour**, and there is now
a width check so that a model with different outputs stops rather than transcribing
nonsense.

This is why `--dump` exists. Comparing raw activations against the Python said the
problem was upstream of note-picking, which is what turned a vague "the notes are wrong"
into a one-line fix.
