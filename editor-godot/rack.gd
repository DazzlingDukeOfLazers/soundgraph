class_name Rack
extends Control
## Graphrack — the same patch, drawn as a Eurorack case.
##
## This is a *view*, not a second editor. It reads the same document, the same registry
## descriptors and the same layering as the graph view, and writes parameter changes back
## through the same path. Nothing here knows anything about audio that the core has not
## published, and there is no second copy of the node vocabulary: a module's knobs and
## jacks are whatever the descriptor says the node has.
##
## Why it exists: a signal-flow graph is the honest picture, but a rack is the picture
## musicians already know how to read, and it is the one that stops people walking past a
## stand. Both are true at once, so both are drawn, and which one leads at Knobcon is a
## question to answer by watching people rather than by arguing.
##
## Layout is deliberately not free-form. Modules are ordered by the layering the graph view
## already computed — signal flows left to right — and then flowed into rack rows. A real
## case has no coordinates either; you slide modules along a rail.

const Layout := preload("res://layout.gd")

signal parameter_changed(node_id: String, parameter: String, value: float)
signal edit_started()
signal edit_finished(label: String)
signal node_selected(node_id: String)

## Cable rendering. The A/B is the point: a hanging cable reads as a real instrument, an
## orthogonal one reads as a circuit, and it is not obvious which wins in front of people.
enum CableStyle { CATENARY, PCB }

# Eurorack geometry, in pixels rather than millimetres. HP is the real horizontal pitch
# unit; module widths are whole numbers of it, which is what makes a wall of modules line
# up the way a real case does.
const HP := 24.0
const MIN_HP := 6
const MODULE_HEIGHT := 404.0
const RAIL := 16.0
const ROW_GAP := 34.0
const CASE_MARGIN := 26.0

const TITLE_BAND := 40.0
const JACK_RADIUS := 11.0
const JACK_ROW_HEIGHT := 46.0
const KNOB_RADIUS := 21.0
const KNOB_CELL := Vector2(66.0, 74.0)

# Cable sag, as a fraction of the horizontal span, clamped so that a very short patch still
# droops and a very long one does not fall off the case.
const SAG_FRACTION := 0.30
const SAG_MIN := 46.0
const SAG_MAX := 260.0

const PANEL := Color(0.157, 0.169, 0.200)
const PANEL_LOW := Color(0.125, 0.137, 0.165)
const PANEL_EDGE := Color(1, 1, 1, 0.07)
const RAIL_COLOUR := Color(0.086, 0.094, 0.110)
const RAIL_EDGE := Color(1, 1, 1, 0.05)
const SCREW := Color(0.42, 0.45, 0.50)
const JACK_RING := Color(0.62, 0.65, 0.70)
const JACK_HOLE := Color(0.055, 0.06, 0.07)
const KNOB_BODY := Color(0.235, 0.251, 0.290)
const KNOB_TRACK := Color(1, 1, 1, 0.13)
const SELECTED := Color(0.43, 0.91, 0.72)

# Category tints. Colour is decoration here, never the only carrier of meaning: every
# module is also titled, and every jack is labelled.
const CATEGORY_TINT := {
	"Terminals": Color(0.55, 0.72, 1.00),
	"Sources": Color(0.43, 0.91, 0.72),
	"Filters": Color(1.00, 0.80, 0.45),
	"Time": Color(0.80, 0.66, 1.00),
	"Amplitude": Color(1.00, 0.62, 0.60),
	"Modulation": Color(0.55, 0.86, 0.95),
	"Maths": Color(0.72, 0.76, 0.84),
}

var registry: Dictionary = {}
var patch: Dictionary = {}
var type_colours: Dictionary = {}
var ink := Color(0.96, 0.96, 0.97)
var ink_dim := Color(0.72, 0.74, 0.78)

var cable_style: int = CableStyle.CATENARY:
	set(value):
		cable_style = value
		if _cables != null:
			_cables.queue_redraw()

## Case width in HP, or 0 to fill whatever space there is.
##
## Filling the window is the default because the window is the case: on a wide screen a
## fixed width leaves a stripe of empty rail doing nothing. But a real rack does have a
## width — 84 HP and 104 HP are the common ones — and building a patch that would actually
## fit a case you own is a reasonable thing to want, so it stays available.
var case_hp: int = 0:
	set(value):
		case_hp = value
		_relayout()

var selected_id := ""

## The document key a hand-set rack order is stored under.
##
## In metadata, which is already a free-form string map that the core round-trips and the
## schema already declares additionalProperties — so this needs no schema change, no C++
## change, and nothing in any other target has to know it exists.
##
## A separate .rack file beside the patch was the other candidate and is worse: the browser
## has no filesystem, so Open is a file picker and Save is a download, and a sidecar would
## mean two of each and a patch that arrives without its layout whenever somebody forgets
## the second file. One file that carries its own presentation travels properly.
##
## Comma-separated because node ids cannot contain a comma — schema/patch.schema.json
## constrains them to ^[A-Za-z0-9_.:-]+$ — so the separator can never collide with a name.
const ORDER_KEY := "rack_order"

## Explicit rack order, set by dragging. Empty means "use the layering", which is the
## default and what a freshly loaded patch gets.
var _order_override: Array = []

var _modules: Dictionary = {}          # node id -> RackModule
var _knobs: Dictionary = {}            # node id -> {parameter name -> Knob}
var _cables: CableLayer
var _content_size := Vector2.ZERO


func _ready() -> void:
	_cables = CableLayer.new()
	_cables.rack = self
	_cables.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# The cable layer is decoration over the top of the modules; it must never take a click
	# that was meant for a knob underneath it.
	_cables.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_cables)
	resized.connect(_relayout)


# ---------------------------------------------------------------------------------
# Building
# ---------------------------------------------------------------------------------

func rebuild() -> void:
	for child in get_children():
		if child is RackModule:
			remove_child(child)
			child.queue_free()
	_modules.clear()
	_knobs.clear()
	# A different document is a different rack. Order set by hand does not carry over.
	if _order_override.size() > 0:
		var still_here: Array = []
		for id in _order_override:
			for node in patch.get("nodes", []):
				if str(node["id"]) == id:
					still_here.append(id)
					break
		_order_override = still_here

	# A document arriving with a remembered order takes it, so loading a patch puts the
	# modules back where they were left.
	if _order_override.is_empty():
		var stored := str(patch.get("metadata", {}).get(ORDER_KEY, ""))
		if not stored.is_empty():
			var present := {}
			for node in patch.get("nodes", []):
				present[str(node["id"])] = true
			for id in stored.split(",", false):
				if present.has(id):
					_order_override.append(id)

	for node in patch.get("nodes", []):
		var module := RackModule.new()
		module.rack = self
		module.node_id = str(node["id"])
		module.type_name = str(node["type"])
		module.descriptor = registry.get(module.type_name, {})
		var given_name: String = str(node.get("name", ""))
		module.title = given_name if given_name != "" else \
			str(module.descriptor.get("display_name", module.type_name))
		module.tooltip_text = str(module.descriptor.get("summary", ""))
		add_child(module)
		_modules[module.node_id] = module
		_knobs[module.node_id] = module.build(node)

	# The cable layer is added first but must draw last, over every module.
	move_child(_cables, get_child_count() - 1)
	_relayout()


## Module order comes from the graph view's own layering rather than a second algorithm.
## A rack has no coordinates — you slide modules along a rail — so all that is wanted from
## the layout is the reading order, which is exactly what the layering gives: signal left
## to right, and within a column the ordering that minimises crossings.
func _module_order() -> Array:
	var ids: Array = []
	var sizes: Dictionary = {}
	for node in patch.get("nodes", []):
		var id := str(node["id"])
		ids.append(id)
		var module: RackModule = _modules.get(id)
		sizes[id] = module.size if module != null else Vector2(144, MODULE_HEIGHT)
	if ids.is_empty():
		return []

	var edges: Array = []
	for connection in patch.get("connections", []):
		var from_id := str(connection["from"]["node"])
		var to_id := str(connection["to"]["node"])
		# Same weighting the graph view uses: the audio path is the spine, modulation hangs
		# off it. Without this an LFO can push the signal chain out of line.
		var weight := 1.0
		var descriptor: Dictionary = registry.get(_type_of(from_id), {})
		for port in descriptor.get("outputs", []):
			if str(port.get("name", "")) == str(connection["from"]["port"]):
				weight = 8.0 if str(port.get("type", "")) == "audio" else 1.0
		edges.append([from_id, to_id, weight])

	# A hand-set order wins. Anything added since is appended, so a new node appears at the
	# end rather than silently reshuffling everything that was placed deliberately.
	if _order_override.size() > 0:
		var ordered: Array = []
		for id in _order_override:
			if ids.has(id):
				ordered.append(id)
		for id in ids:
			if not ordered.has(id):
				ordered.append(id)
		return ordered

	var placed: Dictionary = Layout.arrange({
		"nodes": ids, "edges": edges, "sizes": sizes,
		"grid": 40.0, "column_pitch": 400.0, "column_gutter": 80.0, "row_step": 200.0,
	})

	# Sort by the laid-out position, then by id so the result is stable when two modules
	# land in the same place.
	ids.sort_custom(func(a: String, b: String) -> bool:
		var pa: Vector2 = placed.get(a, Vector2.ZERO)
		var pb: Vector2 = placed.get(b, Vector2.ZERO)
		if not is_equal_approx(pa.x, pb.x):
			return pa.x < pb.x
		if not is_equal_approx(pa.y, pb.y):
			return pa.y < pb.y
		return a < b)
	return ids


func _type_of(node_id: String) -> String:
	for node in patch.get("nodes", []):
		if str(node["id"]) == node_id:
			return str(node["type"])
	return ""


## Flow the modules into rack rows, wrapping at the case width. A module is never split
## across rows and never resized to fit — a rack that reflows by stretching its modules
## would not look like a rack.
func _relayout() -> void:
	var available := maxf(size.x - CASE_MARGIN * 2.0, 200.0)
	if case_hp > 0:
		available = minf(available, case_hp * HP)
	var x := CASE_MARGIN
	var y := CASE_MARGIN + RAIL
	var row_widest := 0.0

	for id in _module_order():
		var module: RackModule = _modules.get(id)
		if module == null:
			continue
		if x > CASE_MARGIN and x + module.size.x > CASE_MARGIN + available:
			x = CASE_MARGIN
			y += MODULE_HEIGHT + RAIL * 2.0 + ROW_GAP
		module.position = Vector2(x, y)
		x += module.size.x
		row_widest = maxf(row_widest, x)

	# Room below the last row for cables to hang into. Without it a catenary between two
	# modules on the bottom row is clipped off by the scroll extent.
	_content_size = Vector2(row_widest + CASE_MARGIN,
		y + MODULE_HEIGHT + RAIL + CASE_MARGIN + SAG_MAX * 0.5)
	custom_minimum_size = Vector2(0.0, _content_size.y)
	queue_redraw()
	if _cables != null:
		_cables.queue_redraw()


## Moves a module to the slot nearest a point, in rack coordinates.
func move_module_to(node_id: String, at: Vector2) -> void:
	var order: Array = _module_order()
	var from := order.find(node_id)
	if from < 0:
		return

	# The target slot is whichever module currently covers that point, by centre distance.
	# Comparing centres rather than edges is what makes a drag land where it looks like it
	# should when modules are different widths.
	# Taken out of the running first. Comparing the drop point against every module
	# *including the one being dropped* only ever finds that module — it is sitting under
	# the cursor at distance zero — so the answer was always "where it already was" and
	# every drag snapped back.
	order.remove_at(from)

	# Where it lands is the first slot that reads as *after* the drop point: a row below,
	# or further right on the same row. Reading order rather than nearest centre, because
	# a rack is a sequence and dropping between two modules should mean between them.
	var insert_at := order.size()
	for index in order.size():
		var module: RackModule = _modules.get(order[index])
		if module == null:
			continue
		var centre := module.position + module.size * 0.5
		var a_row_below := centre.y > at.y + MODULE_HEIGHT * 0.5
		var further_right := absf(centre.y - at.y) <= MODULE_HEIGHT * 0.5 and centre.x > at.x
		if a_row_below or further_right:
			insert_at = index
			break

	order.insert(insert_at, node_id)
	_order_override = order
	_store_order()
	_relayout()


## Back to the order the layering gives, which is what a freshly loaded patch shows.
func clear_order_override() -> void:
	_order_override.clear()
	if patch.has("metadata"):
		patch["metadata"].erase(ORDER_KEY)
	_relayout()


## Writes the order into the document so that saving keeps it.
func _store_order() -> void:
	if not patch.has("metadata"):
		patch["metadata"] = {}
	patch["metadata"][ORDER_KEY] = ",".join(_order_override)


func select(node_id: String) -> void:
	selected_id = node_id
	for id in _modules:
		_modules[id].queue_redraw()


## Called when a value changed somewhere else — the graph view's slider, an undo, a reload —
## so the two views cannot drift apart. Deliberately does not emit: this is a display
## update, not an edit.
func show_parameter(node_id: String, parameter: String, value: float) -> void:
	var knobs: Dictionary = _knobs.get(node_id, {})
	var knob: Knob = knobs.get(parameter)
	if knob != null:
		knob.set_value_silently(value)


# ---------------------------------------------------------------------------------
# The case itself
# ---------------------------------------------------------------------------------

func _draw() -> void:
	# Rails behind every row, drawn the full width so the case reads as continuous even
	# where a row is not full.
	var row_pitch := MODULE_HEIGHT + RAIL * 2.0 + ROW_GAP
	var rows := int(ceil(maxf(_content_size.y - CASE_MARGIN, 1.0) / row_pitch))
	for row in maxi(rows, 1):
		var top := CASE_MARGIN + row * row_pitch
		_draw_rail(Rect2(CASE_MARGIN * 0.5, top, size.x - CASE_MARGIN, RAIL))
		_draw_rail(Rect2(CASE_MARGIN * 0.5, top + RAIL + MODULE_HEIGHT,
			size.x - CASE_MARGIN, RAIL))


func _draw_rail(rect: Rect2) -> void:
	draw_rect(rect, RAIL_COLOUR)
	draw_line(rect.position, rect.position + Vector2(rect.size.x, 0.0), RAIL_EDGE, 1.0)
	# The threaded strip along a rail, suggested rather than drawn to scale.
	var slot := rect.position + Vector2(14.0, rect.size.y * 0.5)
	while slot.x < rect.end.x - 8.0:
		draw_circle(slot, 1.6, Color(1, 1, 1, 0.06))
		slot.x += 24.0


# ---------------------------------------------------------------------------------
# Cables
# ---------------------------------------------------------------------------------

## Every cable, as [from_position, to_position, colour]. Positions are in rack space.
func cable_endpoints() -> Array:
	var cables: Array = []
	for connection in patch.get("connections", []):
		var from_module: RackModule = _modules.get(str(connection["from"]["node"]))
		var to_module: RackModule = _modules.get(str(connection["to"]["node"]))
		if from_module == null or to_module == null:
			continue
		var a: Variant = from_module.jack_position(str(connection["from"]["port"]), false)
		var b: Variant = to_module.jack_position(str(connection["to"]["port"]), true)
		if a == null or b == null:
			continue
		var signal_type := from_module.port_type(str(connection["from"]["port"]), false)
		cables.append([a, b, type_colours.get(signal_type, Color.WHITE)])
	return cables


## A real catenary: the curve a cable takes under its own weight, y = a·cosh(x/a).
##
## The parabola everyone reaches for is close enough to fool the eye, but the shape is the
## whole reason this view exists — a patch cable that hangs correctly is what makes a rack
## read as an instrument rather than a diagram — so it is worth solving properly. `a` is
## found by bisection from the sag we want at the midpoint; there is no closed form.
static func catenary(a_point: Vector2, b_point: Vector2, sag: float,
		segments: int = 28) -> PackedVector2Array:
	var points := PackedVector2Array()
	var span := absf(b_point.x - a_point.x)
	if span < 1.0 or sag <= 0.0:
		# Vertical or near-vertical: hang straight down and back up.
		points.append(a_point)
		points.append(Vector2((a_point.x + b_point.x) * 0.5,
			maxf(a_point.y, b_point.y) + sag))
		points.append(b_point)
		return points

	# sag = a·(cosh(span / 2a) − 1). Monotonically decreasing in a, so bisect.
	var low := 0.01
	var high := maxf(span, sag) * 40.0
	for _i in 60:
		var mid := (low + high) * 0.5
		var s: float = mid * (cosh(span / (2.0 * mid)) - 1.0)
		if s > sag:
			low = mid
		else:
			high = mid
	var a := (low + high) * 0.5

	# The curve is computed about its own low point, then sheared so the ends meet the two
	# jacks even when they sit at different heights.
	#
	# Strictly, a cable between two unequal points is still a plain catenary with its low
	# point off-centre, not a sheared symmetric one — solving that properly means finding
	# the curve of a given arc length through both points, which is a second numerical
	# solve for a difference no one can see at these spans. The shear keeps the ends exact
	# and the sag honest at the midpoint, which is what the eye is actually reading.
	var left := a_point if a_point.x <= b_point.x else b_point
	var right := b_point if a_point.x <= b_point.x else a_point
	for i in segments + 1:
		var t := float(i) / float(segments)
		var x := (t - 0.5) * span
		var drop: float = a * (cosh(x / a) - cosh(span / (2.0 * a)))
		var point := Vector2(left.x + t * span, lerpf(left.y, right.y, t) - drop)
		points.append(point)
	if a_point.x > b_point.x:
		points.reverse()
	return points


## The other half of the A/B: an orthogonal run, the way a patchbay or a board is wired.
## Each cable gets its own horizontal lane below the row so parallel runs do not overlap.
static func pcb_route(a_point: Vector2, b_point: Vector2, lane: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	points.append(a_point)
	points.append(Vector2(a_point.x, lane))
	points.append(Vector2(b_point.x, lane))
	points.append(b_point)
	return _chamfer(points, 10.0)


static func _chamfer(points: PackedVector2Array, radius: float) -> PackedVector2Array:
	if points.size() < 3:
		return points
	var out := PackedVector2Array()
	out.append(points[0])
	for i in range(1, points.size() - 1):
		var previous := points[i - 1]
		var corner := points[i]
		var next := points[i + 1]
		var into := (corner - previous)
		var away := (next - corner)
		var r := minf(radius, minf(into.length(), away.length()) * 0.5)
		if r <= 0.5:
			out.append(corner)
			continue
		out.append(corner - into.normalized() * r)
		out.append(corner + away.normalized() * r)
	out.append(points[points.size() - 1])
	return out


class CableLayer extends Control:
	var rack: Control

	func _draw() -> void:
		if rack == null:
			return
		var cables: Array = rack.cable_endpoints()
		var lane_step := 13.0
		for index in cables.size():
			var entry: Array = cables[index]
			var a: Vector2 = entry[0]
			var b: Vector2 = entry[1]
			var colour: Color = entry[2]
			var points: PackedVector2Array
			if rack.cable_style == Rack.CableStyle.CATENARY:
				var span := absf(b.x - a.x)
				var sag := clampf(span * Rack.SAG_FRACTION, Rack.SAG_MIN, Rack.SAG_MAX)
				points = Rack.catenary(a, b, sag)
			else:
				var lane := maxf(a.y, b.y) + 34.0 + index * lane_step
				points = Rack.pcb_route(a, b, lane)

			# Drawn twice: a dark, slightly wider pass underneath reads as the shadow side
			# of a round cable and keeps overlapping cables legible against each other.
			draw_polyline(points, Color(0, 0, 0, 0.45), 7.0, true)
			draw_polyline(points, colour, 4.0, true)
			draw_circle(a, 5.0, colour)
			draw_circle(b, 5.0, colour)


# ---------------------------------------------------------------------------------
# A module
# ---------------------------------------------------------------------------------

class RackModule extends Control:
	var rack: Control
	var node_id := ""
	var type_name := ""
	var title := ""
	var descriptor: Dictionary = {}

	var _jacks: Array = []   # {"name", "input", "type", "centre"}
	var _dragging := false
	var _grab_offset := Vector2.ZERO

	func build(node: Dictionary) -> Dictionary:
		var inputs: Array = descriptor.get("inputs", [])
		var outputs: Array = descriptor.get("outputs", [])
		var parameters: Array = descriptor.get("parameters", [])

		# Width in whole HP, from whatever the node actually has. A module with more to say
		# is wider, which is also true of the real thing.
		var knob_columns := 2
		var jack_columns := maxi(inputs.size(), outputs.size())
		var needed := maxi(int(ceil(knob_columns * Rack.KNOB_CELL.x / Rack.HP)),
			int(ceil(jack_columns * 46.0 / Rack.HP)) + 1)
		var hp := maxi(Rack.MIN_HP, needed)
		size = Vector2(hp * Rack.HP, Rack.MODULE_HEIGHT)
		custom_minimum_size = size

		var knobs: Dictionary = {}
		var knob_area_top := Rack.TITLE_BAND + 16.0
		for index in parameters.size():
			var parameter: Dictionary = parameters[index]
			var column := index % knob_columns
			var row := index / knob_columns
			var cell_origin := Vector2(
				(size.x - knob_columns * Rack.KNOB_CELL.x) * 0.5 + column * Rack.KNOB_CELL.x,
				knob_area_top + row * Rack.KNOB_CELL.y)
			var knob := Knob.new()
			knob.rack = rack
			knob.node_id = node_id
			knob.descriptor = parameter
			knob.position = cell_origin
			knob.size = Rack.KNOB_CELL
			knob.set_value_silently(float(node.get("parameters", {})
				.get(str(parameter["name"]), parameter["default"])))
			add_child(knob)
			knobs[str(parameter["name"])] = knob

		# Jacks along the bottom: inputs on their own row, outputs beneath, which is the
		# convention the eye already has from the hardware.
		_jacks.clear()
		var jack_top := size.y - Rack.JACK_ROW_HEIGHT * 2.0 - 10.0
		_place_jack_row(inputs, true, jack_top)
		_place_jack_row(outputs, false, jack_top + Rack.JACK_ROW_HEIGHT)
		return knobs

	func _place_jack_row(ports: Array, is_input: bool, row_y: float) -> void:
		if ports.is_empty():
			return
		var step := size.x / float(ports.size())
		for index in ports.size():
			var port: Dictionary = ports[index]
			_jacks.append({
				"name": str(port["name"]),
				"input": is_input,
				"type": str(port.get("type", "")),
				"centre": Vector2(step * (index + 0.5), row_y + Rack.JACK_RADIUS + 4.0),
			})

	func port_type(port_name: String, is_input: bool) -> String:
		for jack in _jacks:
			if jack["name"] == port_name and jack["input"] == is_input:
				return str(jack["type"])
		return ""

	## Centre of a jack, in rack space, or null when this module has no such port.
	func jack_position(port_name: String, is_input: bool):
		for jack in _jacks:
			if jack["name"] == port_name and jack["input"] == is_input:
				return position + (jack["centre"] as Vector2)
		return null

	# Dragging slides a module along the rail — the one thing you can do to a real rack
	# that the graph view has no equivalent for. Knobs sit on top and take their own input
	# first, so a drag can only begin on bare panel, which is also true of the hardware.
	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				rack.select(node_id)
				rack.node_selected.emit(node_id)
				_dragging = true
				_grab_offset = event.position
				z_index = 1              # above its neighbours while it moves
			elif _dragging:
				_dragging = false
				z_index = 0
				rack.move_module_to(node_id, position + size * 0.5)
			accept_event()
		elif event is InputEventMouseMotion and _dragging:
			position += event.position - _grab_offset
			rack.queue_redraw()
			accept_event()

	func _draw() -> void:
		var font: Font = get_theme_default_font()
		var tint: Color = Rack.CATEGORY_TINT.get(
			str(descriptor.get("category", "")), Color(0.7, 0.7, 0.75))

		# Panel, with a faint vertical gradient. Aluminium is not flat.
		draw_rect(Rect2(Vector2.ZERO, size), Rack.PANEL)
		var band := size.y / 8.0
		for i in 8:
			var shade: Color = Rack.PANEL.lerp(Rack.PANEL_LOW, i / 7.0)
			draw_rect(Rect2(0.0, i * band, size.x, band + 1.0), shade)

		draw_line(Vector2(0.5, 0.0), Vector2(0.5, size.y), Rack.PANEL_EDGE, 1.0)
		draw_line(Vector2(size.x - 0.5, 0.0), Vector2(size.x - 0.5, size.y),
			Color(0, 0, 0, 0.35), 1.0)

		# Category stripe under the title, the module's only use of colour for identity —
		# the title says the same thing in words.
		draw_rect(Rect2(10.0, Rack.TITLE_BAND - 7.0, size.x - 20.0, 2.0),
			Color(tint.r, tint.g, tint.b, 0.85))

		if font != null:
			var label := title.to_upper()
			var width := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
			# A long user-given name is clipped rather than shrunk, so every module's title
			# sits on the same baseline at the same size, as a row of panels does.
			draw_string(font, Vector2((size.x - width) * 0.5, 26.0), label,
				HORIZONTAL_ALIGNMENT_LEFT, size.x - 12.0, 14, rack.ink)

		for jack in _jacks:
			_draw_jack(font, jack)

		# Mounting screws, in the rail above and below.
		for point in [Vector2(11.0, 9.0), Vector2(size.x - 11.0, 9.0),
				Vector2(11.0, size.y - 9.0), Vector2(size.x - 11.0, size.y - 9.0)]:
			draw_circle(point, 3.4, Rack.SCREW)
			draw_circle(point, 3.4, Color(0, 0, 0, 0.5), false, 1.0)

		if rack != null and rack.selected_id == node_id:
			draw_rect(Rect2(Vector2.ZERO, size), Rack.SELECTED, false, 2.0)

	func _draw_jack(font: Font, jack: Dictionary) -> void:
		var centre: Vector2 = jack["centre"]
		var colour: Color = rack.type_colours.get(str(jack["type"]), Color.WHITE)
		# The nut, then the hole. An input and an output differ by the ring, not only by
		# where they sit.
		draw_circle(centre, Rack.JACK_RADIUS, Color(0.20, 0.21, 0.24))
		draw_circle(centre, Rack.JACK_RADIUS, Color(0, 0, 0, 0.55), false, 1.0)
		draw_circle(centre, Rack.JACK_RADIUS - 3.0, Rack.JACK_HOLE)
		if bool(jack["input"]):
			draw_circle(centre, Rack.JACK_RADIUS - 1.5, colour, false, 2.0)
		else:
			draw_circle(centre, Rack.JACK_RADIUS - 5.5, colour)

		if font != null:
			var text := str(jack["name"])
			var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
			draw_string(font, centre + Vector2(-width * 0.5, Rack.JACK_RADIUS + 13.0),
				text, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, rack.ink_dim)


# ---------------------------------------------------------------------------------
# A knob
# ---------------------------------------------------------------------------------

## Vertical drag, because that is what a knob does under a mouse — a rotary gesture is
## unpleasant to perform and worse to aim. Fine control on Shift. The whole drag is one
## undo step, matching the sliders in the graph view.
class Knob extends Control:
	const SWEEP := TAU * 0.75          # 270°, the usual pot travel
	const START := PI * 0.75           # pointing down-left at minimum

	var rack: Control
	var node_id := ""
	var descriptor: Dictionary = {}

	var _position := 0.0               # 0..1 along the parameter's own scaling
	var _dragging := false
	var _drag_origin := 0.0
	var _drag_from := 0.0

	func _ready() -> void:
		mouse_default_cursor_shape = Control.CURSOR_VSIZE
		tooltip_text = str(descriptor.get("doc", ""))

	func value() -> float:
		var raw := _to_value(_position)
		# A mode switch has positions, not a range. A filter set to 1.7 is not a thing, and
		# a knob that can produce one would be a quiet way to corrupt a patch.
		if descriptor.has("enum"):
			var options: Array = descriptor["enum"]
			return float(clampi(int(round(raw)), 0, options.size() - 1))
		return raw

	func set_value_silently(value: float) -> void:
		_position = _to_position(value)
		queue_redraw()

	# Scaling comes from the descriptor the core publishes, exactly as the graph view's
	# sliders do. Two views disagreeing about what the middle of a knob means would be a
	# bug nobody would find quickly.
	func _to_value(at: float) -> float:
		var low: float = descriptor["min"]
		var high: float = descriptor["max"]
		match str(descriptor.get("scaling", "linear")):
			"exponential":
				if low > 0.0 and high > 0.0:
					return low * pow(high / low, at)
			"logarithmic":
				return low + (high - low) * at * at
		return low + (high - low) * at

	func _to_position(value: float) -> float:
		var low: float = descriptor["min"]
		var high: float = descriptor["max"]
		if is_equal_approx(low, high):
			return 0.0
		match str(descriptor.get("scaling", "linear")):
			"exponential":
				if low > 0.0 and high > 0.0 and value > 0.0:
					return clampf(log(value / low) / log(high / low), 0.0, 1.0)
			"logarithmic":
				return clampf(sqrt(maxf(0.0, (value - low) / (high - low))), 0.0, 1.0)
		return clampf((value - low) / (high - low), 0.0, 1.0)

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_dragging = true
				_drag_origin = event.position.y
				_drag_from = _position
				rack.edit_started.emit()
			elif _dragging:
				_dragging = false
				rack.edit_finished.emit("set %s" % str(descriptor["name"]))
			accept_event()
		elif event is InputEventMouseMotion and _dragging:
			var travel: float = _drag_origin - event.position.y
			var span := 160.0 if not event.shift_pressed else 640.0
			_position = clampf(_drag_from + travel / span, 0.0, 1.0)
			rack.parameter_changed.emit(node_id, str(descriptor["name"]), value())
			queue_redraw()
			accept_event()

	func _draw() -> void:
		var font: Font = get_theme_default_font()
		var centre := Vector2(size.x * 0.5, Rack.KNOB_RADIUS + 6.0)
		var angle := START + SWEEP * _position

		draw_arc(centre, Rack.KNOB_RADIUS + 5.0, START, START + SWEEP, 40,
			Rack.KNOB_TRACK, 3.0, true)
		draw_arc(centre, Rack.KNOB_RADIUS + 5.0, START, angle, 40,
			Rack.SELECTED, 3.0, true)

		draw_circle(centre, Rack.KNOB_RADIUS, Rack.KNOB_BODY)
		draw_circle(centre, Rack.KNOB_RADIUS, Color(0, 0, 0, 0.5), false, 1.0)
		draw_circle(centre - Vector2(0, 1), Rack.KNOB_RADIUS - 5.0,
			Rack.KNOB_BODY.lightened(0.10))
		# The pointer, which is what actually tells you where the knob is set.
		draw_line(centre + Vector2(cos(angle), sin(angle)) * 6.0,
			centre + Vector2(cos(angle), sin(angle)) * (Rack.KNOB_RADIUS - 3.0),
			rack.ink, 2.5, true)

		if font == null:
			return
		var name_text := str(descriptor["name"])
		var name_width := font.get_string_size(name_text, HORIZONTAL_ALIGNMENT_LEFT,
			-1, 11).x
		draw_string(font, Vector2((size.x - name_width) * 0.5, size.y - 15.0), name_text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, rack.ink_dim)
		var value_text := Rack.format_value(value())
		if descriptor.has("enum"):
			var options: Array = descriptor["enum"]
			value_text = str(options[clampi(int(value()), 0, options.size() - 1)])
		var value_width := font.get_string_size(value_text, HORIZONTAL_ALIGNMENT_LEFT,
			-1, 11).x
		draw_string(font, Vector2((size.x - value_width) * 0.5, size.y - 3.0), value_text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, rack.ink)


static func format_value(value: float) -> String:
	var magnitude := absf(value)
	if magnitude >= 1000.0:
		return "%.0f" % value
	if magnitude >= 10.0:
		return "%.1f" % value
	if magnitude >= 1.0:
		return "%.2f" % value
	return "%.3f" % value
