"""Tier 4: the analog loopback and the upper limits.

Wiring: audio out -> audio in with a (mono) cable. The looplab patch emits a
1500 Hz tone on the left output and analyzes the inputs on-board; the host
only reads numbers, so no audio interface is involved.

The DSP load ramp switches on oscillators in the patch's load bank until the
board runs out of realtime — see ramp.py for the three overload signals.
"""

import json
import pathlib
import time

import pytest

import ramp
import shm
from axoproto import ProtocolError
from conftest import load_patch_bin
from ramp import FREQ_TOL_HZ, MIN_PEAK_DBFS, TONE_HZ, fresh_window

REPORT_DIR = pathlib.Path(__file__).resolve().parent / "reports"


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


def test_dsp_load_ramp_finds_limit(looplab):
    board = looplab
    shm.set_tone(board, True)
    baseline, last_clean, first_dirty, results = ramp.run_ramp(
        board, shm.set_nosc,
        steps=(16, 32, 64, 96, 128, 160, 192, 224, 256, 320, 384, 448, 512,
               640, 768, 896, 1024),
        refine_to=8)

    REPORT_DIR.mkdir(exist_ok=True)
    report = {"max_clean_oscillators": last_clean,
              "first_overload": first_dirty,
              "sweep": results}
    (REPORT_DIR / "dsp_limits.json").write_text(json.dumps(report, indent=2))

    ramp.print_table(results, label="n_osc")
    if first_dirty is None:
        print("  no overload found up to 1024 oscillators")
    print(f"  => clean realtime limit: {last_clean} load-bank oscillators")

    assert baseline["dsp_load_pct"] < 20
    assert baseline["peak_l_dbfs"] > MIN_PEAK_DBFS
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
