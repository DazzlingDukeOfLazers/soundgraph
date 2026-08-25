"""Tier 5: running the audio engine ragged.

The stresslab patch provides a variable-frequency/-amplitude tone, an on-board
Goertzel (SINAD), cumulative click/dropout counters that never sleep between
host polls, the integer load bank, and a verified audio-rate SDRAM ring.
Everything here measures quality *under* punishment, not just survival:
noise floor, linearity, frequency response, SINAD vs DSP load, defect-free
load transitions, USB hammering at high load, SDRAM bandwidth/integrity,
lifecycle churn, and a one-minute everything-at-once soak.

Results land in tests/reports/stress.json.
"""

import json
import time

import pytest

import shm
from axoproto import PATCHMAINLOC, ProtocolError
from conftest import load_patch_bin
from ramp import fresh_window
from test_limits import REPORT_DIR

# From the load ramp: 176 oscillators clean; 160 is a solid ~84% working load.
HIGH_LOAD_OSC = 160
SOAK_LOAD_OSC = 140

_report = {}


def _save_report():
    REPORT_DIR.mkdir(exist_ok=True)
    (REPORT_DIR / "stress.json").write_text(json.dumps(_report, indent=2))


@pytest.fixture(scope="module")
def stresslab(board):
    board.run_patch(load_patch_bin("stresslab"), expect_patch_id=shm.STRESSLAB_ID)
    yield board
    _save_report()
    try:
        shm.set_nosc(board, 0)
        shm.set_sdram_words(board, 0)
        shm.set_stress_tone(board, 1000, None)
        board.stop_patch()
    except ProtocolError:
        pass


def settle_and_window(board):
    """Let a control change propagate, then return a full fresh window."""
    time.sleep(0.15)
    return fresh_window(board)


def test_noise_floor(stresslab):
    board = stresslab
    shm.set_stress_tone(board, 1000, None)   # silence
    state = settle_and_window(board)
    floor_rms = state.rms_l_dbfs
    floor_peak = state.peak_l_dbfs
    print(f"\nnoise floor: rms {floor_rms:.1f} dBFS, peak {floor_peak:.1f} dBFS")
    _report["noise_floor_rms_dbfs"] = round(floor_rms, 1)
    assert floor_peak < -40, "silent input is implausibly loud — loopback issue?"


def test_amplitude_linearity(stresslab):
    board = stresslab
    curve = []
    print("\n  sent dBFS  received rms dBFS")
    for amp in (-36, -30, -24, -18, -12, -6, -3, -1):
        shm.set_stress_tone(board, 1000, amp)
        state = settle_and_window(board)
        curve.append((amp, round(state.rms_l_dbfs, 1)))
        print(f"  {amp:9d}  {state.rms_l_dbfs:17.1f}")
    _report["linearity"] = curve
    # Gain referenced at -12 dBFS; the path must track linearly below -6.
    gain = curve[4][1] - curve[4][0]
    for sent, got in curve[:6]:
        assert abs(got - (sent + gain)) < 1.5, (
            f"non-linear at {sent} dBFS: got {got}, expected {sent + gain:.1f}")
    print(f"  loopback gain {gain:+.1f} dB")


def test_frequency_response(stresslab):
    board = stresslab
    curve = []
    print("\n  freq Hz  rms dBFS")
    for freq in (50, 100, 200, 500, 1000, 2000, 4000, 8000, 12000, 16000, 20000):
        shm.set_stress_tone(board, freq, -12)
        state = settle_and_window(board)
        curve.append((freq, round(state.rms_l_dbfs, 1)))
        print(f"  {freq:7d}  {state.rms_l_dbfs:8.1f}")
    _report["frequency_response"] = curve
    ref = dict(curve)[1000]
    for freq, level in curve:
        if 100 <= freq <= 10000:
            assert abs(level - ref) < 3.0, (
                f"response at {freq} Hz is {level - ref:+.1f} dB vs 1 kHz")


def test_sinad_vs_load(stresslab):
    board = stresslab
    shm.set_stress_tone(board, 1000, -6)
    results = []
    print("\n  n_osc  SINAD dB  dsp%")
    for n in (0, 100, HIGH_LOAD_OSC):
        shm.set_nosc(board, n)
        time.sleep(0.3)
        state = fresh_window(board)
        sinad = state.sinad_db()
        load = board.ping().dsp_load
        results.append((n, round(sinad, 1), load))
        print(f"  {n:5d}  {sinad:8.1f}  {load:4d}")
    shm.set_nosc(board, 0)
    _report["sinad_vs_load"] = results
    # Absolute floors, not relative degradation: the measurement sits near the
    # float32 estimator's resolution, so idle readings bounce between ~47 dB
    # and the 60 dB cap — a delta assertion flakes on that, a floor doesn't.
    for n, sinad, _load in results:
        assert sinad > 40, f"SINAD {sinad} dB at {n} oscillators"


def _arm_detectors(board, freq, amp_dbfs):
    """Arm click/dropout detection calibrated to the current loopback level."""
    state = fresh_window(board)
    shm.set_detectors(board,
                      slope_max=shm.slope_max_for(freq, amp_dbfs),
                      floor_pk=state.in_peak_l // 2)
    shm.clear_counters(board)


def _defects(board):
    state = shm.read_shm(board)
    return state.cum_clicks, state.cum_dropouts, state.cum_sdram_errs


def test_no_defects_under_steady_load(stresslab):
    board = stresslab
    shm.set_stress_tone(board, 1000, -6)
    shm.set_nosc(board, HIGH_LOAD_OSC)
    time.sleep(0.3)
    _arm_detectors(board, 1000, -6)
    time.sleep(5)
    clicks, dropouts, _ = _defects(board)
    shm.set_detectors(board, 0, 0)
    shm.set_nosc(board, 0)
    print(f"\n5 s at ~84% load: {clicks} clicks, {dropouts} dropout-ms")
    _report["steady_load_defects"] = {"clicks": clicks, "dropouts": dropouts}
    assert clicks == 0 and dropouts == 0


def test_load_transitions_are_clean(stresslab):
    """Slamming the scheduler between idle and ~84% every 100 ms must not
    put a single click or dropped millisecond into the audio path."""
    board = stresslab
    shm.set_stress_tone(board, 1000, -6)
    time.sleep(0.3)
    _arm_detectors(board, 1000, -6)
    t0 = time.time()
    flips = 0
    while time.time() - t0 < 5:
        shm.set_nosc(board, HIGH_LOAD_OSC if flips % 2 == 0 else 0)
        flips += 1
        time.sleep(0.1)
    shm.set_nosc(board, 0)
    clicks, dropouts, _ = _defects(board)
    shm.set_detectors(board, 0, 0)
    print(f"\n{flips} load flips: {clicks} clicks, {dropouts} dropout-ms")
    _report["transition_defects"] = {"flips": flips, "clicks": clicks,
                                     "dropouts": dropouts}
    assert clicks == 0 and dropouts == 0


def test_usb_hammer_under_load(stresslab):
    """Saturate the USB protocol while the DSP runs at ~84%: the link must
    keep serving and the audio must not care."""
    board = stresslab
    shm.set_stress_tone(board, 1000, -6)
    shm.set_nosc(board, HIGH_LOAD_OSC)
    time.sleep(0.3)
    _arm_detectors(board, 1000, -6)
    t0 = time.time()
    transferred = 0
    while time.time() - t0 < 5:
        transferred += len(board.read_mem(PATCHMAINLOC, 4096))
    rate = transferred / (time.time() - t0) / 1024
    clicks, dropouts, _ = _defects(board)
    shm.set_detectors(board, 0, 0)
    shm.set_nosc(board, 0)
    print(f"\nUSB under load: {rate:.0f} KB/s readback, "
          f"{clicks} clicks, {dropouts} dropout-ms")
    _report["usb_under_load_kbps"] = round(rate)
    assert rate > 50, "USB throughput collapsed under DSP load"  # KB/s
    assert clicks == 0 and dropouts == 0


def test_sdram_bandwidth_and_integrity(stresslab):
    """Ramp verified SDRAM traffic until the realtime budget breaks; defects
    are judged per step so the knee is a measurement, not a failure. Data
    integrity must hold at every step, overloaded or not — writes and
    verifies run in the DSP cycle regardless of how late it lands."""
    board = stresslab
    shm.set_stress_tone(board, 1000, -6)
    time.sleep(0.3)
    _arm_detectors(board, 1000, -6)
    sweep = []
    last_clean_mbps = 0.0
    total_errs = 0
    print("\n  words/cycle  MB/s(w+v)  dsp%  clicks  drops  errs")
    for words in (64, 128, 256, 512, 1024, 2048):
        shm.set_sdram_words(board, words)
        time.sleep(1.0)  # verify-lag warmup at the new rate
        shm.clear_counters(board)
        time.sleep(1.5)  # judged interval
        load = board.ping().dsp_load
        clicks, drops, errs = _defects(board)
        total_errs += errs
        mbps = words * 2 * 4 * shm.CYCLES_PER_SECOND / 1e6  # write+verify bytes
        sweep.append((words, round(mbps, 1), load, clicks, drops, errs))
        print(f"  {words:11d}  {mbps:9.1f}  {load:4d}  {clicks:6d}  "
              f"{drops:5d}  {errs:4d}")
        clean = clicks == 0 and drops == 0 and errs == 0 and load <= 90
        if clean:
            last_clean_mbps = mbps
        else:
            break
    shm.set_sdram_words(board, 0)
    time.sleep(0.3)
    shm.set_detectors(board, 0, 0)
    _report["sdram_sweep"] = sweep
    _report["sdram_clean_mbps"] = last_clean_mbps
    print(f"  => clean audio-rate SDRAM bandwidth: {last_clean_mbps:.1f} MB/s "
          "(write+verify)")
    assert total_errs == 0, f"{total_errs} SDRAM verify errors — data corruption"
    assert last_clean_mbps >= 3.0, "SDRAM bandwidth implausibly low"


def test_endurance_everything_at_once(stresslab):
    """One minute of tone + DSP load + SDRAM traffic + armed detectors +
    continuous host polling. The counters must stay at zero throughout.
    Loads chosen to land ~75% combined: 100 oscillators (~55%) plus 128
    SDRAM words/cycle (~15%) — 140+256 proved to be over budget together."""
    board = stresslab
    shm.set_stress_tone(board, 1000, -6)
    shm.set_nosc(board, 100)
    shm.set_sdram_words(board, 128)
    time.sleep(1.0)  # SDRAM verify warmup
    _arm_detectors(board, 1000, -6)
    t0 = time.time()
    worst_sinad = float("inf")
    while time.time() - t0 < 60:
        time.sleep(5)
        state = fresh_window(board)
        sinad = state.sinad_db()
        worst_sinad = min(worst_sinad, sinad)
        assert state.cum_clicks == 0, f"click at t={time.time()-t0:.0f}s"
        assert state.cum_dropouts == 0, f"dropout at t={time.time()-t0:.0f}s"
        assert state.cum_sdram_errs == 0, f"SDRAM error at t={time.time()-t0:.0f}s"
    load = board.ping().dsp_load
    shm.set_detectors(board, 0, 0)
    shm.set_nosc(board, 0)
    shm.set_sdram_words(board, 0)
    print(f"\n60 s soak at {load}% load + SDRAM: zero defects, "
          f"worst SINAD {worst_sinad:.1f} dB")
    _report["endurance_60s"] = {"load_pct": load,
                                "worst_sinad_db": round(worst_sinad, 1)}


def test_lifecycle_churn(board):
    """Twenty upload/start/verify/stop cycles, alternating patches — the
    programming path must not degrade with use.

    Runs last: it replaces and stops whatever patch the module fixture
    started, so nothing stateful may follow it."""
    smoke = load_patch_bin("smoke")
    stress = load_patch_bin("stresslab")
    for i in range(20):
        binary, pid = ((smoke, shm.SMOKE_ID) if i % 2 == 0
                       else (stress, shm.STRESSLAB_ID))
        board.run_patch(binary, expect_patch_id=pid, settle_s=0.15)
        hb0 = board.read_u32(shm.SHM_ADDR + 4)
        time.sleep(0.1)
        assert board.read_u32(shm.SHM_ADDR + 4) > hb0, f"cycle {i}: dsp not running"
        board.stop_patch()
        assert board.ping().patch_id == 0, f"cycle {i}: patch did not stop"
