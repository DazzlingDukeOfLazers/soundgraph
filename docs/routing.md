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
crossings                        0               1            26              7
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
busiest cable                    —      1 of 1        10 of 42        4 of 10
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
ten of the forty-two meetings this file enumerates; one cable in babble participates in four
of ten. Seven crossings is not seven unrelated problems.

**And the crossings split into two kinds.** Three of babble's ten sit within fifty units of
an end, and all three are pairs of cables that terminate at *the same node on different
ports* — `n2:0>n4:0` against `n22:0>n4:1`, `n3:0>n5:0` against `n22:0>n5:1`, and two cables
both leaving `n0`. They are not really route conflicts at all; they are two cords converging
on one node from opposite sides and meeting just short of it. The other seven are ninety to
four hundred and twenty units out, in open space, and those are genuine mid-route conflicts.

That distinction matters more than the count. The first kind might be answered at the socket
— port order, or an approach fan — without the router changing a route at all. The second
kind is the router's problem.

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

The cord layer counts 26 crossings on the dense fixture and 7 on babble; this file's own
enumeration finds 42 and 10 after deduplicating hits within a 24-unit radius. Both exclude
cables sharing a port, and the layer is authoritative because it is the thing that draws
them, so the layer's number is what is reported.

The gap is printed rather than reconciled quietly, and it is a finding in its own right:
**two counters over the same geometry disagree by half.** Worth resolving before any goal
uses a crossing count as an objective.

## What the pass looks like from here

Not "reduce crossings". The baseline suggests three separable questions, and they are not
equally urgent:

1. **Route stability.** A grid step should cost a grid step. Twenty-one times is an
   interaction defect, and it is the one a person would notice first.
2. **The detour tail.** A handful of cables carry all the excess. Finding out *why* those
   specific routes cost seven hundred units is a smaller question than reducing cable in
   general.
3. **Crossings**, split by kind: socket congestion near an endpoint, and mid-route conflict.
   And not until the two counters agree.

No route has been changed. This is what the router is doing, measured.
