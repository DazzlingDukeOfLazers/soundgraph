# Node States

What a graph node looks like when something is true about it, and how two things being
true at once stays readable.

The rules are in `editor-godot/node_state.gd`. `editor-godot/state_sheet.gd` takes the
proof, from the running editor on First Synth rather than from a specimen built for the
purpose. Gain, StateVariableFilter and ADSR only; everything else in the library still
wears what it wore.

## Five channels, five questions

The way state design fails is always the same: two facts reach for one channel, the
louder wins, and the quieter stops existing. So each fact owns one.

```
perimeter colour and weight    selection
header surface and mark        validity
body and perimeter value       hover
port glow                      activity, and it was already there
the identity glyph             activity, only where activity has stages
```

A selected node has a mint edge whether or not it is also broken. A broken node has a
warm header whether or not it is also selected. Both facts are on the node at once and
neither is hiding the other.

### The one shared channel, and why

The perimeter. Selection outranks hover there, and that is forced rather than chosen:
GraphNode draws a selected node from its `_selected` styleboxes and never consults the
ordinary ones, so a hover border on a selected node would not draw at all. The surface
lift still happens, so a selected node under the pointer is not the same picture as a
selected node beside it — see the measurements below.

### What is deliberately absent

**A node-level connected state.** Step 7 gave connection to the individual port. A node
with one cable in and five empty sockets is not "connected", it is a node with one cable
in, and rolling six facts into one adjective loses all six.

**Node-wide activity.** The editor already lights output ports by measured level, which
is local and specific. A node-level treatment on top would say "something is happening in
here", which the ports have said better. The rule the proof settled on:

> Visualise runtime activity at the node level only when the activity has semantic
> structure beyond "signal exists".

An envelope has four named stages and passes. An amplifier has signal going through it
and does not — a triangle flickering because sound exists is an animation with no content.
Gain and StateVariableFilter get no header activity treatment, and the proof sheet's
`active` row shows exactly that: the output socket lights and the node does not.

## Measured

Header and body samples off the proof sheet, Lab palette, XL interface. Ratios are
contrast against the state being compared to.

```
state              header          body            vs
normal             37, 45, 56      27, 33, 42      —
hovered            45, 54, 67      33, 40, 50      1.14 header, 1.09 body
selected           51, 60, 74      37, 45, 56      mint perimeter at 2px
selected+hovered   51, 60, 74      45, 54, 67      1.00 header, 1.14 body
warning            70, 70, 62      27, 33, 42      1.46 against a well header
selected+warning   82, 82, 77      37, 45, 56      title still 7.31:1
```

**Hover was too small and the sheet said so.** A third of a surface step put the hovered
header at 1.08 times the plain one, which is under what a large flat field is noticed at,
and two specimens nobody could tell apart. Six tenths gives 1.14 — still the smallest
change in the vocabulary, and now a change.

**Selected and hovered differ in the body, not the header.** A selected header is already
on `ACTIVE`, the top of the surface ladder, and there is nothing above it to lift into.
The body has room and takes it, so the combination reads. Worth writing down because it
looks like a bug in the table above and is not.

**The warning tint is bounded by a rule, not by taste.** The first attempt tinted the
header 30% toward amber. It made a handsome olive slab and put the node's title at 5.3:1
— under the design system's own 7:1 floor, on the one node a reader most needs to read.
The binding case is a selected broken node, whose header has already been lifted a step
before it is tinted: 16% lands at 7.31:1 and 18% at 6.95:1. So the figure is 16%, and it
is the largest one the title survives.

`design_test.gd` now checks every combination — five palettes, selected or not, hovered or
not, well, warned or failing — so it cannot drift back.

## The eight specimens

`state-eight.png`, reading in pairs: normal / hovered, selected / selected+hovered,
active / selected+active, warning / selected+warning.

The combinations are the ones that matter. Isolated states always look fine.

- **selected + warning** is the important one and it works: mint perimeter, warm header,
  a bang at the far end of the header. Two facts, two places, neither obscuring the other.
- **selected + active** keeps the lit socket, which is on the perimeter and not in the
  fill, so the mint edge does not swallow it.
- **hovered** is the quietest thing in the vocabulary on purpose. It answers "the pointer
  is on this one" and stops.

## Reduction

`state-bands.png`: selected, active and warning down the columns, 100 / 66 / 40% down the
rows.

All three survive 40%. Selection survives because mint against a dark canvas is a colour
difference and colour does not shrink. Warning survives because the header is a region
rather than a mark — this is the whole reason the tint carries the fact and the bang only
sharpens it. Activity survives because a lit socket is a lit socket at any size.

What does not survive, and should not: the bang is a dot at 40%, and the identity glyph
has already stood down with the title at 66%. Nothing was added to keep them — a tiny
noisy mark preserved past its size is how a diagram becomes a dashboard.

## The ADSR stage prototype

`state-stages.png`, four captures: attack, decay, sustain, release. The whole contour
stays in the ordinary ink and the live segment is picked out in the accent.

**The identity survives** — that was the hard requirement and it passes. The mark is still
the envelope; one of its four segments is simply lit.

**Segment identification at actual size is partial.** At the 24-pixel header cell the live
segment is four to six pixels of mint. Left against right — attack against release — reads.
Decay against sustain, two adjacent segments in the middle, does not reliably. So the
honest description of what this communicates is "an envelope is running, and roughly
where in its cycle", not "the decay stage is active".

**It is built but not enabled.** `Icons.envelope_stage` draws it and `_dress_anatomy`
honours an `active_stage` on the widget, and nothing in the editor ever sets one: the
stage would have to come from dsp-core, which does not expose it. So this is a proven
mechanism waiting for a data source rather than a feature. The proof sheet drives it
directly.

That is the right place to leave it. The technique is sound, the legibility is measured
rather than assumed, and turning it on is a question about the engine and not about the
drawing.

## Mixed

`state-mixed-close.png` — one frame, three nodes, and the five questions:

1. **Which is selected?** The Amplifier, by a continuous mint perimeter. It does not
   compete with the mint inside the nodes because a boundary is continuous and knob arcs
   and lit sockets are not.
2. **Which is merely hovered?** Neither. On the eight-state sheet, the one that is a shade
   lighter.
3. **Is anything invalid?** The Lowpass, warm header and a bang.
4. **Is anything active?** The Lowpass's output socket is lit; the rest are not.
5. **Which ports are connected?** The sockets with cables in them, against the hollow
   diamonds at `cutoff Hz`, `mod` and `resonance`.

The Lowpass is invalid *and* passing signal at once, which is the pair most likely to
collide, and they sit in different places on the node.

`state-mixed.png` is the same scene fitted to the whole patch, near a third of a zoom.
Selection and warning are still the two things that stand out, which is the answer to a
different question and worth having.

## One thing this step fixed on the way past

The diagnostics list used to wash offending nodes in red with `modulate`, which tinted
their controls, their sockets and the cable ends sitting on them — the signal vocabulary
recoloured to report an unrelated fact. It was also what the execution-order chips used to
point at a node with, so one treatment served two unrelated meanings and red came to mean
"something over there mentioned this".

They are two things now. Pointing borrows the pointer's own channel, and validity is a
property of the node that lives on the node's header.
