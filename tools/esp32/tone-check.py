#!/usr/bin/env python3
"""Play known tones at the board and check that it hears them.

    python tools/esp32/tone-check.py --port COM3

WHAT THIS IS FOR. A microphone is the one part of a board that cannot be verified by
reading a register: the chip reports itself present while the wire from it is dead, and
a capture full of ADC noise looks a lot like a capture of a quiet room. So this closes
the loop through the air — the computer plays a tone of known pitch out of its own
speaker, the board is asked what it heard, and the two are compared.

It needs the board and a speaker in the same room, which is why it is not in the gate.
It is the bring-up check, and the calibration rig for anything that follows: getting a
sensible answer here is what says the board is close enough, and the room quiet enough,
before asking it to do something harder with what it hears.

The tones are deliberately short and quiet, and quieter still as the pitch rises. Equal
amplitude is not equal loudness, and nobody wants 2.5 kHz at conversational volume for
four seconds. 1.2 seconds is long enough: the capture is 200 ms and needs to start after
the tone does and finish before it ends.

The board analyses 62 Hz to 5 kHz, so a tone outside that reads as a miss however well
the speaker plays it. That is deliberate: speech and anything worth testing with live
inside it, and every extra bin is time the console spends not answering.

Windows only for now — winsound is what plays the file without a dependency. On other
platforms, point PLAYER at something that plays a WAV and returns.
"""

import argparse
import math
import struct
import sys
import time
import wave
from pathlib import Path

try:
    import winsound
except ImportError:  # pragma: no cover - platform guard
    winsound = None

try:
    import serial
except ImportError:
    sys.exit("pyserial is missing: pip install pyserial, or use the repo's .venv")

# How far off the played tone the report may land before this counts as a miss. The
# board's bins are 31.25 Hz apart, so anything inside one bin is exact as far as it can
# tell; 4% leaves room for that plus the two clocks disagreeing slightly.
TOLERANCE = 0.04


def make_tone(path: Path, frequency: float, seconds: float = 1.2,
              rate: int = 44100, amplitude: float = 0.28) -> None:
    if frequency > 1000:
        amplitude *= 1000.0 / frequency
    frames = int(rate * seconds)
    fade = rate * 0.05
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(rate)
        samples = bytearray()
        for i in range(frames):
            # A fade at each end, so the speaker is never asked for a step.
            envelope = min(1.0, i / fade, (frames - i) / fade)
            value = amplitude * envelope * math.sin(2.0 * math.pi * frequency * i / rate)
            samples += struct.pack("<h", int(value * 32767))
        handle.writeframes(bytes(samples))


def ask(connection, text: str, quiet_seconds: float = 1.0) -> list:
    connection.reset_input_buffer()
    connection.write((text + "\n").encode())
    connection.flush()
    lines = []
    deadline = time.time() + 6.0
    while time.time() < deadline:
        raw = connection.readline()
        if not raw:
            continue
        line = raw.decode("utf-8", "replace").rstrip()
        if line:
            lines.append(line)
            deadline = time.time() + quiet_seconds
    return lines


def heard_frequency(lines: list) -> float:
    for line in lines:
        if "loudest" in line:
            # "  loudest ~2500 Hz at 0.00249"
            for token in line.replace("~", " ").split():
                try:
                    return float(token)
                except ValueError:
                    continue
    return 0.0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", required=True, help="serial port, e.g. COM3")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--tones", default="440,1000,2500",
                        help="comma-separated frequencies in Hz")
    arguments = parser.parse_args()

    if winsound is None:
        return "this tool plays sound through winsound, which is Windows only"

    here = Path(__file__).resolve().parent
    connection = serial.Serial(arguments.port, arguments.baud, timeout=0.3)
    time.sleep(0.4)

    failures = 0
    for text in arguments.tones.split(","):
        frequency = float(text)
        path = here / f"tone-{int(frequency)}.wav"
        make_tone(path, frequency)

        winsound.PlaySound(str(path), winsound.SND_FILENAME | winsound.SND_ASYNC)
        time.sleep(0.35)
        lines = ask(connection, "mic 200")
        winsound.PlaySound(None, winsound.SND_PURGE)
        path.unlink(missing_ok=True)

        heard = heard_frequency(lines)
        off = abs(heard - frequency) / frequency if heard else 1.0
        verdict = "ok   " if off <= TOLERANCE else "MISS "
        if off > TOLERANCE:
            failures += 1
        print(f"  {verdict} played {frequency:>6.0f} Hz, heard {heard:>6.0f} Hz")
        for line in lines:
            if line.startswith("  ch"):
                print(f"        {line.strip()}")
        time.sleep(0.25)

    connection.close()
    if failures:
        print(f"\n{failures} tone(s) not heard. Move the board nearer the speaker, raise "
              f"the volume, or check `mic gain`.")
        return 1
    print("\nEvery tone came back at the pitch it was played.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
