extends VBoxContainer
## The face of one module, and the surface for editing it.
##
## A module's panel is the same kind of thing as the file's — a selection out of everything
## the graph could expose, in an order somebody chose, with names they chose — so it is
## drawn beside the file's own, in the same column, and only one of them at a time. Which
## one you get is which one you are looking at: select a module instance on the canvas and
## this is its face; select anything else and the file's face comes back.
##
## The gestures are the ones the Graphrack tab had, rebuilt here. Drag a knob to move it
## within the face; drag it off the panel to take it off; drag a ghost on to put it there.
## No mode to arm first: this panel is a builder, and a builder that has to be switched on
## is a builder somebody has to be told about.
## What changed in the rebuild is where the rows come from. GraphRack inferred them from
## where the knobs had ended up on screen — sorting by y with a tolerance taken off the knob
## height — because its face was a GridContainer that wrapped on its own and nobody had
## written the rows down. Here the rows *are* the input: they come from the descriptor,
## which comes from `panel.rows`, so the arrangement on screen and the arrangement in the
## file are the same array and cannot drift. The geometry now only has to answer where a
## drop landed, which is a question about the pointer rather than about the layout.
##
## Values go through the rack's own signals, the way patch_face.gd's do, so two panels
## showing one parameter cannot disagree about what it is set to.

const Rack := preload("res://rack.gd")

## How many knobs to a line when a module has never been arranged. The same wrap the module
## node on the canvas uses, so the first drag starts from what was already on screen.
const PER_LINE := 2

## How far down a ghost is turned: enough to read as an offer rather than as a control.
const OFFERED := Color(1.0, 1.0, 1.0, 0.45)

var patch: Dictionary = {}
var registry: Dictionary = {}
var rack: Control = null

## The instance whose module is being shown, or "" for none.
var node_id := ""

## The face, after a drag. `rows` is the whole arrangement; `added` is set only when what
## was dragged on was a ghost, and carries the inner binding that has to be exported first.
signal rearranged(rows: Array, added: Dictionary)

## A knob was dragged off the panel entirely.
signal removed(export_name: String)

## Somebody tried to arrange a face that is not a module's.
signal refused(reason: String)

## [{control, key, ghost, offer, row, index}] in the order they are drawn, real cells first.
var _cells: Array = []
## The rows as drawn, of export names — what a drag is rearranging.
var _rows: Array = []
var _carrying := -1
var _target: Dictionary = {}


# ---------------------------------------------------------------------------------
# The arithmetic
#
# Static and total: given any rows and any target it returns rows, so the suite can check
# the off-by-ones — moving a knob rightward past itself, a row the move emptied, a fresh
# line at either end — without a mouse or a panel. Lifted unchanged from GraphRack, where
# it was the one part of that view worth keeping.
# ---------------------------------------------------------------------------------

static func moved(rows: Array, name: String, target: Dictionary) -> Array:
	var out: Array = []
	for row: Array in rows:
		out.append(row.duplicate())
	if bool(target.get("remove", false)):
		var kept: Array = []
		for row: Array in out:
			row.erase(name)
			if not row.is_empty():
				kept.append(row)
		return kept
	var row_index := int(target.get("row", 0))
	var index := int(target.get("index", 0))
	if bool(target.get("fresh", false)):
		row_index = clampi(row_index, 0, out.size())
		out.insert(row_index, [])
		index = 0

	# Taken out before it is put back, and the target pulled left when it was sitting
	# ahead of the gap on the same line. Without that, dragging a knob one place to the
	# right lands it exactly where it started and the move looks broken.
	for i in out.size():
		var at: int = (out[i] as Array).find(name)
		if at < 0:
			continue
		(out[i] as Array).remove_at(at)
		if i == row_index and at < index:
			index -= 1
		break

	if row_index < 0 or row_index >= out.size():
		out.append([name])
	else:
		var row: Array = out[row_index]
		row.insert(clampi(index, 0, row.size()), name)

	# A row the move emptied goes. A face does not keep a blank line to show where
	# something used to be.
	var tidied: Array = []
	for row: Array in out:
		if not row.is_empty():
			tidied.append(row)
	return tidied


## The key a ghost is filed under. An export the panel left off keeps its export name,
## since that name is already the document's; an inner knob nobody has exported is filed by
## where it comes from, because two inner nodes may both have a "gain" and the export name
## is not settled until the document settles it.
static func offer_key(parameter: Dictionary) -> String:
	var offer: Dictionary = parameter.get("offer", {})
	if offer.is_empty():
		return str(parameter["name"])
	return "+%s/%s" % [str(offer["node"]), str(offer["parameter"])]


# ---------------------------------------------------------------------------------
# The gesture
# ---------------------------------------------------------------------------------

## First refusal on the press, ahead of the GUI pass — the only reason a knob can be picked
## up at all, since a knob is a Control and would otherwise eat it. Same trick as
## PatchFace._input and PatchGraph._input, for the same reason.
func _input(event: InputEvent) -> void:
	if not is_visible_in_tree() or _cells.is_empty():
		return
	var button := event as InputEventMouseButton
	if button != null and button.button_index == MOUSE_BUTTON_LEFT:
		if button.pressed:
			_carrying = _cell_at(button.global_position)
			_target = {}
			if _carrying >= 0:
				get_viewport().set_input_as_handled()
		elif _carrying >= 0:
			var from := _carrying
			var to := _target
			_carrying = -1
			_target = {}
			queue_redraw()
			get_viewport().set_input_as_handled()
			_finish(from, to)
		return
	var motion := event as InputEventMouseMotion
	if motion != null and _carrying >= 0:
		_target = drop_at(motion.global_position)
		queue_redraw()
		get_viewport().set_input_as_handled()


## Turns a finished drag into the edit it means. Kept apart from _input so the suite can
## drive it with a point instead of three synthetic events.
func _finish(from: int, target: Dictionary) -> void:
	if from < 0 or from >= _cells.size() or target.is_empty():
		return
	var cell: Dictionary = _cells[from]
	var key := str(cell["key"])
	var ghost: bool = bool(cell["ghost"])

	if bool(target.get("remove", false)):
		# Dropping a ghost off the panel is not an edit: it was never on it.
		if ghost:
			return
		emit_signal("removed", key)
		return

	var next := moved(_rows, key, target)
	# Ghosts are not in `_rows` — they are what the face does not show — so moving one is
	# an insertion rather than a move, and `moved` did it above by falling through to the
	# "not found anywhere" case.
	if next == _rows and not ghost:
		return
	emit_signal("rearranged", next, {"node": str(cell.get("offer", {}).get("node", "")),
		"parameter": str(cell.get("offer", {}).get("parameter", "")),
		"key": key} if ghost else {})


func _cell_at(point: Vector2) -> int:
	for index in _cells.size():
		if (_cells[index]["control"] as Control).get_global_rect().has_point(point):
			return index
	return -1


## Where a drop at this point lands.
##
## Off the panel: `{remove: true}`. Inside a row's middle half: into that row, at the gap
## the pointer is past. Inside its top or bottom quarter: a new line above or below. The
## quarters are the only way to say "on its own line" with a gesture that has no second
## button, and they are quarters rather than halves because moving *within* a row is the
## common case and should have the larger target.
func drop_at(point: Vector2) -> Dictionary:
	if not get_global_rect().has_point(point):
		return {"remove": true}
	var lines := _line_rects()
	if lines.is_empty():
		return {"row": 0, "index": 0}
	for i in lines.size():
		var rect: Rect2 = lines[i]
		if point.y < rect.position.y:
			return {"row": i, "fresh": true}
		if point.y > rect.position.y + rect.size.y:
			continue
		var quarter: float = rect.size.y * 0.25
		if point.y < rect.position.y + quarter:
			return {"row": i, "fresh": true}
		if point.y > rect.position.y + rect.size.y - quarter:
			return {"row": i + 1, "fresh": true}
		return {"row": i, "index": _gap_in_row(i, point)}
	# Past the last row: its own line at the end, whatever number that turns out to be.
	return {"row": lines.size(), "fresh": true}


## The gap within one row, counted in cells: how many of its knobs the pointer is past the
## middle of. A gap rather than a cell, because dropping *onto* one has to mean either
## before or after it and there is no way to say which.
func _gap_in_row(row: int, point: Vector2) -> int:
	var gap := 0
	for cell: Dictionary in _cells:
		if bool(cell["ghost"]) or int(cell["row"]) != row:
			continue
		var rect: Rect2 = (cell["control"] as Control).get_global_rect()
		if point.x > rect.position.x + rect.size.x * 0.5:
			gap += 1
	return gap


## The rectangle each drawn row occupies, in viewport space. Ghosts are not a row of the
## face, so they are not one here either.
func _line_rects() -> Array:
	var rects: Array = []
	for row in _rows.size():
		var box := Rect2()
		var found := false
		for cell: Dictionary in _cells:
			if bool(cell["ghost"]) or int(cell["row"]) != row:
				continue
			var rect: Rect2 = (cell["control"] as Control).get_global_rect()
			box = rect if not found else box.merge(rect)
			found = true
		if found:
			rects.append(box)
	return rects


func _draw() -> void:
	if _cells.is_empty():
		return
	var inverse := get_global_transform().affine_inverse()
	for index in _cells.size():
		var rect: Rect2 = (_cells[index]["control"] as Control).get_global_rect()
		var local := Rect2(inverse * rect.position, rect.size)
		if index == _carrying:
			draw_rect(local, Design.ACCENT, false, 2.0)
		else:
			Design.dashed_rect(self, local, Color(Design.INK_BRIGHT, 0.7))
	if _carrying < 0 or _target.is_empty():
		return
	var lines := _line_rects()
	if bool(_target.get("remove", false)) or lines.is_empty():
		return
	if bool(_target.get("fresh", false)):
		# A bar across the width, where the new line would open. What is in doubt during
		# this part of the drag is which *line*, so the mark is a line.
		var at_row: int = clampi(int(_target["row"]), 0, lines.size())
		var edge: Rect2 = lines[mini(at_row, lines.size() - 1)]
		var y: float = edge.position.y if at_row < lines.size() \
			else edge.position.y + edge.size.y
		var start := inverse * Vector2(edge.position.x, y)
		draw_rect(Rect2(start - Vector2(0.0, 1.5), Vector2(edge.size.x, 3.0)), Design.ACCENT)
		return
	# Otherwise a caret in the gap, the way the file's own panel draws one.
	var row_index: int = clampi(int(_target.get("row", 0)), 0, lines.size() - 1)
	var in_row: Array = []
	for cell: Dictionary in _cells:
		if not bool(cell["ghost"]) and int(cell["row"]) == row_index:
			in_row.append((cell["control"] as Control).get_global_rect())
	if in_row.is_empty():
		return
	var gap: int = clampi(int(_target.get("index", 0)), 0, in_row.size())
	var after := gap >= in_row.size()
	var box: Rect2 = in_row[mini(gap, in_row.size() - 1)]
	var spot := inverse * (box.position + (Vector2(box.size.x, 0.0) if after else Vector2.ZERO))
	draw_rect(Rect2(spot - Vector2(1.5, 0.0), Vector2(3.0, box.size.y)), Design.ACCENT)


# ---------------------------------------------------------------------------------
# Drawing the face
# ---------------------------------------------------------------------------------

func _ready() -> void:
	add_theme_constant_override("separation", Design.SPACE_S)


## The module this instance is of, or "" when the selection is not a module.
func module_name() -> String:
	for node in patch.get("nodes", []):
		if str(node["id"]) == node_id:
			return str(node.get("module", ""))
	return ""


## The descriptor the face is drawn from: the synthesized `module:<name>` entry, which
## already carries the resolved rows, the surface and the wand's offers.
func _descriptor() -> Dictionary:
	var name := module_name()
	return registry.get("module:%s" % name, {}) if name != "" else {}


## The face as rows of export names, from the panel when there is one and from the surface
## wrapped PER_LINE when there is not. A module that has never been arranged is therefore
## rearranged from what is already on screen, and the first drag writes down what was
## already true plus the one thing that changed.
func face_rows() -> Array:
	var descriptor := _descriptor()
	var rows: Array = []
	var panel_rows: Array = descriptor.get("panel_rows", [])
	if not panel_rows.is_empty():
		for row: Array in panel_rows:
			rows.append(row.map(func(p): return str(p["name"])))
		return rows
	var line: Array = []
	for parameter: Dictionary in descriptor.get("parameters", []):
		line.append(str(parameter["name"]))
		if line.size() == PER_LINE:
			rows.append(line)
			line = []
	if not line.is_empty():
		rows.append(line)
	return rows


func rebuild() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_cells.clear()
	_rows.clear()

	var name := module_name()
	if name == "":
		return
	var descriptor := _descriptor()
	_rows = face_rows()

	var by_name := {}
	for parameter: Dictionary in descriptor.get("parameters", []):
		by_name[str(parameter["name"])] = parameter
	var shown := {}
	var panel_rows: Array = descriptor.get("panel_rows", [])
	var captions := {}
	for row: Array in panel_rows:
		for parameter: Dictionary in row:
			captions[str(parameter["name"])] = str(parameter.get("display_name", ""))

	for row_index in _rows.size():
		var line := HBoxContainer.new()
		line.add_theme_constant_override("separation", Design.SPACE_M)
		line.alignment = BoxContainer.ALIGNMENT_CENTER
		add_child(line)
		for export_name in _rows[row_index]:
			var key := str(export_name)
			if not by_name.has(key):
				continue
			shown[key] = true
			var cell := _cell(by_name[key], str(captions.get(key, "")))
			line.add_child(cell)
			_cells.append({"control": cell, "key": key, "ghost": false,
				"offer": {}, "row": row_index})

	if _rows.is_empty():
		var hint := Label.new()
		hint.text = "%s exports nothing yet. Raise the wand and drag a knob onto its face." % name
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		hint.add_theme_font_size_override("font_size", Design.type(Design.SIZE_SECONDARY))
		hint.add_theme_color_override("font_color", Design.INK_SECOND)
		add_child(hint)

	# Everything this face could show and does not: exports the panel left off, and every
	# inner knob nobody exported. Under the face rather than in it, because they are not on
	# it — putting one on is a drag from here to there, which is the whole gesture.
	var offers: Array = []
	for parameter: Dictionary in descriptor.get("parameters", []):
		if not shown.has(str(parameter["name"])):
			offers.append(parameter)
	offers.append_array(descriptor.get("offers", []))
	if offers.is_empty():
		return

	var caption := Label.new()
	caption.text = "Not on the face"
	caption.add_theme_font_size_override("font_size", Design.type(Design.SIZE_SECONDARY))
	caption.add_theme_color_override("font_color", Design.INK_SECOND)
	add_child(caption)

	var ghost_line: HBoxContainer = null
	for parameter: Dictionary in offers:
		if ghost_line == null or ghost_line.get_child_count() >= PER_LINE:
			ghost_line = HBoxContainer.new()
			ghost_line.add_theme_constant_override("separation", Design.SPACE_M)
			ghost_line.alignment = BoxContainer.ALIGNMENT_CENTER
			add_child(ghost_line)
		var ghost := _cell(parameter, "")
		ghost.modulate = OFFERED
		ghost_line.add_child(ghost)
		_cells.append({"control": ghost, "key": offer_key(parameter), "ghost": true,
			"offer": parameter.get("offer", {}), "row": -1})


## One knob and its name — the same cell the file's own panel draws, so a knob looks like a
## knob on either of them.
func _cell(parameter: Dictionary, caption_text: String) -> Control:
	var cell := VBoxContainer.new()
	cell.add_theme_constant_override("separation", 0)
	cell.alignment = BoxContainer.ALIGNMENT_CENTER

	var knob := Rack.Knob.new()
	knob.rack = rack
	knob.compact = true
	knob.node_id = node_id
	knob.descriptor = parameter
	knob.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	knob.set_value_silently(_value_of(str(parameter["name"]),
		float(parameter.get("default", 0.0))))
	cell.add_child(knob)

	var label := Label.new()
	label.text = caption_text if caption_text != "" else str(parameter["name"])
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.clip_text = true
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.add_theme_font_override("font", Design.font(Design.WEIGHT_MEDIUM))
	label.add_theme_font_size_override("font_size", Design.type(Design.SIZE_BODY))
	label.add_theme_color_override("font_color", Design.INK_NORMAL)
	# What an offer would be reaching into, so a ghost says where it comes from rather than
	# only what it is called. Two inner nodes may both have a "gain".
	var offer: Dictionary = parameter.get("offer", {})
	label.tooltip_text = "%s.%s" % [str(offer.get("node", "")),
		str(offer.get("parameter", ""))] if not offer.is_empty() else str(parameter["name"])
	cell.add_child(label)
	return cell


func _value_of(parameter: String, fallback: float) -> float:
	for node in patch.get("nodes", []):
		if str(node["id"]) == node_id:
			return float(node.get("parameters", {}).get(parameter, fallback))
	return fallback
