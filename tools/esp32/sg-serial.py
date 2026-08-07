#!/usr/bin/env python3
"""Host-side companion for the SoundGraph ESP32 firmware.

    python sg-serial.py --port COM5 info
    python sg-serial.py --port COM5 deploy ../../examples/patches/first-synth.json
    python sg-serial.py --port COM5 note 45
    python sg-serial.py --port COM5 verify-goldens

Needs pyserial:  pip install pyserial

`verify-goldens` is the Milestone F exit check: it drives the device through the same
tests/golden/cases.json manifest that the native tests and the WebAssembly verifier use,
streams the rendered samples back over serial, and compares them against the recorded
vectors at the embedded tolerance (1e-4 — see docs/test-matrix.md). Same patches, same
events, same vectors; only the silicon differs.
"""
import argparse
import base64
import json
import struct
import sys
import time
from pathlib import Path

try:
    import serial  # type: ignore
except ImportError:
    print("This tool needs pyserial:  pip install pyserial", file=sys.stderr)
    sys.exit(2)

REPO_ROOT = Path(__file__).resolve().parents[2]
GOLDEN_DIR = REPO_ROOT / "tests" / "golden"
EMBEDDED_TOLERANCE = 1.0e-4


def open_port(port: str, baud: int) -> "serial.Serial":
    connection = serial.Serial(port, baud, timeout=2)
    # Opening the port usually resets the board (DTR/RTS toggle). Give it a moment and
    # swallow the boot chatter so command responses start clean.
    time.sleep(1.5)
    connection.reset_input_buffer()
    return connection


def command(connection: "serial.Serial", text: str) -> None:
    connection.write((text + "\n").encode("utf-8"))
    connection.flush()


def read_line(connection: "serial.Serial", timeout_seconds: float = 5.0) -> str:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        line = connection.readline().decode("utf-8", errors="replace").strip()
        if line:
            return line
    return ""


def wait_for(connection: "serial.Serial", prefix: str, timeout_seconds: float = 10.0) -> str:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        line = read_line(connection, timeout_seconds=1.0)
        if line.startswith(prefix):
            return line
        if line.startswith("ERR"):
            raise RuntimeError(line)
    raise TimeoutError(f"device never answered with '{prefix}'")


def read_float_wav(path: Path) -> list:
    raw = path.read_bytes()
    index = raw.find(b"data")
    if index < 0:
        raise ValueError(f"{path} has no data chunk")
    size = struct.unpack_from("<I", raw, index + 4)[0]
    return list(struct.unpack_from(f"<{size // 4}f", raw, index + 8))


def do_info(connection: "serial.Serial", _args) -> int:
    command(connection, "info")
    deadline = time.monotonic() + 3.0
    while time.monotonic() < deadline:
        line = read_line(connection, timeout_seconds=0.5)
        if line:
            print(line)
    return 0


def do_note(connection: "serial.Serial", args) -> int:
    command(connection, f"note {args.note} {args.velocity}")
    print(wait_for(connection, "OK"))
    if args.hold > 0:
        time.sleep(args.hold)
        command(connection, f"off {args.note}")
        print(wait_for(connection, "OK"))
    return 0


def do_deploy(connection: "serial.Serial", args) -> int:
    patch_path = Path(args.patch)
    text = patch_path.read_text(encoding="utf-8")
    payload = text.encode("utf-8")

    command(connection, f"load {len(payload)}")
    wait_for(connection, "SEND")
    connection.write(payload)
    connection.flush()
    answer = wait_for(connection, "OK", timeout_seconds=20.0)
    print(f"{patch_path.name}: {answer}")
    return 0


def do_command(connection: "serial.Serial", args) -> int:
    command(connection, " ".join(args.words))
    print(read_line(connection))
    return 0


def render_case(connection: "serial.Serial", case: dict) -> list:
    """Runs one manifest case on the device, returns the decoded float samples."""
    name = case["name"]
    frames = case["frames"]
    events = [
        (f"note_on:{event['frame']}:{event['note']}:{event.get('velocity', 1.0)}"
         if event["type"] == "note_on"
         else f"note_off:{event['frame']}:{event['note']}")
        for event in case.get("events", [])
    ]
    command(connection, f"render {name} {frames} " + " ".join(events))
    wait_for(connection, f"RENDER {name}", timeout_seconds=15.0)

    samples: list = []
    # 24000 frames at 115200 baud is a slow stream; be patient per line, not in total.
    while True:
        line = read_line(connection, timeout_seconds=30.0)
        if line.startswith("RENDER-END"):
            break
        if line.startswith("D "):
            block = base64.b64decode(line[2:])
            samples.extend(struct.unpack(f"<{len(block) // 4}f", block))
        elif line.startswith("ERR"):
            raise RuntimeError(line)
        elif not line:
            raise TimeoutError(f"stream for '{name}' went quiet at {len(samples)} samples")
    return samples


def do_verify_goldens(connection: "serial.Serial", args) -> int:
    manifest = json.loads((GOLDEN_DIR / "cases.json").read_text(encoding="utf-8"))
    wanted = set(args.cases) if args.cases else None

    print(f"comparing against native vectors at tolerance {EMBEDDED_TOLERANCE}\n")
    failures = 0
    checked = 0

    for case in manifest["cases"]:
        name = case["name"]
        if wanted is not None and name not in wanted:
            continue
        checked += 1

        expected = read_float_wav(GOLDEN_DIR / "vectors" / f"{name}.wav")
        try:
            actual = render_case(connection, case)
        except (RuntimeError, TimeoutError) as error:
            print(f"  FAIL {name}: {error}")
            failures += 1
            continue

        if len(actual) != len(expected):
            print(f"  FAIL {name}: expected {len(expected)} samples, got {len(actual)}")
            failures += 1
            continue

        worst = 0.0
        worst_index = 0
        for i, (a, b) in enumerate(zip(actual, expected)):
            difference = abs(a - b)
            if difference > worst:
                worst = difference
                worst_index = i

        if worst > EMBEDDED_TOLERANCE:
            print(f"  FAIL {name}: differs by {worst:.2e} at sample {worst_index}")
            failures += 1
        else:
            label = "exact" if worst == 0.0 else "ok   "
            print(f"  {label} {name:<16} max difference {worst:.2e}")

    print()
    if checked == 0:
        print("no cases matched")
        return 1
    if failures:
        print(f"{failures} of {checked} cases differ from the native vectors.")
        return 1
    print(f"All {checked} cases match the native vectors within {EMBEDDED_TOLERANCE}.")
    print("The same graph now behaves the same on this board as it does natively and in a browser.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", required=True, help="serial port, e.g. COM5 or /dev/ttyUSB0")
    parser.add_argument("--baud", type=int, default=115200)
    commands = parser.add_subparsers(dest="verb", required=True)

    commands.add_parser("info")

    note = commands.add_parser("note")
    note.add_argument("note", type=int)
    note.add_argument("--velocity", type=float, default=0.9)
    note.add_argument("--hold", type=float, default=1.0, help="seconds before note-off; 0 holds")

    deploy = commands.add_parser("deploy")
    deploy.add_argument("patch")

    raw = commands.add_parser("cmd", help="send a raw console command")
    raw.add_argument("words", nargs="+")

    verify = commands.add_parser("verify-goldens")
    verify.add_argument("cases", nargs="*", help="subset of case names; default is all")

    args = parser.parse_args()
    handlers = {
        "info": do_info,
        "note": do_note,
        "deploy": do_deploy,
        "cmd": do_command,
        "verify-goldens": do_verify_goldens,
    }

    with open_port(args.port, args.baud) as connection:
        return handlers[args.verb](connection, args)


if __name__ == "__main__":
    sys.exit(main())
