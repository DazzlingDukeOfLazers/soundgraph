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

## Where section labels' ids start, well clear of every setting's.
const SECTION_ID := 900

## The optical cell the seven door marks are drawn in — one figure, so that a wide glyph
## and a tall one occupy the same square and the column of them reads as a column.
const DOOR_ICON := 20

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
## The word beside the transport dot.
var transport_word: Label
## The Audio menu, which holds the one setting that is not a View setting.
var _audio_menu: PopupMenu
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
	# No rule between Add node and undo/redo. Making something and taking it back are one
	# group — the thing you do and the way out of it — and a rule between them said there
	# were four groups in this bar where there are three: the name, the work, and the
	# program. Separators are for the joins that mean something.
	var edit_group := _toolbar_group(bar, true)
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
	# The examples are things you open, which is what File is. At the root of the menu
	# they sat as a peer of File and View, which said the program has three concerns and
	# one of them is a folder of demos.
	file_popup.add_child(examples_popup)
	file_popup.add_submenu_item("Open example…", examples_popup.name)
	file_popup.add_separator()
	file_popup.add_item("Import MIDI…", 5)
	file_popup.add_item("Transcribe audio…", 6)
	file_popup.add_separator()
	file_popup.add_item("Save as…", 2)
	# By index, via the id. set_item_tooltip takes a position and these were being handed
	# an id: item 3 does not exist in a four-item menu, so Godot logged an out-of-bounds
	# error and the tooltip explaining what "as definition" even means was never attached
	# to anything. The neighbouring call passed 1 and worked, which is how it went
	# unnoticed — id and index happened to agree there and nowhere else.
	file_popup.id_pressed.connect(func(id: int) -> void: file_action.emit(id))

	# ---- Patch: what you do to the graph, not to the file --------------------------
	# Adding a module is opening a file, which is why it lived under File, but what it
	# does is put a thing in the patch — and a person looking for it is thinking about
	# the patch. The ids stay File's, because the handler behind them is one dialog.
	var patch_popup := PopupMenu.new()
	patch_popup.name = "PatchMenu"
	patch_popup.add_item("Add node…", 200)
	patch_popup.set_item_tooltip(patch_popup.get_item_index(200),
		"The browser: search by what you want, not only by name (Ctrl+Space)")
	patch_popup.add_separator()
	patch_popup.add_item("Make module", 100)
	patch_popup.set_item_tooltip(patch_popup.get_item_index(100),
		"Draw a rectangle round some nodes. What is wholly inside it becomes a "
		+ "module, left open so you can see and arrange its parts.")
	patch_popup.add_item("Add module…", 1)
	patch_popup.set_item_tooltip(patch_popup.get_item_index(1),
		"Add an existing patch into this one. Its nodes are copied in with their names "
		+ "prefixed; its own inputs and outputs are left out, because those belong to a "
		+ "finished patch rather than to a module.")
	patch_popup.add_item("Add module as definition…", 3)
	patch_popup.set_item_tooltip(patch_popup.get_item_index(3),
		"Add an existing patch as a reusable module: one definition, one instance, its "
		+ "terminals becoming the ports. The patch stays one thing instead of dissolving "
		+ "into copied nodes.")
	patch_popup.id_pressed.connect(func(id: int) -> void:
		if id == 200:
			add_node_requested.emit()
		elif id == 100:
			make_module_requested.emit()
		else:
			file_action.emit(id))

	# ---- Edit: the two commands that exist -----------------------------------------
	# Undo and redo and nothing else, because cut, copy, duplicate and select all are
	# not commands this editor has. A menu of greyed-out promises is worse than a short
	# menu — it says the program can do things it cannot.
	var edit_popup := PopupMenu.new()
	edit_popup.name = "EditMenu"
	edit_popup.add_item("Undo", 0)
	edit_popup.set_item_tooltip(0, "Ctrl+Z")
	edit_popup.add_item("Redo", 1)
	edit_popup.set_item_tooltip(1, "Ctrl+Y")
	# No accelerators on these two: the editor already answers Ctrl+Z and Ctrl+Y itself,
	# and a popup accelerator matches while the popup is closed — two handlers, one key,
	# and an undo that undoes twice.
	edit_popup.id_pressed.connect(func(id: int) -> void:
		if id == 0:
			undo_requested.emit()
		else:
			redo_requested.emit())

	# ---- View: seven doors rather than thirty switches -----------------------------
	# It had become a preferences window written as a list: cables, case width, detail,
	# panels, zoom, interface size, rack density, theme, motion, build. Ten unrelated
	# ideas in one column, most of a screen tall, and five of them looked like different
	# flavours of "make things bigger" — UI size, rack density, case width, detail and
	# zoom are four different questions and one of them is not about size at all.
	#
	# So it grows sideways now. Each door names a concept and holds the switches for it,
	# and the ids underneath are untouched, because the handler is about what a setting
	# does and not about which menu it was reached from.
	view_popup = PopupMenu.new()
	view_popup.name = "ViewMenu"

	var graph_menu := _submenu(view_popup, "GraphDisplayMenu", "Graph display")
	# A titled separator, not a disabled item. An item with no id of its own is given
	# one — its own index — so "Cable style" became id 0 and stole every tick meant for
	# Catenary, which is id 0 as well. The separator cannot be selected and cannot
	# collide, and is what a group heading inside a menu is for.
	_section(graph_menu, "Cable style")
	graph_menu.add_radio_check_item("Catenary", 0)
	graph_menu.add_radio_check_item("PCB", 1)
	# The two readings of a zoomed-out graph. Adaptive is the map: the drawing
	# simplifies as you leave so the surviving words stay readable. 1:1 is the
	# photograph: the full module — controls, text, everything — at every zoom,
	# smaller only because it is farther away.
	graph_menu.add_separator()
	_section(graph_menu, "Detail")
	graph_menu.add_radio_check_item("Adaptive", 70)
	graph_menu.add_radio_check_item("1:1", 71)
	graph_menu.set_item_tooltip(graph_menu.get_item_index(70),
		"The map: the drawing simplifies as you zoom out. Toggle with Ctrl+2.")
	graph_menu.set_item_tooltip(graph_menu.get_item_index(71),
		"The photograph: the full module at every zoom. Toggle with Ctrl+2.")
	graph_menu.id_pressed.connect(func(id: int) -> void: view_action.emit(id))

	var rack_menu := _submenu(view_popup, "RackDisplayMenu", "Rack display")
	_section(rack_menu, "Width")
	for index in CASE_LABELS.size():
		# Without the "Case:" the labels carry elsewhere. Under a heading that says
		# Width, inside a door that says Rack display, saying it a third time is the
		# menu explaining itself to itself.
		# capitalize() would do it and would also turn "84 HP" into "84 Hp", which is
		# a unit the eurorack world does not have.
		var width_label := str(CASE_LABELS[index]).trim_prefix("Case: ")
		rack_menu.add_radio_check_item(
			width_label.substr(0, 1).to_upper() + width_label.substr(1), 10 + index)
	rack_menu.add_separator()
	_section(rack_menu, "Presentation")
	for index in Rack.DENSITY_NAMES.size():
		rack_menu.add_radio_check_item(Rack.DENSITY_NAMES[index], 40 + index)
	rack_menu.id_pressed.connect(func(id: int) -> void: view_action.emit(id))

	# What the panels are painted in. A whole-rack default, because a rack that is one
	# family reads as a rack; individual panels are repainted by right-clicking them,
	# which is where somebody is already pointing when they want to change one.
	#
	# Its own door rather than a room inside Rack display: width and presentation
	# describe the rack, and a panel is a panel in every view that draws one.
	var panels_popup := _submenu(view_popup, "PanelsMenu", "Panels")
	panels_popup.add_radio_check_item("Category colours", 200)
	panels_popup.set_item_tooltip(0,
		"One graphite panel each, with a stripe saying what the module is.")
	panels_popup.add_separator()
	for index in ModuleThemes.ORDER.size():
		var key: String = ModuleThemes.ORDER[index]
		panels_popup.add_radio_check_item(ModuleThemes.display_name(key), 201 + index)
		panels_popup.set_item_tooltip(panels_popup.get_item_index(201 + index),
			str(ModuleThemes.THEMES[key].get("blurb", "")))
	# The wordmark's QR, with the panels rather than alone at the foot of View. It is a
	# thing drawn on the interface, which is what this door holds; on its own it was a
	# checkbox nobody had decided the kind of.
	panels_popup.add_separator()
	panels_popup.add_check_item("Show QR code", 104)
	panels_popup.set_item_tooltip(panels_popup.get_item_index(104),
		"The door into the program: mutantfactory.net/soundgraph, beside the "
		+ "wordmark. Untick to work without it watching.")
	panels_popup.about_to_popup.connect(func() -> void:
		panels_popup.set_item_checked(panels_popup.get_item_index(104),
			toolbar_qr != null and toolbar_qr.visible))
	panels_popup.id_pressed.connect(func(id: int) -> void:
		if id == 104:
			if toolbar_qr != null:
				toolbar_qr.visible = not toolbar_qr.visible
				Settings.store("qr_visible", toolbar_qr.visible)
			return
		view_action.emit(id))

	var zoom_menu := _submenu(view_popup, "ZoomMenu", "Zoom")
	zoom_menu.add_item("Fit to screen", 72)
	zoom_menu.set_item_tooltip(zoom_menu.get_item_index(72),
		"Zoom and scroll so the whole patch is visible, clear of the minimap "
		+ "and the zoom controls.")
	zoom_menu.add_item("100%", 73)
	zoom_menu.set_item_tooltip(zoom_menu.get_item_index(73),
		"Working scale. Centres on the selection when there is one, and on "
		+ "whatever the view was already looking at otherwise.")
	# The image editors' pair — fit on 0, real size on 1 — because that is where
	# these hands already are. Accelerators rather than another _unhandled_key
	# branch: the popup matches them while closed, the menu prints them in the
	# right-hand column, and there is exactly one path for key and click alike.
	# Ctrl-modified, so the piano keys cannot collide.
	zoom_menu.set_item_accelerator(zoom_menu.get_item_index(72), KEY_MASK_CTRL | KEY_0)
	zoom_menu.set_item_accelerator(zoom_menu.get_item_index(73), KEY_MASK_CTRL | KEY_1)
	zoom_menu.id_pressed.connect(func(id: int) -> void: view_action.emit(id))

	view_popup.add_separator()

	var size_menu := _submenu(view_popup, "InterfaceSizeMenu", "Interface size")
	for index in Design.SCALE_NAMES.size():
		size_menu.add_radio_check_item(Design.SCALE_NAMES[index], 50 + index)
	size_menu.id_pressed.connect(func(id: int) -> void: view_action.emit(id))

	var theme_menu := _submenu(view_popup, "ThemeMenu", "Theme")
	for index in Design.PALETTE_NAMES.size():
		theme_menu.add_radio_check_item(Design.PALETTE_NAMES[index], 30 + index)
	theme_menu.id_pressed.connect(func(id: int) -> void: view_action.emit(id))

	# An accessibility switch that only exists as a hope is not one. Everything that
	# moves on its own in this editor is off behind this: the signal glow and the grid
	# fade, both of which say something the interface also says without moving.
	#
	# Maximum contrast is not repeated here. It is one of the themes — the same radio
	# group, the same setting — and a second copy would be a second thing to keep in
	# step with the first.
	var access_menu := _submenu(view_popup, "AccessibilityMenu", "Accessibility")
	access_menu.add_check_item("Reduce motion", 20)
	access_menu.id_pressed.connect(func(id: int) -> void: view_action.emit(id))

	view_popup.id_pressed.connect(func(id: int) -> void: view_action.emit(id))

	# ---- Audio ---------------------------------------------------------------------
	# One command today. It has its own door because mute is not a view setting, not a
	# file command and not a graph transformation, and the alternative was the root of
	# the menu — which is how the root became a shelf for whatever had no shelf.
	var audio_popup := PopupMenu.new()
	_audio_menu = audio_popup
	audio_popup.name = "AudioMenu"
	audio_popup.add_check_item("Mute", 101)
	audio_popup.set_item_tooltip(0,
		"Silence the output without changing the patch — the same mute as the "
		+ "keyboard's. Escape still stops every sounding note.")
	audio_popup.about_to_popup.connect(func() -> void:
		audio_popup.set_item_checked(0, bool(is_muted.call())))
	audio_popup.id_pressed.connect(func(_id: int) -> void: mute_toggled.emit())

	# ---- Help ----------------------------------------------------------------------
	var help_popup := PopupMenu.new()
	help_popup.name = "HelpMenu"
	help_popup.add_item("Send feedback…", 105)
	help_popup.set_item_tooltip(0,
		"A note straight to the workbench: what you were doing, what went "
		+ "sideways. The dialog says exactly what it sends, and works offline.")
	help_popup.add_separator()
	# The build, last and unselectable. It is the first thing anybody wants after a
	# reload that behaved oddly, and hunting for it in a log is not an answer.
	help_popup.add_item(description, 60)
	help_popup.set_item_disabled(help_popup.get_item_index(60), true)
	help_popup.id_pressed.connect(func(id: int) -> void:
		if id == 105:
			feedback_requested.emit())

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

	# And the word beside it. A lit dot on its own is colour carrying meaning by itself,
	# which is a thing to hover over to find out about; two syllables say what the light
	# is for and the tooltip still says what it is doing. It is the first thing given up
	# when the bar runs out of room, because by then the dot is all there is space for.
	transport_word = Label.new()
	transport_word.text = "Audio"
	transport_word.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	transport_word.add_theme_font_size_override("font_size",
		Design.type(Design.SIZE_SECONDARY))
	transport_word.add_theme_color_override("font_color", Design.INK_SECOND)
	status_group.add_child(transport_word)

	# ---- the hamburger, upper right --------------------------------------------
	# Seven doors, each one a concept: what you open, what you undo, what you do to the
	# patch, how it is laid out, how it is drawn, what it sounds like, and where to get
	# help. What used to be here instead was every one of those plus Make module, Mute,
	# QR code, feedback and two lines of status, all as peers — which is a debug menu
	# rather than a program's menu.
	#
	# A menu holds commands. It does not hold the application, and it certainly does not
	# hold the answer to "is the audio running" — that is a state, it has a lit dot in
	# the toolbar already, and a disabled menu item is a strange place to read one.
	var burger := MenuButton.new()
	toolbar_menu_button = burger
	burger.icon = _icon(Icons.Kind.HAMBURGER, Design.INK_NORMAL)
	# A bounded square, the size of undo and redo. It was borderless on the argument
	# that the glyph is the button, which is true of a glyph nobody has to find: this
	# one is the way into every command in the program and it sits in the corner with
	# nothing around it. The frame is the same quiet one its neighbours wear, and the
	# forty-pixel floor is the hit area they already have.
	# Said out loud, because a MenuButton is flat unless it is told otherwise and
	# deleting the line that said so left it exactly as it was.
	burger.flat = false
	burger.custom_minimum_size = Vector2(Design.scale(40), Design.scale(40))
	burger.tooltip_text = "File, edit, patch, arrange, view, audio, help"
	var burger_popup := burger.get_popup()
	# Marks on the doors and nowhere else. Seven rows are what the eye lands on when the
	# menu opens, and a shape is quicker to find than a word once you know which one you
	# want; the rows behind them stay text, because a picture beside every command is a
	# menu you have to read twice. Two of the seven are marks the browser's category rail
	# already uses — the junction for a patch, the grid for an arrangement — which is
	# what having one icon set is for.
	for door: Array in [[file_popup, "File", Icons.Kind.FOLDER],
			[edit_popup, "Edit", Icons.Kind.PENCIL],
			[patch_popup, "Patch", Icons.Kind.SPLIT],
			[arrange_popup, "Arrange", Icons.Kind.GRID],
			[view_popup, "View", Icons.Kind.EYE],
			[audio_popup, "Audio", Icons.Kind.SPEAKER],
			[help_popup, "Help", Icons.Kind.QUESTION]]:
		burger_popup.add_child(door[0])
		burger_popup.add_submenu_item(str(door[1]), (door[0] as PopupMenu).name,
			SECTION_ID + burger_popup.item_count)
		# A shade above the label grey, because these rows also carry the submenu
		# chevrons and a mark that names a door should not read as quieter than the
		# arrow saying the door opens.
		burger_popup.set_item_icon(burger_popup.item_count - 1,
			_icon(int(door[2]), Design.INK_SECOND.lerp(Design.INK_NORMAL, 0.4),
				DOOR_ICON))
	toolbar_menu_popup = burger_popup
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


## A section label inside a menu: small, muted, unselectable.
##
## A labelled separator, with the rules either side of the word taken off it in the theme
## — that pairing is what made the first attempt look like an HTML fieldset, and it was
## the rules that were wrong rather than the separator. It reads in the editor's own
## label grey now, a clear step above the grey of a disabled command, because a heading
## that looks unavailable is a heading somebody tries to click.
##
## The first attempt was a disabled item, which also meant an id, which meant one more
## thing that could collide with a setting's. A separator has no id at all.
func _section(menu: PopupMenu, text: String) -> void:
	menu.add_separator(text.to_upper())
	if menu.item_count == 1:
		# A menu that opens with a label at the top opens with the highlight on the
		# label, because a popup focuses its first row and does not care that this one
		# is not a row. Arrowing already skips it; this is only the first frame, and
		# only for a keyboard.
		menu.about_to_popup.connect(func() -> void:
			if menu.item_count > 1:
				menu.set_focused_item(1))


## One submenu, parented and linked in a single move.
func _submenu(parent: PopupMenu, node_name: String, label: String) -> PopupMenu:
	var menu := PopupMenu.new()
	menu.name = node_name
	parent.add_child(menu)
	# With an id of its own, out of the settings' range. A door given no id is given its
	# own index, so the first door in a menu is id 0 — which is also the id of the
	# catenary cable style, and a tick meant for the setting landed on the door instead.
	# Same landmine as the section labels, one level up.
	parent.add_submenu_item(label, node_name, SECTION_ID + parent.item_count)
	return menu


## Ticks a setting by its id, wherever in the menu tree it lives.
##
## The editor used to reach into `view_popup` and set checks by index — twice by raw
## index, which is a number that means "third item" and stops being true the moment a
## separator moves. What a setting is called and which door it sits behind is this file's
## business; whether it is on is the editor's. This is the seam between the two.
func tick(id: int, on: bool) -> void:
	var found := _setting_item(id)
	if not found.is_empty():
		(found[0] as PopupMenu).set_item_checked(int(found[1]), on)


## Ticks exactly one of a group, and clears the rest.
func tick_one_of(ids: Array, chosen: int) -> void:
	for id: int in ids:
		tick(id, id == chosen)


## Whether a setting is ticked. For the suite, which should ask the menu rather than
## know where in it a setting sits.
func ticked(id: int) -> bool:
	var found := _setting_item(id)
	if found.is_empty():
		return false
	return (found[0] as PopupMenu).is_item_checked(int(found[1]))


## The item behind a setting id, searched only where settings live.
##
## Deliberately not the whole menu. The example shelves number their items from zero
## inside their own popups, so a search that walked everything found the fifty-third FM
## voice when it was looking for the XL interface size — and ticked it. Two id spaces
## exist here and only one of them is the settings'.
func _setting_item(id: int) -> Array:
	for menu: PopupMenu in [view_popup, _audio_menu]:
		var found := _item_of(menu, id)
		if not found.is_empty():
			return found
	return []


## A menu by node name, for the one caller that needs the whole list rather than one item.
func menu_named(node_name: String) -> PopupMenu:
	if toolbar_menu_popup == null:
		return null
	return toolbar_menu_popup.find_child(node_name, true, false) as PopupMenu


## The popup holding an id, and the index it sits at. Empty when nothing holds it.
func _item_of(menu: PopupMenu, id: int) -> Array:
	if menu == null:
		return []
	for index in menu.item_count:
		# Checkable only. A setting is a thing that can be on or off, and insisting on
		# that means a door or a label that happens to share an id can never be mistaken
		# for one — belt to the explicit ids' braces.
		if menu.get_item_id(index) != id or menu.is_item_separator(index):
			continue
		if menu.is_item_checkable(index) or menu.is_item_radio_checkable(index):
			return [menu, index]
	for child in menu.get_children():
		var found := _item_of(child as PopupMenu, id)
		if not found.is_empty():
			return found
	return []


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
	if transport_word != null:
		transport_word.visible = toolbar_rung < Rung.IDENTITY


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
