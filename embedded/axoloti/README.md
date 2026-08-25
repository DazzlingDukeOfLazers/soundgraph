# axoloti

Hardware-in-the-loop tests for the Axoloti Core (STM32F427, stock firmware
1.0.12-2). First station of the "Axoloti/Ksoloti experiments" roadmap item:
prove we can program the board over USB, then find its realtime limits.

No Java patcher anywhere: the host speaks the board's vendor bulk USB protocol
directly (`driver/axoproto.py`), and test patches are hand-written C++ against
a self-declared ABI (`patches/axo_abi.h`), linked against the stock firmware's
symbols. Protocol and ABI reference: `firmware/pconnection.c` and
`firmware/patch.h` at tag `1.0.12-2` of https://github.com/axoloti/axoloti.

## Wiring and rig shopping list

USB to the board's device port. Audio out -> audio in with a patch cable
(mono is fine — the tests use the left channel and report what the right one
carries). The loopback lets the on-board analyzer verify real audio without
any host audio interface.

The full rig, in order of usefulness per dollar:

- **Nothing** — the USB device port already carries the test protocol *and*
  class-compliant USB MIDI, so `test_midi.py`'s USB tier runs today.
- **6.35 mm TRS male-male patch cable** — upgrades the mono loop to stereo,
  so the right channel gets the same analyzer treatment as the left.
- **5-pin DIN MIDI cable, male-male** — MIDI OUT looped to MIDI IN. The DIN
  tests self-detect it and light up: burst integrity, wire-speed throughput,
  behavior under DSP load.
- **3.5 mm TRS male → 6.35 mm TRS male cable** — headphone out looped into
  line in, to exercise the codec's headphone driver path. Swap with the main
  loop between runs; the analyzer's level/channel signature says what's
  connected.
- **microSD card, 32 GB or smaller, any name brand** — must be FAT32 (the
  1.0.12 FatFs has no exFAT, so SDXC needs reformatting). Speed class is
  irrelevant here: host-side writes are USB-bound at ~62 KB/s and the F427's
  SDIO tops out far below modern card ratings — a plain Class 10/UHS-I is
  already overkill. Two cards beat one big one (A/B swaps, one sacrificial).
- **USB MIDI device for the host (A) port** — anything class-compliant:
  Korg nanoKEY2 / Akai LPK25 (USB mini-B), Arturia MiniLab 3 or Novation
  Launchpad Mini MK3 (USB-C). For *automated* testing the best device is a
  Raspberry Pi Pico (~$5) or a spare ESP32-S3 devkit running as a TinyUSB
  MIDI gadget — programmable to send deterministic bursts and echo, which
  turns the skipped USB-host test into a real closed loop.

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

## sgaxo: soundgraph patches, compiled for the board

`sgaxo/codegen.py` compiles a soundgraph patch (JSON) into an Axoloti patch
binary: validate against the declared node subset, generate C++ over the
kernel library (`sgaxo/kernels.h`, line-for-line restatements of dsp-core
inner loops), compile with arm-none-eabi-g++ against the stock firmware, and
upload over the driver. The board renders the shared golden vectors and the
host reads the raw float32 samples back over USB:

- six of seven golden cases **bit-exact** (max abs error 0): sine, noise,
  noise-pink, square, delay-feedback (through the SDRAM delay line), and
  ahd-envelope
- `first-synth` (note events, saw, LFO-modulated SVF, ADSR, limiter):
  **max abs error 2e-6** — 50x inside the 1e-4 cross-target tolerance; the
  residual is the SVF's on-board polynomial tan/exp2

Fidelity comes from three rules: the graph runs at dsp-core's 64-frame block
size behind a FIFO (per-block semantics are part of the golden recordings);
every parameter-derived coefficient (ADSR exp curves, glide) is precomputed
on the host in double precision and baked as a literal; and only per-block
modulation math (SVF tan/exp2) runs on the board, as short polynomials.
`-ffp-contract=off` keeps rounding identical to native.

Compiled patches are playable instruments: live MIDI (any transport) drives
the same note handler the golden events replay through.

Supported today: Input(note)/Output seams, Sine/Saw/Square oscillators,
Noise (white and pink), LFO (all shapes), StateVariableFilter, Delay
(SDRAM-backed, 2 s), ADSR, AhdEnvelope, Retrigger, Gain. Everything else is
refused by name
at compile time — the subset is a tested claim, not a vibe.

```sh
python3 sgaxo/codegen.py path/to/patch.json   # -> sgaxo/build/patch.bin
```

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

The stress tier (`tests/test_stress.py`, `patches/stresslab.cpp`) characterizes
the engine rather than just finding its ceiling. Measured on this rig:

- noise floor −66 dBFS RMS; loopback gain −7.6 dB
- amplitude linearity exact (6.0 dB steps) from −36 to −1 dBFS
- frequency response flat within ±0.1 dB, 50 Hz – 20 kHz
- SINAD ~47 dB at −6 dBFS, unchanged from idle to 85% DSP load
  (measurement is loopback path + float32 estimator; ceiling 60 dB)
- zero clicks/dropouts across 5 s at 84% load, 44 idle↔84% load flips,
  USB hammering (129 KB/s readback while at 84%), and a 60 s
  everything-at-once soak (63% load + SDRAM traffic)
- SDRAM: 24.6 MB/s write+verify traffic clean at 68% load; pushing 49 MB/s
  overloads the CPU (audible dropouts) but never corrupts a word
- 20 upload/start/stop churn cycles without degradation

`tools/soak.py --minutes 30` runs the everything-at-once soak for as long as
you like, with per-10 s defect reporting.

One trap for posterity: a marginally seated USB cable brownout-crashes the
board under load and looks exactly like a patch bug (crashes within seconds
whenever the DSP load rises, stable at idle). It cost an afternoon and an
instruction-level binary diff to prove the code innocent. Every ramp
measurement now records the 5 V rail (`v50_raw`, ~3100 healthy); the readings
are noisy, so judge by crashes, not by single samples.
