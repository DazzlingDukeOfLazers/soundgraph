# SoundGraph Architecture

## Objective

No frontend, host, or board target owns graph semantics.

```text
UI / Host / Hardware
        |
        v
SoundGraph APIs
        |
        v
Graph Model + DSP Core
```

## Suggested monorepo

```text
soundgraph/
    README.md
    CLAUDE.md

    docs/
        PLAN.md
        ARCHITECTURE.md
        ROADMAP.md
        UX_PRINCIPLES.md
        KNOBCon_2026.md
        decisions.md
        current-phase.md
        known-issues.md
        test-matrix.md

    schema/
        patch.schema.json
        board.schema.json
        controls.schema.json

    dsp-core/
        include/
        src/
        tests/

    runtime-native/
    runtime-wasm/

    editor-web/
    editor-godot/

    plugin/
        wrapper/

    embedded/
        common/
        esp32-s3/
        esp32-p4/
        boards/

    tools/
        patch-validator/
        golden-test/
        board-generator/

    examples/
        patches/
        boards/
        audio/

    tests/
        golden/
        integration/
```

Start as a monorepo. Split only when a component has a stable API and an independent release reason.

## Patch model

Every patch includes `schema_version`.

Conceptual structure:

```json
{
  "schema_version": 1,
  "metadata": {},
  "nodes": [],
  "connections": [],
  "controls": [],
  "automation": []
}
```

Each node needs a stable `id`, `type`, and parameters.

Connections identify source node/port and destination node/port. Connections are typed and validated.

Parameters should eventually describe:
- unit
- min/max/default
- scaling
- smoothing
- automation capability

Control surfaces are separate from DSP graphs. The same graph parameter may be controlled by a Godot knob, browser slider, DAW automation lane, touchscreen, MIDI controller, or physical encoder.

## DSP core

Prefer portable C++.

Conceptual API:

```cpp
class DspNode {
public:
    void prepare(const PrepareContext&);
    void process(const ProcessContext&);
    void set_parameter(ParameterId, float value);
    void reset();
};
```

Requirements:
- no UI dependency
- no filesystem/network in realtime processing
- no dynamic allocation in steady-state processing
- explicit state/memory needs
- deterministic tests
- target compatibility metadata

## Graph runtime

At load:

```text
parse
validate schema
validate node types
validate ports
validate graph structure
resolve nodes
topological sort
allocate buffers/state
construct processing schedule
```

Avoid locks and allocation in the audio callback.

## Feedback

Do not silently accept arbitrary zero-time cycles. Feedback should be explicit and valid only when a delay/state element breaks the cycle.

Errors should identify the actual loop and offer an actionable fix.

## Parameter updates

Support:
- immediate set
- smoothed set
- scheduled automation

Do not rebuild the graph for knob movement.

## WASM

Preferred browser architecture:

```text
Web/Godot UI
      |
graph + control messages
      |
AudioWorklet
      |
WASM DSP Core
      |
WebAudio
```

Keep DSP off the main UI thread.

## Desktop

Desktop is a thin host around:
- audio devices
- MIDI devices
- SoundGraph runtime
- editor
- storage

## Plugins

Target:
- macOS AU
- macOS VST3
- Windows VST3

AU is a first-class Mac requirement. Investigate iPlug2 or another permissively licensed lightweight wrapper. Do not put Godot itself on the plugin critical path.

## Embedded

Separate processor target from board profile.

Example:

```text
target: esp32-s3
board: waveshare-xyz
```

Target defines architecture/memory/runtime constraints.

Board profile defines codec, I2S, pins, screen, touch, encoders, ADC, MIDI, USB, SD, PSRAM, etc.

Board support should be mostly:

```text
manifest + thin HAL
```

not a fork.

## Embedded deployment

Prefer initially:

```text
generic SoundGraph firmware
          +
serialized/compiled graph
```

before generating a whole custom firmware build for every patch.

## Resource model

Every node should eventually expose:
- CPU cost
- internal RAM
- external/PSRAM use
- state bytes
- buffer needs
- target restrictions

The promise is not "every patch runs everywhere."

The promise is:

> The same graph language understands multiple targets and tells you what fits.

## Golden tests

Run common vectors against:
- native x64
- Apple Silicon
- WASM
- ESP32-S3
- ESP32-P4

Use tolerance-based comparisons rather than requiring bit-identical floating point.

## Guardrails

Do not:
- encode DSP behavior in Godot scenes
- make browser JavaScript the reference DSP implementation
- fork patches per target
- let board profiles alter graph semantics
- rebuild native code for every knob change
- add arbitrary scripting too early
- create hidden state that cannot round-trip through the patch format
