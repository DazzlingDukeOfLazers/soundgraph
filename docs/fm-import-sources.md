# FM import sources

Where the next patch libraries come from: FOSS FM synths and C-based engines whose patch
formats can be mapped onto SoundGraph documents, the way sfxr already was. The sfxr port
set the pattern this list assumes: a reference C implementation vendored as an **oracle**
(`tools/sfxr-ref`), a mapper that emits SoundGraph JSON, and golden vectors proving the
mapping on every target.

## The gate: dsp-core cannot say "FM" yet

The oscillators' `fm` input is **exponential, in octaves** (`frequency *= 2^fm`) — pitch
modulation, right for vibrato and sweeps. Yamaha-style FM — DX7, OPL, Genesis, every
format below — is **linear phase modulation**: the modulator's output is added to the
carrier's *phase*, and the sidebands that make FM sound like FM come from exactly that
linearity. No patch below can be imported faithfully until an oscillator has a linear
`pm` input (and, for every Yamaha format, operator **feedback** — an operator phase-
modulating itself). That work comes first and is small; it is listed at the bottom.

## Priorities

### 1. OPL2 — Freedoom's GENMIDI bank (2-operator)

The smallest faithful step, and the best licence story in FM.

- **Patch data**: [Freedoom](https://github.com/freedoom/freedoom/tree/master/lumps/genmidi)
  builds its GENMIDI from individual SBI files whose instruments come from **OpenBSD's
  kernel** — BSD-licensed, 128 GM melodic + 47 percussion, all original content by
  policy. 175 instruments, every one redistributable.
- **Formats**: SBI (one instrument, trivially documented) and OP2/GENMIDI
  (175 concatenated, [spec on Kaitai](https://formats.kaitai.io/genmidi_op2/index.html)).
  Bytes, not XML.
- **Oracle**: [Nuked-OPL3](https://github.com/nukeykt/Nuked-OPL3), LGPL 2.1, single C
  file, the accepted accuracy benchmark. LGPL is fine for a build-time oracle that never
  ships in the product.
- **Model**: 2 operators, feedback on the modulator, AM/FM connection bit, 4 waveforms
  (sine, half, abs, quarter — trivially cheap), per-op ADSR-style rates, key scaling.
- **Why first**: two operators is the minimal real FM graph; the instrument set covers
  all of General MIDI so an imported library is immediately *useful*; the game-audio
  heritage (AdLib, Doom) matches where SoundGraph already lives; and 2-op FM costs
  almost nothing on the ESP32.

### 2. DX7 — SysEx banks via the Dexed/MSFA engine (6-operator)

The flagship. A DX7 **algorithm is literally a signal-flow graph** of six operators —
importing a patch means *generating topology*, which is the whole SoundGraph thesis
made audible.

- **Patch data**: thousands of banks in 4104-byte 32-voice SysEx. Licensing varies by
  bank: [Musical Artifacts](https://musical-artifacts.com/artifacts?asc=true&order=updated_at&tags=dx7)
  lists per-artifact licences (start there);
  [Bobby Blues' collection](https://bobbyblues.recup.ch/yamaha_dx7/dx7_patches.html)
  declares everything it publishes public domain; the **Yamaha factory ROM banks are
  not ours to ship** — do not import them, however traditional it is.
- **Oracle**: [Dexed](https://github.com/asb2m10/dexed) is GPL v3, but its engine —
  `msfa`, music-synthesizer-for-android — is deliberately kept **Apache 2.0** for
  reuse. [hexter](https://github.com/smbolton/hexter) (GPL2, C) is a second opinion.
- **Model**: 6 ops, 32 algorithms, feedback on one op, 8-segment rate/level envelopes,
  keyboard rate+level scaling, LFO with per-op sensitivity, fixed-frequency mode.
- **Why second**: 10× the surface of OPL2. Worth doing in stages — algorithms and
  envelopes first (that already sounds like a DX7), scaling and LFO after.

### 3. OPN2 / YM2612 — Sega Genesis instruments (4-operator)

- **Patch data**: TFI / DMP / VGI / Y12 instrument files from the DefleMask ecosystem.
  Plentiful but community-ripped from commercial games more often than not —
  **licensing is the weak point**; import the format, curate the data hard.
- **Oracle**: Nuked-OPN2 (same author and licence as Nuked-OPL3).
- **Why third**: 4 ops with per-op detune/multiple sits neatly between OPL2 and DX7,
  and the formats are tiny. Only the provenance problem keeps it out of second place.

### 4. TX81Z (4-op, the OPL waveform trick meets DX envelopes) — SysEx, smaller patch
universe, good fourth once OPL2 and DX7 mappers exist to share code.

### Not prioritized

- **ZynAddSubFX / Surge XT** — magnificent synths, but their patch formats describe an
  architecture SoundGraph would have to *become* rather than *map*; instrument data is
  GPL besides.
- **Vital(ium)** — JSON patches, but wavetable-first; the FM is incidental.
- **munt (MT-32)** — LA synthesis is PCM+subtractive, not FM.

## The dsp-core work the imports gate on

1. ~~`pm` input (linear phase, audio-rate) on the oscillators~~ — **done**, with a
   lesson attached: the feedback golden diverged to full scale in WASM because three
   libms round `std::sin` three ways and a feedback loop compounds one ULP to
   everything. dsp-core owns its sine now (committed table, `make-sine-table.py`), and
   all 20 goldens are bit-exact across native, WASM and the ESP32.
2. ~~Operator feedback~~ — **done**: `feedback` on SineOscillator, two-sample averaged
   like the chips. The importer maps OPL feedback 1–7 to 2^(fb−1)/32 cycles (fb 7 = the
   chip's 4π). Remaining honesty gap: the chip feeds back the *enveloped* output, ours
   is constant-strength — noted per patch.
3. ~~OPL waveform variants~~ — **done**: a shape enum on the sine (sine/half/
   absolute/quarter), built from the owned table so the shapes are bit-exact on every
   target. The full 128-voice melodic bank is imported and every voice agrees with the
   Nuked-OPL3 oracle on pitch and presence in ctest. Second voices (-2 files) and the
   47 percussion entries remain out of scope, noted in tools/opl2/README.md.
4. Rate-based envelopes — handled in the mapper as a fitted rate→time curve. The
   **Nuked-OPL3 oracle now exists** (`tools/opl2-ref`, LGPL emulator vendored under
   `tests/opl2/reference/`) and `tools/opl2-compare.mjs` holds every import to the
   oracle's pitch and presence in ctest; the fitted curve's calibration against oracle
   renders is the natural next use of it. Current level offset vs the oracle: a uniform
   +10 to +22 dB (the chip mixes nine voices into its headroom), reported per run.

Each step lands like every dsp-core change: unit tests, a golden vector, native/WASM
parity, ESP32 verification when a board is on.
