# Design status

Where the desktop design work stands as the Cosmopolitan pass closes and the next
workstream — the web funnel — begins.

**The desktop is the reference implementation.** The web app is a marketing funnel, not
feature parity. Where the two disagree about how something looks, the desktop is right and
`docs/design-tokens.json` is how to find out what it does.

---

## Frozen systems

Four passes are closed. Each has an authoritative document, proofs that regenerate, and a
bar for reopening it. **None may be reopened without measured evidence meeting that bar.**

| System | Authority | Proof | Reopening bar |
|---|---|---|---|
| Graph nodes | `docs/graph-node-system.md` | `dense-graph-qa.json`, glyph and reserved-cell sheets | A defect visible in the eighty-frame QA matrix, or a node that cannot be laid out by `LayoutFit.complaints()` |
| Cables | `docs/graph-cable-system.md` | `cable-closure.json` — 278 invariants over two specimens, four zooms, two palettes | A closure-matrix failure, or a reader who cannot tell a crossing from a junction in the blind test |
| Layout | `docs/layout.md` | `layout-baseline.json`, `crossing-frontier.json`, `legalize_test`, `tidy_test` | A tier-1 fault the legalizer cannot clear, or an operation that is not idempotent |
| Geometry ownership | `docs/routing.md` §2.1–2.4 | `geometry-owners.json`, `hit-geometry.json`, `geometry_contract_test` | A consumer reading a geometry it cannot justify, with the disagreement measured |

The contracts those four settled, in one place:

> **A cable's interactive locus is the centreline actually displayed by the active cable
> style.**
>
> **Structural placement metrics describe the graph, independent of presentation. Visual
> repair and visual cleanup describe the active presentation.**
>
> **Presentation may veto a structural improvement, but presentation never supplies the
> improvement objective.**
>
> **An obstacle may influence a cable's routing candidates only if that obstacle is
> geometrically relevant to reaching that cable's endpoints.**
>
> **A route has a validity result separate from its geometry. A least-blocked fallback must
> never be reported as legal merely because it is the best candidate found.**

---

## Known issues

Measured, reproducible, and **not** blocking the funnel. Each has a proof that regenerates.

| Issue | Size | Where |
|---|---|---|
| The router returns blocked routes during a drag | 249 of 4200 sampled states on the dense fixture; a clear route was available in **every one** | `route-legality.json` |
| A cable whose own port moves can lurch | worst 34.9x a forty-unit nudge, dense; 11.5x babble | `route-baseline.json` |
| Sympathetic reroutes that were avoidable | 16 babble / 31 dense per 92 and 120 probes, all attributable to a consulted obstacle | `route-repair.json` |
| `Tidy flow` places 2 nodes differently by cable style | babble and dense, one fixture each | `geometry_contract_test`, printed every run |
| Two crossing counters disagree by construction | catenary 7/26 against routed 10/44 — different drawings, both correct | `crossing-semantics.json` |
| Godot teardown segfault after a suite passes | roughly one suite in ten, always after the verdict | `docs/current-phase.md` |
| Detour tail | worst excess 822 units dense, 713 babble | `route-baseline.json` |

None of these is visible in a resting screenshot. That is not an accident of luck — it is
why the routing pass had to build perturbation harnesses at all.

---

## Deferred work

Explicitly parked to open the web funnel. Ordered by the evidence, not by appetite.

1. **4B — clear-route completion.** 45% of blocked results are the candidate cap hiding an
   answer already in the router's own list; 50% are reachable by a local splice. Diagnosed
   in full at `docs/routing.md` §4A.
2. **4C — honest reporting of impossible routes.** Nothing to report on current fixtures —
   `boxed in` is zero — so this is a contract without a case.
3. **Route stability, direct-endpoint half.** The 34.9x response.
4. **Local segment repair as a continuity technique.** Built once, reverted for breaking
   determinism; the write-up records what was tried so it is not tried again blind.
5. **Terminal approach.** The converging same-node/different-port meetings, 4 of babble's 10
   and 7 of dense's 44.
6. **Open-field crossing optimisation.**
7. **Detour optimisation.**

---

## Reopening criteria

A frozen system reopens on **measured evidence**, not on an opinion about a screenshot.
Concretely, one of:

- a **failing invariant** in that system's own proof — the closure matrix, the QA matrix,
  the geometry contract test, the legalizer or tidy suites;
- a **new specimen** that the system's own definition of correct cannot handle, added to the
  fixtures and failing there;
- a **measured disagreement** between two things that claim to describe the same object,
  in the shape of the 26-versus-42 crossing gap.

Not a reason: a preference, a new idea, or a screenshot somebody dislikes. The passes that
produced these systems each began with a baseline and changed one variable at a time, and
reopening one costs that again.

---

## Canonical proofs

`docs/proofs/canonical/` — regenerate with

```bash
cd editor-godot && godot --path . --script screenshot.gd -- --matrix ../docs/proofs/canonical-shots.json
```

| Shot | What it is for |
|---|---|
| `graph.png` | the working view, whole patch, fitted |
| `graph-cable-focus.png` | **the golden moment** — read beside `graph.png`: the control cables recede toward the canvas while the focused audio route keeps its ordinary resting appearance. Focus works because the noise leaves, not because the chosen route shouts |
| `graph-dense.png` | a dense patch at 40% |
| `rack.png` | the instrument |
| `schematic.png` | the signal path |
| `face.png` | the panel |

Everything else in `docs/proofs/` is a numeric record with a command that regenerates it;
`docs/proofs/README.md` is the index and states the rule those files exist to enforce.

---

## For the web implementation

`docs/design-tokens.json`, exported from the running desktop by
`editor-godot/design_tokens.gd` — five palettes, spacing, radii, type, node metrics and the
cable constants. **Do not hand-edit it, and do not re-type its values by eye**; a second set
of numbers is a second source of truth, and this project has spent whole goals on exactly
that mistake.

What the tokens deliberately do not carry is behaviour. The crossing knockout, focus
suppression, the detail ladder and the glyph grammar are rules about *when*, and they stay
in `docs/graph-node-system.md` and `docs/graph-cable-system.md`. A funnel almost certainly
wants the palette, the type and the cable colours; it almost certainly does not want the
LOD ladder.
