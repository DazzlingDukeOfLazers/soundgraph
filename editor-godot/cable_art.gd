class_name CableArt
extends RefCounted
## Drawing a patch cable as a small parametric illustration.
##
## Split out of the rack on purpose. The rack knows where cables go; this knows what one
## looks like, and the two questions have different answers to give. Keeping them apart is
## what lets cable_lab.gd put a hundred variants on screen at once without a rack, and what
## will let the rack adopt this without inheriting a lab.
##
## The approach is schematic rather than physical: one highlight, one shadow edge, one
## contact shadow, and a fixed light direction for the whole application. A cable should
## read as a polished illustration of a patch cord, not as a rendered rubber hose — depth
## cues have to survive being small, and a real shading model does not.

## Where the light comes from, for everything in SoundGraph.
##
## A constant, not a parameter. The point of a fixed convention is that modules can move
## and cables can be redrawn and the lighting never argues with itself; making it settable
## would let one cable disagree with another and lose exactly the consistency it buys.
const LIGHT := Vector2(-1.0, -1.0)

## Everything the look is made of, in one place so a lab can sweep it and a theme can
## carry it. Defaults are the spec's midpoints, which is a starting position and not a
## verdict — these are meant to be argued with on screen.
class Style extends RefCounted:
	var thickness := 5.0

	# Pass 1, the contact shadow that lifts the cable off the faceplate.
	var shadow_grow := 3.0
	var shadow_offset := Vector2(1.0, 2.0)
	var shadow_alpha := 0.20

	# Pass 3, the shadow edge that implies a cylinder.
	var edge_width := 0.80          # of thickness
	var edge_darken := 0.30
	var edge_offset := Vector2(0.5, 0.8)
	var edge_alpha := 0.55

	# Pass 4, the highlight. Illustrated rubber, not chrome.
	var highlight_width := 0.25     # of thickness
	var highlight_lighten := 0.35
	var highlight_offset := Vector2(-0.4, -0.5)
	var highlight_alpha := 0.65

	# The plug, in multiples of thickness.
	## How much of the barrel sits behind the jack centre, into the panel.
	##
	## Not zero, which is what the first version assumed. A plug drawn from the jack centre
	## outward lies *beside* the jack rather than in it, and the picture reads as a cable
	## ending near a socket. Straddling the centre is what makes it read as inserted, and
	## it costs one number.
	var plug_seat := 0.32
	var plug_length := 2.6
	var plug_width := 1.65
	var band_width := 0.42
	var relief_length := 0.8
	var plug_body := Color(0.125, 0.129, 0.141)     # #202124
	var plug_shadow := Color(0.043, 0.047, 0.051)   # #0B0C0D
	var plug_highlight_alpha := 0.28
	var plug_contact_alpha := 0.20

	func duplicate_style() -> Style:
		var copy := Style.new()
		for property in get_property_list():
			var name: String = property["name"]
			if property["usage"] & PROPERTY_USAGE_SCRIPT_VARIABLE:
				copy.set(name, get(name))
		return copy


## A cubic Bézier sampled to a polyline, because Godot draws polylines and not curves.
##
## Sampled by length rather than at a fixed count: a short patch and a long one both want
## a smooth outline, and a fixed count gives the long one corners.
static func bezier(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2) -> PackedVector2Array:
	var rough := p0.distance_to(p1) + p1.distance_to(p2) + p2.distance_to(p3)
	var steps := clampi(int(rough / 6.0), 12, 96)
	var points := PackedVector2Array()
	for i in steps + 1:
		var t := float(i) / steps
		var u := 1.0 - t
		points.append(p0 * (u * u * u) + p1 * (3.0 * u * u * t)
			+ p2 * (3.0 * u * t * t) + p3 * (t * t * t))
	return points


static func bezier_tangent(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2,
		t: float) -> Vector2:
	var u := 1.0 - t
	var d := (p1 - p0) * (3.0 * u * u) + (p2 - p1) * (6.0 * u * t) + (p3 - p2) * (3.0 * t * t)
	return d.normalized() if d.length() > 0.001 else Vector2.RIGHT


## The control points for a cable hanging between two jacks.
##
## Slack is a droop and bias is a sideways lean, and the lean is what stops two cables
## between the same pair of modules from lying on top of each other. Both are handed in
## rather than derived here so they can be deterministic per cable — a bias that is
## recomputed each frame is a cable that shivers.
static func control_points(a: Vector2, b: Vector2, slack: float, side_bias: float,
		short_threshold := 90.0) -> Array:
	var span := a.distance_to(b)
	var droop := clampf(span * 0.25, 12.0, 140.0) * slack
	# A short patch that keeps the full quarter-span droop hangs in a U far below both
	# jacks, which reads as a mistake rather than as slack.
	if span < short_threshold:
		droop *= 0.45
	var lean := clampf(span * 0.08, 4.0, 40.0) * side_bias
	return [a, a + Vector2(lean, droop), b + Vector2(-lean, droop), b]


## Where the cable proper begins: past the plug and its strain relief, so the body never
## looks like it runs through the barrel it is supposed to emerge from.
static func exit_point(jack: Vector2, tangent: Vector2, style: Style) -> Vector2:
	var forward := style.plug_length * (1.0 - style.plug_seat) + style.relief_length
	return jack + tangent * forward * style.thickness


static func darken(colour: Color, amount: float) -> Color:
	return Color(colour.r * (1.0 - amount), colour.g * (1.0 - amount),
		colour.b * (1.0 - amount), colour.a)


static func lighten(colour: Color, amount: float) -> Color:
	return Color(lerpf(colour.r, 1.0, amount), lerpf(colour.g, 1.0, amount),
		lerpf(colour.b, 1.0, amount), colour.a)


static func shifted(points: PackedVector2Array, by: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array()
	for point in points:
		out.append(point + by)
	return out


## The four cable passes, in order. The plugs are drawn separately because they sit above
## the cable at one end and below it at the other in the render stack.
static func draw_cable(canvas: CanvasItem, points: PackedVector2Array, colour: Color,
		style: Style) -> void:
	if points.size() < 2:
		return
	canvas.draw_polyline(shifted(points, style.shadow_offset),
		Color(0.0, 0.0, 0.0, style.shadow_alpha), style.thickness + style.shadow_grow, true)
	canvas.draw_polyline(points, colour, style.thickness, true)

	var edge := darken(colour, style.edge_darken)
	edge.a = style.edge_alpha
	canvas.draw_polyline(shifted(points, style.edge_offset), edge,
		style.thickness * style.edge_width, true)

	var lit := lighten(colour, style.highlight_lighten)
	lit.a = style.highlight_alpha
	canvas.draw_polyline(shifted(points, style.highlight_offset), lit,
		style.thickness * style.highlight_width, true)


## An empty jack: ring, dark socket, and a bevel that follows the global light.
static func draw_jack(canvas: CanvasItem, centre: Vector2, radius: float,
		ring: Color, socket: Color) -> void:
	canvas.draw_circle(centre, radius, ring)
	canvas.draw_circle(centre + LIGHT.normalized() * radius * 0.12, radius * 0.86,
		lighten(ring, 0.18))
	canvas.draw_circle(centre, radius * 0.62, socket)


## A plug seated in a jack, pointing along the cable.
##
## Drawn as a rotated box rather than a sprite so it can take any angle and any thickness
## without an asset. The order matters more than the shapes do: contact shadow first so
## the plug sits on the panel, band last but one so the cable colour reaches the dark
## barrel, highlight last so nothing covers it.
static func draw_plug(canvas: CanvasItem, jack: Vector2, tangent: Vector2,
		colour: Color, style: Style) -> void:
	var t := style.thickness
	var length := style.plug_length * t
	var half := style.plug_width * t * 0.5
	var along := tangent.normalized()
	var across := Vector2(-along.y, along.x) * half

	# Straddling the jack centre, not starting at it: the barrel goes a little way behind
	# the panel line so the jack ring shows around it, which is the cue that says seated.
	var base := jack - along * length * style.plug_seat
	var tip := jack + along * length * (1.0 - style.plug_seat)

	# Contact shadow. This is the cue that says "on top of the panel", and the spec is
	# right that it matters more than any amount of barrel shading.
	_quad(canvas, base, tip, across * 1.15, Vector2(1.0, 1.0),
		Color(0.0, 0.0, 0.0, style.plug_contact_alpha))

	_quad(canvas, base, tip, across, Vector2.ZERO, style.plug_body)

	# The band sits at the cable end of the barrel and is the only place the cable's
	# colour touches the plug. Without it a dark plug reads as unrelated hardware.
	var band_start := jack + along * (length - style.band_width * t)
	_quad(canvas, band_start, tip, across, Vector2.ZERO, colour)

	# Strain relief: a short taper from the band out to the cable.
	var relief_end := tip + along * style.relief_length * t
	_taper(canvas, tip, relief_end, half, style.thickness * 0.5,
		darken(colour, 0.35))

	var lit := Color(1.0, 1.0, 1.0, style.plug_highlight_alpha)
	var light_side := LIGHT.normalized()
	var lit_offset := across.normalized() * half * 0.62
	if lit_offset.dot(light_side) < 0.0:
		lit_offset = -lit_offset
	canvas.draw_line(base + lit_offset + along * t * 0.2,
		tip + lit_offset - along * t * 0.2, lit, maxf(1.0, t * 0.16), true)

	var dim := Color(0.0, 0.0, 0.0, style.plug_highlight_alpha)
	canvas.draw_line(base - lit_offset + along * t * 0.2,
		tip - lit_offset - along * t * 0.2, dim, maxf(1.0, t * 0.16), true)


static func _quad(canvas: CanvasItem, from: Vector2, to: Vector2, across: Vector2,
		offset: Vector2, fill: Color) -> void:
	canvas.draw_colored_polygon(PackedVector2Array([
		from + across + offset, to + across + offset,
		to - across + offset, from - across + offset]), fill)


static func _taper(canvas: CanvasItem, from: Vector2, to: Vector2, from_half: float,
		to_half: float, fill: Color) -> void:
	var along := (to - from).normalized()
	var across := Vector2(-along.y, along.x)
	canvas.draw_colored_polygon(PackedVector2Array([
		from + across * from_half, to + across * to_half,
		to - across * to_half, from - across * from_half]), fill)
