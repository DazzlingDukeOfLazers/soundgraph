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
## 7a. Identity is what the node *is*, and a very few types have more than one. A type may
##    declare **one** discrete parameter whose values change the operation it performs,
##    and choose a mark for each — a state-variable filter set to notch is not doing what
##    a lowpass does. `NodeIdentity.VARIANT` is the whole mechanism and it is deliberately
##    narrow: the general rule "a glyph may depend on a parameter" would let any moving
##    value drive identity, and identity would stop being identity. The name never
##    varies; only the mark and the control that sets it.
## 8. Behaviour, not hardware. A response curve rather than a filter; an amplifier symbol
##    rather than an amplifier. A drawing of equipment belongs in the rack, and this pass
##    has already had to walk back out of one.
## 9b. The open field is full, and a new concept that wants another curve has to prove
##    it. Fifteen of these marks are a line doing something across the same square —
##    waveforms, responses, contours, transfer functions — and by step 14F three
##    candidates in one batch failed against marks that were already there. A drawing
##    whose distinction from an existing one is a kink, a plateau, an extra peak or one
##    stroke is not a new mark. Reach instead for **enclosure, topology, an object
##    boundary, repeated structure or a spatial relationship** — the sample's brackets
##    and the operators' ring are both that — or reserve the cell.
## 9c. Empty is part of the vocabulary. A reserved cell is a finished state, not an
##    unfinished one: Phaser, Allpass, Clip, Abs and MinMax all ship without a mark and
##    look restrained rather than broken, because the cell is reserved either way and the
##    name is doing the work. Coverage is not the quality metric; honesty is. A mark that
##    is nearly right is worse than none, because it teaches the reader something untrue
##    and they have no way to find out.
## 9a. Repetition count is silhouette. How many times a shape repeats inside the field is
##    part of its outline, not a detail on it — two cycles of a sine and one cycle of a
##    sine are told apart instantly and neither is wearing a badge. This is what separates
##    an oscillator from an LFO, and it is true as well as convenient: one runs at audio
##    rate and the other does not. It should generalise to the temporal family, where a
##    clock, a pulse train and a delay are all the same idea at different densities.
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

## How many cycles a generator's waveform is drawn with, against the one a control mark
## gets.
##
## This is the rule that keeps a sine oscillator apart from an LFO, and it is the first
## thing the rollout demanded that the three specimens had not already taught. Both marks
## are a sine; what differs is that a generator's waveform *repeats* and a modulation is
## one slow excursion. Two ripples against one broad curve is a silhouette — the shape's
## own frequency — rather than a badge stuck on one of them.
##
## It is also true rather than decorative: an oscillator runs at audio rate and an LFO
## does not, and the marks say exactly that.
const GENERATOR_CYCLES := 2.0
const CONTROL_CYCLES := 1.0

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


## A sine, as points in reach units, over however many cycles the family asks for.
static func sine(cycles: float, small: bool) -> Array:
	var points: Array = []
	var steps := int((9 if small else MODULATION_SEGMENTS) * cycles)
	for i in steps + 1:
		var t := float(i) / float(steps)
		var x := lerpf(-MODULATION_SPAN, MODULATION_SPAN, t)
		points.append(Vector2(x, -sin(t * TAU * cycles) * MODULATION_AMPLITUDE))
	return points


## The modulation wave: one slow excursion, which is what an LFO is.
static func modulation(small: bool) -> Array:
	return sine(CONTROL_CYCLES, small)


## A square wave, two cycles, as the generator family draws one. Corners against the
## sine's curve and the saw's ramp: three waveforms, three outlines, no badges.
static func square(small: bool) -> Array:
	var points: Array = []
	var high := -MODULATION_AMPLITUDE
	var low := MODULATION_AMPLITUDE
	var steps := int(GENERATOR_CYCLES * 2.0)
	var span := MODULATION_SPAN * 2.0 / float(steps)
	var y := high
	points.append(Vector2(-MODULATION_SPAN, y))
	for i in steps:
		var x := -MODULATION_SPAN + span * float(i + 1)
		points.append(Vector2(x, y))
		if i < steps - 1 or not small:
			y = low if is_equal_approx(y, high) else high
			points.append(Vector2(x, y))
	return points


## Noise, as the one waveform with no period: excursions of unequal height, drawn as bars
## standing off a centre line rather than joined into a run.
##
## Joined up they are a zigzag, and at header size a zigzag is the sine's ripple — the two
## were indistinguishable on the first proof sheet. Bars say the thing that actually
## separates noise from every other waveform, which is that no two excursions are alike
## and none of them follows from the last.
##
## Written down rather than generated: a glyph that is different every time it is drawn is
## not a glyph. Six at full size and four at header size, because six bars inside fifteen
## pixels merge into a block.
const NOISE_BARS := [0.55, 0.92, 0.30, 0.72, 0.44, 0.85]
const NOISE_BARS_SMALL := [0.5, 0.92, 0.34, 0.75]


# ---- the temporal family --------------------------------------------------------------
#
# Everything here is a value over time, which is also what the envelope and the modulation
# wave are. What separates the members is **density and regularity**, not decoration:
#
#   repeated smooth cycles     a generator, running at audio rate
#   one broad cycle            a modulator, running under it
#   repeated equal pulses      a clock: regular, discrete, and it only says when
#   unequal bars               noise: no two alike and none following from the last
#   a joined staircase         sample and hold: a continuous signal held between samples
#   separated blocks           a sequencer: a list of discrete values, not a signal
#   one diagonal               a slide: the whole mark is the transition
#   one flat line              a constant: the value that does not change
#
# Two devices do most of the work and both are honest. **Regular against irregular** tells
# a clock from noise and a sequencer from a sample-and-hold. **Joined against separated**
# tells a held signal from a list of values, which is exactly the difference between them.

## A clock: equal pulses on a baseline, evenly spaced. Regularity is the whole message,
## which is why the heights are all the same where the noise mark's are not.
const CLOCK_PULSES := 3
const CLOCK_PULSES_SMALL := 2
const CLOCK_WIDTH := 0.16

## And at header size a pulse is one upright rather than a narrow box. Sixteen hundredths
## of a reach is two pixels there, which is the stroke weight — so the pulse's two edges
## and its top filled into a block, and three blocks on a line read as a square wave. A
## baseline with uprights standing on it is what a clock reduces to, and it keeps the one
## thing that separates it from every other rectangular mark in the set: the baseline.
const CLOCK_WIDTH_SMALL := 0.0

## Sample and hold: a staircase of unequal treads, joined, because the signal is
## continuous and merely held. Written down rather than generated — a glyph that is
## different every time it is drawn is not a glyph.
const HELD_STEPS := [-0.30, 0.62, -0.72, 0.20]
const HELD_STEPS_SMALL := [-0.35, 0.65, -0.70]

## A sequencer: the same idea separated. A list of discrete values is not a signal, and
## drawing the risers would say it was.
const STEP_VALUES := [0.55, -0.25, 0.80, -0.60, 0.15]
const STEP_VALUES_SMALL := [0.55, -0.30, 0.75]


## The clock's pulses, as pairs of points to stroke: the baseline, then up, along, down.
static func clock(small: bool) -> Array:
	var runs: Array = []
	var count: int = CLOCK_PULSES_SMALL if small else CLOCK_PULSES
	var width: float = CLOCK_WIDTH_SMALL if small else CLOCK_WIDTH
	var base := MODULATION_AMPLITUDE * 0.85
	var top := -base
	runs.append([Vector2(-MODULATION_SPAN, base), Vector2(MODULATION_SPAN, base)])
	for i in count:
		var centre := lerpf(-0.72, 0.72,
			0.5 if count == 1 else float(i) / float(count - 1))
		runs.append([Vector2(centre - width, base),
			Vector2(centre - width, top)])
		runs.append([Vector2(centre - width, top),
			Vector2(centre + width, top)])
		runs.append([Vector2(centre + width, top),
			Vector2(centre + width, base)])
	return runs


## The held staircase: treads joined by risers.
static func held(small: bool) -> Array:
	var treads: Array = HELD_STEPS_SMALL if small else HELD_STEPS
	var points: Array = []
	for i in treads.size():
		var from := lerpf(-MODULATION_SPAN, MODULATION_SPAN,
			float(i) / float(treads.size()))
		var to := lerpf(-MODULATION_SPAN, MODULATION_SPAN,
			float(i + 1) / float(treads.size()))
		var y: float = float(treads[i]) * MODULATION_AMPLITUDE
		points.append(Vector2(from, y))
		points.append(Vector2(to, y))
	return points


## The sequencer's steps: the same treads with the risers taken away.
static func steps(small: bool) -> Array:
	var values: Array = STEP_VALUES_SMALL if small else STEP_VALUES
	var runs: Array = []
	var width := MODULATION_SPAN * 2.0 / float(values.size())
	for i in values.size():
		var from := -MODULATION_SPAN + width * float(i) + width * 0.16
		var to := -MODULATION_SPAN + width * float(i + 1) - width * 0.16
		var y: float = float(values[i]) * MODULATION_AMPLITUDE
		runs.append([Vector2(from, y), Vector2(to, y)])
	return runs


## A comb's response: the notch, repeated. And a formant's: the bandpass peak, repeated.
##
## Neither is a new family. A comb filter puts periodic notches in a spectrum and a
## formant filter puts two or three resonances in it, so both are the response grammar
## with rule 9a applied — repetition count is silhouette. One dip is a notch and three
## dips are a comb; one peak is a bandpass and three peaks are a formant.
##
## They are also each other's inverse, the way the notch and the bandpass are: dips in a
## line that is otherwise passing, against peaks rising out of a line that is otherwise
## not. That is the same pair of shapes the filter family already trades in, which is the
## point of having a family.
##
## Drawn directly rather than through `polyline()`, because the knee rule is about a
## single transition between two bands and these are a row of narrow features. A shoulder
## on each side of three dips inside fifteen pixels is a solid bar.
const RESONANCES := 3
const RESONANCES_SMALL := 2
## How much of each feature's slot the feature itself takes. Below about a third the dips
## close up into hairlines at header size and the mark reads as a plain flat line.
const FEATURE_WIDTH := 0.46


## A row of dips (a comb) or of peaks (a formant), as points in reach units.
static func resonances(small: bool, peaks: bool) -> Array:
	var count: int = RESONANCES_SMALL if small else RESONANCES
	var rest: float = STOP if peaks else PASS
	var reach_to: float = PASS if peaks else STOP
	var points: Array = [Vector2(LEFT, rest)]
	var span := (RIGHT - LEFT) / float(count)
	for i in count:
		var middle := LEFT + span * (float(i) + 0.5)
		var half := span * FEATURE_WIDTH * 0.5
		points.append(Vector2(middle - half, rest))
		points.append(Vector2(middle, reach_to))
		points.append(Vector2(middle + half, rest))
	points.append(Vector2(RIGHT, rest))
	return points


## A delay: the same event again, later and smaller.
##
## Deliberately close to the clock and deliberately not it. Both are uprights on a
## baseline, because both are events in time; what separates them is that a clock's are
## all the same height and a delay's fall away. Regular means generated, decaying means
## repeated — and that is the whole difference between the two nodes.
const ECHO_HEIGHTS := [1.0, 0.6, 0.32]
const ECHO_HEIGHTS_SMALL := [1.0, 0.5]


## A sample: a bounded piece of signal.
##
## The enclosure is the whole idea and it is brackets rather than a box, because a box at
## header size fills in — the keyboard proved that, three ways. Two uprights leave the
## interior open and the marks that say "bounded" are on the outside of the content
## instead of around it.
##
## It is also the first mark in the set to use enclosure for identity rather than a curve,
## which is where the saturation rule says new concepts have to go.
const SAMPLE_BOUNDS := 1.05
const SAMPLE_HEIGHT := 0.9
const SAMPLE_SPAN := 0.62
const SAMPLE_AMPLITUDE := 0.55


## The signal inside the brackets: one cycle, kept well clear of them.
## Narrower and shallower at header size, and half a cycle instead of a whole one. At the
## full span the wave's ends touch the brackets and the three marks weld into one blob —
## what has to survive is that there is *something* between two bounds, not which wave.
const SAMPLE_SPAN_SMALL := 0.42
const SAMPLE_AMPLITUDE_SMALL := 0.5


static func sampled(small: bool) -> Array:
	var points: Array = []
	var steps := 8 if small else 14
	var span: float = SAMPLE_SPAN_SMALL if small else SAMPLE_SPAN
	var high: float = SAMPLE_AMPLITUDE_SMALL if small else SAMPLE_AMPLITUDE
	var cycles := 0.5 if small else 1.0
	for i in steps + 1:
		var t := float(i) / float(steps)
		points.append(Vector2(lerpf(-span, span, t),
			-sin(t * TAU * cycles) * high))
	return points


# ---- the maths family -----------------------------------------------------------------
#
# Where the corpus rollout stops being able to borrow. These four are transfer functions —
# what comes out for what goes in — and a transfer function is a real drawing rather than a
# symbol, which is what keeps them clear of the chrome. A bare mathematical sign at
# twenty-four pixels is an application command; a curve is not.
#
# The one place notation survives is inside a ring, which Add and Multiply established and
# which is not extended here: there is no Subtract, Divide or Negate type in the registry
# to extend it with.

## Clip: the transfer curve of a bounded signal. Flat at the floor, straight through the
## middle, flat at the ceiling.
##
## Corner to corner on purpose. The highpass response is also flat-rise-flat and the
## difference is where the flats sit: a response moves between two bands a third of the
## field apart, and a clip runs the whole diagonal of it.
const CLIP_CURVE := [Vector2(-1.1, 0.85), Vector2(-0.55, 0.85), Vector2(0.55, -0.85),
	Vector2(1.1, -0.85)]

## And the second attempt: the *output* rather than the transfer function. A wave with its
## peaks flattened is what clipping looks like on a scope, and it is in the waveform family
## rather than the response family — which is the collision the transfer curve could not
## get out of, because flat-ramp-flat is also the highpass.
const CLIP_FLAT := 0.62

## Abs: the same signal with its negative half folded up. Two humps on a baseline, which
## is what full-wave rectification actually looks like on a scope.
const ABS_HUMPS := 2

## Compare: a signal crossing a threshold. The level runs the width of the field and the
## signal climbs through it, which is the whole of what the node does — everything above
## the line is a one and everything below it is a zero.
const COMPARE_LEVEL := 0.0
const COMPARE_RISE := 0.9

## MinMax: which of two signals is taken. Two lines crossing, and the mark is the envelope
## of the one that wins — the upper for maximum, the lower for minimum. A mirror pair, the
## way the highpass and the lowpass are, and a genuine identity variant because changing
## the mode changes the operation.
const MINMAX_REACH := 0.92


## The rectified humps, as points in reach units.
## A clipped wave: a sine with the top and bottom taken off, over two cycles like every
## other waveform in the generator family.
static func clipped(small: bool) -> Array:
	var points: Array = []
	var cycles := 1.0 if small else GENERATOR_CYCLES
	var steps := int((10 if small else 18) * cycles)
	for i in steps + 1:
		var t := float(i) / float(steps)
		points.append(Vector2(lerpf(-1.1, 1.1, t),
			clampf(-sin(t * TAU * cycles) * MODULATION_AMPLITUDE * 1.6,
				-CLIP_FLAT, CLIP_FLAT)))
	return points


static func rectified(small: bool) -> Array:
	# Two humps at every size. One hump is an arch, and an arch is the bandpass — the
	# whole of what says rectification is that the humps *repeat* on one side of a line.
	var humps: int = ABS_HUMPS
	var points: Array = []
	var steps := 10 * humps
	var base := 0.8
	for i in steps + 1:
		var t := float(i) / float(steps)
		points.append(Vector2(lerpf(-1.1, 1.1, t),
			base - absf(sin(t * PI * float(humps))) * 1.6))
	return points


## The envelope of two crossing signals: the upper one for maximum, the lower for minimum.
static func extremum(upper: bool) -> Array:
	var peak: float = -MINMAX_REACH if upper else MINMAX_REACH
	return [Vector2(-1.1, -peak), Vector2(0.0, peak), Vector2(1.1, -peak)]


# ---- the combining family -------------------------------------------------------------
#
# What happens where signals meet. The signal-flow conventions, which are a family already
# and have been since somebody first drew a block diagram: a ring with a cross in it is a
# multiplier and a ring with a plus in it is a summing junction. Same ring, different
# content, and nothing else in the set is a ring with something inside it.
#
# Drawn rather than borrowed from the icon set's existing cross, which is a dismiss
# button: a node wearing the same mark as a close control is a node somebody will try to
# close.

## The ring, and how far the mark inside it reaches. The content is kept well clear of the
## ring so that at header size the two do not weld into a filled disc.
const JUNCTION_RING := 0.95
const JUNCTION_MARK := 0.5

## At header size the ring **stays** and the mark inside it shrinks instead.
##
## Dropping the ring was tried first and it was wrong for one specific reason: a bare
## cross at twenty-four pixels is the dismiss button, stroke for stroke, and a node
## wearing a close control is a node somebody will try to close. The ring is the part
## that says diagram rather than interface, so the ring is the part that cannot go.
const JUNCTION_MARK_SMALL := 0.42


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
