class_name Rack
extends Control
const Seams := preload("res://seams.gd")
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
## How tall a module is, in three settings.
##
## It was a flat 404 for everything, so a Gain with one knob got the same panel as a
## filter with six and spent most of it empty — half a screen of blank aluminium per
## module. Height comes from content now: title, however many knob rows there are,
## two rows of jacks, and a per-density allowance for the space between them.
##
## Compact spends nothing on that space. Instrument leaves a modest band, which is
## what makes a rack read as hardware rather than as a list. Analysis leaves room for
## a module to show what it is doing — and a simple oscillator stays short in all
## three, because the point is not to fill the space but to stop reserving it.
enum Density { COMPACT, INSTRUMENT, ANALYSIS }

const DENSITY_NAMES := ["Compact", "Instrument", "Analysis"]
const DENSITY_BAND := [0.0, 54.0, 150.0]

static var density: int = Density.INSTRUMENT

## The floor, so a module with no knobs at all is still a module.
const MODULE_MIN_HEIGHT := 190.0

## The height every module in this rack shares, worked out from the busiest one.
##
## Uniform on purpose: modules in a real case share a rail, and a rack of ragged
## panels stops looking like hardware. What was wrong was not that they matched, it
## was that they matched a constant — so a patch of two-knob oscillators reserved the
## same 404px as a patch with a six-parameter filter in it, and spent the difference
## on nothing.
## The height a rack module has before any patch has been measured — and the height the
## file's panel holds its blocks to. The rack recomputes module_height from the busiest
## module because a rail must fit its tallest occupant; the panel keeps the default and
## spends *width* instead, spilling a busy node into another bank of knobs sideways.
const DEFAULT_HEIGHT := 404.0

static var module_height := DEFAULT_HEIGHT


## The height a module needs for its own content, before the density band.
##
## The jacks used to be stacked under the knobs and cost two rows of height on every
## module whether it had four ports or one. They are beside them now — inputs down the
## left edge, outputs down the right — so the height is whichever of the two columns is
## taller, and a two-knob oscillator is a short module again.
static func content_height(parameters: int, ports: int = 0) -> float:
	var knob_rows: int = int(ceil(parameters / 2.0))
	return TITLE_BAND + KNOB_PAD * 2.0 + maxf(knob_rows * KNOB_CELL.y,
		ports * JACK_ROW_HEIGHT)


## Recomputed whenever the rack is rebuilt or the density changes.
static func measure(patch_nodes: Array, registry: Dictionary) -> float:
	var tallest := MODULE_MIN_HEIGHT
	for node in patch_nodes:
		var type_key: String = Seams.registry_key(node)
		var descriptor: Dictionary = registry.get(type_key, {})
		tallest = maxf(tallest, content_height(
			int(descriptor.get("parameters", []).size()),
			maxi(int(descriptor.get("inputs", []).size()),
				int(descriptor.get("outputs", []).size()))))
	# Scaled once, here, rather than at each term. The shared height has to be at least
	# what the tallest module's own contents ask for, and those grow with the reader's
	# size preference; left unscaled, every module at XL outgrew the shared height
	# individually and the rack went ragged, which is the one thing a rack must not be.
	return Design.scale(tallest + DENSITY_BAND[density])


const RAIL := 16.0
const ROW_GAP := 34.0
const CASE_MARGIN := 26.0

const TITLE_BAND := 40.0
const JACK_RADIUS := 11.0
const JACK_ROW_HEIGHT := 46.0
const KNOB_RADIUS := 21.0
const KNOB_CELL := Vector2(66.0, 78.0)

## Breathing room inside a knob cell, and between the knob grid and the panel edges.
##
## The cell used to be a constant 66px and the name and the value were drawn centred at
## whatever width they happened to measure, with no bound at all — so "cutoff_sweep" ran
## straight over "mode" on the next knob and "safety_limit" left the panel entirely. A
## cell is now as wide as the widest thing in it, which is what the padding is measured
## from rather than added to.
const KNOB_PAD := 10.0

## How much of a port name a panel shows before eliding it. The full name is on the
## tooltip; what the panel owes the reader is enough to tell one jack from the next.
const JACK_LABEL_MAX := 92.0


## The knob and the socket, after the reader's size preference.
##
## Geometry was the one part of this panel that ignored the setting: at XL the labels
## grew 35% and the thing they label stayed 21px, so the knobs read as undersized
## controls on an oversized panel — and at Compact the socket was a smaller target than
## the hit-size rule allows anywhere else in the application.
static func knob_radius() -> float:
	return Design.scale(KNOB_RADIUS)


static func jack_radius() -> float:
	return Design.scale(JACK_RADIUS)

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

# Category tints, deliberately muted.
#
# These were at full saturation, which put a red AMPLIFIER stripe and an orange
# FILTERS stripe in direct competition with the mint audio cable and the blue
# modulation cable — two colour languages at the same volume, and the reader has to
# keep them apart. The highest saturation in this application belongs to signal
# semantics; a category is a hint about what a module is for, and a hint should look
# like one. Colour was never the only carrier here anyway: every module is titled and
# every jack is labelled.
const CATEGORY_SATURATION := 0.42

const CATEGORY_TINT := {
	"Terminals": Color(0.55, 0.72, 1.00),
	"Sources": Color(0.43, 0.91, 0.72),
	"Filters": Color(1.00, 0.80, 0.45),
	"Time": Color(0.80, 0.66, 1.00),
	"Amplitude": Color(1.00, 0.62, 0.60),
	"Modulation": Color(0.55, 0.86, 0.95),
	"Maths": Color(0.72, 0.76, 0.84),
}


## A category colour, quietened so the signal colours keep the loudest voice.
static func category_tint(category: String) -> Color:
	var base: Color = CATEGORY_TINT.get(category, Color(0.72, 0.76, 0.84))
	var muted := Color.from_hsv(base.h, base.s * CATEGORY_SATURATION, base.v)
	return muted

var registry: Dictionary = {}
var patch: Dictionary = {}
var type_colours: Dictionary = {}

## Returns the samples on a node's output, or an empty array. Set by the editor.
##
## A callable rather than a reference to the engine, so the rack goes on knowing
## nothing about the extension — it asks a question and gets numbers back, which is
## also what makes it testable without an audio device.
var read_port: Callable = Callable()
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

## Which cable the pointer is over, as an index into cable_endpoints(), or -1.
var hovered_cable := -1

## Where a hand-set rack order lives in the document.
##
## Under "arrangement" rather than "metadata". Metadata is what a person wrote about the
## patch — its name, who made it, what it is for — and a list of node ids is not that.
## Arrangement is declared in the schema as presentation-only, so anything that just wants
## to make sound can skip the whole object and lose nothing.
##
## A separate .rack file was the other candidate and is worse: the browser has no
## filesystem, so Open is a file picker and Save is a download, and a sidecar would mean
## two of each and a patch that arrives without its layout whenever somebody forgets the
## second file. One file that carries its own presentation travels properly.
const ARRANGEMENT_KEY := "arrangement"
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

## Redraws the analysis displays. Called by the editor while the rack is on screen.
##
## Every third frame rather than every one: this is a meter, and a meter that updates
## twenty times a second is already faster than anybody can read. Doing it per frame
## would mean a call across the extension boundary per module per frame for a picture
## nobody could tell apart from this one.
var _display_tick := 0

## The module showing a given patch node, or null.
func module_for(node_id: String):
	for child in get_children():
		if child is RackModule and (child as RackModule).node_id == node_id:
			return child
	return null


func refresh_displays() -> void:
	if density != Density.ANALYSIS:
		return
	_display_tick += 1
	if _display_tick % 3 != 0:
		return
	for child in get_children():
		if child is RackModule:
			(child as RackModule).accumulate()
			child.queue_redraw()


func rebuild() -> void:
	# Before anything is placed, because every module is built against it.
	module_height = measure(patch.get("nodes", []), registry)
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
		var stored: Array = patch.get(ARRANGEMENT_KEY, {}).get(ORDER_KEY, [])
		if not stored.is_empty():
			var present := {}
			for node in patch.get("nodes", []):
				present[str(node["id"])] = true
			# Ids that are no longer in the patch are skipped, and nodes missing from the
			# list are appended by _module_order. An out-of-date hint degrades rather than
			# breaks, which is the only sane behaviour for something optional.
			for id in stored:
				if present.has(str(id)):
					_order_override.append(str(id))

	for node in patch.get("nodes", []):
		var module := RackModule.new()
		module.rack = self
		module.node_id = str(node["id"])
		module.type_name = Seams.registry_key(node)
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
		sizes[id] = module.size if module != null else Vector2(144, module_height)
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
			# Instances resolve to their synthesized descriptor key and seams to the
			# terminal they are, so this view treats both like any node without ever
			# learning what either one is.
			return Seams.registry_key(node)
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
			y += module_height + RAIL * 2.0 + ROW_GAP
		module.position = Vector2(x, y)
		x += module.size.x
		row_widest = maxf(row_widest, x)

	# Room below the last row for cables to hang into. Without it a catenary between two
	# modules on the bottom row is clipped off by the scroll extent.
	_content_size = Vector2(row_widest + CASE_MARGIN,
		y + module_height + RAIL + CASE_MARGIN + SAG_MAX * 0.5)
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
		var a_row_below := centre.y > at.y + module_height * 0.5
		var further_right := absf(centre.y - at.y) <= module_height * 0.5 and centre.x > at.x
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
	if patch.has(ARRANGEMENT_KEY):
		patch[ARRANGEMENT_KEY].erase(ORDER_KEY)
		if patch[ARRANGEMENT_KEY].is_empty():
			patch.erase(ARRANGEMENT_KEY)
	_relayout()


## Writes the order into the document so that saving keeps it.
func _store_order() -> void:
	if not patch.has(ARRANGEMENT_KEY):
		patch[ARRANGEMENT_KEY] = {}
	patch[ARRANGEMENT_KEY][ORDER_KEY] = _order_override.duplicate()


func select(node_id: String) -> void:
	selected_id = node_id
	for id in _modules:
		_modules[id].queue_redraw()
	# The cables care too, now that selecting a module turns down everything it is not
	# connected to. They live in their own layer, so redrawing the modules misses them.
	if _cables != null:
		_cables.queue_redraw()


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
	var row_pitch := module_height + RAIL * 2.0 + ROW_GAP
	var rows := int(ceil(maxf(_content_size.y - CASE_MARGIN, 1.0) / row_pitch))
	for row in maxi(rows, 1):
		var top := CASE_MARGIN + row * row_pitch
		_draw_rail(Rect2(CASE_MARGIN * 0.5, top, size.x - CASE_MARGIN, RAIL))
		_draw_rail(Rect2(CASE_MARGIN * 0.5, top + RAIL + module_height,
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
## Mouse motion over the case itself — which is where the cables are.
##
## The modules take their own input, so this only sees the gaps between them, and the
## gaps are exactly where a hanging cable is. A cable that runs behind a module is
## unreachable, which is correct: you cannot touch it there either.
func _gui_input(event: InputEvent) -> void:
	var motion := event as InputEventMouseMotion
	if motion != null:
		_update_cable_hover(motion.position)


## Nothing under the pointer means nothing highlighted, and leaving the case entirely
## has to count — otherwise the last cable hovered stays lit for ever.
func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT and hovered_cable != -1:
		hovered_cable = -1
		if _cables != null:
			_cables.queue_redraw()


## The cable nearest a point, or -1 if none is close enough.
##
## Measured against the drawn curve rather than the straight line between the ends,
## because in this view they are nowhere near each other — a catenary sags a couple
## of hundred pixels below its own chord, so hit-testing the chord would highlight
## whichever cable happened to pass overhead rather than the one under the pointer.
func cable_at(point: Vector2) -> int:
	var cables := cable_endpoints()
	var lane_step := 13.0
	var best := -1
	# A little wider than the cable is drawn, so it can be caught without precision.
	var best_distance := 12.0
	for index in cables.size():
		var entry: Array = cables[index]
		var a: Vector2 = entry[0]
		var b: Vector2 = entry[1]
		var points: PackedVector2Array
		if cable_style == CableStyle.CATENARY:
			var span := absf(b.x - a.x)
			var sag := clampf(span * SAG_FRACTION, SAG_MIN, SAG_MAX)
			points = catenary(a, b, sag)
		else:
			points = pcb_route(a, b, maxf(a.y, b.y) + 34.0 + index * lane_step)
		for i in points.size() - 1:
			var segment := points[i + 1] - points[i]
			var length_squared := segment.length_squared()
			var along: float = 0.0 if length_squared <= 0.0 else clampf(
				(point - points[i]).dot(segment) / length_squared, 0.0, 1.0)
			var distance := point.distance_to(points[i] + segment * along)
			if distance < best_distance:
				best_distance = distance
				best = index
	return best


## Whether a cable should be drawn at full strength rather than turned down.
##
## Hovering beats selection. A pointer resting on a cable is a direct question about that
## one cable, and answering it with "and also everything else touching the selected module"
## answers a question nobody asked.
##
## With nothing hovered and nothing selected everything stays bright: dimming only means
## something when there is something to pick out, and a rack that is permanently three
## quarters faded has just been drawn badly.
##
## Pass the endpoints in if you already have them — the drawing does, and re-reading the
## patch once per cable would make painting the case quadratic in the number of cables.
func cable_related(index: int, cables: Array = []) -> bool:
	if hovered_cable >= 0:
		return index == hovered_cable
	if selected_id == "":
		return true
	var entries: Array = cables if not cables.is_empty() else cable_endpoints()
	if index < 0 or index >= entries.size():
		return false
	var entry: Array = entries[index]
	return str(entry[3]) == selected_id or str(entry[4]) == selected_id


## Tracks the cable under the pointer.
func _update_cable_hover(point: Vector2) -> void:
	var found := cable_at(point)
	if found == hovered_cable:
		return
	hovered_cable = found
	if _cables != null:
		_cables.queue_redraw()


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
		# The node ids travel with the geometry, so the layer can tell which cables
		# belong to what without going back to the patch for every one of them.
		cables.append([a, b, type_colours.get(signal_type, Color.WHITE),
			str(connection["from"]["node"]), str(connection["to"]["node"])])
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

	## How far a cable is turned down when it has nothing to do with what is selected.
	##
	## Stated as the contrast a dimmed cable should still hold against the case, and handed
	## to Design.recede() to work out the mixing, which is not the same as fading out.
	##
	## At alpha 0.3 an unrelated cable fell to 1.86:1 — under even the 3.25:1 this project
	## holds a plain UI boundary to, so "still part of the patch" was not what was on
	## screen. Naming a floor rather than an amount is what makes it hold on all five
	## palettes: a fixed 45% mix landed at 4.2:1 on Lab and 2.5:1 on Paper Lab, the same
	## instruction giving one result inside the floor and one under it.
	const DIM_TARGET := 3.6

	## A dimmed cable is drawn thinner as well as quieter.
	##
	## Because contrast alone cannot carry this on every palette. Paper Lab's signal
	## colours start at about 6.5:1 against its case, so once a dimmed one is held at the
	## 3.6 floor there is only 1.8 times left between them — where Lab has 2.6. Rather
	## than let the effect be strong on the dark themes and weak on the light one, some of
	## the work goes to a cue that does not vary with the palette at all.
	##
	## It is also the cue that survives the reader: somebody who cannot separate mint from
	## blue can still see which cable is thinner.
	const DIM_WIDTH := 0.8

	## The shadow under a dimmed cable, as a fraction of the one under a lit cable.
	##
	## Not zero. The dark pass is what gives a cable its drawn width, so multiplying it by
	## the same amount as the colour cost dimmed cables ~40% of their thickness as well as
	## their contrast — two cues collapsing together, which is how a cable stopped reading
	## as a cable. Kept faint so the weight holds without the dim ones looking heavy.
	const DIM_SHADOW := 0.4

	func _draw() -> void:
		if rack == null:
			return
		var cables: Array = rack.cable_endpoints()
		var lane_step := 13.0

		# The rack draws its own cables, which is why the dimming half of this is here
		# and not in the graph view: GraphEdit paints connections itself and offers no
		# per-cable alpha, so there the best available answer was to brighten a path and
		# leave the rest alone. Here every cable is ours to turn down.
		for index in cables.size():
			var entry: Array = cables[index]
			var a: Vector2 = entry[0]
			var b: Vector2 = entry[1]
			var colour: Color = entry[2]

			var hovered: bool = index == rack.hovered_cable
			var related: bool = rack.cable_related(index, cables)

			var points: PackedVector2Array
			if rack.cable_style == Rack.CableStyle.CATENARY:
				var span := absf(b.x - a.x)
				var sag := clampf(span * Rack.SAG_FRACTION, Rack.SAG_MIN, Rack.SAG_MAX)
				points = Rack.catenary(a, b, sag)
			else:
				var lane := maxf(a.y, b.y) + 34.0 + index * lane_step
				points = Rack.pcb_route(a, b, lane)

			var width: float = 5.0 if hovered else 4.0
			if not related:
				width *= DIM_WIDTH
			var ink: Color = colour if related \
				else Design.recede(colour, Design.SURFACES[Design.Surface.CANVAS], DIM_TARGET)
			var shadow: float = 0.45 if related else 0.45 * DIM_SHADOW

			# Drawn twice: a dark, slightly wider pass underneath reads as the shadow side
			# of a round cable and keeps overlapping cables legible against each other.
			draw_polyline(points, Color(0, 0, 0, shadow), width + 3.0, true)
			draw_polyline(points, ink, width, true)
			draw_circle(a, 5.0, ink)
			draw_circle(b, 5.0, ink)

			# Both ends of the hovered cable, because a brightened curve still has to be
			# followed by eye to find where it lands — which in a rack means across a
			# tangle of other cables doing the same thing.
			if hovered:
				for spot: Vector2 in [a, b]:
					draw_arc(spot, 12.0, 0.0, TAU, 28, colour, 2.0, true)


# ---------------------------------------------------------------------------------
# A module
# ---------------------------------------------------------------------------------

class RackModule extends Control:
	var rack: Control
	var node_id := ""
	var type_name := ""
	var title := ""
	var descriptor: Dictionary = {}

	var _jacks: Array = []   # Jack controls, both columns
	var _grid: GridContainer = null
	var _dragging := false
	var _grab_offset := Vector2.ZERO

	## Signal in on the left, controls in the middle, signal out on the right.
	##
	## The jacks were in two rows across the bottom, which is where a Eurorack module puts
	## them and which costs this one the two things the arrangement is supposed to buy. On
	## real hardware the patch cables are in front of the panel and you read the labels
	## around them; here the cables are drawn *over* the module, so a bottom row put every
	## cable across the face of the thing it belongs to. And a rack module whose signal
	## runs left to right is the same object as a graph node, which is what lets the two
	## views share a layout instead of arguing about one.
	##
	## Built out of containers rather than arithmetic. Every overlap on this panel came
	## from a hand-computed offset that did not know how wide the text next to it was.
	func build(node: Dictionary) -> Dictionary:
		var inputs: Array = descriptor.get("inputs", [])
		var outputs: Array = descriptor.get("outputs", [])
		var parameters: Array = descriptor.get("parameters", [])

		var frame := MarginContainer.new()
		frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		frame.add_theme_constant_override("margin_left", int(Rack.KNOB_PAD))
		frame.add_theme_constant_override("margin_right", int(Rack.KNOB_PAD))
		frame.add_theme_constant_override("margin_top", int(Rack.TITLE_BAND))
		frame.add_theme_constant_override("margin_bottom", int(Rack.KNOB_PAD) + 8)
		# So a drag still begins anywhere on bare panel: the layout is scaffolding, and
		# scaffolding that swallowed the mouse would take the one gesture the rack has.
		frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(frame)

		var body := HBoxContainer.new()
		body.add_theme_constant_override("separation", Design.SPACE_M)
		body.mouse_filter = Control.MOUSE_FILTER_IGNORE
		frame.add_child(body)

		_jacks.clear()
		body.add_child(_jack_column(inputs, true))

		# The knobs take the middle and sit in the middle of it. A GridContainer has no
		# alignment of its own, so left to itself it packs against the input jacks and
		# leaves the gap on the outside — which reads as a module that has been assembled
		# wrong rather than one with room to spare.
		var centre := CenterContainer.new()
		centre.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
		body.add_child(centre)

		var grid := GridContainer.new()
		grid.columns = 1 if parameters.size() <= 2 else 2
		grid.add_theme_constant_override("h_separation", 0)
		grid.add_theme_constant_override("v_separation", 0)
		grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
		centre.add_child(grid)
		_grid = grid

		var knobs: Dictionary = {}
		for parameter: Dictionary in parameters:
			var knob := Knob.new()
			knob.rack = rack
			knob.node_id = node_id
			knob.descriptor = parameter
			knob.set_value_silently(float(node.get("parameters", {})
				.get(str(parameter["name"]), parameter["default"])))
			grid.add_child(knob)
			knobs[str(parameter["name"])] = knob

		body.add_child(_jack_column(outputs, false))

		# Whole HP, from what the contents actually measure. A module with more to say is
		# wider, which is also true of the real thing — but "more to say" now includes a
		# long parameter name, which is what used to overflow instead of widening.
		var wanted: float = frame.get_combined_minimum_size().x + Rack.KNOB_PAD * 2.0
		var hp := maxi(Rack.MIN_HP, int(ceil(wanted / Rack.HP)))
		custom_minimum_size = Vector2(hp * Rack.HP,
			maxf(Rack.module_height, frame.get_combined_minimum_size().y))
		size = custom_minimum_size
		return knobs

	## One edge of the panel: its jacks, stacked, centred against the knobs.
	func _jack_column(ports: Array, is_input: bool) -> Control:
		var column := VBoxContainer.new()
		column.alignment = BoxContainer.ALIGNMENT_CENTER
		column.add_theme_constant_override("separation", 0)
		column.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		column.mouse_filter = Control.MOUSE_FILTER_IGNORE
		for port: Dictionary in ports:
			var jack := Jack.new()
			jack.rack = rack
			jack.port_name = str(port["name"])
			jack.type_name = str(port.get("type", ""))
			jack.is_input = is_input
			column.add_child(jack)
			_jacks.append(jack)
		return column

	func port_type(port_name: String, is_input: bool) -> String:
		for jack: Jack in _jacks:
			if jack.port_name == port_name and jack.is_input == is_input:
				return jack.type_name
		return ""

	## Centre of a jack, in rack space, or null when this module has no such port.
	func jack_position(port_name: String, is_input: bool):
		for jack: Jack in _jacks:
			if jack.port_name == port_name and jack.is_input == is_input:
				return position + jack.global_position - global_position \
					+ jack.socket_centre()
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

	## What this module is doing, in the band Analysis density reserves.
	##
	## The whole argument for a hardware metaphor is that hardware tells you something
	## by being looked at — a meter moves, a scope draws, an envelope lamp dims. A
	## panel that only holds knobs is a picture of hardware rather than an instrument,
	## and the blank middle of these modules was the clearest evidence of it.
	##
	## Read from the running graph's own buffers, like the scope in the inspector: this
	## draws what is on the wire rather than a guess at what ought to be.
	## How much history each display keeps.
	##
	## A single read returns one processing block — 64 samples. At 110 Hz that is a
	## seventh of a cycle, so a sawtooth drew as a straight diagonal and every display
	## looked like a ramp regardless of what was actually on the wire. Six blocks is
	## about a cycle at the low end and several at the top, which is enough to see the
	## shape of the thing.
	const HISTORY := 384

	var _history := PackedFloat32Array()

	## Pulls the latest block onto the end of the history and drops the oldest.
	func accumulate() -> void:
		if rack == null or not rack.read_port.is_valid():
			return
		var outputs: Array = descriptor.get("outputs", [])
		if outputs.is_empty():
			return
		var block: PackedFloat32Array = rack.read_port.call(node_id,
			str(outputs[0]["name"]))
		if block.is_empty():
			return
		_history.append_array(block)
		if _history.size() > HISTORY:
			_history = _history.slice(_history.size() - HISTORY)


	func _draw_analysis() -> void:
		if Rack.density != Rack.Density.ANALYSIS or rack == null:
			return
		if not rack.read_port.is_valid():
			return
		var outputs: Array = descriptor.get("outputs", [])
		if outputs.is_empty():
			return

		# Under whatever the layout actually did, rather than under a re-derivation of it.
		# The old version counted knob rows and multiplied by a cell height to guess where
		# the knobs ended, which was a second copy of the layout kept in step by hand.
		if _grid == null:
			return
		var top: float = _grid.global_position.y - global_position.y + _grid.size.y + 10.0
		var bottom: float = size.y - Rack.KNOB_PAD - 10.0
		if bottom - top < 24.0:
			return
		var area := Rect2(Rack.KNOB_PAD + 4.0, top, size.x - Rack.KNOB_PAD * 2.0 - 8.0,
			bottom - top)

		# Recessed into the panel, the way a display on a real module is.
		draw_rect(area, Rack.JACK_HOLE)
		draw_rect(area, Rack.PANEL_EDGE, false, 1.0)

		var samples := _history
		var colour: Color = rack.type_colours.get(str(outputs[0]["type"]),
			Design.INK_NORMAL)
		if samples.size() < 2:
			return

		# Audio is drawn against a fixed full scale so two modules can be compared.
		# Control is drawn against its own range, because a frequency wire sits at 440
		# and would otherwise be a flat line pinned to the top of every display.
		var is_audio := str(outputs[0]["type"]) == "audio"
		var low := INF
		var high := -INF
		for value in samples:
			low = minf(low, value)
			high = maxf(high, value)
		if is_audio:
			low = -1.0
			high = 1.0
		elif high - low < 1e-6:
			# A control that is holding still is a flat line through the middle, which is
			# the truth about it and reads better than a full-scale line at the top.
			low -= 1.0
			high += 1.0

		var middle := area.position.y + area.size.y * 0.5
		draw_line(Vector2(area.position.x, middle),
			Vector2(area.end.x, middle), Rack.KNOB_TRACK, 1.0)

		var points := PackedVector2Array()
		points.resize(samples.size())
		var step := area.size.x / float(samples.size() - 1)
		for i in samples.size():
			var t: float = inverse_lerp(low, high, clampf(samples[i], low, high))
			points[i] = Vector2(area.position.x + i * step,
				area.end.y - 3.0 - t * (area.size.y - 6.0))
		draw_polyline(points, colour, 1.5, true)


	func _draw() -> void:
		var font: Font = Design.font(Design.WEIGHT_MEDIUM)
		if font == null:
			font = get_theme_default_font()
		var tint: Color = Rack.category_tint(str(descriptor.get("category", "")))

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

		_draw_analysis()

		# Mounting screws, in the rail above and below.
		for point in [Vector2(11.0, 9.0), Vector2(size.x - 11.0, 9.0),
				Vector2(11.0, size.y - 9.0), Vector2(size.x - 11.0, size.y - 9.0)]:
			draw_circle(point, 3.4, Rack.SCREW)
			draw_circle(point, 3.4, Color(0, 0, 0, 0.5), false, 1.0)

		if rack != null and rack.selected_id == node_id:
			draw_rect(Rect2(Vector2.ZERO, size), Rack.SELECTED, false, 2.0)


# ---------------------------------------------------------------------------------
# A jack
# ---------------------------------------------------------------------------------

## One socket and its name, as a control that knows how much room it needs.
##
## It was drawn straight onto the panel at a computed centre, with the name clipped to a
## fixed 42px column — which is why every port on the keyboard read "freque", "gatı",
## "velocit", "trigge". A control can ask for the width its own text wants, and the
## column it sits in can be as wide as its widest member. That is the whole fix.
class Jack extends Control:
	var rack: Control
	var port_name := ""
	var type_name := ""
	var is_input := true

	func _ready() -> void:
		# The full name, always, whatever the panel had room to print.
		tooltip_text = port_name
		mouse_filter = Control.MOUSE_FILTER_PASS

	func _label_font() -> Font:
		return Design.font(Design.WEIGHT_MEDIUM)

	func _label_size() -> int:
		return Design.type(Design.SIZE_SECONDARY)

	func _text_width() -> float:
		var font := _label_font()
		if font == null:
			return 0.0
		return minf(font.get_string_size(port_name, HORIZONTAL_ALIGNMENT_LEFT, -1,
			_label_size()).x, Design.scale(Rack.JACK_LABEL_MAX))

	func _get_minimum_size() -> Vector2:
		return Vector2(Rack.jack_radius() * 2.0 + 6.0 + _text_width(),
			maxf(Rack.jack_radius() * 2.0 + 6.0, float(_label_size()) + 12.0))

	## Where the cable lands, in this control's own space. The socket hugs the outer edge
	## so a cable leaves the panel rather than crossing it.
	func socket_centre() -> Vector2:
		return Vector2(Rack.jack_radius() if is_input else size.x - Rack.jack_radius(),
			size.y * 0.5)

	func _draw() -> void:
		var centre := socket_centre()
		var colour: Color = rack.type_colours.get(type_name, Color.WHITE)
		# The nut, then the hole. An input and an output differ by the ring, not only by
		# which edge they sit on.
		draw_circle(centre, Rack.jack_radius(), Color(0.20, 0.21, 0.24))
		draw_circle(centre, Rack.jack_radius(), Color(0, 0, 0, 0.55), false, 1.0)
		draw_circle(centre, Rack.jack_radius() - 3.0, Rack.JACK_HOLE)
		if is_input:
			draw_circle(centre, Rack.jack_radius() - 1.5, colour, false, 2.0)
		else:
			draw_circle(centre, Rack.jack_radius() - 5.5, colour)

		var font := _label_font()
		if font == null:
			return
		var room := size.x - Rack.jack_radius() * 2.0 - 6.0
		if room <= 4.0:
			return
		var text := Rack.elided(font, port_name, _label_size(), room)
		var baseline := size.y * 0.5 + float(_label_size()) * 0.36
		draw_string(font,
			Vector2(Rack.jack_radius() * 2.0 + 6.0 if is_input else 0.0, baseline), text,
			HORIZONTAL_ALIGNMENT_LEFT if is_input else HORIZONTAL_ALIGNMENT_RIGHT,
			room, _label_size(), rack.ink_dim)


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

	## Dial only, with the name and the value left to whatever is placing it.
	##
	## The graph view puts the name above the number beside the dial rather than below
	## it, and that is the whole difference between the two views' cells. Stacking them
	## as the rack does makes a cell 99px tall; a graph node with four of those is taller
	## than the sliders it replaced, which is the opposite of the point. Same control,
	## same keyboard, same signal path — one draws its own caption and one does not.
	var compact := false

	var _position := 0.0               # 0..1 along the parameter's own scaling
	var _dragging := false
	var _drag_origin := 0.0
	var _drag_from := 0.0

	func _ready() -> void:
		mouse_default_cursor_shape = Control.CURSOR_VSIZE
		# Reachable by Tab, and announced as the control it is rather than as a drawing.
		focus_mode = Control.FOCUS_ALL
		# The ring is drawn by _draw, and _draw does not run again on its own when focus
		# moves — so without these the ring appeared on the first knob to be focused and
		# then never moved.
		focus_entered.connect(queue_redraw)
		focus_exited.connect(queue_redraw)
		# The name in full ahead of the documentation, because the panel may only have
		# had room for "cutoff_sw…" and the first question a truncated label raises is
		# what it was truncated from.
		var doc := str(descriptor.get("doc", ""))
		tooltip_text = str(descriptor["name"]) + ("\n" + doc if doc != "" else "")

	func _name_text() -> String:
		return str(descriptor["name"])

	func _value_text() -> String:
		if descriptor.has("enum"):
			var options: Array = descriptor["enum"]
			return str(options[clampi(int(value()), 0, options.size() - 1)])
		return Rack.format_value(value())

	## The widest this knob's value will ever be, so the cell does not resize while it is
	## being turned.
	##
	## Measuring the *current* value would make the grid reflow mid-drag — the panel
	## breathing in and out under the pointer as 9.99 became 10.0 — and would let a knob
	## that happens to be sitting at 0 claim a cell too narrow for the number it is about
	## to show.
	func _widest_value() -> String:
		if descriptor.has("enum"):
			var longest := ""
			for option in descriptor["enum"]:
				if str(option).length() > longest.length():
					longest = str(option)
			return longest
		var low := Rack.format_value(float(descriptor.get("min", 0.0)))
		var high := Rack.format_value(float(descriptor.get("max", 1.0)))
		return low if low.length() > high.length() else high

	func _get_minimum_size() -> Vector2:
		if compact:
			# The dial and nothing else. Its own hit area still has to clear the rule
			# every other control in this application obeys.
			var dial := Rack.knob_radius() * 2.0 + 8.0
			return Vector2(dial, maxf(dial, Design.scale(Design.HIT_TARGET)))
		var label_font: Font = Design.font(Design.WEIGHT_MEDIUM)
		var label_size := Design.type(Design.SIZE_SECONDARY)
		var value_font: Font = Design.numeric_font()
		var value_size := Design.type(Design.SIZE_NUMERIC)
		var widest := Rack.knob_radius() * 2.0 + 12.0
		if label_font != null:
			widest = maxf(widest, minf(label_font.get_string_size(_name_text(),
				HORIZONTAL_ALIGNMENT_LEFT, -1, label_size).x,
				Design.scale(Rack.JACK_LABEL_MAX)))
		if value_font != null:
			widest = maxf(widest, value_font.get_string_size(_widest_value(),
				HORIZONTAL_ALIGNMENT_LEFT, -1, value_size).x)
		return Vector2(widest + Rack.KNOB_PAD * 2.0,
			maxf(Rack.KNOB_CELL.y, Rack.knob_radius() * 2.0 + 14.0
				+ float(label_size) + float(value_size) + 10.0))

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

	## One step of the keyboard, as a fraction of the knob's travel. The same numbers the
	## graph view's readout uses, because a reader who has learned that Left is a small
	## step and Shift+Left a large one has learned it for the application, not for a
	## widget.
	const KEY_STEP := 0.01
	const KEY_COARSE := 0.1

	## Moves the knob by a fraction of its travel and reports it, as one undo step.
	##
	## Presses are their own edit rather than being folded into a drag: a drag has a
	## beginning and an end the mouse announces, and a key press has neither.
	func nudge(fraction: float) -> void:
		var before := _position
		_position = clampf(_position + fraction, 0.0, 1.0)
		if is_equal_approx(before, _position):
			return
		rack.edit_started.emit()
		rack.parameter_changed.emit(node_id, str(descriptor["name"]), value())
		rack.edit_finished.emit("set %s" % str(descriptor["name"]))
		queue_redraw()

	func _gui_input(event: InputEvent) -> void:
		# A knob you cannot reach from the keyboard is a knob half the people who might
		# use this cannot reach at all. The graph view's sliders and readouts have taken
		# arrow keys since the accessibility pass; this is the same control wearing a
		# different picture, so it takes them too.
		if event is InputEventKey and event.pressed:
			var step: float = KEY_COARSE if event.shift_pressed else KEY_STEP
			if event.keycode == KEY_LEFT or event.keycode == KEY_DOWN:
				nudge(-step)
				accept_event()
				return
			if event.keycode == KEY_RIGHT or event.keycode == KEY_UP:
				nudge(step)
				accept_event()
				return
			if event.keycode == KEY_HOME:
				nudge(-1.0)
				accept_event()
				return
			if event.keycode == KEY_END:
				nudge(1.0)
				accept_event()
				return
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				# So the arrow keys go to the knob that was just touched, rather than to
				# whatever held focus before it.
				grab_focus()
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
		var centre := Vector2(size.x * 0.5,
			size.y * 0.5 if compact else Rack.knob_radius() + 6.0)
		var angle := START + SWEEP * _position

		draw_arc(centre, Rack.knob_radius() + 5.0, START, START + SWEEP, 40,
			Rack.KNOB_TRACK, 3.0, true)
		draw_arc(centre, Rack.knob_radius() + 5.0, START, angle, 40,
			Rack.SELECTED, 3.0, true)

		# Focus is drawn around the whole cell, not around the dial: the name and the
		# value are part of what is focused, and a ring that hugged the circle looked
		# like a selected knob rather than a keyboard position.
		if has_focus():
			draw_rect(Rect2(Vector2.ONE, size - Vector2.ONE * 2.0), Design.FOCUS,
				false, 2.0)

		draw_circle(centre, Rack.knob_radius(), Rack.KNOB_BODY)
		draw_circle(centre, Rack.knob_radius(), Color(0, 0, 0, 0.5), false, 1.0)
		draw_circle(centre - Vector2(0, 1), Rack.knob_radius() - 5.0,
			Rack.KNOB_BODY.lightened(0.10))
		# The pointer, which is what actually tells you where the knob is set.
		draw_line(centre + Vector2(cos(angle), sin(angle)) * 6.0,
			centre + Vector2(cos(angle), sin(angle)) * (Rack.knob_radius() - 3.0),
			rack.ink, 2.5, true)

		# Compact draws the dial and stops: its name and its number belong to whatever
		# placed it, and drawing them here too would print one over the other.
		if font == null or compact:
			return
		# Names in Medium at the secondary size, values in the tabular face at the
		# numeric size — which is larger, not smaller.
		#
		# Both were 11px, and the value was being treated as metadata attached to the
		# name. It is the other way round: the name tells you which knob this is, which
		# you learn once, and the value tells you where it is set, which is what you came
		# to read and what changes while you watch. At 11px it was the weakest text in
		# the application.
		# Both bounded by the cell, which is itself as wide as the wider of them. Drawn
		# with an explicit width and centred alignment rather than by subtracting a
		# measured half-width from the middle: the old version had no bound at all, so a
		# name wider than its cell simply printed over the knob beside it.
		var label_font: Font = Design.font(Design.WEIGHT_MEDIUM)
		var label_size := Design.type(Design.SIZE_SECONDARY)
		var room := size.x - Rack.KNOB_PAD * 2.0
		var value_font: Font = Design.numeric_font()
		var value_size := Design.type(Design.SIZE_NUMERIC)
		var value_baseline := size.y - Rack.KNOB_PAD * 0.5
		var name_baseline := value_baseline - float(value_size) - 4.0
		draw_string(label_font, Vector2(Rack.KNOB_PAD, name_baseline),
			Rack.elided(label_font, _name_text(), label_size, room),
			HORIZONTAL_ALIGNMENT_CENTER, room, label_size, rack.ink_dim)
		draw_string(value_font, Vector2(Rack.KNOB_PAD, value_baseline),
			Rack.elided(value_font, _value_text(), value_size, room),
			HORIZONTAL_ALIGNMENT_CENTER, room, value_size, rack.ink)


## Trims text to the room there is, with an ellipsis to say it was trimmed.
##
## An ellipsis rather than a hard cut, because "cutoff_mo" and "cutoff_mod" are two
## plausible port names and the reader cannot tell which one they are looking at.
static func elided(font: Font, text: String, size: int, room: float) -> String:
	if font == null or room <= 0.0:
		return ""
	if font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x <= room:
		return text
	var kept := text
	while kept.length() > 1:
		kept = kept.substr(0, kept.length() - 1)
		if font.get_string_size(kept + "…", HORIZONTAL_ALIGNMENT_LEFT, -1,
				size).x <= room:
			return kept + "…"
	return "…"


static func format_value(value: float) -> String:
	var magnitude := absf(value)
	if magnitude >= 1000.0:
		return "%.0f" % value
	if magnitude >= 10.0:
		return "%.1f" % value
	if magnitude >= 1.0:
		return "%.2f" % value
	return "%.3f" % value
