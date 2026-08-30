# The Graph Node Pass

Making the graph read as one technical instrument rather than as miniature synth panels.
Built in steps, each rendered and reviewed before the next, the way the cable renderer and
the Add Node browser were. See `docs/cable-design.md` and `docs/add-node-browser.md`.

The rule the whole pass answers to:

> At reduced zoom, remove information before reducing its legibility. Never solve density
> by shrinking meaningful text into noise.

## Step 1 — the baseline

`editor-godot/graph_baseline.gd` takes it. Four zooms, one patch, every measurement
written to a file rather than read off a picture, because "the same patch opens the same
way afterwards" is a claim about numbers:

```
godot --path editor-godot --script graph_baseline.gd     # GRAPH_BASELINE_OUT names the folder
```

First Synth, 1440x900, XL interface, adaptive detail:

```
node   title              size in graph space   ports in/out
n0     Keyboard           479 x 257             1 / 4
n1     Main Oscillator    339 x 211             3 / 1
n2     Filter Sweep       430 x 119             1 / 1
n3     Lowpass            488 x 257             4 / 1
n4     Amp Envelope       388 x 119             1 / 1
n5     Amplifier          225 x 165             2 / 1
n6     Output             392 x 165             2 / 1
```

Seven nodes, seven wires. Widths run from 225 to 488 — every node is as wide as its
contents made it, which is what step 8's width classes are for.

### What each zoom actually shows

```
zoom   detail band   controls drawn   titles cut
100%   FULL          66               0 of 7
 66%   COMPACT       24               0 of 7
 40%   SUMMARY        0               3 of 7
 28%   SUMMARY        0               4 of 7
```

At 40% and 28%: `Main Oscilla…`, `Amp Envelop…`, `Amplifi…`, then `Main Osc…`,
`Filter Swe…`, `Amp Env…`, `Ampl…`. This is the failure the plan names, and it has a
mechanism rather than an accident behind it.

### Where the ellipsis comes from

The editor already has two answers to zoom, and they are not the same thing:

**The detail bands** — `PatchGraph.level_for()`, FULL / COMPACT / SUMMARY / TOPOLOGY at
0.60 and 0.40 with a hysteresis of 0.02. This is already step 12's idea: at 66% the node
sheds parameter rows (66 controls to 24), at 40% it sheds them all. It works.

**The compensated title** — under a screen minimum (`MIN_SCREEN_NODE_TITLE`, 16px before
the UI scale, so 22px at XL) the node's own title Label is hidden and `ScreenText` draws
the name at that pinned size instead, in `node.size.x * zoom - 12` pixels of room, elided
to fit. That is the right instinct — the name stays legible while the node shrinks — with
the wrong last step: when the pinned name does not fit the shrinking node, it is cut.

So the two systems disagree at the bottom. The bands remove information as they should;
the title refuses to, and pays for it in characters. Nothing here is a rendering bug, and
nothing is fixed by a smaller font: at 28% the Amplifier node is 63 screen pixels wide and
its name at the legibility floor wants 96.

That is the finding step 12 has to answer, and the shape of the answer is in the plan
already: **an intentional short name, not an ellipsis.**

### Two other things the baseline turned up

The lens switch floats over the canvas at the top right, so nodes scroll underneath it —
at 40% the Output node sits behind `Graph | Schematic`. It is a chrome question rather
than a node one, and it is recorded here because a screenshot of the graph at low zoom
will keep showing it.

`Design.MIN_SCREEN_*` rises with the interface scale, so an XL reader reaches every band
sooner and hits the elision earlier. Anything measured in this pass is measured at XL,
which is the tightest case.

### What may not change

Pinned in `editor_test.gd`: First Synth is those seven nodes with those port counts, and
the document holds seven wires. Surfaces, type, icons and what survives a zoom are all in
scope; what the patch *is* is not, and the way that goes wrong is a port quietly gained or
lost while somebody is looking at the colours.

## Step 3 — the canonical anatomy, on three nodes

Gain, StateVariableFilter and ADSR — the Amplifier, the Lowpass and the Amp Envelope of
First Synth. Nothing else takes the anatomy until these are approved, which is what a
proving ground is for. `NodeIdentity.PROVING_GROUND` is the list, and it is the only
place the scope is written down.

### The four parts

```
header    identity: the name, mixed case, left, in a region of its own
body      one surface step under the header, one over the canvas
ports     sockets on the perimeter, labels inside, unchanged this step
control   the body's padding, one gutter figure on each axis
```

Surfaces are the application's own and one step apart each: canvas `0f1318`, body
`1b212a`, header `252d38` on Lab — about five points of luminance between neighbours,
which is the plan's 5–8%. One hairline under the header, because without it the two greys
meet and read as a gradient rather than as two parts. One crisp perimeter. No paint, no
gradient, no shadow: the rack draws modules as hardware and is right to, and a diagram
made of photographs of panels is two languages in one window.

The header stopped being a strip behind a word. It has a height of its own
(`ANATOMY_HEADER`), so a long name and a short one get the same identity region, and the
name is **mixed case, left-aligned** — capitals and centring came from the panel pass,
where a centred legend in capitals is what a faceplate has. `AMPLIFIER` is a label on a
box; `Amplifier` is what the thing is called. Small capitals keep their job for the
metadata under the name.

### Canonical and compact names

`node_identity.gd`. Every node has the name its author gave it and, if its type has been
through the pass, a compact name written down beside it:

```
Gain                  Amp
StateVariableFilter   Filter
ADSR                  Envelope
```

Keyed by **type**, not by the name on the node: somebody who renames their oscillator
"Bass" still gets a compact identity, because what the node *is* has not changed, and an
author cannot be asked to invent a short form for every node they name.

The drawing rule, in `ScreenText._name_for`: the canonical name whenever it fits, at every
size. When it does not, the written-down compact name. Only when there is neither does
anything get cut — so a cut name is now the mark of a type that has not been through the
pass, rather than the normal way of drawing a small node.

Two departures from the table in the brief, both because the key is the type: the brief's
`Amplifier → Amp` is `Gain → Amp` here, and `Lowpass → Lowpass` never fires because
`Lowpass` fits at every zoom — its type's compact is `Filter`, for the day a filter is
named something longer. `Filter Sweep → Sweep` is not in this step at all: the LFO has not
been through the pass, and its compact word is a question for when it is.

### Measured, before and after

Same harness, same patch, same window, same XL scale. The before run has `main.gd`
stashed, so both columns are measured by the same code — the first attempt compared the
new renderer against an approximation of the old one and reported changes in nodes
nothing had touched.

```
topology      7 nodes, 7 wires, no moves, no port changes
sizes         Lowpass 488x257 -> 482x239, Envelope 388x119 -> 382x101,
              Amplifier 225x165 -> 219x147     (the control region's own padding)
100%, 66%     no title changes
40%           'Amp Envelo…' -> 'Envelope'      'Ampli…' -> 'Amp'
28%           'Amp En…'     -> 'Envelope'      'Am…'    -> 'Amp'
```

Titles at 28%: three canonical, two compact, two cut. The two still cut are Main
Oscillator and Filter Sweep, which have not been through the pass — visible, in the same
patch, beside two that have.

### Not in this step

The adaptive bands are untouched: the same 0.60 and 0.40, the same hysteresis, the same
counts at every zoom. Cables, serialisation, node ids, control values and the other four
node types are as they were. Width classes are step 8, so nothing was widened to make a
name fit — the compact name is the answer at this size, by design.
