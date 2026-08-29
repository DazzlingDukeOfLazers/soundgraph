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

## Screws at a graph node's scale. The rack's own 6.8 is sized for a rack module; four of
## those on a node this size read as bolts rather than as fasteners.
const SCREW := 4.2

var skin: Dictionary = {}
var radius := 6.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	resized.connect(queue_redraw)


func dress(new_skin: Dictionary, new_radius: float) -> void:
	skin = new_skin
	radius = new_radius
	queue_redraw()


func _draw() -> void:
	if skin.is_empty() or size.x <= 4.0 or size.y <= 4.0:
		return
	var plate := Rect2(Vector2.ZERO, size)

	# The finish first, under the edges rather than over them — a grain is in the paint
	# and the bevel is the shape of the metal under it.
	var finish := str(skin.get("finish", ""))
	if finish != "":
		# The rack's own figure. Grain runs 0.03 to 0.12 and the multiplier decides
		# everything: six put a 0.43 alpha over the mustard panel and the finish stopped
		# being a finish, it read as upholstery.
		var alpha := clampf(float(skin.get("grain", 0.06)) * 3.0
			* Faceplate.strength(finish), 0.0, 0.33)
		draw_texture_rect(Faceplate.texture(finish), plate, true,
			Color(1.0, 1.0, 1.0, alpha))

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

	# And the screws, which are the single cheapest thing that says "panel". Only where
	# there is room for them: a node narrow enough that its fasteners would land in the
	# lettering is better off with none.
	if size.x > SCREW * 12.0 and size.y > SCREW * 10.0:
		RackView.draw_screws(self, plate, SCREW, true, skin)
