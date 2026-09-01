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

## Goal 2.1 — the pointer and the picture

> **A cable's interactive locus is the centreline actually displayed by the active cable
> style.**

Not a routing goal. `_route` is untouched; so are the cable pixels, the crossing counts, the
layout scoring, legalization and the stability behaviour. The only thing that changes is
which curve the pointer is asked about.

### Two geometries, finally named

`_routes()` said "routes" and meant the obstacle-avoiding polyline whatever the style, so
hit testing reasonably asked for the routes and got a cable nobody could see. The names now
make that mistake harder to make:

```
display_path(connection)    what is on screen. CATENARY hangs, ROUTED routes.
routing_path(connection)    the obstacle-avoiding path, whatever is on screen.
```

Drawing, crossing analysis and picking all take `display_path`, and take it through
`_get_connection_line` — the function Godot calls to draw with — so the picked curve is the
drawn curve by construction rather than by agreement. The cord layer had been spelling its
endpoints out a second time; that seam is gone.

`routing_path` keeps its consumers: trespass and cable cost. It is a hypothesis about where
a cable could go, and goal 2.2 will ask each consumer whether that is what it meant.

### The upper strand rule

At a crossing both cables are the same distance from the pointer, so distance alone cannot
choose and the tie has to come from somewhere. It comes from the same place the knockout
does — draw order:

> **Where two cables are equally near the pointer, the one drawn last wins: the strand the
> picture puts on top.**

`PICK_TIE` is three units, well inside one cord width, so cables merely running alongside
each other are still separated by distance.

### What the probe demands

`hit_geometry.gd`, on all four fixtures, both cable styles, and the zoom bands the editor
presents — 1,373 sample points:

```
                     catenary 100 / 66 / 40      routed 100 / 66 / 40
first-synth               29 / 31 / 33                27 / 27 / 28
plucked-string            26 / 30 / 30                27 / 30 / 30
babble-tidied             79 / 94 / 97                72 / 78 / 76
dense-graph-tidied      105 / 138 / 149             120 / 148 / 149
```

All correct, against 0 of 26 on babble before. Plus 26 crossings that must select the upper
strand, and 177 points on the hidden routing path — far from anything drawn — that must
select **nothing**. That last assertion is what stops the contract being satisfied by simply
casting a wider net.

Two rules the probe had to learn rather than assume, both caught by its own failures:

- **The stub.** `_connection_at` refuses any point within `STUB` of a port; those belong to
  the socket. The first run sampled inside them and reported twenty-five failures on babble,
  every one a short cable whose 20% mark is inside its own stub. A probe that samples where
  the product declines to answer is measuring its own arithmetic.
- **Coincidence.** "Did it return the cable I sampled" is the wrong assertion wherever two
  cables occupy the same place, and they do constantly by design — a fan-out leaves one
  output as two coincident cords, two cables between the same pair of nodes run parallel,
  and routed cables share channels for long stretches. What can be demanded is that
  something is picked, that nothing farther away wins, and that among equals the upper
  strand does. The contested count is reported rather than hidden: 10 of babble's 78 routed
  samples at 66%.

### And the gesture probe, corrected

`cable_gestures.gd` took its points from `graph._routes()`, on the reasoning that this is
what `_connection_at` picks against so the hover test would agree. Sound reasoning, wrong
conclusion: agreeing with the picker was not the same as landing on the cable. It now takes
them from `display_path`, which makes it meaningfully harder to satisfy — a point off the
drawn curve is a failure rather than an adjustment.

Sixteen checks, through `Input.parse_input_event` in a real window: hover, click to lock,
click again to let go, pointer-off does not let go, lock survives zoom and pan, Escape,
empty-canvas click, waypoint drag is not a click, **right-click straightens a dragged
cable**, socket hover, port-family lock, and a drag from a socket that lands on nothing.

Right-click-straighten is new to the probe. It is one of the four gestures that reach a
cable through `_connection_at`, so it had been picking against the invisible path along with
the other three, and nothing tested it.

So the earlier proof is corrected precisely: **the mechanism was valid, and the visible
object now reaches it.**

## Goal 2.2 — who owns which geometry

An audit. No consumer changed. The question for each:

> **What semantic property is this consumer trying to measure, and which geometry actually
> owns that property?**

After 2.1 only two product consumers still read `routing_path`: the arrangement's cable
cost, and the legalizer's trespass test. Both were exercised through the real operation with
only the geometry swapped, on all four fixtures plus a five-node case built to make the two
disagree.

### The ownership table

```
consumer                current    disagree?   affects decisions?   intended owner
drawing                 display    —           —                    DISPLAY
crossing marks          display    —           —                    DISPLAY
hit testing             display    —           —                    DISPLAY  (goal 2.1)
layout crossings        display    —           —                    ?
layout cable total      routing    yes         yes                  ?
layout longest          routing    yes         yes                  ?
legalizer trespass      routing    yes         yes                  ?
```

The last column is deliberately empty. The evidence below says the split is not harmless;
it does not say which way to resolve it, and 2.2 was not authorised to choose.

### A. The four cells

In ROUTED style the two geometries are the same object, so the interesting column is
CATENARY — the style the editor opens in.

```
                     drawn      routed        drawn      routed
                     cable      cable         trespass   trespass
first-synth           2518       2406            1          1
plucked-string        2365       2248            0          0
babble-tidied        14545      16289           14          0
dense-graph-tidied   25740      30648           23          0
disagreement case     3378       3102            1          0
```

Cable cost differs by up to 16%, and in both directions: the catenary is *shorter* than the
route on the hostile fixtures and longer on the simple ones. That is metric disagreement, and
on its own it might be harmless.

### B. Trespass — "legal" currently means the invisible path is clear

Of the four possible states, one dominates and one never appears:

```
display clear / routing clear        common
display trespass / routing clear     14 on babble, 23 on dense, 1 on the built case
display clear / routing trespass     never observed
display trespass / routing trespass  1 on first-synth
```

So the blunt question has a blunt answer. **Yes: the editor reports a layout as legal while
the cable the user is looking at passes through a node** — fourteen times on babble,
twenty-three on the dense fixture. `Resolve overlaps` declines to act on any of them.

`qa/geometry-disagreement.json` reduces that to five nodes: one long cable, one node under
the middle of it. The drawn cable sags straight through the box; the router's path is close
to the chord and clears it; the editor calls the arrangement legal.

The inverse state was never produced, including by deliberate attempt. There is a structural
reason to expect it to be rare — `_route` trespasses only when no candidate is clear, which
means boxed in, and a box tight enough to trap the orthogonal candidates also traps the sag.
Recorded as **not observed** rather than impossible.

### C. Decision disagreement — and it is on the simplest shipped patch

Metric disagreement may be harmless. This is not:

```
first-synth, Resolve overlaps, one node moved

  routed trespass    1 -> 0        the fault it was asked to clear
  drawn  trespass    1 -> 1        n3, crossed by n4>n5. The same one. Still there.
  routed cable    2406 -> 2676     +270 spent
  routed longest  1017 -> 1315     +298
  drawn  cable    2518 -> 2495     -23
```

**The operation moves a node, reports the trespass cleared, and the cable the user is
looking at still runs through exactly the same box** — while spending two hundred and
seventy units of cable nobody can see to achieve it. Not a hostile fixture: `first-synth` is
a shipped example.

That is the finding the goal exists to produce. The product is not merely measuring
invisible geometry, it is *acting* on it, and its success criterion is invisible too.

On the other fixtures all three operations declined to move at any node, so no further
decision disagreements were available to observe — the tidied fixtures are already at their
fixed point, which is what makes them fixtures.

### D. Style invariance — already broken, quietly

```
first-synth           tidy flow places every node the same in both cable styles
plucked-string        the same
babble-tidied         2 nodes differently
dense-graph-tidied    2 nodes differently
disagreement case     the same
```

Changing how cables are *drawn* changes where `Tidy flow` decides nodes belong. That is not
a bug against a stated rule, because no rule was ever stated. There are two coherent
positions and SoundGraph is accidentally between them:

> **Style-independent layout.** Cable style is presentation. Arrangement semantics should not
> change when I change how cables are drawn — which means layout needs a canonical geometry
> that is neither of the two we have.
>
> **WYSIWYG layout.** Arrangement optimises what I am looking at. Then crossings, length and
> trespass all belong to `display_path`, and switching styles legitimately changes what tidy
> means.

2.2 does not choose. It establishes that the choice exists, that it is currently being made
by accident, and that it has consequences on shipped patches.

A third contract may be needed and should not be faked with either existing geometry:

```
DISPLAY             the cable on screen
ROUTING             the obstacle-avoiding construction
STYLE_INDEPENDENT   a canonical cost that must not move when the style does
```

## Goal 2.3 — the boundary, chosen

The audit's table has an intended-owner column now, and it is deliberately mixed, because
the two consumers were asking different questions:

```
consumer                current    intended            why
drawing                 display    DISPLAY
crossing marks          display    DISPLAY
hit testing             display    DISPLAY             goal 2.1
legalizer trespass      DISPLAY    DISPLAY             a fault is a cable you can see
structural cable cost   canonical  STYLE_INDEPENDENT   how far apart connected things are
tidy routes             display    DISPLAY             it cleans up the picture
layout crossings        display    ?                   the one still open
```

> **Structural placement metrics describe the graph, independent of presentation. Visual
> repair and visual cleanup describe the active presentation.**

### Trespass is WYSIWYG

`_layout_faults` reads `_display_routes()`. In ROUTED style that *is* the routed polyline,
so nothing changes there; in CATENARY it is the hanging curve, which is the point.

The defect goal 2.2 caught is gone. On `first-synth` the fault now goes **1 → 0** where it
used to go 1 → 0 in the router's geometry and 1 → 1 in the drawing. The constructed case in
`qa/geometry-disagreement.json` is recognised and repaired. And the claim is checked against
the drawing rather than against the function that made it: for every pair the legalizer stops
listing, `geometry_contract_test.gd` walks the cable as drawn and confirms it misses that
node's body — 34 pairs across the fixtures, none of them lying.

```
                     visible trespass, before -> after Resolve overlaps
first-synth                     1 -> 0     (1 node moved)
babble-tidied                  14 -> 0     (10 nodes)
dense-graph-tidied             23 -> 5     (14 nodes)
geometry-disagreement           1 -> 0     (1 node)
```

Five left on the dense fixture is within the contract — clear it, or decline because no
admissible local repair exists — and "declined" is proved rather than asserted: running the
operation again moves nothing.

### Cable cost is canonical, and boring on purpose

`_layout_cable` is gone. `_structural_cable` is the sum and the maximum of the straight-line
distance between the two ports. No obstacle avoidance, no sag, no cord shape, no waypoint,
no corridor.

Euclidean rather than Manhattan deliberately: Manhattan would bake the ROUTED style's
orthogonal grammar back into a metric that exists precisely to be free of any style's
grammar. It would look canonical and would not be.

Named `structural_` so nobody later reaches for `path.length()` because a field happened to
be called `cable`. The test asserts it against an independently computed sum, not against
itself.

### What that cost, and it is not small

Changing what a fault *is* moved three suites' expectations, and one product behaviour:

- **The legalizer has several times the work.** The hostile patch goes from 33 faults to 2,
  moving 17 nodes and 7989 units where the pre-2.3 witness against a smaller fault set spent
  9 and 1520. It is not worse; it was handed more. The one bound that is not calibration
  still holds: far cheaper than auto-place's 29 nodes and 50742 units.
- **`legalize_test` no longer demands zero**, because the contract does not. It demands most
  of them, and idempotence as the proof of "declined".
- **`tidy_test`'s "starts legal" is gone.** `dense-graph-legalized` and `babble` were legal
  when a trespass meant the hidden path; they carry 23 and 14 visible ones now. The fixtures
  did not change and tidy did not change — the word did.
- **Both tidy operations were briefly dead.** They refused to run on a graph with any fault,
  which was reasonable when most patches had none, and became a refusal on nearly every real
  patch. `routes_test` caught it doing exactly nothing: 31 → 31, 9 → 9. The precondition is
  now the weaker and more honest one — **a tidy operation may not make the drawing less
  legal than it found it** — with overlapping *nodes* still a hard stop, since tidying
  around a genuine collision would hide it and node overlap does not depend on cable style.

### The one still open

`Tidy flow` is structural and should be style-independent. It is not: two nodes on babble
and two on the dense fixture still move differently depending only on how cables are drawn.

2.3 did not cause it — goal 2.2 measured the same two nodes before any of this — and 2.3
cannot close it. `_tidy_flow` guards on `_layout_crossings()`, which the cord layer answers,
so a structural decision is gated on the drawing. Closing it needs a **canonical crossing**:
plausibly the port-to-port chords crossing each other, by exactly the reasoning that made
cable cost Euclidean. That is a decision rather than a cleanup, so it is measured and
printed by `geometry_contract_test.gd` and left named.

### And `routing_path` finally has a small job

It owns ROUTED cable construction and ROUTED cable quality. It is no longer an invisible
proxy for layout semantics, which means the global corridor instability goal 2 measured is
now a defect in one cable style's renderer rather than something reaching into unrelated
editor operations.

## Goal 2.4 — the canonical crossing, and a contradiction in its own brief

`structural_geometry.gd` holds the abstract drawing: what a patch looks like with no cable
renderer involved at all. Both structural metrics now come from the same place.

```
structural length     Euclidean distance between the two ports          (goal 2.3)
structural crossing   a proper interior intersection of two of those chords
```

Three exclusions, so the metric does not inherit presentation noise:

- **shared port** — a fan is not a crossing, which the cable pass settled long ago;
- **shared node at either end** — two cords converging on one module can always be made to
  cross by the port order, and `Tidy flow` moves nodes; it cannot reorder ports, so counting
  these charges it for something it has no instrument to fix. The routing audit already
  named this population: terminal convergence, not a corridor conflict;
- **endpoint touches and collinear overlap** — a proper interior intersection or nothing,
  or the metric jumps about on exactly the coincidences a grid layout produces most.

Called `structural_chord_crossings`, never `crossings`. An unlabelled crossing number has
cost this pass a goal already.

`Tidy flow`'s crossing guard moved onto it. `Tidy routes` kept `_layout_crossings()`,
because improving the crossings on screen is its whole job, and it is allowed to behave
differently between styles.

### And the trespass monotonicity got stronger

A count was the obvious reading of "no less legal" and it is too weak: a move can drop one
trespass, introduce a different one, leave the total unchanged and be accepted.

> **A tidy move may remove a visible trespass. It may not trade one for another.**

So the trespass pairs after have to be a subset of the pairs before. Node overlap keeps its
stricter rule — never any, before or after.

### The contradiction, and the contract that resolves it

The brief asked `Tidy flow` for two things that cannot both hold:

```
do not introduce new visible trespass pairs
cable presentation style has no input whatsoever
```

Visible trespass **is** presentation. Four fixtures never notice, because they have none or
the styles agree. The dense fixture carries twenty-three in CATENARY and none in ROUTED, and
there the two pull apart. Both sides were built and measured:

```
structural trespass guard    style-independent on every fixture
                             dense-graph-legalized: visible trespass 23 -> 25
                                                    drawn crossings  31 -> 32

visible trespass guard       the picture never gets worse
                             two nodes placed differently by style, on one fixture
```

The resolution is not to pick a side but to notice they are different *kinds* of rule:

> **Presentation may veto a structural improvement, but presentation never supplies the
> improvement objective.**

So `Tidy flow` has a style-independent objective and an active-display safety constraint:

```
stage objective                  STYLE_INDEPENDENT
structural chord crossings       STYLE_INDEPENDENT
structural cable cost            STYLE_INDEPENDENT
node overlap legality            STYLE_INDEPENDENT
visible trespass monotonicity    active DISPLAY — may veto, may not propose
```

**Only the active presentation.** Checking both would put ROUTED geometry — and `_route`'s
global corridor instability with it — back inside a CATENARY decision, which is the exact
dependency 2.3 removed. It would also mean that adding a third cable style someday silently
changed the behaviour of the two that already existed.

That makes the dense divergence legitimate rather than tolerated, and the acceptance gate
is stronger than "identical across styles" because it has to be *accounted for*:

1. the structural objective scores an identical placement identically in both styles;
2. both runs admit the same candidates in the same order until the first veto — after one
   fires the two runs are standing in different arrangements and are expected to part, so
   requiring more would be requiring a veto to have no consequences;
3. where the final placements differ, a specific veto must account for it;
4. neither result adds a visible trespass in the style it was run in;
5. `Tidy routes` stays fully DISPLAY-owned.

Point 3 is what stops "style dependence" becoming a catch-all. `tidy_trace` records every
structurally-admitted candidate and what refused it, and the dense fixture now reports:

```
2 node(s) differ, and a display veto accounts for it
    catenary vetoed moving n17: would add ["n7|n8|n17", "n6|n2|n17", "n22|n17|n28"]
```

The alternate legality model that lost — `_structural_faults`,
`_structurally_no_less_legal`, `chord_trespass` — is **deleted**, not parked. A complete
second almost-authoritative implementation with no live consumer is exactly the tempting
near-copy that already cost this pass a goal when `_same_ink` existed twice. The experiment
is preserved here, in prose, with its numbers.

### Where that leaves the ownership table

```
consumer                  owner               settled at
drawing                   DISPLAY             —
crossing marks            DISPLAY             —
hit testing               DISPLAY             2.1
legalizer trespass        DISPLAY             2.3
tidy routes               DISPLAY             2.3
structural cable cost     STYLE_INDEPENDENT   2.3
structural chord cross.   STYLE_INDEPENDENT   2.4
tidy flow's objective     STYLE_INDEPENDENT   2.4
tidy flow's safety veto   active DISPLAY      2.4
```

`routing_path` owns ROUTED cable construction and ROUTED cable quality, and nothing else.
Its global corridor instability is now a defect in one style's renderer rather than
something layout and legalization are quietly answering to — which was the point of the
whole detour. The router's own domain is finally clean enough to work on: the 21.3x nudge
response, the detour tail, and its 44 and 10 routed meetings.

## What the pass looks like from here

Goal 2 reordered this. The stability problem is real but it is not what a user sees, and
something else found on the way is.

1. ~~Hit testing picks against the wrong geometry.~~ **Done, goal 2.1.**
2. ~~The remaining hidden-route consumers.~~ **Audited at 2.2, decided at 2.3.** Trespass
   is DISPLAY, cable cost is STYLE_INDEPENDENT and canonical.
3. ~~A canonical crossing.~~ **Done, goal 2.4**, and the geometry-ownership pass is closed
   with it. Structural objective, display safety, every divergence attributable.
4. **Corridor stability.** A cable's corridor is a greedy pick from a globally ranked
   channel list with no memory of where it already was. This is the "route hysteresis"
   subproblem, and it now has a mechanism rather than a symptom.
4. **The detour tail.** A handful of cables carry all the excess.
5. **Routed meetings**, split into the converging-on-a-terminal population and the
   open-field conflicts.

The principle stands, with the geometry named:

> **A local document edit should cause local change in every geometry the product presents
> or depends upon, unless the previous geometry became invalid.**

The drawn geometry already satisfies it. The routed geometry does not, and after 2.1 and
2.2 the reason it matters is precise: not that cables jump on screen, and no longer that the
pointer misses them, but that **trespass and cable cost are decided on a path that can move
a thousand units away from the edit that caused it** — and goal 2.2 showed the product
acting on that path on a shipped example patch.

Which also means the severity of the stability defect now depends on a decision rather than
on more measurement. If trespass and cable cost move to the displayed geometry, `_route`
becomes primarily the ROUTED-style path generator, and corridor hysteresis becomes an honest
router problem rather than an invisible dependency reaching into unrelated editor
operations.

No route has been changed, and no crossing has been called a router defect.
