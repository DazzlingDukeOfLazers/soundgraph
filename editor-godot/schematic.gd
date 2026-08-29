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
# A schematic rather than a dependency graph, which is a distinction of grammar: wires
# terminate at named terminals rather than on card edges, they run in right angles the
# way a reader traces them with a finger, and their colour says what kind of signal is
# on them. The question this view answers is "what signal goes where, and what does each
# connection mean" — the graph already answers "what exists and how do I change it".
extends Control

const ModuleThemes := preload("res://module_themes.gd")
## For face_text — a terminal is labelled the way the panel labels its socket.
const RackView := preload("res://rack.gd")

## Card geometry. The width is fixed — a grid whose columns change width is not a grid —
## but the height follows the ports: a filter with four inputs needs four terminals, and
## terminals that overlap are not terminals.
const CARD_WIDTH := 286.0
## The header: two lines now, name and kind. The id lost its permanent line — it is
## revealed on the selected card instead, because at overview scale the diagram should
## privilege signal understanding over file bookkeeping.
const HEADER_HEIGHT := 58.0
const PORT_PITCH := 21.0
const CARD_PAD_BOTTOM := 14.0
const MIN_CARD_HEIGHT := 96.0
const COLUMN_GAP := 86.0
const ROW_GAP := 40.0
const PADDING := 34.0
const RADIUS := 10.0

## How thick a cable is drawn, by what it carries: audio along the thick lines, control
## along the thin ones — same rule as everywhere else in the editor.
const AUDIO_WIDTH := 3.0
const CONTROL_WIDTH := 1.6
## A terminal's dot, and the stub that carries the wire clear of the card edge.
const PORT_RADIUS := 3.4
const STUB := 10.0

var patch: Dictionary = {}
var registry: Dictionary = {}
## node id -> Color, for signals by type. Supplied rather than worked out here, so this
## view uses the same colours as every other one.
var type_colours: Dictionary = {}

## The shared selection: the module the editor considers chosen, whichever lens chose
## it. Drawn as an accent outline on this view's card, so selecting a filter in the
## graph and switching here keeps pointing at the same filter. Selection is also this
## view's progressive disclosure: the selected card shows its id.
var selected_id := ""

var _placed: Dictionary = {}     # node id -> Rect2, in this control's own space
var _content := Vector2.ZERO


## Recomputes the layout. Called when the document changes, not every frame.
func rebuild() -> void:
	_placed.clear()
	_content = Vector2.ZERO
	var nodes: Array = patch.get("nodes", [])
	if nodes.is_empty():
		custom_minimum_size = Vector2(CARD_WIDTH + PADDING * 2.0,
			MIN_CARD_HEIGHT + PADDING * 2.0)
		queue_redraw()
		return

	var columns := _rank(nodes)
	# Column heights are the sum of their cards now that cards size to their ports.
	var column_heights: Array = []
	var tallest := 0.0
	for column in columns:
		var height := 0.0
		for id in column:
			height += _card_height(str(id))
		height += maxf((column as Array).size() - 1, 0) * ROW_GAP
		column_heights.append(height)
		tallest = maxf(tallest, height)

	for index in columns.size():
		var column: Array = columns[index]
		var x := PADDING + index * (CARD_WIDTH + COLUMN_GAP)
		# Each column centred against the tallest, so a patch with one long spine and a
		# single modulator hanging off it reads as a spine with something hanging off it.
		var y := PADDING + (tallest - float(column_heights[index])) * 0.5
		for id in column:
			var height := _card_height(str(id))
			_placed[str(id)] = Rect2(Vector2(x, y), Vector2(CARD_WIDTH, height))
			y += height + ROW_GAP

	_content = Vector2(
		PADDING * 2.0 + columns.size() * CARD_WIDTH
			+ maxi(columns.size() - 1, 0) * COLUMN_GAP,
		PADDING * 2.0 + tallest)
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


# ---------------------------------------------------------------------------------
# What a node is, asked of the document and the registry
# ---------------------------------------------------------------------------------

func _node_of(id: String) -> Dictionary:
	for candidate in patch.get("nodes", []):
		if str((candidate as Dictionary).get("id", "")) == id:
			return candidate
	return {}


func _descriptor_of(id: String) -> Dictionary:
	return registry.get(str(_node_of(id).get("type", "")), {})


## The reading class of a node, from this patch's own wiring rather than from its type:
## nothing feeds it, it is a source; it feeds nothing, it is a sink; a
## modulation-category node is a modulator; everything else processes. The wiring is the
## truer answer — the Keyboard's type has a host input and is still where this patch's
## signal begins — and it is what the reader is looking at. The cue this feeds is
## deliberately subtle: an edge tick, not a costume.
func _node_class(id: String) -> String:
	var fed := false
	var feeds := false
	for connection in patch.get("connections", []):
		if str((connection as Dictionary).get("to", {}).get("node", "")) == id:
			fed = true
		if str((connection as Dictionary).get("from", {}).get("node", "")) == id:
			feeds = true
	# Modulation first: an LFO is fed by nothing, and calling it a source because of
	# that files it with the Keyboard — but what makes it what it is, is what it does,
	# and the brief's own classing puts the envelope (which is fed) beside it.
	if str(_descriptor_of(id).get("category", "")).to_lower() == "modulation":
		return "modulator"
	if not feeds and fed:
		return "sink"
	if not fed and feeds:
		return "source"
	return "processor"


func _card_height(id: String) -> float:
	var descriptor := _descriptor_of(id)
	var rows := maxi((descriptor.get("inputs", []) as Array).size(),
		(descriptor.get("outputs", []) as Array).size())
	return maxf(MIN_CARD_HEIGHT, HEADER_HEIGHT + rows * PORT_PITCH + CARD_PAD_BOTTOM)


## Where a named terminal sits, in this control's space. Public because it is the
## contract the wires and the tests both draw against: a wire that does not end on the
## answer to this question is a wire drawn to the wrong place.
func port_point(id: String, port: String, is_input: bool) -> Vector2:
	var box: Rect2 = _placed.get(id, Rect2())
	if box.size.x <= 0.0:
		return Vector2.ZERO
	var ports: Array = _descriptor_of(id).get("inputs" if is_input else "outputs", [])
	for index in ports.size():
		if str((ports[index] as Dictionary).get("name", "")) == port:
			return Vector2(box.position.x if is_input else box.end.x,
				box.position.y + HEADER_HEIGHT + (index + 0.5) * PORT_PITCH)
	# A port the registry does not name (a ghost, an older file): the card's edge
	# midpoint, which is where every wire used to land.
	return Vector2(box.position.x if is_input else box.end.x, box.get_center().y)


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
##
## Right angles, not curves. A schematic is read by tracing, and a finger tracing a wire
## wants runs and corners: out of the source terminal, along to the target's column,
## down or up to the target's row, and in through its terminal. Each wire takes its own
## vertical lane in the gap before the target column, so parallel drops sit beside each
## other instead of on top of each other, and every crossing that remains is a clean
## perpendicular — which cannot be mistaken for a junction, and there are no junctions:
## signals here join only at a terminal.
func _draw_cables() -> void:
	var lane := 0
	for connection in patch.get("connections", []):
		var entry: Dictionary = connection
		var from := str(entry.get("from", {}).get("node", ""))
		var to := str(entry.get("to", {}).get("node", ""))
		if not (_placed.has(from) and _placed.has(to)):
			continue
		var start := port_point(from, str(entry.get("from", {}).get("port", "")), false)
		var finish := port_point(to, str(entry.get("to", {}).get("port", "")), true)

		var signal_type := _signal_of(from, str(entry.get("from", {}).get("port", "")))
		var colour: Color = type_colours.get(signal_type, Design.INK_SECOND)
		# Quiet at rest. The diagram is the hero and a rack of full-strength candy
		# fights it; emphasis belongs to selection and probing, later.
		colour = Color(colour, 0.85 if signal_type == "audio" else 0.78)
		var width := AUDIO_WIDTH if signal_type == "audio" else CONTROL_WIDTH

		var points := PackedVector2Array()
		if finish.x > start.x:
			# The lane: a vertical slot in the gap ahead of the target column, stepped
			# per wire so no two drops share an x.
			var trunk := (_placed[to] as Rect2).position.x - COLUMN_GAP * 0.35 \
				- float(lane % 6) * 7.0
			trunk = maxf(trunk, start.x + STUB + 4.0)
			points.append(start)
			points.append(Vector2(start.x + STUB, start.y))
			points.append(Vector2(trunk, start.y))
			points.append(Vector2(trunk, finish.y))
			points.append(Vector2(finish.x - STUB, finish.y))
			points.append(finish)
		else:
			# Backwards means a cycle, and a cycle is drawn as what it is: a wire going
			# around the outside, under the rows, back to the left.
			var below := maxf((_placed[from] as Rect2).end.y,
				(_placed[to] as Rect2).end.y) + ROW_GAP * 0.6 + float(lane % 6) * 6.0
			points.append(start)
			points.append(Vector2(start.x + STUB + float(lane % 6) * 5.0, start.y))
			points.append(Vector2(start.x + STUB + float(lane % 6) * 5.0, below))
			points.append(Vector2(finish.x - STUB - 6.0, below))
			points.append(Vector2(finish.x - STUB - 6.0, finish.y))
			points.append(finish)
		lane += 1
		draw_polyline(points, colour, width, true)
		# The arrowhead: direction, said once, at the terminal where it matters.
		draw_colored_polygon(PackedVector2Array([finish,
			finish + Vector2(-6.0, -3.4), finish + Vector2(-6.0, 3.4)]), colour)


## What a node's named output carries, from the registry. Unknown ports read as control,
## which is the quieter of the two and the safer thing to guess.
func _signal_of(node_id: String, port: String) -> String:
	var descriptor := _descriptor_of(node_id)
	for outlet in descriptor.get("outputs", []):
		if str((outlet as Dictionary).get("name", "")) == port:
			return str((outlet as Dictionary).get("type", "control"))
	return "control"


func _draw_card(id: String, box: Rect2, font: Font, small: Font, mono: Font) -> void:
	var node := _node_of(id)
	var type_name := str(node.get("type", ""))
	var descriptor: Dictionary = registry.get(type_name, {})
	var category := str(descriptor.get("category", ""))

	_rounded(box, RADIUS, Design.SURFACES[Design.Surface.RAISED])
	# A whisper of header, so the name zone and the terminal zone read as two registers
	# of one block rather than one card of text.
	draw_rect(Rect2(box.position + Vector2(1.0, RADIUS),
		Vector2(box.size.x - 2.0, HEADER_HEIGHT - RADIUS - 6.0)),
		Color(1.0, 1.0, 1.0, 0.025))
	_rounded_outline(box, RADIUS, Design.BORDERS[Design.Surface.RAISED])

	# The endpoint cue: a tick of accent on the edge the world is on. A source's left
	# edge faces silence and a sink's right edge faces the listener; marking those two
	# says "this row starts here and ends there" without costuming anything.
	var reading := _node_class(id)
	if reading == "source":
		draw_rect(Rect2(box.position + Vector2(0.0, RADIUS),
			Vector2(2.5, box.size.y - RADIUS * 2.0)), Color(Design.ACCENT, 0.55))
	elif reading == "sink":
		draw_rect(Rect2(Vector2(box.end.x - 2.5, box.position.y + RADIUS),
			Vector2(2.5, box.size.y - RADIUS * 2.0)), Color(Design.ACCENT, 0.55))

	var title := str(node.get("name", ""))
	if title == "":
		title = type_name
	var left := box.position.x + 18.0
	var room := box.size.x - 36.0

	draw_string(font, Vector2(left, box.position.y + 26.0),
		_elided(font, title, Design.type(Design.SIZE_BODY), room),
		HORIZONTAL_ALIGNMENT_LEFT, room, Design.type(Design.SIZE_BODY),
		Design.INK_BRIGHT)

	# Two lines, not three. The kind-line earns its place; the id spent years on the
	# third line saying something only the file cares about, and it now appears only on
	# the selected card — selection is this view's hover.
	var beneath := type_name if category == "" else "%s · %s" % [type_name, category]
	if small != null:
		var kind := beneath if selected_id != id or mono == null \
			else "%s · %s" % [beneath, id]
		draw_string(small, Vector2(left, box.position.y + 46.0),
			_elided(small, kind, Design.type(Design.SIZE_SECONDARY), room),
			HORIZONTAL_ALIGNMENT_LEFT, room, Design.type(Design.SIZE_SECONDARY),
			Design.INK_SECOND)

	# A modulator wears a thread of its tint under the name — the one class whose
	# difference is what it does rather than where it sits.
	if reading == "modulator":
		draw_rect(Rect2(left, box.position.y + 32.0, 42.0, 1.5),
			Color(RackView.category_tint(category), 0.7))

	_draw_ports(id, box, small)


## The terminals: a dot on the edge, a stub, and the port's own name in the panel's own
## words. Inputs down the left, outputs down the right, in descriptor order — the wire
## ends at the dot, which is what makes this a schematic and not a diagram of cards.
func _draw_ports(id: String, box: Rect2, small: Font) -> void:
	var descriptor := _descriptor_of(id)
	var label_size := maxi(Design.type(Design.SIZE_SECONDARY) - 1, 9)
	for side in 2:
		var is_input: bool = side == 0
		var ports: Array = descriptor.get("inputs" if is_input else "outputs", [])
		for index in ports.size():
			var port: Dictionary = ports[index]
			var at := Vector2(box.position.x if is_input else box.end.x,
				box.position.y + HEADER_HEIGHT + (index + 0.5) * PORT_PITCH)
			var colour: Color = type_colours.get(str(port.get("type", "control")),
				Design.INK_SECOND)
			# The dot: a ring in the signal's colour around a dark centre — the family's
			# socket, at schematic scale.
			draw_circle(at, PORT_RADIUS + 1.2, Design.SURFACES[Design.Surface.CANVAS])
			draw_circle(at, PORT_RADIUS, Color(colour, 0.9), false, 1.4, true)
			if small == null:
				continue
			var text := RackView.face_text(port)
			var measured := small.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT,
				-1.0, label_size)
			var text_at := Vector2(at.x + PORT_RADIUS + 6.0, at.y + measured.y * 0.32) \
				if is_input else \
				Vector2(at.x - PORT_RADIUS - 6.0 - measured.x, at.y + measured.y * 0.32)
			draw_string(small, text_at, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0,
				label_size, Design.INK_SECOND)


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
func card_of(node_id: String) -> Rect2:
	return _placed.get(node_id, Rect2())


func content_size() -> Vector2:
	return _content
