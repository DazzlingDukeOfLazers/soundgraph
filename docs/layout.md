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

## Goal 2 — the minimally legalized fixture

`editor-godot/legalize.gd` derives `qa/dense-graph-legalized.json` from the hostile patch. A
**legalization witness**, not a layout algorithm: the only objective is zero tier-1 faults,
disturbance breaks ties, and nothing else is improved. No column tidying, no crossing
reduction, no stage correction, no cable shortening, no area tightening.

It clears **all** tier-1 faults, not only the overlaps. Three cable trespasses would have
left the fixture tier-1 invalid, and a comparison against an invalid arrangement stops
before readability — which is the whole reason the fixture exists.

```
hostile patch    6 overlaps, 1 clearance fault, 3 trespasses
legalized        0, 0, 0 — in 9 moves, 9 nodes, 1520 units, 1040 at worst
```

### The table

```
                             hand   minimal legal      auto
overlaps                        6               0         0
trespass                        3               0         0
clearance_faults                1               0         0
stage_violations               24              26       133
crossings                      27              31        42
backward                        4               4         6
stage_spread                    7               7        17
surplus_columns                 0               0         2
fanout_spread               789.4           799.4     825.3
cable_longest              2955.2          2955.2    4465.2
cable_p90                  2145.2          1803.6    3427.2
cable_total               29276.6         30708.1   44107.3
area                       10.361          14.538    13.484
columns                         8               8        13
moved                           0               9        29
displacement_median           0.0            40.0    1329.7
displacement_max              0.0          1040.0    3736.3
displacement_total            0.0          1520.0   50741.8

minimal legal against auto: better, first difference at readability / stage_violations
```

### What it separates

**The unavoidable cost of legality is almost nothing.**

```
stage_violations   24 -> 26     two
crossings          27 -> 31     four
cable_total        +1431        five per cent
columns             8 ->  8     unchanged
stage_spread        7 ->  7     unchanged
cable_longest    2955 -> 2955   unchanged
backward            4 ->  4     unchanged
```

**The cost the current arranger adds beyond it is enormous.**

```
stage_violations   26 -> 133    a hundred and seven more
crossings          31 ->  42    eleven more
stage_spread        7 ->  17    ten more
surplus_columns     0 ->   2
cable_longest    2955 -> 4465   fifty-one per cent longer
cable_total     30708 -> 44107  forty-four per cent more
columns             8 ->  13
```

And the disturbance, which is the sentence the whole goal was written to be able to say:

```
                 nodes moved   median   worst    total
minimal legal              9       40    1040     1520
auto-place                29     1330    3736    50742
```

**Three times the nodes, thirty-three times the distance, and a median move of 1330 units
against 40.** Legality costs nine nudges. Auto-place relocates the patch.

> **Legalization should be local and minimally disruptive. It is not permission to
> regenerate the arrangement.**

That is now a measured claim rather than an intuition, and it is the rule the next goal is
built to satisfy.

### The comparison finally reaches tier 2

`minimal legal against auto: better, first difference at readability / stage_violations`.

Goal 1 could not produce that sentence about anything. Every comparison it made stopped at
legalization. With two legal arrangements of the same patch, the objective contract does the
work it was written for — and it says the arranger is worse, and says which tier it is worse
in.

### Two things worth recording

**The router avoids obstacles, and that broke the first search.** Evaluating a trial against
a straight line between two ports reported twenty-six trespasses where the drawing has
three, because `_route` routes around node bodies and `_get_connection_line` at zoom one
does not tell you what was drawn. Reimplementing the router to make the search cheap would
have been a second implementation of the thing being measured, so a trial is applied, drawn
and asked instead — slower, and the only version that is about the program.

**One node is an outlier and it is the whole of the area regression.** Eight of the nine
moves are 40 to 120 units. The ninth is `plug`, wedged between two tall neighbours, which no
move of up to six hundred units in four directions could free: it took a plateau step and a
much longer reach, and it moved 1040 units. That single move is why the legalized fixture is
*larger* than auto-place — area 14.5 against 13.5 — while beating it on everything above
tier 4.

A local repair that has to move one node a thousand units is a signal about the authored
arrangement, not about the repair. It is what the hostile patch's tallest nodes at 520-unit
spacing were always going to cost.

### A note on the fixture's diff

Twenty-four of the thirty nodes differ from `dense-graph.json`, and only nine of those are
moves. The other fifteen are the editor snapping the authored positions to its own 40-unit
grid on load — the hostile patch was written by hand at 520-unit spacing and not every
figure in it was a multiple of forty. The fixture records what the editor actually shows.

## Goal 3 — the local legalizer

A product operation, not a harness: **Arrange → Resolve overlaps**. One undo step, one
sentence of feedback, and it answers exactly one question.

> **Legalization repairs invalid geometry and preserves intent. It is not permission to
> regenerate the arrangement.**

`LayoutLegalize` holds the search rules; `main._legalize_layout()` is the operation.

### What it may change

Tier 1 and nothing else: node overlaps, clearance faults, cable trespasses. It does not
optimise crossings, stage order, cable length, columns, area or anything else — a legalizer
that improved them would be Auto-place wearing a smaller name.

**Local by construction rather than by hope.** Only nodes in a fault may move. A trespass
implicates the node being crossed; the endpoints of the offending cable are admitted only
when moving the crossed node cannot clear it. Nothing else is ever unlocked, so "local" is a
property of the candidate set and not an outcome somebody hopes stayed small enough.

### Escalating rings

```
A  near    1, 2, 3 grid steps        a nudge
B  local   4, 6, 8, 11, 15           a search
C  escape  20, 26, 33, 42, 54, 70    a trapped node, and reported as one
```

The candidate set widens only when the narrower one has no answer, and a phase C move is
attributed rather than absorbed: "moved 9 nodes, 1 of them trapped" is a different sentence
from "moved 9 nodes".

### The scoring, and the one guard

```
1  tier-1 faults remaining
2  gratuitous new crossings      the guard
3  nodes moved
4  total displacement
5  worst displacement
```

Readability is reported, not pursued — with one exception. If two candidates both clear the
same fault and one adds a dozen crossings, taking the other costs nothing and needs no global
objective to justify it. So the guard is a **step**, not a count: adding one crossing and
adding none score the same, and only a gratuitous addition is separated out. That is
deliberately not a crossing minimiser.

### Apply, redraw, re-measure

```
candidate move → apply to the real graph → let the real router rebuild → measure → keep or revert
```

Slow, and correct. Goal 2 established why: the router avoids obstacles, so a trial judged
against a straight port-to-port line reported twenty-six trespasses where the drawing had
three. A cheap duplicate router would be a second implementation of the thing being measured,
and this repository has spent five instruments learning what that costs.

### Anchors

`_layout_anchored()` is the tier-0 seam and today always returns false, because the product
has no pin. It exists now rather than later so that the loops already refuse to move what it
names and the operation already reports the case it cannot repair without one. Adding the
constraint afterwards would mean finding every loop that had assumed it away.

### The acceptance test

`legalize_test.gd`, and it runs **headless** — the router is pure geometry against the
obstacle list, so a fault is measurable without a rendering server. It is in `pre-push.sh`
with the other four suites.

```
the hostile patch starts invalid (10 faults)
and is repaired to zero faults
moving 9 nodes against the witness's 9
and 1600 units in total against the witness's 1520
which is less than auto-place's 29 nodes and 50742 units
running it again moves nothing
and still moves nothing after a reload
dense-graph-legalized is legal, so nothing moves
plucked-string is legal, so nothing moves
babble is legal, so nothing moves
first-synth's 1 fault is repaired
by moving 1 of its seven nodes, not rearranging them
```

**babble is the defining case.** It carries 73 stage violations, 9 crossings and a 3993-unit
cable, and it is legal — so the legalizer must not touch it. An operation that improved it
would have decided that "this could read better" is permission to move something, which is
the exact confusion this feature exists to end.

**Idempotence is the cleanest guarantee it can offer**, and it holds across a save and a
reload as well as a second press.

**And the hostile patch costs nine nudges and 1600 units**, against the witness's nine and
1520 and auto-place's twenty-nine and fifty thousand. The product operation lands where the
evidence said it could.

### What this changes about the product

There is now a menu item for each of two different intentions, where there was one:

```
Resolve overlaps        make the drawing valid; leave my arrangement alone
Auto-place everything   I am explicitly permitting structural change
```

The third — *tidy this area* — is goal 4's, and it is the one that will need the stage
structure goal 1 defined.


## Goal 4 — stage and flow tidy

**Arrange → Tidy flow.** The third intention, and the boundary is the point of having three:

```
Resolve overlaps    owns tier 1
Tidy flow           owns a restricted part of tier 2
Auto-place          keeps permission to regenerate structure
```

It optimises four topology-derived properties as an ordered vector — stage violations,
backward edges, stage spread, surplus columns — and **watches** crossings and cable without
optimising them.

### The two rules that shape it

> **Stage tidy owns X strongly and Y reluctantly.**

Horizontal position is what topology has an opinion about. Vertical position encodes things
topology cannot know: oscillators grouped, modulation under audio, voices stacked. A node
moves toward its stage band in X, keeps its Y, and is nudged vertically only to stay legal.
Vertical *order* is never reshuffled.

> **A component moves as one.**

Stages come from the condensation, so a strongly connected component is one stage unit.
Forcing an internal left-to-right order onto a feedback loop is correcting it into nonsense.

Depth always comes from the **whole** topology, even when only a selection may move — a
selection's induced subgraph would report three middle nodes as sources and destroy their
relationship to the rest of the patch.

### The result

```
                        dense-graph-legalized        babble
stage violations               26 -> 16            73 -> 71
backward                        4 -> 4              2 -> 2
stage spread                    7 -> 7             11 -> 11
surplus columns                 0 -> 0              4 -> 3
crossings                      31 -> 31             9 -> 9
cable total                 30708 -> 30708      16208 -> 16677
longest cable                2955 -> 2955       3993 -> 3993
nodes moved                     6 of 30             1 of 23
total displacement              1129                 320
median displacement              200                 320
yield          1.7 violations per node, 8.9 per 1000 units
```

**dense-graph-legalized is the good case**: ten stage violations removed for six small
moves, a median of two hundred units, and not one crossing, cable unit or vertical position
bought to do it. Auto-place moved twenty-nine nodes a median of 1330 to make that number
*worse*.

### babble is the honest one

**73 → 71.** Not material, and it is the evidence rather than a failure to hide.

The first implementation had the escape hatch the brief allowed — refuse a crossing-adding
move *unless no non-worsening move exists* — and on babble every stage improvement costs
crossings, so the hatch was taken every time. The result was **73 → 56 at the cost of seven
crossings, ten thousand units of cable and a median move of 2720 units**: the auto-place
pathology in miniature, produced by the operation built to avoid it.

So the hatch is gone. If no move improves the stage vector without adding a crossing, move
nothing.

> **Tidy is allowed to say the author already did better than it can prove.**

Which leaves a real finding for the next goal: **babble's disorder is not reachable by
horizontal moves alone.** Its 73 violations live in vertical arrangement and in routing, and
a stage tidy that respects Y and refuses crossings can only find one node worth moving. That
is goal 5's territory, and it is now measured rather than assumed.

### Also learned, twice

A **first-improvement search is order-dependent**, so the traversal is in document order
rather than in widget-creation order. A widget is named by the order it was built, and the
same patch reopened offered a different first improvement and found four more moves at what
had been a fixed point.

And a **reload has to reopen the way the editor opens**. Without restoring zoom and the
detail band, the graph comes back with its nodes a different height, their centres somewhere
else, and three more moves apparently available — the operation looked like it was not
converging when what had changed was the size of everything it was measuring. Sixth
instrument in this programme to be wrong in that family.

### Gated

`tidy_test.gd`, headless, in `pre-push.sh`. Legal before and after, violations never worse,
crossings never worse, at most half the nodes moved, a fixed point on the second press and
across a reopen, one selected node moves nothing else, and plucked-string moves nothing at
all.


## Goal 5A — the crossing-cost frontier

A harness, not an operation. Goal 4 ended with a hypothesis and a warning: babble's remaining
disorder might live in Y, and a lexicographic search given permission to trade will spend
freely in whichever direction it is pointed. So the question is not whether crossings can be
reduced.

> **What does removing a crossing cost in authored arrangement, cable and space?**

Held fixed: tier 0, tier 1 legality, the goal 4 stage vector — goal 5 may not buy a crossing
by undoing goal 4 — X, and **the router**. Moving a node and letting the existing router
respond is layout; changing where the same two endpoints route is a different project that
would alter every cable in every existing patch.

### A new cost metric

**Vertical order inversions.** Displacement alone is the wrong cost: moving a node five
hundred units through empty space can leave every relationship intact, while swapping two
neighbours by a hundred changes which is above the other — and vertical order is where a
patch keeps what its topology cannot say. Counted as pairs whose relative order a move
reversed.

### babble — placement has run out

```
9 crossings, 73 stage violations, 16088 cable, 3993 longest

13 single-node moves remove a crossing; 3 on the frontier
 0 adjacent vertical swaps remove one

node   -cross   moved   cable   longest   area   inversions
n15         1      40     -14         0   0.00            6
n10         1      80     -48        32   0.34            5
n8          1      80    -204         0   0.00            6
```

**Not one move removes two.** The whole graph offers thirteen single-crossing improvements
and no two-node swap helps at all. And each of the three cheapest costs five or six
inversions — it reorders neighbours.

So goal 4's hypothesis is answered, and answered against itself:

> **On babble no single vertical move is worth making.** Not horizontally, which goal 4
> established, and not by any one vertical move either: nine crossings, best case eight, paid
> for by rearranging the author's vertical grouping.

**This was overstated when first written, and goal 5B corrected it.** The claim was that
placement had run out on babble entirely. A *sequence* of cheap moves takes it from nine
crossings to seven for eighty units and one inversion — a frontier of single moves cannot see
that, because the second move only exists once the first has been made. See goal 5B.

That is the most useful thing this harness could have found. For a patch like babble the next
thing to investigate is **the router**, not the layout engine.

### dense-graph-legalized — a healthy frontier with a knee

```
31 crossings, 26 stage violations, 30708 cable, 2955 longest
58 single-node moves remove a crossing; 14 on the frontier

node   -cross   moved   cable   longest   area   inversions
n17         8    3640    4056       980   1.78           28
n17         6    2320      96        12   0.00           27
n24         6    2320     284      -232   2.09           27
n17         5    2200    -264        12   0.00           27
n2          4    1280    -800         0   0.96           13
n24         3    1600     -45      -144   0.00           23
n18         2    1120    1607         0   1.61            9
n24         1      40     385       -40   0.00            2
n26         1      40      41         0   0.00            0
n3          1      40     -40         0   0.00            1
n24         1     120     149      -120   0.00            3
n24         1     160      37      -148   0.00            4
n18         1     240    -299         0   0.00            4
n27         1     360    -135         0   0.00            1
```

**The curve has a knee and it is sharp.** At the bottom: several forty-unit moves, each worth
one crossing, at zero or one inversion and near-zero cable — n26 removes a crossing for forty
units, forty-one units of cable and **no vertical reordering at all**. Then a cliff: the
four-and-above candidates cost one to four *thousand* units and thirteen to twenty-eight
inversions.

n17 at minus eight for 3640 units, 4056 more cable and 28 inversions is the auto-place
pathology arrived at from the other direction. It is exactly what would sit at the top of any
search that ranked crossings first.

### What this settles, and what it does not

**No budget is chosen here**, on purpose — "a crossing is worth five hundred units" is the
weighted score in another costume. But the frontier describes the cheap end without anybody
inventing a figure: the knee is where inversions leave zero.

```
0-1 inversions, a grid step or two       ordinary
13-28 inversions, thousands of units     a different operation
```

**Tidy routes is coherent as a product operation** for a patch with a knee, restricted to the
bottom of it. It is **not** the answer for a patch like babble, where placement offers
nine-to-eight at the price of the author's vertical grouping.

Which forks the next step rather than continuing it:

1. **Goal 5B — Tidy routes**, restricted to the knee: single-node vertical moves at zero or
   one inversion and a bounded displacement, refusing anything the frontier shows on the
   cliff. Provable on dense-graph-legalized, and it will correctly do almost nothing on
   babble.
2. **The router**, as its own project with its own baseline, for the crossings placement
   cannot reach — which on babble is all of them.



## Goal 5B — Tidy routes

**Arrange → Tidy routes.** The fourth operation, and deliberately the smallest.

> **Tidy routes may take only cheap local placement wins. If removing a crossing requires
> reorganising the patch, it declines.**

### The knee as a feasibility boundary, not a score

There is no exchange rate here and no budget in units. A candidate is eligible or it is not:

```
tier 0 unchanged
tier 1 legal
the goal 4 stage vector does not worsen
exactly one node moves
vertically only
inside the legalizer's own nudge ring, not its search or escape radii
at most one vertical order inversion
crossings strictly decrease
```

Among eligible candidates: most crossings removed, then fewest inversions, then least
displacement, then least cable growth, then least growth in the longest route.

The frontier's eight-crossing candidate — 3640 units, 4056 more cable, twenty-eight
reorderings — never enters the competition. It is not a worse candidate; it is not a Tidy
routes candidate at all.

**The ring is the boundary rather than a distance**, because that is what the evidence
established: cheap wins live in the local nudge neighbourhood and the expensive ones require
leaving it. Naming a cutoff in units would be inventing a figure the frontier never produced.

### The results, and a correction

```
                        crossings   nodes   units   inversions   sideways
dense-graph-legalized      31 -> 27      4     200            2          0
babble                      9 ->  7      2      80            1          0
plucked-string                    —      0       0            0          0
first-synth                       —      0       0            0          0
```

**babble corrected goal 5A, and the correction matters.**

5A concluded that placement had run out on babble: thirteen single-node moves each removing
one crossing at five or six inversions, and no adjacent swap helping at all. This test was
written expecting the operation to move nothing.

It takes babble from **nine crossings to seven, for two forty-unit nudges and one
inversion** — better than any candidate the frontier printed, and comfortably inside the
knee.

> **A Pareto frontier of single moves understates what a sequence of cheap moves can reach.**

The frontier measured single moves from the resting arrangement. The operation is iterative:
it takes one cheap move, the drawing changes, and a second cheap move exists that did not
before. That is a property of the instrument, not of babble — the seventh time in this
programme that a measurement has stood for the thing rather than being it, and the first
time the error was in the *optimistic* direction.

So the earlier claim is withdrawn. Placement has not run out on babble; it has run out of
*single* moves worth making. What remains after 9 → 7 is still not reachable, and that part
of the finding stands.

### What is gated

`routes_test.gd`, headless, in `pre-push.sh`. The gates are about the knee rather than about
a fixture doing nothing:

```
a cheap crossing removal is found
the graph is still legal
the stage vector did not regress
nothing moved sideways
inversions within one per move
a second press moves nothing
and so does a press after a reload
a patch with no cheap win left is untouched
one selected node moves nothing else
```

## Cosmopolitan Layout, complete

Four operations, four intentions, where there was one button:

```
Resolve overlaps        make this valid
Tidy flow               improve topology-to-X alignment, creating no crossings
Tidy routes             take only cheap topology-to-Y crossing wins
Auto-place everything   you may reconstruct this layout
```

Each was measured before it was built, and two of them exist only because the measurement
contradicted the plan: the objective contract found that comparisons of differently-legal
arrangements never reach readability at all, and the legalization witness found that legality
costs nine nudges where auto-place spends twenty-nine relocations.

### Where the router stands now

babble remains the hostile fixture for whatever comes next, and its provenance is unusually
strong:

```
the legalizer            correctly does nothing
flow tidy                finds one node
the crossing frontier    offers one move at five or six reorderings
adjacent swaps           offer nothing
tidy routes              takes it from 9 crossings to 7, and then declines
```

Seven crossings and a 3993-unit route remain, and every placement operation this pass built
has now been asked and has answered. **When the router is investigated, it will not be being
asked to compensate for a layout problem** — and that is a thing worth knowing before opening
`_route`, because it is the difference between fixing a router and papering over an
arrangement.
