# The platonic view of a patch.
#
# Wires shows where somebody dragged things. Face shows the instrument. This shows the
# graph itself: what is connected to what, on a grid nobody has moved, laid out by the
# only thing that is actually true about a patch — which signals feed which.
#
# So positions are computed rather than stored, and dragging is not offered. A node sits
# in the column its distance from a source puts it in, and the columns march left to
# right the way the signal does. Two patches that mean the same thing look the same here
# even if one of them was drawn by somebody in a hurry.
#
# Read-only on purpose. The moment this could be rearranged it would need to remember the
# rearrangement, and then it would be a second Wires with worse tools. The whole value is
# that it owes nothing to how the file was drawn.
#
# The look is the one the web page uses for the same job: a card per node carrying its
# name, what kind of thing it is, and its id; audio along the thick lines and control
# along the thin ones.
extends Control

const ModuleThemes := preload("res://module_themes.gd")

## Card geometry. Fixed rather than measured: a grid whose cells change size with their
## contents is not a grid, and a long node name is elided instead — the id underneath is
## the unambiguous one, and it is right there.
const CARD := Vector2(286.0, 108.0)
const COLUMN_GAP := 86.0
const ROW_GAP := 40.0
const PADDING := 34.0
const RADIUS := 10.0

## How thick a cable is drawn, by what it carries. The caption on the web page is the
## whole legend: audio runs along the thick lines, control along the thin ones.
const AUDIO_WIDTH := 3.0
const CONTROL_WIDTH := 1.6

var patch: Dictionary = {}
var registry: Dictionary = {}
## node id -> Color, for the signal a node's first output carries. Supplied rather than
## worked out here, so this view uses the same colours as every other one.
var type_colours: Dictionary = {}

var _placed: Dictionary = {}     # node id -> Rect2, in this control's own space
var _content := Vector2.ZERO


## Recomputes the layout. Called when the document changes, not every frame.
func rebuild() -> void:
	_placed.clear()
	_content = Vector2.ZERO
	var nodes: Array = patch.get("nodes", [])
	if nodes.is_empty():
		custom_minimum_size = Vector2(CARD.x + PADDING * 2.0, CARD.y + PADDING * 2.0)
		queue_redraw()
		return

	var columns := _rank(nodes)
	var tallest := 0
	for column in columns:
		tallest = maxi(tallest, (column as Array).size())

	for index in columns.size():
		var column: Array = columns[index]
		var x := PADDING + index * (CARD.x + COLUMN_GAP)
		# Each column centred against the tallest, so a patch with one long spine and a
		# single modulator hanging off it reads as a spine with something hanging off it.
		var height := column.size() * CARD.y + maxi(column.size() - 1, 0) * ROW_GAP
		var full := tallest * CARD.y + maxi(tallest - 1, 0) * ROW_GAP
		var y := PADDING + (full - height) * 0.5
		for row in column.size():
			_placed[str(column[row])] = Rect2(Vector2(x, y + row * (CARD.y + ROW_GAP)), CARD)

	_content = Vector2(
		PADDING * 2.0 + columns.size() * CARD.x + maxi(columns.size() - 1, 0) * COLUMN_GAP,
		PADDING * 2.0 + tallest * CARD.y + maxi(tallest - 1, 0) * ROW_GAP)
	custom_minimum_size = _content
	size = _content
	queue_redraw()


## Which column each node belongs in: one past the furthest thing that feeds it.
##
## Longest path rather than shortest, so a node is always to the right of everything it
## depends on and a cable never runs backwards unless the patch itself has a loop. A
## feedback edge would make that unsatisfiable, so the walk is depth-limited and anything
## still unsettled lands in the column its best-known depth gives it - a cycle draws as a
## cable going back, which is honest, because that is what a cycle is.
func _rank(nodes: Array) -> Array:
	var depth: Dictionary = {}
	var feeders: Dictionary = {}
	for node in nodes:
		var id := str((node as Dictionary).get("id", ""))
		depth[id] = 0
		feeders[id] = []
	for connection in patch.get("connections", []):
		var from := str((connection as Dictionary).get("from", {}).get("node", ""))
		var to := str((connection as Dictionary).get("to", {}).get("node", ""))
		if depth.has(from) and depth.has(to):
			(feeders[to] as Array).append(from)

	# Relaxed until nothing moves, bounded by the node count: that is enough passes for
	# any acyclic graph and a hard stop for any other kind.
	for pass_index in nodes.size():
		var moved := false
		for id in depth:
			var want := 0
			for feeder in feeders[id]:
				want = maxi(want, int(depth[feeder]) + 1)
			if want > int(depth[id]):
				depth[id] = want
				moved = true
		if not moved:
			break

	var widest := 0
	for id in depth:
		widest = maxi(widest, int(depth[id]))
	var columns: Array = []
	for i in widest + 1:
		columns.append([])
	# Document order within a column, so the picture is stable: two runs of the same file
	# put the same node in the same place, which is the whole point of a platonic view.
	for node in nodes:
		var id := str((node as Dictionary).get("id", ""))
		(columns[int(depth[id])] as Array).append(id)
	return columns


func _draw() -> void:
	var font: Font = Design.font(Design.WEIGHT_SEMIBOLD)
	var small: Font = Design.font(Design.WEIGHT_MEDIUM)
	var mono: Font = Design.numeric_font()
	if font == null:
		font = get_theme_default_font()

	# The board the whole thing sits on.
	draw_rect(Rect2(Vector2.ZERO, _content), Design.SURFACES[Design.Surface.CANVAS])
	_rounded(Rect2(Vector2.ZERO, _content), RADIUS + 4.0,
		Design.SURFACES[Design.Surface.CANVAS])
	_rounded_outline(Rect2(Vector2.ZERO, _content), RADIUS + 4.0,
		Design.BORDERS[Design.Surface.NODE])

	_draw_cables()

	for id in _placed:
		_draw_card(str(id), _placed[id], font, small, mono)

	# The shared selection, in this lens's vocabulary: the same accent every view uses,
	# outlining the chosen module's card.
	if selected_id != "" and _placed.has(selected_id):
		draw_rect((_placed[selected_id] as Rect2).grow(3.0), Design.ACCENT, false, 2.0)


## Cables first, so a card always sits on top of the line that reaches it.
func _draw_cables() -> void:
	for connection in patch.get("connections", []):
		var entry: Dictionary = connection
		var from := str(entry.get("from", {}).get("node", ""))
		var to := str(entry.get("to", {}).get("node", ""))
		if not (_placed.has(from) and _placed.has(to)):
			continue
		var a: Rect2 = _placed[from]
		var b: Rect2 = _placed[to]
		var start := Vector2(a.end.x, a.position.y + a.size.y * 0.5)
		var finish := Vector2(b.position.x, b.position.y + b.size.y * 0.5)

		var signal_type := _signal_of(from, str(entry.get("from", {}).get("port", "")))
		var colour: Color = type_colours.get(signal_type, Design.INK_SECOND)
		var width := AUDIO_WIDTH if signal_type == "audio" else CONTROL_WIDTH

		# A flat run between neighbours, an S where the rows differ, and a loop around
		# the outside when the target is to the left - which only happens in a cycle.
		var points := PackedVector2Array()
		var reach := maxf(absf(finish.x - start.x) * 0.45, COLUMN_GAP * 0.5)
		var curve := Curve2D.new()
		curve.add_point(start, Vector2.ZERO, Vector2(reach, 0.0))
		curve.add_point(finish, Vector2(-reach, 0.0), Vector2.ZERO)
		points = curve.tessellate(4, 2.0)
		draw_polyline(points, colour, width, true)


## What a node's named output carries, from the registry. Unknown ports read as control,
## which is the quieter of the two and the safer thing to guess.
func _signal_of(node_id: String, port: String) -> String:
	for node in patch.get("nodes", []):
		if str((node as Dictionary).get("id", "")) != node_id:
			continue
		var type_name := str((node as Dictionary).get("type", ""))
		for outlet in registry.get(type_name, {}).get("outputs", []):
			if str((outlet as Dictionary).get("name", "")) == port:
				return str((outlet as Dictionary).get("type", "control"))
	return "control"


func _draw_card(id: String, box: Rect2, font: Font, small: Font, mono: Font) -> void:
	var node: Dictionary = {}
	for candidate in patch.get("nodes", []):
		if str((candidate as Dictionary).get("id", "")) == id:
			node = candidate
			break
	var type_name := str(node.get("type", ""))
	var descriptor: Dictionary = registry.get(type_name, {})
	var category := str(descriptor.get("category", ""))

	_rounded(box, RADIUS, Design.SURFACES[Design.Surface.RAISED])
	_rounded_outline(box, RADIUS, Design.BORDERS[Design.Surface.RAISED])

	var title := str(node.get("name", ""))
	if title == "":
		title = type_name
	var left := box.position.x + 18.0
	var room := box.size.x - 36.0

	draw_string(font, Vector2(left, box.position.y + 38.0),
		_elided(font, title, Design.type(Design.SIZE_BODY), room),
		HORIZONTAL_ALIGNMENT_LEFT, room, Design.type(Design.SIZE_BODY),
		Design.INK_BRIGHT)

	var beneath := type_name if category == "" else "%s · %s" % [type_name, category]
	if small != null:
		draw_string(small, Vector2(left, box.position.y + 64.0),
			_elided(small, beneath, Design.type(Design.SIZE_SECONDARY), room),
			HORIZONTAL_ALIGNMENT_LEFT, room, Design.type(Design.SIZE_SECONDARY),
			Design.INK_SECOND)

	# The id last, in the tabular face and the accent: it is the name the file uses and
	# the one somebody types when they go looking in the source.
	if mono != null:
		draw_string(mono, Vector2(left, box.position.y + 88.0), id,
			HORIZONTAL_ALIGNMENT_LEFT, room, Design.type(Design.SIZE_SECONDARY),
			Design.ACCENT)


func _elided(font: Font, text: String, at_size: int, room: float) -> String:
	if font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, at_size).x <= room:
		return text
	var cut := text
	while cut.length() > 1 and font.get_string_size(cut + "…",
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, at_size).x > room:
		cut = cut.substr(0, cut.length() - 1)
	return cut + "…"


## Godot draws rounded rectangles for styleboxes and not for canvas items, so the corners
## are four circles and two rectangles. Cheap, and it keeps the cards looking like the
## cards on the page this is modelled on.
func _rounded(box: Rect2, radius: float, colour: Color) -> void:
	var r := minf(radius, minf(box.size.x, box.size.y) * 0.5)
	draw_rect(Rect2(box.position + Vector2(r, 0.0),
		Vector2(box.size.x - r * 2.0, box.size.y)), colour)
	draw_rect(Rect2(box.position + Vector2(0.0, r),
		Vector2(box.size.x, box.size.y - r * 2.0)), colour)
	for corner in [Vector2(r, r), Vector2(box.size.x - r, r),
			Vector2(r, box.size.y - r), Vector2(box.size.x - r, box.size.y - r)]:
		draw_circle(box.position + corner, r, colour)


func _rounded_outline(box: Rect2, radius: float, colour: Color) -> void:
	var r := minf(radius, minf(box.size.x, box.size.y) * 0.5)
	draw_line(box.position + Vector2(r, 0.5),
		box.position + Vector2(box.size.x - r, 0.5), colour, 1.0)
	draw_line(box.position + Vector2(r, box.size.y - 0.5),
		box.position + Vector2(box.size.x - r, box.size.y - 0.5), colour, 1.0)
	draw_line(box.position + Vector2(0.5, r),
		box.position + Vector2(0.5, box.size.y - r), colour, 1.0)
	draw_line(box.position + Vector2(box.size.x - 0.5, r),
		box.position + Vector2(box.size.x - 0.5, box.size.y - r), colour, 1.0)
	for spec in [[Vector2(r, r), PI, PI * 1.5], [Vector2(box.size.x - r, r), PI * 1.5, TAU],
			[Vector2(box.size.x - r, box.size.y - r), 0.0, PI * 0.5],
			[Vector2(r, box.size.y - r), PI * 0.5, PI]]:
		draw_arc(box.position + (spec[0] as Vector2), r, spec[1], spec[2], 8, colour, 1.0, true)


## Where a node landed, for tests and for whatever wants to point at one.
## The shared selection: the module the editor considers chosen, whichever lens chose
## it. Drawn as an accent outline on this view's card, so selecting a filter in the
## graph and switching here keeps pointing at the same filter.
var selected_id := ""


func card_of(node_id: String) -> Rect2:
	return _placed.get(node_id, Rect2())


func content_size() -> Vector2:
	return _content
