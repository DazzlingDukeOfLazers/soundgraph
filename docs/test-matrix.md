# Test Matrix

## Targets

| Target        | Builds | Unit tests | Golden vectors | Live audio | Status |
|---------------|--------|-----------|----------------|------------|--------|
| Windows x64   | yes    | yes       | yes            | yes        | Milestone A done |
| WASM (Chrome) | yes    | via core  | yes            | yes        | Milestone B done |
| Godot 4.7 win | yes    | 30 checks | via round trip | yes        | Milestone C done |
| ESP32-S3      | yes    | via core  | yes            | yes (Waveshare audio board) | Milestone F done |
| macOS arm64   | yes    | yes       | 12/12 ctest    | yes (miniaudio, CoreAudio) | Godot editor suite green; wasm built with emcc 6.0.6 matches all 18 goldens |
| Linux x64     | —      | —         | —              | —          | not yet exercised |
| Safari        | —      | —         | —              | —          | not yet exercised |
| Firefox       | —      | —         | —              | —          | not yet exercised |
| ESP32-S3      | —      | —         | —              | —          | Milestone F |
| Axoloti Core  | patches via arm-none-eabi-gcc 16 |  67 hardware-in-loop | — (analog loopback instead) | yes (on-board analyzer) | programming + limits proven 2026-08-25 (176 raw osc / 48 Sine nodes / 28 voices; sgaxo goldens: 6 of 7 bit-exact incl. SDRAM delay, first-synth 2e-6); see embedded/axoloti/ |

## Tolerances

Golden comparisons are tolerance based, never bit-exact.

| Comparison            | Tolerance (peak abs error) | Measured |
|-----------------------|----------------------------|----------|
| same target, rebuild  | 0.0 (bit exact expected)   | 0.0      |
| native vs WASM        | 1e-5                       | 2.09e-7 worst case |
| native vs ESP32-S3    | 1e-4                       | 1.90e-5 worst case (delay-feedback); noise and lfo bit-exact |

Rationale: ESP32-S3 has no FPU-identical trig; oscillator phase accumulation and filter
coefficients will diverge in the last few mantissa bits. Any divergence larger than this
indicates a semantic difference, not a floating-point one.

Measured on 2026-08-14, MSVC 19.39 x64 against Emscripten 6.0.6: seven of ten cases are
bit-identical. The three that differ (`sine`, `filter-sweep`, `first-synth`) are exactly
the ones that call `sin` or `tan`, which is the expected shape of a libm difference rather
than a semantic one.

## Running the comparisons

```bash
ctest --test-dir build --output-on-failure   # native, including golden vectors
node runtime-wasm/verify-goldens.mjs         # WebAssembly against the native vectors
godot --headless --path editor-godot --script res://editor_test.gd   # the Godot editor
node tools/verify-roundtrip.mjs              # Godot editor round trip, compared by audio
```

A Godot project must be imported once before its extension is registered — a plain
`--headless --quit` run does not scan the filesystem and the class will appear missing:

```bash
godot --headless --path editor-godot --import
```

The first two read `tests/golden/cases.json`, so neither can drift from the other's
definition of a case. Re-record with `SOUNDGRAPH_UPDATE_GOLDEN=1` and review the diff.

The third is not part of `ctest` because it needs a built `sg-render` and a Godot binary.
It checks meaning rather than text: a patch goes through the editor's real load-and-save
path, and the rendered audio before and after must be identical sample for sample. Set
`GODOT` if the executable is not on the path.

## Editor agreement

| Property | Checked by |
|----------|-----------|
| Godot round trip preserves the graph | `verify-roundtrip.mjs`, identical audio |
| Godot round trip preserves controls, automation and metadata | `verify-roundtrip.mjs`, counts compared |
| Both editors offer the same node vocabulary | both build their palette from `write_registry` |
| Both editors rank intent search identically | both call the core's `search` |
| Both editors report the same problems | both render `write_diagnostics` output |

The last three are structural rather than tested: neither editor holds a copy of the
vocabulary, the ranking or the validator, so there is nothing to drift.

## Per-node coverage

Each node should have: a unit test (behaviour), a serialization test (round-trip), and a
golden vector where its output is non-trivial.

| Node                 | Unit | Serialization | Golden |
|----------------------|------|---------------|--------|
| SineOscillator       | yes  | yes           | yes    |
| SawOscillator        | yes  | yes           | yes    |
| SquareOscillator     | yes  | yes           | yes    |
| Noise                | yes  | yes           | yes (fixed seed) |
| Gain                 | yes  | yes           | —      |
| Mixer                | yes  | yes           | —      |
| ADSR                 | yes  | yes           | yes    |
| LFO                  | yes  | yes           | yes    |
| StateVariableFilter  | yes  | yes           | yes    |
| Delay                | yes  | yes           | yes    |
| Constant             | yes  | yes           | —      |
| Add                  | yes  | yes           | —      |
| Multiply             | yes  | yes           | —      |
| NoteInput            | yes  | yes           | —      |
| AudioInput           | yes  | yes           | —      |
| StereoOutput         | yes  | yes           | —      |

## Graph-level tests

All present and passing as of 2026-08-07.

- topological ordering of a chain and of a diamond graph
- zero-delay cycle rejected, with every node in the loop named and every edge highlighted
- self-connection treated as a cycle
- cycle through `Delay` accepted and reported as a feedback edge
- unknown node type rejected, naming the type
- unknown port rejected, listing the ports that do exist
- duplicate node ids rejected
- second connection into a single-value input rejected, suggesting a Mixer
- summing inputs accept several connections
- missing required input reported against the node
- control surface pointing at a parameter that does not exist rejected
- unsupported `schema_version` refused outright
- block-size independence: 4800, 64 and 37 frame host buffers produce identical output
- `reset()` returns the graph to a byte-identical starting state
- notes reach `NoteInput` and drive the envelope; nothing sounds before the first note
- parameter changes applied through the control queue take effect
- several `StereoOutput` nodes sum onto the master bus
- intent-based node search ("remove high frequencies", "midi keyboard", "make quieter")
- every shipped example patch loads, validates, builds and round-trips unchanged
- `first-synth.json` renders a stable golden vector at correct pitches
