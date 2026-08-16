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

## How many *offers* to a line before wrapping. The knob blocks themselves are laid out
## as rack modules in rebuild(); this only shapes the ghost strip under them.
const PER_LINE := 2

## The four parameters that make an envelope, and the letter each wears on the panel.
##
## When a node carries all four they are drawn as a row of vertical sliders instead of
## knobs, because an envelope reads as heights side by side — the sliders *are* the
## shape of the sound, which four dials never quite manage. All four or none: a node
## with only a `decay` has a decay knob, not a one-slider envelope.
const ENVELOPE := {"attack": "A", "decay": "D", "sustain": "S", "release": "R"}

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
		elif _offers.has(index):
			# Only the ghosts keep the dashed outline. Dashed means "this could be acted
			# on", which is exactly what an offer is — but on every panel cell it was
			# forty rectangles of chrome saying the same thing, and the dotted group
			# frames now carry the panel's structure instead.
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

	# A rack row, not a column.
	#
	# Forty-three knobs stacked downwards is a list nobody reads to the bottom of. So the
	# panel is shaped like the thing it names: a row of modules on one rail, every block the
	# same height the rack view would give this patch, read sideways the way a hardware case
	# is. One block per node, knobs two across inside it exactly as the rack draws them, and
	# a node with more knobs than one bank holds grows *rightwards* — another two-wide bank
	# on the same panel, a wide module rather than a tall one.
	#
	# The row overflows horizontally and scrolls, because that is what a rack does: a case
	# with more modules than the desk is walked along, not folded. Height is the one thing
	# that never moves — the rail is the promise.
	#
	# A block is never split. The knobs of one node belong together, and half an operator in
	# one place with the rest somewhere else is worse than a longer row.
	#
	# Blocks are runs of the same target node *in the order the panel already had*, never a
	# regrouping. A file's own `controls` is an ordered statement of intent and reordering it
	# to tidy the layout would be the panel overruling the author.
	var runs: Array = []
	var on_panel := {}
	for index in controls.size():
		var control: Dictionary = controls[index]
		var target: Dictionary = control.get("target", {})
		var descriptor := _descriptor_for(target)
		if descriptor.is_empty():
			continue
		var node_id := str(target.get("node", ""))
		on_panel["%s.%s" % [node_id, str(target.get("parameter", ""))]] = true
		if runs.is_empty() or str(runs.back()["node"]) != node_id:
			runs.append({"node": node_id, "controls": []})
		(runs.back()["controls"] as Array).append({"control": control,
			"descriptor": descriptor})

	if not runs.is_empty():
		# The rack's *default* height, on purpose not Rack.measure of this patch. The rack
		# view raises its rail to fit the busiest module, because a rail must hold its
		# tallest occupant; measured that way the busiest node always fits one bank and
		# nothing ever spills. The panel does the opposite trade: the height never moves,
		# and a node too busy for one bank pays in width.
		var panel_height: float = float(Design.scale(Rack.DEFAULT_HEIGHT))

		var scroller := ScrollContainer.new()
		scroller.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
		scroller.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		scroller.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		# Room for the row plus the scrollbar under it, so the bar never eats a knob.
		scroller.custom_minimum_size.y = panel_height + Design.scale(14)
		add_child(scroller)

		var rail := HBoxContainer.new()
		rail.add_theme_constant_override("separation", Design.SPACE_M)
		scroller.add_child(rail)

		for run: Dictionary in runs:
			var block := VBoxContainer.new()
			block.add_theme_constant_override("separation", 0)
			block.custom_minimum_size.y = panel_height
			rail.add_child(block)
			# The group frame, dotted. A grouping is a fact about belonging, not an
			# affordance — dashed already means "this could be acted on" and solid means
			# "this is", so the frame gets its own register rather than borrowing one
			# that makes a promise.
			block.draw.connect(func() -> void:
				Design.dotted_rect(block, Rect2(Vector2.ZERO, block.size).grow(-1.0),
					Color(Design.INK_SECOND, 0.5)))

			# The title band. Only worth saying when there is more than one block; a panel
			# of one group is a panel about one thing and the heading would be repeating
			# the file name back.
			var heading := Label.new()
			heading.text = str(run["node"])
			heading.visible = runs.size() > 1
			heading.add_theme_font_size_override("font_size",
				Design.type(Design.SIZE_SECONDARY))
			heading.add_theme_color_override("font_color", Design.INK_SECOND)
			heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			heading.clip_text = true
			heading.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			block.add_child(heading)

			# All four envelope parameters or none — see ENVELOPE.
			var enveloped := true
			for wanted in ENVELOPE:
				var found := false
				for entry: Dictionary in run["controls"]:
					if str((entry["control"] as Dictionary)
							.get("target", {}).get("parameter", "")) == str(wanted):
						found = true
				if not found:
					enveloped = false

			# Build the cells first, because how many fit in a bank depends on how tall
			# they actually are — the caption and the wiring line under each knob grow
			# with the reader's type size, and a capacity guessed from constants would be
			# wrong at exactly the sizes it matters. Built in document order whatever
			# they are, so _cells keeps the order the file states.
			var cells: Array = []
			var slider_cells: Array = []
			var cell_height := 1.0
			for entry: Dictionary in run["controls"]:
				var parameter := str((entry["control"] as Dictionary)
					.get("target", {}).get("parameter", ""))
				var cell: Control
				if enveloped and ENVELOPE.has(parameter):
					var slide := Rack.Fader.new()
					slide.rack = rack
					slide.node_id = str(run["node"])
					slide.descriptor = entry["descriptor"]
					slide.label = str(ENVELOPE[parameter])
					slide.size_flags_horizontal = Control.SIZE_EXPAND_FILL
					slide.size_flags_vertical = Control.SIZE_EXPAND_FILL
					slide.set_value_silently(float(_value_of(str(run["node"]),
						parameter, float(entry["descriptor"].get("default", 0.0)))))
					slider_cells.append(slide)
					cell = slide
				else:
					cell = _cell(entry["control"], entry["descriptor"])
					cells.append(cell)
					cell_height = maxf(cell_height, cell.get_combined_minimum_size().y)
				_targets[_cells.size()] = {"node": str(run["node"]),
					"parameter": parameter}
				_cells.append(cell)
				# Only a panel the file actually has can be rearranged or taken from. The
				# default is a picture of what is there; dragging within it would be
				# dragging within a derivation, and the honest first gesture is putting
				# a knob on.
				if not derived:
					_ids.append(str((entry["control"] as Dictionary).get("id", "")))

			var banks := HBoxContainer.new()
			banks.add_theme_constant_override("separation", Design.SPACE_M)
			block.add_child(banks)

			# The envelope reserves its floor before the banks divide what is left, or a
			# busy node's knobs would push the sliders out of the block's fixed height.
			var reserved := 0.0
			if not slider_cells.is_empty():
				reserved = (slider_cells[0] as Control).get_combined_minimum_size().y \
					+ float(Design.SPACE_S)
			var room: float = panel_height - heading.get_combined_minimum_size().y \
				- reserved
			var pitch: float = cell_height + float(Design.SPACE_S)
			var rows: int = maxi(1, int(floorf((room + float(Design.SPACE_S)) / pitch)))
			var bank: GridContainer = null
			for cell_index in cells.size():
				if cell_index % (rows * 2) == 0:
					bank = GridContainer.new()
					bank.columns = 2
					bank.add_theme_constant_override("h_separation", Design.SPACE_M)
					bank.add_theme_constant_override("v_separation", Design.SPACE_S)
					banks.add_child(bank)
				bank.add_child(cells[cell_index])

			# The sliders sit under the knobs at exactly the knobs' width, so the block
			# stays as wide as its widest bank and the envelope stretches into whatever
			# height the block has left — tall sliders being the point of the trade.
			if not slider_cells.is_empty():
				var envelope := HBoxContainer.new()
				envelope.add_theme_constant_override("separation", Design.SPACE_S)
				envelope.size_flags_vertical = Control.SIZE_EXPAND_FILL
				var span: float = banks.get_combined_minimum_size().x
				if span > 0.0:
					envelope.custom_minimum_size.x = span
				for slide in slider_cells:
					envelope.add_child(slide)
				block.add_child(envelope)

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
	# One rack pitch, the same one the rack view uses. A flowed row gives each child the
	# width it asks for, and a caption that clips to an ellipsis asks for almost nothing —
	# without a floor the knobs would sit at whatever width their names happened to want,
	# which is a row of knobs at a dozen different spacings. It is a floor and not a size:
	# a knob that needs more at a large UI scale still gets it.
	cell.custom_minimum_size.x = Design.scale(Rack.KNOB_CELL.x)

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
