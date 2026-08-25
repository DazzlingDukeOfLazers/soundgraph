"""Shared load-ramp machinery: drive a count control up until the board runs
out of realtime, judged by three independent signals (firmware dspLoadPct,
heartbeat rate, loopback analyzer), then bisect the knee."""

import statistics
import time

import usb.core

import shm
from axoproto import ProtocolError

# A ramp step can fail three ways: the board stops answering (ProtocolError),
# the analyzer stalls (AssertionError), or the board drops off USB entirely
# (usb.core.USBError — seen with a marginal cable browning out under load).
STEP_ERRORS = (ProtocolError, AssertionError, usb.core.USBError)

TONE_HZ = 1500
FREQ_TOL_HZ = 100
MIN_PEAK_DBFS = -40


def fresh_window(board, timeout_s=3.0):
    """Wait for two window publications so the last full window reflects the
    current control settings, then return it."""
    start = shm.read_shm(board).win_count
    deadline = time.monotonic() + timeout_s
    while True:
        state = shm.read_shm(board)
        if state.win_count >= start + 2:
            return state
        if time.monotonic() > deadline:
            raise AssertionError("analyzer windows stopped advancing")
        time.sleep(0.05)


def measure(board, set_count, n, settle_s=0.4):
    set_count(board, n)
    time.sleep(settle_s)
    acks = [board.ping(timeout_s=4) for _ in range(5)]
    loads = [a.dsp_load for a in acks]
    # The 5 V rail, raw sysmon units (~3100 healthy on this board). A sagging
    # rail brownout-crashes the board under load and mimics a software bug —
    # it cost an afternoon once; keep it in every measurement.
    v50 = statistics.median(a.voltage_50 for a in acks)
    hb0 = board.read_u32(shm.SHM_ADDR + 4, timeout_s=4)
    t0 = time.monotonic()
    time.sleep(0.3)
    hb1 = board.read_u32(shm.SHM_ADDR + 4, timeout_s=4)
    hb_rate = (hb1 - hb0) / (time.monotonic() - t0)
    state = fresh_window(board)
    return {
        "n": n,
        "dsp_load_pct": statistics.median(loads),
        "heartbeat_rate": round(hb_rate),
        "peak_l_dbfs": round(state.peak_l_dbfs, 1),
        "zc_hz": state.zc_frequency_hz,
        "v50_raw": v50,
    }


def is_clean(m, baseline_peak_dbfs):
    return (m["dsp_load_pct"] <= 95
            and m["heartbeat_rate"] >= 0.95 * shm.CYCLES_PER_SECOND
            and abs(m["zc_hz"] - TONE_HZ) < FREQ_TOL_HZ
            and m["peak_l_dbfs"] > baseline_peak_dbfs - 6)


def run_ramp(board, set_count, steps, refine_to=8):
    """Returns (baseline, last_clean, first_dirty, results). Leaves the count
    at 0. first_dirty is None when every step ran clean."""
    baseline = measure(board, set_count, 0)
    results = [baseline]
    last_clean, first_dirty = 0, None
    for n in steps:
        try:
            m = measure(board, set_count, n)
        except STEP_ERRORS as e:
            results.append({"n": n, "error": str(e)})
            first_dirty = n
            break
        results.append(m)
        if is_clean(m, baseline["peak_l_dbfs"]):
            last_clean = n
        else:
            first_dirty = n
            break

    lo, hi = last_clean, first_dirty
    while hi is not None and hi - lo > refine_to:
        mid = (lo + hi) // 2
        try:
            m = measure(board, set_count, mid)
            results.append(m)
            if is_clean(m, baseline["peak_l_dbfs"]):
                lo = mid
            else:
                hi = mid
        except STEP_ERRORS:
            hi = mid
    set_count(board, 0)
    return baseline, lo, first_dirty, results


def print_table(results, label="n"):
    print(f"\n  {label:>7}  load%  heartbeat  peak dBFS  zc Hz  v50")
    for m in results:
        if "error" in m:
            print(f"  {m['n']:7d}  link/analyzer lost: {m['error'][:60]}")
        else:
            print(f"  {m['n']:7d}  {m['dsp_load_pct']:4d}  "
                  f"{m['heartbeat_rate']:9d}  {m['peak_l_dbfs']:8.1f}  "
                  f"{m['zc_hz']:6.0f}  {m['v50_raw']:4.0f}")
