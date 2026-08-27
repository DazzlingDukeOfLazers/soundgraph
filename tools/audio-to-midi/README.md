# Audio to MIDI (the reference implementation)

**For everyday use, reach for `sg-transcribe` instead** — same model, same answers,
16 MB instead of 1831 MB, and no Python at all. See `tools/sg-transcribe/README.md`.

This one stays because it is the thing the native tool is checked against. Running both
over the same audio and comparing raw activations is what found the head-assignment bug
in the C++ port: it said the disagreement was upstream of note-picking, which turned
"the notes are wrong" into a one-line fix. A reference implementation you can still run
is worth more than the disk it costs, and the venv is gitignored, so deleting it costs
nothing but `pip install -r requirements.txt` to get back.

Turns a recording into notes: always a Standard MIDI File, and on request the piano
roll of a patch.

```
.venv/Scripts/python transcribe.py hummed.wav
.venv/Scripts/python transcribe.py hummed.wav --patch ../../examples/patches/first-synth.json --tempo 96
```

The first writes `hummed.mid` beside the audio. The second does that *and* writes the
transcription into the patch as its `sequence`, so it opens in the editor with the notes
already in the roll.

## Why it is a tool and not a node

dsp-core is std-only C++ and the sole authority on graph semantics. Recognising notes in
a recording is neither of those things, so it lives out here with `lpc-encode.mjs` and
the DX7 and OPL2 importers, and is never linked into anything that ships. Nothing in the
engine, the editor or the firmware depends on it existing.

## Setup

It keeps its own virtualenv on purpose. The one in the repository root holds esptool and
pyserial for flashing boards, and this pulls in a machine-learning runtime that has no
business landing there.

```
python -m venv .venv
.venv/Scripts/python -m pip install "basic-pitch[onnx]"
```

The model is [Basic Pitch](https://github.com/spotify/basic-pitch) (Apache-2.0):
polyphonic, instrument-agnostic, a few seconds of laptop CPU for a few minutes of audio.

**On size.** Basic Pitch chooses its runtime by platform, and on Windows the line falls
on the Python version:

```
tensorflow ; platform_system != "Darwin" and python_version >= "3.11"
onnxruntime; platform_system == "Windows" and python_version <  "3.11"
```

Measured on Python 3.11: **1831 MB installed, 1176 MB of which is TensorFlow and Keras.**
A 3.10 environment would take ONNX Runtime instead and land near 650 MB. Same weights
either way. That has not been tried here, so it is what the dependency table promises
rather than something measured. On macOS it takes CoreML and the question does not arise.

## Output

**MIDI, always.** Written first, before anything else can fail, because it is the format
every other program understands. The editor reads one straight into the roll from
`File > Import MIDI`, so a transcription is usable with no further tooling.

**A patch `sequence`, on request.** `--patch` writes the roll directly. Worth doing
because the MIDI importer quantises to sixteenths and keeps the first sixteen bars,
which is right for importing a *tune* and lossy for a transcription, where the point is
what was actually played. `--out` writes a copy instead of editing in place.

## Knobs worth reaching for

| Flag | For |
|---|---|
| `--onset` | 0..1, default 0.5. Raise it when room noise is heard as notes; lower it when quiet playing goes missing |
| `--min-ms` | Drop notes shorter than this. Raise it to clear up a chattery transcription |
| `--min-pitch` / `--max-pitch` | Ignore everything outside a register - useful for pulling a bass line out of a mix |
| `--tempo` / `--division` | How the roll is laid out. The model hears absolute time; landing on a grid means choosing a beat |

That last one is the one to think about. The model reports when notes happened, not what
they were played against. Transcribing unmetered playing will look untidy in the roll at
any tempo, and that is honest: the alternative is inventing a beat nobody played to.

## Checking it

```
.venv/Scripts/python check.py --render ../../build/bin/sg-render.exe --patch ../../examples/patches/first-synth.json
```

Renders a known melody with `sg-render`, transcribes it, and compares. Ground truth is
not a guess - sg-render was told which notes to play - so "it produced some notes" cannot
be mistaken for "it worked". The melody has an octave leap in it on purpose, because
octave errors are the classic failure of every pitch tracker ever written and a scale
would hide them.

**This is not in `pre-push.sh`.** The gate has to pass on a machine that has never
installed a machine-learning runtime.
