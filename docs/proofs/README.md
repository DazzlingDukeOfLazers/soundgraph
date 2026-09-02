# Proofs

What each design pass was accepted on, and how to make it again.

**The numbers are archived; the pictures are regenerated.** That is this repository's habit
already — `docs/graph-baseline.json` is the step 1 baseline and there is no step 1
screenshot — and it is the right way round. A committed PNG is a claim nobody can re-derive
and a diff nobody can read; a committed record is a number the next run can be checked
against. Every sheet below is one command away, and every command is deterministic: same
patch, same seed, same layout.

Run any of them against `editor-godot/qa/dense-graph.json` — the hostile specimen built for
15B, which is the baseline for the cable pass too. Do not build a friendlier one.

## The records, archived

| File | Written by | What it settles |
|---|---|---|
| `registry-inventory.json` | `inventory.gd` | every runtime type, its class, its narrowest valid width at every interface scale, and the equation `registry = migrated + held` |
| `width-classes.json` | `width_sheet.gd` | each type's preferred width, its required class per scale, and the verdict against its declared class |
| `dense-graph-qa.json` | `qa_sheet.gd` | the eighty-frame matrix: health, identity variants, title columns, and every complaint (none) |
| `crossing-separation.json` | `crossing_sheet.gd` | goal 1: the same-colour crossings, and the ink each of the four constructions introduces at them |
| `focus-suppression.json` | `focus_sheet.gd` | goal 2: the three suppression levels, what each keeps of its resting luminance, and the achieved ratio |
| `blind-cue-answers.json` | `blind_cues.gd` | the key to the blind test that froze goal 3: fourteen shuffled endpoint-free crops, named 14 of 14 |
| `crossing-frontier.json` | `crossing_frontier.gd` | goal 5A: every single-node vertical move that removes a crossing, and what each one costs |
| `layout-baseline.json` | `layout_baseline.gd` | the layout pass's step 1: every patch measured by hand and as auto-place arranges it |
| `cable-closure.json` | `cable_closure.gd` | the cable pass's closure matrix: 278 invariants over both specimens, four zooms and two palettes |
| `cable-baseline.json` | `cable_baseline.gd` | the cable pass's step 1: every route's length and detour, every crossing's position, angle and colour pair, every bundle, every trespass, and the cable share of the patch at four zooms |
| `route-baseline.json` | `route_baseline.gd` | the routing pass's step 1: every route's length, stretch, excess, bends, reversals, clearance and trespasses, taken from the same points the cord layer draws, plus determinism over two reads and the response to a forty-unit nudge |
| `crossing-semantics.json` | `crossing_semantics.gd` | routing goal 1.1: every intersection on both geometries, with the reason it is or is not drawn as a crossing, and the proof that sharing the classifier moved no count |
| `route-stability.json` | `route_stability.gd` | routing goal 2: which product pathway reads which geometry, how far a forty-unit nudge travels in each of them, every changed cable attributed, and whether connection order matters |
| `hit-geometry.json` | `hit_geometry.gd` | routing goal 2.1: 1,373 points on the displayed centreline of every cable, in both styles at three zooms, each of which must select its own cable; plus the upper strand at every crossing and a refusal on the hidden path |
| `geometry-owners.json` | `geometry_owners.gd` | routing goal 2.2: every metric under both cable styles and both geometries, the four trespass states, and whether each layout operation would have decided differently on the other one |
| `route-locality.json` | `route_locality.gd` | routing goal 3: where every candidate channel comes from, and whether an obstacle the router never consulted can still move a cable |
| `route-repair.json` | `route_repair.gd` | routing goal 3C: every reroute after a nudge, classified by whether the old route was still legal, broken in one place, or genuinely impossible to keep |
| `route-legality.json` | `route_legality.gd` | routing goal 4A: every blocked route the router returns, and whether a clear one was demonstrably available — by its own candidate list, by a splice, or by a grid walk that owes it nothing |

## The sheets, on demand

Not headless where it says so: headless has no rendering server, so there is nothing to
capture.

```bash
# every runtime type: class, narrowest valid width, the equation
INVENTORY_OUT=/tmp/p godot --headless --path editor-godot --script inventory.gd

# which class each type belongs in, by forcing it to each in turn
WIDTH_SHEET_OUT=/tmp/p godot --path editor-godot --script width_sheet.gd

# the glyph families at four sizes, and the eleven collision groups at the header cell
GLYPH_SHEET_OUT=/tmp/p godot --headless --path editor-godot --script glyph_sheet.gd

# twelve reserved identity cells, with three glyph-bearing headers for scale
RESERVED_SHEET_OUT=/tmp/p godot --path editor-godot --script reserved_sheet.gd

# eight state combinations on one node, and the three that must survive the bands
STATE_SHEET_OUT=/tmp/p godot --path editor-godot --script state_sheet.gd

# the detail ladder, every band boundary crossed at a hundredth either side
OPTICAL_SHEET_OUT=/tmp/p godot --path editor-godot --script optical_sheet.gd

# the dense graph: 26 pictures, 80 frames of machine checks
QA_SHEET_OUT=/tmp/p godot --path editor-godot --script qa_sheet.gd

# what a parameter says to the reader at each distance, and whether anything outlives FULL
godot --path editor-godot --script qa_reduced.gd

# the cable pass's baseline: routes, crossings, bundles, trespass, ink share
CABLE_BASELINE_OUT=/tmp/p godot --headless --path editor-godot --script cable_baseline.gd

# goal 1: none / halo / knockout / bump on the same-colour crossings, plus the ink
CROSSING_SHEET_OUT=/tmp/p godot --path editor-godot --script crossing_sheet.gd

# goal 2: five focus scenes at three suppression levels, plus the invariants
FOCUS_SHEET_OUT=/tmp/p godot --path editor-godot --script focus_sheet.gd

# every port on every runtime type, and which signal classes actually exist
SIGNAL_AUDIT_OUT=/tmp/p godot --headless --path editor-godot --script signal_audit.gd

# the blind test: shuffled endpoint-free crops, and a key not to open first
BLIND_CUES_OUT=/tmp/p godot --path editor-godot --script blind_cues.gd

# the gestures, through real input routing in a real window
godot --path editor-godot --script cable_gestures.gd

# the cable closure matrix: 278 invariants over both specimens
CABLE_CLOSURE_OUT=/tmp/p godot --path editor-godot --script cable_closure.gd

# the layout baseline: four patches, by hand against auto-place
LAYOUT_BASELINE_OUT=/tmp/p godot --path editor-godot --script layout_baseline.gd

# the crossing-cost frontier: what removing a crossing costs, by placement alone
CROSSING_FRONTIER_OUT=/tmp/p godot --headless --path editor-godot --script crossing_frontier.gd

# the routing baseline, on the fixtures the layout pass leaves behind
ROUTE_BASELINE_OUT=/tmp/p godot --headless --path editor-godot --script route_baseline.gd

# why the crossing counters disagree, and the proof that they no longer can
CROSSING_SEMANTICS_OUT=/tmp/p godot --headless --path editor-godot --script crossing_semantics.gd

# where a 40-unit edit lands, in both the drawn and the routed geometry
ROUTE_STABILITY_OUT=/tmp/p godot --headless --path editor-godot --script route_stability.gd

# is the cable you can see the cable you can touch?
HIT_GEOMETRY_OUT=/tmp/p godot --headless --path editor-godot --script hit_geometry.gd

# which geometry each consumer means, and whether the split changes a decision
GEOMETRY_OWNERS_OUT=/tmp/p godot --headless --path editor-godot --script geometry_owners.gd

# which obstacles are allowed an opinion about a cable, and whether that holds
ROUTE_LOCALITY_OUT=/tmp/p godot --headless --path editor-godot --script route_locality.gd

# when a cable had to move, did the edit require it to move that much?
ROUTE_REPAIR_OUT=/tmp/p godot --headless --path editor-godot --script route_repair.gd

# when the router returns a blocked route, was a clear one available?
ROUTE_LEGALITY_OUT=/tmp/p godot --headless --path editor-godot --script route_legality.gd
```

`crossing_semantics.gd` is on the push gate as well, and writes its record only when the
variable is set — a gate that leaves an untracked file behind every run is a gate people
start ignoring.

`route_baseline.gd` reads `qa/babble-tidied.json` and `qa/dense-graph-tidied.json`, which are
themselves derived rather than hand-edited. Regenerate those first if the layout operations
change underneath them:

```bash
godot --headless --path editor-godot --script tidy_fixtures.gd
```

`godot` is whatever `git config soundgraph.godot` names.

## What each sheet is for

| Sheet | The question |
|---|---|
| `glyph-proof.png` | do the marks form families, or are they one-off pictures? |
| `glyph-collisions.png` | does each confusable pair separate at the twenty-four pixel header cell? |
| `reserved-cells.png` | do twelve empty identity cells look intentional beside three that are filled? |
| `qa-<palette>-<scale>-<zoom>.png` | does the dense graph read at four distances in three environments? |
| `qa-grey-100.png`, `qa-grey-40.png` | which channels survive with the colour taken out? |

The grayscale pair is the one to keep looking at. Five of six channels survive it — socket
shape, socket fill, perimeter, header tint, identity — and the sixth is a cable's signal
type between its endpoints, which is hue-only and is the cable pass's problem.

## The rule this directory exists to enforce

A proof is a claim about a number or about a picture that can be made again. If a sheet
cannot be regenerated by one of the commands above, it is not a proof, it is a memory.
