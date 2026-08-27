#!/usr/bin/env python3
"""Does the transcriber hear what was actually played?

Renders a known melody with sg-render, transcribes it, and compares. Ground truth is
not a guess here: sg-render was told which notes to play, so the answer is known before
the model is asked, and "it produced some notes" cannot be mistaken for "it worked".

    check.py --render ../../build/bin/sg-render.exe --patch ../../examples/patches/first-synth.json

Not wired into pre-push.sh. The gate has to pass on a machine that has never installed
a machine-learning runtime, and this needs a 400 MB environment to say anything at all.
"""

import argparse
import json
import pathlib
import subprocess
import sys
import tempfile

# A melody with a leap in it, so octave errors - the classic failure of every pitch
# tracker ever written - show up as a wrong answer rather than hiding in a scale.
MELODY = [60, 64, 67, 72, 67, 64]
SECONDS = 6
GATE = 0.75


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--render", type=pathlib.Path, required=True, help="sg-render binary")
    p.add_argument("--patch", type=pathlib.Path, required=True, help="patch to play")
    p.add_argument("--keep", action="store_true", help="leave the wav behind to listen to")
    args = p.parse_args()

    for needed in (args.render, args.patch):
        if not needed.exists():
            print("missing: %s" % needed, file=sys.stderr)
            return 1

    work = pathlib.Path(tempfile.mkdtemp(prefix="a2m-check-"))
    wav = work / "truth.wav"
    subprocess.run([str(args.render), str(args.patch), str(wav),
                    "--seconds", str(SECONDS),
                    "--notes", ",".join(str(n) for n in MELODY),
                    "--gate", str(GATE), "--quiet"], check=True)

    sys.path.insert(0, str(pathlib.Path(__file__).parent))
    import transcribe

    patch_copy = work / "out.json"
    patch_copy.write_text(args.patch.read_text(encoding="utf-8"), encoding="utf-8")
    code = transcribe.main([str(wav), "--patch", str(patch_copy),
                            "--tempo", "60", "--division", "4", "--quiet"])
    if code != 0:
        return code

    heard = json.loads(patch_copy.read_text(encoding="utf-8"))["sequence"]["notes"]

    # One note a second was played. Collapse to the loudest-lasting note in each second
    # so that a stray harmonic does not count as a missed melody.
    per_second = {}
    for note in heard:
        # 60 bpm, four steps a beat: four steps is one second.
        second = note["step"] // 4
        if note["length"] > per_second.get(second, (0, 0))[1]:
            per_second[second] = (note["note"], note["length"])
    line = [per_second.get(i, (None, 0))[0] for i in range(len(MELODY))]

    print()
    print("  played %s" % MELODY)
    print("  heard  %s" % line)
    exact = sum(1 for a, b in zip(MELODY, line) if a == b)
    octave = sum(1 for a, b in zip(MELODY, line)
                 if b is not None and a != b and (a - b) % 12 == 0)
    print("  %d of %d exact, %d octave errors, %d notes total"
          % (exact, len(MELODY), octave, len(heard)))

    if not args.keep:
        for f in work.iterdir():
            f.unlink()
        work.rmdir()
    else:
        print("  kept %s" % work)

    if exact == len(MELODY):
        print("  PASS - every note of the melody came back")
        return 0
    print("  FAIL - the melody did not survive the round trip")
    return 1


if __name__ == "__main__":
    sys.exit(main())
