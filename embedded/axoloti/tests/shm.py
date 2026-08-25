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
STRESSLAB_ID = 0x53545231    # "STR1"

# magic, heartbeat, ctrl_tone, ctrl_nosc, ctrl_nsine, ctrl_nvoice, win_count,
# msq_l, msq_r, peak_l, peak_r, zerocross_l, dcsum_l (8-aligned at 48), sink,
# then the stress block: ctrl_step, ctrl_amp, ctrl_coeff, ctrl_slope_max,
# ctrl_floor, ctrl_sdram_words, cum_clicks, cum_dropouts, cum_sdram_errs,
# goertzel_sig, goertzel_tot
_FMT = "<IIiiiiIIIiiIqI" + "IiIiiIIIIII"
SIZE = struct.calcsize(_FMT)

OFF_CTRL_TONE = 8
OFF_CTRL_NOSC = 12
OFF_CTRL_NSINE = 16
OFF_CTRL_NVOICE = 20
OFF_CTRL_STEP = 60
OFF_CTRL_AMP = 64
OFF_CTRL_COEFF = 68
OFF_CTRL_SLOPE_MAX = 72
OFF_CTRL_FLOOR = 76
OFF_CTRL_SDRAM_WORDS = 80
OFF_CUM_COUNTERS = 84        # clicks, dropouts, sdram_errs — three u32s

SAMPLE_RATE = 48000
Q27 = 1 << 27


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
    ctrl_step: int
    ctrl_amp: int
    ctrl_coeff: int
    ctrl_slope_max: int
    ctrl_floor: int
    ctrl_sdram_words: int
    cum_clicks: int
    cum_dropouts: int
    cum_sdram_errs: int
    goertzel_sig: int
    goertzel_tot: int

    def sinad_db(self):
        """SINAD of the last window from the on-board Goertzel, in dB.

        goertzel_sig is s1^2 + s2^2 - coeff*s1*s2 for a window of N samples of
        x scaled to +-1; for a sine of amplitude A at the bin it equals
        A^2*N^2/4, so signal mean-square is 2*sig/N^2 and noise+distortion is
        the total mean-square minus that.
        """
        import math
        n = WINDOW_SAMPLES
        sig = struct.unpack("<f", struct.pack("<I", self.goertzel_sig))[0]
        tot = struct.unpack("<f", struct.pack("<I", self.goertzel_tot))[0]
        signal_ms = 2.0 * sig / (n * n)
        noise_ms = tot / n - signal_ms
        if signal_ms <= 0:
            return float("-inf")
        if noise_ms <= 0:
            # Float32 accumulation can't resolve noise this far below the
            # signal; report the estimator's ceiling rather than infinity.
            return 60.0
        return min(10 * math.log10(signal_ms / noise_ms), 60.0)

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

    @property
    def rms_l_dbfs(self):
        """Left input RMS level re q27 full scale, from the window mean-square.

        in_msq_l = (sum of (x>>8)^2) >> 20 over 4800 samples, so mean-square
        in q27^2 units is msq * 2^36 / 4800.
        """
        import math
        if self.in_msq_l <= 0:
            return float("-inf")
        ms = self.in_msq_l * (2 ** 36) / WINDOW_SAMPLES
        return 10 * math.log10(ms / (2 ** 54))


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


# --- stresslab controls ------------------------------------------------------

def set_stress_tone(board, freq_hz, amp_dbfs):
    """Configure the variable tone and the matching Goertzel coefficient.

    Use frequencies that are a multiple of 10 Hz so they land on an exact bin
    of the 4800-sample (100 ms) analysis window. amp_dbfs=None silences.
    """
    import math
    if amp_dbfs is None:
        amp = 0
    else:
        amp = int(Q27 * (10 ** (amp_dbfs / 20)))
    step = int(freq_hz * (1 << 32) / SAMPLE_RATE) & 0xFFFFFFFF
    coeff = 2.0 * math.cos(2 * math.pi * freq_hz / SAMPLE_RATE)
    board.write_mem(SHM_ADDR + OFF_CTRL_STEP,
                    struct.pack("<IiI", step, amp, struct.unpack(
                        "<I", struct.pack("<f", coeff))[0]))


def set_detectors(board, slope_max, floor_pk):
    """Arm the click/dropout detectors (0 disables either)."""
    board.write_mem(SHM_ADDR + OFF_CTRL_SLOPE_MAX,
                    struct.pack("<ii", slope_max, floor_pk))


def set_sdram_words(board, words):
    board.write_mem(SHM_ADDR + OFF_CTRL_SDRAM_WORDS, struct.pack("<I", words))


def clear_counters(board):
    board.write_mem(SHM_ADDR + OFF_CUM_COUNTERS, struct.pack("<III", 0, 0, 0))


def slope_max_for(freq_hz, amp_dbfs, margin=3.0):
    """Steepest legitimate inter-sample step of the loopback tone, q27,
    with a safety margin for analog gain error and noise."""
    import math
    amp = Q27 * (10 ** (amp_dbfs / 20))
    return int(amp * 2 * math.pi * freq_hz / SAMPLE_RATE * margin)
