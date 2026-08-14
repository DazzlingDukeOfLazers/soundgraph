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

## How many knobs to a line before wrapping. A performance panel is read across, and a
## column of one is a list.
const PER_LINE := 2

var patch: Dictionary = {}
var registry: Dictionary = {}
var rack: Control = null

## The panel's own order, after somebody dragged a knob to a new place in it.
signal reordered(control_ids: Array)

## True while the wand is up. A knob on this panel is a control to be turned, until then —
## the same bargain the rack strikes, and for the same reason: a knob that moved *and*
## turned would be one you could not put down without also having changed the sound.
var wand := false:
	set(value):
		wand = value
		_carrying = -1
		_target = -1
		set_process_input(value)
		queue_redraw()

var _cells: Array = []          # Control per control, in panel order
var _ids: Array = []            # the control ids, same order
var _carrying := -1
var _target := -1


## First refusal on the press, ahead of the GUI pass — the only reason a knob can be
## picked up at all, since a knob is a Control and would otherwise eat it. See
## PatchGraph._input, which does the same thing for the same reason.
func _input(event: InputEvent) -> void:
	if not wand or not is_visible_in_tree() or _cells.is_empty():
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
			if to >= 0 and to != from:
				var moved: Array = _ids.duplicate()
				var name: String = moved[from]
				moved.remove_at(from)
				moved.insert(clampi(to if to < from else to - 1, 0, moved.size()), name)
				reordered.emit(moved)
		return
	var motion := event as InputEventMouseMotion
	if motion != null and _carrying >= 0:
		_target = _gap_at(motion.global_position)
		queue_redraw()
		get_viewport().set_input_as_handled()


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
	for cell: Control in _cells:
		var rect: Rect2 = cell.get_global_rect()
		if point.y > rect.position.y + rect.size.y or (point.y > rect.position.y
				and point.x > rect.position.x + rect.size.x * 0.5):
			gap += 1
	return gap


func _draw() -> void:
	if not wand or _cells.is_empty():
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


func rebuild() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_cells.clear()
	_ids.clear()

	var controls: Array = patch.get("controls", [])
	if controls.is_empty():
		# An empty panel says what it is for. A blank column is indistinguishable from a
		# broken one, and this is the state every new patch starts in.
		var hint := Label.new()
		hint.text = "No knobs on the face yet. Raise the wand and click one in the graph."
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		hint.add_theme_font_size_override("font_size", Design.type(Design.SIZE_SECONDARY))
		hint.add_theme_color_override("font_color", Design.INK_SECOND)
		add_child(hint)
		return

	var line: HBoxContainer = null
	for index in controls.size():
		var control: Dictionary = controls[index]
		var descriptor := _descriptor_for(control.get("target", {}))
		if descriptor.is_empty():
			continue
		if line == null or line.get_child_count() >= PER_LINE:
			line = HBoxContainer.new()
			line.add_theme_constant_override("separation", Design.SPACE_M)
			line.alignment = BoxContainer.ALIGNMENT_CENTER
			add_child(line)
		var cell := _cell(control, descriptor)
		line.add_child(cell)
		_cells.append(cell)
		_ids.append(str(control.get("id", "")))


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
