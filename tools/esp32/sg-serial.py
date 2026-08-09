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
    # Opening the port resets the board (DTR/RTS toggle), so a burst of boot logging is
    # on its way. Drain until the line has been quiet for a moment rather than sleeping a
    # fixed time — the boot log's tail interleaving with the first command's response was
    # a real failure mode, not a theoretical one.
    deadline = time.monotonic() + 6.0
    quiet_since = time.monotonic()
    connection.timeout = 0.1
    while time.monotonic() < deadline:
        if connection.read(4096):
            quiet_since = time.monotonic()
        elif time.monotonic() - quiet_since > 0.5:
            break
    connection.timeout = 2
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
            try:
                _, declared, payload = line.split(" ", 2)
                block = base64.b64decode(payload, validate=True)
                if len(block) != int(declared) or len(block) % 4 != 0:
                    raise ValueError(f"declared {declared} bytes, decoded {len(block)}")
            except (ValueError, IndexError) as error:
                raise RuntimeError(f"corrupt data line at {len(samples)} samples: {error}")
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


def reset_board(connection: "serial.Serial") -> None:
    """Hard-resets the chip via the RTS line.

    DTR must be dropped first: with DTR asserted (pyserial's default on open), the
    USB-Serial-JTAG bridge gates the RTS reset and the pulse does nothing — the board
    sails on and everything downstream misreads "no reset" as "device dead".
    """
    connection.dtr = False
    connection.rts = True
    time.sleep(0.1)
    connection.rts = False


def drain_until_quiet(connection: "serial.Serial", quiet_seconds: float = 0.5,
                      limit_seconds: float = 8.0) -> str:
    captured = []
    deadline = time.monotonic() + limit_seconds
    quiet_since = time.monotonic()
    old_timeout = connection.timeout
    connection.timeout = 0.1
    while time.monotonic() < deadline:
        data = connection.read(4096)
        if data:
            captured.append(data.decode("utf-8", errors="replace"))
            quiet_since = time.monotonic()
        elif time.monotonic() - quiet_since > quiet_seconds:
            break
    connection.timeout = old_timeout
    return "".join(captured)


def query_info(connection: "serial.Serial") -> dict:
    command(connection, "info")
    fields = {}
    deadline = time.monotonic() + 3.0
    while time.monotonic() < deadline:
        line = read_line(connection, timeout_seconds=0.5)
        if not line:
            break
        parts = line.split(None, 1)
        if len(parts) == 2:
            fields[parts[0]] = parts[1]
    return fields


def do_soak(connection: "serial.Serial", args) -> int:
    """The Knobcon reliability rule, literally: can this boot cleanly N times in a row?

    Each cycle resets the board by closing and reopening the port — the one reset path
    that has proven reliable on the USB-Serial-JTAG bridge (RTS-pulse resets are stateful
    and parked the chip in silent download mode on the second pulse). It also exercises
    USB re-enumeration every cycle, which is closer to booth reality anyway. Heap numbers
    are tracked across cycles because a slow leak is exactly the failure that survives
    ten demos and dies during the eleventh.
    """
    heaps = []
    for cycle in range(1, args.cycles + 1):
        connection.close()
        time.sleep(0.5)
        connection = serial.Serial(args.port, args.baud, timeout=2)
        boot_log = drain_until_quiet(connection)

        if "SoundGraph on" not in boot_log:
            print(f"  FAIL cycle {cycle}: the banner never appeared")
            if boot_log.strip():
                tail = boot_log.strip().splitlines()[-3:]
                for line in tail:
                    print(f"         {line}")
            return 1

        fields = query_info(connection)
        nodes = fields.get("nodes", "?")
        arp = fields.get("arpeggiator", "?")
        heap = fields.get("heap", "")
        internal = heap.split()[0] if heap else "?"
        heaps.append(int(internal) if internal.isdigit() else 0)

        if nodes == "?" or arp != "on":
            print(f"  FAIL cycle {cycle}: console up but wrong state (nodes={nodes}, arp={arp})")
            return 1
        print(f"  ok   cycle {cycle:>2}: {nodes} nodes, arp {arp}, {internal} B internal free")

    spread = max(heaps) - min(heaps) if heaps else 0
    print(f"\n{args.cycles} consecutive clean boots. Internal heap spread across cycles: {spread} B.")
    if spread > 8192:
        print("That spread is worth investigating before the show.")
        return 1
    return 0


def send_load(connection: "serial.Serial", payload: bytes, truncate_to: int = -1) -> str:
    """Runs the load protocol, optionally lying about the length to test truncation."""
    command(connection, f"load {len(payload)}")
    answer = read_line(connection, timeout_seconds=5.0)
    if not answer.startswith("SEND"):
        return answer
    body = payload if truncate_to < 0 else payload[:truncate_to]
    connection.write(body)
    connection.flush()
    answer = read_line(connection, timeout_seconds=30.0)
    if answer.startswith("ERR upload stalled"):
        # The device drains its input for a moment after an aborted upload, so that
        # stragglers from the dead transfer cannot be misread as commands. Anything sent
        # during that window is eaten — deliberately — so wait it out.
        time.sleep(1.2)
    return answer


def do_abuse(connection: "serial.Serial", args) -> int:
    """Feeds the device the patches a stranger's laptop will eventually produce."""
    good_patch = (REPO_ROOT / "examples" / "patches" / "first-synth.json").read_text("utf-8")

    cases = [
        ("plain garbage", b"this is not json at all", None),
        ("truncated JSON", b'{"schema_version": 1, "nodes": [', None),
        ("wrong schema version", b'{"schema_version": 99, "nodes": [], "connections": []}', None),
        ("unknown node type",
         b'{"schema_version": 1, "nodes": [{"id": "x", "type": "Reverb"}], "connections": []}',
         None),
        ("zero-delay cycle",
         b'{"schema_version": 1, "nodes": ['
         b'{"id": "a", "type": "Gain"}, {"id": "b", "type": "Gain"},'
         b'{"id": "out", "type": "StereoOutput"}],'
         b'"connections": ['
         b'{"from": {"node": "a", "port": "out"}, "to": {"node": "b", "port": "in"}},'
         b'{"from": {"node": "b", "port": "out"}, "to": {"node": "a", "port": "in"}},'
         b'{"from": {"node": "b", "port": "out"}, "to": {"node": "out", "port": "left"}}]}',
         None),
        ("truncated upload", good_patch.encode("utf-8"), len(good_patch) // 2),
    ]

    failures = 0
    for name, payload, truncate in cases:
        answer = send_load(connection, payload, -1 if truncate is None else truncate)
        rejected = answer.startswith("ERR")

        # Whatever just happened, the console must still be alive and a patch playing.
        fields = query_info(connection)
        alive = fields.get("nodes", "?") != "?"

        if rejected and alive:
            print(f"  ok   {name:<22} rejected, device alive ({answer[:60]})")
        else:
            print(f"  FAIL {name:<22} rejected={rejected} alive={alive} answer={answer[:60]}")
            failures += 1

    # A rejected patch must not have been persisted: after a reboot the demo (or the
    # last good deploy) should play, not garbage.
    reset_board(connection)
    boot = drain_until_quiet(connection)
    fields = query_info(connection)
    if "SoundGraph on" in boot and fields.get("nodes", "?") != "?":
        print(f"  ok   after reboot            {fields.get('nodes')} nodes loaded, arp {fields.get('arpeggiator')}")
    else:
        print("  FAIL after reboot            device did not come back clean")
        failures += 1

    # And a good deploy must still work after all that abuse.
    answer = send_load(connection, good_patch.encode("utf-8"))
    if answer.startswith("OK"):
        print(f"  ok   good deploy after abuse {answer[:50]}")
    else:
        print(f"  FAIL good deploy after abuse {answer[:60]}")
        failures += 1

    print()
    if failures:
        print(f"{failures} abuse case(s) failed.")
        return 1
    print("The device shrugged off everything. That is the demo posture.")
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

    soak = commands.add_parser("soak", help="repeated hard resets with a health check each time")
    soak.add_argument("--cycles", type=int, default=30)

    commands.add_parser("abuse", help="malformed and truncated patches; the device must shrug")

    args = parser.parse_args()
    handlers = {
        "info": do_info,
        "note": do_note,
        "deploy": do_deploy,
        "cmd": do_command,
        "verify-goldens": do_verify_goldens,
        "soak": do_soak,
        "abuse": do_abuse,
    }

    with open_port(args.port, args.baud) as connection:
        return handlers[args.verb](connection, args)


if __name__ == "__main__":
    sys.exit(main())
