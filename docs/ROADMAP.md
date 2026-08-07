# SoundGraph Roadmap

## Milestone A — Graph Makes Sound

```text
patch JSON
 -> validation
 -> DSP graph
 -> scheduler
 -> offline render
 -> native live audio
```

Exit: a saved SoundGraph patch produces deterministic audio without a UI dependency.

## Milestone B — Browser Runtime

```text
same DSP core
 -> WASM
 -> AudioWorklet
 -> live browser audio
```

Exit: native and browser behavior match within declared tolerances.

## Milestone C — Two Editors

Deliver:
- simple web reference editor
- Godot primary editor

Both open/save the same graph and preserve semantics.

## Milestone D — Automation

Deliver parameter automation, interpolation, playback, looping, and manual override.

Automation must be project/graph data, not hidden frontend state.

## Milestone E — Desktop App

macOS and Windows:
- audio device
- MIDI device
- editor
- save/load
- diagnostics

## Milestone F — First Embedded Target

Target one ESP32-S3 board.

Deliver:
- backend
- board profile
- codec/I2S HAL
- patch loader
- runtime
- deployment
- tests

Exit: the same graph runs in browser/native and on one physical S3 board.

## Milestone G — Board Abstraction

Add a second meaningfully different board.

Exit: mostly profile/HAL work, not a platform fork.

## Milestone H — ESP32-P4

Use the same graph model on a larger target.

Exit: a graph too large for S3 can run logically unchanged on P4.

## Milestone I — DAW Plugins

Targets:
- macOS AU
- macOS VST3
- Windows VST3

Exit: same graph works in standalone/browser and a major DAW.

## Milestone J — Board Packs

Each board gets:

```text
boards/<vendor>/<board>/
    board.json
    README.md
    test-results.json
    examples/
    media/
```

## Milestone K — Legacy/External Ecosystem Experiments

Only after the core is stable:
- Axoloti/Ksoloti target
- Pure Data import/export subset
- other graph interchange

Do not promise full compatibility before semantic evaluation.

## Later

Possible later areas:
- sampling
- wavetable
- physical modeling
- convolution
- reusable subgraphs
- package/node ecosystem
- user DSP extensions
- patch libraries
- collaboration
- tablet editing
- educational courses
- full DAW-hosted editor
- hardware control-surface designer
