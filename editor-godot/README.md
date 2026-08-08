# editor-godot

The primary editor, and deliberately not the authority on anything.

Every question this UI needs answered — what node types exist, what ports they have,
whether a connection is legal, what is wrong with a graph, what a wire is carrying — is
asked of the `SoundGraphEngine` extension, which wraps the same `dsp-core` as the browser
and the command line tools. There is no DSP in GDScript and no second copy of the node
vocabulary, because a second copy is a second set of answers that will eventually
disagree with the first.

Concretely, that means adding a node type to `dsp-core` makes it appear in this editor —
with its ports, units, ranges, enum labels, tooltips and search terms — without a line of
GDScript changing.

## Build and run

The extension binary and the example patches are build output, not repository content.
Build them first:

```bash
cmake -S runtime-godot -B runtime-godot/build -DCMAKE_BUILD_TYPE=Release
cmake --build runtime-godot/build
```

That writes `editor-godot/bin/` and `editor-godot/examples/`. Then open `editor-godot/`
in Godot 4.7.

The first configure clones and builds `godot-cpp`, which takes a while and produces around
two thousand binding files. Afterwards it is incremental.

## Using it

| | |
|---|---|
| Add a node | **Ctrl+Space**, or right-click the canvas, or the toolbar button — every result has its own **Add** button, and the dialog stays open so you can add several |
| Undo / redo | **Ctrl+Z** / **Ctrl+Shift+Z** (or Ctrl+Y), and the toolbar buttons, which name what they will undo |
| Tidy the graph | **Auto-place** lays it out left to right on the 40 grid |
| Move a cable | drag it; right-click puts it back |
| Play | **A W S E D F T G Y H U J K**, with **Z** / **X** to shift octave |
| Inspect a signal | select a node — the scope shows what its first output is carrying |
| Fix a problem | the panel names the nodes involved and highlights them in the graph |

## The grid

The canvas draws its own three-tier grid, and each tier **is** one of the layout's
pitches:

| line | spacing | means |
|---|---|---|
| faint | 40 | the snap step — where a dragged node lands |
| medium | 200 | a **row** — the vertical pitch auto-place uses |
| heavy | 400 | a **column** — the horizontal pitch auto-place uses |

GraphEdit's own grid draws minor lines at the snap distance and major lines at some
multiple of it, which leaves you counting minor lines to find the one you meant to align
to. Here there is nothing to count: the heavy line *is* the column and the medium line
*is* the row, so "line it up with a major line" and "put it where the layout would" are
the same instruction. GraphEdit's grid is switched off so only one grid is drawn.

Loading a patch snaps every node — and every cable waypoint — onto the 40 grid. A file
written by another editor, or by hand, otherwise lands on arbitrary pixels and every
alignment cue on the canvas is off by a few, which reads as the grid being broken rather
than the file.

## Layout

Everything snaps to a **40 pixel grid**, so hand-placed and auto-placed nodes share a
pitch instead of drifting a few pixels apart.

**Auto-place** (`layout.gd`) is the Sugiyama framework for layered graph drawing. Placing
nodes by depth alone — which is all the first version did — gets the columns right and
nothing else: it says nothing about which node sits above which, so cables cross for no
reason, and it stacks each column from the top, so a chain that should read as a straight
line zig-zags. The four phases:

1. **Cycle removal.** A feedback loop is temporarily reversed so the rest can assume a
   DAG. SoundGraph only permits cycles through a `Delay` anyway, so this draws a loop the
   way a person would: forward along the signal, back underneath.
2. **Layer assignment.** Longest path, then sources pulled right to sit beside whatever
   they drive — which is why an LFO lands next to its filter instead of stranded at the
   far left.
3. **Crossing reduction.** The median heuristic swept in both directions, then
   adjacent-swap transposition, keeping the ordering whose crossings were *actually
   measured* to be lowest rather than assumed.
4. **Coordinate assignment.** Each node is pulled toward the median of its neighbours,
   resolved against the no-overlap constraints by isotonic regression — which gives the
   closest legal placement rather than an approximation of it.

Edges spanning more than one column get **dummy nodes** in the layers they cross. Without
them a long cable is invisible to both the crossing count and the spacing, so it happily
cuts across whatever is in the way. Dummy chains are weighted heavily in phase 4, which is
what keeps a long cable straight instead of bowed.

**Cables are weighted by what they carry.** An audio cable pulls its ends into line far
harder than a control cable does, so the signal chain comes out as one straight spine with
the modulation sources arranged beneath it — the shape a person draws by hand. A weighted
median is still a compromise, though, and a spine node sitting above two modulators gets
tugged down by both; so after the sweeps, the strongest chains are put on a single row
outright and the rest of each column gives way around them.

**Rows land on the major grid lines** (multiples of 200), not on every grid line.
Vertical separation is a whole number of those steps, so a stack reads as a stack instead
of landing on whatever arithmetic the node heights happened to produce.

Column and row pitch come from real widget sizes, so a column of wide nodes pushes the
next one out instead of overlapping it.

**With nodes selected**, only those are arranged; everything else becomes a fixed anchor
that still pulls on the result, and the arrangement is translated back to where the
selection already sat. Tidying one corner does not move it across the canvas or fight the
part you already arranged by hand.

References: Sugiyama, Tagawa & Toda (1981); Gansner, Koutsofios, North & Vo, *A Technique
for Drawing Directed Graphs* (1993) for median + transpose; Brandes & Köpf, *Fast and
Simple Horizontal Coordinate Assignment* (2002).

`layout_test.gd` checks it against graphs with an obvious right answer — parallel chains,
a fully reversed bipartite graph, a chain that must come out perfectly straight — by
measuring crossings on the final coordinates rather than comparing to a recorded layout.

## Cables

A curved cable that passes straight through a node is unreadable — you cannot tell where
it goes. So a cable stays a smooth curve while its path is clear and switches to a routed
orthogonal trace with 45-degree corners when it would cross something, which is why PCB
traces look the way they do.

A graph dense enough will always have some crossings left. Where two cables do cross, the
lower one **darkens as it approaches, cuts out beneath the junction, and fades back** —
so it reads as one cable passing under another rather than as two cables that happen to
end near each other. The upper cable is then laid back over the shadow so it stays
unbroken.
That is drawn on a Control inserted directly after GraphEdit's own connection layer —
above the cables, below the nodes — and recomputed only when the view actually changes,
since rerouting every cable on every frame is enough work to hold a core down by itself.

When the router's choice still is not what you want, **drag the cable**. That drops a
waypoint it must pass through, snapped to the same grid; right-clicking the cable removes
it. Waypoints are saved in the patch next to the node positions, so a layout you arranged
by hand comes back the way you left it.

## Undo

Undo works on whole-document snapshots rather than a hand-written inverse per operation.
A patch is a few kilobytes, and the code that turns a document into a view is the same
path used for loading — so "undo an edit" reduces to "load the previous document", which
cannot drift out of step with the edits the way per-operation inverses eventually do.

Two details matter in use:

**A drag is one step.** Node moves bracket on `begin_node_move`/`end_node_move`, knob
turns on the slider's `drag_started`/`drag_ended`, and cable drags on their own signal.
Without that, one sweep of a filter knob would bury the history under hundreds of entries.
A drag that ends where it started records nothing.

**Undoing a knob turn does not restart the sound.** If two snapshots differ only in
parameter values, the values are pushed straight to the running engine and the knobs move
to match — no rebuild, so oscillators keep their phase and delay lines keep their
contents. Rebuilding on every undo would make the feature unusable while playing, which is
the same reason knob movement never reloads the patch in the first place.

Opening a file starts a new history: undoing across a load would restore another patch's
nodes into this one.

## Saving

Saved patches go through the core's own serialiser, not Godot's. Godot's `JSON.stringify`
sorts keys alphabetically and renders every number as a float, so a saved patch would come
back with `"schema_version": 1.0` and its fields shuffled. The patch format is the
product; it should not degrade depending on which editor wrote it.

Search accepts intent, not just names: *remove high frequencies*, *make quieter*, *echo*,
*midi keyboard*. The ranking comes from the core, so it matches the web editor and
`sg-validate --list-nodes`.

## Round trip

Milestone C's exit condition is that a patch edited here opens in the browser and vice
versa without changing meaning. That is checked by rendering, not by comparing text:

```bash
node tools/verify-roundtrip.mjs
```

It pushes each example through this editor's real load-and-save path — building the graph
view, generating the parameter widgets, reading it all back — then renders the original
and the result with `sg-render` and requires the audio to be **identical**, sample for
sample. Two patch files can differ in key order, number formatting and whitespace while
describing the same graph, and can look similar while describing different ones; only the
audio settles it.

## Notes for whoever edits this next

**Moving a knob must not reload the patch.** Parameter changes go straight to the running
engine and are recorded in the document. Rebuilding the graph would interrupt the sound,
which is exactly what "patching should feel immediate" rules out. Only structural edits —
adding, deleting, connecting, disconnecting — trigger a reload.

**Patch ids and Godot node names are not the same namespace.** Patch ids may contain
characters Godot rejects in a node name, so the mapping is kept explicitly in `ids` rather
than assuming the two agree.

**Rebuilding the view removes nodes before freeing them.** A queued node keeps its name
until the end of the frame, and a new node claiming that name gets silently renamed —
which corrupts the id mapping in a way that is very annoying to track down.
