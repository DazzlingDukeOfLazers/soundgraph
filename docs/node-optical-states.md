# Optical States

What a node is at each distance, written down as a contract instead of left as behaviour.

Almost nothing here is new machinery. `PatchGraph.Detail` already had four bands chosen by
measured floors, and step 1 showed the editor already shedding parameter rows and then the
whole control panel as the zoom fell. What it never had was a statement of what each band
is *for* — and behaviour with no statement is behaviour nobody can hold to account, which
is how a level of detail quietly acquires a tiny knob that is technically drawable.

`editor-godot/node_optical.gd` is the statement. `editor-godot/optical_sheet.gd` is the
audit that checks it, and it found four things: two bugs, one wrong entry in the contract's
own table, and one place where the renderer disagrees with the brief and is right.

## The three states, on the four bands that produce them

No new thresholds. The names go on what is already there.

```
FULL      Detail.FULL                  the working node, edited in place
REDUCED   Detail.COMPACT               still a node, secondary information gone
MAP       Detail.SUMMARY, TOPOLOGY     a symbol in a signal-flow diagram
```

MAP is two bands because it is two cuts of one idea: SUMMARY keeps the port names,
TOPOLOGY has not the room for them. Neither draws a control, and that is what makes both
of them MAP rather than a smaller REDUCED.

### Where the boundaries actually are

They move with the interface scale, and not all in the same direction.

```
scale          FULL    REDUCED   MAP      value drawn at
Small          0.875   0.580     0.380    14 px
Comfortable    0.875   0.580     0.380    16 px
Large          0.875   0.667     0.437    18 px
XL             0.875   0.783     0.513    22 px
```

Read as: at XL a node is FULL at or above 0.875, REDUCED from 0.783, MAP below. Confirmed
live by the sweep — FULL to REDUCED between 0.875 and 0.870, REDUCED to MAP between 0.783
and 0.778, and MAP's inner cut between 0.513 and 0.508.

**REDUCED is a tenth of a zoom wide at XL and three tenths at Comfortable.** That is the
first finding and it has a cause: the FULL floor is `TYPE_FLOOR / SIZE_NUMERIC` on *base*
type sizes, so it is 0.875 at every interface scale, while the room floors underneath it
are scaled up by the reader's preference. At XL a parameter value is actually drawn at
22px and stays over the 14px floor down to a zoom of 0.636 — so FULL ends at 0.875 for a
reason that stopped being true two scale steps ago, and REDUCED is squeezed into what is
left above the room floor at 0.783.

It is reported rather than changed. Moving it is not a small edit: the legibility floor
falls as the interface scale rises and the room floors climb, so at XL a corrected FULL
floor of 0.636 would sit *below* the REDUCED floor of 0.783 and the band would vanish
entirely. Which of the two governs is a real design question — the existing comment
already argues that room wins — and it is not one to settle inside a step whose brief says
not to replace the mechanism.

## What each state contains

```
FULL      identity glyph, canonical title, controls, parameter labels and values,
          dropdowns, port labels, ports, every interaction and validity state.
          The complete steps 3-11 node.

REDUCED   title, ports and their connection, the parameter names as words where the
          controls were, port labels. Nothing to aim at: the controls have given
          their room to the words that say what they were.

MAP       silhouette, identity, perimeter sockets, cables, selection, validity.
          Port names while they fit. Nothing else.
```

### REDUCED keeps names and drops values, and that is deliberate

The brief's priority puts important values above secondary parameter labels. The renderer
does the opposite, and its own comment says why:

> If the two genuinely cannot both fit, the *value* goes, because a name with no number
> still says what the node has and a number with no name says nothing.

That is right, and the orphan it avoids is a real thing that used to happen here: drawn
independently, the value's box expanded into the room the hidden slider left, the name was
pushed back to its own 96px, "resonance" no longer fitted at its minimum, and the number
survived on its own. The brief allows for exactly this — *the exact ordering can vary
where the current renderer already demonstrates a better solution* — so it stands.

It is not eagerness, either. At XL and a zoom of 0.83 a parameter cell is 94 screen pixels
wide and "resonance" at the 20px legibility floor wants 85 of them. There is no room for
both. One word or none, and the name is the word worth having.

## What the audit found

### The ellipsis was being applied to the wrong name — fixed

`Amp Envelope` fell to `Amp E…` below a zoom of 0.28. The fallback found the type's
written-down compact name, `Envelope`, decided it did not fit either, and then cut the
**canonical** name — throwing away the shorter name it had just rejected and cutting the
longer one instead. `Amp E…` says less than `Envelo…` would have, and neither is an
identity.

The rule now is canonical, then the compact name, then **nothing at all** — for a type
that has a compact name. That is the governing rule of the whole pass applied to its own
last case: remove information before reducing its legibility. At the zoom where this
happens the node is a symbol in a diagram whose position and cables already say which one
it is, and a reader who needs the name can come closer.

A type with *no* compact name still gets cut, because for it a cut is the only thing on
offer and half a name beats none. So an ellipsis in the graph now means exactly one thing:
**that type has not been through the pass.** The 28% acceptance picture shows it — `Main…`
and `Filter Sw…` are cut, `Lowpass`, `Amp` and `Envelope` are whole words.

`design_test.gd` holds the three migrated types at zero cuts across thirty-six zooms and
five palettes, so it cannot come back.

### The identity glyph is not on the band ladder — table corrected

The first draft of the survival table said the glyph survives FULL. It does not survive
all of it. The glyph stands down with the title Label at the *title's* compensation
boundary, which at XL is near a zoom of 0.90 — inside FULL, above the FULL/REDUCED line at
0.875. So for the bottom slice of FULL the node has no mark.

Two systems keyed to two different thresholds, which is the thing this step exists to
notice. The behaviour is right — a mark that has stopped reading should go — so the table
was corrected rather than the code. Moving either threshold to make a table look tidy is
what the brief said not to do.

### The transitions are clean

Thirty-three zooms, every boundary crossed at a hundredth and a half-hundredth either
side. No title jumping, no body resizing, no compact name arriving early, no value orphaned
by the control it belonged to, no control disappearing while its label stayed.

One thing is worth writing down because it looks like a fault and is not. The parameter
labels vanish at a zoom of 0.783 and the band changes at 0.778, so for five thousandths of
zoom the node is in REDUCED while showing MAP's content. The two thresholds are different
arithmetic for the same idea — the point at which the control panel's words stop fitting —
and they land a fraction apart. Nothing is visible, because both remove the same
information: the picture at 0.783 and the picture at 0.778 are identical. It is an
inconsistency in the bookkeeping and not in the drawing, and fixing it would mean moving a
threshold to tidy a number nobody sees.

### Empty MAP bodies are fine, and the chassis stays put

At MAP the controls are gone and a wide node is a mostly empty rectangle. Looked at in a
patch rather than in isolation, this is not harmful: the empty body is what gives the node
a silhouette, its footprint still matches the size it has at FULL, and the cables still
land where they land. Shrinking the chassis at low zoom would move every cable end, break
the correspondence between the map and the thing it is a map of, and make zooming a
rearrangement rather than an approach.

So nothing was changed. Node dimensions do not depend on zoom, and this is the audit that
decided they should not start.

## The proof sheets

```
godot --path editor-godot --script optical_sheet.gd   # OPTICAL_SHEET_OUT names the folder
```

`optical-{node}.png` is one node at FULL, REDUCED and MAP at the sizes it is actually
drawn — the sheet that judges design. `optical-{node}-magnified.png` is the same rasters
enlarged three times with nearest-neighbour, which is the sheet that diagnoses rendering.
The two answer different questions and neither substitutes for the other.

`optical-patch-{100,66,40,28}.png` is the whole of First Synth, three migrated nodes among
four that are not. `optical-states.json` is the sweep.

## Acceptance, at 28%

- Migrated nodes become simpler as the zoom falls, and they do it by dropping information
  rather than shrinking it.
- The unmigrated four demonstrate the old behaviour: two of them are cut.
- Titles are intentional — three whole words where a slice used to be.
- The signal path is traceable, and the sockets are still told apart by shape and colour.
- Selection and validity survive, as step 11 measured.
- No control is drawn anywhere below FULL merely because it technically could be.
