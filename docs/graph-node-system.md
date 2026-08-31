# The graph node system

The specification for what a node in the patch graph is. Frozen at step 15A.3 of the
cosmopolitan pass, validated at 15B, and closed at 15B.1 — which reopened it once, for the
one systemic defect the dense-graph QA found, and closed it again.

`docs/graph-nodes.md` is the running record — every step, what was tried, what failed and
why. This is the settled result, written so that node fifty-two can be added without
reading that record.

**How to use this document.** A new node type is a *consumer* of the system. Work down the
checklist at the end; every decision it asks for has a rule here. If your type needs
something the rules cannot express, that is evidence the system lacks a semantic
primitive — bring the evidence, not a special case.

---

## 1. Anatomy

A node is four regions, top to bottom:

```
┌─────────────────────────────────────┐
│ [glyph] Title                   [!] │   header
├─────────────────────────────────────┤   rule
│ ○ in            name        out ●   │   port rows
│                 value               │   parameter rows
│ ◇ mod                               │
└─────────────────────────────────────┘   perimeter
```

| Region | Holds | Notes |
|---|---|---|
| Header | identity glyph cell, title, alert cell | Fixed height, `ANATOMY_HEADER`. |
| Glyph cell | one mark, or nothing | **Always present.** Reserved even when empty. |
| Alert cell | the validity mark | **Not** reserved. Drawn only when something is wrong. |
| Body | port rows and parameter rows | |
| Perimeter | selection, hover, health | See §6. |

The glyph cell is reserved and the alert cell is not, and the asymmetry is the point: every
title in the graph starts at the same x whether its type has a mark or not, so rolling new
types through the language cannot make the graph jitter — while an alert present on every
node as an empty square would be a permanent claim that something might be wrong.

Verified numerically at 15B: across thirty nodes, five palettes and four interface scales,
the title column does not vary by a pixel.

## 2. Spacing

Every figure in `NodeGrid`. Everything is a multiple of eight, or of four where a gap is
inside one object rather than between two. There are no other exceptions.

```
INSET_X        12   body edge to content, and the header's own name inset
INSET_TOP       8   under the header's rule
INSET_BOTTOM    8   under the last row
ROW_GAP         8   row to row
COLUMN_GAP     16   control to control on a row, and port label to controls
COLUMN         84   one control column — cells share it
LABEL_GAP       4   inside a cell: control to name
VALUE_GAP       4   inside a cell: name to value
CELL_ROW       72   a row carrying controls
PORT_ROW       24   a row carrying only ports
PORT_GUTTER_MAX 96  the most one port label may do to a node's width
```

**Port gutters are equal within a node and measured from that node's own longest port
label.** Equal, because otherwise "mod" on one row and "cutoff Hz" on the next moves the
whole control block sideways and two tidy rows read as four islands. Per-node, because a
fixed figure is a width class in disguise — 88px was tried and widened a two-port amplifier
from 219 to 314.

## 3. Typography

Type sizes come from `Design`. Three rules govern them:

1. **Font size participates in the level of detail.** When room runs out, remove
   lower-priority information rather than shrink required information below its floor.
2. **`TYPE_FLOOR = 14`.** No text is ever drawn smaller, at any interface scale. So text is
   *relatively larger* at the smaller scales — which is why **Compact is usually the
   binding case for width and XL the most forgiving.** Never accept a measurement taken
   only at XL.
3. **Screen minimums.** A label whose on-screen size falls under its floor is hidden and
   redrawn by the `ScreenText` overlay at the floor, pinned. If the pinned text will not
   fit its slot, it is not drawn at all (`Fit.NO_ROOM`) — **per parameter cell, not per
   label**. See §11.

## 4. Control grammar

| Parameter kind | Control | Reduced-detail stand-in |
|---|---|---|
| Continuous | knob + name + value field | name and value as words |
| Enumerated | dropdown | the chosen option as a label (`enum_value`) |

A cell is `control zone / name / value`, top to bottom — the rack's order. The name and the
value each get the full width of the cell rather than sharing a half-width line with the
dial, which is what stops a long name crowding its own value out of the picture.

**Cells on a row take equal widths.** That is what puts the control on the second row under
the control on the first, and it is the fact the packing rule in §9 turns on.

## 5. Socket grammar

Sockets carry the signal type by **shape as well as colour**, which is what makes them the
one channel that survives a grayscale render:

| Signal | Shape | Colour |
|---|---|---|
| audio | circle | mint |
| control | diamond | periwinkle |
| gate / trigger | circle | amber |

Connected sockets are filled; unconnected sockets are outlines. Both survive grayscale.

A cable takes the colour of what it carries and has **no** shape channel — see §11.

## 6. State channels

Five orthogonal channels in `NodeState`. Orthogonal means no state may erase another; all
five combinations were rendered and checked at step 11 and again at 15B.

| Channel | Carrier | Tokens |
|---|---|---|
| selection | perimeter colour + edge width | `SELECTION_CALM 0.22`, `SELECTION_EDGE 2` |
| hover | surface lift | `HOVER_LIFT 0.6` |
| health | header tint + alert mark | `HEALTH_TINT 0.16`, amber warning / red error |
| activity | output port level | existing port glow; nothing at node level |
| connection | socket fill | see §5 |

**There is no node-level "connected" state and no glow.** A node's connection is said by
its sockets and its cables, which is where a reader is already looking.

`HEALTH_TINT` is 0.16 and not more: at 0.30 the title fell to 5.3:1 against its own header,
under the program's 7:1 floor. `design_test.gd` gates the ratio across every palette.

## 7. Width ladder

```
enum Width { NARROW, SNUG, STANDARD, WIDE, EXTRA, BROAD }
const WIDTHS := [176, 208, 296, 376, 416, 448]
```

The figure is the **outer footprint** in graph space at base interface scale — border and
content margins included, before the interface scale multiplies it. A Standard node at XL
stands at 400 real pixels and there is nothing to add or subtract.

**A class is a width, not a floor.** `custom_minimum_size` only pushes a Control wider and
nothing pulls one back, so the width is set as well as floored once the tree has settled.

Two rules, both learned expensively:

> **Classes are discovered from clusters of actual requirement across the corpus, not
> chosen in advance and not stretched to fit one awkward node.**

> **Assign the smallest class at which the node is still *valid* in FULL detail, at its
> worst interface scale.**

Valid, not preferred. `width_sheet.gd` forces a node to each class in turn and asks whether
anything broke — a refused width, a clipped label, a child outside its node, two controls
overlapping on a row, a body that reflowed and grew taller. The first class that survives is
the class. `LayoutFit.complaints()` is the single definition of "broke", shared by every
harness so none of them can drift.

Natural width — how wide a node makes itself when nothing constrains it — is reported as
diagnosis and is **not** the selector. The state-variable filter preferred 411, required
416, and sat happily at 376; three real numbers and only one of them a contract.

## 8. Scaling

```gdscript
static func scaled(base: int) -> int:
    return int(roundf(float(base) * maxf(1.0, Design.SCALE_FACTORS[Design.ui_scale])))
```

Up with the interface scale, never down. A reader who asks for smaller interface text is
not asking for narrower nodes: at 0.875 a Wide node would get 329 pixels while the text
inside it barely shrinks at all, and five types fit no class at all.

## 9. The measured row-packing rule

The order is the contract:

```
build the controls → measure what they need → group them into rows → place the rows
```

Cells are constructed onto a hidden bench parented to the widget — so a Control that only
knows its size once it has a theme gets one, and an invisible child adds nothing to the
node's minimum — measured, then taken off the bench into their rows rather than rebuilt.

> **Layout may use a semantic descriptor to decide what a control *is*. Physical packing
> uses what the rendered control *measures*.**

```gdscript
const SPAN_OVER := 1.5
static func spans(cell: Control, siblings: Array) -> bool
```

A cell takes a row to itself when its measured minimum exceeds its **widest rowmate** by
half again. The criterion is relative because the allocation is relative: cells on a row
take equal widths, so a row of two costs twice its wider cell — pairing a 224 dropdown with
a 113 knob costs 448, not 337.

No absolute threshold can express that, proven from both sides. At one column every knob
cleared it (a knob cell is a dial *and* a name) and 32 of 51 types reflowed; at two columns
the Scale Quantizer's dropdown missed by two pixels, 224 against 226.

Scale Quantizer's two parameters sit at 224 against 113 and are the only such pair in
fifty-one types. Adopting the rule reflowed exactly one type — 536 to 424, which validates
at Broad — and left every other type's narrowest valid width unchanged to the unit.

## 10. Identity

### The name

```
canonical name if it fits at the legibility floor
    ↓
the type's written-down compact name
    ↓
nothing at all
```

`ScreenText._name_for` is the one implementation. **A cut name is a failure** for a migrated
type; an ellipsis in the graph now means exactly one thing — that type has not been through
the pass. Gated at zero.

**Every migrated type must have a compact name.** It is not a judgement about whether the
canonical will fit; it is what the type is called when there is no room, and a type without
one falls back to cutting. It does not have to fit either: a narrow node at a quarter zoom
has room for about three characters, and drawing nothing is the rule working.

Two types have none on purpose. "Keyboard" and "Output" are already the shortest true names
those things have, and inventing "Keys" and "Out" would be shortening for its own sake.

### The glyph

Nine rules, in `GlyphGrammar` and `docs/node-glyph-grammar.md`:

1. One field, one weight, one grid — `Icons.STROKE = 2.0`, drawn at `OPTICAL_SIZE = 30`.
2. A mark describes **behaviour**, not equipment: a response curve, not a filter; a gain
   stage, not an amplifier with a handle on it.
3. Marks are constructed from the grammar's own constants, never drawn by eye.
4. A family shares a construction; members differ by one parameter of it.
5. Nothing in a mark depends on colour.
6. The mark is subordinate to the name — secondary ink.
7. A mark that has stopped reading stands down. **7a:** a type may declare one identity
   *variant* parameter, and the mark follows it.
8. Marks are proofed at the size they are drawn at, magnified — never at 96px.
9. **Difference must be silhouette, not detail.**
   - **9a** repetition count is silhouette, not detail.
   - **9b** when the open field is full, reach for enclosure, topology or spatial
     relationship.
   - **9c** empty is part of the vocabulary.

### Identity variants

```gdscript
const VARIANT := {
    "StateVariableFilter": {"parameter": "mode", "glyphs": [LOW, HIGH, BAND, NOTCH]},
    "OnePoleFilter":       {"parameter": "mode", "glyphs": [LOW, HIGH]},
}
```

Opt-in, one parameter, and only where the parameter genuinely changes what the node *does*.
A state-variable filter set to notch is not doing the operation a lowpass does, so its mark
is not the lowpass mark.

### Reserved cells

> **A reserved identity cell is an intentional terminal state, not incomplete work.**

Twelve of the fifty-one types have one. Each was refused for a written reason, and the
reasons cluster:

| Type | Why |
|---|---|
| Clip, Abs, MinMax | their drawings are transfer functions; the response and generator families already own that territory, and the difference is detail rather than silhouette (rule 9) |
| Phaser, Allpass | a response the reader cannot see — phase, not amplitude |
| Drive | a transfer curve again; a clipped wave against the square is a matter of corner sharpness |
| Speech, Sampler hosts, Note Triggers | equipment, not operation (rule 2) |
| PluginEffect, PluginInstrument | a host has no operation of its own; the plugin's identity is not ours to draw |
| CableTest | a diagnostic, not an instrument |
| ScaleQuantizer | its operation is a table lookup, which has no shape |

**This closes the question. There is no target of 100% icon coverage, and pressure toward
one should be refused.** 15B's reserved-cell sheet puts all twelve side by side with three
glyph-bearing headers: the blanks read as a set of nodes whose identity is the word, the
title column is unmoved, and nothing looks broken.

### Rejected constructions, so they are not re-tried

| Concept | Tried | Why it failed |
|---|---|---|
| note seam | a keyboard, three cuts | a keyboard's identity is many parallel elements; the glyph field is seven stroke widths across. Structural, not fixable. Replaced by boundary marks ⊢ / ⊣ |
| gain | a line with a short upright at one end and a tall one at the other | reads as a plus sign at header size |
| Abs | rectified humps | reads as a formant |
| compressor | two lines meeting at a point | that is the disclosure chevron |
| maths signs | bare `+`, `×`, `<` | a mathematical sign at header size is an application command |
| the ring as rescue | putting a refused mark inside a circle | its interior is under three pixels at header size; it carries a plus and a cross and nothing larger |

## 11. Optical states — FULL, REDUCED, MAP

```
FULL      Detail.FULL                  the working node, edited in place
REDUCED   Detail.COMPACT               still a node, secondary information gone
MAP       Detail.SUMMARY, TOPOLOGY     a symbol in a signal-flow diagram
```

|  | FULL | REDUCED | MAP |
|---|---|---|---|
| selection | yes | yes | yes |
| validity | yes | yes | yes |
| hover | yes | simplified | minimal |
| connected socket | yes | yes | yes |
| activity | yes | optional | where still useful |
| **controls** | yes | **no** | **no** |
| parameter values | yes | as words | no |
| port labels | yes | yes | while they fit |
| identity glyph | *not on this ladder* — it stands down with the title at the title's own compensation boundary |

**Words out-survive controls.** At REDUCED the knob's room is given to the words that say
what it was: between "frequency" and a nameless groove, the word carries the meaning and
the groove is recoverable by zooming in.

### The unit of removal

> **A parameter cell is the unit of level-of-detail removal. Its name and its value appear
> together or not at all.**

`ScreenText.cell_reaches()` is the decision and `_draw_pairs` is the only caller. Nothing
ranks the halves: both universal priorities were tried — keep the value, keep the name —
and both were wrong for the same reason. `cutoff` alone is incomplete but interpretable;
`900 Hz` alone is considerably worse; neither is a smaller version of the statement.

This was 15B's one systemic finding and the only rule added after the freeze. Before it,
`Fit.NO_ROOM` decided per *label* while a parameter is a *cell*, and 29% of cells at
Compact and 13% at Comfortable arrived as half a pair, in both directions, across nine node
types. After it: zero, at every zoom, at every interface scale, and a hundredth either side
of every band boundary — and **no cell that was whole became absent.** The split cells moved
from split to absent and nothing else moved.

One cost, recorded: at Compact and at the 86–89% straddle, the Keyboard's `transpose` cell
loses its name as well as its number. The knob is still drawn — control visibility did not
change — so what the reader sees is an unlabelled dial rather than a labelled one with no
figure. One cell of ninety-seven, at the tightest interface scale.

### Body controls declare their own distance

> **Every interactive body control declares the lowest optical state it may appear in.
> The default is FULL.**

`NodeOptical.requires(control, state)` at the control's construction site; `floor_of` and
`survives` read it; `_apply_body_optics` enforces it. A widget is for aiming at and there is
nothing to aim at past FULL, so anything that survives further has to say so.

This replaced six `hide()` calls. The plugin host's three buttons, the CC learn button, the
speech words button and the sequencer's step lane were all being drawn at 28%, because each
is added straight to the node and the parameter-row machinery never saw them. They are
governed now because the grammar says so, and so is the seventh.

## 12. Value formatting

`ValueText` in `value_text.gd`. Semantic, not `%f`:

```
STEPS        500.0   the resolution a drag is quantised to
FIGURES        3.0   significant figures
MAX_DECIMALS     4
```

Seconds become milliseconds under a second (`600 ms`, not `0.6`); frequencies take a kHz
suffix over a thousand (`1.2 kHz`); a unitless ratio keeps three figures. The column is
sized from `ValueText.widest()` so a value changing does not move the layout.

## 13. The fifty-one runtime types

```
51 runtime types
   39  migrated
   12  migrated, identity cell intentionally reserved
    0  held
```

| Class | Width | Types |
|---|---|---|
| Narrow | 176 | Gain, Constant, Add, Multiply, Level, Compare, Abs, AudioInput, CableTest, Drive |
| Snug | 208 | TriggerBus, StereoLevel, SampleHold, seam:Input/audio |
| Standard | 296 | ADSR, SawOscillator, Noise, Mixer, Allpass, Formant, Clip, PluginInstrument, Crush, AhdEnvelope, MidiCC, NoteTriggers, StereoOutput |
| Wide | 376 | seam:Output/stereo, LFO, seam:Input/note, Phaser, NoiseOscillator, StepSequencer, Delay, Comb, MinMax, Sampler, Speech, PluginEffect, Compressor, Retrigger, Euclid, NoteInput |
| Extra | 416 | StateVariableFilter, Clock, OnePoleFilter, SquareOscillator, SineOscillator |
| Broad | 448 | Arpeggio, Slide, ScaleQuantizer |

`inventory.gd` enumerates the registry, binary-searches each type's narrowest valid width at
every interface scale, and asserts `registry runtime types = migrated + held`. Run it after
adding a type.

## 14. Adding node fifty-two

1. **Width class.** Run `width_sheet.gd` with `WIDTH_SHEET_TYPES=YourType`. Take the
   smallest class that is valid at its *worst* interface scale. If none holds it, that is
   evidence for a class — bring it to `inventory.gd`'s histogram, not to a new number.
2. **Compact name.** Mandatory. Add it to `NodeIdentity.COMPACT`. It does not have to fit
   at every zoom.
3. **Glyph.** Ask what the node *does*, not what it looks like or what its ports are.
   Search for semantic consensus first — the corpus establishes what a concept looks like;
   SoundGraph owns the final geometry. Construct it from `GlyphGrammar` constants. Proof it
   with `glyph_sheet.gd` at the header cell, beside the marks it could be confused with.
   **If it fails rule 9, reserve the cell and write down why.** That is a finished answer.
4. **Identity variant** only if one parameter genuinely changes the operation.
5. **Register it** in `NodeIdentity.MIGRATED`.
6. **Run the gates**: `editor_test`, `design_test`, `layout_test`, `panel_style_test`, then
   `inventory.gd` for the equation and `qa_sheet.gd` for the dense graph.

**Do not** add a spacing token, a width, a type size, a state channel or a glyph rule for
one node. If your type needs one, the evidence has to be several independent types or
contexts — that is the bar the frozen system is held to, and it is the bar that stopped this
pass from becoming a redesign loop.

## 15. The harnesses

| Script | Answers |
|---|---|
| `inventory.gd` | every runtime type, its class, its narrowest valid width, the equation |
| `width_sheet.gd` | which class a type belongs in, by forcing it to each in turn |
| `layout_fit.gd` | the one definition of "laid out correctly" |
| `glyph_sheet.gd` | do the marks form families; do the confusable pairs separate at header size |
| `state_sheet.gd` | do five state channels coexist |
| `optical_sheet.gd` | does the detail ladder hold across every band boundary |
| `reserved_sheet.gd` | do twelve empty identity cells look intentional |
| `qa_sheet.gd` | the dense graph: eighty frames of machine checks, twenty-six pictures |
| `qa_reduced.gd` | what a parameter actually says to the reader at each distance, and whether any control outlives FULL |
| `graph_baseline.gd` | the step 1 measurements, so nothing has silently moved |
