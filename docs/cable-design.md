# The Cable Renderer

The patch cable is a finished visual subsystem. It was arrived at in ten goals, each one
changing a single variable, each judged against a rendered comparison and approved before
the next began. This is the resulting grammar, the frozen figures, and — more usefully —
the reasoning and the wrong turns, so that a later change can tell which parts are
decisions and which are accidents.

The build order was the point. Every goal froze what came before it, so a comparison only
ever had one thing in it to disagree with, and "does this look better" never had to be
answered about six changes at once.

## The grammar

A cable is read outward from its own middle, and then along its length:

```
              directional glint          Goal 3
                    ↓
              saturated candy body       Goal 1
                    ↓
              darker same-hue shell      Goal 2
                    ↓
              seated cast shadow         Goal 4
```

```
socket hardware → cut-end mouth → colour collar → cord → crossing → collar → mouth
                  Goal 5                          Goal 1  Goal 8
```

and along its route: a deterministic hang of its own (Goal 6), a departure that separates
it from its neighbours (Goal 7), and a material response to the surface it lies on
(Goal 9).

## The frozen figures

Rack cords, and the graph's, share these. `CableArt.Style` carries the defaults; the two
cord styles set them.

```
body width                8.5   (10.0 traced)
body core                 0.84  of width; the rest is shell
shell darken              0.42  dark surface     0.55  light surface
shell offset              (1.3, 1.5)             — one geometry, both surfaces
glint width               1.5
glint offset              (-2.0, -2.3)
glint alpha               0.60  dark surface     0.38  light surface
shadow width              9.5
shadow offset             (2.0, 2.8)
shadow alpha              0.32  dark surface     0.30  light surface
hang variation            ±5% sag, ±3% apex bias, ±3° tangent, over a quarter span
departure splay           ±5°, alternating by anchor, over an eighth span
```

The light-surface column is *response strength only*. Hues, mass and every geometry are
the same on cream as on graphite: a cable keeps its identity and its silhouette earns the
contrast. Chartreuse decided those numbers — it is the closest of the palette to cream,
and the temptation is to darken the body until it separates, which turns it olive and
throws away the one thing it is for.

## What each goal settled, and what it got wrong first

**1 — Mass.** The material stack existed but every pass except the body was subliminal at
a 5px width. The code carried a description of juiciness; the pixels carried a spline.
Wrong first: claiming the richness was "buried by the plugs". Removing the plugs revealed
the stack's absence, not its presence.

**2 — The shell.** A crescent visible only where it peeked past the body became a shell
wrapping the whole cord, by narrowing the body into the envelope the offset edge already
defined. Nothing got wider.

**3 — The glint.** 2.2px read as a stripe painted along the tube; 1.5px pushed further
into the light reads as sheen on a curved surface.

**4 — The shadow.** At 0.2 alpha, black on a near-black canvas was a rumour and the cable
floated. Denser, tighter, offset opposite the glint, so the whole cable answers to one
light. Fixed here: the graph's shadow offset had never scaled with zoom.

**5 — The endpoint.** The transition carried four marks; the neck was a relic of the old
thin line and had become a second cable drawn over the first. Two marks remain: a cut-end
mouth and a colour collar seated in the socket ring.

**6 — The hang.** Sag was a pure function of span, so eight equal spans hung eight
identical curves. Seeded from endpoints quantised to a 4px grid — the first attempt used
raw floats and re-rolled a cable between runs on sub-pixel layout jitter, caught by
rendering twice and diffing.

**7 — The departure.** Adjacent occupied sockets alternate their release direction, so
neighbours are *guaranteed* to diverge rather than likely to. Its own term with its own
falloff: added to Goal 6's random lean it could be cancelled to two degrees of separation,
and it would have inherited a quarter-span reach when the goal was the departure alone.

**8 — Crossings.** Nothing needed changing; the test proved it. Occlusion plus a local
halo darkens the under-cable by 65% over about twenty pixels. Two renders differing only
in connection order differed in a 50×20 pixel region and nowhere else, which is the proof
that no geometry was mirrored or regenerated to fake it.

**9 — The surface.** `panel_is_light()` asked a fixed dark constant and had answered
"dark" for every patch ever loaded: the light-surface response was written, commented, and
had never once executed. See `Rack.cables_on_light_panel`.

**10 — Integration.** The finished cable in the real editor, both surfaces, three zooms,
every emphasis state. No change warranted.

## Known limitation

A cable is built once for its whole run, but it crosses cream panels *and* the dark canvas
in the gaps between rack rows. On Ivory Lab the near-black audio lead measures 1.43:1
against the canvas while it is in a gap, where its red neighbours measure 4.6:1. One lead,
one palette, the width of a rail.

It is recorded rather than fixed because every available fix reopens a settled decision —
the approved glint strength, the frozen palette, or the per-surface sampling deliberately
deferred as a larger rendering problem. When there is a broader reason to solve it, the
answer is local surface-aware rendering, not making Ivory's black cable grey.

## Testing

`examples/patches/cable-test.json` is the test card: two `CableTest` nodes, eight lanes,
each cable wearing one of the first eight cable colours in order, and playable so the
picture can be judged with the sound on. A rendering change that costs a colour its
identity shows up as two cables that suddenly match.

Note what it does *not* prove. `CableTest` overrides cable colour with the candy palette,
so it demonstrates that the renderer survives a light surface. That a *theme's own*
palette survives one is a different question, answered by loading a real Ivory Lab patch —
whose leads are black and red by design, not candy. Both tests are worth having, and the
first was briefly mistaken for the second.

The suite pins what the picture cannot: the palette walk per lane, that crossings are
detected at all, and that the crossing halo is wider than the body laid over it.
