class_name GlyphGrammar
extends RefCounted

## How a node identity glyph is constructed.
##
## Step 9 drew three marks — an amplifier triangle, a filter response, an envelope contour
## — and they worked. This file is the difference between three marks that worked and a
## system that can produce the fiftieth one: the rules those three obey, written down as
## numbers a later drawing can be built from rather than as an impression a later drawing
## has to be judged against.
##
## Nothing here is a picture. The pictures are in `icons.gd`, which is where ink meets an
## image; this is the coordinate system, the shared levels, and the family plans they are
## drawn from. A new glyph should be constructible from this file and the family table
## below without inventing anything, and where it cannot be, that is the finding — the
## grammar is short a rule, and the rule goes here rather than into the drawing.
##
## ## The contract
##
## Every identity glyph obeys all eight. They are not preferences.
##
## 1. One cell. The mark lives in a square inside the node header, ANATOMY_GLYPH across,
##    reserved whether or not the type has a mark yet. A header does not grow to hold one
##    and a title does not start in a different place because one is missing.
## 2. One coordinate system. `middle` is the centre of the cell and `reach` is
##    `size * 0.28`. Every coordinate in every glyph is written as middle plus or minus a
##    multiple of reach, so a mark drawn at 96 and a mark drawn at 10 are the same drawing.
## 3. One field. FIELD reach units from the centre, and no further. The corners of the
##    cell are not drawing room — they are the air that keeps neighbouring marks from
##    touching and that keeps a mark from looking bigger than the word beside it.
## 4. One weight. `Icons.STROKE`, at every size, for every mark. A single stroke weight is
##    most of what makes a set look like a set.
## 5. An optical cut, not a smaller drawing. Below `Icons.OPTICAL_SIZE` a mark may be
##    drawn differently — fewer segments, larger terminals, an opened counter — but it may
##    not be drawn smaller and hoped about. The cut is a redraw for the space, the way a
##    type designer cuts a face for eight point.
## 6. Identity ink, never a signal colour. Marks are drawn in `Design.INK_SECOND`. The
##    cable colours mean signal type; a lowpass is not green because audio is green, and
##    the day a mark borrows a semantic colour is the day the semantic colours stop
##    meaning anything.
## 7. The mark yields to the name. When the title falls to the compensation overlay, the
##    glyph goes with it. Legibility of the name outranks the presence of the mark,
##    always, and no mark may push a title into its compact form.
## 8. Behaviour, not hardware. A response curve rather than a filter; an amplifier symbol
##    rather than an amplifier. A drawing of equipment belongs in the rack, and this pass
##    has already had to walk back out of one.
## 9. Siblings differ in silhouette, not in a detail. A family is only useful if its
##    members are told apart as fast as the family is recognised, and at 24 pixels the
##    only thing that separates two marks is their outline. Mirroring is a silhouette;
##    inverting is a silhouette; removing one stroke is not. This rule is here because
##    the step 10 proof sheet found it the hard way, and `ROUTE_SWITCH` still fails it —
##    see `docs/node-glyph-grammar.md`.
##
## ## The families
##
## A family is a group of node types that share one drawing and differ by one
## transformation of it. That is what makes the set learnable: a reader who has met the
## lowpass has met the highpass, because the second is the first read the other way round,
## and nothing new had to be memorised.
##
## The grammar for each, semantically rather than as a list of pictures:
##
## [codeblock]
## Generators   waveform geometry — one cycle in the field
##              sine smooth, square cornered, saw ramped, noise unrepeating
## Filters      one response axis, two levels, transitions between them
##              lowpass falls, highpass rises, bandpass is a hill, notch is a valley
## Dynamics     amplitude transformed
##              gain the amplifier triangle, compressor a range converging,
##              limiter a signal meeting a ceiling
## Time         repetition along the horizontal
##              delay repeats, reverb repeats and decays, chorus displaces a copy
## Routing      terminals and the cords between them
##              split one to many, merge many to one, switch a selectable branch
## Control      the shape of a value over time
##              envelope the ADSR contour, LFO a slow wave, clock a pulse train,
##              sequencer discrete steps
## [/codeblock]
##
## Two of the six are drawn and proved — filters and routing, on the sheet
## `glyph_sheet.gd` renders. The other four are grammar only, on purpose: the point of
## this step was to show that families can be constructed, not to spend it drawing forty
## pictures nobody has asked for yet.
##
## ## What is deliberately not here
##
## Activity state. The Noun Project search behind step 9 turned up an envelope family
## (385861-385867) that draws the whole ADSR contour every time and solids only the
## segment being named, dashing the rest — identity kept, state added on top of it. It is
## the right idea and it is recorded in `docs/node-glyph-grammar.md`, not implemented,
## because a header mark that changes while the patch runs is interaction design and this
## file is meant to still be true afterwards.

## How far from the centre a mark may reach, in reach units. Read off the approved step 9
## specimens, which stand at 1.1 and 1.15 — the amplifier's leads are the widest thing in
## the set and they set the edge.
const FIELD := 1.15


# ---- the filter family ---------------------------------------------------------------
#
# One axis, two levels and the transitions between them, which is how a response is drawn
# on paper and how it was drawn for the lowpass in step 9. Everything below is that
# specimen, generalised: the levels are its levels, the span is its span, and the knee is
# where its knee was.

## The two levels a response sits at. Amplitude is up, so the passband is the negative one
## — screen coordinates run down.
const PASS := -0.5
const STOP := 0.85

## The span the curve is drawn across. Not symmetric, and it was not in the specimen
## either: a response reads left to right and wants a little more room to arrive than to
## depart.
const LEFT := -1.1
const RIGHT := 1.05

## Where the shoulder of a transition sits, as fractions measured from the passband end:
## along the transition in x, and toward the stop level in y.
##
## The knee belongs to the passband. A real filter leaves its passband gently and arrives
## at its stopband steeply, and because the level fraction (0.44) is under the along
## fraction (0.55) that is exactly what this draws — the curve hangs above its own chord.
## Anchoring at the pass end rather than at the left end is what makes the rule survive
## mirroring: the highpass gets the same gentle departure, on the other side.
##
## Read off the step 9 lowpass, whose shoulder was placed by hand at 0.547 and 0.444.
const KNEE_ALONG := 0.55
const KNEE_LEVEL := 0.44

## The four responses, as level plans: a list of [x, level] breakpoints in reach units,
## always in ascending x. Consecutive points at one level are a flat run; points at
## different levels are a transition, and polyline() puts the shoulder in.
##
## The lowpass is the step 9 specimen unchanged. The highpass is it mirrored. The bandpass
## and the notch are the same two levels with a plateau in the middle, at one width, so
## that the pair reads as one shape and its inverse rather than as two drawings.
const RESPONSE_LOW := [[LEFT, PASS], [0.1, PASS], [RIGHT, STOP]]
const RESPONSE_HIGH := [[LEFT, STOP], [-0.15, PASS], [RIGHT, PASS]]
const RESPONSE_BAND := [[LEFT, STOP], [-0.18, PASS], [0.18, PASS], [RIGHT, STOP]]
const RESPONSE_NOTCH := [[LEFT, PASS], [-0.18, STOP], [0.18, STOP], [RIGHT, PASS]]


# ---- the control family ---------------------------------------------------------------

## The ADSR contour, as the four segments it is made of: attack, decay, sustain, release.
##
## Five points and four segments, which is the whole reason this is written down rather
## than drawn inline — the segments are named things, and a mark that wants to say which
## one is running needs to be able to ask for the third one by number.
##
## The peak is left of centre and the sustain is a plateau above the baseline, which is
## what separates this from the bandpass's symmetric arch. They are the closest pair in
## the set and the asymmetry is the whole of the difference.
const ENVELOPE_CONTOUR := [Vector2(-1.1, 0.8), Vector2(-0.45, -0.8), Vector2(0.0, -0.1),
	Vector2(0.5, -0.1), Vector2(1.1, 0.8)]
enum Stage { ATTACK, DECAY, SUSTAIN, RELEASE }


## A level plan expanded into the polyline to stroke, in reach units from the centre.
##
## The small cut is rule 5 doing its work: below the optical size a transition is one
## straight ramp. The shoulder of a curve is a pixel and a half at header size and reads
## as a kink rather than as a corner, so at that size it is not drawn at all. Direction is
## the whole message down there, and direction is what survives.
static func polyline(plan: Array, small: bool) -> Array:
	var points: Array = [Vector2(plan[0][0], plan[0][1])]
	for i in plan.size() - 1:
		var a := Vector2(plan[i][0], plan[i][1])
		var b := Vector2(plan[i + 1][0], plan[i + 1][1])
		if not small and not is_equal_approx(a.y, b.y):
			# The pass end anchors the knee, whichever end of the transition it is.
			var from_pass := is_equal_approx(a.y, PASS)
			var pass_end := a if from_pass else b
			var stop_end := b if from_pass else a
			points.append(Vector2(
				pass_end.x + (stop_end.x - pass_end.x) * KNEE_ALONG,
				PASS + (STOP - PASS) * KNEE_LEVEL))
		points.append(b)
	return points


## One cycle of a sawtooth, as the generator family draws a waveform: the shape the node
## actually makes, in the field, at the field's own width.
##
## A saw and not a sine because this type is a `SawOscillator`. That is the generator
## family's whole rule — the mark is the waveform — and it is what keeps the oscillator
## and the modulator apart without either of them wearing a distinguishing decoration.
## The corpus agrees: every sawtooth in the Noun Project's signal-processing collections
## is this drawing.
const SAW_CONTOUR := [Vector2(-1.1, 0.72), Vector2(0.0, -0.72), Vector2(0.0, 0.72),
	Vector2(1.1, -0.72)]

## And at header size, one tooth instead of two. Two ramps and a vertical inside fifteen
## pixels is a hatched box; one ramp with its return is still unmistakably a saw.
const SAW_SMALL := [Vector2(-1.0, 0.72), Vector2(0.45, -0.72), Vector2(0.45, 0.72),
	Vector2(1.05, -0.28)]

## A slow modulation, as one large smooth cycle.
##
## The control family's mark for a thing that moves other things. Angular against smooth
## is what separates it from the oscillator, and that is a silhouette rather than a
## detail — rule 9 — which is also where the corpus landed on its own: every icon filed
## under "modulation" is a sinuous curve and every one under "sawtooth" is a ramp.
##
## Sampled rather than arced so the two ends leave the field horizontally, the way a wave
## drawn on paper does.
const MODULATION_AMPLITUDE := 0.78
const MODULATION_SPAN := 1.1
const MODULATION_SEGMENTS := 14


## The modulation wave, as points in reach units.
static func modulation(small: bool) -> Array:
	var points: Array = []
	var steps: int = 9 if small else MODULATION_SEGMENTS
	for i in steps + 1:
		var t := float(i) / float(steps)
		var x := lerpf(-MODULATION_SPAN, MODULATION_SPAN, t)
		points.append(Vector2(x, -sin(t * TAU) * MODULATION_AMPLITUDE))
	return points


# ---- the routing family --------------------------------------------------------------
#
# Terminals and the cords between them, which is what the reader is already looking at:
# the graph itself is discs on the perimeter of boxes with lines between them, and a
# routing mark is that picture at glyph size. Nothing else in the icon set is made of
# discs joined by strokes, so the family is legible as a family before any one of its
# members is read.

## A terminal, and the junction where cords meet. The junction is smaller on purpose: it
## is a place on a cord rather than a place a cord ends, and three strokes meeting with
## nothing at the meeting close up into a plain arrowhead.
const TERMINAL := 0.30
const JUNCTION := 0.24

## How far out a terminal sits, and how far a fan spreads from the centre line.
const TERMINAL_X := 0.92
const FAN_Y := 0.62

## Where the junction sits, as a distance from the centre toward the single-terminal side.
## The fan is two discs and the trunk is one, so the mark balances by giving the heavier
## end less room.
const JUNCTION_X := 0.08

## Below the optical size the terminals grow and the cords shorten. The nodes have to be
## the biggest thing in the mark for the mark to be about nodes — the rail's split glyph
## learned this the hard way, where keeping the large span gave the ports two pixels each
## and produced a chevron with a dot on it.
const SMALL_TERMINAL := 0.40
const SMALL_TERMINAL_X := 0.70
const SMALL_FAN_Y := 0.56


## The routing geometry for a size band: [terminal radius, terminal x, fan y].
static func routing(small: bool) -> Array:
	if small:
		return [SMALL_TERMINAL, SMALL_TERMINAL_X, SMALL_FAN_Y]
	return [TERMINAL, TERMINAL_X, FAN_Y]
