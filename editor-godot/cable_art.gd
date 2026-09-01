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

	## How loudly this cable is drawn, from 1.0 at rest down to nearly nothing.
	##
	## Cable pass, goal 2. Focus in this program works by the field getting **quieter**,
	## not by the chosen route shouting: a focused cable is drawn at its ordinary resting
	## appearance and everything unrelated is suppressed. That is the whole mechanism, and
	## it is why this is a property of the cables that are *not* being looked at.
	##
	## Alpha only. Hue, width, path and the goal 1 knockout geometry are untouched, so a
	## suppressed cable is the same cable seen through less contrast — it still crosses
	## rather than joins, and it is still the colour it was.
	var prominence := 1.0

	## The colour a suppressed cable is mixed toward, which is the canvas it lies on.
	##
	## Suppression cannot be done by scaling alpha, and the first attempt proved it: a cord
	## is six stacked passes — two shadows, two shell strokes, a body and a highlight — and
	## scaling each one's alpha independently leaves the composite far more opaque than the
	## number suggests. At a nominal 45% the measured luminance ratio was 1.23, and at 25%
	## it was 1.44, so the three specimens were nearly the same picture and the nominal
	## figure meant nothing.
	##
	## Mixing toward the ground instead gives a reduction that lands where it is asked to.
	## Hue direction, width and path are untouched; what changes is contrast against the
	## canvas, which is what prominence means.
	var ground := Color(0.0, 0.0, 0.0, 0.0)

	## What this cable carries, for the goal 3 type cue. Audio is unmarked.
	var signal_class := 0

	## Points a type cue must keep clear of, in the same space as the route: the crossings
	## on this cord and its two ends.
	var cue_avoid := PackedVector2Array()

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

	# Goal 2. One multiplier applied to every pass, so a suppressed cable is the same
	# drawing at less contrast rather than a different drawing. Named rather than inlined
	# because it appears six times below and a stack where five passes dim and one does not
	# is a cable with a bright outline round it.
	var loud: float = clampf(style.prominence, 0.0, 1.0)
	# Toward the canvas by however much prominence was given up. A pass with no ground to
	# mix toward falls back to its own colour, so a caller that never sets one is
	# unaffected — which is every caller that does not suppress.
	var quiet := func(ink: Color) -> Color:
		if loud >= 1.0 or style.ground.a <= 0.0:
			return ink
		var mixed := ink.lerp(style.ground, 1.0 - loud)
		mixed.a = ink.a
		return mixed

	if level != Detail.ICON:
		# Two passes rather than one, which is the cheapest convincing softness there is:
		# a wide faint one that lands on the faceplate and a tighter one that sits under
		# the cable. One hard-edged shadow reads as a second cable drawn in black; this
		# reads as the panel darkening under something lying across it.
		canvas.draw_polyline(shifted(points, style.shadow_offset * 1.9),
			Color(0.0, 0.0, 0.0, style.shadow_alpha * 0.55 * loud),
			style.shadow_width + style.thickness * 0.7, true)
		canvas.draw_polyline(shifted(points, style.shadow_offset),
			Color(0.0, 0.0, 0.0, style.shadow_alpha * loud), style.shadow_width, true)

	var body_width := style.thickness * style.body_core
	if level == Detail.FULL:
		var edge: Color = quiet.call(darken(colour, style.edge_darken))
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

	var body: Color = quiet.call(colour)
	canvas.draw_polyline(points, body, body_width, true)
	_round_joins(canvas, points, Vector2.ZERO, body, body_width)
	# The highlight, and with it the goal 3 type cue. Every branch leaves the body and the
	# shell exactly as they were: the cue is spent out of the bright pass or laid on top of
	# it, and never out of the cord itself.
	var sheen := Color(quiet.call(lighten(colour, style.highlight_lighten)),
		style.highlight_alpha * loud)
	var lifted := shifted(points, style.highlight_offset)
	var cues: Dictionary = cue_sites(points, style)
	var marks: Array = cues["placed"]

	if marks.is_empty() or type_cue != TypeCue.HIGHLIGHT:
		canvas.draw_polyline(lifted, sheen, style.highlight_width, true)
	else:
		# Candidate A. The sheen becomes sparse strokes, single for control and paired for
		# event. Nothing is added: this cue costs *less* ink than the cable it is on, which
		# is why it was the preferred first specimen.
		for mark: Dictionary in marks:
			_draw_arc_run(canvas, lifted, points, float(mark["arc"]), CUE_STROKE, sheen,
				style.highlight_width)

	if not marks.is_empty() and type_cue == TypeCue.RIBS:
		# Candidate B. Short transverse marks laid across the cord, in the sheen's own ink
		# so they belong to the same material.
		for mark: Dictionary in marks:
			var across := Vector2(-(mark["along"] as Vector2).y,
				(mark["along"] as Vector2).x)
			var centre: Vector2 = mark["at"]
			canvas.draw_line(centre - across * style.thickness * 0.62,
				centre + across * style.thickness * 0.62, sheen,
				maxf(style.highlight_width, 1.0), true)

	if not marks.is_empty() and type_cue == TypeCue.STAMPS:
		# Candidate C, expected to lose and proved rather than assumed. The socket shapes
		# work because they live at the ends; a diamond in the middle of a cable is a
		# connector, a junction or a very small node.
		for mark: Dictionary in marks:
			var across := Vector2(-(mark["along"] as Vector2).y,
				(mark["along"] as Vector2).x)
			var centre: Vector2 = (mark["at"] as Vector2) + across * style.thickness * 1.1
			var radius: float = style.thickness * 0.34
			# The control socket's own diamond, repeated. Which is the reason this
			# candidate is expected to lose: the shape works at an endpoint because an
			# endpoint is where a socket is.
			canvas.draw_colored_polygon(PackedVector2Array([
				centre + Vector2(0.0, -radius), centre + Vector2(radius, 0.0),
				centre + Vector2(0.0, radius), centre + Vector2(-radius, 0.0)]), sheen)


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


## How a crossing is separated, and the harness hook that swaps the construction.
##
## Cable pass, goal 1. The measured defect is narrow and it is worth restating, because a
## general "improve crossings" would be the wrong work: the baseline found **zero** shallow
## crossings in the hostile patch — Goal 6's per-cable hang and Goal 7's departure splay
## have already made every intersection transverse — and fifteen of the thirty-two are
## between cables of the *same colour*. So the target is exactly:
##
## > At a transverse crossing between visually identical cables, a reader can immediately
## > tell which strand continues through the intersection.
##
## Named for what it does rather than for one candidate's geometry. "Bridge" would smuggle
## in the bump.
##
## [codeblock]
## NONE       nothing; the reference, so the sheet shows what a treatment is buying
## HALO       a darker halo under the upper cable — the incumbent, shipped since goal 8
## KNOCKOUT   the lower cable erased for a short span, and the upper drawn over the gap
## BUMP       the upper cable locally lifted into an arc
## [/codeblock]
enum Crossing { NONE, HALO, KNOCKOUT, BUMP }

## Set by `crossing_sheet.gd` while it renders the comparison, and by nothing else.
##
## KNOCKOUT since goal 1. The sheet put all four on the same twelve same-colour crossings
## and the reference column settled it: with nothing at all the two strands fuse into a
## lozenge, and the halo — the incumbent — barely changes that, because darkening the upper
## cable's underside says nothing when the cable underneath is the same colour. The knockout
## reads immediately as one line passing over another, and it does it while adding
## twenty-two units of ink across twelve crossings against the bump's thirteen hundred.
static var crossing_style := Crossing.KNOCKOUT

## Whether the treatment is applied only where both cables are the same colour.
##
## **False, since goal 1.1, and this is a harness hook rather than a setting.** The sheet
## rendered both and the conditional rule lost on meaning rather than on ink.
##
## What a knockout says is *these two paths cross here; they do not join*, and that is true
## of a blue crossing a blue and equally true of a blue crossing a green. Applying it only
## where the hues happen to coincide makes its presence a fact about the palette rather than
## about the graph — an unexplained channel that looks like it means something, and whose
## real rule no reader can recover. The cost of dropping the condition was forty-two ink
## units across fifteen more crossings, which is nothing.
##
## So the grammar is now as simple as it can be:
##
## > **A gap means a crossing. A continuous meeting means a connection.**
static var crossing_same_colour_only := false

## How a cable says what it carries, other than by being that colour.
##
## Cable pass, goal 3, and it closes the accessibility defect the node QA found: socket
## shape carries the signal type at both ends and survives a grayscale render, and the
## cable between them carries hue and nothing else. The requirement is narrow —
##
## > Given a mid-span crop with the endpoints unavailable and the hue removed, identify the
## > cable's signal class, without mistaking the cue for a junction, a crossing, a direction
## > arrow or activity.
##
## — and the body of the cable is not redesigned to meet it. **No candidate breaks the
## body.** A dashed wire is a different object; every one of these leaves the cord solid and
## spends only what it has to.
##
## [codeblock]
## NONE       no cue at all; the reference
## HIGHLIGHT  the existing bright pass, interrupted into sparse strokes
## RIBS       short transverse marks laid across the cord at intervals
## STAMPS     the socket shapes, repeated beside the route
## [/codeblock]
enum TypeCue { NONE, HIGHLIGHT, RIBS, STAMPS }

## What a cable carries, as far as its own middle is concerned.
##
## **Two, because SoundGraph has two.** Goal 3.0 enumerated all 182 ports on all 51 runtime
## types: 78 audio, 104 control, and **not one** declaring event or note — none falling back
## to a default either, every declaration explicit. `SignalType::Event` and `SignalType::Note`
## exist in dsp-core, `signal_types_compatible` enforces them as message types that do not
## interconvert with streams, and no node in the library emits one. In dsp-core they appear
## only in the two functions that turn them into strings and back.
##
## So a paired event cadence would be a visually elegant grammar for a class this program
## does not have. The socket vocabulary already advertises four shapes for two realities;
## the cables are not going to make that worse.
##
## **Audio is unmarked.** It is the commonest cable in every patch and the strongest thing
## in the resting language, so the additional ink belongs to the class that is not the
## default. Continuous is audio; a sparse cadence is control.
##
## If a node ever declares an event or note port, this reopens — and it reopens *here*,
## because the cue is derived from the graph model and not from the socket shape. See
## docs/cables.md, goal 3.0.
enum SignalClass { AUDIO, CONTROL }

## RIBS, and it was not the expected winner either.
##
## The endpoint-free grayscale sheet was brutal about it. With nothing at all, the two
## classes are the same picture — the defect, confirmed. The **highlight cadence**, the
## preferred first specimen, produces an interruption so slight that it cannot be found
## without knowing where to look: spending the sheen was elegant and it does not carry.
## The **stamps** are legible and fail the other half of the requirement — a diamond beside
## a cable reads as a connector or a very small node, exactly as predicted. The **ribs** are
## small, quiet, plainly visible, and read as marks on the cable rather than as objects
## beside it.
##
## And the integration frame agrees: at 100% in the hostile graph the ribs are barely
## noticeable, and nothing about the patch reads as decorated.
##
## Caveat worth keeping: the identification was done by somebody holding the answer key.
## The shuffled test is still worth a human doing.
static var type_cue := TypeCue.RIBS

## Screen pixels between one type cue and the next.
##
## **Screen space, not graph space**, and that is the whole of the geometry rule. A cadence
## measured in graph units is absurdly sparse when you zoom in and plaid when you zoom out;
## measured on the glass it stays about the same however far away the patch is.
const CUE_CADENCE := 160.0

## How much of the cable one cue occupies.
const CUE_STROKE := 20.0

## How far a cue keeps away from anything that already means something.
##
## The precedence, which is not negotiable:
##
## > **connection and crossing geometry > type cue > focus prominence**
##
## And the corollary, written down so that nobody later "fixes" this by plastering ribs onto
## every short segment:
##
## > **Cable type cues are sparse and redundant, not locally guaranteed. A cue may be
## > omitted wherever connection, crossing or bend geometry has the higher priority.**
##
## The blind test is what earns that. Fourteen endpoint-free crops named fourteen times —
## and the one crop that could not be classified was taken inside a crossing, where the
## exclusion had refused a rib. That is the hierarchy working. A cable has to offer enough
## sparse evidence along its route to identify its class; no arbitrary twenty pixels of it
## has to.
##
## A knockout says two paths cross and do not join. If a periodic cadence were allowed to
## put a mark inside one, the cadence would be deciding that a crossing has a dash in it,
## and the crossing grammar goal 1 just finished would be the thing that gave way.
const CUE_CLEARANCE := 26.0

## And a turn sharper than this is no place for a mark: a transverse rib on a bend is not
## transverse to anything, and a highlight stroke across a corner reads as a kink.
const CUE_BEND := 35.0


## Where the type cues fall along a route, and how many were refused.
##
## Split out and pure for the reason `fit_for` and `cell_reaches` are: the proof sheet has
## to be able to ask where the marks are and how many the exclusions ate, and a sheet that
## works that out for itself is a second implementation of the placement rule that can
## agree with the geometry while disagreeing with the picture.
##
## `avoid` is in the same space as `points` — the crossings on this cord and its two ends.
static func cue_sites(points: PackedVector2Array, style: Style) -> Dictionary:
	var placed: Array = []
	var skipped := 0
	if points.size() < 2 or style.signal_class == SignalClass.AUDIO 			or type_cue == TypeCue.NONE:
		return {"placed": placed, "skipped": 0, "length": _arc_length(points)}
	var total := _arc_length(points)
	# Half a cadence in from each end, so a route carries whole cues rather than starting
	# with a fragment of one.
	var at := CUE_CADENCE * 0.5
	while at < total:
		var found := _at_arc(points, at)
		var here: Vector2 = found["at"]
		var refused := false
		# The ends of the cable belong to the sockets and the plugs.
		if at < CUE_CLEARANCE or total - at < CUE_CLEARANCE:
			refused = true
		for other: Vector2 in style.cue_avoid:
			if here.distance_to(other) < CUE_CLEARANCE:
				refused = true
				break
		if not refused and float(found["bend"]) > CUE_BEND:
			refused = true
		if refused:
			skipped += 1
		else:
			placed.append({"at": here, "along": found["along"], "arc": at})
		at += CUE_CADENCE
	return {"placed": placed, "skipped": skipped, "length": total}


static func _arc_length(points: PackedVector2Array) -> float:
	var total := 0.0
	for i in range(points.size() - 1):
		total += points[i].distance_to(points[i + 1])
	return total


## Position, heading and local bend at a distance along a path.
static func _at_arc(points: PackedVector2Array, distance: float) -> Dictionary:
	var walked := 0.0
	for i in range(points.size() - 1):
		var span := points[i].distance_to(points[i + 1])
		if span <= 0.0001:
			continue
		if walked + span >= distance:
			var t := (distance - walked) / span
			var along := (points[i + 1] - points[i]) / span
			# How much the path turns across this cue's own footprint, which is what
			# decides whether there is a straight enough place to put a mark.
			var before := along
			var after := along
			if i > 0:
				before = (points[i] - points[i - 1]).normalized()
			if i + 2 < points.size():
				after = (points[i + 2] - points[i + 1]).normalized()
			var bend := rad_to_deg(acos(clampf(before.dot(after), -1.0, 1.0)))
			return {"at": points[i].lerp(points[i + 1], t), "along": along, "bend": bend}
		walked += span
	return {"at": points[points.size() - 1], "along": Vector2.RIGHT, "bend": 0.0}


## The suppression levels goal 2 proofs, and the one it shipped.
##
## Starting specimens rather than tokens: three points across the plausible range, judged on
## the hostile graph, choosing the quietest background at which the topology of the rest of
## the patch is still readable. A background that vanishes has not been suppressed, it has
## been deleted, and a reader who cannot see where the other cables go cannot tell what the
## focused one is threading through.
const SUPPRESSION_LEVELS := [0.65, 0.45, 0.25]

## What an unrelated cable is drawn at while something else is focused.
##
## 0.25, which is the quietest of the three specimens and was not the expected winner. The
## prior was 40-50%, and it was a good prior for a mechanism that delivers its nominal
## figure. This one does not: the number is a mix toward the canvas and the *achieved*
## luminance ratio between a focused cable and the field is what a reader actually receives.
##
## [codeblock]
## nominal   focused keeps   background keeps   ratio
##   0.65        1.002            0.814          1.23
##   0.45        1.000            0.710          1.41
##   0.25        0.998            0.608          1.64
## [/codeblock]
##
## So 1.64 is the figure to carry forward, not 0.25. If the mechanism ever changes, re-derive
## the nominal from the ratio rather than keeping this number.
##
## At 0.25 the hostile graph still reads: every suppressed cable is visible, the topology of
## the rest of the patch is intact, and nothing has vanished — which is the stated win
## condition, the quietest background that still leaves the network there. At 0.45 the
## focused route is hard to pick out of the field at 40%.
static var suppression := 0.25

## Clearance either side of the upper cable, as a fraction of its own width. The gap has to
## read as a gap and not as a nick, and it must not be so wide that the lower cable looks
## cut in half rather than passed over.
const KNOCKOUT_CLEARANCE := 0.55

## How far a bump lifts, and over what span, as fractions of the cable's own width.
const BUMP_LIFT := 1.15
const BUMP_SPAN := 3.0


## A short piece of a path, centred on a point, following the path rather than a chord.
##
## The halo below takes every vertex within a radius, which on a smooth curve can find
## fewer than two and on a bendy one finds a piece whose length is nothing like the radius.
## A knockout has to be a specific length — the upper cable's width plus clearance — so it
## walks the path instead.
static func span_at(points: PackedVector2Array, at: Vector2,
		half_length: float) -> PackedVector2Array:
	if points.size() < 2:
		return PackedVector2Array()
	# The segment the point lies on, by distance rather than by containment: `at` comes
	# from an intersection test and is on the segment to within floating point, not on it.
	var best := 0
	var nearest := INF
	for i in points.size() - 1:
		var closest := Geometry2D.get_closest_point_to_segment(at, points[i],
			points[i + 1])
		var away := closest.distance_squared_to(at)
		if away < nearest:
			nearest = away
			best = i
	var out := PackedVector2Array([at])
	# Backwards along the path, then forwards, accumulating real length.
	var left := half_length
	var i := best
	var from := at
	while left > 0.0 and i >= 0:
		var step := from.distance_to(points[i])
		if step >= left:
			out.insert(0, from + (points[i] - from).normalized() * left)
			left = 0.0
		else:
			out.insert(0, points[i])
			left -= step
			from = points[i]
			i -= 1
	if left > 0.0 and out.size() >= 2:
		# Ran off the end of the path: extend along its own last direction rather than
		# stopping short, so a crossing near an endpoint still gets a full-length gap.
		var heading := (out[0] - out[1]).normalized()
		out.insert(0, out[0] + heading * left)
	left = half_length
	i = best + 1
	from = at
	while left > 0.0 and i < points.size():
		var step := from.distance_to(points[i])
		if step >= left:
			out.append(from + (points[i] - from).normalized() * left)
			left = 0.0
		else:
			out.append(points[i])
			left -= step
			from = points[i]
			i += 1
	if left > 0.0 and out.size() >= 2:
		var heading := (out[out.size() - 1] - out[out.size() - 2]).normalized()
		out.append(out[out.size() - 1] + heading * left)
	return out


## The lower cable erased where the upper one passes over it.
##
## Nothing is added on top: the gap is cut in the ground colour and the upper cable is then
## drawn by the ordinary path, unchanged. That is the whole claim — *these lines cross and
## do not join* — said with the least ink of the three, and said only where it is needed.
##
## Cut along the **lower** cable and across its full drawn extent, shadow included. A gap
## that erases the body and leaves the shadow reads as a cable with a bruise on it. Two
## passes for the same reason `draw_cable` lays two shadows: the wide offset one first,
## then the tight one.
##
## No dot, no ring, no taper. Anything that closes across the gap becomes a junction mark,
## and a junction mark on a patch cable is a claim that two signals meet.
static func draw_crossing_knockout(canvas: CanvasItem, lower: PackedVector2Array,
		at: Vector2, style: Style, ground: Color) -> void:
	var half: float = style.thickness * (0.5 + KNOCKOUT_CLEARANCE)
	var gap := span_at(lower, at, half)
	if gap.size() < 2:
		return
	var opaque := Color(ground.r, ground.g, ground.b, 1.0)
	canvas.draw_polyline(shifted(gap, style.shadow_offset * 1.9), opaque,
		style.shadow_width + style.thickness * 0.7, true)
	canvas.draw_polyline(shifted(gap, style.shadow_offset), opaque,
		style.shadow_width, true)
	canvas.draw_polyline(gap, opaque, style.thickness + style.edge_offset.length() * 2.0,
		true)


## The upper cable's path, lifted into a local arc where it crosses.
##
## The third candidate, and the one expected to lose: it is the most explicit silhouette of
## the three and it is the only one that says something untrue. The route is a fact about
## the patch, and a cable that visibly detours around another cable has been drawn going
## somewhere it does not go. It also reads as printed-circuit crossover notation, which is
## a different language from a patch cable.
##
## Drawn from a displaced copy, so the route itself and the connection coordinates are
## untouched — the distortion is in the picture and not in the document.
static func bumped(points: PackedVector2Array, ats: Array,
		style: Style) -> PackedVector2Array:
	if ats.is_empty() or points.size() < 2:
		return points
	var span: float = style.thickness * BUMP_SPAN
	var lift: float = style.thickness * BUMP_LIFT
	var out := PackedVector2Array()
	for i in points.size():
		var point := points[i]
		var heading: Vector2 = (points[mini(i + 1, points.size() - 1)]
			- points[maxi(i - 1, 0)]).normalized()
		if heading == Vector2.ZERO:
			out.append(point)
			continue
		# One consistent side, always. Alternating would encode something, and the
		# constraint is that a crossing mark says nothing about direction or about which
		# cable matters more.
		var side := Vector2(-heading.y, heading.x)
		var push := 0.0
		for at: Vector2 in ats:
			var away := point.distance_to(at)
			if away < span:
				push = maxf(push, lift * cos(PI * 0.5 * away / span))
		out.append(point + side * push)
	return out


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


## A short run of a path, drawn from the path itself rather than from a chord.
##
## The stroke has to follow the cable: a straight segment laid across a curve is a chord,
## and at cable width the difference reads as the mark sitting beside the cord instead of
## on it.
static func _draw_arc_run(canvas: CanvasItem, lifted: PackedVector2Array,
		points: PackedVector2Array, middle: float, run: float, ink: Color,
		width: float) -> void:
	var total := _arc_length(points)
	var from := clampf(middle - run * 0.5, 0.0, total)
	var to := clampf(middle + run * 0.5, 0.0, total)
	if to - from < 1.0:
		return
	var piece := PackedVector2Array()
	var walked := 0.0
	var offset: Vector2 = lifted[0] - points[0]
	for i in range(points.size() - 1):
		var span := points[i].distance_to(points[i + 1])
		if span <= 0.0001:
			continue
		var start := walked
		var finish := walked + span
		if finish >= from and start <= to:
			var a := clampf((from - start) / span, 0.0, 1.0)
			var b := clampf((to - start) / span, 0.0, 1.0)
			if piece.is_empty():
				piece.append(points[i].lerp(points[i + 1], a) + offset)
			piece.append(points[i].lerp(points[i + 1], b) + offset)
		walked = finish
	if piece.size() >= 2:
		canvas.draw_polyline(piece, ink, width, true)


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
