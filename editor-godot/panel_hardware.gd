extends Control

## The parts of a graph node's faceplate that a stylebox cannot draw.
##
## A StyleBoxFlat gives one fill, one border colour and one corner radius, which is a
## coloured rectangle — and a coloured rectangle is exactly the thing the panels were
## being rejected for. A plate is an object: it has a lit edge along the top, a dark
## sidewall along the bottom where it turns away from the light, a finish, and screws
## holding it in a rack.
##
## All of it is drawn at the very edge of the node or on top of it as hardware, which is
## what makes it safe to draw above the node's own content: a GraphNode paints its panel
## and its port icons in its own _draw, so anything else can only come after. There is no
## text at the plate's edge and a screw is meant to sit on top.
##
## Shared with the rack rather than reimplemented — Rack.draw_screws puts the same screw
## on both, because a module seen in the graph and the same module seen in the rack are
## one object drawn twice.

const RackView := preload("res://rack.gd")
const Faceplate := preload("res://faceplate.gd")

## Screws at a graph node's scale.
##
## Four-two was chosen to be discreet and was simply too small to be anything: at 75% it
## is three pixels of grey and by 50% it is gone, which makes it decoration that only
## exists in the screenshot you designed it in. A detail either contributes at working
## zoom or it should not be drawn. Six is a fastener; it is also still under the rack's
## own 6.8, which is sized for a panel twice this size.
const SCREW := 6.0

var skin: Dictionary = {}
var radius := 6.0
## The colour round the outside: the plate's own edge, or the accent when the pointer is
## on the module or it is selected.
var outline := Color(0, 0, 0, 0)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	resized.connect(queue_redraw)


func dress(new_skin: Dictionary, new_radius: float, new_outline: Color) -> void:
	skin = new_skin
	radius = new_radius
	outline = new_outline
	queue_redraw()


## A rounded rectangle as a run of points, corners first.
static func _rounded(rect: Rect2, corner: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	var r := minf(corner, minf(rect.size.x, rect.size.y) * 0.5)
	var centres := [
		Vector2(rect.end.x - r, rect.position.y + r),
		Vector2(rect.end.x - r, rect.end.y - r),
		Vector2(rect.position.x + r, rect.end.y - r),
		Vector2(rect.position.x + r, rect.position.y + r),
	]
	for corner_index in 4:
		var from := -PI * 0.5 + corner_index * PI * 0.5
		for step in 5:
			var at: float = from + (PI * 0.5) * (float(step) / 4.0)
			points.append(centres[corner_index] + Vector2(cos(at), sin(at)) * r)
	points.append(points[0])
	return points


func _draw() -> void:
	if skin.is_empty() or size.x <= 4.0 or size.y <= 4.0:
		return
	var plate := Rect2(Vector2.ZERO, size)

	# The finish first, under the edges rather than over them — a grain is in the paint
	# and the bevel is the shape of the metal under it.
	var finish := str(skin.get("finish", ""))
	if finish != "":
		# The shared veil formula, so a module is exactly as grainy here as on the rack.
		draw_texture_rect(Faceplate.texture(finish), plate, true,
			Color(1.0, 1.0, 1.0,
				Faceplate.veil_alpha(finish, float(skin.get("grain", 0.06)))))

	# Lit along the top, dark along the bottom. One pixel each, inset past the corner
	# radius so neither line runs out into the rounding. This is the whole of the
	# "material rather than fill" problem: a plate that is a single flat colour reads as
	# paint on glass however good the colour is, and two hairlines are enough to make it
	# read as something with a thickness.
	var highlight: Color = skin.get("highlight", Color(0, 0, 0, 0))
	# panel_low, not panel_edge: the rack calls the white sheen along its left edge
	# "panel_edge", and the dark colour a plate is mounted in is panel_low.
	var sidewall: Color = skin.get("panel_low", Color(0, 0, 0, 0))
	var inset := radius * 0.7
	if highlight.a > 0.0:
		draw_line(Vector2(inset, 0.5), Vector2(size.x - inset, 0.5),
			Color(highlight, 0.85), 1.0)
		draw_line(Vector2(0.5, inset), Vector2(0.5, size.y - inset),
			Color(highlight, 0.45), 1.0)
	if sidewall.a > 0.0:
		draw_line(Vector2(inset, size.y - 0.5), Vector2(size.x - inset, size.y - 0.5),
			Color(sidewall, 0.9), 1.5)
		draw_line(Vector2(size.x - 0.5, inset), Vector2(size.x - 0.5, size.y - inset),
			Color(sidewall, 0.7), 1.0)

	# The I/O rail: a shallow recess behind a column of three or more sockets, so the
	# ports read as one piece of machined hardware rather than as a scatter of holes.
	# Geometry is read live from the widget at draw time — the ports are wherever the
	# layout put them, and asking any earlier is the ValueField lesson again.
	var widget := get_parent() as GraphNode
	if widget != null:
		for side in 2:
			var count := widget.get_output_port_count() if side == 0 \
				else widget.get_input_port_count()
			if count < 3:
				continue
			var top := INF
			var bottom := -INF
			for port in count:
				var at: Vector2 = widget.get_output_port_position(port) if side == 0 \
					else widget.get_input_port_position(port)
				top = minf(top, at.y)
				bottom = maxf(bottom, at.y)
			var pad := 15.0
			var rail_width := 27.0
			var rail := Rect2(size.x - rail_width if side == 0 else 0.0,
				top - pad, rail_width, bottom - top + pad * 2.0)
			var low: Color = skin.get("panel_low", Color(0, 0, 0, 0.2))
			draw_rect(rail, Color(low, 0.30))
			# The recess's inner wall: one rule on the panel side, muted, which is what
			# says "cut into the plate" instead of "stripe printed on it".
			var wall_x := rail.position.x if side == 0 else rail.end.x
			draw_line(Vector2(wall_x, rail.position.y), Vector2(wall_x, rail.end.y),
				Color(skin.get("muted", low), 0.5), 1.0)

	# The outline, drawn here rather than left to the styleboxes.
	#
	# A GraphNode is painted as two boxes — a titlebar and a body — and each of them can
	# carry one border colour on four sides. Whichever way those are set, the pair meet
	# in the middle of the panel, and any border either of them draws along that join is
	# a hairline ruled across the module under its title. That is the header rule this
	# pass set out to remove, and it came back through the one door left open: the join
	# is invisible only if neither box draws anything at all there. So neither does, and
	# the module's edge is one unbroken run of points around the outside.
	if outline.a > 0.0:
		draw_polyline(_rounded(plate.grow(-0.5), radius), outline, 1.0, true)

	# And the screws, which are the single cheapest thing that says "panel". Only where
	# there is room for them: a node narrow enough that its fasteners would land in the
	# lettering is better off with none.
	if size.x > SCREW * 12.0 and size.y > SCREW * 10.0:
		RackView.draw_screws(self, plate, SCREW, true, skin)
