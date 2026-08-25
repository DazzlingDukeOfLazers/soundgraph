# axoloti

Hardware-in-the-loop tests for the Axoloti Core (STM32F427, stock firmware
1.0.12-2). First station of the "Axoloti/Ksoloti experiments" roadmap item:
prove we can program the board over USB, then find its realtime limits.

No Java patcher anywhere: the host speaks the board's vendor bulk USB protocol
directly (`driver/axoproto.py`), and test patches are hand-written C++ against
a self-declared ABI (`patches/axo_abi.h`), linked against the stock firmware's
symbols. Protocol and ABI reference: `firmware/pconnection.c` and
`firmware/patch.h` at tag `1.0.12-2` of https://github.com/axoloti/axoloti.

## Wiring

USB to the board's device port. Audio out -> audio in with a patch cable
(mono is fine — the tests use the left channel and report what the right one
carries). The loopback lets the on-board analyzer verify real audio without
any host audio interface.

## Setup

```sh
brew install libusb arm-none-eabi-gcc arm-none-eabi-binutils
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
tools/fetch-sdk.sh          # official 1.0.12-2 release, pinned sha256 -> sdk/
make -C patches             # -> patches/build/*.bin
```

`sdk/` holds GPL-3.0 upstream artifacts (firmware elf/bin, linker script) and
is fetched, not committed.

## Run

```sh
.venv/bin/pytest tests -v -s
```

Everything skips cleanly when no board is on USB, so this suite is safe to
point CI at; it is deliberately not wired into the repo's default ctest run.

Tiers, in dependency order:

| file | proves | needs |
|------|--------|-------|
| `tests/test_link.py` | enumeration, ping/ack, firmware identity | board |
| `tests/test_programming.py` | memory write/read-back = the patch upload path, throughput floors | board |
| `tests/test_patch_run.py` | compiled patches execute: heartbeat at 3000 cycles/s, clean restart | board + built patches |
| `tests/test_limits.py` | analog loopback integrity, DSP load ramp -> max clean oscillator count (`tests/reports/dsp_limits.json`) | board + loopback cable |

## How the pieces talk

- Host -> board: `AxoW` (memory write) uploads, `Axos`/`AxoS` start/stop,
  `Axor`/`Axoy` read memory, `Axop` ping. Acks (`AxoA`) carry `dspLoadPct`
  and the running patch id.
- Patch -> host: a fixed shared-memory block at `0x2001C000`
  (`patches/sg_shm.h` = `tests/shm.py`) with a heartbeat, an input analyzer
  (peak/mean-square/zero-crossings per 100 ms window) and controls the host
  pokes by memory write (tone on/off, load-bank size).
- The load bank in `patches/looplab.cpp` burns DSP cycles in 0..1024
  oscillator steps without touching the audio path, so overload shows up
  as missed cycles and loopback dropouts — which is the point.

## Known limits (device-reported, see tests/reports/)

Patch code+rodata window is 44 KB (`ramlink.ld`), upload runs ~60 KB/s
(the firmware parses uploads byte-by-byte), readback ~700 KB/s.

Realtime ceilings measured on a stock Core (clean = all three overload
signals green, loopback verified):

| workload | clean limit | ~load/unit |
|----------|-------------|------------|
| raw q32 phase-acc oscillators (`looplab`) | 176 | 0.52% |
| soundgraph Sine nodes, faithful float port (`nodelab`) | 48 | 1.9% |
| Sine→SVF→Gain voices (`nodelab`) | 28 (84 nodes) | 3.3% |

The Sine node costs ~3.7x a raw oscillator: float table-lerp is cheap on the
M4F, but the per-sample nullptr checks, nyquist clamp and the
`frequency / sample_rate` divide (14-cycle FPU op, per sample) add up. A full
voice is ~1.7 Sine-equivalents — the SVF's five-multiply core plus Gain are
cheaper than the oscillator that feeds them.

One trap for posterity: a marginally seated USB cable brownout-crashes the
board under load and looks exactly like a patch bug (crashes within seconds
whenever the DSP load rises, stable at idle). It cost an afternoon and an
instruction-level binary diff to prove the code innocent. Every ramp
measurement now records the 5 V rail (`v50_raw`, ~3100 healthy); the readings
are noisy, so judge by crashes, not by single samples.
