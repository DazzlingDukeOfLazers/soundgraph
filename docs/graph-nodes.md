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

## Step 4 — the internal grid

`node_grid.gd` holds every figure the inside of a node is built from. Before it they were
spread through the builder — `SPACE_M` here, a bare `0` there, a row height that happened
to be 74 — and the result was what you would expect: controls that had each been nudged
until they looked right on whichever node somebody was looking at.

```
INSET_X       12    body edge to anything inside it, and the header's own inset
INSET_TOP      8    under the header's rule, before the first row
INSET_BOTTOM   8    under the last row, before the body's foot
ROW_GAP        8    between rows
COLUMN_GAP    16    between controls on a row, and between a port label and the controls
COLUMN        84    one control column, shared by every cell
LABEL_GAP      4    control to its name
VALUE_GAP      4    name to its value
CELL_ROW      72    a row carrying controls
PORT_ROW      24    a row carrying only ports
```

Eights, or fours where the gap is inside one object rather than between two. `CELL_ROW`
and `PORT_ROW` were 74 and 28 — near enough to the rhythm to look deliberate, far enough
off it to put every row below them half a unit out.

### What was actually wrong with the Lowpass

Not the spacing. The controls sat in a box that expands to fill, centred between two port
labels of different lengths — so `mod` on one row and `cutoff Hz` on the next moved the
whole control block sideways, and two tidy rows read as four islands.

**The gutters are equal within a node and measured from that node's own longest port
label.** Equal, so the control region has one left edge and one right edge on every row;
measured per node, because a fixed figure is a width class in disguise — 88px was tried,
and the Amplifier, which has two short port names and one knob, went from 219 to 314
holding two gutters sized for a node it is not.

With that, cutoff sits over mode and resonance over sweep: two rows, by rule rather than
by nudging.

### The three specimens

```
Gain        one column, two ports      219x147 -> 231x150
ADSR        a regular 2x2              382x101 -> 400x101
SVF         mixed two-column           482x239 -> 500x248
```

Twelve to eighteen pixels wider, from the gaps: `COLUMN_GAP` is 16 where the old
separation was 12, and it is paid twice on a row. Three pixels taller on two of them, from
the micro gaps inside the cells. `COLUMN` is 84 rather than the 104 tried first, because
84 is the floor the builder already used for a name box — the column is not there to make
cells wider, it is there to make them the same.

The simple node stayed simple: the Amplifier is 231 wide, not 314.

### Measured

Topology unchanged: seven nodes, seven wires, no moves, no ports gained or lost. The other
four node types are untouched. Detail bands identical at every zoom. One title changed at
40% — `Amp Envelope` now fits its canonical name in a node eighteen pixels wider, so it no
longer needs its compact one. That is a consequence of the grid rather than a width class,
and it is recorded here because the next person to read the title numbers will wonder.

## Step 5 — control typography

`node_text.gd` holds six roles and every decision about face, size and colour that goes
with them. They were being made where each label was built, which is how two of them ended
up identical.

```
NODE_TITLE      semibold, node-title size, bright        identity
PARAM_VALUE     numeric face with tabular figures,       the loudest thing inside
                numeric size, bright
PARAM_UNIT      unit face, unit size, secondary          the value's family, one down
PARAM_LABEL     medium, body size, secondary             subordinate to its value
PORT_LABEL      regular, body size, secondary a shade    the quietest text on the node
                quieter
CONTROL_OPTION  medium, control size, bright             a dropdown's value reads as one
```

Reading order, which is the test: **node name → values → parameter names → port labels.**
Before this, a parameter's name and a port's name were both medium weight, body size,
normal ink — and the value was bright. Four ranks of information, two ranks of type.

### The Amplifier's two `gain`s

Not renamed. The port one is regular weight in the quietest ink on the node, beside its
socket; the parameter one is medium in secondary ink, centred under the knob it names,
with its value bright underneath. They are now different kinds of text saying the same
word, which is what they are.

It is better and it is not finished: the two are still the same size, and what will
actually settle it is position — a port label that reads as belonging to its socket rather
than sitting in the same column of text. That is step 7, and this is the note the brief
asked for rather than a rename.

### The floor bites from above

The first cut of `PARAM_LABEL` dropped it to the secondary size, which is the obvious way
to make a label subordinate. At XL that is 19px against a `MIN_SCREEN_LABEL` floor of 20 —
so at **100% zoom** every parameter name went under the legibility floor, the compensation
system took them over, and the node lost its parameter names and its values at the one
zoom where nothing should be compensated.

Rank is carried by weight and ink here, which the floor has no opinion about. The lesson
generalises: on this editor, type size is load-bearing for the level-of-detail system, and
"make it smaller so it recedes" is not available below the floor.

### Measured

Tabular figures were already in place — `Design.numeric_font` sets `tnum` — so values do
not shove their units sideways as they change; the roles make it explicit rather than
incidental.

Node sizes moved by one to three pixels, from the regular-weight port labels being
narrower than the medium ones they replaced. Topology, positions, ports, cables, control
values, chassis, grid and the other four node types are unchanged, and the detail bands
draw the same 66 / 24 / 0 / 0 controls at the same four zooms.

Precision is untouched: `0.700`, `900.0 Hz`, `0.000 octaves/s` are as they were. Three
decimals on a gain of 0.7 and on a sweep of zero is more precision than either reading
needs, and that is a formatting decision rather than a typographic one — recorded here,
not taken.

## Step 6 — the control as a diagram

The rack's knob is a moulded part: a collar, a cast shadow, a cap, a moulding line, a
sheen, a dark under-stroke beneath the pointer and eleven printed ticks around it. That is
right on a faceplate. In the graph it is nine primitives that say what the knob is made
of, and at 40% they average into a textured grey circle.

`Rack.Knob` gained a `diagram` flag — the same control, same descriptor, same drag, same
keyboard, a different picture, which is the relationship the fader already had with it.
Four marks, and every one says where the knob is set:

```
track     where it can go       one thin arc, quiet
arc       where it is           the same arc in mint, from the minimum
body      the control itself    one disc, one edge
pointer   where it is, again    the strongest mark on it
```

The value is said twice on purpose. The arc reads at a glance and at any size; the pointer
reads precisely. That redundancy is why this survives being shrunk when nine layers of
moulding did not. The pointer is a fifth of the radius and floored at two pixels, where
the rack's was a fixed 2.8 over a dark 4.4 — two smudges once the zoom got hold of it.

### Ticks: compared, then dropped

The proof sheet has three bands — the old knob, the diagram, the diagram with three
reference marks — each at 96px, then at the size a node actually draws it, then that at
66% and 40%, with the knob at 10%, 50% and 90% of its travel.

Three marks are legible on the 96px specimen and gone by 66% of actual size. They are not
carrying position; the arc is. `diagram_ticks` exists and is off, so the comparison can be
made again rather than argued about.

The enlarged specimen does look too simple, which the brief predicted. The actual-size
column is the one that decides, and there the diagram is clearer at every position.

### The dropdown

`mode` was the loudest thing on the Lowpass: a bright slab with a heavy border between two
knobs that had just been quietened. It is the node's own surface now, with the hairline
every other edge here wears and the editor's drawn caret instead of the theme's arrow.

It took two goes, and the first failure is worth keeping: `_mount_chooser` strips every
stylebox off an unpainted module's dropdown as it passes, so the styling was applied and
then quietly removed. The only reason it was caught is that the font size it does *not*
strip stayed put, so the control was half-dressed rather than plainly wrong. The node's
dropdown carries a `node_diagram` mark, and `_mount_chooser` puts the dress back where it
has just taken it off.

### Measured

Node sizes are unchanged from step 5 — the diagram occupies the same box as the moulding
it replaced. Topology, ports, cables, values, typography, grid, chassis, detail bands and
the other four types are all as they were: the same 66 / 24 / 0 / 0 controls at the same
four zooms, the same seven nodes and seven wires.

## Step 7 — ports and cable termination

A cable should look plugged into a socket, not connected to a coloured coordinate.

### The socket

Three marks, and a rule about what each is for:

```
hole    dark, in the canvas's own colour     a socket is a hole in the node
ring    the signal's colour                  what a port must say before it is read
edge    one hairline                         so the ring has an edge against the body
```

No washer, no nut, no bevel, no glow. The knobs have just escaped from miniature hardware
and the ports are not walking back into it.

**The ring carries the type as well as the colour.** Audio is round, control a diamond,
event a square — the same shape language the old grommet drew as a pip *inside* the
socket, moved onto the ring itself. One mark doing two jobs instead of two marks doing one
each, and a reader who cannot separate mint from blue can still separate the ports.

**Connected and unconnected differ in weight, not in light.** An occupied socket has a
fuller ring and a trace of the cable's colour in its hole; an empty one is a thinner ring
around a dark one. The first attempt differed by a shade of alpha and could not be told
apart on the Lowpass, which is the node that has both at once. Nothing glows: whether a
cable is plugged in and whether signal is flowing are two facts, and only one of them is
allowed to be bright.

### Termination

The node draws above the cord layer already, so a cable ends *under* an opaque socket with
no masking, no reordering and no change to the connection coordinate. What had to go was
the plug: `PlugOverlay` draws a mouth and a collar at every connected end, above
everything, and on a node whose port is already a socket that is a second mark saying the
same thing. Ports on the pass are skipped there; the node's own icon is the termination.

### Paint wins where there is paint

The proving ground is now "these three types **and** no faceplate". A painted module keeps
the rack grammar whole — plate, grommet, plug seated in it — because half a module in each
language is worse than either. The panel suite caught exactly that: a painted patch whose
filter had lost its plugs while its neighbours kept theirs. It is a fact about the paint as
much as about the type, so it is decided where the paint is, not where the widget is born.

### Measured

Nothing moved. Same node sizes, same port positions, same seven nodes and seven wires,
same detail bands, same 66 / 24 / 0 / 0 controls. Signal colours untouched; no port
renamed.

The duplicate `gain` reads as two different things now, and it is placement that did it
rather than type: one sits on the perimeter beside a blue diamond, the other under a knob
above its own value. The spatial grammar separates them, which is what step 5 predicted it
would take.

## The acceptance sheet, before step 8

The three specimens together at 100%, 66% and 40%, each captured from the real patch and
composed side by side at one scale per sheet. Five questions, answered honestly:

**Does any node look a generation older than the others?** No. The three share a header,
a socket grammar, a control language and a type ranking, and the four types that have not
been through the pass are visibly of the older generation in the same patch — which is
the evidence the scope is real rather than a claim.

**Can the signal path be followed before reading labels?** Yes, and shape does most of it:
round sockets are audio, diamonds are control, and the cables carry the same colours.

**Do ports dominate?** No, and it is close. At 100% the sockets are the smallest marks on
the node; at 66% they and the header are all that is left, which is the band doing its
job.

**Is the body calm?** Yes at 100%. The Lowpass is the busiest and it is the one with six
ports and four controls.

**At 40%, does the graph become simpler or merely smaller?** Simpler: the controls are
gone, the names are compact where they need to be, and what remains is a labelled box with
sockets.

## Step 8 — width classes, measured rather than chosen

The specimens were measured under the frozen language first, at base scale:

```
node          width  title needs  compact  columns  control room  gutters L/R
Gain           170        96         60       1          84         30 / 23
ADSR           294       136         95       2         184         31 / 23
StateVariable  368        91         64       2         184         74 / 23
```

The classes are those widths rounded up onto the eight the rest of the node is built on:

```
Narrow     176    Gain
Standard   296    ADSR
Wide       376    StateVariableFilter
```

Not equal increments, and there is no reason they should be — a class exists to give the
graph a rhythm of a few repeated widths, not to make a table of round numbers. There is no
fourth class yet; one arrives when a node earns it, measured the same way.

`NodeGrid.WIDTH_CLASS` maps type to class. That is metadata: a width that emerges from
whatever minimum sizes the controls happened to ask for is not a class, it is an accident
with a name.

### What changed

```
Amplifier      230 -> 238    (+8)
Amp Envelope   397 -> 400    (+3)
Lowpass        497 -> 508    (+11)
```

Titles are unchanged at 100, 66, 40 and 28% — canonical where they were canonical, compact
where they were compact. No other node moved; topology, ports, cables and values are as
they were.

### The long-label ceiling

`PORT_GUTTER_MAX` is 96 at base scale. The longest gutter in the proving ground is the
Lowpass's 74, so it does not bind today; it is there so that the first node with a
genuinely long port name clips and records the overflow on itself rather than dragging the
width system wider. What to do about such a label — a compact port name, a second line, a
tooltip — is its own policy, and this is the ceiling that stops it being decided by
accident.

## Step 9 — the identity glyph

### On the Noun Project

The client is `TheMutantFactory/noun-project-utils` — a standard-library Python CLI for
API v2, whose credentials resolve from `NOUN_KEY`/`NOUN_SECRET`, then
`~/.config/noun/credentials.cfg`, then the Dot-Gobbler game's own Godot store. It was
already on this machine and already authenticated, which the first pass of this step
failed to find and wrongly reported as "no integration anywhere". The search below is what
that pass should have contained.

**It cost nothing.** `search` and `usage` are free; only `GET /v2/icon/{id}` is metered.
The metered counter read 2 before this step and 2 after; the free counter went 9 to 24.
And search results carry `thumbnail_url` on the static CDN, so every candidate below was
**looked at**, as a contact sheet of PNGs, without a download being charged. That is the
useful discovery for the rollout: the whole browsing half of this work is free, and the
spend only begins if a mark is actually taken.

### What the corpus said about the three concepts

```
concept    searched                                   read
amplifier  "amplifier", "operational amplifier",      1013490, 5944775, 6311101,
           "gain"                                     1375352/3, 8455775, 8372410
filter     "low pass filter", "audio filter",         4799932, 4799936, 4799937,
           "frequency response", "filter cutoff"      6041992, 627910, 5341173
envelope   "adsr envelope"                            6850395, 385861-385867
```

**Nothing was redrawn.** All three marks are the convention the corpus converges on, which
is the outcome to want from a search like this — it is evidence the marks are readable by
people who have never seen this program, not a shopping trip.

- **The amplifier.** Every serious result is the schematic triangle. `1013490` is the
  cleanest of them and is the same drawing as ours. What the corpus adds is a
  *subtraction*: they nearly all carry `+`/`−` input pins and power rails, and ours must
  not. Those pins make it an op-amp, and a Gain node is a gain stage, not a part.
- **"gain" is a financial word.** `8372410`, `8228118`, `7593916`, `6775810` are all
  arrows, bar charts and dollar coins. Worth knowing beyond this step: it is a term the
  browser's search should not lean on either.
- **The response curve.** `4799932` (`lpf`, Slamet Widodo, from a collection called
  Signal Processors, 158763) is our mark almost exactly — flat, a knee, away down the top
  end. Two things come with it. Its siblings `4799936` (`hpf`) and `4799937` (`bpf`) are
  the same drawing mirrored and humped, so **the filter family already has a drawing rule**
  waiting for the day HighPass and BandPass need marks. And it draws axes, which ours does
  not; at an 18-pixel header those lines would be a pixel of clutter, so the omission
  stands, but it is now a decision rather than an oversight.
- **The two rejected metaphors are both in the corpus, and both are worse.** `627910` is
  the funnel — a picture of a filter — and `6041992` is a literal resistor and capacitor.
  Step 9 turned both down on reasoning; the sheet is what that reasoning looks like at
  150 pixels.
- **The envelope.** `6850395` is the four-stage contour, same as ours. The better find is
  `385861`-`385867`: one family that draws the *whole* envelope every time and solids only
  the segment being named, dashing the rest. That is a real technique for showing which
  stage is running, and it is written down here because interaction states are step 11's
  problem and this is the answer arriving early.

### What is owed

Nothing. No artwork was downloaded and none is used: these are conventions read off a
corpus, and a schematic amplifier triangle is not anybody's copyright. So there is no
attribution string to ship and the marks remain locally drawn.

If a glyph is ever genuinely sourced, `TheMutantFactory/get-in-loser` is the layout to
copy — the downloaded original kept so derived files can be rebuilt, a licence record with
creator and terms, a generator, and the attribution in prose with the modifications named.
It also names the thing SoundGraph would need and does not have: CC BY wants *visible*
attribution, so a sourced icon means the application needs somewhere to show it, and that
somewhere is Help.

### The marks

```
Gain                  the amplifier symbol: a triangle in the signal path
StateVariableFilter   the response: flat, a knee, away down the top end
ADSR                  the envelope's own polyline, attack through release
```

All three describe behaviour rather than equipment — a response curve rather than a
filter, the amplifier symbol rather than an amplifier. A picture of the hardware would be
the third time this pass has had to walk back out of a rack.

**Gain was a comparison.** The other candidate was amplitude growing along a signal: a
horizontal line with a short upright at one end and a tall one at the other. At header
size the two uprights and the line read as a plus sign. The triangle is what a gain stage
is called on every schematic ever printed and it survives the size, so the level candidate
was drawn, rejected and deleted rather than kept as a second option nobody would choose.

**The envelope reuses the browser rail's mark**, which is the same idea in a different
place — one icon set, used twice. The filter does not: the rail's Filters row is a funnel,
which names the *category*, and the node names the *operation*. Two marks for related
things, and it is deliberate; recorded here because it is the sort of thing that looks
like an oversight later.

### Where it sits

At the left of the title, in a cell that is reserved whether or not a type has a glyph
yet, so rolling the rest of the library through the pass cannot make titles jitter
sideways. Identity ink, not a signal colour: a lowpass is not green because audio is
green. Title stronger than mark, mark stronger than metadata — the ranking the menu's
doors already use.

### The mark stands down when the title is compensated

At 66% and below the node's own title Label is hidden and the name is drawn at the
legibility floor from the node's left edge. A mark left in place there has two ways to go
and both are wrong: over the letters, or in front of them — taking room the name needs and
pushing it into its compact form earlier than it should, which is a threshold moved by a
decoration. So the glyph fades with the Label it belongs to. The identity glyph is a
full-size device; below that, the name is the identity.

That is the honest limitation of this step: **the accelerator is not there in the band
where reading is hardest.** Making it survive means revisiting how the compensated title
divides the header, which is step 12's question and not this one's.

### Measured

Node sizes byte-identical to step 8. Titles identical at 100, 66, 40 and 28% — canonical
and compact exactly where they were. No node widened, no threshold moved, no control,
port, dropdown or header dimension touched.

Blind test: with the titles hidden, the three headers read as an amplifier, a time
contour and a frequency response. The envelope and the response curve are the closest pair
— both are angular lines — and they still separate: one rises before it falls and holds a
plateau, the other starts flat and only falls.

## Step 10 — the family grammar

Not forty icons. The three marks that worked, turned into the rules they obey, and two
families drawn to prove the rules produce siblings rather than one-off pictures.

`editor-godot/glyph_grammar.gd` holds the contract and the family plans;
`editor-godot/glyph_sheet.gd` renders the proof. The reasoning, the sheet's row order and
the two places the grammar strains are in `docs/node-glyph-grammar.md`; when to search the
Noun Project and what it costs is in `docs/icon-sourcing.md`.

Three things worth carrying out of it:

**The specimens are unchanged, and that is measured.** The lowpass was rewritten to be
constructed from the shared grammar rather than from its own hand-placed numbers, and all
twelve renders — three marks, four sizes — come out pixel for pixel identical to the
capture taken before the change. A refactor that claims to change nothing should be made
to prove it.

**The proof sheet found a rule.** Siblings have to differ in silhouette, not in a detail.
Mirroring is a silhouette and the highpass is immediately the lowpass; removing one stroke
is not, and the routing switch is legible only if you already suspect it. Three
constructions were drawn for the switch and the best of them still fails, which is
recorded as a failure rather than nudged until it photographs well.

**Nothing was migrated.** Gain, StateVariableFilter and ADSR are still the only types
wearing a mark. The seven new glyphs are attached to nothing.

`design_test.gd` now checks every icon marks pixels and stays inside its cell — the first
because an icon that silently draws nothing is the tofu box in a new hat, the second
because the field is what keeps a mark off the title beside it.

## Step 11 — the state vocabulary

Five channels, one per fact, so that a node can be selected, broken and passing signal at
once and a reader can still answer each separately. `editor-godot/node_state.gd` holds
them; `editor-godot/state_sheet.gd` proves them on First Synth; `docs/node-states.md` is
the record, the measurements and the two verdicts.

The short version:

**Selection** is a continuous mint perimeter at twice the weight, calmed a fifth of the
way toward the node surface. Two cues, one of them not colour, and continuity is what
separates it from the mint already inside the node.

**Validity** is the header, tinted 16% toward amber or red, with a bang at the far end.
Sixteen is not a preference: at 18 the title of a selected broken node falls to 6.95:1,
under the program's own 7:1 floor, and `design_test.gd` now checks every combination in
every palette so it cannot drift back. The old treatment washed the whole node in red
with `modulate`, which recoloured its sockets and the cable ends on them — the signal
vocabulary spent on an unrelated fact.

**Hover** is six tenths of a surface step, and it was a third until the proof sheet showed
two specimens nobody could tell apart at 1.08 times the plain header.

**Activity** stays local. The rule the step settled on is that node-level activity is only
worth drawing when the activity has structure beyond "signal exists" — so Gain and
StateVariableFilter get nothing, and the sheet's active row shows a lit socket on an
otherwise ordinary node, which is the finding rather than a gap in it.

**The ADSR stage prototype works and is not switched on.** The whole contour stays drawn
and the live segment is picked out; identity survives, which was the hard requirement.
Left against right reads at header size and the two middle segments do not, so what it
honestly says is "an envelope is running, roughly here" rather than which stage. Nothing
in the editor sets a stage — that would have to come from dsp-core — so the mechanism
exists, is measured, and waits for a data source.

Selection, validity and activity all survive 40%. The bang and the identity glyph do not,
and nothing was added to keep them.

## Step 12 — the optical contract

Most of the machinery was already right. `NodeOptical` names what it does — FULL,
REDUCED, MAP, on the four bands that already produced them, with no new thresholds — and
`optical_sheet.gd` audits it by sweeping every boundary at a hundredth and a
half-hundredth either side rather than photographing four zooms. `docs/node-optical-
states.md` is the record.

Two bugs fixed, one table corrected, one disagreement resolved in the renderer's favour.

**The ellipsis was cutting the wrong name.** Below 0.28 the Amp Envelope fell to
`Amp E…`: the fallback found the type's compact name, decided `Envelope` did not fit
either, and then cut the *canonical* name — discarding the shorter name it had just
rejected in order to cut the longer one. The rule now is canonical, then compact, then
nothing at all, which is this pass's own governing rule applied to its last case. An
ellipsis in the graph now means exactly one thing: that type has not been through the
pass. `design_test.gd` holds the migrated three at zero cuts across thirty-six zooms and
five palettes.

**The identity glyph is not on the band ladder.** It stands down with the title at the
title's own compensation boundary, near 0.90 at XL — inside FULL, above the FULL/REDUCED
line at 0.875 — so the bottom slice of FULL has no mark. The behaviour is right and the
first draft of the survival table was wrong, so the table changed and the code did not.

**REDUCED keeps parameter names and drops their values**, which is the opposite of the
brief's priority and is correct: a name with no number still says what the node has and a
number with no name says nothing. At XL and 0.83 a cell is 94 screen pixels and
"resonance" wants 85 at the legibility floor, so it is one word or none.

**REDUCED is a tenth of a zoom wide at XL and three tenths at Comfortable.** The FULL
floor is computed from base type sizes and so does not move with the interface scale,
while the room floors under it do. Reported and not changed — a corrected FULL floor would
sit below the REDUCED floor at XL and delete the band, and which of the two governs is a
real question rather than an arithmetic slip.

Empty MAP bodies were audited and left alone. The footprint a node keeps at every zoom is
what makes the map correspond to the thing it is a map of.

## Step 13 — how a value is written

`0.700` is a debugger printing a float; `0.7` is an instrument telling you its setting.
`editor-godot/value_text.gd` is the one formatter, and both the graph and the rack call
it — there used to be two identical copies drifting apart. `docs/value-text.md` is the
record.

The old rule keyed the decimals to the value's own magnitude, which is why every value on
a normalised control wore three of them whatever the control was. The new one asks the
parameter descriptor: enough decimals for about five hundred readings across the range,
never fewer than three significant figures, then the trailing zeros come off. A gain of 0
to 4 gets thousandths and a cutoff of 20 to 20000 hertz gets whole hertz, from one rule.

```
gain 0.700 -> 0.7        cutoff 900.0 Hz -> 900 Hz      resonance 0.550 -> 0.55
sweep 0.000 octaves/s -> 0 octaves/s     attack 10.0 ms -> 10 ms
decay 250.0 ms -> 250 ms                 release 300.0 ms -> 300 ms
```

No node changed size — 238x150, 508x248 and 400x101 before and after.

**The parse was broken and this step fixed it.** A field showing `10.0 ms` seeded its
editor with that string, and pressing return without changing a character stored **ten
seconds**: the display converted units and the parse did not, so the one gesture that
should be a no-op moved the value furthest. It predates this step; the old formatting made
it harder to notice.

Where no unit is typed the two conversions want opposite answers — 20 over a millisecond
reading means milliseconds, 440 over a kilohertz reading means hertz — and what separates
them is the parameter's own range rather than a guess. The property the suite holds is a
fixed point rather than equality: what the field shows, parsed and shown again, is the
same string. A display is a rounding and always was.

## Step 14 — First Synth, all seven

The four that were left — Main Oscillator, Filter Sweep, Keyboard and Output — take the
frozen steps 3–13 language. `NodeIdentity.MIGRATED` is seven types now, which is every
node in the patch, and the graph can finally be judged as a composition rather than as
three islands inside the old interface.

**Nothing new was designed.** Two glyphs came straight out of the family grammar, one out
of the seam idea, and the fourth was abandoned after three attempts.

### Widths: all four fitted classes that already existed

```
type                  natural   class      as drawn
SawOscillator           253     Standard      400
seam:Output/stereo      286     Standard      401
LFO                     326     Wide          508
seam:Input/note         350     Wide          508
```

Natural is base scale under the frozen anatomy, drawn is at XL. Three at Narrow/Standard
/Wide already existed and no fifth was needed, which is the first real evidence that three
is enough — a class system whose first four arrivals each want a new class is not one.

The cost is visible and worth naming: the Keyboard's content wants 350 and its class gives
it 376, so it carries the widest empty margin in the patch. That is what a class system
buys a rhythm with. The Output stands one pixel over its class at 401, because the class
is a floor rather than a cap and its content asks for that pixel.

### The saw and the sweep

The pair the step was really about. They come apart without either wearing a
distinguishing decoration, because the family grammar already had the answer: a generator
is drawn as **the waveform it makes**, so a `SawOscillator` is a sawtooth, and a modulator
is drawn as **the shape of a value over time**, so an LFO is one large smooth cycle.
Angular against smooth — a silhouette rather than a detail, which is rule 9.

The Noun Project agrees and was asked for free: every icon filed under `sawtooth` is a
ramp and every one under `modulation` is a sinuous curve. Nothing was downloaded.

### The keyboard that could not be drawn

Three cuts were drawn — a full case with black keys hanging into it, an open pair of rails,
and keys standing on a front rail with no case. All three fill in at header size, and the
reason is structural rather than fixable: a keyboard's identity is *many parallel
elements* and the glyph field is about seven stroke widths across. You cannot draw many
parallel things in seven stroke widths.

So the seams are drawn as what they are — the edge of the patch — rather than as the
equipment on the other side of it. A bar for the boundary and a line for the signal
crossing it, mirrored for direction: `⊢` entering, `⊣` leaving. One drawing, two members,
told apart by a mirror, which is the same rule that gave the highpass and the merge. What
kind of signal crosses is said by the socket's own colour and shape, a channel that
already exists and does not need saying twice.

### One key, asked the same way everywhere

The migration turned up a real bug and it took three edits to finish. A seam is keyed by
the port it stands for — `seam:Input/note` — and the patch document's own `type` field
says only `Input`. `_type_key()` has always existed to reconcile them, and three places
were not using it: the width class, the diagram-control switch, and the parameter row's.

The symptoms were exactly what you would expect from two keys for one thing. The seams
took the new anatomy from `_style_widget` (which uses the key) and missed their width
class (which did not). The Output's safety-limit dropdown came out with a native chevron
and rounded corners next to a Filter Sweep whose dropdown was flat and square, and its
level knob kept the rack's tick ring while every other migrated knob had shed it.

### The gate

Seven nodes, seven wires, every port count and every position identical to the step 1
baseline. Zero elided titles across thirty-three zooms — the whole patch reads as whole
words at 28%, where two of the four used to be cut.

Four suite checks were rewritten rather than deleted. They asserted the old unmigrated
hover mechanism — "a node at rest has no stylebox override" — on `osc`, which is now
migrated and therefore always carries its anatomy. They ask `NodeState` now, which is what
the fact actually is.

### The 401, and what a width class actually is

Neither of the two candidate explanations. The class *was* authoritative — the Output
seam's own combined minimum agreed with its class at every moment — and the node stood at
401 anyway, because a `custom_minimum_size` only ever pushes a Control wider and nothing
pulls one back down. A child asked for one extra pixel while the rows were being built,
the node grew, the child settled, and the pixel stayed. A high-water mark, not a
disagreement.

So the width is now **set as well as floored**, in the same post-layout pass that already
measures node heights for the same reason. And two things are written down in
`node_grid.gd` that were not:

**What the figure measures.** The outer footprint in graph space at base scale — the whole
box a reader sees and a cable lands on, border and content margins included, before
`Design.scale()` multiplies it.

**A class is decided at a type's worst interface scale.** This one the gate found. Chasing
the 401 turned up that the Output seam fits Standard at XL and does not at Comfortable:
the class figure scales linearly and the content does not, because type sizes stop
shrinking at `TYPE_FLOOR`, so at smaller scales the words inside a node are relatively
larger than the box around them. XL — the scale every acceptance in this pass has been
judged at — is the *most forgiving* one, which is worth knowing before fifty types are
assigned by looking at it.

The Output seam is therefore Wide, not Standard. And the other thing that finding says:
**Standard has almost no headroom.** It was derived from one specimen, the ADSR at 294,
and rounded to 296; the very next type to arrive wanted 299. A batch that puts several
types between 296 and 330 is evidence to re-derive the class rather than to keep sending
them all to Wide.

`editor_test.gd` now holds every migrated node at exactly its declared class, and reports
the overflow when one will not fit — which is a design question raised rather than
absorbed.

## Step 14B — the first family batch, and two exceptions

Three types adopted the language and needed nothing new. Three more were held, and the
batch as named could not be run at all. Both of those are reported here rather than worked
around, which is what the batch was for.

### Exception 1 — Highpass, Bandpass and Notch are not node types

They are `mode` values. `StateVariableFilter` has four — lowpass, highpass, bandpass,
notch — and `OnePoleFilter` has two. There is no type to migrate and no type to hang a
glyph on, so the three response curves step 10 drew and proved have nothing to attach to
under the current rule, which keys a glyph to a type.

That also means there is a **live defect**, introduced in step 9 and invisible until now:
a StateVariableFilter set to notch wears a lowpass mark. First Synth's filter happens to
be in lowpass mode, which is why nobody saw it, and a mark that says the wrong thing is
worse than no mark at all.

The fix is a rule the grammar does not currently have — **a glyph keyed by a type and a
mode, for a type that declares one** — and a new rule is a design decision rather than
something a migration gets to make. It is small, it would put the four drawings to work,
and it would make the filter's header say what the filter is actually doing. Not taken
here.

### Exception 2 — the batch asked for a fourth width class

Measured at Comfortable, which the step 14A finding established as the binding scale:

```
Noise                 290     Standard      migrated
Phaser                326     Wide          migrated
NoiseOscillator       354     Wide          migrated
OnePoleFilter         405     -- no class holds it
SquareOscillator      410     -- no class holds it
SineOscillator        413     -- no class holds it
```

Three independent types inside eight units of each other, all just past Wide at 376. That
is a cluster earning a class rather than one node being awkward, and rounded onto the
eight the figure would be **416**. It is not added, and the three types are held out of
`MIGRATED` until the decision is taken.

### What went in

Noise, NoiseOscillator and Phaser, on the mechanical checklist and with no new ideas. All
three stand at exactly their declared class at both interface scales, zero elided titles,
topology and values untouched.

Two things worth noting from them. Both noise sources wear the same mark, because they are
the same operation and the word beside it says which — the same reasoning the browser's
three banks share one. And **the Phaser ships with no glyph at all**: its family, things
that happen over time, has not been drawn, the identity cell is reserved whether or not a
type has a mark, and the title still starts where every other title starts. It is the
first type to ship on "no glyph beats a misleading glyph", and it costs nothing.

### The generator family needed one rule, and it was earned

A sine oscillator and an LFO are both a sine. The grammar had no way to tell them apart
until this batch, and the answer is not a badge: **a generator's waveform repeats and a
control's does not.** Two cycles against one. The shape's own frequency is the silhouette,
which is rule 9, and it is also simply true — an oscillator runs at audio rate and an LFO
does not.

Noise took a second attempt. Drawn as a polyline of unequal heights it is a zigzag, and at
header size a zigzag is the sine's ripple; the two were indistinguishable on the proof
sheet. Drawn as unequal bars standing off a centre line it says the thing that actually
separates noise from every other waveform — that no two excursions are alike and none
follows from the last — and it is unlike anything else in the set at every size.

## Step 14B.1 — identity variants, and a fourth width class

### The header does not hard-code Lowpass

Checked before writing any code, because if it did, fixing only the glyph would have left
a second lie. It does not. The registry already calls the type **Filter**
(`kStateVariableFilter`'s display name), which is option A and was in force all along;
`Lowpass` is the name the First Synth example's author gave that instance, the same way
the oscillator in it is called `Main Oscillator`.

So nothing about the identity needed changing. What did need changing is that the mark
ignored the mode.

### One declared parameter may drive identity

`NodeIdentity.VARIANT`. A type may declare **one** discrete parameter whose values change
the operation it performs, and choose a mark for each:

```
StateVariableFilter   mode   lowpass / highpass / bandpass / notch
OnePoleFilter         mode   lowpass / highpass
```

Everything else stays keyed by type alone. The narrowness is the point — the general rule
"a glyph may depend on a parameter" would let any moving value drive identity, and
identity would stop being identity. Rule 7a in `glyph_grammar.gd`, and `design_test.gd`
checks the mechanism has not spread: every declared type names its parameter, has marks
for more than one mode, draws a different mark for each, and falls back to its type mark
for a mode it has not got.

**The name never varies.** A node keeps what its author called it while the glyph says
which response is running and the dropdown says it in words. A node that renamed itself
when you turned one control would look like it had become a different type, which it has
not. That does mean First Synth's filter, called `Lowpass` by its author, will wear a
notch curve if somebody sets it to notch — which is what every author-given name in the
program does when the thing under it changes, and is theirs to update.

Step 10's four response curves are finally doing something.

### Width.EXTRA, at 416

Added on the evidence rather than in advance: three independent types — OnePoleFilter at
405, SquareOscillator at 410, SineOscillator at 413, all measured at Comfortable — inside
eight units of each other and all just past Wide at 376. Rounded onto the eight, 416.

Named plainly, because the useful thing is the metric and the assignment rather than a
taxonomy. And it establishes how the class set grows from here:

> Classes are discovered from clusters of actual requirement across the corpus, not chosen
> in advance and not stretched to fit one awkward node.

Sending three types to a class 130 units wider than they need, to preserve a set inferred
from three initial specimens, would have been the tail wagging the dog.

No types were migrated into it in this commit. The three that earned it are still held out
of `MIGRATED`, and they are the front of the 14C queue.

### One more rule out of the batch

Rule 9a: **repetition count is silhouette.** How many times a shape repeats inside the
field is part of its outline rather than a detail on it — two cycles of a sine and one
cycle of a sine are told apart instantly and neither is wearing a badge. It should
generalise to the temporal family, where a clock, a pulse train and a delay are the same
idea at different densities.

## Step 14C — the control family

Seven types in, one held, one new gate, and one thing to decide.

### The temporal family

Everything in it is a value over time, which is also what the envelope and the modulation
wave already were. What separates the members is **density and regularity**:

```
repeated smooth cycles     a generator, at audio rate
one broad cycle            a modulator, under it
repeated equal pulses      a clock: regular, discrete, and it only says when
unequal bars               noise: no two alike and none following from the last
a joined staircase         sample and hold: a continuous signal held between samples
separated blocks           a sequencer: a list of discrete values, not a signal
one diagonal               a slide: the whole mark is the transition
one flat line              a constant: the value that does not change
```

Two devices do the work and both are honest. **Regular against irregular** tells a clock
from noise and a sequencer from a sample-and-hold. **Joined against separated** tells a
held signal from a list of values, which is exactly the difference between them.

The clock needed an optical cut. At sixteen hundredths of a reach a pulse is two pixels
wide — the stroke weight — so its two edges and its top filled into a block, and three
blocks on a line read as a square wave. At header size a pulse is one upright standing on
the baseline instead, and the baseline is what keeps it apart from every other rectangular
mark in the set.

### The variant mechanism carried to a second type

`OnePoleFilter` uses the same four-curve filter family as `StateVariableFilter`, with two
of them. Type implementation and filter mode stay separate facts: what a one-pole filter
is, is a filter; which response it is running is the curve on its header.

### Widths: the 416 class was the right rung

Measured at Comfortable, which is the binding scale:

```
Constant          163    Narrow
SampleHold        194    Standard
StepSequencer     354    Wide
Clock             388    Extra
OnePoleFilter     405    Extra
SquareOscillator  410    Extra
SineOscillator    413    Extra
Slide             433    -- held, 17 past the top of the set
```

Four of seven landed in the class the previous batch's evidence created, which is the
first sign it was a real rung rather than an accommodation. **Slide is held**: one type 17
units past Extra is an outlier, not a cluster, and the rule wants several independent
types agreeing before a rung is added. Its glyph is drawn and waiting.

A measurement note that cost an hour: a node built while the graph is already at a reduced
zoom never reaches its full width, because its rows are hidden from the start and the size
high-water mark is the reduced one. The first run of this batch reported a one-pole filter
at 194 when it stands at 405 everywhere a person would see it. **Widths are measured at
zoom 1.0, at full detail, or they are not measured.**

### The gate found nine missing compact names

`editor_test.gd` now sweeps **every migrated type**, not the ones that happen to be in the
example patch — the rollout adds types faster than any one patch can hold them. It uses
the registry's display name and the type's own width class, and it immediately failed on
nine of seventeen.

The batches before this one had assigned compact names by eye, judging at 28% and stopping
there. A compact name is not a judgement about whether the canonical will fit; it is what
a type is called when there is no room, and a type without one falls back to cutting.

It does not have to fit either, which is the part that makes this tractable. A Narrow node
at a quarter zoom has room for about three characters and no real word is three
characters, so a compact name will sometimes not fit and the renderer draws nothing at
all. That is the step 12 rule working — remove information rather than reduce its
legibility — and `Co…` is not an identity.

```
seam:Input/note    Input        SineOscillator     Sine
seam:Output/stereo Output       SquareOscillator   Square
NoiseOscillator    Noise osc    OnePoleFilter      One-pole
SampleHold         S&H          StepSequencer      Steps
Constant           Value
```

### One decision, not taken

`SawOscillator`'s compact name is `Oscillator`, agreed in 14A when it was the only
oscillator in the language. There are three now, and `Oscillator` for the saw one is the
odd entry in a set that otherwise reads `Sine`, `Square`, `Saw`. At map size First Synth
says `Oscillator` where a sine oscillator beside it would say `Sine`.

Changing it is one line and it changes what an approved picture says, so it is reported
rather than done.
