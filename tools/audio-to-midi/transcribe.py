#!/usr/bin/env python3
"""Audio in, notes out - a MIDI file and, optionally, a patch's piano roll.

    transcribe.py song.wav                       # song.mid beside it
    transcribe.py song.wav --patch first-synth.json --tempo 120

Transcription is a *tool*, not part of the engine. dsp-core is std-only C++ and the
sole authority on graph semantics; recognising notes in a recording is neither, so it
lives out here with lpc-encode and the DX7 importers and is never linked into anything.

The model is Spotify's Basic Pitch (Apache-2.0): polyphonic, instrument-agnostic, and
small enough to run on a laptop CPU in a few seconds.

It keeps its own virtualenv rather than joining the one embedded/ uses, and the reason
is size. The model itself is a few megabytes; the runtime around it is not. Basic Pitch
picks that runtime by platform, and on Windows the line is drawn at the Python version:

    tensorflow ; platform_system != "Darwin" and python_version >= "3.11"
    onnxruntime; platform_system == "Windows" and python_version <  "3.11"

Measured on the Windows 3.11 environment this was built in: 1831 MB installed, of which
TensorFlow and Keras are 1176 MB. Dropping to 3.10 would swap that pair for ONNX
Runtime and land somewhere near 650 MB - worth knowing, though not tried here, so treat
it as what the dependency table promises rather than as a measurement.

Either way the weights are the same ones. Keeping this venv separate means whichever
runtime you end up with cannot wander into the environment you reach for when a board
needs reflashing.

Two outputs, because they are wanted for different things:

  * A Standard MIDI File, always. It is the format every other program understands,
    and the editor already reads one straight into the roll.
  * A patch `sequence`, on request. The importer quantises to sixteenths and keeps the
    first sixteen bars, which is right for importing a MIDI file and lossy for a
    transcription - writing the roll directly keeps whatever was played.
"""

import argparse
import json
import pathlib
import sys


# Basic Pitch's own defaults, named here so they can be argued with from the command
# line rather than guessed at. Onset threshold is the one worth reaching for: raise it
# when a breathy recording invents notes, lower it when quiet playing goes missing.
#
# The minimum note length was wrong here and said it was theirs: 58 ms against the 127.7
# that predict() actually defaults to. That made this tool keep notes basic-pitch would
# have dropped, which is a defensible choice but not the one the comment claimed, and it
# meant the native tool and this one disagreed for a reason that had nothing to do with
# either of them.
DEFAULT_ONSET = 0.5
DEFAULT_FRAME = 0.3
DEFAULT_MIN_MS = 127.7

# The roll's own ceiling, from editor-godot/piano_roll.gd. A transcription longer than
# this is truncated rather than silently folded, and says so.
MAX_STEPS = 2048


def parse_args(argv):
    p = argparse.ArgumentParser(
        description="Transcribe an audio file to MIDI, and optionally into a patch.")
    p.add_argument("audio", type=pathlib.Path,
                   help="wav, mp3, flac, ogg, m4a - anything librosa can open")
    p.add_argument("--midi", type=pathlib.Path,
                   help="where to write the MIDI file (default: alongside the audio)")
    p.add_argument("--patch", type=pathlib.Path,
                   help="a patch to write the transcription into as its piano roll")
    p.add_argument("--out", type=pathlib.Path,
                   help="write the modified patch here instead of over the original")
    p.add_argument("--tempo", type=float, default=120.0,
                   help="beats per minute the roll is laid out against (default 120)")
    p.add_argument("--division", type=int, default=4, choices=[1, 2, 4, 8, 16],
                   help="steps per beat: 4 is sixteenths, 16 is sixty-fourths")
    p.add_argument("--onset", type=float, default=DEFAULT_ONSET,
                   help="0..1; raise it if quiet noise is being heard as notes")
    p.add_argument("--frame", type=float, default=DEFAULT_FRAME,
                   help="0..1; note confidence threshold")
    p.add_argument("--min-ms", type=float, default=DEFAULT_MIN_MS,
                   help="drop notes shorter than this many milliseconds")
    p.add_argument("--min-pitch", type=int, default=0,
                   help="ignore notes below this MIDI number")
    p.add_argument("--max-pitch", type=int, default=127,
                   help="ignore notes above this MIDI number")
    p.add_argument("--quiet", action="store_true", help="print nothing but errors")
    return p.parse_args(argv)


def transcribe(args):
    """Runs the model. Imported late so that --help works without the model loaded."""
    from basic_pitch.inference import predict
    from basic_pitch import ICASSP_2022_MODEL_PATH

    model_output, midi_data, note_events = predict(
        str(args.audio),
        ICASSP_2022_MODEL_PATH,
        onset_threshold=args.onset,
        frame_threshold=args.frame,
        minimum_note_length=args.min_ms,
        minimum_frequency=None,
        maximum_frequency=None,
    )
    return midi_data, note_events


def to_sequence(notes, tempo, division, say):
    """Note events (start seconds, end seconds, pitch) into a patch `sequence`.

    The model reports absolute time, so landing on a grid means choosing a tempo - it
    hears what was played, not what it was played against. A transcription of unmetered
    playing will look untidy in the roll at any tempo, and that is honest rather than
    broken: the alternative is inventing a beat nobody played to.
    """
    step_seconds = 60.0 / tempo / division
    laid = []
    for start, end, pitch in notes:
        step = int(round(start / step_seconds))
        length = max(1, int(round((end - start) / step_seconds)))
        laid.append((step, int(pitch), length))
    laid.sort(key=lambda n: (n[0], n[1]))

    kept = [n for n in laid if n[0] + n[2] <= MAX_STEPS]
    dropped = len(laid) - len(kept)
    if dropped:
        say("  %d note%s past the roll's %d steps stayed behind"
            % (dropped, "" if dropped == 1 else "s", MAX_STEPS))

    steps = max((n[0] + n[2] for n in kept), default=0) + 4
    return {
        "tempo": float(tempo),
        "division": division,
        "steps": min(max(steps, 8), MAX_STEPS),
        "notes": [{"step": s, "note": n, "length": l} for (s, n, l) in kept],
    }


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)

    def say(message):
        if not args.quiet:
            print(message)

    if not args.audio.is_file():
        print("no such audio file: %s" % args.audio, file=sys.stderr)
        return 1

    say("listening to %s" % args.audio.name)
    try:
        midi_data, note_events = transcribe(args)
    except ImportError as problem:
        print("basic-pitch is not installed in this environment: %s" % problem,
              file=sys.stderr)
        print("see tools/audio-to-midi/README.md", file=sys.stderr)
        return 1

    # The MIDI file, always. Written before anything else can go wrong, because it is
    # the output every other program can read and the one worth not losing.
    midi_path = args.midi or args.audio.with_suffix(".mid")
    midi_path.parent.mkdir(parents=True, exist_ok=True)
    midi_data.write(str(midi_path))
    say("wrote %s" % midi_path)

    # note_events are (start, end, pitch, amplitude, bends); the roll wants the first
    # three, and only within the register asked for.
    notes = [(float(e[0]), float(e[1]), int(e[2])) for e in note_events
             if args.min_pitch <= int(e[2]) <= args.max_pitch]
    if not notes:
        say("  no notes found - try a lower --onset")
        return 0

    span = max(e[1] for e in notes)
    pitches = sorted(n[2] for n in notes)
    say("  %d notes over %.1f s, from %d to %d"
        % (len(notes), span, pitches[0], pitches[-1]))

    if args.patch:
        if not args.patch.is_file():
            print("no such patch: %s" % args.patch, file=sys.stderr)
            return 1
        patch = json.loads(args.patch.read_text(encoding="utf-8"))
        patch["sequence"] = to_sequence(notes, args.tempo, args.division, say)
        target = args.out or args.patch
        target.write_text(json.dumps(patch, indent=2) + "\n", encoding="utf-8")
        say("wrote the roll into %s - %d notes at 1/%d, %d steps"
            % (target, len(patch["sequence"]["notes"]), args.division * 4,
               patch["sequence"]["steps"]))

    return 0


if __name__ == "__main__":
    sys.exit(main())
