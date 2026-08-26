#!/usr/bin/env python3
"""Say every command the board knows and report what it heard.

    python tools/esp32/voice-check.py --port COM3

WHAT THIS IS FOR. Speech recognition fails for two completely different reasons, and from
the outside they look identical: the recogniser did not match the phrase, or the room was
too loud for the wake word to fire at all. Telling them apart is the whole job of this
tool, so it samples the microphone's noise floor immediately before each attempt and
prints it beside the result.

That distinction has already paid for itself. A run that looked like steady decay — the
last three attempts failing every time — turned out to be the room: the successful wakes
all sat at a floor of 0.0022 to 0.0029, and the three failures at 0.0174, 0.0051 and
0.0153. Six times louder. Nothing was wrong with the firmware; something in the room had
started up.

It speaks through the Windows OS voice, so nothing is sent anywhere — the same position
the recognition itself takes. A synthesised voice is not a fair test of how well a person
is understood, and it is a very fair test of whether the pipeline is working at all.

The board and a speaker have to be in one room, which is why this is not in the gate.
"""

import argparse
import subprocess
import sys
import threading
import time

try:
    import serial
except ImportError:
    sys.exit("pyserial is missing: pip install pyserial, or use the repo's .venv")

# Every phrasing, and the canonical command it belongs to. Mirrors kPhrases in
# main/speech.cpp — the board reports what it matched by its canonical name, so a hit is
# "the canonical name of the thing I said", not "the thing I said".
VOCABULARY = [
    ("next patch", "next patch"),
    ("next sound", "next patch"),
    ("previous patch", "previous patch"),
    ("last patch", "previous patch"),
    ("go back", "previous patch"),
    ("turn it up", "turn it up"),
    ("louder please", "turn it up"),
    ("turn it down", "turn it down"),
    ("quieter please", "turn it down"),
    ("start playing", "start playing"),
    ("play the sound", "start playing"),
    ("stop playing", "stop playing"),
    ("be quiet", "stop playing"),
]

# Above this, a miss is the room's fault rather than the recogniser's. Taken from the
# measurement above: quiet is a shade under 0.003, and the failures were multiples of it.
NOISY = 0.004


def speak(text):
    subprocess.run(
        ["powershell", "-NoProfile", "-Command",
         "Add-Type -AssemblyName System.Speech; "
         "$s = New-Object System.Speech.Synthesis.SpeechSynthesizer; "
         "$s.Volume = 100; "
         f"$s.Speak('{text}')"],
        capture_output=True, timeout=30)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", required=True)
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--gap", type=float, default=4.0,
                        help="seconds between attempts; must exceed the command window")
    arguments = parser.parse_args()

    connection = serial.Serial(arguments.port, arguments.baud, timeout=0.2)
    # Opening the port resets the board, and the models take a moment to load. Without
    # this the first attempt is a miss against a board that had not finished booting.
    time.sleep(3.0)
    connection.reset_input_buffer()

    lines = []
    stop = threading.Event()

    def reader():
        while not stop.is_set():
            raw = connection.readline()
            if not raw:
                continue
            text = raw.decode("utf-8", "replace").rstrip()
            if text:
                lines.append(text)

    threading.Thread(target=reader, daemon=True).start()

    hits = 0
    wakes = 0
    noisy = 0
    for spoken, canonical in VOCABULARY:
        mark = len(lines)
        connection.write(b"mic 200\n")
        connection.flush()
        time.sleep(1.4)
        floor = 0.0
        for line in lines[mark:]:
            if line.strip().startswith("ch0"):
                for token in line.split():
                    if token.startswith("rms="):
                        floor = float(token[4:])

        mark = len(lines)
        # One utterance, the way a person addresses one of these. Said as two, the
        # process launch between them eats most of the board's command window.
        speak(f"Hi ESP, {spoken}")
        time.sleep(2.5)

        woke = any("awake" in line for line in lines[mark:])
        matched = None
        for line in lines[mark:]:
            if line.startswith("HEARD "):
                matched = line[len("HEARD "):]

        ok = bool(matched) and matched.startswith(canonical)
        hits += 1 if ok else 0
        wakes += 1 if woke else 0
        loud = floor > NOISY
        noisy += 1 if (loud and not ok) else 0
        note = "  (the room was loud)" if loud and not ok else ""
        print(f"  {'ok  ' if ok else 'MISS'} {spoken:<16} floor={floor:.5f} "
              f"wake={'y' if woke else 'n'} heard={matched or '-'}{note}")
        time.sleep(arguments.gap)

    stop.set()
    time.sleep(0.3)
    connection.close()

    print(f"\nwake word {wakes}/{len(VOCABULARY)}   commands {hits}/{len(VOCABULARY)}")
    if noisy:
        print(f"{noisy} of the misses happened with the room above {NOISY} rms — that is "
              f"the room, not the recogniser. Try again when it is quiet.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
