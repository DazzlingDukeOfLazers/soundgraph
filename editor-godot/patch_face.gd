extends VBoxContainer
## The face of the whole file: the knobs somebody plays, rather than the graph that makes
## the sound.
##
## It needs no new idea in the document, because the document has had one since v1.
## `controls` is the performance surface — "deliberately separate from the DSP graph: the
## same parameter may be driven by a Godot knob, a browser slider, a DAW automation lane,
## a MIDI CC or a physical encoder without changing the graph", says the schema — and every
## example in this repository carries one. First Synth has seven. Collapse remaps them
## through a module's facade, expand brings them back down, and nothing in the editor has
## ever drawn a single one of them. This draws them.
##
## So a patch has a panel the way a module does, and it is the same kind of thing: a
## selection out of everything the graph could expose, in an order somebody chose, with
## names they chose. The wand puts knobs on it and takes them off.
##
## Values go through the rack's own signals rather than a second copy of the wiring —
## `parameter_changed` already lands in main._on_rack_parameter_changed, which writes the
## document and syncs whichever other view did not originate the change. Two panels
## showing one parameter cannot drift apart about what it is set to.

const Rack := preload("res://rack.gd")
const Seams := preload("res://seams.gd")

## How many knobs to a line before wrapping. A performance panel is read across, and a
## column of one is a list.
const PER_LINE := 2

## How far down an offer is turned: enough to read as something available rather than as
## something already on the panel. The same value the module's face uses.
const OFFERED := Color(1.0, 1.0, 1.0, 0.45)

var patch: Dictionary = {}
var registry: Dictionary = {}
var rack: Control = null

## True while the panel is showing the default rather than the file's own.
##
## A file with no `controls` used to get one line of hint and nothing else — which is most
## of them, since only the hand-written examples carry a panel. A DX7 patch is fifteen nodes
## and sixty-odd knobs and the panel said "no knobs on the face yet", which is true about the
## document and useless about the instrument.
##
## So the default is every knob the patch has, grouped by the node it belongs to. It is a
## view, not an edit: nothing is written until somebody puts a knob on deliberately, and at
## that moment main seeds `controls` from this same list so the default becomes theirs
## rather than being replaced by the one thing they just added.
var derived := false

## The panel's own order, after somebody dragged a knob to a new place in it.
signal reordered(control_ids: Array)

## The node whose knobs are offered under the panel, or "" for none. Set from the selection:
## the offers are what *that* node could put on the face and has not, so choosing a node is
## how you choose what to add.
var offer_node := "":
	set(value):
		offer_node = value
		_carrying = -1
		_target = -1

## A knob was dragged onto the panel from the offers, or off the panel altogether. Both go
## through main._toggle_control, which is a toggle: the panel is the one place a control is
## listed, so putting one on and taking it off are the same edit run twice.
signal offered(node_id: String, parameter: String)

var _cells: Array = []          # Control per cell, panel first then the offers
var _ids: Array = []            # the control ids, panel cells only
## {cell index: {"node", "parameter"}} for the offers, and for the panel's own cells, so a
## drag either way knows what it is holding without asking the document again.
var _offers: Dictionary = {}
var _targets: Dictionary = {}
var _carrying := -1
var _target := -1


## First refusal on the press, ahead of the GUI pass — the only reason a knob can be
## picked up at all, since a knob is a Control and would otherwise eat it. See
## PatchGraph._input, which does the same thing for the same reason.
func _input(event: InputEvent) -> void:
	if not is_visible_in_tree() or _cells.is_empty():
		return
	var button := event as InputEventMouseButton
	if button != null and button.button_index == MOUSE_BUTTON_LEFT:
		if button.pressed:
			_carrying = _cell_at(button.global_position)
			_target = _carrying
			if _carrying >= 0:
				get_viewport().set_input_as_handled()
		elif _carrying >= 0:
			var from := _carrying
			var to := _target
			_carrying = -1
			_target = -1
			queue_redraw()
			get_viewport().set_input_as_handled()
			_finish(from, to)
		return
	var motion := event as InputEventMouseMotion
	if motion != null and _carrying >= 0:
		_target = _gap_at(motion.global_position) \
			if get_global_rect().has_point(motion.global_position) else -1
		queue_redraw()
		get_viewport().set_input_as_handled()


## What a finished drag meant. Kept apart from _input so the suite can drive it with two
## indices rather than three synthetic events.
func _finish(from: int, to: int) -> void:
	if from < 0 or from >= _cells.size():
		return
	var offer: Dictionary = _offers.get(from, {})
	if not offer.is_empty():
		# From the offers onto the panel. Anywhere on it: an offer has no place on the face
		# yet, so "where" is not a question it can answer, and the panel's own order is what
		# a later drag is for.
		if to >= 0:
			offered.emit(str(offer["node"]), str(offer["parameter"]))
		return
	if to < 0:
		# Off the panel: the same toggle, run the other way.
		var target: Dictionary = _targets.get(from, {})
		if not target.is_empty():
			offered.emit(str(target["node"]), str(target["parameter"]))
		return
	if to == from:
		return
	var moved: Array = _ids.duplicate()
	var name: String = moved[from]
	moved.remove_at(from)
	moved.insert(clampi(to if to < from else to - 1, 0, moved.size()), name)
	reordered.emit(moved)


func _cell_at(point: Vector2) -> int:
	for index in _cells.size():
		if (_cells[index] as Control).get_global_rect().has_point(point):
			return index
	return -1


## The gap a drop would land in, counted in cells: the number of cells whose middle the
## pointer is already past. A gap rather than a cell, because dropping *onto* something
## has to mean either before or after it and there is no way to say which.
func _gap_at(point: Vector2) -> int:
	var gap := 0
	for index in _ids.size():
		var rect: Rect2 = (_cells[index] as Control).get_global_rect()
		if point.y > rect.position.y + rect.size.y or (point.y > rect.position.y
				and point.x > rect.position.x + rect.size.x * 0.5):
			gap += 1
	return gap


func _draw() -> void:
	if _cells.is_empty():
		return
	var inverse := get_global_transform().affine_inverse()
	for index in _cells.size():
		var rect: Rect2 = (_cells[index] as Control).get_global_rect()
		var local := Rect2(inverse * rect.position, rect.size)
		if index == _carrying:
			draw_rect(local, Design.ACCENT, false, 2.0)
		else:
			Design.dashed_rect(self, local, Color(Design.INK_BRIGHT, 0.7))
	if _carrying < 0 or _target < 0:
		return
	# The caret, in the gap the drop would land in. Past the last cell it goes on the far
	# edge of it, which is the only place left to mean "after everything".
	var edge: Rect2
	var after := _target >= _cells.size()
	edge = (_cells[mini(_target, _cells.size() - 1)] as Control).get_global_rect()
	var at := inverse * (edge.position + (Vector2(edge.size.x, 0.0) if after else Vector2.ZERO))
	draw_rect(Rect2(at - Vector2(1.5, 0.0), Vector2(3.0, edge.size.y)), Design.ACCENT)


func _ready() -> void:
	add_theme_constant_override("separation", Design.SPACE_S)


## The parameter descriptor a control points at, or empty when it points at nothing —
## which happens to a file somebody hand-edited, and to one whose node was deleted.
func _descriptor_for(target: Dictionary) -> Dictionary:
	var node_id := str(target.get("node", ""))
	for node in patch.get("nodes", []):
		if str(node["id"]) != node_id:
			continue
		var type_key: String = "module:%s" % str(node.get("module", "")) \
			if str(node.get("type", "")) == "module" else str(node.get("type", ""))
		for parameter in registry.get(type_key, {}).get("parameters", []):
			if str(parameter["name"]) == str(target.get("parameter", "")):
				return parameter
		return {}
	return {}


## Every knob in the patch, in document order, as control entries. A module instance
## contributes its exported surface; a plain node its own parameters — which is the same
## rule the inspector and the node bodies follow, so the panel shows what the graph shows.
static func default_controls(patch: Dictionary, registry: Dictionary) -> Array:
	var out: Array = []
	for node in patch.get("nodes", []):
		# Ports are not knobs. They appear on the panel, but as the strip below rather than
		# as something to turn.
		if Seams.is_port_seam(node) or str(node.get("type", "")) in ["Input", "Output"]:
			continue
		var key: String = "module:%s" % str(node.get("module", "")) \
			if str(node.get("type", "")) == "module" else str(node.get("type", ""))
		for parameter in registry.get(key, {}).get("parameters", []):
			out.append({
				"id": "%s.%s" % [str(node["id"]), str(parameter["name"])],
				"label": str(parameter.get("display_name", parameter["name"])),
				"kind": "knob",
				"target": {"node": str(node["id"]), "parameter": str(parameter["name"])},
			})
	return out


func rebuild() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_cells.clear()
	_ids.clear()
	_offers.clear()
	_targets.clear()

	var controls: Array = patch.get("controls", [])
	derived = controls.is_empty()
	if derived:
		controls = default_controls(patch, registry)
		if not controls.is_empty():
			var note := Label.new()
			note.text = "Every knob in the patch. Drag one on to start a panel of your own."
			note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			note.add_theme_font_size_override("font_size", Design.type(Design.SIZE_SECONDARY))
			note.add_theme_color_override("font_color", Design.INK_SECOND)
			add_child(note)
	if controls.is_empty():
		# A blank column is indistinguishable from a broken one, and this is the state a
		# patch with nothing to turn is genuinely in.
		var hint := Label.new()
		hint.text = "Nothing to turn in this patch yet."
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		hint.add_theme_font_size_override("font_size", Design.type(Design.SIZE_SECONDARY))
		hint.add_theme_color_override("font_color", Design.INK_SECOND)
		add_child(hint)

	# Grouped, then flowed.
	#
	# Forty-three knobs in one column is a column nobody reads to the bottom of. They go in
	# blocks instead — one per node, wrapped two wide — and the blocks flow across whatever
	# width the panel has, wrapping to a new line when they run out of room. Widen the panel
	# and you get more blocks side by side; it fills horizontally rather than growing down.
	#
	# A block is never split. The knobs of one node belong together, and half of an operator
	# at the bottom of one line with the rest at the top of the next is worse than either a
	# short line or a long panel. That is the whole reason this is a flow of blocks rather
	# than a flow of knobs.
	#
	# Blocks are runs of the same target node *in the order the panel already had*, never a
	# regrouping. A file's own `controls` is an ordered statement of intent and reordering it
	# to tidy the layout would be the panel overruling the author.
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", Design.SPACE_M)
	flow.add_theme_constant_override("v_separation", Design.SPACE_M)
	flow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(flow)

	var on_panel := {}
	var block: VBoxContainer = null
	var grid: GridContainer = null
	var block_node := ""
	for index in controls.size():
		var control: Dictionary = controls[index]
		var target: Dictionary = control.get("target", {})
		var descriptor := _descriptor_for(target)
		if descriptor.is_empty():
			continue
		var node_id := str(target.get("node", ""))
		on_panel["%s.%s" % [node_id, str(target.get("parameter", ""))]] = true

		if block == null or node_id != block_node:
			block_node = node_id
			block = VBoxContainer.new()
			block.add_theme_constant_override("separation", 0)
			flow.add_child(block)
			# Which node these belong to. Only worth saying when there is more than one
			# block; a panel of one group is a panel about one thing and the heading would
			# be repeating the file name back.
			var heading := Label.new()
			heading.text = node_id
			heading.add_theme_font_size_override("font_size",
				Design.type(Design.SIZE_SECONDARY))
			heading.add_theme_color_override("font_color", Design.INK_SECOND)
			heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			heading.clip_text = true
			heading.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			block.add_child(heading)
			grid = GridContainer.new()
			grid.columns = PER_LINE
			grid.add_theme_constant_override("h_separation", Design.SPACE_M)
			grid.add_theme_constant_override("v_separation", Design.SPACE_S)
			block.add_child(grid)

		var cell := _cell(control, descriptor)
		grid.add_child(cell)
		_targets[_cells.size()] = {"node": node_id,
			"parameter": str(target.get("parameter", ""))}
		_cells.append(cell)
		# Only a panel the file actually has can be rearranged or taken from. The default
		# is a picture of what is there; dragging within it would be dragging within a
		# derivation, and the honest first gesture is putting a knob on.
		if not derived:
			_ids.append(str(control.get("id", "")))

	# One block is one thing, and does not need labelling as such.
	if flow.get_child_count() == 1:
		var only: Node = flow.get_child(0)
		if only.get_child_count() > 0 and only.get_child(0) is Label:
			(only.get_child(0) as Label).visible = false

	_add_ports()

	# What the selected node could put on the panel and has not.
	#
	# The same offer the module's face makes, at the file's scale — and the reason there is
	# no tool to raise. The wand asked you to arm a mode and then point at a knob on the
	# canvas; this asks you to select the node you were going to point at anyway, and shows
	# what it has. Only the selection, because every parameter in a large patch is hundreds
	# of knobs and a panel of offers nobody can read is not an offer.
	if offer_node == "":
		return
	var spare: Array = []
	for parameter: Dictionary in registry.get(_type_of(offer_node), {}).get("parameters", []):
		if not on_panel.has("%s.%s" % [offer_node, str(parameter["name"])]):
			spare.append(parameter)
	if spare.is_empty():
		return

	var caption := Label.new()
	caption.text = "%s — not on the panel" % offer_node
	caption.add_theme_font_size_override("font_size", Design.type(Design.SIZE_SECONDARY))
	caption.add_theme_color_override("font_color", Design.INK_SECOND)
	add_child(caption)

	var offer_line: HBoxContainer = null
	for parameter: Dictionary in spare:
		if offer_line == null or offer_line.get_child_count() >= PER_LINE:
			offer_line = HBoxContainer.new()
			offer_line.add_theme_constant_override("separation", Design.SPACE_M)
			offer_line.alignment = BoxContainer.ALIGNMENT_CENTER
			add_child(offer_line)
		var ghost := _cell({"target": {"node": offer_node,
			"parameter": str(parameter["name"])}}, parameter)
		ghost.modulate = OFFERED
		offer_line.add_child(ghost)
		_offers[_cells.size()] = {"node": offer_node, "parameter": str(parameter["name"])}
		_cells.append(ghost)


## Where this file meets the machine: its ports, in the order the document lists them.
##
## On the panel because the panel is the file\'s face, and a face has its sockets on it —
## "what do I plug in, and where does it come out" is the other half of "what do I turn".
## Read-only here: a port is moved by dragging its jack on the keyboard, which is the
## gesture that already exists for it.
func _add_ports() -> void:
	var seams: Array = []
	for node in patch.get("nodes", []):
		if str(node.get("type", "")) in ["Input", "Output"]:
			seams.append(node)
	if seams.is_empty():
		return

	var caption := Label.new()
	caption.text = "Ports"
	caption.add_theme_font_override("font", Design.font(Design.WEIGHT_MEDIUM))
	caption.add_theme_font_size_override("font_size", Design.type(Design.SIZE_SECONDARY))
	caption.add_theme_color_override("font_color", Design.INK_SECOND)
	add_child(caption)

	for node: Dictionary in seams:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", Design.SPACE_S)

		var name_label := Label.new()
		var shown := str(node.get("name", ""))
		if shown == "":
			shown = str(node["id"])
		name_label.text = shown
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_label.clip_text = true
		name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		name_label.add_theme_font_size_override("font_size", Design.type(Design.SIZE_CONTROL))
		row.add_child(name_label)

		var where := Label.new()
		var host := str(node.get("host", ""))
		# What is plugged into it, or that nothing is — which is a state that means
		# something now: a port nothing drives is one this patch offers to whatever uses it.
		where.text = host if host != "" else "not plugged in"
		where.add_theme_font_size_override("font_size", Design.type(Design.SIZE_SECONDARY))
		where.add_theme_color_override("font_color",
			Design.INK_SECOND if host != "" else Design.INK_DISABLED)
		row.add_child(where)
		add_child(row)


## The registry key of a node in this patch — a module's synthesized entry or its plain
## type. Same rule as _descriptor_for, which is where it came from.
func _type_of(node_id: String) -> String:
	for node in patch.get("nodes", []):
		if str(node["id"]) != node_id:
			continue
		return "module:%s" % str(node.get("module", "")) \
			if str(node.get("type", "")) == "module" else str(node.get("type", ""))
	return ""


## One knob and its name. The name is the control's label when it has one, since that is
## the whole point of a label — "Cutoff" is what a player calls it and `cutoff` is what
## the graph calls it, and the file has room for both.
func _cell(control: Dictionary, descriptor: Dictionary) -> Control:
	var cell := VBoxContainer.new()
	cell.add_theme_constant_override("separation", 0)
	cell.alignment = BoxContainer.ALIGNMENT_CENTER
	cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var target: Dictionary = control.get("target", {})
	var knob := Rack.Knob.new()
	knob.rack = rack
	knob.compact = true
	knob.node_id = str(target.get("node", ""))
	knob.descriptor = descriptor
	knob.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var current: float = float(_value_of(str(target.get("node", "")),
		str(target.get("parameter", "")), float(descriptor.get("default", 0.0))))
	knob.set_value_silently(current)
	cell.add_child(knob)

	var caption := Label.new()
	caption.text = str(control.get("label", "")) if str(control.get("label", "")) != "" \
		else str(target.get("parameter", ""))
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	caption.clip_text = true
	caption.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	caption.add_theme_font_override("font", Design.font(Design.WEIGHT_MEDIUM))
	caption.add_theme_font_size_override("font_size", Design.type(Design.SIZE_BODY))
	caption.add_theme_color_override("font_color", Design.INK_NORMAL)
	# What it actually drives, quietly, under the name somebody gave it. A panel whose
	# captions have been renamed is a panel you cannot trace back to the graph without it.
	caption.tooltip_text = "%s.%s" % [str(target.get("node", "")),
		str(target.get("parameter", ""))]
	cell.add_child(caption)

	var wiring := Label.new()
	wiring.text = "%s.%s" % [str(target.get("node", "")), str(target.get("parameter", ""))]
	wiring.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	wiring.clip_text = true
	wiring.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	wiring.add_theme_font_size_override("font_size", Design.type(Design.SIZE_SECONDARY))
	wiring.add_theme_color_override("font_color", Design.INK_SECOND)
	cell.add_child(wiring)
	return cell


func _value_of(node_id: String, parameter: String, fallback: float) -> float:
	for node in patch.get("nodes", []):
		if str(node["id"]) == node_id:
			return float(node.get("parameters", {}).get(parameter, fallback))
	return fallback
