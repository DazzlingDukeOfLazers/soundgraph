extends Control
## SoundGraph — Godot editor.
##
## The primary editor, and deliberately not the authority on anything. Every question this
## UI needs answered — what node types exist, what ports they have, whether a connection
## is legal, what is wrong with the graph, what a wire is carrying — is asked of the
## SoundGraphEngine extension, which wraps the same dsp-core as the browser and the
## command line tools. Nothing here reimplements graph semantics, because a second
## implementation is a second set of answers.
##
## The UI is built in code rather than in a .tscn: the node widgets have to be generated
## from the registry anyway, so there is little left worth storing in a scene file.

const Scope := preload("res://scope.gd")
const PatchGraph := preload("res://patch_graph.gd")
const Layout := preload("res://layout.gd")

## Layout grid. Everything auto-place produces lands on this, so a hand-aligned patch and
## a generated one look like they came from the same hand.
const GRID := 40.0
## Minimum distance between columns. Wider nodes push their own column out, but never in.
const COLUMN_PITCH := 400.0
## Space left beyond the widest node in a column before the next column starts.
const COLUMN_GUTTER := 80.0
## Rows land on multiples of this — the major grid lines. Aligning to every 40 scatters
## rows onto arbitrary values; one coarse pitch is what makes a stack read as a stack.
const ROW_STEP := 200.0
# ---------------------------------------------------------------------------------
# Typography
#
# Atkinson Hyperlegible, from the Braille Institute, drawn specifically so that letters
# which usually blur together — I l 1, O 0, b d — stay distinguishable at small sizes and
# low vision. Used at bold weight throughout, with sizes well above the usual editor
# default, and high-contrast colours, following the same reasoning the Braille Institute
# applies to its own material: legibility first, density second.
#
# This also matches the project's own rule from docs/UX_PRINCIPLES.md — "avoid tiny text,
# tiny hit targets, cryptic abbreviations" — which the first pass paid lip service to.
# ---------------------------------------------------------------------------------

const FONT_PATH := "res://fonts/AtkinsonHyperlegibleNext.ttf"
const FONT_WEIGHT := 700          # bold
const FONT_SIZE := 18             # body
const FONT_SIZE_SMALL := 15       # captions, port labels, parameter names
const FONT_SIZE_HEADING := 15     # section headings, letterspaced and upper case
const FONT_SIZE_TITLE := 24

## High contrast, and warmer than a pure grey so long sessions are easier on the eye.
const INK := Color(0.96, 0.96, 0.97)
const INK_DIM := Color(0.72, 0.74, 0.78)
const ACCENT := Color(0.43, 0.91, 0.72)
const WARNING := Color(1.0, 0.80, 0.45)
const ERROR := Color(1.0, 0.55, 0.50)

## How much harder an audio cable pulls its ends into line than a control cable does.
## This is what makes the signal chain come out as one straight spine with the modulation
## sources arranged around it, rather than everything averaged into a gentle zig-zag.
const AUDIO_PULL := 8.0


static func snap_up(value: float, step: float) -> float:
	return ceilf(value / step) * step

## Everything openable from the Examples menu.
##
## The game sounds are here as well as in the sandbox, and that is the point: they are not
## a private asset format the sandbox reads, they are ordinary patches. Open the coin,
## change the arpeggio interval, hear a different coin — and the same file is what the
## sandbox plays and what deploys to the board.
##
## They are also the sfxr port's output, so each one is a sound demonstrably equal to what
## sfxr makes rather than an approximation somebody eyeballed.
const EXAMPLES := {
	"First Synth": "first-synth.json",
	"Delay Echo": "delay-echo.json",
	"Game: coin": "game/coin.json",
	"Game: jump": "game/jump.json",
	"Game: jump (double)": "game/jump2.json",
	"Game: hurt": "game/hurt.json",
	"Game: shoot": "game/shoot.json",
	"Game: explode": "game/explode.json",
	"Game: powerup": "game/powerup.json",
	"Game: select": "game/select.json",
}

# Signal types, mapped to GraphEdit slot types so the engine's own compatibility rule is
# what the mouse enforces while dragging a wire.
const SLOT_AUDIO := 0
const SLOT_CONTROL := 1
const SLOT_EVENT := 2
const SLOT_NOTE := 3

const TYPE_COLOURS := {
	"audio": Color(0.43, 0.91, 0.72),
	"control": Color(0.55, 0.72, 1.0),
	"event": Color(1.0, 0.80, 0.50),
	"note": Color(0.94, 0.62, 0.90),
}

# Computer-keyboard note mapping, matching the web editor so muscle memory carries over.
const KEY_NOTES := {
	KEY_A: 0, KEY_W: 1, KEY_S: 2, KEY_E: 3, KEY_D: 4, KEY_F: 5, KEY_T: 6,
	KEY_G: 7, KEY_Y: 8, KEY_H: 9, KEY_U: 10, KEY_J: 11, KEY_K: 12,
}

# Left untyped, and instantiated through ClassDB rather than by name. Annotating it as
# SoundGraphEngine would make this script fail to *parse* when the extension is missing,
# which means the helpful "build the extension first" message below could never be shown —
# the user would get a parse error instead.
var engine
var registry: Dictionary = {}          # type name -> descriptor from the core
var patch: Dictionary = {}             # the document, in patch-format shape
var widgets: Dictionary = {}           # patch node id -> GraphNode
var ids: Dictionary = {}               # GraphNode.name -> patch node id

var graph_edit: GraphEdit
var views: TabContainer
var rack: Rack
var sandbox: Sandbox
var keyboard: Keyboard
## What is open, shown so "which patch am I looking at" is never a guess.
var document_label: Label
var document_name := "untitled"
var diagnostics_list: VBoxContainer
var info_label: RichTextLabel
var scope: Control
var status_label: Label
var search_popup: PopupPanel
var search_field: LineEdit
var search_results: VBoxContainer
var search_hint: Label
var file_dialog: FileDialog

var player: AudioStreamPlayer
var playback: AudioStreamGeneratorPlayback

var octave := 3
var held_notes := {}
var inspecting := {}                   # {"node": id, "port": name} or empty
var suppress_reload := false
## The file dialog does open, save and import; this says which is in flight.
var _importing_module := false

## Undo works on whole-document snapshots rather than per-operation inverses. A patch is
## a few kilobytes, and the code that turns one into a view is the same well-exercised
## path used for loading — so "undo an edit" reduces to "load the previous document",
## which cannot drift out of step with the operations the way hand-written inverses do.
var undo_redo := UndoRedo.new()
var _pending_snapshot: Dictionary = {}
var undo_button: Button
var redo_button: Button
var arrange_selection_button: Button

## node id -> parameter name -> {"slider": Control, "readout": Label, "descriptor": Dictionary}
## Kept so an undone knob turn can move the knob back without rebuilding the graph.
var parameter_widgets := {}


func _ready() -> void:
	if not ClassDB.class_exists("SoundGraphEngine"):
		_fatal("The SoundGraphEngine extension is not loaded.\n\n" +
			"Build it first:\n" +
			"  cmake -S runtime-godot -B runtime-godot/build -DCMAKE_BUILD_TYPE=Release\n" +
			"  cmake --build runtime-godot/build\n\n" +
			"That writes editor-godot/bin/, then reopen this project.")
		return

	engine = ClassDB.instantiate("SoundGraphEngine")
	var registry_json: Variant = JSON.parse_string(engine.get_registry_json())
	if typeof(registry_json) != TYPE_DICTIONARY:
		_fatal("The extension returned a node registry that could not be read.")
		return
	for type in registry_json["types"]:
		registry[type["name"]] = type

	_apply_theme()
	_build_ui()
	_start_audio()
	_load_example("First Synth")


## One theme on the root, inherited by everything — including the GraphNodes generated for
## each patch node, which would otherwise each need their own overrides.
func _apply_theme() -> void:
	var face := load(FONT_PATH)
	if face == null:
		push_warning("Atkinson Hyperlegible is missing; falling back to the default font")
		return

	var bold := FontVariation.new()
	bold.base_font = face
	bold.variation_opentype = {&"wght": FONT_WEIGHT}

	var editor_theme := Theme.new()
	editor_theme.default_font = bold
	editor_theme.default_font_size = FONT_SIZE

	# Text colour is set per type rather than globally: Godot has no single "text colour",
	# and leaving these at the defaults would undo the contrast the font is here for.
	for type_name in ["Label", "Button", "CheckButton", "OptionButton", "LineEdit",
			"RichTextLabel", "ItemList", "PopupMenu", "TabBar"]:
		editor_theme.set_color("font_color", type_name, INK)
	editor_theme.set_color("default_color", "RichTextLabel", INK)
	editor_theme.set_color("font_placeholder_color", "LineEdit", INK_DIM)
	editor_theme.set_color("title_color", "GraphNode", INK)

	# Roomier controls. A slider you can actually hit matters as much as type you can
	# read, and both are the same principle.
	editor_theme.set_constant("outline_size", "Label", 0)
	theme = editor_theme


func _fatal(message: String) -> void:
	var label := Label.new()
	label.text = message
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(label)
	push_error(message)


# ---------------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------------

func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	root.add_child(_build_toolbar())

	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.split_offset = 980
	root.add_child(split)

	graph_edit = PatchGraph.new()
	graph_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	graph_edit.right_disconnects = true
	graph_edit.show_grid = false   # the canvas draws its own; see below
	graph_edit.minimap_enabled = true
	# Snap to the same grid auto-place uses, so dragging a node by hand keeps the pitch.
	graph_edit.snapping_enabled = true
	graph_edit.snapping_distance = int(GRID)
	# The canvas draws its own grid, whose tiers are the layout's own pitches: a heavy
	# line is a column, a medium one is a row, a faint one is the snap step. GraphEdit's
	# built-in grid would otherwise draw a second, unrelated set of major lines over it.
	graph_edit.show_grid_buttons = false
	graph_edit.grid_minor = GRID
	graph_edit.grid_half_major = ROW_STEP
	graph_edit.grid_major = COLUMN_PITCH
	graph_edit.waypoint_changed.connect(_on_waypoint_changed)
	# audio and control are both sample streams and interconvert freely; event and note are
	# discrete and require an exact match. This is the core's rule, not a UI preference.
	graph_edit.add_valid_connection_type(SLOT_AUDIO, SLOT_CONTROL)
	graph_edit.add_valid_connection_type(SLOT_CONTROL, SLOT_AUDIO)
	graph_edit.connection_request.connect(_on_connection_request)
	graph_edit.disconnection_request.connect(_on_disconnection_request)
	graph_edit.delete_nodes_request.connect(_on_delete_nodes_request)
	graph_edit.node_selected.connect(_on_node_selected)
	graph_edit.node_selected.connect(func(_n): _refresh_selection_button())
	graph_edit.node_deselected.connect(func(_n): _refresh_selection_button())
	graph_edit.popup_request.connect(_on_graph_popup_request)
	# Node drags and cable drags bracket their own undo entries, so a drag is one step
	# rather than one per pixel of mouse movement.
	graph_edit.begin_node_move.connect(func() -> void: _begin_edit())
	graph_edit.end_node_move.connect(func() -> void: _commit_edit("move"))
	graph_edit.cable_drag_started.connect(func() -> void: _begin_edit())

	# Two views of one document, side by side in tabs rather than as a mode: the graph is
	# the honest picture of signal flow, the rack is the picture a musician already knows
	# how to read. Which one leads at Knobcon is a question to settle by watching people.
	views = TabContainer.new()
	views.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	graph_edit.name = "Graph"
	views.add_child(graph_edit)

	var rack_scroll := ScrollContainer.new()
	rack_scroll.name = "Rack"
	rack_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	rack = Rack.new()
	rack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rack.type_colours = TYPE_COLOURS
	rack.ink = INK
	rack.ink_dim = INK_DIM
	rack.parameter_changed.connect(_on_rack_parameter_changed)
	rack.edit_started.connect(func() -> void: _begin_edit())
	rack.edit_finished.connect(func(label: String) -> void: _commit_edit(label))
	rack.node_selected.connect(_on_rack_node_selected)
	rack_scroll.add_child(rack)
	views.add_child(rack_scroll)

	# A third view, and a different kind of answer: not how a patch looks, but what it is
	# for. Editing the jump patch in the Graph tab and hearing it change here, without a
	# rebuild, is the argument for shipping instructions rather than recordings.
	sandbox = Sandbox.new()
	sandbox.name = "Sandbox"
	views.add_child(sandbox)
	# Both views start on the style the toolbar says they are on. Worth knowing when
	# comparing them: dragging a cable waypoint is a PCB-mode gesture — a hanging cable
	# has no corners to grab, which is part of what is being traded.
	graph_edit.cable_style = Rack.CableStyle.CATENARY
	# The rack lays out against the width it is given, so it has to be told when the tab
	# is first shown — before that it has no size to flow modules into.
	views.tab_changed.connect(func(_index: int) -> void:
		rack.rebuild()
		if sandbox != null and sandbox.is_visible_in_tree():
			sandbox.ensure_sounds_loaded())
	split.add_child(views)

	split.add_child(_build_side_panel())

	# Under the tabs rather than inside one: the graph and the rack are two views of the
	# same running patch, and the thing that plays it belongs to neither.
	keyboard = Keyboard.new()
	keyboard.note_pressed.connect(_on_keyboard_pressed)
	keyboard.note_released.connect(_on_keyboard_released)
	root.add_child(keyboard)
	_refresh_keyboard_range()
	_build_search_popup()

	file_dialog = FileDialog.new()
	file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	file_dialog.add_filter("*.json", "SoundGraph patch")
	file_dialog.file_selected.connect(_on_file_selected)
	add_child(file_dialog)

	if _on_web():
		_install_web_file_bridge()


# Mouse-operated controls must not hold keyboard focus. The computer keyboard is the
# piano: a slider that keeps focus after a drag silently eats the next note the user
# plays, which reads as "the synth stopped working". Text fields (search, dialogs) keep
# focus because typing into them is the point.
func _defocus(control: Control) -> Control:
	control.focus_mode = Control.FOCUS_NONE
	return control


func _build_toolbar() -> Control:
	var bar := HBoxContainer.new()
	bar.custom_minimum_size.y = 44
	bar.add_theme_constant_override("separation", 8)

	var title := Label.new()
	title.text = "  SoundGraph"
	title.add_theme_font_size_override("font_size", FONT_SIZE_TITLE)
	bar.add_child(title)

	var examples := OptionButton.new()
	for name in EXAMPLES:
		examples.add_item(name)
	examples.item_selected.connect(func(index: int) -> void:
		_load_example(examples.get_item_text(index)))
	bar.add_child(_defocus(examples))

	var add_button := Button.new()
	add_button.text = "Add node…"
	add_button.tooltip_text = "Search by what you want, not only by name (Ctrl+Space)"
	add_button.pressed.connect(_open_search)
	bar.add_child(_defocus(add_button))

	var arrange := Button.new()
	arrange.text = "Auto-place"
	arrange.tooltip_text = "Lay the whole graph out left to right. The same patch always " \
		+ "lands the same way, wherever things were before."
	arrange.pressed.connect(_auto_place)
	bar.add_child(_defocus(arrange))

	arrange_selection_button = Button.new()
	arrange_selection_button.text = "Arrange selection"
	arrange_selection_button.tooltip_text = "Arrange only the selected nodes, leaving the " \
		+ "rest where they are"
	arrange_selection_button.disabled = true
	arrange_selection_button.pressed.connect(_arrange_selection)
	bar.add_child(_defocus(arrange_selection_button))

	# Visible buttons as well as the shortcut: an undo you cannot see is an undo a first
	# time user does not know they have.
	undo_button = Button.new()
	undo_button.text = "Undo"
	undo_button.disabled = true
	undo_button.pressed.connect(_undo)
	bar.add_child(_defocus(undo_button))

	redo_button = Button.new()
	redo_button.text = "Redo"
	redo_button.disabled = true
	redo_button.pressed.connect(_redo)
	bar.add_child(_defocus(redo_button))

	var open_button := Button.new()
	open_button.text = "Open…"
	open_button.pressed.connect(func() -> void:
		_importing_module = false
		if _on_web():
			_web_open()
			return
		file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		file_dialog.title = "Open patch"
		file_dialog.popup_centered_ratio(0.6))
	bar.add_child(_defocus(open_button))

	var import_button := Button.new()
	import_button.text = "Add module…"
	import_button.tooltip_text = "Add an existing patch into this one. Its nodes are " 		+ "copied in with their names prefixed; its own inputs and outputs are left out, " 		+ "because those belong to a finished patch rather than to a module."
	import_button.pressed.connect(func() -> void:
		_importing_module = true
		if _on_web():
			_web_open()
			return
		file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		file_dialog.title = "Add a patch as a module"
		file_dialog.popup_centered_ratio(0.6))
	bar.add_child(_defocus(import_button))

	var save_button := Button.new()
	save_button.text = "Save as…"
	save_button.pressed.connect(func() -> void:
		_importing_module = false
		if _on_web():
			_web_save()
			return
		file_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
		file_dialog.title = "Save patch"
		file_dialog.current_file = "patch.json"
		file_dialog.popup_centered_ratio(0.6))
	bar.add_child(_defocus(save_button))

	# The A/B. Both views honour it, so the comparison is between two ways of drawing a
	# cable rather than between two views that happen to draw them differently.
	var cables := OptionButton.new()
	cables.add_item("Catenary")
	cables.add_item("PCB")
	cables.selected = 0
	cables.tooltip_text = "How patch cables are drawn: hanging under their own weight, " \
		+ "or routed at right angles around what is in the way"
	cables.item_selected.connect(func(index: int) -> void:
		rack.cable_style = index
		graph_edit.cable_style = index
		graph_edit.refresh_cables())
	bar.add_child(_defocus(cables))

	# How wide the rack's case is. Filling the window is the default — the window is the
	# case — but a patch built to fit 84 or 104 HP is one that would fit real hardware.
	var case_width := OptionButton.new()
	case_width.add_item("Case: fit window")
	case_width.add_item("Case: 84 HP")
	case_width.add_item("Case: 104 HP")
	case_width.add_item("Case: 168 HP")
	case_width.selected = 0
	case_width.tooltip_text = "How wide the rack is. HP is the Eurorack width unit; a " \
		+ "typical case is 84 or 104 of them."
	const CASE_WIDTHS := [0, 84, 104, 168]
	case_width.item_selected.connect(func(index: int) -> void:
		rack.case_hp = CASE_WIDTHS[index])
	bar.add_child(_defocus(case_width))

	# One-shot patches — the game sounds, anything gated by a constant — fire on the first
	# sample and are then silent forever. The keyboard cannot retrigger them because they
	# have no NoteInput to send a note to, so without this an opened coin sound plays once
	# on load and can never be heard again while you edit it.
	var retrigger := Button.new()
	retrigger.text = "Fire"
	retrigger.tooltip_text = "Play a one-shot patch again from the start. Does nothing " 		+ "audible to a patch that waits for notes."
	retrigger.pressed.connect(func() -> void:
		if engine == null or not engine.is_loaded():
			return
		# Both, because there are two kinds of one-shot. A patch gated by a NoteInput needs
		# a note; a patch gated by a constant needs the graph put back to its start. Doing
		# one and not the other made the button work for half the examples.
		engine.reset()
		_let_go_note(60)
		_hold_note(60)
		status_label.text = "fired")
	bar.add_child(_defocus(retrigger))

	var panic := Button.new()
	panic.text = "All notes off"
	panic.pressed.connect(func() -> void:
		engine.all_notes_off()
		held_notes.clear()
		if keyboard != null:
			keyboard.set_held_notes(held_notes))
	bar.add_child(_defocus(panic))

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(spacer)

	document_label = Label.new()
	document_label.text = document_name
	document_label.add_theme_color_override("font_color", ACCENT)
	bar.add_child(document_label)

	var separator := Label.new()
	separator.text = "·"
	separator.add_theme_color_override("font_color", INK_DIM)
	bar.add_child(separator)

	status_label = Label.new()
	status_label.text = "starting…"
	bar.add_child(status_label)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_right", 12)
	bar.add_child(margin)
	return bar


func _build_side_panel() -> Control:
	var panel := VBoxContainer.new()
	panel.custom_minimum_size.x = 380
	panel.add_theme_constant_override("separation", 6)

	panel.add_child(_section_heading("Signal"))
	scope = Scope.new()
	scope.custom_minimum_size.y = 130
	panel.add_child(scope)

	var hint := Label.new()
	hint.text = "Select a node to see what it is putting out."
	hint.add_theme_font_size_override("font_size", FONT_SIZE_SMALL)
	hint.modulate = INK_DIM
	panel.add_child(hint)

	panel.add_child(_section_heading("Problems"))
	var diagnostics_scroll := ScrollContainer.new()
	diagnostics_scroll.custom_minimum_size.y = 180
	diagnostics_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	diagnostics_list = VBoxContainer.new()
	diagnostics_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	diagnostics_scroll.add_child(diagnostics_list)
	panel.add_child(diagnostics_scroll)

	panel.add_child(_section_heading("What the graph is doing"))
	info_label = RichTextLabel.new()
	info_label.bbcode_enabled = true
	info_label.fit_content = true
	info_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(info_label)

	var keys := Label.new()
	keys.text = "Play with A W S E D F T G Y H U J K. Z and X shift octave."
	keys.add_theme_font_size_override("font_size", FONT_SIZE_SMALL)
	keys.modulate = INK_DIM
	keys.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	panel.add_child(keys)

	return panel


func _section_heading(text: String) -> Label:
	var label := Label.new()
	label.text = text.to_upper()
	label.add_theme_font_size_override("font_size", FONT_SIZE_HEADING)
	label.modulate = INK_DIM
	return label


# ---------------------------------------------------------------------------------
# Audio
# ---------------------------------------------------------------------------------

func _start_audio() -> void:
	var generator := AudioStreamGenerator.new()
	generator.mix_rate = 48000.0
	generator.buffer_length = 0.1

	player = AudioStreamPlayer.new()
	player.stream = generator
	# Godot defaults web playback to *sample* mode, which pre-bakes a stream into a buffer
	# and cannot work for a generator whose samples do not exist until they are asked for.
	# The symptom is a warning — "trying to play a sample from a stream that cannot be
	# sampled" — and silence, on the web only. Every desktop build sounds fine, which is
	# what made this survive so long.
	player.playback_type = AudioServer.PLAYBACK_TYPE_STREAM
	add_child(player)
	player.play()
	playback = player.get_stream_playback()


func _process(_delta: float) -> void:
	if engine == null or playback == null:
		return
	if engine.is_loaded():
		engine.fill_playback(playback, playback.get_frames_available())
	_update_scope()


func _update_scope() -> void:
	if scope == null:
		return
	if inspecting.is_empty():
		scope.show_samples(engine.get_scope(1024), "master output")
		return
	var signal_samples: PackedFloat32Array = engine.get_port_signal(
		inspecting["node"], inspecting["port"])
	scope.show_samples(signal_samples, "%s.%s" % [inspecting["node"], inspecting["port"]])


# ---------------------------------------------------------------------------------
# Building the graph view from the registry
# ---------------------------------------------------------------------------------

func _slot_type(signal_type: String) -> int:
	match signal_type:
		"audio": return SLOT_AUDIO
		"control": return SLOT_CONTROL
		"event": return SLOT_EVENT
		_: return SLOT_NOTE


func _rebuild_view() -> void:
	graph_edit.clear_connections()
	for child in graph_edit.get_children():
		if child is GraphNode:
			# Removed before freeing, not just queued: a queued node keeps its name until
			# the end of the frame, and a new node claiming that name would be renamed out
			# from under the id mapping.
			graph_edit.remove_child(child)
			child.queue_free()
	widgets.clear()
	ids.clear()
	parameter_widgets.clear()

	for node in patch.get("nodes", []):
		_create_widget(node)

	# Connections are added after every node exists, since both endpoints must be present.
	await get_tree().process_frame
	for connection in patch.get("connections", []):
		var from_id: String = connection["from"]["node"]
		var to_id: String = connection["to"]["node"]
		if not widgets.has(from_id) or not widgets.has(to_id):
			continue
		var from_port := _output_port_index(from_id, connection["from"]["port"])
		var to_port := _input_port_index(to_id, connection["to"]["port"])
		if from_port < 0 or to_port < 0:
			continue
		graph_edit.connect_node(widgets[from_id].name, from_port, widgets[to_id].name, to_port)

	_restore_waypoints()

	# The rack reads the same document, so it is rebuilt from the same place rather than
	# kept in step by hand.
	if rack != null:
		rack.registry = registry
		rack.patch = patch
		rack.rebuild()


func _create_widget(node: Dictionary) -> void:
	var type_name: String = node["type"]
	var descriptor: Dictionary = registry.get(type_name, {})

	var widget := GraphNode.new()
	# Patch ids allow characters Godot node names do not, so the mapping is kept
	# explicitly rather than assuming the two naming schemes agree.
	widget.name = "n%d" % widgets.size()
	widget.title = node.get("name", "") if node.get("name", "") != "" else \
		descriptor.get("display_name", type_name)
	widget.tooltip_text = descriptor.get("summary", "")
	widget.position_offset = Vector2(
		node.get("position", {}).get("x", 0.0),
		node.get("position", {}).get("y", 0.0))
	widget.set_meta("patch_id", node["id"])
	widget.set_meta("type", type_name)

	var inputs: Array = descriptor.get("inputs", [])
	var outputs: Array = descriptor.get("outputs", [])

	# One row per port pair. The port name and its unit are written out, so the type is
	# never carried by colour alone.
	var rows: int = maxi(inputs.size(), outputs.size())
	for row in rows:
		var line := HBoxContainer.new()
		var left := Label.new()
		left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if row < inputs.size():
			left.text = _port_caption(inputs[row])
			if inputs[row].get("required", false):
				left.tooltip_text = "Required. " + str(inputs[row].get("doc", ""))
			else:
				left.tooltip_text = str(inputs[row].get("doc", ""))
		line.add_child(left)

		var right := Label.new()
		right.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if row < outputs.size():
			right.text = _port_caption(outputs[row])
			right.tooltip_text = str(outputs[row].get("doc", ""))
		line.add_child(right)
		widget.add_child(line)

		var has_input := row < inputs.size()
		var has_output := row < outputs.size()
		widget.set_slot(row,
			has_input, _slot_type(inputs[row]["type"]) if has_input else 0,
			TYPE_COLOURS.get(inputs[row]["type"], Color.WHITE) if has_input else Color.WHITE,
			has_output, _slot_type(outputs[row]["type"]) if has_output else 0,
			TYPE_COLOURS.get(outputs[row]["type"], Color.WHITE) if has_output else Color.WHITE)

	_add_parameter_rows(widget, node, descriptor)

	graph_edit.add_child(widget)
	widgets[node["id"]] = widget
	ids[widget.name] = node["id"]


func _port_caption(port: Dictionary) -> String:
	var unit: String = port.get("unit", "")
	if unit != "":
		return "%s  (%s)" % [port["name"], unit]
	return str(port["name"])


func _add_parameter_rows(widget: GraphNode, node: Dictionary, descriptor: Dictionary) -> void:
	var parameters: Array = descriptor.get("parameters", [])
	if parameters.is_empty():
		return

	# Progressive complexity: a node shows its common case, and says how much it is
	# holding back rather than hiding it silently.
	var always_visible: int = 2 if parameters.size() > 3 else parameters.size()
	var extra: Array[Control] = []

	for index in parameters.size():
		var row := _build_parameter_row(node, parameters[index])
		widget.add_child(row)
		if index >= always_visible:
			row.visible = false
			extra.append(row)

	if extra.is_empty():
		return

	var toggle := CheckButton.new()
	toggle.text = "%d more" % extra.size()
	toggle.add_theme_font_size_override("font_size", FONT_SIZE_SMALL)
	toggle.toggled.connect(func(pressed: bool) -> void:
		for row in extra:
			row.visible = pressed
		toggle.text = "fewer" if pressed else "%d more" % extra.size())
	widget.add_child(_defocus(toggle))


func _build_parameter_row(node: Dictionary, parameter: Dictionary) -> Control:
	var row := HBoxContainer.new()
	var name: String = parameter["name"]
	var node_id: String = node["id"]
	var current: float = float(node.get("parameters", {}).get(name, parameter["default"]))

	var label := Label.new()
	label.text = name
	label.custom_minimum_size.x = 92
	label.tooltip_text = str(parameter.get("doc", ""))
	label.add_theme_font_size_override("font_size", FONT_SIZE_SMALL)
	row.add_child(label)

	if parameter.has("enum"):
		var options := OptionButton.new()
		for entry in parameter["enum"]:
			options.add_item(str(entry))
		options.selected = clampi(int(round(current)), 0, parameter["enum"].size() - 1)
		options.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		options.item_selected.connect(func(index: int) -> void:
			_begin_edit()
			_set_parameter(node_id, name, float(index))
			_commit_edit("set %s" % name))
		row.add_child(_defocus(options))
		_remember_parameter_widget(node_id, name, options, null, parameter)
		return row

	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.0001
	slider.value = _to_position(parameter, current)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size.x = 110

	var readout := Label.new()
	readout.text = _format_value(current)
	readout.custom_minimum_size.x = 62
	readout.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	readout.add_theme_font_size_override("font_size", FONT_SIZE_SMALL)

	slider.value_changed.connect(func(position: float) -> void:
		var value := _to_value(parameter, position)
		readout.text = _format_value(value)
		_set_parameter(node_id, name, value))

	# A whole drag is one undo step. Bracketing on the drag rather than on each value
	# change is what stops a single sweep of a knob from filling the history.
	slider.drag_started.connect(func() -> void: _begin_edit())
	slider.drag_ended.connect(func(changed: bool) -> void:
		if changed:
			_commit_edit("set %s" % name)
		else:
			_pending_snapshot = {})

	row.add_child(_defocus(slider))
	row.add_child(readout)
	_remember_parameter_widget(node_id, name, slider, readout, parameter)
	return row


func _remember_parameter_widget(node_id: String, parameter_name: String, control: Control,
		readout: Label, descriptor: Dictionary) -> void:
	if not parameter_widgets.has(node_id):
		parameter_widgets[node_id] = {}
	parameter_widgets[node_id][parameter_name] = {
		"slider": control, "readout": readout, "descriptor": descriptor,
	}


# Parameter scaling, taken from the descriptor the core publishes rather than guessed at.
func _to_value(parameter: Dictionary, position: float) -> float:
	var low: float = parameter["min"]
	var high: float = parameter["max"]
	match parameter.get("scaling", "linear"):
		"exponential":
			if low > 0.0 and high > 0.0:
				return low * pow(high / low, position)
		"logarithmic":
			return low + (high - low) * position * position
	return low + (high - low) * position


func _to_position(parameter: Dictionary, value: float) -> float:
	var low: float = parameter["min"]
	var high: float = parameter["max"]
	if is_equal_approx(low, high):
		return 0.0
	match parameter.get("scaling", "linear"):
		"exponential":
			if low > 0.0 and high > 0.0 and value > 0.0:
				return clampf(log(value / low) / log(high / low), 0.0, 1.0)
		"logarithmic":
			return clampf(sqrt(maxf(0.0, (value - low) / (high - low))), 0.0, 1.0)
	return clampf((value - low) / (high - low), 0.0, 1.0)


func _format_value(value: float) -> String:
	var magnitude := absf(value)
	if magnitude >= 1000.0:
		return "%.0f" % value
	if magnitude >= 10.0:
		return "%.1f" % value
	if magnitude >= 1.0:
		return "%.2f" % value
	return "%.3f" % value


# ---------------------------------------------------------------------------------
# Editing
# ---------------------------------------------------------------------------------

## Moving a knob must not rebuild the graph — it sets the value on the running engine and
## records it in the document. Rebuilding would interrupt the sound, which is exactly what
## "patching should feel immediate" rules out.
func _set_parameter(node_id: String, parameter: String, value: float) -> void:
	engine.set_parameter(node_id, parameter, value)
	for node in patch.get("nodes", []):
		if node["id"] == node_id:
			if not node.has("parameters"):
				node["parameters"] = {}
			node["parameters"][parameter] = value
			return


func _port_list(node_id: String, key: String) -> Array:
	if not widgets.has(node_id):
		return []
	var type_name: String = widgets[node_id].get_meta("type")
	return registry.get(type_name, {}).get(key, [])


func _input_port_index(node_id: String, port: String) -> int:
	var ports := _port_list(node_id, "inputs")
	for index in ports.size():
		if ports[index]["name"] == port:
			return index
	return -1


func _output_port_index(node_id: String, port: String) -> int:
	var ports := _port_list(node_id, "outputs")
	for index in ports.size():
		if ports[index]["name"] == port:
			return index
	return -1


func _on_connection_request(from_node: StringName, from_port: int, to_node: StringName,
		to_port: int) -> void:
	var from_id: String = ids.get(from_node, "")
	var to_id: String = ids.get(to_node, "")
	if from_id == "" or to_id == "":
		return

	var from_ports := _port_list(from_id, "outputs")
	var to_ports := _port_list(to_id, "inputs")
	if from_port >= from_ports.size() or to_port >= to_ports.size():
		return

	_begin_edit()
	patch["connections"].append({
		"from": {"node": from_id, "port": from_ports[from_port]["name"]},
		"to": {"node": to_id, "port": to_ports[to_port]["name"]},
	})
	graph_edit.connect_node(from_node, from_port, to_node, to_port)
	_apply()
	_commit_edit("connect")


func _on_disconnection_request(from_node: StringName, from_port: int, to_node: StringName,
		to_port: int) -> void:
	var from_id: String = ids.get(from_node, "")
	var to_id: String = ids.get(to_node, "")
	var from_ports := _port_list(from_id, "outputs")
	var to_ports := _port_list(to_id, "inputs")
	if from_port >= from_ports.size() or to_port >= to_ports.size():
		return

	_begin_edit()
	var from_name: String = from_ports[from_port]["name"]
	var to_name: String = to_ports[to_port]["name"]
	var remaining := []
	for connection in patch["connections"]:
		var matches: bool = connection["from"]["node"] == from_id \
			and connection["from"]["port"] == from_name \
			and connection["to"]["node"] == to_id \
			and connection["to"]["port"] == to_name
		if not matches:
			remaining.append(connection)
	patch["connections"] = remaining

	graph_edit.disconnect_node(from_node, from_port, to_node, to_port)
	_apply()
	_commit_edit("disconnect")


func _on_delete_nodes_request(nodes: Array[StringName]) -> void:
	_begin_edit()
	for godot_name in nodes:
		var node_id: String = ids.get(godot_name, "")
		if node_id == "":
			continue
		var kept_nodes := []
		for node in patch["nodes"]:
			if node["id"] != node_id:
				kept_nodes.append(node)
		patch["nodes"] = kept_nodes

		var kept_connections := []
		for connection in patch["connections"]:
			if connection["from"]["node"] != node_id and connection["to"]["node"] != node_id:
				kept_connections.append(connection)
		patch["connections"] = kept_connections

		# Control surfaces and automation point at parameters; a deleted node takes them
		# with it, or the patch would fail validation on the next load.
		patch["controls"] = _without_target(patch.get("controls", []), node_id)
		patch["automation"] = _without_target(patch.get("automation", []), node_id)

	inspecting = {}
	await _rebuild_view()
	_apply()
	_commit_edit("delete" if nodes.size() == 1 else "delete %d nodes" % nodes.size())


func _without_target(entries: Array, node_id: String) -> Array:
	var kept := []
	for entry in entries:
		if entry.get("target", {}).get("node", "") != node_id:
			kept.append(entry)
	return kept


func _on_node_selected(node: Node) -> void:
	var node_id: String = ids.get(node.name, "")
	var outputs := _port_list(node_id, "outputs")
	if node_id == "" or outputs.is_empty():
		inspecting = {}
		return
	inspecting = {"node": node_id, "port": outputs[0]["name"]}


## A knob in the rack and a slider in the graph are two handles on one value. The edit goes
## through the same path either way; the other view is then told what to show, so the two
## cannot drift apart while both are open.
func _on_rack_parameter_changed(node_id: String, parameter: String, value: float) -> void:
	_set_parameter(node_id, parameter, value)
	var entry: Dictionary = parameter_widgets.get(node_id, {}).get(parameter, {})
	if entry.is_empty():
		return
	var control: Control = entry["slider"]
	if control is HSlider:
		# set_value_no_signal, or the slider's own handler would write the value back and
		# the two would fight over every drag.
		control.set_value_no_signal(_to_position(entry["descriptor"], value))
	elif control is OptionButton:
		control.selected = int(round(value))
	var readout: Label = entry["readout"]
	if readout != null:
		readout.text = _format_value(value)


func _on_rack_node_selected(node_id: String) -> void:
	var outputs := _port_list(node_id, "outputs")
	inspecting = {"node": node_id, "port": outputs[0]["name"]} if not outputs.is_empty() \
		else {}


func _on_keyboard_pressed(note: int) -> void:
	_hold_note(note)


func _on_keyboard_released(note: int) -> void:
	_let_go_note(note)


## Every note goes through these two, whether a mouse or a computer key started it. The
## on-screen keyboard lights up from held_notes rather than from its own clicks, so what
## you see is what the engine was actually told.
func _hold_note(note: int) -> void:
	if engine == null or held_notes.has(note):
		return
	held_notes[note] = true
	engine.note_on(note, 0.9)
	if keyboard != null:
		keyboard.set_held_notes(held_notes)


func _let_go_note(note: int) -> void:
	if engine == null or not held_notes.has(note):
		return
	held_notes.erase(note)
	engine.note_off(note)
	if keyboard != null:
		keyboard.set_held_notes(held_notes)


## The keyboard shows the octave the computer keys are playing, plus one above it, with the
## mapped keys lettered on the keys themselves.
func _refresh_keyboard_range() -> void:
	if keyboard == null:
		return
	var base: int = octave * 12 + 12
	var labels := {}
	for keycode in KEY_NOTES:
		labels[base + KEY_NOTES[keycode]] = OS.get_keycode_string(keycode)
	keyboard.key_labels = labels
	keyboard.set_range(base, 2)


## Names the open document. Called from every route in — the file dialog, the browser's
## file input, the examples menu — so the label cannot go stale by one of them forgetting.
func _set_document_name(name: String) -> void:
	document_name = name if not name.is_empty() else "untitled"
	if document_label != null:
		document_label.text = document_name


func _on_graph_popup_request(at_position: Vector2) -> void:
	_open_search(at_position)


# ---------------------------------------------------------------------------------
# Adding nodes, by intent
# ---------------------------------------------------------------------------------

func _build_search_popup() -> void:
	search_popup = PopupPanel.new()
	search_popup.size = Vector2i(560, 420)

	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	search_field = LineEdit.new()
	search_field.placeholder_text = "What do you want to do?  e.g. \"remove high frequencies\""
	search_field.text_changed.connect(_on_search_changed)
	search_field.text_submitted.connect(func(_text: String) -> void: _add_first_result())
	box.add_child(search_field)

	# A list of rows rather than an ItemList: every result carries its own Add button.
	# Relying on double-click alone hid the one action the dialog exists for.
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	search_results = VBoxContainer.new()
	search_results.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(search_results)
	box.add_child(scroll)

	search_hint = Label.new()
	search_hint.text = "Enter adds the top result. The dialog stays open so you can add several."
	search_hint.add_theme_font_size_override("font_size", FONT_SIZE_SMALL)
	search_hint.modulate = INK_DIM
	box.add_child(search_hint)

	search_popup.add_child(box)
	add_child(search_popup)


func _build_result_row(type_name: String) -> Control:
	var descriptor: Dictionary = registry.get(type_name, {})

	var row := PanelContainer.new()
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 10)

	var text := VBoxContainer.new()
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var title := Label.new()
	title.text = descriptor.get("display_name", type_name)
	text.add_child(title)

	var summary := Label.new()
	summary.text = descriptor.get("summary", "")
	summary.add_theme_font_size_override("font_size", FONT_SIZE_SMALL)
	summary.modulate = INK_DIM
	summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	summary.custom_minimum_size.x = 380
	text.add_child(summary)

	line.add_child(text)

	var add := Button.new()
	add.text = "Add"
	add.custom_minimum_size = Vector2(72, 40)
	add.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	add.tooltip_text = "Add a %s to the patch" % descriptor.get("display_name", type_name)
	add.pressed.connect(func() -> void: _add_from_search(type_name))
	line.add_child(_defocus(add))

	row.add_child(line)
	return row


var _search_spawn := Vector2.ZERO
var _search_top_result := ""
var _added_since_open := 0


func _open_search(at_position: Vector2 = Vector2(120, 120)) -> void:
	_search_spawn = at_position
	_added_since_open = 0
	search_field.text = ""
	_on_search_changed("")
	search_popup.popup_centered()
	search_field.grab_focus()


func _on_search_changed(query: String) -> void:
	for child in search_results.get_children():
		search_results.remove_child(child)
		child.queue_free()

	# The ranking is the core's, so "make quieter" finds the same node here, in the
	# browser, and on the command line.
	var names: PackedStringArray = engine.search_nodes(query) if query.strip_edges() != "" \
		else PackedStringArray(registry.keys())

	_search_top_result = names[0] if names.size() > 0 else ""
	for type_name in names:
		search_results.add_child(_build_result_row(type_name))

	if names.is_empty():
		var empty := Label.new()
		empty.text = "Nothing matches that. Try what you want to do — \"echo\", \"make quieter\"."
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		empty.modulate = INK_DIM
		search_results.add_child(empty)


func _add_first_result() -> void:
	if _search_top_result != "":
		_add_from_search(_search_top_result)


## Adds a node and keeps the dialog open — building a patch usually means adding several,
## and reopening the search for each one is the slow way to do it.
func _add_from_search(type_name: String) -> void:
	# Fan successive additions down the grid so they do not land on top of each other.
	var spawn := (_search_spawn + graph_edit.scroll_offset) / graph_edit.zoom
	spawn += Vector2(0.0, _added_since_open * GRID * 4.0)
	_added_since_open += 1

	var node_id := await _add_node(type_name, spawn)
	search_hint.text = "Added %s. Keep going, or press Escape when you are done." % node_id


func _add_node(type_name: String, at_position: Vector2) -> String:
	_begin_edit()
	var descriptor: Dictionary = registry.get(type_name, {})
	var base: String = type_name.to_snake_case()
	var suffix := 1
	var node_id := base
	var existing := {}
	for node in patch.get("nodes", []):
		existing[node["id"]] = true
	while existing.has(node_id):
		suffix += 1
		node_id = "%s%d" % [base, suffix]

	# Registry defaults, so a freshly dropped node does something sensible immediately.
	var parameters := {}
	for parameter in descriptor.get("parameters", []):
		parameters[parameter["name"]] = parameter["default"]

	patch["nodes"].append({
		"id": node_id,
		"type": type_name,
		"parameters": parameters,
		"position": {
			"x": snappedf(at_position.x, GRID),
			"y": snappedf(at_position.y, GRID),
		},
	})
	await _rebuild_view()
	_apply()
	_commit_edit("add %s" % registry.get(type_name, {}).get("display_name", type_name))
	return node_id


# ---------------------------------------------------------------------------------
# Document
# ---------------------------------------------------------------------------------

# ---------------------------------------------------------------------------------
# Auto-place
#
# The layered layout lives in layout.gd; this gathers the graph, hands it over, and
# writes the result back. With nodes selected it arranges only those, treating everything
# else as a fixed anchor that still pulls on the result — so tidying part of a patch
# does not fight the part you already arranged.
# ---------------------------------------------------------------------------------

func _refresh_selection_button() -> void:
	if arrange_selection_button != null:
		arrange_selection_button.disabled = _selected_ids().size() < 2


func _selected_ids() -> Array:
	var selected := []
	for id in widgets:
		if widgets[id].selected:
			selected.append(id)
	return selected


## Arranges the whole graph. The result depends only on the graph — the same patch always
## lands the same way, no matter where anything happened to be first.
func _auto_place() -> void:
	var everything := []
	for node in patch.get("nodes", []):
		everything.append(node["id"])
	await _arrange(everything)


## Arranges just the selected nodes, treating the rest as fixed anchors. Kept as its own
## action rather than something Auto-place decides for you: an arrangement that silently
## changed meaning depending on what happened to still be selected — which, after a drag,
## is whatever was just dragged — is exactly what made this feel unpredictable.
func _arrange_selection() -> void:
	var selected := _selected_ids()
	if selected.size() < 2:
		status_label.text = "select two or more nodes to arrange them together"
		return
	await _arrange(selected)


func _arrange(movable: Array) -> void:
	if patch.get("nodes", []).is_empty() or movable.is_empty():
		return

	_begin_edit()

	var sizes := {}
	for node in patch["nodes"]:
		var widget: GraphNode = widgets.get(node["id"])
		sizes[node["id"]] = widget.size if widget != null else Vector2(240.0, 140.0)

	var anchors := {}
	var moving := {}
	for id in movable:
		moving[id] = true
	for node in patch["nodes"]:
		if not moving.has(node["id"]):
			anchors[node["id"]] = Vector2(
				node.get("position", {}).get("x", 0.0), node.get("position", {}).get("y", 0.0))

	# Each cable carries the weight of what it actually transports. The port's declared
	# signal type comes from the core's registry, so "the audio path" is the core's own
	# notion of audio, not a guess made here.
	var edges := []
	for connection in patch.get("connections", []):
		var from_id: String = connection["from"]["node"]
		var port_index := _output_port_index(from_id, connection["from"]["port"])
		var ports := _port_list(from_id, "outputs")
		var is_audio: bool = port_index >= 0 and port_index < ports.size() \
			and ports[port_index]["type"] == "audio"
		edges.append([from_id, connection["to"]["node"], AUDIO_PULL if is_audio else 1.0])

	var placed: Dictionary = Layout.arrange({
		"nodes": movable, "edges": edges, "sizes": sizes, "anchors": anchors,
		"grid": GRID, "column_pitch": COLUMN_PITCH,
		"column_gutter": COLUMN_GUTTER, "row_step": ROW_STEP,
	})

	# Straightening pulls nodes toward their neighbours, which routinely lands the result
	# above and left of the origin. A partial arrangement is translated back to where the
	# selection already sat, so tidying one corner does not move it across the canvas; a
	# whole-graph arrangement is normalised to the origin instead.
	var old_origin := Vector2(INF, INF)
	var new_origin := Vector2(INF, INF)
	for node in patch["nodes"]:
		if not moving.has(node["id"]) or not placed.has(node["id"]):
			continue
		old_origin.x = minf(old_origin.x, node.get("position", {}).get("x", 0.0))
		old_origin.y = minf(old_origin.y, node.get("position", {}).get("y", 0.0))
		new_origin.x = minf(new_origin.x, placed[node["id"]].x)
		new_origin.y = minf(new_origin.y, placed[node["id"]].y)

	var shift := Vector2.ZERO
	if new_origin.x < INF:
		var target: Vector2 = old_origin if not anchors.is_empty() else Vector2.ZERO
		shift = ((target - new_origin) / GRID).round() * GRID

	for node in patch["nodes"]:
		if placed.has(node["id"]):
			var point: Vector2 = placed[node["id"]] + shift
			node["position"] = {"x": point.x, "y": point.y}

	# Hand-placed cable waypoints describe a layout that no longer exists.
	for connection in patch.get("connections", []):
		if moving.has(connection["from"]["node"]) or moving.has(connection["to"]["node"]):
			connection.erase("waypoint")

	await _rebuild_view()
	_apply()
	_commit_edit("auto-place")
	status_label.text = "placed %d node%s" % [
		placed.size(), "" if placed.size() == 1 else "s"]


# ---------------------------------------------------------------------------------
# Undo
# ---------------------------------------------------------------------------------

func _snapshot() -> Dictionary:
	_capture_positions()
	return patch.duplicate(true)


## Records the start of an edit. Paired with _commit_edit; safe to call again before
## committing, which is what happens when a drag is interrupted.
func _begin_edit() -> void:
	_pending_snapshot = _snapshot()


func _commit_edit(label: String) -> void:
	if _pending_snapshot.is_empty():
		return
	var before := _pending_snapshot
	_pending_snapshot = {}
	var after := _snapshot()
	if JSON.stringify(before) == JSON.stringify(after):
		return  # a drag that went nowhere is not an edit

	undo_redo.create_action(label)
	undo_redo.add_do_method(_restore.bind(after))
	undo_redo.add_undo_method(_restore.bind(before))
	# The change is already applied; committing must not run it a second time.
	undo_redo.commit_action(false)
	_refresh_undo_buttons()


## True when two documents differ only in parameter values — the common case for a knob
## turn, and the one where rebuilding the graph would be audible.
func _differs_only_in_parameters(a: Dictionary, b: Dictionary) -> bool:
	var without_parameters := func(document: Dictionary) -> String:
		var copy: Dictionary = document.duplicate(true)
		for node in copy.get("nodes", []):
			node.erase("parameters")
		return JSON.stringify(copy)
	return without_parameters.call(a) == without_parameters.call(b)


func _restore(snapshot: Dictionary) -> void:
	var live_parameters := _differs_only_in_parameters(patch, snapshot)
	patch = snapshot.duplicate(true)

	if live_parameters:
		# Undoing a knob turn moves the knob, it does not restart the sound. Rebuilding
		# here would empty every delay line and retrigger every oscillator.
		for node in patch.get("nodes", []):
			for parameter_name in node.get("parameters", {}):
				var value: float = node["parameters"][parameter_name]
				engine.set_parameter(node["id"], parameter_name, value)
				_show_parameter(node["id"], parameter_name, value)
		status_label.text = "playing"
	else:
		_rebuild_and_apply()
	_refresh_undo_buttons()


## Not a coroutine: UndoRedo calls its actions synchronously, so the rebuild is started
## and allowed to finish on its own frames.
func _rebuild_and_apply() -> void:
	await _rebuild_view()
	_apply()


func _show_parameter(node_id: String, parameter_name: String, value: float) -> void:
	var entry: Dictionary = parameter_widgets.get(node_id, {}).get(parameter_name, {})
	if entry.is_empty():
		return
	var slider = entry.get("slider")
	var readout: Label = entry.get("readout")
	if slider is OptionButton:
		slider.selected = clampi(int(round(value)), 0, slider.item_count - 1)
		return
	if slider is HSlider:
		# set_value_no_signal, or restoring a value would look like the user turning it.
		slider.set_value_no_signal(_to_position(entry["descriptor"], value))
	if readout != null:
		readout.text = _format_value(value)


func _undo() -> void:
	if not undo_redo.has_undo():
		return
	var label := undo_redo.get_current_action_name()
	undo_redo.undo()
	status_label.text = "undid %s" % label
	_refresh_undo_buttons()


func _redo() -> void:
	if not undo_redo.has_redo():
		return
	undo_redo.redo()
	status_label.text = "redid %s" % undo_redo.get_current_action_name()
	_refresh_undo_buttons()


func _refresh_undo_buttons() -> void:
	if undo_button == null:
		return
	undo_button.disabled = not undo_redo.has_undo()
	redo_button.disabled = not undo_redo.has_redo()
	undo_button.tooltip_text = "Undo %s (Ctrl+Z)" % undo_redo.get_current_action_name() \
		if undo_redo.has_undo() else "Nothing to undo"
	redo_button.tooltip_text = "Redo (Ctrl+Shift+Z)"


# ---------------------------------------------------------------------------------
# Cable waypoints
# ---------------------------------------------------------------------------------

func _on_waypoint_changed(from_node: StringName, from_port: int, to_node: StringName,
		to_port: int, point: Variant) -> void:
	var from_id: String = ids.get(from_node, "")
	var to_id: String = ids.get(to_node, "")
	var from_ports := _port_list(from_id, "outputs")
	var to_ports := _port_list(to_id, "inputs")
	if from_port >= from_ports.size() or to_port >= to_ports.size():
		return

	for connection in patch.get("connections", []):
		if connection["from"]["node"] == from_id \
			and connection["from"]["port"] == from_ports[from_port]["name"] \
			and connection["to"]["node"] == to_id \
			and connection["to"]["port"] == to_ports[to_port]["name"]:
			if point == null:
				connection.erase("waypoint")
			else:
				connection["waypoint"] = {"x": point.x, "y": point.y}
			_commit_edit("move cable" if point != null else "straighten cable")
			return


## Pushes stored waypoints into the canvas after a load or rebuild.
func _restore_waypoints() -> void:
	graph_edit.clear_waypoints()
	for connection in patch.get("connections", []):
		if not connection.has("waypoint"):
			continue
		var from_id: String = connection["from"]["node"]
		var to_id: String = connection["to"]["node"]
		if not widgets.has(from_id) or not widgets.has(to_id):
			continue
		var from_port := _output_port_index(from_id, connection["from"]["port"])
		var to_port := _input_port_index(to_id, connection["to"]["port"])
		if from_port < 0 or to_port < 0:
			continue
		var key: String = PatchGraph.connection_key(
			widgets[from_id].name, from_port, widgets[to_id].name, to_port)
		graph_edit.set_waypoint(key, Vector2(
			connection["waypoint"].get("x", 0.0), connection["waypoint"].get("y", 0.0)))


func _capture_positions() -> void:
	for node in patch.get("nodes", []):
		if widgets.has(node["id"]):
			var offset: Vector2 = widgets[node["id"]].position_offset
			node["position"] = {"x": offset.x, "y": offset.y}


## Serialises, validates and reloads. Called for structural edits only.
func _apply() -> void:
	if suppress_reload:
		return
	_capture_positions()
	var text := JSON.stringify(patch, "  ")

	var report: Variant = JSON.parse_string(engine.validate_patch(text))
	var diagnostics: Array = report["diagnostics"] if typeof(report) == TYPE_DICTIONARY else []
	_show_diagnostics(diagnostics)

	if typeof(report) == TYPE_DICTIONARY and report["ok"]:
		engine.load_patch(text, 48000.0)
		_show_info()
		status_label.text = "playing"
	else:
		status_label.text = "patch has errors"


func _show_diagnostics(diagnostics: Array) -> void:
	for child in diagnostics_list.get_children():
		child.queue_free()

	if diagnostics.is_empty():
		var ok := Label.new()
		ok.text = "No problems."
		ok.modulate = ACCENT
		diagnostics_list.add_child(ok)
		_highlight([])
		return

	var to_highlight := []
	for diagnostic in diagnostics:
		var card := VBoxContainer.new()

		var message := Label.new()
		message.text = diagnostic["message"]
		message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		message.modulate = ERROR if diagnostic["severity"] == "error" else WARNING
		card.add_child(message)

		# Spatial, not just textual: the offending nodes are named and highlighted in the
		# graph, and clicking the problem frames them.
		if diagnostic.has("nodes"):
			for node_id in diagnostic["nodes"]:
				to_highlight.append(node_id)
			var where := Label.new()
			where.text = "  " + " → ".join(diagnostic["nodes"])
			where.add_theme_font_size_override("font_size", FONT_SIZE_SMALL)
			where.modulate = INK_DIM
			card.add_child(where)

		if diagnostic.has("suggestion"):
			var suggestion := Label.new()
			suggestion.text = diagnostic["suggestion"]
			suggestion.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			suggestion.add_theme_font_size_override("font_size", FONT_SIZE_SMALL)
			suggestion.modulate = ACCENT
			card.add_child(suggestion)

		var rule := HSeparator.new()
		card.add_child(rule)
		diagnostics_list.add_child(card)

	_highlight(to_highlight)


func _highlight(node_ids: Array) -> void:
	for id in widgets:
		var widget: GraphNode = widgets[id]
		widget.modulate = Color(1.0, 0.65, 0.6) if node_ids.has(id) else Color.WHITE


func _show_info() -> void:
	var info: Variant = JSON.parse_string(engine.get_info_json())
	if typeof(info) != TYPE_DICTIONARY:
		return

	var order := []
	for node in info["nodes"]:
		order.append(node["id"])

	var text := "[b]Runs in this order[/b]\n%s\n" % "  →  ".join(order)
	if not info["feedback"].is_empty():
		text += "\n[b]Feedback[/b]\n"
		for edge in info["feedback"]:
			text += "%s → %s [i](previous block)[/i]\n" % [edge["from"], edge["to"]]
	var cost: Dictionary = info["cost"]
	text += "\n[b]Estimated cost[/b]\ncpu %.1f units · state %d B · buffers %.1f KB\n%d nodes at %d Hz" % [
		cost["cpu"], int(cost["state_bytes"]), float(cost["heap_bytes"]) / 1024.0,
		int(info["node_count"]), int(info["sample_rate"])]
	info_label.text = text


## Where an example actually lives.
##
## The copy under res://examples is mirrored in from examples/patches by the build, which
## means it goes stale the moment a patch is edited without rebuilding the extension —
## and the editor then quietly opens an old layout while the repository has a new one.
## That is a genuinely confusing failure, so the repository copy wins whenever it is
## reachable, and res:// is the fallback for an exported build that has no repository
## around it.
func _example_path(file_name: String) -> String:
	var repository := ProjectSettings.globalize_path("res://") \
		.path_join("../examples/patches").path_join(file_name)
	if FileAccess.file_exists(repository):
		return repository
	return "res://examples/" + file_name


func _load_example(name: String) -> void:
	if not EXAMPLES.has(name):
		return
	var path := _example_path(EXAMPLES[name])
	if _importing_module:
		_importing_module = false
		var module_file := FileAccess.open(path, FileAccess.READ)
		if module_file == null:
			status_label.text = "could not read %s" % path
			return
		_import_module(module_file.get_as_text(), ModuleImport.name_from_path(path))
		return

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		status_label.text = "could not open %s" % path
		return
	_set_document_name(path.get_file())
	_load_text(file.get_as_text())


func _on_file_selected(path: String) -> void:
	if file_dialog.file_mode == FileDialog.FILE_MODE_SAVE_FILE:
		_capture_positions()
		var out := FileAccess.open(path, FileAccess.WRITE)
		if out == null:
			status_label.text = "could not write %s" % path
			return
		# Written through the core's serialiser, not Godot's: the patch format is the
		# product, and it should read the same whichever editor saved it.
		out.store_string(engine.format_patch(JSON.stringify(patch, "  ")))
		_set_document_name(path.get_file())
		status_label.text = "saved"
		return

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		status_label.text = "could not open %s" % path
		return
	_load_text(file.get_as_text())


# ---------------------------------------------------------------------------------
# Files in a browser
#
# A web export has no filesystem to show a dialog for. Opening goes through a real
# <input type="file"> so the browser's own picker appears, and saving goes through a
# download — which is what a browser considers "save as" and what a phone will do
# something sensible with.
# ---------------------------------------------------------------------------------

var _web_callback   # must outlive the call; a collected callback crashes the bridge


func _on_web() -> bool:
	return OS.has_feature("web")


func _install_web_file_bridge() -> void:
	JavaScriptBridge.eval("""
		window.soundgraphPickFile = function (callback) {
			const input = document.createElement('input');
			input.type = 'file';
			input.accept = '.json,application/json';
			input.onchange = function () {
				const file = input.files && input.files[0];
				if (!file) { return; }
				const reader = new FileReader();
				// The name as well as the contents: without it the editor cannot say what is
			// open, and in a browser there is no path to fall back on.
			reader.onload = function () { callback(String(reader.result), file.name); };
				reader.readAsText(file);
			};
			input.click();
		};
	""", true)


func _web_open() -> void:
	_web_callback = JavaScriptBridge.create_callback(_on_web_file_chosen)
	var window = JavaScriptBridge.get_interface("window")
	if window == null:
		status_label.text = "this browser did not expose a file picker"
		return
	window.soundgraphPickFile(_web_callback)


func _on_web_file_chosen(arguments: Array) -> void:
	if arguments.is_empty():
		return
	var chosen_name: String = str(arguments[1]) if arguments.size() > 1 else ""
	if _importing_module:
		_importing_module = false
		_import_module(str(arguments[0]),
			ModuleImport.name_from_path(chosen_name) if not chosen_name.is_empty() else "module")
		return
	_set_document_name(chosen_name)
	_load_text(str(arguments[0]))


## Inlines another patch into this one. Undoable like any other edit, and validated
## afterwards — an import that produces an invalid graph should say so in the same place
## every other mistake does, not in a dialog of its own.
func _import_module(text: String, module_name: String) -> void:
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		status_label.text = "that file is not a patch"
		return

	_begin_edit()
	_capture_positions()

	# Dropped in clear of what is already there, so an imported module never lands on top
	# of the existing graph.
	var lowest := 0.0
	for node in patch.get("nodes", []):
		lowest = maxf(lowest, float(node.get("position", {}).get("y", 0.0)))
	var at := Vector2(0.0, snap_up(lowest + ROW_STEP * 1.5, ROW_STEP))

	var result: ModuleImport.Result = ModuleImport.merge(patch, parsed, module_name, registry, at)
	if not result.ok():
		_pending_snapshot = {}
		status_label.text = result.error
		return

	_rebuild_view()
	_apply()
	_commit_edit("add module %s" % module_name)
	# _apply sets its own status; the import has more to say than "playing".
	status_label.text = "%s: %s" % [module_name, result.summary()]


func _web_save() -> void:
	_capture_positions()
	var text: String = engine.format_patch(JSON.stringify(patch, "  "))
	var name: String = patch.get("metadata", {}).get("name", "patch")
	var file_name := name.to_lower().replace(" ", "-") + ".json"
	JavaScriptBridge.download_buffer(text.to_utf8_buffer(), file_name, "application/json")
	_set_document_name(file_name)
	status_label.text = "downloaded %s" % file_name


func _load_text(text: String) -> void:
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		status_label.text = "that file is not a patch"
		return
	patch = parsed
	if not patch.has("nodes"):
		patch["nodes"] = []
	if not patch.has("connections"):
		patch["connections"] = []
	inspecting = {}

	# Snap whatever arrives onto the grid. A patch written by another editor, or by hand,
	# lands on arbitrary pixels, and then every alignment cue in the canvas is off by a
	# few — which reads as the grid being broken rather than the file. Only positions
	# move; nothing about the graph changes.
	var moved := 0
	for node in patch["nodes"]:
		if not node.has("position"):
			continue
		var before := Vector2(node["position"].get("x", 0.0), node["position"].get("y", 0.0))
		var after := (before / GRID).round() * GRID
		if not before.is_equal_approx(after):
			node["position"] = {"x": after.x, "y": after.y}
			moved += 1
	for connection in patch.get("connections", []):
		if connection.has("waypoint"):
			var point := Vector2(connection["waypoint"].get("x", 0.0),
				connection["waypoint"].get("y", 0.0))
			point = (point / GRID).round() * GRID
			connection["waypoint"] = {"x": point.x, "y": point.y}

	# Opening a document starts a new history. Undoing across a load would restore a
	# different patch's nodes into this one, which is never what anyone means.
	# A patch can arrive with no positions at all — anything generated, anything typed by
	# hand — and every node then lands on the origin in one unreadable stack. That is what
	# the game sounds do: the sfxr mapper writes a graph, not a drawing, and it has no
	# business inventing coordinates when the editor already has a layout engine that
	# produces better ones than a straight line would.
	#
	# "No positions" also covers the case where they are all the same, which is what a file
	# with position fields full of zeroes looks like.
	var positioned := {}
	for node in patch["nodes"]:
		if node.has("position"):
			positioned["%s,%s" % [node["position"].get("x", 0.0),
				node["position"].get("y", 0.0)]] = true
	var needs_layout: bool = patch["nodes"].size() > 1 and positioned.size() <= 1

	undo_redo.clear_history(true)
	_pending_snapshot = {}
	await _rebuild_view()

	if needs_layout:
		await _auto_place()
		# Laid out on arrival, so it is not an edit anyone should have to undo.
		undo_redo.clear_history(true)
		_pending_snapshot = {}

	_apply()
	_refresh_undo_buttons()
	if needs_layout:
		status_label.text = "arranged %d nodes — the file had no layout" % patch["nodes"].size()
	elif moved > 0:
		status_label.text = "snapped %d node%s to the grid" % [moved, "" if moved == 1 else "s"]


# ---------------------------------------------------------------------------------
# Playing
# ---------------------------------------------------------------------------------

func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or key.echo or engine == null:
		return
	if search_popup.visible:
		return
	# The sandbox uses A and D to run, which are also two of the piano keys. While it is
	# showing, the keyboard belongs to it — otherwise walking left plays a note.
	if sandbox != null and sandbox.wants_keyboard():
		return
	if key.pressed and key.keycode == KEY_SPACE and key.ctrl_pressed:
		_open_search()
		accept_event()
		return

	# Undo before the octave shortcut: Z is both, and Ctrl+Z has to win.
	if key.pressed and key.ctrl_pressed and key.keycode == KEY_Z:
		if key.shift_pressed:
			_redo()
		else:
			_undo()
		accept_event()
		return
	if key.pressed and key.ctrl_pressed and key.keycode == KEY_Y:
		_redo()
		accept_event()
		return

	if key.ctrl_pressed:
		return  # no note or octave shortcut fires with Ctrl held

	if key.pressed and key.keycode == KEY_Z:
		octave = maxi(0, octave - 1)
		_refresh_keyboard_range()
		return
	if key.pressed and key.keycode == KEY_X:
		octave = mini(7, octave + 1)
		_refresh_keyboard_range()
		return

	if not KEY_NOTES.has(key.keycode):
		return
	var note: int = octave * 12 + 12 + KEY_NOTES[key.keycode]
	if key.pressed:
		_hold_note(note)
	else:
		_let_go_note(note)
