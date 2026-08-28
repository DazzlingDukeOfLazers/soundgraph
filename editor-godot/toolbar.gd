class_name EditorToolbar
extends MarginContainer
const ModuleThemes := preload("res://module_themes.gd")
## The editor's top row, extracted whole from main.gd once its rework settled.
##
## It owns what a top row is: the identity block and its QR, the one verb, undo and
## redo, the message gap, the transport dot, the hamburger, and the responsive ladder
## that decides what a narrow window costs. It does not own what any of it *does* —
## every action leaves through a signal, and main wires them to the handlers it always
## had. The split line is the same one the architecture draws everywhere else: this
## file knows how the bar looks and folds, main knows what the program means.
##
## The popups (view, arrange, the menu itself) stay reachable as members because main
## legitimately updates their check states as the document changes; that is state
## display, not action handling, and mirroring it through signals would be ceremony.

signal add_node_requested
signal undo_requested
signal redo_requested
signal example_chosen(label: String)
signal file_action(id: int)
signal view_action(id: int)
signal arrange_action(id: int)
signal make_module_requested
## Somebody wants to tell the workbench something. Main owns the dialog.
signal feedback_requested
signal mute_toggled

enum Rung {
	FULL,       ## everything
	EDIT,       ## undo and redo go; Ctrl+Z and Ctrl+Y do not
	IDENTITY,   ## the product name goes; the document name stays
	VERB,       ## Add node keeps only its +; the hamburger survives every rung
}
const RUNG_COUNT := 4

## The case menu's labels and their widths in HP, kept together because a menu whose
## indexes drift from its meanings is the oldest bug menus have.
const CASE_LABELS := ["Case: fit window", "Case: 84 HP", "Case: 104 HP", "Case: 168 HP"]
const CASE_WIDTHS := [0, 84, 104, 168]

const PatchGraph := preload("res://patch_graph.gd")

## Large example groups become submenus so the curated top level survives the banks.
const EXAMPLE_SUBMENU_THRESHOLD := 16

var toolbar_identity: VBoxContainer
var toolbar_title: Label
var toolbar_edit_group: HBoxContainer
var toolbar_menu_button: MenuButton
var toolbar_identity_margin: MarginContainer
var toolbar_menu_popup: PopupMenu
var toolbar_qr: TextureRect
var toolbar_add_button: Button
var toolbar_rung := Rung.FULL
var undo_button: Button
var redo_button: Button
var message_label: Label
var transport_dot: TextureRect
var view_popup: PopupMenu
var arrange_popup: PopupMenu
var _primary_buttons: Array[Button] = []

## Injected: the examples menu's contents, the tooltip-and-menu build description, and
## where the truth about mute lives (main owns the one mute state; this bar only asks).
var examples: Dictionary = {}
var description := ""
var is_muted: Callable = func() -> bool: return false

## Which VSeparator introduces which group, so hiding a group takes its rule with it.
var _toolbar_rules: Dictionary = {}
var _fitting_toolbar := false


func _init(menu_examples: Dictionary, build_description: String) -> void:
	examples = menu_examples
	description = build_description
	_build()


func _ready() -> void:
	# The window resizing is the event the ladder actually cares about: the bar's own
	# resized signal does not fire when the window shrinks past the point where the
	# bar stops fitting — by then the bar is already wider than the screen.
	get_viewport().size_changed.connect(_fit_toolbar.bind(-1.0))
	_fit_toolbar.call_deferred()


# Mouse-operated controls must not hold keyboard focus: the computer keyboard is the
# piano. Same rule, and the same hit-area floor, as main's _defocus — duplicated the
# way a load-bearing convention may be, rather than reached back through a reference.
func _defocus(control: Control) -> Control:
	control.focus_mode = Control.FOCUS_NONE
	control.custom_minimum_size.y = maxf(control.custom_minimum_size.y,
		Design.scale(Design.HIT_TARGET))
	return control


func _icon(kind: int, colour: Color = Design.INK_NORMAL, size: int = 0) -> Texture2D:
	return Icons.get_icon(kind, Design.scale(size if size > 0 else Design.SIZE_CONTROL),
		colour)


func _toolbar_group(bar: HBoxContainer, first: bool = false) -> HBoxContainer:
	if not first:
		var rule := VSeparator.new()
		rule.add_theme_constant_override("separation", Design.SPACE_M)
		bar.add_child(rule)
	var group := HBoxContainer.new()
	group.add_theme_constant_override("separation", Design.SPACE_XS)
	bar.add_child(group)
	if not first:
		_toolbar_rules[group] = bar.get_child(bar.get_child_count() - 2)
	return group


func _build() -> void:
	var bar := HBoxContainer.new()
	bar.custom_minimum_size.y = Design.scale(52)
	bar.add_theme_constant_override("separation", Design.SPACE_S)

	# ---- who and what: context before actions -----------------------------------
	# The product name and the open document were at opposite ends of the bar with
	# nine buttons between them. Together, top left, they answer "where am I" before
	# anything asks "what do you want to do".
	_toolbar_rules.clear()
	var identity := VBoxContainer.new()
	toolbar_identity = identity
	identity.add_theme_constant_override("separation", 0)
	# Centred, so the block sits in the middle of the bar whether it is two lines or the
	# one it drops to on a narrow window. Top-aligned it was fine at full width and read
	# as a mistake the moment the product name went, with the file name left hanging off
	# the top edge of a 52px bar.
	identity.alignment = BoxContainer.ALIGNMENT_CENTER
	# 150 was 37px more than the widest thing in it, on a toolbar that had eight pixels
	# of room. The floor is still here — it keeps the block from collapsing and stops the
	# rest of the bar shuffling sideways every time a document is opened — but it is now
	# set just above what the title actually measures rather than to a round number.
	identity.custom_minimum_size.x = Design.scale(120)

	var title := Label.new()
	toolbar_title = title
	title.text = "SoundGraph"
	title.add_theme_font_override("font", Design.font(Design.WEIGHT_SEMIBOLD))
	title.add_theme_font_size_override("font_size", Design.type(Design.SIZE_APP_TITLE))
	title.add_theme_color_override("font_color", Design.INK_BRIGHT)
	# Hovering the product name is the other place somebody would look for what they are
	# running, and it costs no room at all.
	title.tooltip_text = description
	title.mouse_filter = Control.MOUSE_FILTER_STOP
	identity.add_child(title)

	# At least a character of air on either side, and the same air between the QR
	# and the name. The code points at mutantfactory.net/soundgraph — the door into
	# this program, standing where a logo would.
	var identity_margin := MarginContainer.new()
	toolbar_identity_margin = identity_margin
	identity_margin.add_theme_constant_override("margin_left",
		Design.type(Design.SIZE_APP_TITLE))
	identity_margin.add_theme_constant_override("margin_right",
		Design.type(Design.SIZE_APP_TITLE))
	var identity_row := HBoxContainer.new()
	identity_row.add_theme_constant_override("separation",
		Design.type(Design.SIZE_APP_TITLE))
	var qr := TextureRect.new()
	toolbar_qr = qr
	qr.visible = bool(Settings.fetch("qr_visible", true))
	var qr_image := Image.load_from_file(
		ProjectSettings.globalize_path("res://soundgraph_qr.png"))
	if qr_image != null:
		qr.texture = ImageTexture.create_from_image(qr_image)
	# Ignore the texture's own size or the bar becomes 396px of quiet zone.
	qr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	qr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	# Nearest, or the modules smear into grey and the phone gives up.
	qr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	qr.custom_minimum_size = Vector2(Design.scale(Design.HIT_TARGET),
		Design.scale(Design.HIT_TARGET))
	qr.tooltip_text = "mutantfactory.net/soundgraph — click for a scannable size"
	qr.mouse_filter = Control.MOUSE_FILTER_STOP
	qr.gui_input.connect(func(event: InputEvent) -> void:
		var click := event as InputEventMouseButton
		if click != null and click.pressed and click.button_index == MOUSE_BUTTON_LEFT:
			_show_qr_large())
	identity_row.add_child(qr)
	identity_row.add_child(identity)
	identity_margin.add_child(identity_row)
	bar.add_child(identity_margin)

	# The menus that are visited rather than lived in — Examples, File, View,
	# Arrange, Make module, Mute — are built here as plain popups and gathered into
	# the hamburger at the bar's right end, where the eye starts. The toolbar keeps
	# only what is reached for constantly: the verb, undo, and the truth strip.
	var examples_popup := PopupMenu.new()
	examples_popup.name = "ExamplesMenu"
	# Large groups become submenus so the curated top level survives the banks. Grouping
	# is by the label prefix _scan_examples already assigns, and the submenu wiring is
	# per-group so a second bank costs a table entry, not a copy of this code.
	var grouped: Dictionary = {}
	var top_names: Array = []
	for label in examples.keys():
		var text := str(label)
		var split := text.find(": ")
		var prefix := text.substr(0, split) if split > 0 else ""
		if prefix != "":
			if not grouped.has(prefix):
				grouped[prefix] = []
			grouped[prefix].append(label)
		else:
			top_names.append(label)
	for prefix in grouped.keys():
		if grouped[prefix].size() < EXAMPLE_SUBMENU_THRESHOLD:
			top_names.append_array(grouped[prefix])
			grouped.erase(prefix)
	for index in top_names.size():
		examples_popup.add_item(str(top_names[index]), index)
	for prefix in grouped.keys():
		var bank_names: Array = grouped[prefix]
		bank_names.sort()
		var bank_popup := PopupMenu.new()
		bank_popup.name = "%sExamples" % prefix
		examples_popup.add_child(bank_popup)
		examples_popup.add_submenu_item("%s bank" % prefix, bank_popup.name)
		for index in bank_names.size():
			bank_popup.add_item(
				str(bank_names[index]).trim_prefix(prefix + ": ").capitalize(), index)
		var chosen := bank_names
		bank_popup.id_pressed.connect(func(id: int) -> void:
			example_chosen.emit(str(chosen[id])))
	examples_popup.id_pressed.connect(func(id: int) -> void:
		example_chosen.emit(str(top_names[id])))

	# ---- graph: the core verb, and the two that tidy up after it -----------------
	# Add node is what this application is for, so it is the one filled button in the
	# chrome and it comes first. Everything having equal weight meant reading all
	# thirteen controls to find the one that matters.
	var graph_group := _toolbar_group(bar, true)
	var add_button := Button.new()
	toolbar_add_button = add_button
	add_button.text = "+  Add node"
	add_button.tooltip_text = "Search by what you want, not only by name (Ctrl+Space)"
	add_button.pressed.connect(func() -> void: add_node_requested.emit())
	_primary_buttons.append(add_button)
	graph_group.add_child(Design.make_primary(_defocus(add_button) as Button))

	# Auto-place and Arrange selection behind one menu, for the same reason. Both are
	# occasional; the second is usually unavailable anyway, and a permanently greyed
	# button is chrome that has never done anything for anyone.
	arrange_popup = PopupMenu.new()
	arrange_popup.name = "ArrangeMenu"
	arrange_popup.add_item("Auto-place everything", 0)
	arrange_popup.add_item("Arrange selection", 1)
	arrange_popup.add_item("Collapse selection into module", 2)
	arrange_popup.set_item_tooltip(0, "Lay the whole graph out left to right. The same "
		+ "patch always lands the same way, wherever things were before.")
	arrange_popup.set_item_tooltip(2, "The selected nodes become a module: one node "
		+ "wearing their boundary as ports and their settings as knobs. Undo undoes it.")
	arrange_popup.set_item_disabled(1, true)
	arrange_popup.set_item_disabled(2, true)
	arrange_popup.id_pressed.connect(func(id: int) -> void:
		arrange_action.emit(id))

	# ---- edit --------------------------------------------------------------------
	# Visible buttons as well as the shortcut: an undo you cannot see is an undo a first
	# time user does not know they have.
	# Icons, exceptionally. The rule since the tofu incident has been words over glyphs,
	# because almost no glyph reads correctly without its tooltip — but undo and redo are
	# the two commands whose curved arrows genuinely are universal, the icons are drawn
	# rather than hoped for in a font, and these were the two widest buttons in the bar's
	# narrowest group. The tooltips still say the word and the shortcut.
	var edit_group := _toolbar_group(bar)
	toolbar_edit_group = edit_group
	undo_button = Button.new()
	undo_button.icon = _icon(Icons.Kind.UNDO, Design.INK_NORMAL)
	undo_button.disabled = true
	undo_button.pressed.connect(func() -> void: undo_requested.emit())
	edit_group.add_child(_defocus(undo_button))

	redo_button = Button.new()
	redo_button.icon = _icon(Icons.Kind.REDO, Design.INK_NORMAL)
	redo_button.disabled = true
	redo_button.pressed.connect(func() -> void: redo_requested.emit())
	edit_group.add_child(_defocus(redo_button))

	# Open, Add module and Save as behind one menu.
	#
	# Not tidiness for its own sake: with every command exposed the toolbar had a
	# minimum width of 1786px, so on any window narrower than that the whole layout
	# was forced wider than the window and the inspector hung off the right-hand edge
	# with its text cut in half. These three are reached once per session; Add node is
	# reached constantly. Only one of them earns permanent space.
	var file_popup := PopupMenu.new()
	file_popup.name = "FileMenu"
	file_popup.add_item("New", 4)
	file_popup.add_item("Open…", 0)
	file_popup.add_item("Add module…", 1)
	file_popup.add_item("Add module as definition…", 3)
	file_popup.add_item("Import MIDI…", 5)
	file_popup.add_item("Transcribe audio…", 6)
	file_popup.add_item("Save as…", 2)
	# By index, via the id. set_item_tooltip takes a position and these were being handed
	# an id: item 3 does not exist in a four-item menu, so Godot logged an out-of-bounds
	# error and the tooltip explaining what "as definition" even means was never attached
	# to anything. The neighbouring call passed 1 and worked, which is how it went
	# unnoticed — id and index happened to agree there and nowhere else.
	file_popup.set_item_tooltip(file_popup.get_item_index(3),
		"Add an existing patch as a reusable module: one definition, one instance, its "
		+ "terminals becoming the ports. The patch stays one thing instead of dissolving "
		+ "into copied nodes.")
	file_popup.set_item_tooltip(file_popup.get_item_index(1),
		"Add an existing patch into this one. Its nodes are copied in with their names "
		+ "prefixed; its own inputs and outputs are left out, because those belong to a "
		+ "finished patch rather than to a module.")
	file_popup.id_pressed.connect(func(id: int) -> void: file_action.emit(id))

	view_popup = PopupMenu.new()
	view_popup.name = "ViewMenu"
	view_popup.add_radio_check_item("Cables: catenary", 0)
	view_popup.add_radio_check_item("Cables: PCB", 1)
	view_popup.set_item_checked(0, true)
	view_popup.add_separator()
	for index in CASE_LABELS.size():
		view_popup.add_radio_check_item(CASE_LABELS[index], 10 + index)
	view_popup.set_item_checked(3, true)
	view_popup.add_separator()
	# The two readings of a zoomed-out graph. Adaptive is the map: the drawing
	# simplifies as you leave so the surviving words stay readable. 1:1 is the
	# photograph: the full module — controls, text, everything — at every zoom,
	# smaller only because it is farther away.
	view_popup.add_radio_check_item("Detail: adaptive", 70)
	view_popup.add_radio_check_item("Detail: 1:1", 71)
	view_popup.set_item_tooltip(view_popup.get_item_index(70),
		"The map: the drawing simplifies as you zoom out. Toggle with Ctrl+2.")
	view_popup.set_item_tooltip(view_popup.get_item_index(71),
		"The photograph: the full module at every zoom. Toggle with Ctrl+2.")
	view_popup.set_item_checked(view_popup.get_item_index(
		70 + int(Settings.fetch("graph_detail", PatchGraph.DetailMode.ONE_TO_ONE))), true)
	# Beside the detail pair because the two get reached for together: 1:1 is "show
	# me the real thing" and fit is "show me all of it". An action rather than a
	# state — same framing the toolbar's Fit does, in the menu where the eye already
	# is when choosing how to look at the graph.
	# What the panels are painted in. A whole-rack default, because a rack that is one
	# family reads as a rack; individual panels are repainted by right-clicking them,
	# which is where somebody is already pointing when they want to change one.
	view_popup.add_separator()
	var panels_popup := PopupMenu.new()
	panels_popup.name = "PanelsMenu"
	panels_popup.add_radio_check_item("Category colours", 200)
	panels_popup.set_item_tooltip(0,
		"One graphite panel each, with a stripe saying what the module is.")
	panels_popup.add_separator()
	for index in ModuleThemes.ORDER.size():
		var key: String = ModuleThemes.ORDER[index]
		panels_popup.add_radio_check_item(ModuleThemes.display_name(key), 201 + index)
		panels_popup.set_item_tooltip(panels_popup.get_item_index(201 + index),
			str(ModuleThemes.THEMES[key].get("blurb", "")))
	panels_popup.id_pressed.connect(func(id: int) -> void: view_action.emit(id))
	view_popup.add_child(panels_popup)
	view_popup.add_submenu_item("Panels", panels_popup.name)
	view_popup.add_separator()
	view_popup.add_item("Zoom: fit to screen", 72)
	view_popup.set_item_tooltip(view_popup.get_item_index(72),
		"Zoom and scroll so the whole patch is visible, clear of the minimap "
		+ "and the zoom controls.")
	view_popup.add_item("Zoom: 100%", 73)
	view_popup.set_item_tooltip(view_popup.get_item_index(73),
		"Working scale. Centres on the selection when there is one, and on "
		+ "whatever the view was already looking at otherwise.")
	# The image editors' pair — fit on 0, real size on 1 — because that is where
	# these hands already are. Accelerators rather than another _unhandled_key
	# branch: the popup matches them while closed, the menu prints them in the
	# right-hand column, and there is exactly one path for key and click alike.
	# Ctrl-modified, so the piano keys cannot collide.
	view_popup.set_item_accelerator(view_popup.get_item_index(72),
		KEY_MASK_CTRL | KEY_0)
	view_popup.set_item_accelerator(view_popup.get_item_index(73),
		KEY_MASK_CTRL | KEY_1)
	view_popup.add_separator()
	# An accessibility switch that only exists as a hope is not one. Everything that
	# moves on its own in this editor is off behind this: the signal glow and the grid
	# fade, both of which say something the interface also says without moving.
	view_popup.add_separator()
	for index in Design.SCALE_NAMES.size():
		view_popup.add_radio_check_item("Size: %s" % Design.SCALE_NAMES[index],
			50 + index)
	view_popup.set_item_checked(view_popup.get_item_index(50 + Design.ui_scale), true)
	view_popup.add_separator()
	for index in Rack.DENSITY_NAMES.size():
		view_popup.add_radio_check_item("Rack: %s" % Rack.DENSITY_NAMES[index],
			40 + index)
	view_popup.set_item_checked(view_popup.get_item_index(40 + Rack.density), true)
	view_popup.add_separator()
	for index in Design.PALETTE_NAMES.size():
		view_popup.add_radio_check_item(Design.PALETTE_NAMES[index], 30 + index)
	view_popup.add_separator()
	view_popup.add_check_item("Reduce motion", 20)
	view_popup.set_item_checked(view_popup.get_item_index(20), Design.reduced_motion)
	# The build, last and unselectable. It goes in a menu rather than on the toolbar
	# because the toolbar has eight pixels of room and this is not something anybody
	# reads while playing — but it is the first thing anybody wants after a reload that
	# behaved oddly, and hunting for it in a log is not an answer.
	view_popup.add_separator()
	view_popup.add_item(description, 60)
	view_popup.set_item_disabled(view_popup.get_item_index(60), true)
	view_popup.id_pressed.connect(func(id: int) -> void: view_action.emit(id))

	# ---- performance, pinned to the right ----------------------------------------
	# The gap that pins the performance group right is also where passing remarks go.
	#
	# There are two kinds of thing to say and ten places were writing one label: three
	# states ("playing", "patch has errors") and seven remarks ("undid move", "saved",
	# "placed 7 nodes"). Whichever happened last owned the line, so the strip could sit
	# reading "saved" while the graph was broken.
	#
	# The remark lives in the flexible middle rather than a slot of its own, because a
	# fixed slot holds the toolbar open: "arranged 7 nodes — the file had no layout"
	# took the layout's minimum width from 1267 to 1515 and pushed the inspector off
	# the screen, which is a bug this file already has a test for.
	message_label = Label.new()
	message_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	message_label.clip_text = true
	# Aligned left and trimmed at the end, not aligned right and clipped at the start.
	#
	# Right alignment plus clip_text takes the overflow off the *front*, so every message
	# too long for the gap lost its first words and kept its last: raising the wand printed
	# "point at the jacks and knobs the module should show" and the strip read "ould show".
	# A truncated message has to begin at the beginning — that is the half that says what
	# happened — and an ellipsis has to admit there is more, which clipping never did.
	message_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	message_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	message_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	message_label.add_theme_font_size_override("font_size",
		Design.type(Design.SIZE_SECONDARY))
	message_label.add_theme_color_override("font_color", Design.INK_SECOND)
	bar.add_child(message_label)
	# ---- status ------------------------------------------------------------------
	# One short line rather than prose: what state the engine is in, and whether the
	# graph is valid. Set from _refresh_status().
	# One strip, three facts, always in the same order.
	#
	# The engine state, whether the graph is valid, and the sample rate were in three
	# different places in three different voices — "playing" alone in the far corner,
	# "Graph valid" at the top of the inspector, and the rate buried in the cost
	# readout. Read together they answer "is this thing working" at a glance; scattered,
	# each one on its own looked like an afterthought.
	# The words moved into the menu; the dot stays, because it is the one part
	# legible from across a table and its tooltip still says the whole sentence.
	var status_group := _toolbar_group(bar)
	status_group.add_theme_constant_override("separation", Design.SPACE_S)

	transport_dot = TextureRect.new()
	transport_dot.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	status_group.add_child(transport_dot)

	# ---- the hamburger, upper right --------------------------------------------
	# Everything visited rather than lived in, behind one drawn glyph. Examples,
	# File, View and Arrange keep their whole menus as submenus; Make module keeps
	# its gesture; Mute presses the keyboard's own mute so there is one mute state,
	# not two. Audition is gone — reset-and-strike lives on the keys it imitated.
	var burger := MenuButton.new()
	toolbar_menu_button = burger
	burger.icon = _icon(Icons.Kind.HAMBURGER, Design.INK_NORMAL)
	# Borderless: the glyph is the button. A frame around three bars read as a tiny
	# window that had lost its contents.
	burger.flat = true
	burger.tooltip_text = "Examples, file, view, arrange — the menus"
	var burger_popup := burger.get_popup()
	burger_popup.add_child(examples_popup)
	burger_popup.add_submenu_item("Examples", "ExamplesMenu")
	burger_popup.add_child(file_popup)
	burger_popup.add_submenu_item("File", "FileMenu")
	burger_popup.add_child(view_popup)
	burger_popup.add_submenu_item("View", "ViewMenu")
	burger_popup.add_child(arrange_popup)
	burger_popup.add_submenu_item("Arrange", "ArrangeMenu")
	burger_popup.add_separator()
	burger_popup.add_item("Make module", 100)
	burger_popup.set_item_tooltip(burger_popup.get_item_index(100),
		"Draw a rectangle round some nodes. What is wholly inside it becomes a "
		+ "module, left open so you can see and arrange its parts.")
	burger_popup.add_check_item("Mute", 101)
	burger_popup.add_check_item("QR code", 104)
	burger_popup.set_item_tooltip(burger_popup.get_item_index(104),
		"The door into the program: mutantfactory.net/soundgraph, beside the "
		+ "wordmark. Untick to work without it watching.")
	burger_popup.set_item_tooltip(burger_popup.get_item_index(101),
		"Silence the output without changing the patch — the same mute as the "
		+ "keyboard's. Escape still stops every sounding note.")
	burger_popup.add_item("Send feedback…", 105)
	burger_popup.set_item_tooltip(burger_popup.get_item_index(105),
		"A note straight to the workbench: what you were doing, what went "
		+ "sideways. The dialog says exactly what it sends, and works offline.")
	burger_popup.add_separator()
	burger_popup.add_item("Audio starting…", 102)
	burger_popup.set_item_disabled(burger_popup.get_item_index(102), true)
	burger_popup.add_item("Graph valid", 103)
	burger_popup.set_item_disabled(burger_popup.get_item_index(103), true)
	toolbar_menu_popup = burger_popup
	burger_popup.about_to_popup.connect(func() -> void:
		burger_popup.set_item_checked(burger_popup.get_item_index(101),
			bool(is_muted.call()))
		burger_popup.set_item_checked(burger_popup.get_item_index(104),
			toolbar_qr != null and toolbar_qr.visible))
	burger_popup.id_pressed.connect(func(id: int) -> void:
		if id == 100:
			make_module_requested.emit()
		elif id == 101:
			mute_toggled.emit()
		elif id == 104:
			if toolbar_qr != null:
				toolbar_qr.visible = not toolbar_qr.visible
				Settings.store("qr_visible", toolbar_qr.visible)
		elif id == 105:
			feedback_requested.emit())
	bar.add_child(_defocus(burger))

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_right", Design.SPACE_M)
	bar.add_child(margin)
	bar.resized.connect(_fit_toolbar)
	# Air above and below: buttons pressed against the bar's edges read as cramped
	# in a way no amount of horizontal order repairs. This node IS that margin.
	add_theme_constant_override("margin_top", Design.SPACE_S)
	add_theme_constant_override("margin_bottom", Design.SPACE_S)
	add_child(bar)


## Shows or hides a toolbar group along with the rule that introduces it.


func _show_toolbar_group(group: HBoxContainer, shown: bool) -> void:
	if group == null:
		return
	group.visible = shown
	if _toolbar_rules.has(group):
		(_toolbar_rules[group] as Control).visible = shown


## Puts the bar on a given rung. Everything above the rung is showing, everything at or
## below it has been given up.
##
## Deliberately not "hide whatever does not fit". Which control that turns out to be
## depends on the order they were added in, so the bar would lose Silence on one window
## and the product name on another, and nobody could learn what a narrow window costs.


func _apply_toolbar_rung(rung: int) -> void:
	toolbar_rung = clampi(rung, Rung.FULL, RUNG_COUNT - 1)
	if toolbar_title != null:
		toolbar_title.visible = toolbar_rung < Rung.IDENTITY
	if toolbar_identity != null:
		# The floor drops with the title, or the block goes on holding open 120px of
		# nothing and giving the name up buys the bar exactly zero.
		toolbar_identity.custom_minimum_size.x = Design.scale(
			120 if toolbar_rung < Rung.IDENTITY else 72)
	if toolbar_identity_margin != null:
		# The wordmark's air goes with the wordmark. Margins that outlive their title
		# are two characters of nothing on the narrowest bar there is.
		var air := Design.type(Design.SIZE_APP_TITLE) \
			if toolbar_rung < Rung.IDENTITY else Design.SPACE_XS
		toolbar_identity_margin.add_theme_constant_override("margin_left", air)
		toolbar_identity_margin.add_theme_constant_override("margin_right", air)
	if toolbar_add_button != null:
		# The verb keeps its meaning and gives up its words; the tooltip still says
		# them. The hamburger is never on the ladder at all — since the menus moved
		# inside it, it is the one control whose loss would strand the user.
		toolbar_add_button.text = "+  Add node" if toolbar_rung < Rung.VERB else "+"
	_show_toolbar_group(toolbar_edit_group, toolbar_rung < Rung.EDIT)


## Picks the highest rung the window can afford, from the top.
##
## From the top every time rather than stepping up and down from where it was: a ladder
## that only ever descends never comes back when the window is widened again, and one
## that steps by one has to be run repeatedly to settle.
## A width can be passed in, so a test can ask what a 1280px window would look like
## without owning a 1280px window. Left at -1 it measures the bar it has.


func _fit_toolbar(width: float = -1.0) -> void:
	if _fitting_toolbar:
		return
	# The window, not the bar. Measuring the bar is circular and silently defeats the
	# whole ladder: when the column's minimum is wider than the window the container
	# hands the toolbar that minimum anyway — the bar is 1610px wide on a 1280px screen,
	# 330 of it off the edge — so asking the bar how much room it has gets the answer
	# "as much as I asked for", every time, and no rung is ever climbed. The viewport is
	# the one width in the chain that content cannot inflate.
	var available: float = width
	if available <= 0.0:
		var view := get_viewport()
		available = view.get_visible_rect().size.x if view != null else 0.0
	if available <= 0.0:
		return
	_fitting_toolbar = true
	for rung in RUNG_COUNT:
		_apply_toolbar_rung(rung)
		if get_combined_minimum_size().x <= available:
			break
	_fitting_toolbar = false


func _show_qr_large() -> void:
	var dialog := AcceptDialog.new()
	dialog.title = "mutantfactory.net/soundgraph"
	var big := TextureRect.new()
	var image := Image.load_from_file(
		ProjectSettings.globalize_path("res://soundgraph_qr.png"))
	if image != null:
		big.texture = ImageTexture.create_from_image(image)
	big.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	big.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	big.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	big.custom_minimum_size = Vector2(Design.scale(396), Design.scale(396))
	dialog.add_child(big)
	add_child(dialog)
	dialog.popup_centered()
	dialog.visibility_changed.connect(func() -> void:
		if not dialog.visible:
			dialog.queue_free())
