class_name CableArt
extends RefCounted
## Drawing a patch cable as a small parametric illustration.
##
## Split out of the rack on purpose. The rack knows where cables go; this knows what one
## looks like, and the two have different answers to give.
##
## The target is a chunky illustrated patch cord, not a coloured spline with a cap. The
## first pass drifted to the latter — technically clean, materially flat — and the fix was
## not in the curve. It was hierarchy at the ends and a body that dominates its own
## lighting. Everything here is sized so the sequence reads without being examined:
##
##     chunky plug -> loud colour collar -> tapered strain relief -> saturated body
##     -> one bright edge -> one dark edge -> subtle shadow -> imperfect hang

## Where the light comes from, for everything in SoundGraph.
##
## A constant, not a parameter. The point of a fixed convention is that modules can move
## and cables can be redrawn and the lighting never argues with itself.
const LIGHT := Vector2(-1.0, -1.0)

## Candy insulation, not dark-mode UI.
##
## The palette this replaced was tasteful, and that was the problem — it read as modern
## SaaS rather than as a box of patch cables. These are meant to be almost obnoxious
## against a dark faceplate, because that is what the object actually is.
const PALETTE := {
	"cyan": Color("25D9E8"),
	"magenta": Color("FF4FA3"),
	"chartreuse": Color("B8F238"),
	"amber": Color("FFC84A"),
	"orange": Color("FF7B3F"),
	"violet": Color("A575FF"),
	"teal": Color("46E0B5"),
	"coral": Color("FF686E"),
}

const PALETTE_ORDER := ["cyan", "magenta", "chartreuse", "amber",
	"orange", "violet", "teal", "coral"]

## Slack presets. Most patches should live around 0.7-0.9; loose is meant to be spaghetti.
const SLACK := {"tight": 0.50, "medium": 0.82, "loose": 1.15}

## How much detail there is room for, which is a question about pixels and not about zoom.
enum Detail { FULL, SIMPLE, ICON }

## How the plug is projected out of a flat, front-facing panel.
##
## The faceplate is top-down and the plug was drawn from the side, which is readable and
## slightly impossible — a side-view object pasted onto a circular socket. These are the
## grammars worth comparing before one is adopted.
enum PlugView { SIDE, EMERGE, TOP_DOWN }


class Style extends RefCounted:
	## The body, and the baseline everything else is stated against.
	##
	## 5 px is the 100% cable. 3 px reads as a graph line, 4 is delicate, 7 has the right
	## chunkiness but belongs to hover and selection rather than to rest.
	var thickness := 5.0

	# The cast shadow that lifts the cable off the faceplate.
	var shadow_width := 8.0
	var shadow_offset := Vector2(1.0, 2.0)
	var shadow_alpha := 0.22

	## The dark edge, at full body width rather than a fraction of it.
	##
	## Offset by less than a pixel, which leaves a crescent along the lower right and is
	## what gives the cable its roundness. Drawn under the body, not over it — a dark pass
	## on top reads as a second stripe painted on a flat line.
	var edge_darken := 0.35
	var edge_offset := Vector2(0.7, 0.8)

	## The highlight: one thin bright line, in the cable's own colour lightened.
	##
	## Near-white on every cable is what made the first pass look like plastic tube with a
	## stripe down it. A green cable wants a pale green highlight.
	var highlight_width := 1.1
	var highlight_lighten := 0.35
	var highlight_alpha := 0.55
	var highlight_offset := Vector2(-0.6, -0.7)

	## The plug, deliberately oversized. This is iconographic representation, not
	## mechanical drafting: at true scale a 3.5 mm plug on a 5 px cable is a nub, and a nub
	## is what the first pass drew.
	var plug_length := 3.45     # of thickness -> ~17 px
	var plug_width := 2.35      # of thickness -> ~12 px
	## How much of the barrel sits behind the jack line.
	##
	## Lower than it was. At 0.30 the plug sat flush and the endpoint read as a dark cap on
	## a line; the eye wants the barrel to project out of the socket, not to fill it. The
	## ring lost weight at the same time — when the ring and the barrel carry equal
	## visual weight the picture has no hierarchy, and hierarchy is the whole difference
	## between a socket with something in it and a donut with a stripe.
	var plug_seat := 0.20
	var band_width := 2.5       # px, absolute: the collar is a signal, not a proportion
	var relief_length := 8.0    # px
	var relief_start := 8.0     # px wide where it leaves the band
	## Straight cable after the relief, before the curve takes over.
	##
	## Longer than it was, and the curve now leaves along it rather than turning at its
	## end — a short lead followed by an immediate bend reads as a hook, which is a
	## different object from a cable hanging.
	var lead_out := 16.0
	## How far the first control point continues along the exit before gravity wins.
	var ease := 22.0

	## The projection grammar, and how far the plug leans toward the cable.
	##
	## A plug coming straight out of a perfectly front-facing panel would show almost no
	## length at all, so the tilt is an honest abstraction rather than an attempt at
	## optical correctness: it exists to say "this projects out of the panel", which strict
	## perspective would say by showing nothing.
	var plug_view := PlugView.SIDE
	var tilt_degrees := 27.0
	var barrel_taper := 0.13
	var plug_body := Color("26282C")
	## The mouth of the socket, behind the barrel. A hole for the plug to be in.
	var socket_mouth := Color("07080A")
	## The rim, as a fraction of the jack radius. A rim frames the insertion; a filled
	## disc competes with the thing inserted into it.
	var ring_width := 0.30
	var plug_highlight_alpha := 0.30
	var plug_contact_alpha := 0.22

	## Screen-space floors. Below these the cable stops shrinking and starts simplifying,
	## because 5 x 0.35 is 1.75 px and 1.75 px of anything is a rumour.
	var min_thickness := 2.75
	var min_plug := 6.5

	func scaled(zoom: float) -> Style:
		var out := Style.new()
		for property in get_property_list():
			if property["usage"] & PROPERTY_USAGE_SCRIPT_VARIABLE:
				out.set(property["name"], get(property["name"]))
		out.thickness = maxf(thickness * zoom, min_thickness)
		out.shadow_width = out.thickness + 3.0 * zoom
		out.highlight_width = maxf(highlight_width * zoom, 1.0)
		out.band_width = maxf(band_width * zoom, 1.0)
		out.relief_length = relief_length * zoom
		out.relief_start = relief_start * zoom
		out.lead_out = lead_out * zoom
		return out

	## What to bother drawing at this size.
	func detail() -> int:
		var barrel := plug_length * thickness
		if barrel < min_plug * 1.6:
			return Detail.ICON
		if barrel < min_plug * 2.6:
			return Detail.SIMPLE
		return Detail.FULL


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


## Bounded, repeatable wobble from a cable's identity.
##
## Every cable in the first pass was the same perfect smile, which exposed the algorithm
## rather than the object — the picture said "cubic Bézier with identical control points"
## when it should have said "cable hanging between two things". Seeded from the id so a
## cable keeps its own hang: asymmetry that is regenerated per frame is a cable that
## shivers, which is worse than one that is too neat.
static func _wobble(id: String, salt: int) -> float:
	var h := hash(id + "/" + str(salt))
	return (float(h % 2000) / 1000.0) - 1.0      # -1..1


## Control points for a cable hanging between two exit points.
static func control_points(a: Vector2, b: Vector2, slack: float, id := "",
		short_threshold := 90.0, a_dir := Vector2.ZERO, b_dir := Vector2.ZERO,
		ease := 0.0) -> Array:
	var span := a.distance_to(b)
	var droop := clampf(span * 0.25, 12.0, 140.0) * slack
	# A short patch with a full quarter-span droop hangs in a U well below both jacks,
	# which reads as a mistake rather than as slack.
	if span < short_threshold:
		droop *= 0.45

	var left := droop * (1.0 + 0.08 * _wobble(id, 1))
	var right := droop * (1.0 + 0.08 * _wobble(id, 2))
	var bow := span * 0.06
	# The control points continue along the exit direction before the droop is applied, so
	# the curve leaves the plug the way the plug points and only then falls. Without this
	# the first control sits straight below the lead-out and the cable turns a corner
	# where it should be easing.
	return [a,
		a + a_dir * ease + Vector2(bow * (0.6 + 0.4 * _wobble(id, 3)), left),
		b + b_dir * ease + Vector2(-bow * (0.9 + 0.4 * _wobble(id, 4)), right),
		b]


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


## The whole path from jack to jack: plug, strain relief, a straight lead-out, then the
## hanging curve, then the same in reverse.
##
## The lead-out is what stops the object reading as one giant Bézier. It lets the plug's
## angle and the cable's curvature exist independently — a cable leaves its plug in the
## direction the plug points, and only then begins to fall.
static func cable_path(a: Vector2, a_dir: Vector2, b: Vector2, b_dir: Vector2,
		slack: float, style: Style, id := "") -> PackedVector2Array:
	var out_a := exit_point(a, a_dir, style)
	var out_b := exit_point(b, b_dir, style)
	var lead_a := out_a + a_dir * style.lead_out
	var lead_b := out_b + b_dir * style.lead_out

	var controls: Array = control_points(lead_a, lead_b, slack, id, 90.0,
		a_dir, b_dir, style.ease)
	var points := PackedVector2Array([out_a])
	points.append_array(bezier(controls[0], controls[1], controls[2], controls[3]))
	points.append(out_b)
	return points


## Where the cable proper begins: past the barrel and the strain relief.
static func exit_point(jack: Vector2, direction: Vector2, style: Style) -> Vector2:
	var forward := style.plug_length * style.thickness * (1.0 - style.plug_seat)
	return jack + direction * (forward + style.relief_length)


## Shadow, dark edge, body, highlight — in that order, so the body dominates and the cues
## stay thin.
static func draw_cable(canvas: CanvasItem, points: PackedVector2Array, colour: Color,
		style: Style) -> void:
	if points.size() < 2:
		return
	var level := style.detail()

	if level != Detail.ICON:
		# Two passes rather than one, which is the cheapest convincing softness there is:
		# a wide faint one that lands on the faceplate and a tighter one that sits under
		# the cable. One hard-edged shadow reads as a second cable drawn in black; this
		# reads as the panel darkening under something lying across it.
		canvas.draw_polyline(shifted(points, style.shadow_offset * 1.9),
			Color(0.0, 0.0, 0.0, style.shadow_alpha * 0.55),
			style.shadow_width + style.thickness * 0.7, true)
		canvas.draw_polyline(shifted(points, style.shadow_offset),
			Color(0.0, 0.0, 0.0, style.shadow_alpha), style.shadow_width, true)

	if level == Detail.FULL:
		canvas.draw_polyline(shifted(points, style.edge_offset),
			darken(colour, style.edge_darken), style.thickness, true)

	canvas.draw_polyline(points, colour, style.thickness, true)
	canvas.draw_polyline(shifted(points, style.highlight_offset),
		Color(lighten(colour, style.highlight_lighten), style.highlight_alpha),
		style.highlight_width, true)


static func draw_jack(canvas: CanvasItem, centre: Vector2, radius: float,
		ring: Color, socket: Color, style: Style = null) -> void:
	var rim: float = radius * (style.ring_width if style != null else 0.30)
	canvas.draw_circle(centre, radius, socket)
	# The rim, drawn as a ring rather than a disc. Lit from the upper left like everything
	# else, so an empty jack still has a direction to it.
	canvas.draw_arc(centre, radius - rim * 0.5, 0.0, TAU, 32, ring, rim, true)
	canvas.draw_arc(centre, radius - rim * 0.5, PI * 0.85, PI * 1.75, 16,
		lighten(ring, 0.22), rim * 0.7, true)


## The socket with something in it: the mouth stays dark around the barrel so the plug
## reads as sitting *in* a hole rather than on top of a disc.
static func draw_socket(canvas: CanvasItem, centre: Vector2, radius: float,
		ring: Color, style: Style) -> void:
	var rim := radius * style.ring_width
	canvas.draw_circle(centre, radius, style.socket_mouth)
	canvas.draw_arc(centre, radius - rim * 0.5, 0.0, TAU, 32, ring, rim, true)
	canvas.draw_arc(centre, radius - rim * 0.5, PI * 0.85, PI * 1.75, 16,
		lighten(ring, 0.22), rim * 0.7, true)


## The plug: barrel, collar, tapered relief. Three obvious shapes in a row, because the
## sequence is what says "this is hardware" rather than "this line stops here".
static func draw_plug(canvas: CanvasItem, jack: Vector2, direction: Vector2,
		colour: Color, style: Style) -> void:
	var t := style.thickness
	var level := style.detail()
	var along := direction.normalized()
	var across := Vector2(-along.y, along.x)

	var length := style.plug_length * t
	var half := style.plug_width * t * 0.5
	var base := jack - along * length * style.plug_seat
	var tip := jack + along * length * (1.0 - style.plug_seat)

	# Contact shadow first. This is the cue that says "sitting on the panel", and it does
	# more for the illusion than any amount of shading on the barrel itself.
	if level != Detail.ICON:
		_quad(canvas, base, tip, across * (half + 1.5), Vector2(1.0, 1.5),
			Color(0.0, 0.0, 0.0, style.plug_contact_alpha))

	_quad(canvas, base, tip, across * half, Vector2.ZERO, style.plug_body)

	# The collar, loud on purpose. It ties the dark plug to its cable, keeps identity when
	# several plugs overlap, and at low zoom it is the last thing to survive — one bright
	# bar is enough to say which cable this is.
	var band_a := tip - along * style.band_width
	_quad(canvas, band_a, tip, across * half, Vector2.ZERO, colour)

	if level != Detail.ICON:
		var relief_end := tip + along * style.relief_length
		_taper(canvas, tip, relief_end, style.relief_start * 0.5, t * 0.5,
			darken(colour, 0.45))

	if level == Detail.FULL:
		var lit := across * half * 0.60
		if lit.dot(LIGHT.normalized()) < 0.0:
			lit = -lit
		canvas.draw_line(base + lit + along * t * 0.25, tip + lit - along * t * 0.25,
			Color(1.0, 1.0, 1.0, style.plug_highlight_alpha), maxf(1.0, t * 0.18), true)
		canvas.draw_line(base - lit + along * t * 0.25, tip - lit - along * t * 0.25,
			Color(0.0, 0.0, 0.0, style.plug_highlight_alpha), maxf(1.0, t * 0.18), true)


## An ellipse, for the parts of the plug that are circles seen obliquely.
static func _ellipse(canvas: CanvasItem, centre: Vector2, along: Vector2, rx: float,
		ry: float, fill: Color, arc_from := 0.0, arc_to := TAU) -> void:
	var across := Vector2(-along.y, along.x)
	var points := PackedVector2Array()
	var steps := 24
	for i in steps + 1:
		var a: float = arc_from + (arc_to - arc_from) * float(i) / steps
		points.append(centre + along * (sin(a) * rx) + across * (cos(a) * ry))
	canvas.draw_colored_polygon(points, fill)


## A band between two concentric ellipses, over an arc. The near half of a ring.
static func _ellipse_band(canvas: CanvasItem, centre: Vector2, along: Vector2,
		rx: float, ry: float, inner: float, fill: Color,
		arc_from := 0.0, arc_to := PI) -> void:
	var across := Vector2(-along.y, along.x)
	var points := PackedVector2Array()
	var steps := 18
	for i in steps + 1:
		var a: float = arc_from + (arc_to - arc_from) * float(i) / steps
		points.append(centre + along * (sin(a) * rx) + across * (cos(a) * ry))
	for i in steps + 1:
		var a: float = arc_to + (arc_from - arc_to) * float(i) / steps
		points.append(centre + along * (sin(a) * rx * inner) + across * (cos(a) * ry * inner))
	canvas.draw_colored_polygon(points, fill)


## The plug rising out of the panel.
##
## Four zones, each a little further from top-down than the last: the rim stays flat, the
## collar is a compressed ring at the panel line, the barrel is a short tapered extrusion,
## and the relief hands over to the cable. Nothing here is a camera — it is a controlled
## 2D deformation, because a miniature 3D renderer would buy accuracy nobody asked for and
## cost the flat, graphic character that makes the rest of the interface legible.
##
## The shadow does most of the persuading. Its separation from the plug grows from nothing
## at the socket to the cable's normal offset by the time the cable begins, and the eye
## reads increasing separation as increasing height far more readily than it reads a
## correctly foreshortened cylinder.
static func draw_plug_emergent(canvas: CanvasItem, jack: Vector2, direction: Vector2,
		colour: Color, style: Style) -> void:
	var t := style.thickness
	var level := style.detail()
	var along := direction.normalized()
	var across := Vector2(-along.y, along.x)

	var tilt: float = deg_to_rad(style.tilt_degrees)
	var squash: float = cos(tilt)                       # how flat the collar ring reads
	var base_half := style.plug_width * t * 0.5
	var far_half := base_half * (1.0 - style.barrel_taper)
	# Projected length: what a tilted cylinder shows of itself. Scaled so the useful range
	# of tilts lands in the 8-12 px the geometry wants at a 5 px cable.
	var length: float = style.plug_length * t * sin(tilt) * 1.9

	var tip := jack + along * length

	# Shadow, ramped. At the socket the plug is in the panel and casts nothing; by the
	# relief it casts what the cable casts.
	if level != Detail.ICON:
		var lift := style.shadow_offset * 0.9
		_taper(canvas, jack + lift * 0.15, tip + lift, base_half * 1.05, far_half * 1.1,
			Color(0.0, 0.0, 0.0, style.plug_contact_alpha * 0.9))

	# The collar is a ring the barrel passes through, not a lid laid over the socket.
	#
	# Filled, it read as a coloured cap covering the hole — which is the same mistake as
	# the original plug: one grammar pasted over another. Occlusion is what makes them
	# agree. The far half of the ring goes down first, the barrel over it, then the near
	# half over the barrel, and the eye is told the cylinder passes through the opening.
	var collar_rx := base_half * (0.40 + 0.55 * squash)
	var collar_ry := base_half * 1.12
	var collar_at := jack + along * style.band_width * 0.15
	_ellipse_band(canvas, collar_at, along, collar_rx, collar_ry, 0.52, colour, PI, TAU)

	# The barrel: a short tapered extrusion, narrowing along the projection so the eye
	# reads a cylinder leaving a hole rather than a rectangle laid over a circle.
	_taper(canvas, jack, tip, base_half, far_half, style.plug_body)
	_ellipse(canvas, tip, along, far_half * 0.55, far_half,
		lighten(style.plug_body, 0.10))

	_ellipse_band(canvas, collar_at, along, collar_rx, collar_ry, 0.52, colour, 0.0, PI)

	if level != Detail.ICON:
		var relief_end := tip + along * style.relief_length
		_taper(canvas, tip, relief_end, far_half * 0.92, t * 0.5,
			darken(colour, 0.45))

	if level == Detail.FULL:
		# Longitudinal on the barrel, where the socket's lighting was radial. The
		# progression from one to the other is what ties the pieces into one object.
		var lit := across * base_half * 0.55
		if lit.dot(LIGHT.normalized()) < 0.0:
			lit = -lit
		canvas.draw_line(jack + lit * 0.9 + along * length * 0.15, tip + lit * 0.8,
			Color(1.0, 1.0, 1.0, style.plug_highlight_alpha), maxf(1.0, t * 0.16), true)
		canvas.draw_line(jack - lit * 0.9 + along * length * 0.15, tip - lit * 0.8,
			Color(0.0, 0.0, 0.0, style.plug_highlight_alpha * 1.1), maxf(1.0, t * 0.16),
			true)


## The plug with no perspective at all: everything in the panel plane.
##
## The control, and not a straw man. It is internally consistent in a way the side view
## never was, and if the emergence treatments read as confusing then this is the honest
## answer — a cable leaving a socket, drawn flat, with the collar as a ring in the jack.
static func draw_plug_topdown(canvas: CanvasItem, jack: Vector2, direction: Vector2,
		colour: Color, style: Style) -> void:
	var t := style.thickness
	var along := direction.normalized()
	var radius := style.plug_width * t * 0.5

	_ellipse(canvas, jack, along, radius * 0.86, radius * 0.86, style.plug_body)
	# A ring of cable colour inside the socket: the endpoint cue, with nothing pretending
	# to stand out of the panel.
	canvas.draw_arc(jack, radius * 0.62, 0.0, TAU, 28, colour, maxf(2.0, t * 0.5), true)
	if style.detail() != Detail.ICON:
		_taper(canvas, jack + along * radius * 0.5, jack + along * (radius + style.relief_length),
			t * 0.75, t * 0.5, darken(colour, 0.45))


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
