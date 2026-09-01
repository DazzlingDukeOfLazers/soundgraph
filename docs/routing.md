# Cosmopolitan Routing

The record of the routing pass. Baseline first, then one problem at a time, in the discipline
the node, cable and layout passes used.

## The boundary, written down first

> **Routing is judged with node positions, port positions, cable endpoints, node geometry and
> the frozen cable visual grammar all held fixed.**

That is what stops the router "winning" by quietly borrowing from layout. `docs/layout.md`
and `docs/graph-cable-system.md` are both closed, and nothing in this pass may reopen either.

### And a naming rule, from goal 1.1

> **Never write "crossings" in this pass without naming the geometry and the concept.**

`catenary marks`, `catenary meetings`, `routed marks`, `routed meetings`. The bare number
cost this pass a whole goal's worth of wrong conclusions and it is now treated as an error.

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

## Goal 2 — where a local edit actually lands

> **A local document edit should cause local change in every geometry the product presents
> or depends upon, unless the previous geometry became invalid.**

Goal 1 said a forty-unit nudge moves a cable 21.3x the nudge and called it an editor
defect. Goal 1.1 then found that every one of those figures came from `_routes()` while the
editor draws catenaries. So the claim had an unexamined step: **nobody had established that
the user sees any of it.** `route_stability.gd` asks three questions in the order that stops
the later ones being wasted.

### A. Visibility — the drawing does not jump

```
                     routed worst    drawn worst
plucked-string            1.0x           1.0x
babble-tidied            18.5x           1.4x
dense-graph-tidied       15.7x           1.5x
```

The routed geometry lurches. The drawn geometry does not: 1.4x and 1.5x is a cable adjusting
itself, which is what the principle asks for. **Goal 1's headline is withdrawn** — no user
watching this editor sees an 850-unit cable jump, because a hanging cable is a function of
its own two endpoints and cannot be rerouted by a distant node at all.

The 25 drawn cables on the dense fixture that change with both endpoints still are the
departure splay from the cable pass's goal 7, which alternates down each column of occupied
anchors. Moving a node reorders that column and flips a neighbour's lean. Small, local,
and by design.

### But the routed geometry is not latent, and that is the real finding

Asked by switching `cable_style` and watching which answers move — a grep finds call sites,
and `_get_connection_line` calls `_route` at a line CATENARY never reaches, so the source
says the drawing depends on the router and the product says otherwise.

```
layout crossings          drawn      7 catenary / 11 routed
crossing marks            drawn      7 / 11
layout cable, total       routed     16289 either way
layout cable, longest     routed     4025 either way
legalize trespasses       routed     0 either way
hit testing               routed
```

Two consequences, and the second one is serious.

**The layout objective is split across two geometries.** Crossings are counted in the
picture the editor draws; cable length and trespass are measured in the router's. One
objective, two drawings.

**Hit testing targets a geometry the user cannot see.** `_connection_at` picks against
`_route`, and it is on the live path for cable hover, click-to-lock focus, waypoint drag
and right-click-to-straighten — none of them gated on cable style. Sampling each cable at
the midpoint of the curve *as drawn*:

```
                  sampled   hit nothing   named another cable   correct
plucked-string          6             4                     1         1
babble-tidied          26            22                     4         0
dense-graph-tidied     35            26                     2         7
```

The gap between the drawn cable and its own click target is a median 33 to 50 units and a
worst of 550, against a `GRAB_DISTANCE` of 12. **On babble you cannot click a single one of
the twenty-six cables where it is drawn.**

That also corrects the scope of an earlier proof rather than its result. The cable pass's
gesture harness was made to work by taking its probe points from `graph._routes()`, because
that is what `_connection_at` picks against. It proved the focus mechanism fires when you
click the right place. It never asked whether the right place is where the cable is drawn —
the eighth instrument in this programme to stand for the thing instead of being it.

### B. Attribution — and a prediction that failed usefully

```
                    changed   direct   obstacle-local   dependent   unexplained
plucked-string           48       48                0           0             0
babble-tidied           251      200               38           1            12
dense-graph-tidied      313      266               42           0             5
```

The prediction written into the harness before it ran: obstacles are node rectangles and
nothing else, so a cable can only reroute if a box it cares about moved, and the unexplained
population should be empty. **It was not**, so by the harness's own rule the influence
region was suspect rather than the router mysterious. Measuring the distance settles it:

```
babble-tidied        the unexplained run  974 to 2894 units from the node that moved
dense-graph-tidied                        472 to 1044
```

No influence region covers 2894 units. The prediction was wrong for an instructive reason:
obstacles are the only input, but they are a **global** input to candidate generation rather
than a local input to collision. Being in the obstacle list is not the same as being in the
way.

`_orthogonal_candidates` builds its channel positions from *every* obstacle in the graph,
sorts them by distance from this cable's own midpoint, and `_route` takes the first clear
one. Move any node and its two channel coordinates shift by the nudge, reordering that
ranking for every cable whose span contains them. So:

> **A cable's corridor is a greedy pick from a list ranked by the position of every node in
> the patch. There is no path memory, so nothing prefers the corridor it was already in.**

That is the mechanism behind the strangers, and it is a different repair from anything to do
with obstacles being in the way.

### C. Order sensitivity — no

```
plucked-string        0 of 6 routes differ when the connection order is reversed
babble-tidied         0 of 26
dense-graph-tidied    0 of 35
```

`_route(a, b)` is a function of two points and a set of boxes. Routing is per-cable pure, so
the strangers are not path-allocation order dependence in the connection sense. They are
obstacle-ranking dependence, which the previous section names exactly.

### Two instrument corrections made during this goal

Both worth recording, because one of them was me being wrong about the instrument:

- I suspected the harness compared every probe against a baseline captured once at the top
  of the run, and rebuilt it to re-read before each probe. **The numbers were identical.**
  The drift hypothesis was wrong and the instrument had been right; the fresh baseline is
  kept because it is strictly more correct and costs nothing.
- The focused probe that chased the unexplained cables tried one of the four nudge
  directions, found the routes byte-identical, and I nearly reported the harness as broken
  on the strength of it. The harness nudges four ways. A probe that tries one is not
  checking the same claim.

## What the pass looks like from here

Goal 2 reordered this. The stability problem is real but it is not what a user sees, and
something else found on the way is.

1. **Hit testing picks against the wrong geometry.** Not a routing problem at all — the
   click target should be the cable that is drawn. It is the only item here a person
   experiences today, and it silently undermines the cable pass's focus work.
2. **The layout objective is split across two geometries.** Crossings from the drawing,
   length and trespass from the router. Worth settling before either is optimised further.
3. **Corridor stability.** A cable's corridor is a greedy pick from a globally ranked
   channel list with no memory of where it already was. This is the "route hysteresis"
   subproblem, and it now has a mechanism rather than a symptom.
4. **The detour tail.** A handful of cables carry all the excess.
5. **Routed meetings**, split into the converging-on-a-terminal population and the
   open-field conflicts.

The principle stands, with the geometry named:

> **A local document edit should cause local change in every geometry the product presents
> or depends upon, unless the previous geometry became invalid.**

The drawn geometry already satisfies it. The routed geometry does not, and the reason it
matters is not that cables jump on screen — it is that hit testing, trespass and cable cost
are all measured there.

No route has been changed, and no crossing has been called a router defect.
