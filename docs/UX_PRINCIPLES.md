# SoundGraph UX Principles

SoundGraph should preserve what visual audio patching does well while deliberately applying modern interaction design.

## Progressive complexity

A node initially shows the common case.

```text
+------------------+
| Saw Oscillator   |
| Frequency   440  |
|                o |---->
+------------------+
```

Advanced mode may reveal phase, sync, FM, PWM, reset, etc.

## Readable by default

Avoid tiny text, tiny hit targets, cryptic abbreviations, and maximum-density layouts as the default.

Expert-density modes can come later.

## Connections have meaning

Use typed connections and visual distinctions that do not rely on color alone.

Example:

```text
audio     strong solid
control   lighter/thinner
event     dashed
note      event/message style
```

When dragging a connection:
- compatible ports become obvious
- incompatible ports reject clearly
- useful converters may be suggested

## Search by intent

Search should accept both technical and human language:

```text
lowpass
low pass
remove high frequencies
make quieter
midi keyboard
smooth control
echo
```

Show canonical technical names without requiring users to know them first.

## Make signals inspectable

Useful interactions:
- click wire -> waveform
- click node -> level meter
- inspect filter -> frequency response
- inspect ADSR -> envelope
- inspect oscillator -> waveform
- inspect control -> value/time plot

## Errors should be spatial and actionable

Bad:

```text
DSP ERROR: CYCLE DETECTED
```

Better: highlight the loop and explain what is missing.

For target failures, explain actual resources and possible fixes.

## Beginner help must not punish experts

Help should be contextual, optional, and collapsible.

## The graph should teach

A learner should be able to inspect each stage of a synth/effect and hear/see what changes.

## Great defaults matter

Dropping a node should usually produce useful behavior immediately.

## Patching should feel immediate

```text
connect
hear
turn knob
hear
disconnect
hear
```

Ordinary edits should not require compilation.

## Navigation must be excellent

Eventually:
- smooth pan/zoom
- zoom to selection
- frame selection
- search
- undo/redo
- groups/subgraphs
- minimap if useful
- strong keyboard navigation

## Target compatibility should be visible

Example:

```text
Web          Ready
macOS        Ready
Windows      Ready
ESP32-S3     72% CPU / 48% RAM
ESP32-P4     Ready
```

## Separate graph from performance surface

The same cutoff parameter may be controlled by:
- graph knob
- MIDI controller
- DAW automation
- touchscreen
- physical encoder

## Modern does not mean decorative

Prioritize legibility, predictability, low interaction cost, debugging, and visual organization before decorative animation.

## UX test

For every feature ask:

> Can someone who understands the concept discover how to use it without already knowing SoundGraph?

And:

> Can an expert repeat the operation quickly without the interface getting in the way?
