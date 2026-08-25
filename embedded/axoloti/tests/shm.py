"""Python mirror of patches/sg_shm.h — keep the two in lockstep."""

import struct
from dataclasses import dataclass

SHM_ADDR = 0x2001C000
WINDOW_CYCLES = 300          # dsp cycles per analyzer window
WINDOW_SAMPLES = WINDOW_CYCLES * 16   # 4800 samples = 100 ms
CYCLES_PER_SECOND = 3000     # 48 kHz / 16-sample buffers

SMOKE_ID = 0x534D4B31        # "SMK1"
LOOPLAB_ID = 0x4C4F4F31      # "LOO1"
NODELAB_ID = 0x4E4F4431      # "NOD1"

# magic, heartbeat, ctrl_tone, ctrl_nosc, ctrl_nsine, ctrl_nvoice, win_count,
# msq_l, msq_r, peak_l, peak_r, zerocross_l, dcsum_l (8-aligned at 48), sink
_FMT = "<IIiiiiIIIiiIqI"
SIZE = struct.calcsize(_FMT)

OFF_CTRL_TONE = 8
OFF_CTRL_NOSC = 12
OFF_CTRL_NSINE = 16
OFF_CTRL_NVOICE = 20


@dataclass
class Shm:
    magic: int
    heartbeat: int
    ctrl_tone: int
    ctrl_nosc: int
    ctrl_nsine: int
    ctrl_nvoice: int
    win_count: int
    in_msq_l: int
    in_msq_r: int
    in_peak_l: int
    in_peak_r: int
    in_zerocross_l: int
    in_dcsum_l: int
    sink: int

    @property
    def peak_l_dbfs(self):
        """Left input peak relative to q27 full scale, in dB."""
        import math
        if self.in_peak_l <= 0:
            return float("-inf")
        return 20 * math.log10(self.in_peak_l / (1 << 27))

    @property
    def zc_frequency_hz(self):
        """Tone frequency estimated from zero crossings of one 100 ms window."""
        return self.in_zerocross_l / 2 * (1000 / 100)


def read_shm(board) -> Shm:
    return Shm(*struct.unpack(_FMT, board.read_mem(SHM_ADDR, SIZE)))


def set_tone(board, on):
    board.write_mem(SHM_ADDR + OFF_CTRL_TONE, struct.pack("<i", 1 if on else 0))


def set_nosc(board, n):
    board.write_mem(SHM_ADDR + OFF_CTRL_NOSC, struct.pack("<i", n))


def set_nsine(board, n):
    board.write_mem(SHM_ADDR + OFF_CTRL_NSINE, struct.pack("<i", n))


def set_nvoice(board, n):
    board.write_mem(SHM_ADDR + OFF_CTRL_NVOICE, struct.pack("<i", n))
