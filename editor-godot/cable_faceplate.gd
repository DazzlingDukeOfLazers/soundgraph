extends RefCounted
## A fake module panel, because a cable in empty space is not the thing being judged.
##
## Every earlier sheet asked "what does this cable look like". This one asks the question
## that actually matters: does it look plugged into a synthesizer, or does it look like
## the endpoint of a graph connection? Those are told apart by a jack ring surviving
## around a plug, by cables crossing panel text instead of politely avoiding it, and by
## the whole construction still reading when the rack is zoomed out.

const CableArt := preload("res://cable_art.gd")

## Jacks on the panel, in panel-local coordinates, laid out as a module actually would be.
const JACKS := [
	{"at": Vector2(40, 232), "label": "IN"},
	{"at": Vector2(96, 232), "label": "CV"},
	{"at": Vector2(152, 232), "label": "GATE"},
	{"at": Vector2(208, 232), "label": "OUT"},
]

## Patches between them, and to the next module along, with the colours chosen to be the
## loud end of the palette.
const PATCHES := [
	{"from": 3, "to": 100, "colour": "cyan", "slack": "medium", "id": "a"},
	{"from": 1, "to": 101, "colour": "magenta", "slack": "loose", "id": "b"},
	{"from": 2, "to": 102, "colour": "chartreuse", "slack": "tight", "id": "c"},
]


static func draw_panel(canvas: CanvasItem, origin: Vector2, zoom: float,
		font: Font) -> void:
	var style: CableArt.Style = CableArt.Style.new().scaled(zoom)
	var panel: Color = Design.SURFACES[Design.Surface.NODE]
	var raised: Color = Design.SURFACES[Design.Surface.RAISED]
	var size := Vector2(250, 300) * zoom

	canvas.draw_rect(Rect2(origin, size), panel)
	canvas.draw_rect(Rect2(origin, size), Design.BORDERS[Design.Surface.NODE], false,
		maxf(1.0, zoom))

	# A neighbour to patch into, so at least one cable leaves the module rather than
	# looping back into it.
	var far := origin + Vector2(size.x + 90.0 * zoom, 0.0)
	canvas.draw_rect(Rect2(far, size), panel)
	canvas.draw_rect(Rect2(far, size), Design.BORDERS[Design.Surface.NODE], false,
		maxf(1.0, zoom))

	_panel_graphics(canvas, origin, zoom, font, raised, "SHAPER")
	_panel_graphics(canvas, far, zoom, font, raised, "DELAY")

	var here: Array = []
	for jack: Dictionary in JACKS:
		here.append(origin + jack["at"] * zoom)
	var there: Array = []
	for jack: Dictionary in JACKS:
		there.append(far + jack["at"] * zoom)

	# Wide enough that the ring survives around the plug. That ring is the whole tell:
	# with it the picture says "plugged into a synthesizer", without it the plug is just a
	# dark blob where a line stops.
	var radius: float = maxf(style.plug_width * style.thickness * 0.5 + 5.0 * zoom, 6.0)
	var socket: Color = Design.SURFACES[Design.Surface.CANVAS]

	for index in here.size():
		CableArt.draw_jack(canvas, here[index], radius, raised, socket.darkened(0.4))
		CableArt.draw_jack(canvas, there[index], radius, raised, socket.darkened(0.4))
		if zoom >= 0.5:
			var label: String = JACKS[index]["label"]
			var width := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1,
				int(9 * zoom)).x
			canvas.draw_string(font, here[index] + Vector2(-width * 0.5, radius + 12 * zoom),
				label, HORIZONTAL_ALIGNMENT_LEFT, -1, int(9 * zoom), Design.INK_SECOND)

	# Cables last, and over everything. Patch cords really do cover panel text; pretending
	# otherwise is what makes a rack look like a schematic editor.
	for patch: Dictionary in PATCHES:
		var a: Vector2 = here[patch["from"]]
		var b: Vector2 = there[patch["to"] - 100] if patch["to"] >= 100 \
			else here[patch["to"]]
		var colour: Color = CableArt.PALETTE[patch["colour"]]
		var slack: float = CableArt.SLACK[patch["slack"]]
		# Cables leave a faceplate towards the viewer, which in this projection is down.
		var out := Vector2(0.0, 1.0)
		var points := CableArt.cable_path(a, out, b, out, slack, style, patch["id"])
		CableArt.draw_cable(canvas, points, colour, style)
		CableArt.draw_plug(canvas, a, out, colour, style)
		CableArt.draw_plug(canvas, b, out, colour, style)


static func _panel_graphics(canvas: CanvasItem, origin: Vector2, zoom: float, font: Font,
		raised: Color, title: String) -> void:
	canvas.draw_string(font, origin + Vector2(14, 26) * zoom, title,
		HORIZONTAL_ALIGNMENT_LEFT, -1, int(13 * zoom), Design.INK_NORMAL)

	# Two knobs and a printed line, so there is something for a cable to cross.
	for i in 2:
		var centre := origin + Vector2(56 + i * 96, 96) * zoom
		var r := 26.0 * zoom
		canvas.draw_circle(centre + Vector2(1, 2) * zoom, r, Color(0, 0, 0, 0.25))
		canvas.draw_circle(centre, r, raised)
		canvas.draw_circle(centre, r * 0.92, CableArt.lighten(raised, 0.10))
		canvas.draw_line(centre, centre + Vector2(0.35, -0.94) * r * 0.8,
			Design.INK_NORMAL, maxf(1.0, 2.0 * zoom), true)

	if zoom >= 0.5:
		canvas.draw_string(font, origin + Vector2(14, 168) * zoom,
			"DRIVE   TONE   MIX", HORIZONTAL_ALIGNMENT_LEFT, -1, int(9 * zoom),
			Design.INK_SECOND)
