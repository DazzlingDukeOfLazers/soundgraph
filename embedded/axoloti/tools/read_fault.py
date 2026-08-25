"""Wait for the Axoloti to (re)appear on USB, connect, and print whatever the
firmware reports — including the exception dump it preserves in battery-backed
SRAM across a crash reboot (exception_checkandreport in exceptions.c sends it
as log text right after the first acknowledged command).

Usage: python tools/read_fault.py   (from embedded/axoloti, venv active)
"""

import pathlib
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "driver"))

import axoproto  # noqa: E402

print("waiting for Axoloti on USB...", flush=True)
board = None
deadline = time.monotonic() + 600
while board is None:
    try:
        board = axoproto.Axoloti()
    except axoproto.BoardNotFound:
        if time.monotonic() > deadline:
            sys.exit("gave up after 10 minutes")
        time.sleep(2)
    except axoproto.ProtocolError as e:
        print(f"present but not answering yet ({e}); retrying", flush=True)
        time.sleep(2)

print("connected")
fw = board.fw_info()
print(f"firmware {'.'.join(map(str, fw.version))}, fwid {fw.fwid:#010x}")

# The exception report rides in after acks; ping a few times and collect.
for _ in range(5):
    board.ping()
    time.sleep(0.2)
# Pump any remaining traffic so stray AxoT packets get parsed.
try:
    board._wait_packet("~", timeout_s=1.0)
except axoproto.ProtocolError:
    pass

if board.log_messages:
    print("board log:")
    for line in board.log_messages:
        print(f"  {line}")
else:
    print("no log messages — no preserved exception dump was reported")

ack = board.ping()
print(f"state: dsp_load={ack.dsp_load}% patch_id={ack.patch_id:#x} "
      f"v10={ack.voltage_10} v50={ack.voltage_50}")
board.close()
