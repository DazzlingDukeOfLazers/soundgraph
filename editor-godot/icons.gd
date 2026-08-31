class_name Icons
extends RefCounted
## A small icon set, drawn rather than typed.
##
## The editor was using Unicode symbols as icons — ▸ for disclosure, ● for unsaved, ✓ for
## valid, ■ for silence, ▶ for fire. Seven of the twelve are not in Atkinson Hyperlegible
## Next, so they rendered as tofu boxes, and nothing in the build said so: a missing glyph
## is not an error, it is a rectangle. Software with little boxes in it reads as unfinished
## no matter how much care went into everything else.
##
## Drawn here instead, for three reasons beyond fixing that. They scale with the UI scale
## rather than with whatever size the font happens to draw a symbol at. They take a colour,
## so an icon can sit in the ink ladder like everything else. And they cannot go missing —
## there is no font, no icon file and no dependency to fail to load.
##
## Kept deliberately plain: one stroke weight, one grid, no detail that survives being 14px
## on a projector. `icons_test.gd` renders every one and checks it actually marks pixels,
## because an icon that silently draws nothing is the same failure in a new hat.

## Consistent across the set. A single weight is most of what makes an icon set look like a
## set rather than a collection.
const STROKE := 2.0

## Below this, a glyph may be drawn differently rather than smaller.
##
## Optical sizing, which is what a type designer does when a face is cut for eight point:
## not the same drawing scaled down, but the same idea drawn for the space it has. Three
## marks here take it up. A junction of three lines at menu size is a chevron; the eye's
## two lids close on its pupil; the grid's four cells shrink until the space between them
## is what you see. The rest scale honestly, because they were simple enough to.
const OPTICAL_SIZE := 30

static var _cache: Dictionary = {}


enum Kind {
	CARET_RIGHT,    ## disclosure, closed
	CARET_DOWN,     ## disclosure, open
	DOT,            ## unsaved changes
	TICK,           ## valid
	STOP,           ## panic / silence
	PLAY,           ## fire a one-shot
	CHEVRON_LEFT,   ## collapse a panel
	CHEVRON_RIGHT,  ## expand a panel
	ARROW_RIGHT,    ## signal flow
	UNDO,           ## curved arrow, left
	REDO,           ## curved arrow, right
	HAMBURGER,      ## the everything-else menu
	PAUSE,          ## the roll mid-run: press again to rest
	HEART,          ## loved — the reader's own mark, not the program's
	CROSS,          ## dismiss a panel

	# The Add Node browser's category rail. One family, drawn on the same grid at the
	# same weight as everything above — a category mark is there to be recognised as a
	# shape before it is read as a word, which nine borrowed styles cannot do.
	GRID,           ## everything there is
	WAVE,           ## oscillators — the smooth one
	FUNNEL,         ## filters
	ENVELOPE,       ## attack, decay, sustain, release
	ZIGZAG,         ## modulation — a wave with corners, so it is not the oscillator
	SPLIT,          ## utilities — one in, two out
	FADERS,         ## mixing
	ECHO,           ## effects
	PLUG,           ## MIDI and IO
	STEPS,          ## sequencers
	EXAMPLE,        ## a patch you can run
	BANK,           ## a library of them — shared by all three banks on purpose
	SEARCH,         ## the field at the top of the results

	# The node identity glyphs. A mark on a node header answers "what kind of signal
	# operation is this" before the title is read, so these describe behaviour rather
	# than equipment: a response curve, not a filter; a gain stage, not an amplifier
	# with a handle on it.
	RESPONSE_LOW,   ## a lowpass: flat, then falling
	GAIN_TRIANGLE,  ## a gain stage, as the amplifier symbol

	# Step 10's proof that the grammar makes families rather than one-off pictures. Two
	# of them, drawn but attached to nothing: the filter siblings, which are the lowpass
	# read the other three ways, and the routing siblings, which are the graph itself at
	# glyph size. Both are constructed from `GlyphGrammar` — every number they stand on
	# is written down there, not here.
	RESPONSE_HIGH,  ## a highpass: rising, then flat
	RESPONSE_BAND,  ## a bandpass: a hill
	RESPONSE_NOTCH, ## a notch: a valley
	ROUTE_SPLIT,    ## one terminal in, two out
	ROUTE_MERGE,    ## two in, one out
	ROUTE_SWITCH,   ## one in, two possible, one of them made

	# The four that finished First Synth.
	SAW_WAVE,       ## a sawtooth oscillator: the waveform it makes
	SINE_WAVE,      ## and a sine one
	SQUARE_WAVE,    ## and a square one
	NOISE_WAVE,     ## and the one with no period at all

	# The temporal family: value over time, told apart by density and regularity.
	PULSE_TRAIN,    ## a clock — equal pulses, evenly spaced
	HELD,           ## sample and hold — a joined staircase of unequal treads
	STEPS_ORDERED,  ## a sequencer — the same treads, separated, because it is a list
	SLIDE,          ## a glide — the whole mark is the transition
	SUM_JUNCTION,   ## signals added: the summing junction of every block diagram
	PRODUCT,        ## signals multiplied: the same ring with a cross in it
	FLAT,           ## a constant — the value that does not change
	MODULATION,     ## a slow wave that moves something else
	ORIGINATE,      ## the patch's edge, signal entering
	TERMINATE,      ## the patch's edge, signal leaving
	# A second gain candidate was drawn and thrown away: a signal line with a short
	# upright at one end and a tall one at the other, meaning "small in, large out". At
	# header size the two uprights and the line read as a plus sign. The triangle is the
	# amplifier symbol on every schematic ever printed, and it survives the size.

	# The seven doors of the main menu. Marks on the roots only: a menu whose every row
	# has a picture is a menu you read twice, and the doors are the rows the eye lands
	# on first. Same grid, same weight, same family as everything above.
	FOLDER,         ## File
	PENCIL,         ## Edit
	EYE,            ## View
	SPEAKER,        ## Audio
	QUESTION,       ## Help

	# Validity, on a node header. Not in a triangle: the triangle is four more strokes
	# in an eighteen-pixel cell and what survives of it at that size is a smudge with a
	# line in it. The bang alone is unambiguous, and which severity is carried by the
	# colour it is drawn in — warning amber, error red, neither of them anywhere near
	# the signal palette.
	ALERT,          ## something is wrong with this node
}


## An icon as a texture, cached by kind, size and colour.
static func get_icon(kind: int, size: int, colour: Color) -> Texture2D:
	var key := "%d:%d:%s" % [kind, size, colour.to_html(false)]
	if _cache.has(key):
		return _cache[key]

	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))
	var middle := (size - 1) * 0.5
	var reach := size * 0.28
	# Whether this is the small cut. Read once so a glyph can ask without repeating the
	# threshold, and so the threshold is written down in exactly one place.
	var small := size <= OPTICAL_SIZE

	match kind:
		Kind.CARET_RIGHT:
			_triangle(image, Vector2(middle - reach * 0.5, middle), reach, 0.0, colour)
		Kind.CARET_DOWN:
			_triangle(image, Vector2(middle, middle - reach * 0.5), reach, PI * 0.5, colour)
		Kind.PLAY:
			_triangle(image, Vector2(middle - reach * 0.4, middle), reach * 1.2, 0.0, colour)
		Kind.DOT:
			_disc(image, Vector2(middle, middle), reach * 0.75, colour)
		Kind.STOP:
			_box(image, Vector2(middle, middle), reach * 0.9, colour)
		Kind.TICK:
			_stroke(image, Vector2(middle - reach, middle),
				Vector2(middle - reach * 0.25, middle + reach * 0.7), colour)
			_stroke(image, Vector2(middle - reach * 0.25, middle + reach * 0.7),
				Vector2(middle + reach, middle - reach * 0.75), colour)
		Kind.CHEVRON_LEFT:
			_stroke(image, Vector2(middle + reach * 0.4, middle - reach),
				Vector2(middle - reach * 0.4, middle), colour)
			_stroke(image, Vector2(middle - reach * 0.4, middle),
				Vector2(middle + reach * 0.4, middle + reach), colour)
		Kind.CHEVRON_RIGHT:
			_stroke(image, Vector2(middle - reach * 0.4, middle - reach),
				Vector2(middle + reach * 0.4, middle), colour)
			_stroke(image, Vector2(middle + reach * 0.4, middle),
				Vector2(middle - reach * 0.4, middle + reach), colour)
		Kind.HAMBURGER:
			# Three bars, evenly spaced: the one glyph whose reading predates tooltips.
			for row: int in [-1, 0, 1]:
				var y := middle + reach * 0.7 * float(row)
				_stroke(image, Vector2(middle - reach, y), Vector2(middle + reach, y),
					colour)
		Kind.HEART:
			# Two lobes and a point — drawn, like everything here, because a font's
			# heart is the tofu incident waiting for its sequel.
			var lobe := reach * 0.52
			_disc(image, Vector2(middle - lobe * 0.92, middle - reach * 0.30), lobe, colour)
			_disc(image, Vector2(middle + lobe * 0.92, middle - reach * 0.30), lobe, colour)
			_triangle(image, Vector2(middle, middle + reach * 0.05), reach * 1.08,
				PI * 0.5, colour)
		Kind.GRID:
			# Bigger cells, further apart, at menu size: four squares of three pixels
			# read as a texture rather than as an arrangement of anything.
			var cell: float = reach * (0.38 if small else 0.3)
			var spread: float = reach * (0.62 if small else 0.55)
			for corner: Vector2 in [Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1),
					Vector2(1, 1)]:
				_box(image, Vector2(middle, middle) + corner * spread, cell, colour)
		Kind.WAVE:
			# One cycle, sampled. The oscillator mark and the modulation mark are the
			# same gesture with and without corners, which is the actual difference
			# between the two families.
			var previous := Vector2(middle - reach * 1.1, middle)
			for i in 10:
				var t: float = float(i + 1) / 10.0
				var point := Vector2(middle + reach * (t * 2.2 - 1.1),
					middle - sin(t * TAU) * reach * 0.72)
				_stroke(image, previous, point, colour)
				previous = point
		Kind.ZIGZAG:
			var corners: Array = [Vector2(-1.1, 0.5), Vector2(-0.55, -0.6),
				Vector2(0.0, 0.5), Vector2(0.55, -0.6), Vector2(1.1, 0.5)]
			for i in corners.size() - 1:
				_stroke(image, Vector2(middle, middle) + (corners[i] as Vector2) * reach,
					Vector2(middle, middle) + (corners[i + 1] as Vector2) * reach, colour)
		Kind.FUNNEL:
			_stroke(image, Vector2(middle - reach, middle - reach * 0.8),
				Vector2(middle + reach, middle - reach * 0.8), colour)
			_stroke(image, Vector2(middle - reach, middle - reach * 0.8),
				Vector2(middle, middle + reach * 0.1), colour)
			_stroke(image, Vector2(middle + reach, middle - reach * 0.8),
				Vector2(middle, middle + reach * 0.1), colour)
			_stroke(image, Vector2(middle, middle + reach * 0.1),
				Vector2(middle, middle + reach * 0.9), colour)
		Kind.ENVELOPE:
			_polyline(image, GlyphGrammar.ENVELOPE_CONTOUR, middle, reach, colour)
		Kind.SPLIT:
			if small:
				# Nodes and the cords between them, drawn as nodes. The junction reads
				# as a chevron once its three lines are eleven pixels long, and a
				# chevron says "next" rather than "patch".
				# Fat ports and short cords. The first cut kept the span of the large
				# glyph and gave the ports two pixels each, which is a chevron with a
				# dot on it — the nodes have to be the biggest thing in the mark for
				# the mark to be about nodes.
				var here := Vector2(middle - reach * 0.62, middle)
				for side: float in [-1.0, 1.0]:
					var there := Vector2(middle + reach * 0.66,
						middle + reach * 0.58 * side)
					_stroke(image, here, there, colour)
					_disc(image, there, reach * 0.4, colour)
				_disc(image, here, reach * 0.44, colour)
				return _finish(image, key)
			# One in, two out, with the junction marked. Without the dot the three
			# strokes close up into a plain arrowhead at rail size.
			var fork := Vector2(middle + reach * 0.1, middle)
			_stroke(image, Vector2(middle - reach * 1.1, middle), fork, colour)
			_stroke(image, fork, Vector2(middle + reach * 0.95, middle - reach * 0.7),
				colour)
			_stroke(image, fork, Vector2(middle + reach * 0.95, middle + reach * 0.7),
				colour)
			_disc(image, fork, reach * 0.26, colour)
		Kind.FADERS:
			# Three tracks with their caps at three heights. The caps are the whole
			# reading: three bare uprights is a barcode.
			var heights: Array = [-0.25, 0.35, -0.6]
			for track in 3:
				var x: float = middle + reach * (float(track) - 1.0) * 0.8
				_stroke(image, Vector2(x, middle - reach * 0.9),
					Vector2(x, middle + reach * 0.9), colour)
				_box(image, Vector2(x, middle + reach * float(heights[track])),
					reach * 0.3, colour)
		Kind.ECHO:
			var source := Vector2(middle - reach * 0.75, middle)
			_disc(image, source, reach * 0.28, colour)
			for ring: float in [0.7, 1.25]:
				_arc(image, source, reach * ring, -TAU * 0.16, TAU * 0.16, colour)
		Kind.PLUG:
			_arc(image, Vector2(middle, middle), reach * 0.95, 0.0, TAU, colour)
			for pin in 3:
				var angle: float = PI * (0.62 + 0.38 * float(pin))
				_disc(image, Vector2(middle, middle)
					+ Vector2(cos(angle), sin(angle)) * reach * 0.45,
					reach * 0.2, colour)
		Kind.STEPS:
			# A pattern, not a bar chart: two rows of cells, on and off, which is what a
			# step sequencer looks like from across the room.
			for step in 4:
				var x: float = middle + reach * (float(step) - 1.5) * 0.62
				var high: bool = step % 2 == 0
				_box(image, Vector2(x, middle + reach * (0.4 if high else -0.4)),
					reach * 0.26, colour)
		Kind.EXAMPLE:
			# A patch in a frame, with the play mark of the transport it runs under.
			var edge := reach * 0.95
			for pair: Array in [[-1, -1, 1, -1], [1, -1, 1, 1], [1, 1, -1, 1],
					[-1, 1, -1, -1]]:
				_stroke(image, Vector2(middle + edge * pair[0], middle + edge * pair[1]),
					Vector2(middle + edge * pair[2], middle + edge * pair[3]), colour)
			_triangle(image, Vector2(middle - reach * 0.16, middle), reach * 0.5, 0.0,
				colour)
		Kind.BANK:
			# Stacked plates. All three banks wear it: they are one family of thing, and
			# the word beside it is what says which.
			for plate in 3:
				var y: float = middle + reach * (float(plate) - 1.0) * 0.62
				var width: float = reach * (1.05 - 0.12 * float(plate))
				_stroke(image, Vector2(middle - width, y), Vector2(middle + width, y),
					colour)
		Kind.RESPONSE_LOW, Kind.RESPONSE_HIGH, Kind.RESPONSE_BAND, Kind.RESPONSE_NOTCH:
			# The response, drawn the way it is drawn on paper: flat across the band it
			# passes, a knee, and away down the stop end. Not a funnel — a funnel is a
			# picture of a filter, and this is a picture of what a filter does.
			#
			# Four marks, one drawing. The plan is a list of levels and the grammar puts
			# the knees in, which is the whole point of having a grammar: the highpass is
			# not a second opinion about what a filter looks like, it is the lowpass read
			# the other way round.
			_polyline(image, GlyphGrammar.polyline(_response_plan(kind), small),
				middle, reach, colour)
		Kind.GAIN_TRIANGLE:
			# The amplifier symbol, which is what a gain stage is called on a schematic:
			# a triangle in the signal path, pointing the way the signal goes.
			_triangle(image, Vector2(middle - reach * 0.1, middle), reach * 1.0, 0.0,
				colour)
			_stroke(image, Vector2(middle - reach * 1.15, middle),
				Vector2(middle - reach * 0.6, middle), colour)
			_stroke(image, Vector2(middle + reach * 0.78, middle),
				Vector2(middle + reach * 1.15, middle), colour)
		Kind.SAW_WAVE:
			_polyline(image, GlyphGrammar.SAW_SMALL if small
				else GlyphGrammar.SAW_CONTOUR, middle, reach, colour)
		Kind.SINE_WAVE:
			_polyline(image, GlyphGrammar.sine(GlyphGrammar.GENERATOR_CYCLES, small),
				middle, reach, colour)
		Kind.SQUARE_WAVE:
			_polyline(image, GlyphGrammar.square(small), middle, reach, colour)
		Kind.NOISE_WAVE:
			# Not a polyline. Joined up, an irregular run of points is a zigzag, and at
			# header size a zigzag is the sine's ripple — the two were indistinguishable
			# on the proof sheet. Unequal bars standing off a centre line say the one
			# thing noise has to say, which is that no two excursions are alike, and they
			# say it without a line implying that they follow one another.
			var bars: Array = GlyphGrammar.NOISE_BARS_SMALL if small 				else GlyphGrammar.NOISE_BARS
			for i in bars.size():
				var x: float = middle + reach * lerpf(-1.05, 1.05,
					float(i) / float(bars.size() - 1))
				var height: float = reach * float(bars[i])
				_stroke(image, Vector2(x, middle - height), Vector2(x, middle + height),
					colour)
		Kind.PULSE_TRAIN:
			for run: Array in GlyphGrammar.clock(small):
				_stroke(image, Vector2(middle, middle) + (run[0] as Vector2) * reach,
					Vector2(middle, middle) + (run[1] as Vector2) * reach, colour)
		Kind.HELD:
			_polyline(image, GlyphGrammar.held(small), middle, reach, colour)
		Kind.STEPS_ORDERED:
			for run: Array in GlyphGrammar.steps(small):
				_stroke(image, Vector2(middle, middle) + (run[0] as Vector2) * reach,
					Vector2(middle, middle) + (run[1] as Vector2) * reach, colour)
		Kind.SUM_JUNCTION, Kind.PRODUCT:
			# The two signal-flow conventions, and they are a family: one ring, one mark
			# inside it. The ring is drawn at every size and the mark inside it shrinks
			# instead — a bare cross at header size is the dismiss button stroke for
			# stroke, and the ring is what says diagram rather than interface.
			var arm: float = GlyphGrammar.JUNCTION_MARK_SMALL if small \
				else GlyphGrammar.JUNCTION_MARK
			_arc(image, Vector2(middle, middle), reach * GlyphGrammar.JUNCTION_RING,
				0.0, TAU, colour)
			if kind == Kind.SUM_JUNCTION:
				_stroke(image, Vector2(middle - reach * arm, middle),
					Vector2(middle + reach * arm, middle), colour)
				_stroke(image, Vector2(middle, middle - reach * arm),
					Vector2(middle, middle + reach * arm), colour)
			else:
				var lean := reach * arm * 0.72
				_stroke(image, Vector2(middle - lean, middle - lean),
					Vector2(middle + lean, middle + lean), colour)
				_stroke(image, Vector2(middle + lean, middle - lean),
					Vector2(middle - lean, middle + lean), colour)
		Kind.SLIDE:
			# One diagonal, corner to corner. Not a rise between two flats — that is the
			# highpass, and a slide is not a response. The whole mark being the
			# transition is the point: nothing is held at either end.
			_stroke(image, Vector2(middle - reach * 1.05, middle + reach * 0.85),
				Vector2(middle + reach * 1.05, middle - reach * 0.85), colour)
		Kind.FLAT:
			# A value that does not change, drawn as exactly that. It looks like the least
			# a glyph can be and it is precisely what a constant is.
			_stroke(image, Vector2(middle - reach * 1.1, middle),
				Vector2(middle + reach * 1.1, middle), colour)
		Kind.MODULATION:
			# One cycle against the generators' two. A sine oscillator and an LFO are
			# both a sine and the difference is that one repeats: the shape's own
			# frequency is the silhouette, which is rule 9 and is also simply true.
			_polyline(image, GlyphGrammar.modulation(small), middle, reach, colour)
		Kind.ORIGINATE, Kind.TERMINATE:
			# The edge of the patch, and which side of it the signal is on. A bar is the
			# boundary; the line is the signal running to it or away from it.
			#
			# Not an arrow — the set has one already and it means flow rather than
			# destination — and not a speaker or a keyboard, because a seam is not the
			# equipment on the other side of it. What kind of signal crosses here is
			# said by the socket's own colour and shape, which is a channel that already
			# exists and does not need saying twice.
			#
			# One drawing mirrored, which is the same family rule that gave the highpass
			# and the merge: siblings differ by silhouette, and a mirror is a silhouette.
			var side: float = -1.0 if kind == Kind.ORIGINATE else 1.0
			_stroke(image, Vector2(middle - reach * 1.1 * side, middle),
				Vector2(middle + reach * 0.55 * side, middle), colour)
			_stroke(image, Vector2(middle + reach * 0.55 * side, middle - reach * 0.8),
				Vector2(middle + reach * 0.55 * side, middle + reach * 0.8), colour)
		Kind.ROUTE_SPLIT, Kind.ROUTE_MERGE, Kind.ROUTE_SWITCH:
			# Terminals and the cords between them — the graph itself, at glyph size.
			# Nothing else in the set is discs joined by strokes, so these read as a
			# family before any one of them is read as a member of it.
			var geometry := GlyphGrammar.routing(small)
			var terminal: float = geometry[0]
			var out_x: float = geometry[1]
			var fan_y: float = geometry[2]
			# The merge is the split mirrored, so one drawing serves both: `side` is
			# which way the fan points and everything else follows it.
			var side: float = -1.0 if kind == Kind.ROUTE_MERGE else 1.0
			var trunk := Vector2(middle - reach * out_x * side, middle)
			var junction := Vector2(
				middle + reach * GlyphGrammar.JUNCTION_X * side, middle)
			_stroke(image, trunk, junction, colour)
			for lean: float in [-1.0, 1.0]:
				var end := Vector2(middle + reach * out_x * side,
					middle + reach * fan_y * lean)
				# The switch draws one cord, not two. Two possible ways and one of them
				# made is what a switch is; a second cord would make it a split.
				# The switch draws one cord, not two. Two ways available and one of them
				# made is what a switch is; a second cord would make it a split.
				#
				# Two other ways of saying it were drawn and are worse. A stub on the
				# unmade branch — a cord that starts and stops — closes most of the gap it
				# is meant to open, and at header size the switch became the split exactly.
				# A blade that leans without arriving reads at 96 and loses the aim at 24.
				if kind != Kind.ROUTE_SWITCH or lean < 0.0:
					_stroke(image, junction, end, colour)
				_disc(image, end, reach * terminal, colour)
			_disc(image, trunk, reach * terminal, colour)
			_disc(image, junction, reach * GlyphGrammar.JUNCTION, colour)
		Kind.FOLDER:
			# The back plate and the tab that names a folder a folder.
			var top := middle - reach * 0.55
			var foot := middle + reach * 0.7
			_stroke(image, Vector2(middle - reach, top),
				Vector2(middle - reach, foot), colour)
			_stroke(image, Vector2(middle + reach, top + reach * 0.3),
				Vector2(middle + reach, foot), colour)
			_stroke(image, Vector2(middle - reach, foot),
				Vector2(middle + reach, foot), colour)
			_stroke(image, Vector2(middle - reach, top),
				Vector2(middle - reach * 0.15, top), colour)
			_stroke(image, Vector2(middle - reach * 0.15, top),
				Vector2(middle + reach * 0.1, top + reach * 0.3), colour)
			_stroke(image, Vector2(middle + reach * 0.1, top + reach * 0.3),
				Vector2(middle + reach, top + reach * 0.3), colour)
		Kind.PENCIL:
			# A shaft on the diagonal, a nib at the near end, a ferrule at the far one.
			# The shaft's two sides are offset along the perpendicular, which for a
			# diagonal running up-right is down-right. The first attempt offset them
			# along the shaft instead and drew one line twice.
			var nib := Vector2(middle - reach * 0.9, middle + reach * 0.9)
			var butt := Vector2(middle + reach * 0.85, middle - reach * 0.85)
			var across := Vector2(0.33, 0.33) * reach
			_stroke(image, nib + across, butt + across, colour)
			_stroke(image, nib - across, butt - across, colour)
			_stroke(image, butt + across, butt - across, colour)
			_triangle(image, nib + Vector2(-0.28, 0.28) * reach, reach * 0.5,
				TAU * 0.375, colour)
		Kind.EYE:
			# Two arcs meeting at the corners, and the pupil between them. Each lid is
			# the far side of a circle whose centre is on the other side of the eye:
			# sweeping the near side instead gave a pinched slot the size of the pupil.
			#
			# The small cut opens the lids and grows the pupil. Scaled down, the arcs
			# close to within a pixel or two of the pupil and the mark becomes one dark
			# smudge — a silhouette with a hole in it is the most an eye can be at this
			# size, so at this size that is what it is.
			# The lens opens by moving each lid's centre closer, not by growing it: the
			# first small cut left half a pixel of white between the lids and the pupil
			# and read as a flat slot.
			var lid: float = reach * (1.55 if small else 1.3)
			var away: float = reach * (1.0 if small else 0.9)
			var span: float = 0.4 if small else 0.44
			_arc(image, Vector2(middle, middle + away), lid,
				-TAU * span, -TAU * (0.5 - span), colour)
			_arc(image, Vector2(middle, middle - away), lid,
				TAU * (0.5 - span), TAU * span, colour)
			_disc(image, Vector2(middle, middle), reach * (0.4 if small else 0.3), colour)
		Kind.SPEAKER:
			# A driver and the air leaving it. The effects mark is a dot and two arcs;
			# this one has a body, which is the difference between a thing that sounds
			# and a thing that happens to a sound.
			# Throat, cone, air. Drawn as an outline rather than as a box behind a
			# triangle, which merged into an arrowhead and read as Play.
			_box(image, Vector2(middle - reach * 0.85, middle), reach * 0.26, colour)
			_stroke(image, Vector2(middle - reach * 0.6, middle - reach * 0.26),
				Vector2(middle - reach * 0.1, middle - reach * 0.8), colour)
			_stroke(image, Vector2(middle - reach * 0.6, middle + reach * 0.26),
				Vector2(middle - reach * 0.1, middle + reach * 0.8), colour)
			_stroke(image, Vector2(middle - reach * 0.1, middle - reach * 0.8),
				Vector2(middle - reach * 0.1, middle + reach * 0.8), colour)
			for ring: float in [0.62, 1.0]:
				_arc(image, Vector2(middle - reach * 0.05, middle), reach * ring,
					-TAU * 0.13, TAU * 0.13, colour)
		Kind.QUESTION:
			# The hook, the stem and the point, inside the ring that says "ask".
			# The mark without its ring. A circle round it left the hook four pixels
			# tall at the size a menu draws this, and a question mark you cannot read
			# is a smudge in a circle.
			# Angles increase clockwise on a screen, so the hook is swept from the left
			# up over the top and down the right — 0.5 of a turn to just past a whole
			# one. Sweeping to 0.09 instead took the long way under and drew a hook
			# hanging off the bottom, which reads as a letter nobody asked for.
			var pivot := Vector2(middle, middle - reach * 0.45)
			_arc(image, pivot, reach * 0.52, TAU * 0.5, TAU * 1.06, colour)
			_stroke(image, pivot + Vector2(cos(TAU * 0.06), sin(TAU * 0.06)) * reach * 0.52,
				Vector2(middle + reach * 0.06, middle + reach * 0.3), colour)
			_disc(image, Vector2(middle + reach * 0.06, middle + reach * 0.8),
				reach * 0.19, colour)
		Kind.ALERT:
			# The stem and the point, on the same proportions the question mark's are
			# drawn at, so the two marks are the same height and weight when they sit in
			# the same size of cell.
			_stroke(image, Vector2(middle, middle - reach * 0.9),
				Vector2(middle, middle + reach * 0.3), colour)
			_disc(image, Vector2(middle, middle + reach * 0.8), reach * 0.19, colour)
		Kind.SEARCH:
			var lens := Vector2(middle - reach * 0.22, middle - reach * 0.22)
			_arc(image, lens, reach * 0.72, 0.0, TAU, colour)
			_stroke(image, lens + Vector2(0.51, 0.51) * reach,
				Vector2(middle + reach * 0.95, middle + reach * 0.95), colour)
		Kind.CROSS:
			# Two strokes. The multiplication sign is in the font and the ballot X is
			# not, and reaching for either is how a close button becomes a tofu box on
			# somebody else's machine — the suite catches that, and this is the answer
			# it wants.
			_stroke(image, Vector2(middle - reach * 0.75, middle - reach * 0.75),
				Vector2(middle + reach * 0.75, middle + reach * 0.75), colour)
			_stroke(image, Vector2(middle + reach * 0.75, middle - reach * 0.75),
				Vector2(middle - reach * 0.75, middle + reach * 0.75), colour)
		Kind.PAUSE:
			# Two uprights, the play triangle's opposite number.
			for side: int in [-1, 1]:
				var x := middle + reach * 0.45 * float(side)
				_stroke(image, Vector2(x, middle - reach * 0.75),
					Vector2(x, middle + reach * 0.75), colour)
		Kind.ARROW_RIGHT:
			_stroke(image, Vector2(middle - reach, middle), Vector2(middle + reach, middle),
				colour)
			_stroke(image, Vector2(middle + reach, middle),
				Vector2(middle + reach * 0.3, middle - reach * 0.6), colour)
			_stroke(image, Vector2(middle + reach, middle),
				Vector2(middle + reach * 0.3, middle + reach * 0.6), colour)
		Kind.UNDO, Kind.REDO:
			# The one curved pair. Undo and redo are the two commands whose glyph really
			# is universal — a word was doing nothing a tooltip does not do better, on
			# the two widest buttons of the toolbar's narrowest group. Drawn, like every
			# other icon here, because the tofu incident is not getting a sequel.
			var mirror: float = -1.0 if kind == Kind.REDO else 1.0
			var centre := Vector2(middle, middle + reach * 0.15)
			# Most of a circle, open toward the top left (top right for redo).
			var start := -0.42 * TAU if kind == Kind.UNDO else -0.08 * TAU
			var sweep := 0.72 * TAU * mirror
			_arc(image, centre, reach, start + sweep, start, colour)
			# The head sits at the open end, pointing along the way the arc was going.
			var tip := centre + Vector2(cos(start), sin(start)) * reach
			var tangent := Vector2(sin(start), -cos(start)) * mirror
			_triangle(image, tip - tangent * reach * 0.1, reach * 0.62,
				tangent.angle(), colour)

	return _finish(image, key)


## A run of points in reach units, stroked end to end from the centre of the cell.
static func _polyline(image: Image, points: Array, middle: float, reach: float,
		colour: Color) -> void:
	var origin := Vector2(middle, middle)
	for i in points.size() - 1:
		_stroke(image, origin + (points[i] as Vector2) * reach,
			origin + (points[i + 1] as Vector2) * reach, colour)


## Which of the four responses a kind wants. The lowpass is the default because it is the
## specimen the other three were derived from.
static func _response_plan(kind: int) -> Array:
	match kind:
		Kind.RESPONSE_HIGH:
			return GlyphGrammar.RESPONSE_HIGH
		Kind.RESPONSE_BAND:
			return GlyphGrammar.RESPONSE_BAND
		Kind.RESPONSE_NOTCH:
			return GlyphGrammar.RESPONSE_NOTCH
	return GlyphGrammar.RESPONSE_LOW


## The envelope contour with one of its four segments picked out.
##
## Step 11's activity prototype, and the only node glyph that has a runtime state at all:
## an envelope's stages are named, discrete and inherent to the node, which is the bar an
## activity treatment has to clear. The whole contour stays drawn in the ordinary ink so
## the mark is still the mark — identity first, state on top of it, never state instead
## of it.
##
## Its own function rather than four more kinds, because a staged envelope is one drawing
## with a parameter and four enum entries would be four drawings that happen to look
## alike.
static func envelope_stage(size: int, colour: Color, active: Color,
		stage: int) -> Texture2D:
	var key := "env:%d:%s:%s:%d" % [size, colour.to_html(false), active.to_html(false),
		stage]
	if _cache.has(key):
		return _cache[key]
	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))
	var middle := (size - 1) * 0.5
	var reach := size * 0.28
	var origin := Vector2(middle, middle)
	var contour: Array = GlyphGrammar.ENVELOPE_CONTOUR
	for i in contour.size() - 1:
		# The live segment is drawn last so its ink lands on top where two segments meet
		# at a corner.
		if i == stage:
			continue
		_stroke(image, origin + (contour[i] as Vector2) * reach,
			origin + (contour[i + 1] as Vector2) * reach, colour)
	if stage >= 0 and stage < contour.size() - 1:
		_stroke(image, origin + (contour[stage] as Vector2) * reach,
			origin + (contour[stage + 1] as Vector2) * reach, active)
	return _finish(image, key)


## Caches a drawn glyph under its key and hands it back.
##
## Its own function because a glyph with a small cut returns from the middle of the
## match, and two copies of "make a texture, cache it, return it" is two places for the
## caching to be forgotten.
static func _finish(image: Image, key: String) -> Texture2D:
	var texture := ImageTexture.create_from_image(image)
	_cache[key] = texture
	return texture


## A line, drawn by distance so the edges are soft at any angle — a Bresenham line at this
## size looks like a staircase, which is exactly the cheap-looking thing being fixed.
static func _stroke(image: Image, from: Vector2, to: Vector2, colour: Color) -> void:
	var half := STROKE * 0.5
	for y in image.get_height():
		for x in image.get_width():
			var point := Vector2(x, y)
			var along := (to - from)
			var length_squared := along.length_squared()
			var t: float = 0.0 if length_squared <= 0.0 \
				else clampf((point - from).dot(along) / length_squared, 0.0, 1.0)
			var distance := point.distance_to(from + along * t)
			_blend(image, x, y, colour, clampf(half + 0.5 - distance, 0.0, 1.0))


## An arc, as chained strokes — twelve segments is smooth at these sizes and keeps the
## soft distance-field edge the strokes already have.
static func _arc(image: Image, centre: Vector2, radius: float, from_angle: float,
		to_angle: float, colour: Color) -> void:
	const SEGMENTS := 12
	var previous := centre + Vector2(cos(from_angle), sin(from_angle)) * radius
	for i in SEGMENTS:
		var angle: float = lerpf(from_angle, to_angle, float(i + 1) / SEGMENTS)
		var point := centre + Vector2(cos(angle), sin(angle)) * radius
		_stroke(image, previous, point, colour)
		previous = point


static func _triangle(image: Image, tip_anchor: Vector2, reach: float, rotation: float,
		colour: Color) -> void:
	# Three half-plane tests. Cheap, and gives a clean edge at any rotation.
	var points := []
	for i in 3:
		var angle := rotation + TAU * float(i) / 3.0
		points.append(tip_anchor + Vector2(cos(angle), sin(angle)) * reach)
	for y in image.get_height():
		for x in image.get_width():
			var point := Vector2(x, y)
			var inside := true
			for i in 3:
				var a: Vector2 = points[i]
				var b: Vector2 = points[(i + 1) % 3]
				if (b - a).cross(point - a) < 0.0:
					inside = false
			if inside:
				_blend(image, x, y, colour, 1.0)


static func _disc(image: Image, centre: Vector2, radius: float, colour: Color) -> void:
	for y in image.get_height():
		for x in image.get_width():
			var distance := Vector2(x, y).distance_to(centre)
			_blend(image, x, y, colour, clampf(radius + 0.5 - distance, 0.0, 1.0))


static func _box(image: Image, centre: Vector2, half: float, colour: Color) -> void:
	for y in image.get_height():
		for x in image.get_width():
			var offset := (Vector2(x, y) - centre).abs()
			var distance: float = maxf(offset.x, offset.y)
			_blend(image, x, y, colour, clampf(half + 0.5 - distance, 0.0, 1.0))


## Adds coverage rather than replacing it, so two strokes meeting at a corner do not punch
## a hole in each other.
static func _blend(image: Image, x: int, y: int, colour: Color, coverage: float) -> void:
	if coverage <= 0.0:
		return
	var existing := image.get_pixel(x, y)
	image.set_pixel(x, y, Color(colour.r, colour.g, colour.b,
		maxf(existing.a, coverage * colour.a)))
