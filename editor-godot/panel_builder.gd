class_name PanelBuilder
extends HSplitContainer
## Where a composite gets a face: the primitives on the left, the panel they wear on the
## right.
##
## Collapsing an ADSR and an Amp into one module already works — that is stage 3, and it
## derives the surface rather than asking anybody to declare it. What it cannot do is make
## the result *compact*, which is the reason for collapsing anything. The derived surface
## exports every knob the inner nodes had, in the order they were found, under names like
## `amp_gain`, and a module built to be smaller than its parts arrives bigger.
##
## So this is the pruning half. On the left, the definition's own nodes, wired as the
## author left them — the thing being wrapped, not an abstraction of it. On the right, one
## line per export: on the panel or not, what it is called there, where it sits, and where
## a row breaks. Underneath, an actual instance of the module being edited, built by the
## same code that builds it everywhere else, so the preview cannot drift from the article.
##
## Nothing here touches the surface. Turning a knob off takes it off the face and leaves it
## exported, settable and automatable — see docs/modules-design.md. The worst this view can
## do to a patch is make it look different.

## The panel as it now stands, ready to store on the definition. `label` is the undo entry.
signal panel_edited(module_name: String, panel: Dictionary, label: String)
## A cable the author just patched between two of the definition's own nodes.
signal wired(module_name: String, from_node: String, from_port: String,
	to_node: String, to_port: String)
## Something the author tried that could not be done, in words for the status line.
signal refused(reason: String)
## A new name for the definition being edited.
signal module_renamed(from_name: String, to_name: String)

const LIST_WIDTH := 520.0

## Room for a face, at whatever size the face has to be shrunk to.
##
## It was 420 and fixed, on the reasoning that a preview clipped through its own bottom
## row of knobs answers a different question from the one it exists to answer. True, and
## it made the wrong trade: a four-knob row is wider than this column, so the module ran
## off the right edge, and a full-height preview left the *list* — the thing actually
## being edited — showing four of five rows with the fifth below the fold. The knob whose
## caption had been customised was the one you could not see.
##
## So the preview zooms to fit instead of reserving its natural size, and the list gets
## the rest. A face read at 60% still says what is on it and in what order, which is what
## somebody arranging one needs to know.
const PREVIEW_HEIGHT := 300.0

var patch: Dictionary = {}
var registry: Dictionary = {}
var type_colours: Dictionary = {}
var ink := Color.WHITE
var ink_dim := Color.GRAY

## Which definition is being given a face. Empty when the document has no modules.
var module_name := ""

## One per export, in panel order: {"name": String, "on": bool, "caption": String,
## "breaks": bool}. The single source this view edits; everything else is drawn from it.
var _entries: Array = []

var _picker: OptionButton
var _name_field: LineEdit
var _list: VBoxContainer
var _note: Label
var _inner: GraphRack
var _inner_holder: Control
var _preview: GraphRack
var _preview_holder: Control
var _building := false


func _ready() -> void:
	split_offset = int(-LIST_WIDTH)
	add_child(_build_left())
	add_child(_build_right())


## The primitives, connected. A rack rather than a picture of one: these are the module's
## own nodes, and reading them is the same job as reading any other rack.
func _build_left() -> Control:
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", Design.SPACE_S)
	column.add_child(_heading("Inside"))

	var scroller := ScrollContainer.new()
	scroller.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroller.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_inner = GraphRack.new()
	_inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_inner.type_colours = type_colours
	_inner.ink = ink
	_inner.ink_dim = ink_dim
	# Patching, inside the module. This is the half that makes the tab able to build a
	# combo from nothing: add two primitives, run a cable between them, and the module's
	# declared surface follows — a definition's ports are derived from its wiring.
	_inner.connection_made.connect(func(from_node: String, from_port: String,
			to_node: String, to_port: String) -> void:
		if module_name == "":
			return
		wired.emit(module_name, from_node, from_port, to_node, to_port))
	_inner.patch_refused.connect(func(reason: String) -> void: refused.emit(reason))
	# A plain Control between scroller and rack, for the same reason the main case has
	# one: a container resets its children's transform on every layout pass.
	_inner_holder = Control.new()
	_inner_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_inner_holder.add_child(_inner)
	scroller.add_child(_inner_holder)
	column.add_child(scroller)
	return _pad(column)


func _build_right() -> Control:
	var column := VBoxContainer.new()
	column.custom_minimum_size.x = Design.scale(LIST_WIDTH)
	column.size_flags_horizontal = Control.SIZE_FILL
	column.add_theme_constant_override("separation", Design.SPACE_S)

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", Design.SPACE_S)
	top.add_child(_heading("Panel"))
	_picker = OptionButton.new()
	_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_picker.add_theme_font_override("font", Design.font(Design.WEIGHT_MEDIUM))
	_picker.add_theme_font_size_override("font_size", Design.type(Design.SIZE_CONTROL))
	_picker.item_selected.connect(func(index: int) -> void:
		module_name = _picker.get_item_text(index)
		rebuild())
	top.add_child(_picker)
	column.add_child(top)

	# The name, editable, because until now there was none anywhere in the editor and
	# collapse calls every fresh definition "part". The face never showed it — a panel
	# takes its title from the module's display name — but the running order, the outline
	# and every diagnostic say it, and "part.filter" tells a reader nothing about which
	# part. Kept beneath the picker rather than replacing it: one control chooses which
	# module, the other says what it is called, and a single control doing both is how you
	# rename something by trying to select it.
	var naming := HBoxContainer.new()
	naming.add_theme_constant_override("separation", Design.SPACE_S)
	var naming_label := Label.new()
	naming_label.text = "Name"
	naming_label.add_theme_font_size_override("font_size", Design.type(Design.SIZE_BODY))
	naming_label.add_theme_color_override("font_color", ink_dim)
	naming.add_child(naming_label)
	_name_field = LineEdit.new()
	_name_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_field.tooltip_text = "Renames the definition, and any instance still carrying" \
		+ " its old name. Letters, digits, _ and - only."
	_name_field.add_theme_font_size_override("font_size", Design.type(Design.SIZE_CONTROL))
	_name_field.text_submitted.connect(func(_text: String) -> void:
		_name_field.release_focus())
	_name_field.focus_exited.connect(_submit_name)
	naming.add_child(_name_field)
	column.add_child(naming)

	_note = Label.new()
	_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_note.add_theme_font_size_override("font_size", Design.type(Design.SIZE_SECONDARY))
	_note.add_theme_color_override("font_color", ink_dim)
	column.add_child(_note)

	var scroller := ScrollContainer.new()
	scroller.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroller.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", Design.SPACE_XS)
	scroller.add_child(_list)
	column.add_child(scroller)

	column.add_child(_heading("Face"))
	# The preview is a real instance in a real rack. A hand-drawn approximation would be
	# one more thing that can disagree with the module, and disagreeing quietly is exactly
	# what a preview must never do.
	var preview_scroll := ScrollContainer.new()
	preview_scroll.custom_minimum_size.y = Design.scale(PREVIEW_HEIGHT)
	preview_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_preview = GraphRack.new()
	_preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preview.type_colours = type_colours
	_preview.ink = ink
	_preview.ink_dim = ink_dim
	_preview_holder = Control.new()
	_preview_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_preview_holder.add_child(_preview)
	preview_scroll.add_child(_preview_holder)
	column.add_child(preview_scroll)
	return _pad(column)


## Room around a half. Both panes butt against the tab edge otherwise, and the left one
## against the split as well.
func _pad(inner: Control) -> Control:
	var margin := MarginContainer.new()
	margin.size_flags_horizontal = inner.size_flags_horizontal
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, Design.SPACE_M)
	margin.add_child(inner)
	return margin


## Asks for a rename, if the field says something new. The document decides whether it is
## allowed — this view has no business knowing what makes a name legal, and duplicating
## that rule here is how the two answers drift apart.
func _submit_name() -> void:
	if _building or module_name == "":
		return
	var wanted := _name_field.text.strip_edges()
	if wanted == module_name or wanted == "":
		_name_field.text = module_name
		return
	module_renamed.emit(module_name, wanted)


func _heading(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_override("font", Design.font(Design.WEIGHT_SEMIBOLD))
	label.add_theme_font_size_override("font_size", Design.type(Design.SIZE_HEADING))
	label.add_theme_color_override("font_color", ink)
	return label


## Repopulates from the document: the module list, the chosen definition's exports, both
## racks. Called when the document changes or the author picks a different module — not
## after an edit this view made, which would take the caption field out from under a
## cursor that is still typing in it.
func rebuild() -> void:
	if _picker == null:
		return
	_building = true
	var names: Array = patch.get("modules", {}).keys()
	names.sort()
	_picker.clear()
	for name in names:
		_picker.add_item(str(name))
	if not names.has(module_name):
		module_name = str(names[0]) if not names.is_empty() else ""
	if module_name != "":
		_picker.select(names.find(module_name))
	_name_field.text = module_name
	_name_field.editable = module_name != ""
	_building = false

	_seed_entries()
	_draw_list()
	_rebuild_racks()


## The editable model, from the definition's panel when it has one and from its declared
## surface when it does not.
##
## The seeded default is deliberately the face the module already wears: every export on,
## broken two to a row, which is what a module with no panel is drawn as. Opening this
## view and saving without touching anything must not move a single knob — otherwise the
## first thing the builder does to a patch is change it.
func _seed_entries() -> void:
	_entries.clear()
	if module_name == "":
		return
	var definition: Dictionary = patch.get("modules", {}).get(module_name, {})
	var surface: Array = definition.get("parameters", [])
	var declared := {}
	for binding: Dictionary in surface:
		declared[str(binding["name"])] = true

	var panel: Dictionary = definition.get("panel", {})
	var labels: Dictionary = panel.get("labels", {})
	var rows: Array = panel.get("rows", [])
	if rows.is_empty():
		var index := 0
		for binding: Dictionary in surface:
			_entries.append({"name": str(binding["name"]), "on": true,
				"caption": "", "breaks": index % 2 == 0})
			index += 1
		return

	# Panel order first, then whatever the panel never mentioned — off, but present, so
	# an export added to the definition after the panel was written is visible here
	# rather than silently missing.
	var placed := {}
	for row: Array in rows:
		var first := true
		for export_name in row:
			var key := str(export_name)
			if not declared.has(key) or placed.has(key):
				continue
			placed[key] = true
			_entries.append({"name": key, "on": true,
				"caption": str(labels.get(key, "")), "breaks": first})
			first = false
	for binding: Dictionary in surface:
		var key := str(binding["name"])
		if placed.has(key):
			continue
		_entries.append({"name": key, "on": false,
			"caption": str(labels.get(key, "")), "breaks": false})


func _draw_list() -> void:
	for child in _list.get_children():
		_list.remove_child(child)
		child.queue_free()
	if module_name == "":
		_note.text = "No modules yet. Add a node and this tab starts one for you — or " \
			+ "select two or more nodes in the graph and collapse them into one."
		return
	if _entries.is_empty():
		_note.text = "'%s' exports nothing to put on a panel — its inner nodes were " \
			% module_name + "left at their defaults, so there is no knob to show."
		return
	_note.text = "On the face, in order. A knob turned off here is still exported: " \
		+ "controls, automation and the file all keep it."

	for index in _entries.size():
		_list.add_child(_build_entry_row(index))


func _build_entry_row(index: int) -> Control:
	var entry: Dictionary = _entries[index]
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", Design.SPACE_XS)

	var on := CheckBox.new()
	on.button_pressed = bool(entry["on"])
	on.tooltip_text = "Show this knob on the panel"
	on.focus_mode = Control.FOCUS_NONE
	on.toggled.connect(func(pressed: bool) -> void:
		_entries[index]["on"] = pressed
		_commit("show %s" % entry["name"] if pressed else "hide %s" % entry["name"]))
	row.add_child(on)

	var name_label := Label.new()
	name_label.text = str(entry["name"])
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.add_theme_font_size_override("font_size", Design.type(Design.SIZE_BODY))
	name_label.add_theme_color_override("font_color",
		ink if bool(entry["on"]) else ink_dim)
	row.add_child(name_label)

	# The caption, not a rename: what the panel calls it. Empty means the export name,
	# which is why the placeholder shows what you would get by leaving it alone.
	var caption := LineEdit.new()
	caption.text = str(entry["caption"])
	caption.placeholder_text = str(entry["name"])
	caption.custom_minimum_size.x = Design.scale(110)
	caption.tooltip_text = "What the panel calls it. Blank uses the exported name."
	caption.add_theme_font_size_override("font_size", Design.type(Design.SIZE_CONTROL))
	caption.text_submitted.connect(func(_text: String) -> void:
		caption.release_focus())
	caption.focus_exited.connect(func() -> void:
		if caption.text == str(_entries[index]["caption"]):
			return
		_entries[index]["caption"] = caption.text
		_commit("rename %s" % entry["name"]))
	row.add_child(caption)

	row.add_child(_step_button("↑", index > 0, func() -> void: _move(index, -1)))
	row.add_child(_step_button("↓", index < _entries.size() - 1,
		func() -> void: _move(index, 1)))

	# Where a row ends. The first knob on the panel always starts one, so its toggle is
	# fixed on rather than hidden — a control that vanishes is harder to understand than
	# one that is plainly not yours to press.
	var breaks := Button.new()
	breaks.text = "↵"
	breaks.toggle_mode = true
	breaks.button_pressed = bool(entry["breaks"])
	breaks.disabled = index == _first_on()
	breaks.focus_mode = Control.FOCUS_NONE
	breaks.tooltip_text = "Start a new row of knobs here"
	breaks.custom_minimum_size.x = Design.scale(34)
	breaks.toggled.connect(func(pressed: bool) -> void:
		_entries[index]["breaks"] = pressed
		_commit("row break"))
	row.add_child(breaks)
	return row


func _step_button(text: String, enabled: bool, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.disabled = not enabled
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size.x = Design.scale(34)
	button.pressed.connect(action)
	return button


## The first entry that is on the panel, or -1. It carries the implicit row break.
func _first_on() -> int:
	for index in _entries.size():
		if bool(_entries[index]["on"]):
			return index
	return -1


func _move(index: int, by: int) -> void:
	var to := index + by
	if to < 0 or to >= _entries.size():
		return
	var moved: Dictionary = _entries[index]
	_entries.remove_at(index)
	_entries.insert(to, moved)
	_commit("move %s" % moved["name"])


## The panel this list now describes.
##
## Rows are cut at the breaks, so the model stays one flat ordered list and the row
## structure is derived — which is what makes moving a knob a single operation rather than
## a remove from one row and an insert into another.
func to_panel() -> Dictionary:
	var rows: Array = []
	var labels := {}
	var current: Array = []
	for entry: Dictionary in _entries:
		if not bool(entry["on"]):
			continue
		if bool(entry["breaks"]) and not current.is_empty():
			rows.append(current)
			current = []
		current.append(str(entry["name"]))
		if str(entry["caption"]) != "":
			labels[str(entry["name"])] = str(entry["caption"])
	if not current.is_empty():
		rows.append(current)
	var panel := {}
	if not rows.is_empty():
		panel["rows"] = rows
	if not labels.is_empty():
		panel["labels"] = labels
	return panel


func _commit(label: String) -> void:
	if _building or module_name == "":
		return
	panel_edited.emit(module_name, to_panel(), label)
	_draw_list()


## Both racks, after the document has been rebuilt around a new panel. The list is left
## alone: it is what the author is currently editing.
func refresh() -> void:
	_rebuild_racks()


func _rebuild_racks() -> void:
	if _inner == null or module_name == "":
		return
	var definition: Dictionary = patch.get("modules", {}).get(module_name, {})
	# The definition's own nodes, laid out as an ordinary patch. Positions are not stored
	# on a definition, so the rack seeds them the way it seeds any patch it has not seen.
	_inner.registry = registry
	_inner.patch = {
		"nodes": definition.get("nodes", []).duplicate(true),
		"connections": definition.get("connections", []).duplicate(true),
	}
	_inner.rebuild()

	_preview.registry = registry
	_preview.patch = {
		"modules": {module_name: definition},
		"nodes": [{"id": module_name, "type": "module", "module": module_name,
			"position": {"x": 0.0, "y": 0.0}}],
		"connections": [],
	}
	_preview.rebuild()

	# Laid out again a frame later, and this is not belt-and-braces. A rack sizes itself
	# against the viewport it is inside, and on the frame a tab is first shown it has not
	# been given one — so the first pass lands against the minimum-width floor and every
	# module is drawn clipped. The structural tests could not see this; the screenshot
	# could. One frame is enough for the width to be real.
	await get_tree().process_frame
	if _inner == null or not is_instance_valid(_inner):
		return
	_inner._relayout()
	_preview._relayout()
	_inner_holder.custom_minimum_size = _inner.size
	# The face, whole, at whatever size whole requires. A module with four knobs on a row
	# is wider than this column and being shown three of them is worse than being shown
	# all four small.
	_preview.zoom_to_fit()
	await get_tree().process_frame
	if not is_instance_valid(_preview):
		return
	_preview_holder.custom_minimum_size = _preview.size * _preview.zoom
