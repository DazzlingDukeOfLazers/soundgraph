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
## So this began as the pruning half. On the left, the definition's own nodes, wired as
## the author left them — the thing being wrapped, not an abstraction of it. On the right,
## the module's ports and its knobs, and underneath, an actual instance built by the same
## code that builds it everywhere else, so the preview cannot drift from the article.
##
## It declares as well as prunes, because pruning alone only ever worked on a module that
## collapse had already made. Collapse derives a surface from context — ports from the
## connections crossing the selection boundary, exports from the values an author had
## already set — and a module assembled here was never in the graph, so there is no
## boundary to read and nothing has been set. Built from nothing, it came out with no
## ports and no knobs: a box that could not be plugged in or turned.
##
## Two kinds of edit live here and the difference is worth keeping straight, because they
## look alike in the list and do not behave alike:
##
##   surface — declared ports, exported parameters. What a patch can reach. Taking one
##             away strands cables and controls, so this view removes them and says so.
##   face    — the panel: which exports get a knob, in what order, called what. Purely
##             presentation, and a knob taken off the face is still exported.
##
## See docs/modules-design.md. The face half still cannot damage a patch; the surface half
## can, which is why it is the half that reports what it took with it.

## What the knob list now says: which inner parameters the module exports, and which of
## those are on its face. Sent together because they are edited together — a knob cannot
## be on a face it is not exported to. `label` is the undo entry.
signal surface_edited(module_name: String, parameters: Array, panel: Dictionary,
	label: String)
## A cable the author just patched between two of the definition's own nodes.
signal wired(module_name: String, from_node: String, from_port: String,
	to_node: String, to_port: String)
## Something the author tried that could not be done, in words for the status line.
signal refused(reason: String)
## A new name for the definition being edited.
signal module_renamed(from_name: String, to_name: String)
## The declared surface: which inner ports the module shows the world, and as what.
signal ports_edited(module_name: String, inputs: Array, outputs: Array, label: String)

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

## One per inner parameter, exported or not, in panel order:
## {"name": String, "node": String, "parameter": String, "exported": bool, "on": bool,
## "caption": String, "breaks": bool}.
##
## `name` is the export binding — what the outside sets — and `caption` is only what the
## panel calls it. `exported` is the surface, `on` is the face. The single source this
## view edits; everything else is drawn from it.
var _entries: Array = []

## One per inner port that could be declared, in the order the inner nodes give them:
## {"node": String, "port": String, "is_input": bool, "on": bool, "name": String}.
##
## Separate from _entries because ports and knobs are separate questions. A knob is
## presentation — turning it off changes what a face shows and nothing else. A port is
## *surface*: declaring one is the only thing that lets the outside reach in, and
## undeclaring one takes a cable off the instance. The two lists look alike and are not
## alike, which is why they carry different headings and this comment.
var _ports: Array = []

var _picker: OptionButton
var _name_field: LineEdit
var _list: VBoxContainer
var _ports_box: VBoxContainer
var _ports_note: Label
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

	# Ports before knobs, because that is the order the questions arrive in: what the
	# module connects to, then what somebody turns on it. It is also the shorter list —
	# a module has two or three ports and can have a dozen knobs — so putting it first
	# costs the knobs almost nothing.
	column.add_child(_heading("Ports"))
	_ports_note = Label.new()
	_ports_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_ports_note.add_theme_font_size_override("font_size",
		Design.type(Design.SIZE_SECONDARY))
	_ports_note.add_theme_color_override("font_color", ink_dim)
	column.add_child(_ports_note)
	_ports_box = VBoxContainer.new()
	_ports_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ports_box.add_theme_constant_override("separation", Design.SPACE_XS)
	column.add_child(_ports_box)

	column.add_child(_heading("Knobs"))
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
	_seed_ports()
	_draw_list()
	_draw_ports()
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
	var panel: Dictionary = definition.get("panel", {})
	var labels: Dictionary = panel.get("labels", {})
	var rows: Array = panel.get("rows", [])

	# The already-exported ones first and verbatim, so nothing a collapse derived is lost
	# or renamed by passing through this list. Everything else follows as an offer.
	var by_export := {}
	var covered := {}
	for binding: Dictionary in surface:
		var entry := {
			"name": str(binding["name"]),
			"node": str(binding.get("node", "")),
			"parameter": str(binding.get("parameter", "")),
			"exported": true,
			"on": rows.is_empty(),
			"caption": str(labels.get(str(binding["name"]), "")),
			"breaks": false,
		}
		by_export[str(binding["name"])] = entry
		covered["%s/%s" % [entry["node"], entry["parameter"]]] = true

	# Panel order decides the order of the exported ones; anything the panel never
	# mentioned keeps its place after them, off the face but visible.
	var ordered: Array = []
	if rows.is_empty():
		var index := 0
		for binding: Dictionary in surface:
			var entry: Dictionary = by_export[str(binding["name"])]
			entry["breaks"] = index % 2 == 0
			ordered.append(entry)
			index += 1
	else:
		var placed := {}
		for row: Array in rows:
			var first := true
			for export_name in row:
				var key := str(export_name)
				if not by_export.has(key) or placed.has(key):
					continue
				placed[key] = true
				var entry: Dictionary = by_export[key]
				entry["on"] = true
				entry["breaks"] = first
				ordered.append(entry)
				first = false
		for binding: Dictionary in surface:
			if not placed.has(str(binding["name"])):
				ordered.append(by_export[str(binding["name"])])

	# And every inner parameter that is not exported yet, offered rather than assumed.
	# A module built here has none exported at all — collapse gets its exports from the
	# values an author had already set, and nothing added in this tab has been set.
	for node: Dictionary in definition.get("nodes", []):
		var type_entry: Dictionary = registry.get(str(node.get("type", "")), {})
		for parameter: Dictionary in type_entry.get("parameters", []):
			var key := "%s/%s" % [str(node["id"]), str(parameter["name"])]
			if covered.has(key):
				continue
			ordered.append({
				"name": str(parameter["name"]),
				"node": str(node["id"]),
				"parameter": str(parameter["name"]),
				"exported": false,
				"on": false,
				"caption": "",
				"breaks": false,
			})
	_entries = ordered


## Every inner port that could be a module port, and whether it already is.
##
## An input already fed by a cable inside the definition is left out: it has a source, and
## offering to give it a second one is offering to sum two things somebody has not asked
## to sum. Outputs are always listed — an inner output feeding another inner node can
## perfectly well also leave the module, which is what fan-out is.
func _seed_ports() -> void:
	_ports.clear()
	if module_name == "":
		return
	var definition: Dictionary = patch.get("modules", {}).get(module_name, {})
	var fed := {}
	for connection in definition.get("connections", []):
		fed["%s/%s" % [str(connection["to"]["node"]), str(connection["to"]["port"])]] = true

	var declared := {}
	for side in ["inputs", "outputs"]:
		for binding: Dictionary in definition.get(side, []):
			declared["%s/%s" % [str(binding["node"]), str(binding["port"])]] = \
				str(binding["name"])

	for node: Dictionary in definition.get("nodes", []):
		var type_entry: Dictionary = registry.get(str(node.get("type", "")), {})
		for side in ["inputs", "outputs"]:
			for port: Dictionary in type_entry.get(side, []):
				var key := "%s/%s" % [str(node["id"]), str(port["name"])]
				if side == "inputs" and fed.has(key) and not declared.has(key):
					continue
				_ports.append({
					"node": str(node["id"]),
					"port": str(port["name"]),
					"is_input": side == "inputs",
					"on": declared.has(key),
					"name": str(declared.get(key, port["name"])),
				})


func _draw_ports() -> void:
	for child in _ports_box.get_children():
		_ports_box.remove_child(child)
		child.queue_free()
	if module_name == "":
		_ports_note.text = ""
		return
	if _ports.is_empty():
		_ports_note.text = "Nothing inside this module has a free port yet."
		return
	_ports_note.text = "What the outside can reach. A port left undeclared is not on " \
		+ "the instance at all, so nothing can be plugged into it."
	for index in _ports.size():
		_ports_box.add_child(_build_port_row(index))


func _build_port_row(index: int) -> Control:
	var entry: Dictionary = _ports[index]
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", Design.SPACE_XS)

	var on := CheckBox.new()
	on.button_pressed = bool(entry["on"])
	on.focus_mode = Control.FOCUS_NONE
	on.tooltip_text = "Show this port on the instance"
	on.toggled.connect(func(pressed: bool) -> void:
		_ports[index]["on"] = pressed
		_commit_ports("%s %s.%s" % ["declare" if pressed else "undeclare",
			entry["node"], entry["port"]]))
	row.add_child(on)

	# Which way the signal goes, in a word. Inputs and outputs are interleaved here — a
	# module's ports are its nodes' ports, in node order — so nothing about the position
	# says which edge of the panel a jack lands on. Words rather than arrows: the design
	# suite checks that every character the editor shows is one the font can actually
	# draw, and it caught "→" the first time this was written.
	var direction := Label.new()
	direction.text = "in" if bool(entry["is_input"]) else "out"
	direction.custom_minimum_size.x = Design.scale(30)
	direction.add_theme_font_size_override("font_size",
		Design.type(Design.SIZE_SECONDARY))
	direction.add_theme_color_override("font_color", ink_dim)
	row.add_child(direction)

	var inner := Label.new()
	inner.text = "%s.%s" % [str(entry["node"]), str(entry["port"])]
	inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner.add_theme_font_size_override("font_size", Design.type(Design.SIZE_BODY))
	inner.add_theme_color_override("font_color", ink if bool(entry["on"]) else ink_dim)
	row.add_child(inner)

	# The name the outside sees. Unlike a knob's caption this *is* the binding — a cable
	# lands on it — so it is the port's name and not a label beside one.
	var named := LineEdit.new()
	named.text = str(entry["name"])
	named.placeholder_text = str(entry["port"])
	named.custom_minimum_size.x = Design.scale(110)
	named.editable = bool(entry["on"])
	named.tooltip_text = "What a cable connects to on the instance"
	named.add_theme_font_size_override("font_size", Design.type(Design.SIZE_CONTROL))
	named.text_submitted.connect(func(_text: String) -> void: named.release_focus())
	named.focus_exited.connect(func() -> void:
		var wanted := named.text.strip_edges()
		if wanted == str(_ports[index]["name"]) or wanted == "":
			named.text = str(_ports[index]["name"])
			return
		_ports[index]["name"] = wanted
		_commit_ports("rename port %s" % wanted))
	row.add_child(named)
	return row


## The declared surface this list now describes, as two arrays of bindings.
##
## Names are made unique per side the way ModuleAuthor does it — falling back to
## node_port — because two ports called the same thing is a document the loader refuses,
## and refusing to save is a worse answer than choosing a name.
func to_ports() -> Dictionary:
	var inputs: Array = []
	var outputs: Array = []
	for entry: Dictionary in _ports:
		if not bool(entry["on"]):
			continue
		var side: Array = inputs if bool(entry["is_input"]) else outputs
		var name := str(entry["name"])
		for existing in side:
			if str(existing["name"]) == name:
				name = "%s_%s" % [str(entry["node"]), str(entry["port"])]
				break
		side.append({"name": name, "node": str(entry["node"]),
			"port": str(entry["port"])})
	return {"inputs": inputs, "outputs": outputs}


func _commit_ports(label: String) -> void:
	if _building or module_name == "":
		return
	var declared := to_ports()
	ports_edited.emit(module_name, declared["inputs"], declared["outputs"], label)


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

	# Two checkboxes, because these are two questions and the second one used to have no
	# way of being asked. Exported puts the knob on the module's surface: a patch can set
	# it, a control can drive it, automation can reach it. On the face puts it on the
	# panel. Exported-but-off-the-face is a real and useful state — it is what `mode` and
	# `cutoff_sweep` are on the filter combo — so it gets its own control rather than
	# being inferred from the other.
	var exported := CheckBox.new()
	exported.button_pressed = bool(entry["exported"])
	exported.tooltip_text = "Export this knob: the module's surface, what a patch can set"
	exported.focus_mode = Control.FOCUS_NONE
	exported.toggled.connect(func(pressed: bool) -> void:
		_entries[index]["exported"] = pressed
		# Nothing can be on a face it is not exported to, and a newly exported knob
		# almost always wants to be seen — so the face follows unless it is being taken
		# away, where it has no choice.
		_entries[index]["on"] = pressed
		_commit("%s %s" % ["export" if pressed else "unexport", entry["name"]]))
	row.add_child(exported)

	var on := CheckBox.new()
	on.button_pressed = bool(entry["on"])
	on.disabled = not bool(entry["exported"])
	on.tooltip_text = "Show this knob on the panel"
	on.focus_mode = Control.FOCUS_NONE
	on.toggled.connect(func(pressed: bool) -> void:
		_entries[index]["on"] = pressed
		_commit("show %s" % entry["name"] if pressed else "hide %s" % entry["name"]))
	row.add_child(on)

	var name_label := Label.new()
	name_label.text = str(entry["name"]) if bool(entry["exported"]) \
		else "%s.%s" % [str(entry["node"]), str(entry["parameter"])]
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.add_theme_font_size_override("font_size", Design.type(Design.SIZE_BODY))
	name_label.add_theme_color_override("font_color",
		ink if bool(entry["exported"]) else ink_dim)
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

	# Words, not arrows. These were ↑ ↓ ↵ and rendered fine in a screenshot because the
	# system font quietly filled in behind — design_test asks the project's own font
	# whether it can draw each character, which is the question that matters for the web
	# export and for anybody else's machine.
	row.add_child(_step_button("up", index > 0, func() -> void: _move(index, -1)))
	row.add_child(_step_button("dn", index < _entries.size() - 1,
		func() -> void: _move(index, 1)))

	# Where a row ends. The first knob on the panel always starts one, so its toggle is
	# fixed on rather than hidden — a control that vanishes is harder to understand than
	# one that is plainly not yours to press.
	var breaks := Button.new()
	breaks.text = "row"
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
## The declared parameters this list now says the module exports.
##
## Names are made unique the way ModuleAuthor does it, falling back to node_parameter,
## because two exports called the same thing is a document the loader refuses — and two
## inner nodes with a knob called `gain` is the ordinary case, not an odd one.
func to_exports() -> Array:
	var exported: Array = []
	for entry: Dictionary in _entries:
		if not bool(entry["exported"]):
			continue
		var name := str(entry["name"])
		for existing in exported:
			if str(existing["name"]) == name:
				name = "%s_%s" % [str(entry["node"]), str(entry["parameter"])]
				break
		entry["name"] = name
		exported.append({"name": name, "node": str(entry["node"]),
			"parameter": str(entry["parameter"])})
	return exported


func to_panel() -> Dictionary:
	var rows: Array = []
	var labels := {}
	var current: Array = []
	for entry: Dictionary in _entries:
		if not bool(entry["on"]) or not bool(entry["exported"]):
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
	# Exports first: to_panel only emits rows for knobs that are exported, and to_exports
	# is what settles their names when two of them collide.
	var exported := to_exports()
	surface_edited.emit(module_name, exported, to_panel(), label)
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
