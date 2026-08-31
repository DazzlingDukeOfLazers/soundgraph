# Cosmopolitan Cables

The record of the cable pass, in the same discipline as the node pass: baseline first, then
one problem at a time, each goal changing a single variable and judged against a rendered
comparison before the next begins.

## What is in scope, and what is already finished

`docs/cable-design.md` is a **finished, frozen subsystem** and is not in scope. Ten goals
settled the material of one cable — mass, shell, glint, shadow, plug, cut-end mouth, colour
collar, deterministic hang, departure splay, crossing occlusion and surface response — each
against a rendered comparison, each freezing what came before it. Those figures stand.

This pass is a different layer: **routing and legibility in a dense field.** How a cable
behaves as one of thirty-five rather than as one cable.

The rule that carries over from the node pass, unaltered:

> **Colour, topology, focus, signal type, connection state and activity are separate
> channels. No treatment may make one of them carry another.**

That is the rule the node pass spent eleven steps learning, and a cable pass that ignores it
will rediscover every problem the node pass already solved.

## The seven problems

1. **Crossing ambiguity.** At dense intersections, especially same-colour ones, it takes
   effort to work out which strand continues through which path.
2. **Long-route ownership.** A cable crossing half the graph becomes visually detached from
   both its ends.
3. **Colour-only type information along the span.** The endpoints carry socket shape; the
   middle of a cable carries hue and nothing else.
4. **Cable hierarchy.** Every ordinary cable demands about the same attention, whether it is
   the main audio path, a secondary modulation, or one of twenty event connections.
5. **Dense bundles.** Parallel and near-parallel runs accumulate into visual mass rather
   than behaving like organised routes.
6. **Occlusion at nodes.** Socket termination is settled; a cable passing behind or beside
   an unrelated node still complicates local reading.
7. **MAP behaviour.** At 28–40% the cables are a larger share of what is left, so their
   grammar matters more exactly where the node grammar has stood down.

## Step 1 — the baseline

`cable_baseline.gd`, against `editor-godot/qa/dense-graph.json` — the hostile specimen built
for the node pass's 15B. Deliberately not a new, friendlier cable card: it already has the
long crossings, the fan-outs, the multi-input mixing and the density.

```bash
CABLE_BASELINE_OUT=/tmp/p godot --headless --path editor-godot --script cable_baseline.gd
```

It measures rather than describes, because six of the seven problems are about density and
density is what an impression is worst at.

```
cables            35
  median length   357 units
  longest         2955 units          8.3x the median
crossings         32
  same colour     15                  47%
  under 25 deg     0
  both             0
bundled pairs      2                  within 10 units, under 15 deg, for over 20 units
node crossings     3                  a cable over a node it has no business with

patch extent      4016 x 2580 units, 29277 units of cable in it

zoom     band        cord px    cable share
100      FULL           8.00           2.3%
 66      REDUCED        5.28           2.3%
 40      MAP            3.20           2.3%
 28      MAP            2.40           2.4%
```

Archived at `docs/proofs/cable-baseline.json`, with every crossing's position, angle and
colour pair, every cable's detour ratio, and every trespass.

### What the baseline already changed about the plan

Three of the seven problems came back much smaller than they look, and one came back
differently shaped. That is the whole reason to measure before designing.

**Shallow crossings do not exist here — zero of thirty-two.** The expectation going in was
that grazing intersections would be the hard ones, and the catenary routing has already
solved that: Goal 6's per-cable hang and Goal 7's alternating departure splay push
neighbours apart, so every crossing in the specimen is transverse. **Problem 1 is therefore
not about angle. It is about the fifteen same-colour crossings**, which meet at perfectly
readable angles and are still ambiguous because both strands are the same mint.

That is a much narrower target than "crossing treatment", and it points somewhere specific:
whatever is done at a junction has to distinguish two cables that are *identical in every
channel except which one is on top*.

**Bundles are two pairs, not a problem.** Goal 7's splay is doing its job. Problem 5 may be
a problem in patches with wider fan-outs than this one, and the honest position is that the
specimen does not demonstrate it. Do not design for it on this evidence.

**Trespass is three.** Problem 6 is real and rare. Three cables pass through a node's
territory that has nothing to do with them.

**Cable share is flat at 2.3%, and that is the finding.** The cord width scales linearly
until `maxf(8 * zoom, 2.4)` puts a floor under it below a zoom of 0.3, so cables hold
exactly their share of the picture at every distance and gain 0.1 point at 28%. So **problem
7 is not cables getting heavier. It is everything else getting lighter** — at MAP the nodes
shed their controls, their values and eventually their port names, and the cables are left
carrying a larger share of the *remaining information* while carrying an unchanged share of
the *ink*. Reducing cable weight at MAP would be solving the wrong half.

**Problem 2 stands, and has a figure.** The longest cable is 2955 units against a median of
357 — eight times — in a patch 4016 units wide. One cable crosses three quarters of the
graph.

## The first question

> **How does a single route stay identifiable through a dense field without making every
> route louder?**

Three techniques, tested separately and in this order:

1. **Crossing treatment** — a bridge, gap or halo at intersections so continuity is
   obvious. Aimed at the fifteen same-colour crossings, which is now known to be the whole
   of problem 1. Goal 8 already established that occlusion plus a local halo works; the
   question is whether it is enough when both cables are the same colour.
2. **Focus treatment** — hovering or selecting a cable or a socket **suppresses unrelated
   cables** rather than brightening the chosen one. Suppression rather than emphasis,
   because emphasis is another way of making the graph louder and the whole point is that
   it should get quieter.
3. **Sparse type marking** — very infrequent inline semantic marks or texture, as the
   grayscale fallback for problem 3. **Only after crossings work**, and deliberately last.

### What not to start with

Dashed control cables, or any repeating pattern. With thirty-five intersecting cables, a
reasonable pattern becomes plaid, and the pattern then competes with the crossing treatment
that problem 1 actually needs. The grayscale gap is real and it is filed in
`docs/known-issues.md`; it is third in the queue and not first.
