# Cosmopolitan Layout

The record of the layout pass, in the discipline the node and cable passes used: baseline
first, then one problem at a time, each goal changing a single variable and judged against a
rendered comparison before the next begins.

## What is in scope

**Nodes and cables are closed and are not in scope.** `docs/graph-node-system.md` and
`docs/graph-cable-system.md` are authoritative and both were frozen on measured evidence.
Nothing in this pass may reopen either.

This pass is about **where things are**. The dense screenshots made the case: the graph
objects are no longer the difficulty. Long routes, crisscrossing modulation and the large
source-to-output span are arrangement problems, and the cable pass made crossings
*understandable* rather than absent. The best crossing is still one the layout never needed
to create.

The question:

> **Can SoundGraph arrange a patch so its computation is visually obvious before the user
> cleans it up by hand?**

## Step 1 — the baseline

`layout_baseline.gd` measures every patch twice: as its author left it, and as
`_auto_place()` arranges it. `Layout.arrange` already exists, is deterministic, weights
audio edges more heavily than control ones and honours anchors — whether it is *better* than
a hand arrangement is what nobody had measured.

```bash
LAYOUT_BASELINE_OUT=/tmp/p godot --path editor-godot --script layout_baseline.gd
```

### The result

```
                    dense-graph        first-synth      plucked-string    babble
                  hand    auto       hand    auto      hand    auto     hand   auto
nodes               30      30          7       7         5       5       23     23
nodes moved          —      29          —       7         —       4        —      0
cable total      29277   44107       2406    2949      2248    1140    16208  16208
cable longest     2955    4465       1017    1452       464     272     3993   3993
crossings           27      42          0       0         1       1        9      9
backward             4       6          0       0         0       0        2      2
forward            0.89    0.83       1.00    1.00      1.00    1.00     0.92   0.92
overlaps             6       0          0       0         0       0        0      0
trespass             3       0          1       0         0       0        0      0
columns              8      22          5       5         5       5       17     17
area (Mu²)       10.36   13.48       2.35    2.48      1.81    0.80     5.82   5.82
```

### What it says, and it is not what I expected

**Auto-place is not better. On the hostile graph it is substantially worse.** Fifty-one per
cent more cable, fifty-one per cent longer longest route, fifty-six per cent more crossings,
half again as many backward cables, thirty per cent more area, and the eight columns a
reader could see become twenty-two.

What it *does* fix is collisions: six node overlaps and three trespasses both go to zero.

> **The engine optimises collision, not cable cost.** That is the finding, and it reframes
> the project. This is not "there is no arrangement algorithm". It is "the arrangement
> algorithm optimises the wrong objective for a dense patch."

Three supporting results, and they are not all in the same direction:

- **plucked-string**: auto is much better — half the cable, half the area. Five nodes, one
  chain. The engine is good at small patches with an obvious order.
- **first-synth**: roughly neutral. Twenty-three per cent more cable, one trespass removed.
- **babble**: **zero nodes moved.** Twenty-three nodes, and the engine is already at its own
  fixed point. Its positions were produced by the engine, so this says the engine is stable
  rather than that babble is well arranged — and babble carries nine crossings and a
  3993-unit cable at that fixed point.

That last one is the sharpest of the four. A layout engine that cannot improve its own
output is not converging on something good; it is converging.

### A defect in the specimen, recorded

**`qa/dense-graph.json` has six node overlaps in its hand arrangement.** Authored at 520-unit
column spacing with nodes up to 448 wide and some considerably taller than the row pitch, so
several pairs touch.

It never affected the node or cable proofs — those measure node-local and cable-local
properties, and every one of them was taken from a node's own rectangle or a cable's own
route. But it is sloppy, and it is exactly the class of thing this pass is about. Left as it
is for now: changing the specimen mid-pass would invalidate the cable closure matrix, and the
overlaps are a fair thing for a layout baseline to have found.

## What the baseline suggests the pass should be

Not "write an arrangement algorithm" — there is one. The measured shape of the problem is:

1. **An objective function nobody wrote down.** The engine minimises collision. A reader
   minimises cable, crossings and backward flow. Those disagree on the hostile graph by
   fifty per cent, and the first question is which of them the arrangement is *for*.
2. **Column discipline.** Eight legible columns became twenty-two. A patch a reader can see
   the flow of is a patch with few columns and clear membership, and the engine currently
   has no notion that a column is a thing worth having few of.
3. **Preserving intent.** Every one of these numbers is for a total re-arrangement. Nobody
   wants their patch rebuilt; the useful operation is probably local, and the anchors
   mechanism already exists to express it.

## What is deliberately not in this pass

The other three workspace candidates, which the dense screenshots also raised. Recorded here
so they are not lost, and not started:

- **The right inspector/probe panel** takes a large share of the horizontal workspace while
  often showing an empty scope and "point the probe at a wire".
- **The bottom instrument dock** takes a substantial share of the vertical workspace at
  graph-inspection time, when nobody is playing.
- **Canvas navigation furniture** — the view switch, minimap, zoom and tabs — is fine
  individually and nibbles at the graph from every side collectively. The representation
  switch floating over the graph is the known wart.

Each wants the same treatment: baseline before design.
