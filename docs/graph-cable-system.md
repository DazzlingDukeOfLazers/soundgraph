# The graph cable system

The specification for what a cable in the patch graph is. Frozen at the end of the
Cosmopolitan Cables pass.

There are two documents about cables and they answer different questions.
`docs/cable-design.md` is the **material** — what one cable is made of, settled over ten
goals: mass, shell, glint, shadow, plug, cut-end mouth, colour collar, deterministic hang,
departure splay and surface response. This is the **language** — how a cable behaves as one
of thirty-five. `docs/cables.md` is the running record of how each rule was arrived at,
including the wrong turns, which are the useful part.

---

## 0. The freeze

**Cosmopolitan Cables 1.0. This document is authoritative and the design is closed.**

```
278 closure invariants over two specimens, four zooms, two palettes    no complaints
 14 gesture checks through real input routing                          all passed
 14 of 14 endpoint-free grayscale crops named blind
```

The bar for reopening is the node pass's bar: **several independent contexts demonstrating
that a rule is inadequate, measured rather than observed.** A screenshot that could be made
prettier is not evidence.

---

## 1. The resting vocabulary

Five statements. That is the whole language.

```
continuous unmarked span      audio
sparse transverse rib         control
a gap                         two paths cross and do not join
a continuous meeting          a connection
suppression                   focus prominence, and nothing else
```

And the channel rule, carried over from the node pass unaltered:

> **Colour, topology, focus, signal type, connection state and activity are separate
> channels. No treatment may make one of them carry another.**

## 2. Crossing separation

> **A gap means a crossing. A continuous meeting means a connection.**

At every true crossing the lower cable is erased for a short span in the ground colour and
the upper is drawn over the gap, unchanged. Nothing is added *at* the junction — no dot, no
ring, no taper. Anything that closes across the gap becomes a junction mark, and a junction
mark on a patch cable claims that two signals meet.

```
true transverse crossing      knockout
shared endpoint, fan-out      never
colour                        irrelevant
z-order                       connection order; deterministic, and means nothing
gap length                    the upper cable's width plus KNOCKOUT_CLEARANCE either side
```

**Colour is irrelevant, and that was a decision.** The conditional rule — treat only
same-coloured crossings — cost less ink and lost on meaning: a treatment that appears at
some crossings and not others is a channel that looks like it means something, and no reader
can recover "these two happened to be the same colour" as the reason.

**A fan-out is never separated.** Cables leaving one output meet by design. GraphEdit's own
thin-line crossing pass had that exclusion and the cord layer that replaced it had lost it,
so a three-way fan-out was being marked as three crossings.

Candidates weighed and rejected, with the ink each spends across twelve crossings:

| | ink added | why not |
|---|---|---|
| nothing | 0 | two identical strands fuse into a lozenge |
| halo under the upper cable | 0 | darkening the upper cable's underside says nothing when the cable underneath is the same colour — the case it was never tested on |
| **knockout** | **22** | ships |
| local bump | 1391 | sixty-three times the ink, and it says something untrue: the route is a fact about the patch |

## 3. Focus by suppression

> **The focused cable is drawn at its ordinary resting appearance. Focus works because the
> noise leaves.**

No extra width, saturation, glow or brightness on the chosen route. Unrelated cables are
mixed toward the canvas at `CableArt.suppression`.

```
hover a cable      transiently focus that connection
hover a port       transiently focus every cable on that port
```

Neither propagates through a node. A cable graph is not a semantic signal chain — the nodes
between transform things — and lighting the whole downstream network is a different feature
with a different meaning.

### Alpha does not work, and the number is not the figure

A cord is **six stacked passes**. Scaling each one's alpha independently leaves the
composite far more opaque than the number claims:

```
                alpha-scaled          mixed toward the ground
nominal      background   ratio       background   ratio
  0.65          0.905      1.11          0.814      1.23
  0.45          0.820      1.23          0.710      1.41
  0.25          0.697      1.44          0.608      1.64
```

So the mechanism mixes each coloured pass toward the ground, and the shipped nominal is
**0.25** — lower than the 40–50% expectation, because that expectation was right for a
mechanism that delivers its nominal figure and this one delivers less.

> **The design target is the achieved ratio, 1.64, not the nominal 0.25.** If the mechanism
> changes, re-derive the nominal from the ratio.

And the ratio is a measurement of a *scene*, not a constant: 1.64 across five focus scenes
on the hostile graph, 1.81 for one scene on it, 1.27 on the sparse type specimen where most
of the suppressed set is short. What must hold everywhere is a floor — the focused route
clearly ahead of the field — and the closure matrix holds it at 1.2.

## 4. Type cues

> **Cable type is derived from signal semantics in the graph model, never inferred from
> socket shape or colour.**

Two classes, because the program has two. All 182 ports on all 51 runtime types declare
audio or control and nothing else; `SignalType::Event` and `SignalType::Note` are real in
dsp-core — message types that do not interconvert with streams — and appear in `dsp-core/src`
only in the functions that turn them into strings and back. See §7.

```
audio      unmarked; the commonest cable, and the extra ink belongs elsewhere
control    a short transverse rib every CUE_CADENCE screen pixels
```

**Screen space, not graph space.** A cadence in graph units is absurdly sparse when you zoom
in and plaid when you zoom out; on the glass it stays constant.

**The body is never broken.** A dashed wire is a different object. The rib is laid across a
continuous cord in the sheen's own ink, so it belongs to the same material.

Exclusions: both cable ends, every crossing on that cord, and any bend over `CUE_BEND`.

> **connection and crossing geometry > type cue > focus prominence**

> **Cable type cues are sparse and redundant, not locally guaranteed. A cue may be omitted
> wherever connection, crossing or bend geometry has the higher priority.**

That corollary exists so nobody later "fixes" the crossing exclusion by plastering ribs onto
every short segment. The blind test earns it: fourteen endpoint-free grayscale crops named
fourteen times, and the one crop that could not be classified was taken *inside a crossing*,
where the exclusion had refused a rib. A cable must offer enough sparse evidence along its
route to identify its class. No arbitrary twenty pixels of it must.

Candidates weighed:

| | ink /1000px | why not |
|---|---|---|
| highlight cadence | −876 | spends the sheen it already had, costs negative ink, and produces an interruption nobody can find without knowing where to look |
| **transverse ribs** | **+61** | ships |
| off-path stamps | +92 | a diamond beside a cable reads as a connector or a very small node |

## 5. Persistent focus

> **Transient and persistent focus render identically. Persistence changes lifetime, never
> appearance.**

There is no locked colour, border, glow or width. A sixth cable channel for "this focus is
pinned" would undo the discipline the other three goals established. If a reader needs to
know the focus is locked, that belongs outside the wire.

```
click a cable         pin it; clicking it again lets go
click a port          pin its family; clicking it again lets go
Escape                let go
click empty canvas    let go
```

**Model B: the lock is home and hover previews.** Hovering another route while one is pinned
shows the other; taking the pointer away comes home to the pinned one. A lock that ignored
hover would be more predictable and would make comparing two routes a matter of unlocking
and relocking — the gesture the lock exists to save.

A lock is an **identity**, not a position, so it survives zoom and pan for free.
`prune_focus_lock()` runs on every rebuild because a stale reference would leave the field
quieted around nothing; opening a document clears it outright. Escape lets go of a focus
*before* it panics the instrument — Escape is the key for "never mind", and letting go of a
focus is a smaller never-mind than silencing the sound.

## 6. The frozen figures

```
KNOCKOUT_CLEARANCE   0.55   of the upper cable's width, either side of the gap
suppression          0.25   mixed toward the ground; the target is the 1.64 ratio
SPAN                 —      routes are never altered by focus, lock or cue
CUE_CADENCE        160.0    screen pixels between ribs
CUE_STROKE          20.0    screen pixels a cue occupies
CUE_CLEARANCE       26.0    screen pixels a cue keeps from anything that already means something
CUE_BEND            35.0    degrees; sharper than this is no place for a mark
```

The material figures — body width, shell darken, glint, shadow, hang, splay — are in
`docs/cable-design.md` and are not part of this vocabulary.

## 7. The taxonomy oddity, recorded and not resolved

The engine supports audio, control, event and note. The runtime graph uses audio and
control. The node and socket vocabulary still contains four shapes, two of which — square
and ring — no port can produce, and a trigger colour no cable can wear.

**Nothing is lying about an actual connection.** It is dead vocabulary, so it does not
reopen the frozen node grammar and it did not justify a third cable class. The question it
raises is a product and DSP-model one:

> Should SoundGraph eventually expose discrete message ports, or should the UI remove
> grammar for types the product deliberately does not use?

Filed in `docs/known-issues.md`. Not a reason to mutate a proven cable system.

## 8. Adding to the system

1. **Do not.** A cable is a consumer of this vocabulary. If a new idea needs a sixth
   statement, that is evidence the language lacks a primitive — bring the evidence.
2. If you must, the harnesses are below and the closure matrix is the gate.

**Do not** add a channel for a state that already has one, do not encode a semantic in a
treatment that was chosen for a different semantic, and do not tune a nominal figure without
re-deriving the achieved measurement it stands for.

## 9. The harnesses

| Script | Answers |
|---|---|
| `cable_baseline.gd` | routes, crossings, bundles, trespass, ink share — the step 1 measurements |
| `crossing_sheet.gd` | none / halo / knockout / bump on the same-colour crossings, and the ink each spends |
| `focus_sheet.gd` | five focus scenes at three suppression levels, and what each keeps of its resting luminance |
| `signal_audit.gd` | every port on every runtime type, and which signal classes exist |
| `type_cue_sheet.gd` | the four type-cue candidates, endpoint-free at 100% and whole-graph below |
| `blind_cues.gd` | shuffled endpoint-free crops and a key not to open first |
| `cable_gestures.gd` | the click, drag and key gestures, through real input routing in a window |
| `cable_closure.gd` | the closure matrix: 278 invariants over both specimens |

Two specimens, and they answer different questions:

```
editor-godot/qa/dense-graph.json    does the vocabulary stay calm in a real patch?
editor-godot/qa/cable-types.json    can the vocabulary be read at all?
```

`cable_gestures.gd` and every sheet need a window. Headless Godot has no rendering server
and no input routing, and a check that passes there would be a check of an empty room.
