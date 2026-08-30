class_name CableArt
extends RefCounted
## Drawing a patch cable as a small parametric illustration.
##
## Split out of the rack on purpose. The rack knows where cables go; this knows what one
## looks like, and the two have different answers to give.
##
## The finished grammar, the frozen figures, the reasoning and the wrong turns are in
## docs/cable-design.md. Read it before retuning anything here: most of these numbers
## were settled one at a time against a rendered comparison, and the document says which
## are decisions and which are accidents.
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
## The faceplate is top-down and the plug was once drawn from the side, which is readable
## and slightly impossible — a side-view object pasted onto a circular socket.
enum PlugView { SIDE, EMERGE, TOP_DOWN }

## How much plug there is room to draw, which is the same question as which grammar to
## use.
##
## The comparison sheet settled that there is no single right projection: the 27 degree
## emergence is the strongest object when there are pixels for it, and the flat top-down
## symbol is the cleanest thing to be when there are not. So the projection is part of the
## level of detail rather than a style setting — C is the canonical physical object and D
## is its low-resolution glyph, and the renderer reveals more physical information as the
## pixels arrive.
enum PlugLod { FULL, SIMPLE, GLYPH }

## Chosen from rendered screen-space size, never from a zoom percentage.
##
## A zoom number is a fact about a viewport and says nothing about how many pixels reached
## this particular plug — which is what actually decides whether a barrel is a cylinder or
## a smudge. Screen space survives DPI scaling, window size, module width and whatever the
## rack does next; 35% does not.
static func plug_lod(style: Style) -> int:
	var diameter: float = style.plug_width * style.thickness * style.screen_scale
	# 11, not 12. The canonical 5 px cable puts a 2.35t plug at 11.75 px, which fell on
	# the wrong side of a threshold written before the plug had its final width — so the
	# primary working scale rendered the simplified model and the full one was reachable
	# only by zooming in. Thresholds should be tuned to the sizes that actually occur.
	#
	# Diameter alone is not enough, though, and the real rack is what proved it. A plug
	# has to fit in the room between one jack and the next, and in the rack that room is
	# the jack pitch — 28 px, against a full assembly that reaches about 23 and a cable
	# still travelling straight for 16 after that. Every plug landed on the socket below
	# it: a module's `frequency` covered its `gate`, and an empty jack under a plugged one
	# looked plugged. Width was never the problem. Length was.
	if diameter >= 11.0 and _fits(style, PlugLod.FULL):
		return PlugLod.FULL
	if diameter >= 8.0 and _fits(style, PlugLod.SIMPLE):
		return PlugLod.SIMPLE
	# The glyph is the last tier, and there is no fourth one under it.
	#
	# There was: an iconographic endpoint for plugs below 5 px, which nothing could ever
	# reach. The screen-space floor holds a cable at 2.75 px however far you zoom out, and
	# that puts a 2.35t plug at 6.46 px on the glass — over the threshold, always, from
	# every style built anywhere in this repo. The floor and the threshold contradicted
	# each other and the floor is the one worth keeping, because a connection vanishing at
	# low zoom is the thing it was added to prevent.
	#
	# Kept as a comment rather than as a branch, since there is no surface that wants it.
	# A minimap or a navigator might, and would be free to floor lower and add a tier back
	# — which is a smaller job than working out why a branch that never runs is there.
	return PlugLod.GLYPH


static func _fits(style: Style, tier: int) -> bool:
	var footprint := plug_footprint(style, tier)
	return footprint.forward_reach <= style.max_reach \
		and footprint.lateral_radius <= style.max_lateral


## What a tier of plug actually occupies around its socket.
##
## Every tier reports, including the flat ones that project nothing. The scalar this
## replaces returned zero for those two by way of an early return — true today, and true
## only because the glyph happens to draw nothing outward. The glyph has already had one
## feature removed for reaching too far, and the next one added would have made the
## collision test quietly wrong rather than loudly wrong, which is the worse of the two.
##
## Lateral is reported and checked, but nothing sets a bound on it yet. The room a plug
## competes for in this rack is the vertical pitch of the jack column, and the plug's
## forward direction is that same axis. A module that ever puts a control beside a jack
## would set max_lateral, and the tier selection would already honour it.
class PlugFootprint extends RefCounted:
	## Out of the panel, towards the viewer: barrel plus relief.
	var forward_reach := 0.0
	## Back into the panel — the seated part, behind the socket face.
	var backward_reach := 0.0
	## The widest the assembly gets, measured from the socket centre.
	var lateral_radius := 0.0

	func _init(forward := 0.0, backward := 0.0, lateral := 0.0) -> void:
		forward_reach = forward
		backward_reach = backward
		lateral_radius = lateral


static func plug_footprint(style: Style, tier: int) -> PlugFootprint:
	var half: float = style.plug_width * style.thickness * 0.5
	match tier:
		PlugLod.FULL, PlugLod.SIMPLE:
			var length: float = style.plug_length * style.thickness \
				* sin(deg_to_rad(style.tilt_degrees)) * 1.9
			var relief: float = style.relief_length * (1.0 if tier == PlugLod.FULL else 0.7)
			return PlugFootprint.new(length + relief,
				style.plug_length * style.thickness * style.plug_seat, half * 1.12)
		_:
			return PlugFootprint.new(0.0, 0.0, half * 0.86)


class Style extends RefCounted:
	## The body, and the baseline everything else is stated against.
	##
	## 5 px is the 100% cable. 3 px reads as a graph line, 4 is delicate, 7 has the right
	## chunkiness but belongs to hover and selection rather than to rest.
	var thickness := 5.0

	# The cast shadow that lifts the cable off the faceplate.
	var shadow_width := 8.0
	var shadow_offset := Vector2(1.0, 2.0)
	## Reduced from 0.22. The weight a cable carries comes from the whole stack, not from
	## the body, and the broad shadow is the pass that costs the least to lose — a rack of
	## amber cables read as dominant while every individual measurement was correct.
	var shadow_alpha := 0.18

	## The dark edge, at full body width rather than a fraction of it.
	##
	## Offset by less than a pixel, which leaves a crescent along the lower right and is
	## what gives the cable its roundness. Drawn under the body, not over it — a dark pass
	## on top reads as a second stripe painted on a flat line.
	var edge_darken := 0.35
	var edge_offset := Vector2(0.7, 0.8)
	## How much of the cable's width the saturated body keeps, the rest going to the
	## dark same-hue shell that wraps it. 1.0 is the old construction — shell visible
	## only as the offset crescent — and the cords run narrower so the body sits inside
	## a darker version of itself all the way round. The total apparent diameter does
	## not change: the shell fills the envelope the offset edge already defined.
	var body_core := 1.0

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
	## The barrel. Darker than any panel it might be drawn on.
	##
	## It was 26282C, which is a fine charcoal and almost exactly the colour of a module
	## panel — so on the lab's mock faceplate the barrel read, and in the real rack it
	## disappeared entirely. What survived was the pair of lighting lines drawn on it,
	## 6 px apart, which looked like a thin grey wire threaded through a grommet: the
	## chunkiest part of the assembly rendering as the thinnest. A plug is a black
	## anodised or nickel object and can safely be darker than every surface behind it.
	var _plug_body := Color("141619")
	## The barrel on a light faceplate. Still dark — a plug is a dark object — but not so
	## dark that the socket mouth behind it cannot be told from it.
	var _plug_body_light := Color("2a2c30")
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
	## The smallest a plug silhouette is allowed to be before it stops being drawn as an
	## object at all.
	##
	## Was 6.5, which quietly made the icon tier unreachable: with the body floored at
	## 2.75 px the plug could never measure less than 6.5, so the "under 5 px" branch was
	## dead code that looked like coverage. A floor and a threshold that contradict each
	## other are worse than either alone.
	var min_plug := 4.0

	## Whether the surface under the cable is a light material.
	##
	## A cable's roundness is one lighter edge and one darker, and which is which depends
	## on nothing but the light — but the *shadow* and the *plug* depend on the panel. A
	## black barrel disappears on anodised black and a 22% black shadow disappears with
	## it, so both are stated against the surface rather than fixed for the one faceplate
	## everything here was first drawn on.
	var panel_is_light := false

	## The room the plug has to project into, in pixels, before it runs into whatever is
	## next to the socket. INF means open panel: the lab sheets, where nothing is near.
	##
	## The rack sets it from its jack pitch. This is the one thing a synthetic sheet could
	## never supply, and it is what decides the tier as much as the size does.
	var max_reach := INF

	## The room beside the socket, in pixels. Reported against by every plug tier; see
	## PlugFootprint for why nothing sets it yet.
	var max_lateral := INF

	## Pixels on the glass per pixel of this style, when the canvas is scaled under us.
	##
	## The rack zooms by scaling a Control, so a 5 px cable is 5 px in the numbers here and
	## something else entirely on the screen — and the whole point of choosing a tier from
	## screen-space size is that it survives exactly this. Reach does not need it: the room
	## between two jacks scales with the plug that has to fit in it.
	var screen_scale := 1.0

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

	# A destination above the source means the cable has to leave downwards, fall, and
	# climb back — both plugs point out of the panel, so there is no other way out of the
	# socket. The fall then has to be deep enough to turn in: at a short span the droop
	# came out about the same as the straight run out of the plug, so the outbound and
	# return legs met at the bottom in a point rather than a bend, and a short cable to a
	# module above read as a spike. Found by dragging a module under a hovered cable,
	# which is a state no resting frame contains.
	var climbs := b.y < a.y

	var left := droop * (1.0 + 0.08 * _wobble(id, 1))
	var right := droop * (1.0 + 0.08 * _wobble(id, 2))
	# A cable to a module above does not hang in the middle. It cannot: both plugs point
	# out of the panel, so it leaves downwards and arrives from below, and pushing both
	# controls down as well folds it in half. The fold can never be wider than the
	# horizontal distance the cable has to cover, so on a short climb it is a crease a few
	# pixels across ending in a point — which is what a dragged module produced, and what
	# three rounds of widening the fold could not fix, because the room was not there to
	# widen it into.
	#
	# So the far control stays near its own end and the cable makes one sweep instead of a
	# loop: down out of the plug, across, and up into the other. Which is also what the
	# real thing does over that distance — a lead between two modules a hand apart is not
	# slack enough to hang.
	if climbs:
		right = droop * 0.15
	# The bow is what holds the two legs apart, and it is the difference between them
	# rather than their average: p1 goes one way and p2 the other. A proportional bow is
	# fine for a cable that runs across the case, and far too small for one that turns
	# round — a sixteenth of a short span leaves the legs closer together than the cable
	# is wide, and they meet at the bottom in a point.
	var bow := span * 0.06

	# How nearly the two jacks are stacked, 0 for side by side and 1 for one above the
	# other. Two exits both pointing out of the panel means a cable between stacked jacks
	# has to leave downwards, fall, and come back up — which is what a real one does, and
	# what the mirrored bow turned into an S written straight down the module's own jack
	# column: a hard vertical line covering every jack between the two it connects, and
	# reading as a PCB trace rather than as anything hanging.
	#
	# So the swing goes the same way at both ends instead of opposite ways. The cable
	# leans out to one side, falls, and returns — the loop is still there, it just happens
	# beside the column rather than on top of it. Which side is seeded, so a cable keeps
	# it, and two cables down the same column do not choose the same one.
	var vertical := clampf(1.0 - absf(b.x - a.x) / maxf(absf(b.y - a.y), 1.0), 0.0, 1.0)
	var swing := span * 0.30 * vertical * (1.0 if _wobble(id, 5) >= 0.0 else -1.0)

	# The control points continue along the exit direction before the droop is applied, so
	# the curve leaves the plug the way the plug points and only then falls. Without this
	# the first control sits straight below the lead-out and the cable turns a corner
	# where it should be easing.
	return [a,
		a + a_dir * ease + Vector2(bow * (0.6 + 0.4 * _wobble(id, 3)) + swing, left),
		b + b_dir * ease + Vector2(-bow * (0.9 + 0.4 * _wobble(id, 4)) + swing, right),
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
	# The straight run out of the panel — plug, relief, lead-out — held inside the room the
	# plug was given. Otherwise the tier that was demoted because it would have collided
	# with the next jack goes and collides with it anyway, in cable rather than in plug.
	var lead := style.lead_out
	if style.max_reach < INF:
		lead = maxf(style.lead_out * 0.35,
			minf(style.lead_out, style.max_reach - a.distance_to(out_a)))
	var lead_a := out_a + a_dir * lead
	var lead_b := out_b + b_dir * lead

	var controls: Array = control_points(lead_a, lead_b, slack, id, 90.0,
		a_dir, b_dir, style.ease)
	var points := PackedVector2Array([out_a])
	points.append_array(bezier(controls[0], controls[1], controls[2], controls[3]))
	points.append(out_b)
	return points


## Where the cable proper begins: past the barrel and the strain relief.
##
## Past whichever of those the plug is actually drawing. The flat tiers have no barrel and
## no relief — that is what makes them flat — but the cable went on leaving 38 px below
## the socket as though they were there, which in a column of jacks 28 px apart is a
## straight drop across the next one and a half. In a four-input mixer every cable then
## appeared to be plugged into the jack below its own. The plug reports the room it needs;
## the cable has to believe the same number.
static func exit_point(jack: Vector2, direction: Vector2, style: Style) -> Vector2:
	var tier := plug_lod(style)
	if tier == PlugLod.GLYPH:
		return jack + direction * (style.plug_width * style.thickness * 0.5)
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

	var body_width := style.thickness * style.body_core
	if level == Detail.FULL:
		var edge := darken(colour, style.edge_darken)
		# The shell, in two passes over one envelope: a centred tube at full width, so
		# the body sits inside a darker version of itself all the way round, and the
		# offset pass toward lower-right, where the light does not reach — which keeps
		# the shell asymmetric enough to read as a lit cylinder rather than an outline.
		# The envelope is the same one the offset edge always defined; the roundness
		# comes from the body narrowing into it, not from anything getting wider.
		if style.body_core < 1.0:
			canvas.draw_polyline(points, edge, style.thickness, true)
			_round_joins(canvas, points, Vector2.ZERO, edge, style.thickness)
		canvas.draw_polyline(shifted(points, style.edge_offset), edge,
			style.thickness, true)
		_round_joins(canvas, points, style.edge_offset, edge, style.thickness)

	canvas.draw_polyline(points, colour, body_width, true)
	_round_joins(canvas, points, Vector2.ZERO, colour, body_width)
	canvas.draw_polyline(shifted(points, style.highlight_offset),
		Color(lighten(colour, style.highlight_lighten), style.highlight_alpha),
		style.highlight_width, true)


## Where one cable crosses another, as points on the upper cable's path.
##
## Cheap on purpose. Two whole paths are rejected on their bounding boxes before a single
## segment is looked at, which kills most of the pairs in a rack, and near-misses are not
## chased: a crossing the eye cannot see does not need to be explained to it.
static func crossings(upper: PackedVector2Array,
		lower: PackedVector2Array) -> PackedVector2Array:
	var hits := PackedVector2Array()
	if upper.size() < 2 or lower.size() < 2:
		return hits
	var box_a := _bounds(upper)
	var box_b := _bounds(lower)
	if not box_a.grow(2.0).intersects(box_b):
		return hits
	for i in upper.size() - 1:
		var p1 := upper[i]
		var p2 := upper[i + 1]
		var seg := Rect2(p1, Vector2.ZERO).expand(p2).grow(1.0)
		if not seg.intersects(box_b):
			continue
		for j in lower.size() - 1:
			var hit: Variant = Geometry2D.segment_intersects_segment(
				p1, p2, lower[j], lower[j + 1])
			if hit != null:
				hits.append(hit)
				break        # one mark per segment; a crossing is not a series of them
	return hits


## A short darker shadow under the upper cable, local to where it passes over another.
##
## The same trick that made the plug read: topology by occlusion rather than by depth. The
## eye is told which cable is on top by seeing one of them darkened where the other lies
## across it, and that is the whole of the claim — no depth buffer, no cable-length
## shadows cast onto neighbours, nothing that would need a z-order the document does not
## have. Only the crossing is reinforced.
static func draw_crossing_shadow(canvas: CanvasItem, upper: PackedVector2Array,
		at: Vector2, style: Style, radius := 10.0) -> void:
	var local := PackedVector2Array()
	for point: Vector2 in upper:
		if point.distance_to(at) <= radius:
			local.append(point)
	# A curve this smooth can put fewer than two vertices inside a 10 px window, and a
	# one-point polyline draws nothing at all.
	if local.size() < 2:
		local = PackedVector2Array([at - Vector2(radius, 0.0) * 0.4,
			at + Vector2(radius, 0.0) * 0.4])
	# Wider than the cable's own shadow and darker, or it is not there at all: the upper
	# cable lays its normal two shadow passes and then its 5 px body over this one, and a
	# stroke narrower than the body only ever darkens what the body then covers. What has
	# to show is the halo either side.
	canvas.draw_polyline(shifted(local, style.shadow_offset * 1.2),
		Color(0.0, 0.0, 0.0, style.shadow_alpha * 2.4),
		style.shadow_width + style.thickness, true)


static func _bounds(points: PackedVector2Array) -> Rect2:
	var box := Rect2(points[0], Vector2.ZERO)
	for point: Vector2 in points:
		box = box.expand(point)
	return box


## Round off the corners a polyline leaves at its sharpest bends.
##
## draw_polyline miters its joins, which is invisible on a curve that turns gently and a
## spike on one that does not — and a cable to a module above has to turn right round,
## because both plugs point out of the panel and there is no other way out of a socket. It
## came out as a dart at the bottom of the hairpin.
##
## Only the sharp ones: a dot at every vertex would be forty draws a cable and four
## thousand a rack, to fix two of them.
static func _round_joins(canvas: CanvasItem, points: PackedVector2Array, offset: Vector2,
		colour: Color, width: float) -> void:
	if points.size() < 3:
		return
	for i in range(1, points.size() - 1):
		var into: Vector2 = (points[i] - points[i - 1]).normalized()
		var outof: Vector2 = (points[i + 1] - points[i]).normalized()
		# cos 25 degrees. Anything gentler than this the miter already covers.
		if into.dot(outof) < 0.906:
			canvas.draw_circle(points[i] + offset, width * 0.5, colour)


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

	# A capsule rather than a quad. The rectangle was the whole of why the barrel read
	# as a PCB header tab: hard corners along its length say "stamped flat part", and a
	# rounded end at each junction says "turned cylinder" — which is all a silhouette
	# this size can say about roundness, and enough.
	_quad(canvas, base, tip, across * half, Vector2.ZERO, body(style))
	canvas.draw_circle(base, half, body(style))
	canvas.draw_circle(tip, half, body(style))

	# The collar, loud on purpose. It ties the dark plug to its cable, keeps identity when
	# several plugs overlap, and at low zoom it is the last thing to survive — one bright
	# bar is enough to say which cable this is.
	var band_a := tip - along * style.band_width
	_quad(canvas, band_a, tip, across * half, Vector2.ZERO, colour)
	canvas.draw_circle(tip, half, colour)

	if level != Detail.ICON:
		# In the cable's own colour, barely darkened. It was 0.45, which made the relief
		# read as part of the hardware — a grey stalk between barrel and cable — when its
		# whole job is to be the moulded rubber of the cable gripping the plug: the
		# flexible half of the handshake, in the flexible part's colour.
		var relief_end := tip + along * style.relief_length
		_taper(canvas, tip, relief_end, style.relief_start * 0.5, t * 0.5,
			darken(colour, 0.18))

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


## The plug, in whichever grammar the available pixels support.
##
## Callers ask for a plug and get the right one; nothing above this has to know that there
## are four of them or where the thresholds are.
static func draw_plug_adaptive(canvas: CanvasItem, jack: Vector2, direction: Vector2,
		colour: Color, style: Style) -> void:
	match plug_lod(style):
		PlugLod.FULL: draw_plug_emergent(canvas, jack, direction, colour, style, true)
		PlugLod.SIMPLE: draw_plug_emergent(canvas, jack, direction, colour, style, false)
		_: draw_plug_topdown(canvas, jack, direction, colour, style)


## The barrel's colour on this faceplate.
static func body(style: Style) -> Color:
	return style._plug_body_light if style.panel_is_light else style._plug_body


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
		colour: Color, style: Style, full := true) -> void:
	var t := style.thickness
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
	# relief it casts what the cable casts. Separation reads as height more readily than
	# any amount of correct foreshortening.
	if full:
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
	# One shape, not two. There was a lit ellipse capping the barrel as well, which made
	# five or six tonal bands stacked between the socket and the cable — legible at 4x and
	# noise at 1x. Fewer, larger shapes read better and downscale better, and the
	# hierarchy the eye wants is only ever socket, collar, barrel, relief, cable.
	_taper(canvas, jack, tip, base_half, far_half, body(style))

	_ellipse_band(canvas, collar_at, along, collar_rx, collar_ry, 0.52, colour, 0.0, PI)

	var relief_end := tip + along * style.relief_length * (1.0 if full else 0.7)
	_taper(canvas, tip, relief_end, far_half * 0.92, t * 0.5, darken(colour, 0.45))

	if full:
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
	var radius := style.plug_width * t * 0.5

	_ellipse(canvas, jack, direction.normalized(), radius * 0.86, radius * 0.86, body(style))
	# A ring of cable colour inside the socket: the endpoint cue, with nothing pretending
	# to stand out of the panel.
	canvas.draw_arc(jack, radius * 0.62, 0.0, TAU, 28, colour, maxf(2.0, t * 0.5), true)
	# And nothing else. There was a strain relief here, a tapered wedge reaching a further
	# 14 px out of the socket, which is most of the way to the next jack — so the tier
	# chosen because the full plug would not fit went and did not fit either, by a
	# different route. A glyph that keeps one piece of the object it replaced is not a
	# glyph. Socket, bright ring, cable.


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
