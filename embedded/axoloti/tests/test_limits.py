"""Tier 4: the analog loopback and the upper limits.

Wiring: audio out -> audio in with a (mono) cable. The looplab patch emits a
1500 Hz tone on the left output and analyzes the inputs on-board; the host
only reads numbers, so no audio interface is involved.

The DSP load ramp switches on oscillators in the patch's load bank until the
board runs out of realtime, using three independent overload signals: the
firmware's own dspLoadPct, the heartbeat rate (dropped cycles), and the
loopback analyzer (audible dropouts collapse peak/frequency stability).
"""

import json
import pathlib
import statistics
import time

import pytest

import shm
from axoproto import ProtocolError
from conftest import load_patch_bin

REPORT_DIR = pathlib.Path(__file__).resolve().parent / "reports"

TONE_HZ = 1500
FREQ_TOL_HZ = 100
# Minimum acceptable loopback level: generous, the tone leaves at -6 dBFS.
MIN_PEAK_DBFS = -40


@pytest.fixture(scope="module")
def looplab(board):
    board.run_patch(load_patch_bin("looplab"), expect_patch_id=shm.LOOPLAB_ID)
    yield board
    try:
        shm.set_nosc(board, 0)
        shm.set_tone(board, False)
        board.stop_patch()
    except ProtocolError:
        pass


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


def test_loopback_carries_tone(looplab):
    board = looplab
    shm.set_tone(board, True)
    state = fresh_window(board)
    print(f"\nloopback: peak L {state.peak_l_dbfs:.1f} dBFS, "
          f"peak R {state.in_peak_r} raw, "
          f"zc-estimated {state.zc_frequency_hz:.0f} Hz")
    assert state.peak_l_dbfs > MIN_PEAK_DBFS, (
        f"left input peak {state.peak_l_dbfs:.1f} dBFS — is the out->in "
        "loopback cable connected?")
    assert abs(state.zc_frequency_hz - TONE_HZ) < FREQ_TOL_HZ, (
        f"zero-crossing frequency {state.zc_frequency_hz:.0f} Hz, "
        f"expected ~{TONE_HZ} Hz")
    if state.in_peak_r < state.in_peak_l / 8:
        print("right input is dead — consistent with a mono loopback cable")
    else:
        print("right input carries signal — stereo loopback cable")


def test_tone_off_goes_quiet(looplab):
    board = looplab
    shm.set_tone(board, True)
    on = fresh_window(board)
    shm.set_tone(board, False)
    off = fresh_window(board)
    assert off.in_peak_l < on.in_peak_l / 4, (
        f"input peak only fell {on.in_peak_l} -> {off.in_peak_l} "
        "when the tone stopped")


def _measure(board, n, settle_s=0.4):
    shm.set_nosc(board, n)
    time.sleep(settle_s)
    loads = [board.ping(timeout_s=4).dsp_load for _ in range(5)]
    hb0 = board.read_u32(shm.SHM_ADDR + 4, timeout_s=4)
    t0 = time.monotonic()
    time.sleep(0.3)
    hb1 = board.read_u32(shm.SHM_ADDR + 4, timeout_s=4)
    hb_rate = (hb1 - hb0) / (time.monotonic() - t0)
    state = fresh_window(board)
    return {
        "n_osc": n,
        "dsp_load_pct": statistics.median(loads),
        "heartbeat_rate": round(hb_rate),
        "peak_l_dbfs": round(state.peak_l_dbfs, 1),
        "zc_hz": state.zc_frequency_hz,
    }


def _is_clean(m, baseline_peak_dbfs):
    return (m["dsp_load_pct"] <= 95
            and m["heartbeat_rate"] >= 0.95 * shm.CYCLES_PER_SECOND
            and abs(m["zc_hz"] - TONE_HZ) < FREQ_TOL_HZ
            and m["peak_l_dbfs"] > baseline_peak_dbfs - 6)


def test_dsp_load_ramp_finds_limit(looplab):
    board = looplab
    shm.set_tone(board, True)
    baseline = _measure(board, 0)
    assert baseline["dsp_load_pct"] < 20
    assert baseline["peak_l_dbfs"] > MIN_PEAK_DBFS

    results = [baseline]
    last_clean, first_dirty = 0, None
    for n in (16, 32, 64, 96, 128, 160, 192, 224, 256, 320, 384,
              448, 512, 640, 768, 896, 1024):
        try:
            m = _measure(board, n)
        except (ProtocolError, AssertionError) as e:
            m = {"n_osc": n, "error": str(e)}
            results.append(m)
            first_dirty = n
            break
        results.append(m)
        if _is_clean(m, baseline["peak_l_dbfs"]):
            last_clean = n
        else:
            first_dirty = n
            break

    # Refine the knee to within 8 oscillators.
    lo, hi = last_clean, first_dirty
    while hi is not None and hi - lo > 8:
        mid = (lo + hi) // 2
        try:
            m = _measure(board, mid)
            results.append(m)
            if _is_clean(m, baseline["peak_l_dbfs"]):
                lo = mid
            else:
                hi = mid
        except (ProtocolError, AssertionError):
            hi = mid
    last_clean = lo

    shm.set_nosc(board, 0)

    REPORT_DIR.mkdir(exist_ok=True)
    report = {"max_clean_oscillators": last_clean,
              "first_overload": first_dirty,
              "sweep": results}
    (REPORT_DIR / "dsp_limits.json").write_text(json.dumps(report, indent=2))

    print("\n  n_osc  load%  heartbeat  peak dBFS  zc Hz")
    for m in results:
        if "error" in m:
            print(f"  {m['n_osc']:5d}  link/analyzer lost: {m['error'][:60]}")
        else:
            print(f"  {m['n_osc']:5d}  {m['dsp_load_pct']:4d}  "
                  f"{m['heartbeat_rate']:9d}  {m['peak_l_dbfs']:8.1f}  "
                  f"{m['zc_hz']:6.0f}")
    if first_dirty is None:
        print(f"  no overload found up to 1024 oscillators")
    print(f"  => clean realtime limit: {last_clean} load-bank oscillators")

    assert last_clean >= 32, "board overloads implausibly early"


def test_loopback_survives_sustained_load(looplab):
    """At ~70% of the found limit the loopback must stay clean for 2 s."""
    board = looplab
    report_path = REPORT_DIR / "dsp_limits.json"
    if not report_path.exists():
        pytest.skip("run test_dsp_load_ramp_finds_limit first")
    limit = json.loads(report_path.read_text())["max_clean_oscillators"]
    n = max(16, int(limit * 0.7))
    shm.set_tone(board, True)
    shm.set_nosc(board, n)
    time.sleep(0.4)
    peaks, freqs = [], []
    end = time.monotonic() + 2.0
    while time.monotonic() < end:
        state = fresh_window(board)
        peaks.append(state.peak_l_dbfs)
        freqs.append(state.zc_frequency_hz)
    shm.set_nosc(board, 0)
    assert min(peaks) > MIN_PEAK_DBFS
    assert max(freqs) - min(freqs) < 2 * FREQ_TOL_HZ, (
        f"tone frequency wobbled {min(freqs):.0f}..{max(freqs):.0f} Hz "
        f"under {n}-oscillator load")
