# Cosmopolitan Routing

The record of the routing pass. Baseline first, then one problem at a time, in the discipline
the node, cable and layout passes used.

## The boundary, written down first

> **Routing is judged with node positions, port positions, cable endpoints, node geometry and
> the frozen cable visual grammar all held fixed.**

That is what stops the router "winning" by quietly borrowing from layout. `docs/layout.md`
and `docs/graph-cable-system.md` are both closed, and nothing in this pass may reopen either.

## The specimens

Derived by `tidy_fixtures.gd`, not edited in place:

```
qa/babble-tidied.json         babble after the whole layout pass, 9 crossings -> 7
qa/dense-graph-tidied.json    the legalized hostile patch after flow and route tidy, 31 -> 26
```

Their provenance is what makes them worth having. On babble the legalizer correctly moves
nothing, flow tidy finds one node, the crossing frontier offers one move at five or six
reorderings, adjacent swaps offer nothing, and route tidy takes it from nine crossings to
seven and then declines. **What remains is what placement cannot reach.**

### The operations are not commutative, and it costs a crossing

Found while deriving the fixtures. Route tidy on its own takes babble from nine crossings to
seven; run after flow tidy it can do nothing at all, because flow moves a node without
changing any crossing and that move removes the two forty-unit route wins that had been
available.

```
flow first, to a fixed point      8 crossings
routes first, to a fixed point    7 crossings
```

So the fixture is derived by running both orders to their own fixed points and keeping the
better — the claim it exists to support is that the router is not compensating for a layout
problem, and that claim needs the best placement can reach rather than the best one ordering
happens to reach.

Recorded rather than fixed. Layout is frozen, and an operation ordering is a product question
rather than a routing one.

## Goal 1 — the baseline

> **With layout frozen, what exactly is the current router spending distance, bends,
> backtracking and crossings on?**

Every figure comes from `graph._routes()`, the same points the cord layer draws. No
straight-line proxy, no second router, no inferred obstacles — seven instruments in this
programme have been wrong by standing for the thing they measured instead of being it.

```
                       first-synth  plucked-string  dense-tidied  babble-tidied
cables                           7               6            35             26
crossings, routed                0               1            44             10
crossings, as drawn              0               1            26              7
cable total                   2406            2248         30648          16289
longest                       1017             464          2955           4025
stretch, median               1.02            1.04          1.04           1.05
stretch, worst                1.23            1.06          1.66           1.47
excess, median                   6              18            19              7
excess, worst                   56              22           822            713
bends                            6               0           110             82
axis reversals                  14               0            52             49
tightest clearance               0             474            18             30
trespass                         1               0             0              0
busiest cable                    —      1 of 1        11 of 44        4 of 10
determinism                    0/7             0/6          0/35           0/26
stability, worst              9.3x            1.0x         21.3x          11.5x
stability, mean               1.1x            1.0x          1.4x           1.4x
reroutes of cables that
did not move                     1               0            47             51
```

### What it says

**Determinism is perfect.** Not one route of seventy-four differs between two reads of the
same document. Whatever else is true, the router is a function of its inputs.

**Individual routes are economical.** Median stretch is 1.02 to 1.05 everywhere: a typical
cable is within five per cent of the straight line between its ends. The cost is entirely in
a tail — worst stretch 1.66 and worst excess 822 units on the dense fixture, 1.47 and 713 on
babble. **A few cables are doing all the detouring**, which is why stretch and excess are
both kept: stretch finds a short cable taking a silly detour, excess finds a long one wasting
seven hundred real units.

**Crossings are concentrated, not diffuse.** One cable in the dense fixture participates in
eleven of its forty-four routed meetings; one cable in babble participates in four of ten.
Ten crossings is not ten unrelated problems.

**And the crossings split into two kinds.** Four of babble's ten are pairs of cables that
end at *the same node on different ports* and meet on the approach to it. They are not
really route conflicts; they are two cords converging on one destination and meeting just
short of it. The other six are ninety to four hundred and twenty units out in open space,
and those are genuine mid-route conflicts.

That distinction matters more than the count, and goal 1.1 gave it a definition that does
not depend on picking a distance: the two cables share a node, and the meeting is on the
half of each cable nearer that node. On the dense fixture the same test finds seven of
forty-four. The first kind might be answered at the terminal — port order, or an approach
fan — without the router changing a route at all. The second kind is the router's problem.

**Stability is the finding.** The question was whether a forty-unit node nudge produces a
forty-unit route adjustment or sends the cable down a different corridor, and on the hostile
fixtures the answer is unambiguous:

```
plucked-string   worst 1.0x, mean 1.0x, 0 cables rerouted that did not move
dense-tidied     worst 21.3x, mean 1.4x, 47
babble-tidied    worst 11.5x, mean 1.4x, 51
```

A single grid step can move a cable **eight hundred and fifty units**, and around fifty cables
whose own endpoints did not move are rerouted by a node passing through their corridor. The
mean is 1.4×, so most nudges behave — but the tail is a cable jumping corridors, and that is
something a person feels in the hand rather than sees in a screenshot.

**A patch with room does not have the problem.** plucked-string routes at 1.0× with zero
stranger reroutes, zero bends and 474 units of clearance. The router is not badly behaved in
open space; it is badly behaved in tight space, and the tight-space cases hug obstacles at
eighteen and thirty units.

### One thing this baseline could not reconcile

The cord layer counted 26 crossings on the dense fixture where this file's enumeration
found 42, and 7 against 10 on babble. The layer was reported as authoritative because it is
the thing that draws them, and the gap was printed rather than explained.

**That was the right instinct and the wrong conclusion.** Goal 1.1 took it apart; the
corrected figures are already in the table above. What follows is what it found.

## Goal 1.1 — reconciling the crossing semantics

> **With no routing change at all, make every crossing-count disagreement explain itself.**

### They were not looking at the same drawing

The editor opens in **CATENARY** cable style. The cord layer draws hanging curves;
`_routes()` returns the PCB router's polylines. On babble that is twenty-six cables at
twenty-nine vertices each against twenty-five, and not one of them the same shape.

So the two counts were never in conflict. They were counts of two different pictures, and
comparing them was a category error that neither counter could have detected on its own.

```
                    catenary, as the editor opens    routed, what _route produces
dense-tidied        26 marks   26 meetings           45 marks   44 meetings
babble-tidied        7 marks    7 meetings           11 marks   10 meetings
plucked-string       1          1                     1          1
first-synth          0          0                     0          0
```

Which leaves a second finding sitting in plain sight: **the router's own geometry crosses
roughly twice as much as the style the editor actually draws.** Twenty-six against
forty-four, seven against ten. Nothing here acts on that, but it is now a fact on the record
rather than an accident of which harness was asked.

### Two counts remain, and both are true

On one geometry the numbers still differ, and the difference is real rather than a bug:

- a **mark** is a crossing treatment the cord layer paints. It inherits
  `CableArt.crossings`, which takes the first hit on each segment of the upper cable and
  moves on. It is the right number for "how much crossing grammar is on this screen".
- a **meeting** is a place two drawn cables actually cross, with doubled reports merged.
  It is the right number for an objective, because an optimiser that removed a mark by
  splitting it in two would otherwise score a win.

`CableCrossings.tally` is where that naming lives, so neither number can be reported again
without saying which one it is.

### One classifier, three consumers

`cable_crossings.gd` now holds the whole decision, and `_draw`, `crossing_sites` and
`route_baseline.gd` all call it. The geometry is a parameter and every answer records which
geometry it was asked about — a classifier that quietly picked one would have been the same
defect in a new place.

For each intersection it returns the pair, the position, the crossing angle, the distance
from each cable's own end, whether it is rendered, **why**, and a set of traits that decide
nothing:

```
reason   ordinary_crossing | shared_port | colour_rule
traits   same_node | converging | shallow
```

Reasons decide; traits describe. A trait that quietly decided something would be an
exclusion rule nobody voted for, and promoting one is a later goal's job with the population
in front of it.

**No exclusion rule changed.** The acceptance test is that all four fixtures still count
exactly what they counted before — 0, 1, 26, 7 — and that the layer, the classifier and the
number layout optimises against all agree. `crossing_semantics.gd` asserts that on every
push.

### Three counting bugs it found on the way

Worth listing, because each one had been reporting a plausible number:

- **`_same_ink` was two different rules.** The first version of the classifier tested
  colour in HSV; the cord layer tests it channel by channel in RGB. They agree on most
  pairs, which is exactly what makes a near-copy dangerous.
- **The dedup never deduplicated.** It accumulated positions in a `PackedVector2Array`,
  which is a value type in GDScript — the cast on the way to `append` handed back a copy,
  nothing was ever stored, and every hit reported itself as the first of its kind. Caught
  because two meetings at *identical* coordinates printed as separate rows.
- **The listing could not tell two crossings apart.** "Distance from the nearer end" is
  symmetric about the middle, so one cable crossing another twice — once outbound, once
  back — printed the same numbers twice and read as a duplicated row. The count was right;
  the line was ambiguous. Positions are now in it.

Goal 1's own crossing figures were wrong in both directions as a result: 42 and 10 were
undercounts of the routed geometry, and 26 and 7 were counts of a different drawing. The
table above is corrected. The routing measurements — stretch, excess, bends, clearance,
determinism, stability — were all taken from `_routes()` and stand unchanged.

### What this says about the tidied fixtures

`tidy_fixtures.gd` derived them by minimising `_layout_crossings()`, which reads the cord
layer, which draws catenaries. So the fixtures are optimised for the picture the editor
shows and carry 44 and 10 meetings in the router's own geometry.

Recorded, not fixed. Layout is frozen, and this is a question about which drawing an
operation optimises rather than about how it searches.

## What the pass looks like from here

Not "reduce crossings". The baseline suggests three separable questions, and they are not
equally urgent:

1. **Route stability.** A grid step should cost a grid step. Twenty-one times is an
   interaction defect, and it is the one a person would notice first.
2. **The detour tail.** A handful of cables carry all the excess. Finding out *why* those
   specific routes cost seven hundred units is a smaller question than reducing cable in
   general.
3. **Crossings**, split by kind: the converging-on-a-terminal population and the open-field
   conflicts. The counters agree now, so this is unblocked — but it is still third.

Stability comes first, and the reason is worth stating as a principle rather than a
preference. Suppose an alternate-path search removes three crossings, and then a filter
nudged forty units sends fifty cables into other corridors. There would be no way to tell
whether the search improved the router or found one fragile equilibrium.

> **A local document edit should cause local route change, unless the old corridor has
> become invalid.**

Not zero change, and not continuity at any cost. Route hysteresis as an explicit concern,
which the router does not currently have.

No route has been changed. This is what the router is doing, measured.
