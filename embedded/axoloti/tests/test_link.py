"""Tier 1: the USB link. No toolchain or built patches required."""

import statistics
import time

import axoproto


def test_firmware_identity(board):
    fw = board.fw_info()
    assert fw.patchmainloc == axoproto.PATCHMAINLOC
    assert fw.fwid == axoproto.STOCK_1_0_12_2_FWID, (
        f"board firmware id {fw.fwid:#010x} is not stock 1.0.12-2 "
        f"({axoproto.STOCK_1_0_12_2_FWID:#010x}); the prebuilt test patches "
        "link against stock symbols and will refuse to start. Re-fetch an SDK "
        "matching the board's firmware, or reflash stock 1.0.12-2.")


def test_ping_reports_sane_state(board):
    ack = board.ping()
    assert 0 <= ack.dsp_load <= 100
    assert ack.fs_ready in (0, 1)


def test_ping_latency(board):
    latencies = []
    for _ in range(50):
        t0 = time.monotonic()
        board.ping()
        latencies.append(time.monotonic() - t0)
    median = statistics.median(latencies)
    assert median < 0.05, f"median ping latency {median * 1000:.1f} ms"
