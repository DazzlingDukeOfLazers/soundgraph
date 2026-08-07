# SoundGraph
## Project Plan

**SoundGraph** is an open visual audio-programming platform from Mutant Factory.

The central artifact is a portable **sound graph**, not a particular UI, plugin format, operating system, or piece of hardware.

A SoundGraph patch should ultimately run in:
- browser / WebAssembly
- desktop app
- DAWs through AU/VST3
- ESP32-S3
- ESP32-P4
- selected third-party development boards
- later, possibly Axoloti/Ksoloti-compatible hardware

The project is optimized for **software leverage rather than a physical-product business**. Small hardware runs may happen later, but inventory and manufacturing should not become prerequisites for the platform to succeed.

## Core idea

```text
                   SoundGraph Patch
                        JSON
                         |
              +----------+----------+
              |                     |
              v                     v
       Graph Validation        Target Profile
              |
              v
       Canonical DSP Graph
              |
     +--------+--------+---------+---------+
     |                 |         |         |
     v                 v         v         v
 Browser/WASM      Desktop     DAW      Embedded
 AudioWorklet       App       AU/VST3   ESP32
```

## Product principles

1. **The graph is the product.** Godot scenes, browser state, plugin presets, and ESP-IDF projects are not canonical.
2. **One DSP implementation, many hosts.** Prefer a portable C++ DSP core with thin wrappers.
3. **Modern visual-programming UX.** Improve readability, discoverability, debugging, onboarding, search, signal inspection, and target/resource feedback.
4. **Progressive complexity.** Simple nodes should look simple; advanced ports and parameters can be expanded.
5. **Inspectability.** Click wires/nodes to inspect waveforms, envelopes, levels, filter responses, and resource use.
6. **Browser as zero-install doorway.**
7. **Godot as a first-class editor, not DSP authority.**
8. **Maintain a second conventional web editor** for differential testing and a lightweight reference frontend.
9. **Hardware is a target, not the business model.**
10. **Board support should create publishable work:** profile, tests, docs, examples, and videos.

## Initial node vocabulary

```text
AudioInput
StereoOutput
SineOscillator
SawOscillator
SquareOscillator
Noise
Gain
Mixer
ADSR
LFO
StateVariableFilter
Delay
Constant
Add
Multiply
MIDI/NoteInput
```

Initial signal types:

```text
audio
control
event
note/MIDI
```

Do not build a general-purpose visual programming language yet.

## Runtime model

```text
Patch JSON
 -> validate
 -> instantiate precompiled DSP nodes
 -> resolve connections
 -> topological schedule
 -> allocate state/buffers
 -> run
```

Do not compile C++ every time the user edits a connection. Generated embedded code can be added later if it proves necessary.

## First vertical slice

```text
MIDI/Note
   |
   v
Saw Oscillator
   |
   v
SVF Lowpass <--- LFO
   |
   v
Gain <---------- ADSR
   |
   v
Stereo Output
```

Expose cutoff, resonance, ADSR, LFO rate/amount, and master gain.

This patch should eventually run through the same graph model in:
1. native test runtime
2. browser/WASM
3. simple web editor
4. Godot editor
5. one ESP32-S3 target

## Second vertical slice

```text
Audio Input -> Filter -> Delay -> Stereo Output
                         ^
                         |
                      Feedback
```

This validates effects, live input, delay memory, feedback, and automation.

## Success definition

A user can:
1. open a URL
2. create or load a graph
3. hear it immediately
4. understand what the graph is doing
5. save/share it
6. run it in desktop/DAW targets later
7. select a supported ESP32 board
8. deploy a compatible graph
9. understand why a graph does or does not fit a target

Long-term leverage:

```text
one graph model
x many execution environments
x many cheap hardware targets
x many examples/tutorials
```
