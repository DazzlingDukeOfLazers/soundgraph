"""Long endurance soak: tone + DSP load + SDRAM traffic + armed defect
detectors, for as long as you like. The pytest endurance test runs one minute;
this is the hours version.

Usage (from embedded/axoloti):
    .venv/bin/python tools/soak.py --minutes 30 [--osc 140] [--sdram 256]

Exits non-zero on any click, dropout, SDRAM error, heartbeat stall, or link
loss. Prints a status line every 10 s; give it a terminal and walk away.
"""

import argparse
import pathlib
import sys
import time

_HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(_HERE.parent / "driver"))
sys.path.insert(0, str(_HERE.parent / "tests"))

import shm  # noqa: E402
from axoproto import Axoloti  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--minutes", type=float, default=30)
parser.add_argument("--osc", type=int, default=140, help="load-bank oscillators")
parser.add_argument("--sdram", type=int, default=256, help="SDRAM words/cycle")
parser.add_argument("--freq", type=int, default=1000, help="tone Hz (multiple of 10)")
args = parser.parse_args()

board = Axoloti()
binary = (_HERE.parent / "patches" / "build" / "stresslab.bin").read_bytes()
board.run_patch(binary, expect_patch_id=shm.STRESSLAB_ID)
shm.set_stress_tone(board, args.freq, -6)
shm.set_nosc(board, args.osc)
shm.set_sdram_words(board, args.sdram)
time.sleep(1.0)
state = shm.read_shm(board)
shm.set_detectors(board,
                  slope_max=shm.slope_max_for(args.freq, -6),
                  floor_pk=state.in_peak_l // 2)
shm.clear_counters(board)

t0 = time.time()
last_hb = board.read_u32(shm.SHM_ADDR + 4)
last_t = time.monotonic()
failures = 0
print(f"soaking {args.minutes} min: {args.osc} osc, {args.sdram} SDRAM w/cyc, "
      f"{args.freq} Hz tone at -6 dBFS")
try:
    while time.time() - t0 < args.minutes * 60:
        time.sleep(10)
        state = shm.read_shm(board)
        hb = state.heartbeat
        now = time.monotonic()
        rate = (hb - last_hb) / (now - last_t)
        last_hb, last_t = hb, now
        sinad = state.sinad_db()
        ack = board.ping()
        line = (f"t={time.time()-t0:6.0f}s hb_rate={rate:4.0f} "
                f"load={ack.dsp_load:2d}% sinad={sinad:5.1f}dB "
                f"clicks={state.cum_clicks} drops={state.cum_dropouts} "
                f"sdram_errs={state.cum_sdram_errs} v50={ack.voltage_50}")
        bad = (state.cum_clicks or state.cum_dropouts or state.cum_sdram_errs
               or rate < 0.95 * shm.CYCLES_PER_SECOND)
        if bad:
            failures += 1
            line += "  <-- DEFECT"
        print(line, flush=True)
except Exception as e:
    print(f"LINK LOST at t={time.time()-t0:.0f}s: {type(e).__name__}: {e}")
    sys.exit(2)

shm.set_nosc(board, 0)
shm.set_sdram_words(board, 0)
shm.set_detectors(board, 0, 0)
board.stop_patch()
board.close()
print("soak finished:", "CLEAN" if failures == 0 else f"{failures} bad intervals")
sys.exit(0 if failures == 0 else 1)
