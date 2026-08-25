"""Tier 3: real patch execution — upload a compiled patch, watch it live."""

import time

import shm
from conftest import load_patch_bin


def test_smoke_patch_executes(board):
    binary = load_patch_bin("smoke")
    ack = board.run_patch(binary, expect_patch_id=shm.SMOKE_ID)
    assert ack.patch_id == shm.SMOKE_ID
    assert board.read_u32(shm.SHM_ADDR) == shm.SMOKE_ID  # magic

    hb0 = board.read_u32(shm.SHM_ADDR + 4)
    t0 = time.monotonic()
    time.sleep(0.5)
    hb1 = board.read_u32(shm.SHM_ADDR + 4)
    elapsed = time.monotonic() - t0
    rate = (hb1 - hb0) / elapsed
    # 48 kHz / 16-sample buffers = 3000 dsp cycles per second.
    assert 0.9 * shm.CYCLES_PER_SECOND < rate < 1.1 * shm.CYCLES_PER_SECOND, \
        f"heartbeat {rate:.0f}/s, expected ~{shm.CYCLES_PER_SECOND}"

    board.stop_patch()
    assert board.ping().patch_id == 0


def test_looplab_starts_and_analyzes(board):
    binary = load_patch_bin("looplab")
    board.run_patch(binary, expect_patch_id=shm.LOOPLAB_ID)
    time.sleep(0.5)
    state = shm.read_shm(board)
    assert state.magic == shm.LOOPLAB_ID
    assert state.win_count >= 3            # analyzer windows are being published
    assert state.ctrl_tone == 0
    assert state.ctrl_nosc == 0
    ack = board.ping()
    assert ack.dsp_load < 20, f"idle looplab at {ack.dsp_load}% dsp load"
    board.stop_patch()


def test_patch_restart_is_clean(board):
    """Upload/start/stop twice — the second life must behave like the first."""
    binary = load_patch_bin("smoke")
    for _ in range(2):
        board.run_patch(binary, expect_patch_id=shm.SMOKE_ID)
        hb0 = board.read_u32(shm.SHM_ADDR + 4)
        time.sleep(0.2)
        assert board.read_u32(shm.SHM_ADDR + 4) > hb0
        board.stop_patch()
