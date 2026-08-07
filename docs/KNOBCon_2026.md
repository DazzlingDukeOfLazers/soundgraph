# SoundGraph Knobcon 2026 Plan

**Start:** August 7, 2026  
**Target:** September 11, 2026  
**Development window:** about five weeks

## Objective

Do not finish SoundGraph.

Demonstrate one compelling end-to-end idea:

> Create/edit a sound patch in a modern visual editor, hear it immediately, save it as a portable graph, and run the same graph on one inexpensive ESP32-S3 development board.

## Definition of done by September 4

A stranger can:
1. open SoundGraph
2. load/create a simple patch
3. play it from MIDI or onscreen control
4. change parameters live
5. connect/disconnect a few nodes
6. save/load
7. select one supported ESP32-S3 board
8. deploy the patch
9. hear the physical board produce the corresponding sound

September 4 is feature freeze.

September 5-10 are hardening and show prep.

## Demo patch

```text
MIDI/Note
   |
   v
Saw Oscillator
   |
   v
Lowpass Filter <--- LFO
   |
   v
Gain <------------- ADSR
   |
   v
Stereo Output
```

## Ideal 90-second demo

1. Play the browser synth from MIDI.
2. Change cutoff.
3. Connect LFO to filter modulation.
4. Hear the change.
5. Save graph.
6. Say: "The web app isn't the synth. This graph is the synth."
7. Select ESP32-S3 target.
8. Deploy.
9. Physical development board makes the sound.

## Aug 7-13 — Make Sound

Build:
- patch schema
- DSP core
- validation
- scheduler
- golden tests
- offline rendering
- native playback

Exit:

```text
JSON -> DSP -> sound
```

## Aug 14-20 — Browser

Build:
- WASM
- AudioWorklet
- simple web host
- live parameters
- basic MIDI if practical
- plain web editor

Exit: a URL can load a patch, play sound, change cutoff, and save/load JSON.

## Aug 21-27 — Make It SoundGraph

Build:
- Godot graph editor
- readable nodes
- typed connections
- search/add node
- round-trip JSON
- one useful visualizer
- strong validation feedback
- enough visual polish for public demo

Exit: a patch edited in web opens in Godot and vice versa.

## Aug 28-Sep 3 — Hardware Escape

Pick **one** ESP32-S3 board.

Build:
- board profile
- codec/I2S HAL
- graph loader/runtime
- deployment
- physical audio

CLI deployment is acceptable before browser deployment.

Exit: the same first synth graph makes sound on real S3 hardware.

## Sep 4 — Feature freeze

No major architecture changes unless required to make the core demo work.

## Sep 5-10 — Harden

Test:
- clean browser
- Windows
- macOS
- refresh/reload
- board flashing
- power cycling
- MIDI reconnect
- malformed graphs
- offline/local demo path

Prepare:
- landing page
- README
- QR
- examples
- getting started
- architecture diagram
- board page
- short video
- backup firmware/cables/board if practical

## Stretch goals only

- P4
- packaged desktop app
- automation lane
- WebUSB/WebSerial deployment
- second board
- Axoloti
- AU
- VST3

Plugins are not on the Knobcon critical path.

## Hard non-goals before Knobcon

Do not build:
- custom PCB
- custom enclosure
- manufacturing workflow
- cloud accounts
- patch marketplace
- collaboration backend
- general Node-RED clone
- arbitrary code nodes
- complete Pure Data compatibility
- complete Axoloti compatibility
- many board targets
- mobile app

## Reliability rule

After freeze ask:

> Can this demo work thirty consecutive times in front of strangers?

A smaller reliable demo wins.
