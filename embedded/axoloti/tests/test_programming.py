"""Tier 2: the programming path — generic memory write/read over USB, which is
exactly how patch binaries reach the board. No toolchain required."""

import os
import struct
import time

import pytest

import axoproto


@pytest.fixture(autouse=True)
def stopped(board):
    board.stop_patch()
    yield


@pytest.mark.parametrize("size", [4, 64, 1024, 4096, 16384, axoproto.PATCH_CODE_SIZE])
def test_roundtrip_random(board, size):
    payload = os.urandom(size)
    board.write_mem(axoproto.PATCHMAINLOC, payload)
    assert board.read_mem(axoproto.PATCHMAINLOC, size) == payload


def test_roundtrip_counter_pattern(board):
    payload = struct.pack("<1024I", *range(1024))
    board.write_mem(axoproto.PATCHMAINLOC, payload)
    assert board.read_mem(axoproto.PATCHMAINLOC, len(payload)) == payload


def test_word_read_matches_block_read(board):
    payload = os.urandom(16)
    board.write_mem(axoproto.PATCHMAINLOC, payload)
    for i in range(4):
        word = board.read_u32(axoproto.PATCHMAINLOC + 4 * i)
        assert word == struct.unpack_from("<I", payload, 4 * i)[0]


def test_oversized_patch_rejected(board):
    with pytest.raises(ValueError):
        board.upload_patch(b"\x00" * (axoproto.PATCH_CODE_SIZE + 4))


def test_upload_throughput_floor(board):
    """Regression floor, not a benchmark: measured ~63 KB/s up, ~770 KB/s down
    on the byte-state-machine firmware; fail only on collapse."""
    payload = os.urandom(32768)
    t0 = time.monotonic()
    board.write_mem(axoproto.PATCHMAINLOC, payload)
    up = len(payload) / (time.monotonic() - t0)
    t0 = time.monotonic()
    board.read_mem(axoproto.PATCHMAINLOC, len(payload))
    down = len(payload) / (time.monotonic() - t0)
    print(f"\nupload {up / 1024:.0f} KB/s, readback {down / 1024:.0f} KB/s")
    assert up > 20 * 1024
    assert down > 80 * 1024
