# Cosmopolitan Cables

The record of the cable pass, in the same discipline as the node pass: baseline first, then
one problem at a time, each goal changing a single variable and judged against a rendered
comparison before the next begins.

## What is in scope, and what is already finished

`docs/cable-design.md` is a **finished, frozen subsystem** and is not in scope. Ten goals
settled the material of one cable — mass, shell, glint, shadow, plug, cut-end mouth, colour
collar, deterministic hang, departure splay, crossing occlusion and surface response — each
against a rendered comparison, each freezing what came before it. Those figures stand.

This pass is a different layer: **routing and legibility in a dense field.** How a cable
behaves as one of thirty-five rather than as one cable.

The rule that carries over from the node pass, unaltered:

> **Colour, topology, focus, signal type, connection state and activity are separate
> channels. No treatment may make one of them carry another.**

That is the rule the node pass spent eleven steps learning, and a cable pass that ignores it
will rediscover every problem the node pass already solved.

## The seven problems

1. **Crossing ambiguity.** At dense intersections, especially same-colour ones, it takes
   effort to work out which strand continues through which path.
2. **Long-route ownership.** A cable crossing half the graph becomes visually detached from
   both its ends.
3. **Colour-only type information along the span.** The endpoints carry socket shape; the
   middle of a cable carries hue and nothing else.
4. **Cable hierarchy.** Every ordinary cable demands about the same attention, whether it is
   the main audio path, a secondary modulation, or one of twenty event connections.
5. **Dense bundles.** Parallel and near-parallel runs accumulate into visual mass rather
   than behaving like organised routes.
6. **Occlusion at nodes.** Socket termination is settled; a cable passing behind or beside
   an unrelated node still complicates local reading.
7. **MAP behaviour.** At 28–40% the cables are a larger share of what is left, so their
   grammar matters more exactly where the node grammar has stood down.

## Step 1 — the baseline

`cable_baseline.gd`, against `editor-godot/qa/dense-graph.json` — the hostile specimen built
for the node pass's 15B. Deliberately not a new, friendlier cable card: it already has the
long crossings, the fan-outs, the multi-input mixing and the density.

```bash
CABLE_BASELINE_OUT=/tmp/p godot --headless --path editor-godot --script cable_baseline.gd
```

It measures rather than describes, because six of the seven problems are about density and
density is what an impression is worst at.

```
cables            35
  median length   357 units
  longest         2955 units          8.3x the median
crossings         32
  same colour     15                  47%
  under 25 deg     0
  both             0
bundled pairs      2                  within 10 units, under 15 deg, for over 20 units
node crossings     3                  a cable over a node it has no business with

patch extent      4016 x 2580 units, 29277 units of cable in it

zoom     band        cord px    cable share
100      FULL           8.00           2.3%
 66      REDUCED        5.28           2.3%
 40      MAP            3.20           2.3%
 28      MAP            2.40           2.4%
```

Archived at `docs/proofs/cable-baseline.json`, with every crossing's position, angle and
colour pair, every cable's detour ratio, and every trespass.

### What the baseline already changed about the plan

Three of the seven problems came back much smaller than they look, and one came back
differently shaped. That is the whole reason to measure before designing.

**Shallow crossings do not exist here — zero of thirty-two.** The expectation going in was
that grazing intersections would be the hard ones, and the catenary routing has already
solved that: Goal 6's per-cable hang and Goal 7's alternating departure splay push
neighbours apart, so every crossing in the specimen is transverse. **Problem 1 is therefore
not about angle. It is about the fifteen same-colour crossings**, which meet at perfectly
readable angles and are still ambiguous because both strands are the same mint.

That is a much narrower target than "crossing treatment", and it points somewhere specific:
whatever is done at a junction has to distinguish two cables that are *identical in every
channel except which one is on top*.

**Bundles are two pairs, not a problem.** Goal 7's splay is doing its job. Problem 5 may be
a problem in patches with wider fan-outs than this one, and the honest position is that the
specimen does not demonstrate it. Do not design for it on this evidence.

**Trespass is three.** Problem 6 is real and rare. Three cables pass through a node's
territory that has nothing to do with them.

**Cable share is flat at 2.3%, and that is the finding.** The cord width scales linearly
until `maxf(8 * zoom, 2.4)` puts a floor under it below a zoom of 0.3, so cables hold
exactly their share of the picture at every distance and gain 0.1 point at 28%. So **problem
7 is not cables getting heavier. It is everything else getting lighter** — at MAP the nodes
shed their controls, their values and eventually their port names, and the cables are left
carrying a larger share of the *remaining information* while carrying an unchanged share of
the *ink*. Reducing cable weight at MAP would be solving the wrong half.

**Problem 2 stands, and has a figure.** The longest cable is 2955 units against a median of
357 — eight times — in a patch 4016 units wide. One cable crosses three quarters of the
graph.

## The first question

> **How does a single route stay identifiable through a dense field without making every
> route louder?**

Three techniques, tested separately and in this order:

1. **Crossing treatment** — a bridge, gap or halo at intersections so continuity is
   obvious. Aimed at the fifteen same-colour crossings, which is now known to be the whole
   of problem 1. Goal 8 already established that occlusion plus a local halo works; the
   question is whether it is enough when both cables are the same colour.
2. **Focus treatment** — hovering or selecting a cable or a socket **suppresses unrelated
   cables** rather than brightening the chosen one. Suppression rather than emphasis,
   because emphasis is another way of making the graph louder and the whole point is that
   it should get quieter.
3. **Sparse type marking** — very infrequent inline semantic marks or texture, as the
   grayscale fallback for problem 3. **Only after crossings work**, and deliberately last.

## Goal 1 — crossing separation

**Not "improve crossings".** The measured defect is narrow, and the goal is stated as the
narrow thing:

> At a transverse crossing between visually identical cables, a reader can immediately tell
> which strand continues through the intersection.

Nothing else moved: not width, routing, splay, bundling, MAP scaling or node trespass. The
route geometry and the connection coordinates are untouched; the treatment is a drawing.

Named **crossing separation**, not "bridge". A bridge is one candidate's geometry and the
name would have smuggled it in.

### The exclusion the incumbent had lost

Before any candidate was drawn, the sheet found something the baseline had not: the cord
layer was treating **fan-out convergences as crossings.** Cables leaving one output or
arriving at one input meet by design, and a separation mark there says the opposite of what
is true — the clock's three-way fan-out was being marked as three crossings. GraphEdit's own
thin-line crossing pass had that exclusion; the cord layer that replaced it never did.

Restoring it took the specimen from 31 crossings to 27, and the same-colour set from 16 to
12. Four of the sixteen "hard cases" were cables that genuinely join.

### The four columns

| | what it does | pixels | ink added | ink removed |
|---|---|---|---|---|
| none | nothing — the reference | 0 | 0 | 0 |
| halo | darker halo under the upper cable (the incumbent, goal 8) | 659 | 0 | 117 |
| **knockout** | **lower cable erased for a short span, upper drawn over the gap** | **1359** | **22** | **229** |
| bump | upper cable lifted into a local arc | 10477 | 1391 | 1086 |
| knockout, every crossing | the unconditional rule | 4468 | 64 | 759 |

Measured at the crossings rather than across the frame. The frame-wide diff was tried first
and was not reproducible — three runs gave 908, 940 and 890 touched pixels for one treatment,
because something else in the editor moves between captures. The crops are taken back to back
at one scroll position with nothing changed but the construction, and they repeat to within a
pixel.

### What the sheet showed

**Knockout wins, as expected, and the reference column is what makes the case.** With
nothing at all, two identical blue strands fuse into a lozenge at the crossing and there is
no way to tell which continues. **The halo barely changes that** — darkening the upper
cable's underside says nothing when the cable underneath is the same colour, which is
precisely the case it was never tested on. The knockout reads immediately as one line
passing over another, and it does it with twenty-two units of added ink across twelve
crossings.

**The bump loses on both counts.** It adds sixty-three times the ink, and it says something
untrue: the cable visibly detours around another cable, and the route is a fact about the
patch. It also reads as printed-circuit crossover notation, which is a different language
from a patch cord.

At 40% and 28% the treatment is invisible, which is the intended behaviour — almost nothing
until you need to trace a route.

### The constraints, and how they are met

| Constraint | How |
|---|---|
| never resembles an electrical junction | nothing is drawn *at* the crossing; a gap is cut. No dot, no ring, no taper — anything that closes across the gap becomes a junction mark |
| implies no direction | the gap is symmetric about the intersection and follows the lower cable's own path |
| encodes no type, activity, selection or focus | it is one shape in the ground colour, and it appears at every qualifying crossing regardless of what the cables carry |
| route geometry unchanged | the knockout is a drawing pass; `_get_connection_line` is untouched. Only the bump displaces anything, and even it draws from a copy |
| local to the crossing | the gap is the upper cable's width plus clearance either side, `span_at` walks the path to that length, and `editor_test` holds it at exactly that |
| deterministic priority | connection order, which is the file's order — the same rule the layer already used, and nothing semantic invented about which cable deserves to be on top |

### Goal 1.1 — unconditional, and the grammar closes

Both rules were rendered and the conditional one lost on **meaning**, not on ink.

What a knockout says is *these two paths cross here; they do not join*. That is true of a
blue over a blue and equally true of a blue over a green. Applying it only where the hues
coincide makes its presence a fact about the palette rather than about the graph — an
unexplained channel that looks like it means something and whose real rule no reader can
recover. The cost of dropping the condition was forty-two ink units across fifteen more
crossings, and neither the 100% nor the 40% frame shows an artefact from it.

The rule, final:

```
true transverse crossing          knockout
shared endpoint, fan-out          never
an actual junction                never
colour                            irrelevant
z-order                           connection order; deterministic, and means nothing
```

Which leaves the crossing grammar as small as it can be:

> **A gap means a crossing. A continuous meeting means a connection.**

**Goal 1 is frozen.**

## Goal 2 — route focus by suppression

Aimed at the long-route problem the baseline measured. The mechanism is a prohibition:

> **The focused cable is drawn at its ordinary resting appearance.** No extra width, no
> saturation, no glow, no brightening. Focus works because the noise leaves.

Two questions, kept separate. **Cable hover** focuses one connection. **Port hover** focuses
everything plugged into that one port, because an output with three cables on it really is
one source feeding three destinations and should read as a family. Neither propagates
through a node: a cable graph is not a semantic signal chain, and lighting the whole
downstream network is a different feature with a different meaning.

Crossings are untouched. A dimmed cable still crosses rather than joins, and which cable is
over does not depend on what the pointer is doing — that would make focus mutate geometry.
Nodes are untouched entirely, so that this step answers about cables alone.

### The mechanism had to change, and that is the finding

Alpha was the obvious implementation and it does not work. A cord is **six stacked passes**
— two shadows, two shell strokes, a body and a highlight — and scaling each one's alpha
independently leaves the composite far more opaque than the number says:

```
                alpha-scaled          mixed toward the ground
nominal      background   ratio       background   ratio
  0.65          0.905      1.11          0.814      1.23
  0.45          0.820      1.23          0.710      1.41
  0.25          0.697      1.44          0.608      1.64
```

At a nominal 45% the alpha version bought a 1.23 luminance ratio, and the three specimens
were nearly the same picture — the number meant nothing. Mixing each coloured pass toward
the canvas instead gives a reduction that lands where it is asked to. Hue direction, width
and path are untouched; what changes is contrast against the ground.

### The level

**0.25 ships, and it was not the expected winner.** The prior was 40–50%, and that was a
good prior for a mechanism that delivers its nominal figure. This one delivers less, so the
same effect needs a lower number.

The figure to carry forward is **the achieved ratio, 1.64**, not the nominal 0.25. If the
mechanism changes again, re-derive the nominal from the ratio.

At 0.25 on the hostile graph at 40%, the focused route threads unmistakably from the
keyboard down to Speak, and every suppressed cable is still visible with the topology of the
rest of the patch intact. Nothing has vanished, which is the stated win condition — the
quietest background that still leaves the network there. At 0.45 the focused route is hard
to pick out of the field.

### What was measured, not eyeballed

```
focused keeps      1.002 / 1.000 / 0.998    the prohibition, at all three levels
routes             point-identical in graph space, focused and not
crossings          same count, same positions, focused and not
cable hover        exactly one connection unsuppressed
port hover         exactly the cables on that port
nodes              2 sampled pixels, on one short cable near a node edge
```

### Three instruments were wrong before one was right

Worth recording, because every one of them failed the same way — **a reference frame is only
a reference for as long as nothing has moved, and in a live program that is about four
frames.**

1. The luminance ratio compared the focused cables against the background cables. They are
   different cables carrying different signals and mint is brighter than periwinkle: at 65%
   suppression it reported the background as *brighter* than the focus.
2. The node check diffed against a resting frame from the top of the run and reported a
   floor of 33 changed pixels rising to 180 by the end **in the baseline scene**, where
   nothing is focused. Not jitter — drift, something in the editor settling over minutes.
3. With the reference fixed, the focused set still read 0.505. The port-hover cables sit
   off-screen at 100% in a patch four thousand units wide, and their empty readings were
   being averaged in as "this cable is black".

All three are now measured from one before/after pair captured back to back, with the view
centred on the cables being asked about.

## Goal 3 — grayscale cable type — **not finished, and not shipped**

The requirement, narrow:

> Given a mid-span crop with the endpoints unavailable and the hue removed, identify the
> cable's signal class — without mistaking the cue for a junction, a crossing, a direction
> arrow or activity.

### What is built and gated

All three candidates, none of them shipped. `CableArt.type_cue` is `NONE`, so nothing about
the resting cable has changed for anybody.

```
NONE       the reference
HIGHLIGHT  the existing bright pass, interrupted into sparse strokes
RIBS       short transverse marks laid across the cord
STAMPS     the socket shapes, repeated beside the route
```

**No candidate breaks the cable body.** A dashed wire is a different object; all three leave
the cord solid and spend only the highlight pass or a mark laid on top of it.

The placement rule is `CableArt.cue_sites()` — one pure function, shared by the renderer and
the sheet for the same reason `fit_for` and `cell_reaches` are:

```
cadence      160 screen pixels, measured on the glass and not in graph units
audio        unmarked; the additional ink belongs to the classes that are not the default
control      a single stroke per cadence
event        a paired stroke per cadence
exclusions   sockets, both cable ends, every crossing on this cord, and any bend over 35°
precedence   connection and crossing geometry > type cue > focus prominence
```

Measured on the hostile graph: **76 cues placed, 4 refused by the exclusions, an achieved
cadence of 165 screen pixels** against a 160 target. Routes point-identical, crossing count
and positions identical, the focused cable byte-equivalent with its cue included.

### Why it is not finished

**The specimen has no event-class cable.** Thirty-five cables: eighteen audio, seventeen
control, **zero event**. So a third of the vocabulary — the paired cadence, the one that has
to be told apart from the single one — is drawn and gated but never exercised by the graph
it is supposed to be judged in. Choosing a candidate on a two-class proof would be choosing
it on the easy half of the question.

This is worth a look on its own account. The registry's port types in this patch resolve to
audio and control only, while the socket grammar has four shapes and the palette has a
trigger colour. Either the hostile patch happens to contain no event-typed output, or the
port types and the socket shapes disagree about what a gate is — and the second would be a
defect in the node data, not in the cables.

**And the endpoint-free crop is not achievable below 100%.** At 40% and 28% a 340-pixel crop
of a patch four thousand units wide contains nodes whatever it is centred on, so the sheet
comes back with labels in it and the endpoints are not hidden at all. The mid-span test is a
100% test; the lower zooms want the whole-graph frames instead, and the sheet should say so
rather than producing six crops of which four answer a different question.

The crop selection also needs to choose spans that are genuinely clear of nodes rather than
the middle of the longest cable, which in this patch lands under one.

### What would finish it

1. A specimen carrying all three classes — either the hostile patch gains an event cable, or
   the event class is proved on a second patch that has one, named in the sheet.
2. Mid-span crops at 100% only, chosen from spans measurably clear of any node.
3. The three candidates side by side on one control cable and one event cable, shuffled, and
   named without the ends.

Until then the default stays `NONE`. A cue chosen on an unfinished sheet is the "45% felt
good" failure this programme keeps avoiding, and goal 2 has just finished demonstrating how
easily an instrument can be confidently wrong.

### What not to start with

Dashed control cables, or any repeating pattern. With thirty-five intersecting cables, a
reasonable pattern becomes plaid, and the pattern then competes with the crossing treatment
that problem 1 actually needs. The grayscale gap is real and it is filed in
`docs/known-issues.md`; it is third in the queue and not first.
