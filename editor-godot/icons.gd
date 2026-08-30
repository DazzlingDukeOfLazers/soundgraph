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
			for corner: Vector2 in [Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1),
					Vector2(1, 1)]:
				_box(image, Vector2(middle, middle) + corner * reach * 0.55,
					reach * 0.3, colour)
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
			var stages: Array = [Vector2(-1.1, 0.8), Vector2(-0.45, -0.8),
				Vector2(0.0, -0.1), Vector2(0.5, -0.1), Vector2(1.1, 0.8)]
			for i in stages.size() - 1:
				_stroke(image, Vector2(middle, middle) + (stages[i] as Vector2) * reach,
					Vector2(middle, middle) + (stages[i + 1] as Vector2) * reach, colour)
		Kind.SPLIT:
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
