"""Tier 7: the microSD slot. Skips entirely until a card is inserted.

Card requirements (see README): FAT32, so 32 GB or smaller out of the box —
the 1.0.12 FatFs build has no exFAT. Speed class is nearly irrelevant over
this path: host-side writes are bottlenecked by the ~62 KB/s USB upload, and
the board's SDIO tops out far below any modern card's rating.

The protocol offers create/append/close/delete/mkdir/stat/list but no file
read-back, so content integrity is verified via sizes, listings and free-space
accounting; the read path gets exercised by the board's own /start.bin boot
mechanism, which needs a power cycle and stays a manual check.
"""

import os
import time

import pytest

import axoproto

TEST_DIR = "/sgtest"


@pytest.fixture(scope="module")
def sd(board):
    board.stop_patch()
    # Any file operation makes the firmware attempt to mount the card.
    board.sd_info("/")
    if board.ping().fs_ready != 1:
        pytest.skip("no mounted SD card — insert a FAT32-formatted microSD")
    board.sd_mkdir(TEST_DIR)
    yield board
    # Remove everything the tests left behind, files before their directory.
    try:
        _, entries = board.sd_dir_listing()
        victims = sorted((n for n, _s, _t in entries
                          if n.startswith(TEST_DIR.lstrip("/"))),
                         key=len, reverse=True)
        for name in victims:
            board.sd_delete("/" + name.rstrip("/"))
    except axoproto.ProtocolError:
        pass


def _write_file(board, path, data, chunk=16384):
    board.sd_create(path, prealloc=len(data))
    for off in range(0, len(data), chunk):
        board.sd_append(data[off:off + chunk])
    board.sd_close()


def test_write_and_stat(sd):
    board = sd
    payload = os.urandom(65536)
    _write_file(board, TEST_DIR + "/a.bin", payload)
    info = board.sd_info(TEST_DIR + "/a.bin")
    assert info is not None, "file vanished"
    assert info[0] == len(payload), f"size {info[0]} != {len(payload)}"


def test_listing_sees_the_file(sd):
    board = sd
    _, entries = board.sd_dir_listing()
    names = {n: s for n, s, _t in entries}
    assert "sgtest/a.bin" in names, f"listing missing our file: {sorted(names)[:10]}"
    assert names["sgtest/a.bin"] == 65536


def test_many_small_files(sd):
    board = sd
    for i in range(20):
        _write_file(board, f"{TEST_DIR}/small{i:02d}.bin", os.urandom(1024))
    _, entries = board.sd_dir_listing()
    small = [n for n, _s, _t in entries if "small" in n]
    assert len(small) == 20, f"listing shows {len(small)}/20 small files"
    for i in range(20):
        board.sd_delete(f"{TEST_DIR}/small{i:02d}.bin")
    _, entries = board.sd_dir_listing()
    assert not [n for n, _s, _t in entries if "small" in n], "delete left files"


def test_write_throughput_and_free_space(sd):
    board = sd
    stats0, _ = board.sd_dir_listing()
    payload = os.urandom(262144)
    t0 = time.monotonic()
    _write_file(board, TEST_DIR + "/big.bin", payload)
    rate = len(payload) / (time.monotonic() - t0) / 1024
    print(f"\nSD write via USB: {rate:.0f} KB/s "
          "(USB-bound; not a card benchmark)")
    assert rate > 20, "SD write path implausibly slow"
    board.sd_delete(TEST_DIR + "/big.bin")
    stats1, _ = board.sd_dir_listing()
    assert stats1[0] >= stats0[0], (
        f"free clusters fell {stats0[0]} -> {stats1[0]} after create+delete")


def test_overwrite_shrinks(sd):
    board = sd
    _write_file(board, TEST_DIR + "/shrink.bin", os.urandom(32768))
    _write_file(board, TEST_DIR + "/shrink.bin", os.urandom(1024))
    info = board.sd_info(TEST_DIR + "/shrink.bin")
    assert info is not None and info[0] == 1024, (
        "create-always did not truncate on overwrite")
