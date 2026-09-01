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


## Goal 1 — the arrangement objective contract

No placement changed. What changed is that the thing an arrangement is *for* is now written
down and measured.

> **Arrangement has two jobs: legalize the drawing, then improve its readability. Those are
> not the same optimisation.**

The hand arrangement of the hostile graph is the evidence for that sentence. It is
substantially better on every readability and route figure, and it is **invalid in six
places**. Auto-place legalizes it and destroys much of the structure on the way past.

### Lexicographic, not weighted

`LayoutObjective` in `editor-godot/layout_objective.gd`. Deliberately not a single weighted
score: a weighted sum has to claim that one crossing is worth three hundred and seventeen
pixels of cable, and nobody believes any such number — it is a way of writing down that the
question was not answered.

```
0  invariants      topology_changed, anchors_moved
1  legalization    overlaps, trespass, clearance_faults
2  readability     stage_violations, crossings, backward, stage_spread,
                   surplus_columns, fanout_spread
3  route           cable_longest, cable_p90, cable_total
4  spatial         area, aspect, whitespace
5  disturbance     moved, displacement_max, displacement_median, displacement_total
```

Compared in order. The first tier that differs decides, and within a tier the first metric
that differs decides. Which gives the rule a future arranger is held to:

> **Arrangement is monotonic against this contract. Never accept a move that improves a
> lower tier by worsening a higher one.**

`admissible()` is that rule as a function, so that when an algorithm finally exists the
thing it must not do is already spelt.

### Stages come from the topology, not from the grid

"Twenty-two columns" needed a meaning before it could be a target. So:

1. collapse strongly connected components, so feedback loops are one unit — a delay feeding
   its own input is not later than itself;
2. take depth on the condensation as the **longest** path from a source, because a node's
   stage is set by the deepest thing that reaches it;
3. cluster horizontal centres into **bands** by the gaps between them, at half the median
   node width, so the same rule reads a patch of narrow nodes and a patch of wide ones.

Which turns three vague complaints into three measurements:

```
stage_violations   pairs where a later stage stands left of an earlier one
stage_spread       bands one logical stage is scattered across, summed
surplus_columns    bands the drawing spends beyond what the graph's depth requires
```

And `backward` now has a real definition rather than "the arrow points left".

### Displacement, which the first baseline was missing

"29 moved" and "29 moved" are the same sentence about very different events.

```
moved                 how many
displacement_total    summed Euclidean
displacement_median   the typical one
displacement_max      the worst one
```

### The re-scored fixtures

```
                        dense-graph    first-synth   plucked-string      babble
                        hand   auto    hand  auto     hand   auto     hand   auto
overlaps                   6      0       0     0        0      0        0      0
trespass                   3      0       1     0        0      0        0      0
stage_violations          24    133       2     2        0      0       73     73
crossings                 27     42       0     0        1      1        9      9
backward                   4      6       0     0        0      0        2      2
stage_spread               7     17       1     1        0      0       11     11
surplus_columns            0      2       0     0        0      0        4      4
cable_longest           2955   4465    1017  1452      464    272     3993   3993
cable_p90               2145   3427     411   497      439    266     1985   1985
area (Mu²)             10.36  13.48    2.35  2.48     1.81   0.80     5.82   5.82
moved                      —     29       —     7        —      4        —      0
displacement_median        —   1330       —    80        —    412        —      0
displacement_max           —   3736       —   200        —    440        —      0

verdict                 auto better   auto better   auto better   indistinguishable
first difference at     legalization  legalization  route         identical
                        / overlaps    / trespass    / cable_longest
```

### What the contract says that the raw numbers did not

**Three of the four comparisons never reach tier 2.** The verdict is settled at legalization
and the readability figures are never consulted — which is correct behaviour for a
lexicographic order and is also the most useful thing this goal found:

> **You cannot learn anything about readability by comparing arrangements of different
> legality.** The comparison stops before it gets there.

So the derived fixture is not a nice-to-have. It is required for the next measurement to
mean anything at all.

**And auto-place is "better" on the hostile graph while destroying its readability.**
Stage violations go from 24 to 133 — five and a half times — crossings up 56%, stage spread
from 7 to 17, and it relocates twenty-nine nodes a median of 1330 units with a worst case of
3736. The tier order permits every bit of that, because tier 1 dominates and six overlaps
are a tier 1 fault.

That is the gap the contract exposes, and it is sharper than "the engine optimises the wrong
thing":

> **Nothing bounds the price of legalization.** A legal drawing beats an illegal one, always
> and correctly. What no rule currently says is that legalizing six overlaps may not cost a
> hundred and nine stage violations.

Which is exactly what `admissible()` would forbid if arrangement were a sequence of moves
rather than a wholesale replacement. The engine does not make moves; it produces an
arrangement. A future one should make moves.

**babble is promoted to an acceptance fixture.** Every one of the twenty-four metrics is
identical, hand and auto: the engine is at its own fixed point, and that fixed point carries
73 stage violations, 9 crossings, 4 surplus columns and a 3993-unit cable.

> **An arrangement fixed point is not evidence of quality.** A new arranger must be able to
> answer "I can improve this legal layout without making a higher-priority objective worse",
> and if it cannot, it should move nothing.

**One number worth keeping for its own sake:** the hostile graph's *hand* arrangement has 24
stage violations across 30 nodes; babble's *engine* arrangement has 73 across 23. A person
laying out a patch they were deliberately making unpleasant still ordered it three times
better than the engine orders one of its own.

## What the pass looks like from here

Not "write an arrangement algorithm" — there is one. The measured shape:

1. **A derived fixture.** `dense-graph-legalized.json`: the hostile graph with only the
   minimum moves needed to remove its six overlaps, so legalization can be separated from
   optimisation. Then four arrangements can be compared where three of them are equally
   legal and the comparison reaches tier 2.
2. **Bounded legalization.** Some rule that says what legalizing may cost.
3. **A three-stage arranger**, if the fixtures support it: legalize locally, establish the
   stage structure, then reduce crossings and cable without destroying intent — rather than
   one monolithic pass.

The hostile specimen stays exactly as it is. It is now a historical baseline for nodes,
cables and layout, and its six overlaps are part of the evidence rather than a defect to be
tidied away.
