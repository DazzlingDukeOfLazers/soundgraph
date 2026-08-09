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
## Which subfolders of examples/patches to offer, and what to call them in the menu.
##
## The list of *files* used to live here, and it was one more pair of things that had to
## agree: adding a patch meant remembering to add a line, and the twenty-three node demos
## would have meant twenty-three lines nobody would ever check. So the menu is built by
## scanning instead. This dictionary is the ordering and the labels, which is a decision;
## the contents are not.
const EXAMPLE_GROUPS := {
	"": "",
	"game": "Game",
	"nodes": "Node",
}

## Filled by _scan_examples() at startup: menu label -> path relative to examples/patches.
var _examples: Dictionary = {}

# Signal types, mapped to GraphEdit slot types so the engine's own compatibility rule is
# what the mouse enforces while dragging a wire.
const SLOT_AUDIO := 0
const SLOT_CONTROL := 1
const SLOT_EVENT := 2
const SLOT_NOTE := 3

## Signal colours live in the palette now, so a theme can adjust their luminance
## without any component learning a new meaning. Kept as a property rather than a
## constant because the palette can change while the editor is running.
var TYPE_COLOURS: Dictionary:
	get:
		return {
			"audio": Design.AUDIO, "control": Design.CONTROL,
			"event": Design.TRIGGER, "note": Design.TRIGGER,
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
## The inspector's width, and the range a person may drag it through.
##
## It was a constant, which meant 380px of the window belonged to the inspector
## whether it was showing a node's parameters or the words "Graph valid". Graph work
## wants horizontal room more than almost anything else, so this is now a setting
## with a floor, a ceiling and a way to take it to nothing at all.
const SIDE_PANEL_MIN := 280
const SIDE_PANEL_MAX := 420
const SIDE_PANEL_DEFAULT := 340
## The strip left behind when it is collapsed: just enough for the button that
## brings it back, because a panel with no way back is a panel you have lost.
const SIDE_PANEL_COLLAPSED := 36

var side_panel_width := SIDE_PANEL_DEFAULT
var side_panel_open := true

var split: HSplitContainer
var side_panel: VBoxContainer
var side_panel_body: VBoxContainer
var side_panel_toggle: Button
## Buttons carrying per-instance styles, which a theme rebuild cannot reach.
var _primary_buttons: Array[Button] = []
var _panic_buttons: Array[Button] = []

var transport_dot: TextureRect
var message_label: Label
var _message_clears_at := 0
var _problem_count := 0
var arrange_popup: PopupMenu
var view_popup: PopupMenu
var keyboard_bar: Control
var keyboard_dock: PanelContainer
var keyboard_toggle: Button
var keyboard_expanded := true
## What is open, shown so "which patch am I looking at" is never a guess.
var document_label: Label
var document_name := "untitled"
var diagnostics_list: VBoxContainer
## Round-robin state for the signal glow; see _update_port_levels().
var _level_targets: Array = []
var _level_cursor := 0

var health_label: Label
var diagnostics_heading: Label
var context_heading: Label
var context_panel: VBoxContainer
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
## How many octaves the on-screen keyboard shows. Two fits a laptop; a wide screen has
## room for a patch's whole range at once, and a small one is better off with big keys.
var keyboard_octaves := 2
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
	# Before any token is read. Static vars start empty and every colour below would
	# otherwise be whatever GDScript initialised them to.
	Settings.apply()

	# The window itself, which nothing had ever themed.
	#
	# The toolbar and the dock have no background of their own, so what shows behind
	# them is the renderer's clear colour — Godot's default mid-grey. On four dark
	# palettes that is close enough to the chrome to pass unnoticed; on Paper it is a
	# grey band across the top of a white application, which is how it was finally
	# spotted. Every palette had it.
	RenderingServer.set_default_clear_color(Design.SURFACES[Design.Surface.NODE])

	if Design.font() == null:
		push_warning("Atkinson Hyperlegible is missing; falling back to the default font")
		return

	Design.unknown_items.clear()
	var editor_theme := Theme.new()
	editor_theme.default_font = Design.font(Design.WEIGHT_REGULAR)
	editor_theme.default_font_size = Design.scale(Design.SIZE_BODY)

	# ---- type by role ---------------------------------------------------------------
	# Regular for labels, Medium for anything you operate. That single distinction does
	# more for hierarchy than any amount of colour, and it was unavailable until the
	# weight axis started working — see Design._weight_tag().
	Design.set_type(editor_theme, "Label", Design.WEIGHT_REGULAR, Design.SIZE_BODY,
		Design.INK_NORMAL)
	Design.set_type(editor_theme, "RichTextLabel", Design.WEIGHT_REGULAR, Design.SIZE_BODY,
		Design.INK_NORMAL, "default_color")
	for pressable in ["Button", "CheckButton", "CheckBox", "OptionButton", "MenuButton"]:
		Design.set_type(editor_theme, pressable, Design.WEIGHT_MEDIUM, Design.SIZE_CONTROL,
			Design.INK_NORMAL)
	Design.set_type(editor_theme, "LineEdit", Design.WEIGHT_REGULAR, Design.SIZE_CONTROL,
		Design.INK_BRIGHT)
	Design.set_type(editor_theme, "PopupMenu", Design.WEIGHT_REGULAR, Design.SIZE_BODY,
		Design.INK_NORMAL)
	Design.set_type(editor_theme, "ItemList", Design.WEIGHT_REGULAR, Design.SIZE_BODY,
		Design.INK_NORMAL)
	Design.set_type(editor_theme, "TabBar", Design.WEIGHT_MEDIUM, Design.SIZE_CONTROL,
		Design.INK_SECOND, "font_unselected_color")
	# Tabs, which had never been styled and were showing Godot's defaults. Invisible
	# against four dark palettes and a grey slab across a white one.
	var tab_selected := Design.padded_panel(Design.Surface.NODE, Design.SPACE_M,
		Design.SPACE_S, Design.RADIUS_BUTTON)
	tab_selected.corner_radius_bottom_left = 0
	tab_selected.corner_radius_bottom_right = 0
	Design.set_box(editor_theme, "tab_selected", "TabBar", tab_selected)
	Design.set_box(editor_theme, "tab_focus", "TabBar", Design.focus_ring(Design.FOCUS))
	var tab_quiet := tab_selected.duplicate() as StyleBoxFlat
	tab_quiet.bg_color = Design.SURFACES[Design.Surface.CANVAS]
	tab_quiet.border_color = Design.SURFACES[Design.Surface.CANVAS]
	Design.set_box(editor_theme, "tab_unselected", "TabBar", tab_quiet)
	var tab_hover := tab_quiet.duplicate() as StyleBoxFlat
	tab_hover.bg_color = Design.SURFACES[Design.Surface.RAISED]
	Design.set_box(editor_theme, "tab_hovered", "TabBar", tab_hover)
	Design.set_box(editor_theme, "panel", "TabContainer",
		Design.panel(Design.Surface.CANVAS, 0, 0))
	Design.set_box(editor_theme, "tabbar_background", "TabContainer",
		Design.panel(Design.Surface.CANVAS, 0, 0))
	Design.set_colour(editor_theme, "font_selected_color", "TabBar", Design.INK_BRIGHT)
	Design.set_colour(editor_theme, "font_hovered_color", "TabBar", Design.INK_NORMAL)
	Design.set_colour(editor_theme, "font_placeholder_color", "LineEdit", Design.INK_SECOND)
	Design.set_colour(editor_theme, "font_disabled_color", "Button", Design.INK_DISABLED)
	Design.set_colour(editor_theme, "font_hover_color", "Button", Design.INK_BRIGHT)
	Design.set_constant(editor_theme, "outline_size", "Label", 0)

	# ---- surfaces -------------------------------------------------------------------
	Design.set_box(editor_theme, "panel", "PanelContainer",
		Design.panel(Design.Surface.NODE))
	Design.set_box(editor_theme, "panel", "Panel", Design.panel(Design.Surface.NODE))

	# A button is a raised thing you press into the active level. Three states, each a
	# real step, plus a focus ring that is its own state rather than a recoloured hover —
	# keyboard focus has to be visible on its own terms.
	Design.set_box(editor_theme, "normal", "Button",
		Design.padded_panel(Design.Surface.RAISED, Design.SPACE_M, Design.SPACE_S,
			Design.RADIUS_BUTTON, true))
	var hovered := Design.padded_panel(Design.Surface.ACTIVE, Design.SPACE_M,
		Design.SPACE_S, Design.RADIUS_BUTTON, true)
	Design.set_box(editor_theme, "hover", "Button", hovered)
	var pressed := Design.padded_panel(Design.Surface.ACTIVE, Design.SPACE_M,
		Design.SPACE_S, Design.RADIUS_BUTTON, true)
	pressed.border_color = Design.ACCENT
	Design.set_box(editor_theme, "pressed", "Button", pressed)
	var disabled := Design.padded_panel(Design.Surface.NODE, Design.SPACE_M,
		Design.SPACE_S, Design.RADIUS_BUTTON)
	Design.set_box(editor_theme, "disabled", "Button", disabled)
	Design.set_box(editor_theme, "focus", "Button", Design.focus_ring())
	Design.set_box(editor_theme, "focus", "LineEdit", Design.focus_ring())
	Design.set_box(editor_theme, "normal", "LineEdit",
		Design.padded_panel(Design.Surface.CANVAS, Design.SPACE_M, Design.SPACE_S,
			Design.RADIUS_BUTTON, true))
	Design.set_box(editor_theme, "panel", "PopupMenu",
		Design.padded_panel(Design.Surface.RAISED, Design.SPACE_S, Design.SPACE_S))

	# ---- nodes ----------------------------------------------------------------------
	# A node is one level above the canvas and its header one above that, so the header
	# reads as part of the node rather than as a window title bar bolted to it.
	var node_body := Design.padded_panel(Design.Surface.NODE, Design.NODE_PADDING_H,
		Design.NODE_PADDING_V, Design.RADIUS_NODE)
	node_body.border_width_top = 0
	Design.set_box(editor_theme, "panel", "GraphNode", node_body)
	var node_head := Design.padded_panel(Design.Surface.RAISED, Design.NODE_PADDING_H,
		Design.SPACE_S, Design.RADIUS_NODE)
	node_head.corner_radius_bottom_left = 0
	node_head.corner_radius_bottom_right = 0
	node_head.border_width_bottom = 0
	Design.set_box(editor_theme, "titlebar", "GraphNode", node_head)

	# Selection is meant to be findable from peripheral vision: a 2px accent outline on
	# both halves, and the whole node lifted a level. One of those alone reads as a
	# hover; together they read as "this is the one".
	var selected_body := node_body.duplicate() as StyleBoxFlat
	selected_body.bg_color = Design.SURFACES[Design.Surface.RAISED]
	selected_body.set_border_width_all(2)
	selected_body.border_width_top = 0
	selected_body.border_color = Design.ACCENT
	Design.set_box(editor_theme, "panel_selected", "GraphNode", selected_body)
	var selected_head := node_head.duplicate() as StyleBoxFlat
	selected_head.bg_color = Design.SURFACES[Design.Surface.ACTIVE]
	selected_head.set_border_width_all(2)
	selected_head.border_width_bottom = 0
	selected_head.border_color = Design.ACCENT
	Design.set_box(editor_theme, "titlebar_selected", "GraphNode", selected_head)

	# GraphNode has no title colour or title font in the theme at all — the title is a
	# plain Label inside the titlebar, so it is styled per node in _style_node_title().
	# The previous code set "title_color" here and it had never done anything, which is
	# the same silent-ignore this guard exists to catch.
	Design.set_constant(editor_theme, "separation", "GraphNode", Design.SPACE_S)

	# ---- canvas ---------------------------------------------------------------------
	# The grid was competing with the node borders and the cables. Minor lines are now
	# barely there and major lines only just present: invisible while you read a node,
	# and enough to align against the moment you start moving one.
	Design.set_colour(editor_theme, "grid_minor", "GraphEdit", Color("1a1d22"))
	Design.set_colour(editor_theme, "grid_major", "GraphEdit", Color("222630"))
	Design.set_colour(editor_theme, "activity", "GraphEdit", Design.ACCENT)
	# While a cable is being dragged, GraphEdit tints the ports it could legally land
	# on — but only if the theme says what that looks like, and at the default it is
	# close enough to nothing that the answer to "can this go here" was still to let go
	# and find out. Accent for a legal target, error for the cable's own end.
	Design.set_colour(editor_theme, "connection_valid_target_tint_color", "GraphEdit",
		Design.ACCENT)
	Design.set_colour(editor_theme, "connection_hover_tint_color", "GraphEdit",
		Design.INK_BRIGHT)
	Design.set_colour(editor_theme, "connection_rim_color", "GraphEdit",
		Design.SURFACES[Design.Surface.CANVAS])
	Design.set_colour(editor_theme, "selection_fill", "GraphEdit",
		Color(Design.ACCENT.r, Design.ACCENT.g, Design.ACCENT.b, 0.10))
	Design.set_colour(editor_theme, "selection_stroke", "GraphEdit", Design.ACCENT)
	Design.set_constant(editor_theme, "connection_hover_thickness", "GraphEdit", 5)
	Design.set_box(editor_theme, "panel", "GraphEdit",
		Design.panel(Design.Surface.CANVAS, 0, 0))

	# Ports: the jack you see stays small, the target you have to hit does not. WCAG 2.2
	# asks for 24x24 as a minimum and this is a patching interface, where missing the
	# port is the single most common way to fail at the main thing the app does.
	# The minimap. It was the last thing on the canvas the design system had not
	# touched: a flat grey rectangle with no border, no relationship to any other
	# surface, and nodes drawn in the same grey as the background it sat on — which
	# read as a panel that had failed to draw rather than as a map of anything.
	#
	# On the ladder now, one level above the canvas it floats over, with the viewport
	# rectangle in the accent so "where am I" is answerable without squinting.
	Design.set_box(editor_theme, "panel", "GraphEditMinimap",
		Design.panel(Design.Surface.NODE, Design.RADIUS_PANEL))
	var minimap_node := Design.panel(Design.Surface.ACTIVE, 1, 0)
	Design.set_box(editor_theme, "node", "GraphEditMinimap", minimap_node)
	var minimap_camera := StyleBoxFlat.new()
	minimap_camera.draw_center = false
	minimap_camera.set_border_width_all(2)
	minimap_camera.border_color = Design.ACCENT
	minimap_camera.set_corner_radius_all(2)
	Design.set_box(editor_theme, "camera", "GraphEditMinimap", minimap_camera)
	Design.set_colour(editor_theme, "resizer_color", "GraphEditMinimap",
		Design.INK_SECOND)

	# The zoom and minimap buttons float over the canvas with nothing behind them, so
	# they get the panel the rest of the chrome uses.
	Design.set_box(editor_theme, "menu_panel", "GraphEdit",
		Design.padded_panel(Design.Surface.NODE, Design.SPACE_S, Design.SPACE_XS))

	Design.set_constant(editor_theme, "port_hotzone_inner_extent", "GraphEdit",
		Design.scale(14))
	Design.set_constant(editor_theme, "port_hotzone_outer_extent", "GraphEdit",
		Design.scale(18))

	theme = editor_theme
	if not Design.unknown_items.is_empty():
		push_warning("theme items Godot does not know: " + ", ".join(Design.unknown_items))


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

	split = HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(split)
	# The divider is placed from the right, on every resize. It used to be a constant
	# split_offset, which is measured from the *first* child rather than from the
	# window — so the inspector sat at the same absolute x whatever the window size,
	# and on anything narrower than about 1790px it hung off the right-hand edge with
	# its contents cut in half. Every automated check passed the whole time, because
	# nothing that measures a widget notices the widget is outside the window.
	split.resized.connect(_fit_side_panel)
	split.dragged.connect(_on_split_dragged)

	graph_edit = PatchGraph.new()
	graph_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	graph_edit.right_disconnects = true
	graph_edit.show_grid = false   # the canvas draws its own; see below
	# Thinner than the default. A cable is a relationship between two nodes, and at 4px
	# it was drawing more attention than either of them; the path highlight is what
	# makes a cable loud, and that only works if the resting state is quiet.
	graph_edit.connection_lines_thickness = 2.5
	graph_edit.connection_lines_antialiased = true
	# The minimap was a flat grey rectangle sitting over the canvas with no border and
	# no relationship to anything else on screen — it read as a panel that had failed
	# to draw. Smaller, and on the same surface ladder as everything else.
	graph_edit.minimap_enabled = true
	graph_edit.minimap_size = Vector2(180, 110)
	# Opaque, now that it is a surface rather than a grey box: it was faded to hide
	# how out of place it looked, which is treating the symptom.
	graph_edit.minimap_opacity = 0.9
	# Snap to the same grid auto-place uses, so dragging a node by hand keeps the pitch.
	graph_edit.snapping_enabled = true
	graph_edit.snapping_distance = int(GRID)
	# The canvas draws its own grid, whose tiers are the layout's own pitches: a heavy
	# line is a column, a medium one is a row, a faint one is the snap step. GraphEdit's
	# built-in grid would otherwise draw a second, unrelated set of major lines over it.
	graph_edit.show_grid_buttons = false
	# The zoom percentage, spelled out. It was a row of icons whose middle one meant
	# "reset to 100%" without saying what the current value was — and now that zoom
	# decides how much of a node is drawn, the number is genuinely worth reading: it
	# is the difference between "the parameters have gone" and "the parameters have
	# gone because I am at 40%".
	graph_edit.show_zoom_label = true
	# And one button fewer. Arrange is in the toolbar menu now, so the icon beside the
	# zoom controls was a second way to do a thing that already had a labelled one —
	# the kind of duplication that makes a toolbar feel busy without adding anything.
	graph_edit.show_arrange_button = false
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
	graph_edit.detail_changed.connect(_apply_detail)
	graph_edit.port_hovered.connect(_on_port_hovered)
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
	_set_side_panel_open(true)

	# Under the tabs rather than inside one: the graph and the rack are two views of the
	# same running patch, and the thing that plays it belongs to neither.
	root.add_child(_build_keyboard_dock())
	_set_keyboard_expanded(true)
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


## Somewhere to put a group of related controls, with a rule before it.
##
## The toolbar read as one long sentence — Add node, Auto-place, Arrange selection,
## Undo, Redo, Open, Add module, Save as, Catenary, Case, Fire, All notes off — with
## nothing to say where one idea ended and the next began. Same controls, grouped:
## project, edit, graph, view, and performance pinned to the right.
func _toolbar_group(bar: HBoxContainer, first: bool = false) -> HBoxContainer:
	if not first:
		var rule := VSeparator.new()
		rule.add_theme_constant_override("separation", Design.SPACE_M)
		bar.add_child(rule)
	var group := HBoxContainer.new()
	group.add_theme_constant_override("separation", Design.SPACE_XS)
	bar.add_child(group)
	return group


func _build_toolbar() -> Control:
	var bar := HBoxContainer.new()
	bar.custom_minimum_size.y = Design.scale(52)
	bar.add_theme_constant_override("separation", Design.SPACE_S)

	# ---- who and what: context before actions -----------------------------------
	# The product name and the open document were at opposite ends of the bar with
	# nine buttons between them. Together, top left, they answer "where am I" before
	# anything asks "what do you want to do".
	var identity := VBoxContainer.new()
	identity.add_theme_constant_override("separation", 0)
	identity.custom_minimum_size.x = Design.scale(150)

	var title := Label.new()
	title.text = "SoundGraph"
	title.add_theme_font_override("font", Design.font(Design.WEIGHT_SEMIBOLD))
	title.add_theme_font_size_override("font_size", Design.scale(Design.SIZE_APP_TITLE))
	title.add_theme_color_override("font_color", Design.INK_BRIGHT)
	identity.add_child(title)

	document_label = Label.new()
	document_label.text = document_name
	document_label.add_theme_font_size_override("font_size",
		Design.scale(Design.SIZE_SECONDARY))
	document_label.add_theme_color_override("font_color", Design.INK_SECOND)
	identity.add_child(document_label)
	bar.add_child(identity)

	var project := _toolbar_group(bar, true)
	# A menu, not a dropdown showing its last selection.
	#
	# As an OptionButton it sat in the toolbar reading "Delay Echo" while the document
	# name two inches to the left read "first-synth.json" — because an OptionButton
	# shows what was last picked from it, which stops being true the moment anything
	# else opens a file. Two labels disagreeing about what is open is worse than one
	# label; now the identity block is the only thing that answers that question.
	var examples := MenuButton.new()
	examples.text = "Examples"
	examples.flat = false
	_scan_examples()
	var examples_popup := examples.get_popup()
	var example_names: Array = _examples.keys()
	for index in example_names.size():
		examples_popup.add_item(str(example_names[index]), index)
	examples_popup.id_pressed.connect(func(id: int) -> void:
		_load_example(str(example_names[id])))
	project.add_child(_defocus(examples))

	# ---- graph: the core verb, and the two that tidy up after it -----------------
	# Add node is what this application is for, so it is the one filled button in the
	# chrome and it comes first. Everything having equal weight meant reading all
	# thirteen controls to find the one that matters.
	var graph_group := _toolbar_group(bar)
	var add_button := Button.new()
	add_button.text = "+  Add node"
	add_button.tooltip_text = "Search by what you want, not only by name (Ctrl+Space)"
	add_button.pressed.connect(_open_search)
	_primary_buttons.append(add_button)
	graph_group.add_child(Design.make_primary(_defocus(add_button) as Button))

	# Auto-place and Arrange selection behind one menu, for the same reason. Both are
	# occasional; the second is usually unavailable anyway, and a permanently greyed
	# button is chrome that has never done anything for anyone.
	var arrange_menu := MenuButton.new()
	arrange_menu.text = "Arrange"
	arrange_menu.flat = false
	arrange_popup = arrange_menu.get_popup()
	arrange_popup.add_item("Auto-place everything", 0)
	arrange_popup.add_item("Arrange selection", 1)
	arrange_popup.add_separator()
	arrange_popup.add_item("Fit graph in view", 2)
	arrange_popup.set_item_tooltip(2, "Zoom and scroll so the whole patch is visible, "
		+ "clear of the minimap and the zoom controls.")
	arrange_popup.set_item_tooltip(0, "Lay the whole graph out left to right. The same "
		+ "patch always lands the same way, wherever things were before.")
	arrange_popup.set_item_disabled(1, true)
	# if/elif rather than match: a lambda closes with a bracket on the last line, and a
	# match arm followed by ")" is not something the parser will accept.
	arrange_popup.id_pressed.connect(func(id: int) -> void:
		if id == 0:
			_auto_place()
		elif id == 1:
			_arrange_selection()
		else:
			graph_edit.fit_graph())
	graph_group.add_child(_defocus(arrange_menu))

	# ---- edit --------------------------------------------------------------------
	# Visible buttons as well as the shortcut: an undo you cannot see is an undo a first
	# time user does not know they have.
	var edit_group := _toolbar_group(bar)
	undo_button = Button.new()
	undo_button.text = "Undo"
	undo_button.disabled = true
	undo_button.pressed.connect(_undo)
	edit_group.add_child(_defocus(undo_button))

	redo_button = Button.new()
	redo_button.text = "Redo"
	redo_button.disabled = true
	redo_button.pressed.connect(_redo)
	edit_group.add_child(_defocus(redo_button))

	# Open, Add module and Save as behind one menu.
	#
	# Not tidiness for its own sake: with every command exposed the toolbar had a
	# minimum width of 1786px, so on any window narrower than that the whole layout
	# was forced wider than the window and the inspector hung off the right-hand edge
	# with its text cut in half. These three are reached once per session; Add node is
	# reached constantly. Only one of them earns permanent space.
	var file_menu := MenuButton.new()
	file_menu.text = "File"
	file_menu.flat = false
	var file_popup := file_menu.get_popup()
	file_popup.add_item("Open…", 0)
	file_popup.add_item("Add module…", 1)
	file_popup.add_item("Save as…", 2)
	file_popup.set_item_tooltip(1, "Add an existing patch into this one. Its nodes are "
		+ "copied in with their names prefixed; its own inputs and outputs are left out, "
		+ "because those belong to a finished patch rather than to a module.")
	file_popup.id_pressed.connect(_on_file_menu)
	project.add_child(_defocus(file_menu))

	var view_group := _toolbar_group(bar)
	# Cable style is the A/B for Knobcon and the case width is set once per patch, so
	# both are radio groups in one menu rather than two dropdowns holding 266px of bar
	# open all the time.
	var view_menu := MenuButton.new()
	view_menu.text = "View"
	view_menu.flat = false
	view_popup = view_menu.get_popup()
	view_popup.add_radio_check_item("Cables: catenary", 0)
	view_popup.add_radio_check_item("Cables: PCB", 1)
	view_popup.set_item_checked(0, true)
	view_popup.add_separator()
	for index in CASE_LABELS.size():
		view_popup.add_radio_check_item(CASE_LABELS[index], 10 + index)
	view_popup.set_item_checked(3, true)
	view_popup.add_separator()
	# An accessibility switch that only exists as a hope is not one. Everything that
	# moves on its own in this editor is off behind this: the signal glow and the grid
	# fade, both of which say something the interface also says without moving.
	view_popup.add_separator()
	for index in Design.PALETTE_NAMES.size():
		view_popup.add_radio_check_item(Design.PALETTE_NAMES[index], 30 + index)
	view_popup.add_separator()
	view_popup.add_check_item("Reduce motion", 20)
	view_popup.set_item_checked(view_popup.get_item_index(20), Design.reduced_motion)
	view_popup.id_pressed.connect(_on_view_menu)
	view_group.add_child(_defocus(view_menu))

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
	message_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	message_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	message_label.add_theme_font_size_override("font_size",
		Design.scale(Design.SIZE_SECONDARY))
	message_label.add_theme_color_override("font_color", Design.INK_SECOND)
	bar.add_child(message_label)
	var performance := _toolbar_group(bar)

	var retrigger := Button.new()
	# "Fire" was a personality word that only reads as one if you already know what it
	# does. "Audition" is what this is: play the patch once so you can hear it, without
	# committing to holding a key down.
	retrigger.text = "Audition"
	retrigger.icon = _icon(Icons.Kind.PLAY, Design.INK_NORMAL)
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
		_say("fired"))
	performance.add_child(_defocus(retrigger))

	# The panic control. Everything else in this bar can be hunted for; this one
	# cannot, because the reason you want it is that something is already wrong and
	# loud. So it is the only error-coloured thing in the chrome, it carries a stop
	# glyph, and it is pinned to the right edge — a fixed place, not a position that
	# depends on how many other buttons happen to be showing.
	var panic := Button.new()
	panic.text = "Silence"
	panic.icon = _icon(Icons.Kind.STOP, Design.PANIC)
	panic.tooltip_text = "Stop every sounding note immediately (Escape)"
	panic.pressed.connect(_all_notes_off)
	_panic_buttons.append(panic)
	performance.add_child(Design.make_panic(_defocus(panic) as Button))

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
	var status_group := _toolbar_group(bar)
	status_group.add_theme_constant_override("separation", Design.SPACE_S)

	transport_dot = TextureRect.new()
	transport_dot.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	status_group.add_child(transport_dot)

	status_label = Label.new()
	status_label.text = "starting…"
	status_label.add_theme_font_override("font", Design.numeric_font())
	status_label.add_theme_font_size_override("font_size",
		Design.scale(Design.SIZE_SECONDARY))
	status_label.add_theme_color_override("font_color", Design.INK_SECOND)
	status_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	status_group.add_child(status_label)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_right", Design.SPACE_M)
	bar.add_child(margin)
	return bar


const CASE_LABELS := ["Case: fit window", "Case: 84 HP", "Case: 104 HP", "Case: 168 HP"]
const CASE_WIDTHS := [0, 84, 104, 168]


func _on_file_menu(id: int) -> void:
	_importing_module = id == 1
	if _on_web():
		if id == 2:
			_web_save()
		else:
			_web_open()
		return
	if id == 2:
		file_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
		file_dialog.title = "Save patch"
		file_dialog.current_file = "patch.json"
	else:
		file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		file_dialog.title = "Add a patch as a module" if id == 1 else "Open patch"
	file_dialog.popup_centered_ratio(0.6)


func _on_view_menu(id: int) -> void:
	if id >= 30:
		_use_palette(id - 30)
		return
	if id == 20:
		Design.reduced_motion = not Design.reduced_motion
		Settings.store("reduced_motion", Design.reduced_motion)
		view_popup.set_item_checked(view_popup.get_item_index(20), Design.reduced_motion)
		if Design.reduced_motion and graph_edit != null:
			# Cleared rather than frozen, or the last frame of glow would sit there
			# forever looking like a port that is stuck on.
			graph_edit.port_levels.clear()
			graph_edit.queue_redraw()
		return
	if id < 10:
		for index in 2:
			view_popup.set_item_checked(index, index == id)
		rack.cable_style = id
		graph_edit.cable_style = id
		graph_edit.refresh_cables()
		return
	var choice := id - 10
	for index in CASE_LABELS.size():
		view_popup.set_item_checked(index + 3, index == choice)
	rack.case_hp = CASE_WIDTHS[choice]


## Switches theme and rebuilds everything that holds a colour.
##
## The theme is a property of the person, not of the patch — opening somebody else's
## file must not change your contrast mode — so it is saved to user settings and nothing
## about it is ever written into a .json.
func _use_palette(index: int) -> void:
	Design.use_palette(index)
	Settings.store("palette", index)
	for entry in Design.PALETTE_NAMES.size():
		view_popup.set_item_checked(view_popup.get_item_index(30 + entry), entry == index)

	# The theme carries most of it. What it cannot reach is anything styled per widget —
	# node titles, the port icons, the scope — so the graph is rebuilt, which is cheap and
	# is the same path a reload takes.
	_apply_theme()
	# Per-instance overrides are invisible to a theme rebuild, so anything styled
	# directly has to be restyled by hand. Without this the accent and panic buttons
	# kept whatever palette was active when they were built and every other palette
	# measured identically — which is exactly what the readability check reported.
	for button in _primary_buttons:
		Design.make_primary(button)
	for button in _panic_buttons:
		Design.make_panic(button)
	_port_icons.clear()
	_rebuild_view()
	_refresh_context()
	_refresh_status()
	if keyboard != null:
		keyboard.queue_redraw()
	if scope != null:
		scope.queue_redraw()
	if rack != null:
		rack.type_colours = TYPE_COLOURS
		rack.rebuild()
	_say("theme: %s" % Design.PALETTE_NAMES[index])


## Stops every sounding note. Wired to both the panic button and Escape, because a
## panic control that needs the mouse is one you cannot reach while holding a chord.
func _all_notes_off() -> void:
	if engine != null:
		engine.all_notes_off()
	held_notes.clear()
	if keyboard != null:
		keyboard.set_held_notes(held_notes)


## Keeps the inspector at a fixed width against the right edge, whatever the window
## is doing, and gives everything else to the graph.
func _fit_side_panel() -> void:
	if split == null or views == null:
		return
	var wanted := side_panel_width if side_panel_open else SIDE_PANEL_COLLAPSED
	# The minimum size is what actually holds the width open; the split offset alone
	# lets the container squeeze the panel narrower than asked, which clipped the scope
	# and cut the ends off every readout in it.
	if side_panel != null:
		side_panel.custom_minimum_size.x = wanted
	var graph_minimum := views.get_combined_minimum_size().x
	split.split_offset = int(split.size.x - wanted - graph_minimum)


## Reads the width back off the divider after a drag, so dragging *is* the setting.
##
## A separate width control next to a draggable divider is two ways to say the same
## thing, and they disagree the moment either is used.
func _on_split_dragged(_offset: int) -> void:
	if split == null or side_panel == null or not side_panel_open:
		return
	side_panel_width = clampi(int(split.size.x - split.split_offset
		- views.get_combined_minimum_size().x), SIDE_PANEL_MIN, SIDE_PANEL_MAX)
	_fit_side_panel()


func _set_side_panel_open(open: bool) -> void:
	side_panel_open = open
	if side_panel_body != null:
		# Hidden rather than squeezed. A panel narrowed to 36px is a column of clipped
		# words that still takes clicks and still has to be laid out.
		side_panel_body.visible = open
	if side_panel_toggle != null:
		side_panel_toggle.text = ""
		side_panel_toggle.icon = _icon(
			Icons.Kind.CHEVRON_RIGHT if open else Icons.Kind.CHEVRON_LEFT,
			Design.INK_SECOND)
		side_panel_toggle.tooltip_text = ("Hide the inspector  (Ctrl+I)" if open
			else "Show the inspector  (Ctrl+I)")
	_fit_side_panel()


## The inspector, which changes with what is selected.
##
## It used to be three fixed regions, and two of them were nearly always empty: a SIGNAL
## box with nothing in it and a PROBLEMS list saying "No problems." in green, between them
## taking most of the height to say nothing at all — while the execution order, which is
## the one genuinely interesting thing this editor knows that a patch cable does not tell
## you, was squeezed into a line of grey text at the bottom.
##
## Now the space earns its width. Nothing selected: what the graph is and the order it
## runs in. A node selected: that node. Problems appear only when there are some.
func _build_side_panel() -> Control:
	side_panel = VBoxContainer.new()
	side_panel.custom_minimum_size.x = SIDE_PANEL_COLLAPSED
	side_panel.add_theme_constant_override("separation", Design.SPACE_S)

	# The collapse control sits above everything and never moves, so the way back is
	# in the same place whether the panel is open or shut.
	var strip := HBoxContainer.new()
	side_panel_toggle = Button.new()
	side_panel_toggle.flat = true
	side_panel_toggle.custom_minimum_size.x = Design.scale(28)
	side_panel_toggle.pressed.connect(func() -> void:
		_set_side_panel_open(not side_panel_open))
	strip.add_child(_defocus(side_panel_toggle))
	side_panel.add_child(strip)

	# Padded, because the panel now sits against the window edge rather than inside a
	# fixed-width column — the scope was running right off the side of the screen and
	# every readout in it ended a pixel from the frame.
	var inset := MarginContainer.new()
	inset.size_flags_vertical = Control.SIZE_EXPAND_FILL
	for edge in ["left", "right", "bottom"]:
		inset.add_theme_constant_override("margin_" + edge, Design.scale(Design.SPACE_M))
	side_panel.add_child(inset)

	side_panel_body = VBoxContainer.new()
	side_panel_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	side_panel_body.add_theme_constant_override("separation", Design.SPACE_M)
	inset.add_child(side_panel_body)

	var panel := side_panel_body

	# One quiet line, always in the same place. Valid is the normal state and should look
	# like it — a green "No problems." carried as much visual authority as an actual error,
	# so the panel read as urgent when nothing was wrong.
	health_label = Label.new()
	health_label.add_theme_font_size_override("font_size",
		Design.scale(Design.SIZE_SECONDARY))
	panel.add_child(health_label)

	diagnostics_heading = _section_heading("Problems")
	panel.add_child(diagnostics_heading)
	diagnostics_list = VBoxContainer.new()
	diagnostics_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	diagnostics_list.add_theme_constant_override("separation", Design.SPACE_S)
	panel.add_child(diagnostics_list)

	# No SIGNAL heading. The scope writes what it is showing across its own top left —
	# "filter.out", or "master output" — so a heading above it said the same thing
	# twice, in a smaller voice, one line further from the thing it described.
	scope = Scope.new()
	scope.custom_minimum_size.y = Design.scale(120)
	panel.add_child(scope)

	context_heading = _section_heading("The graph")
	panel.add_child(context_heading)
	context_panel = VBoxContainer.new()
	context_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	context_panel.add_theme_constant_override("separation", Design.SPACE_S)
	panel.add_child(context_panel)

	# What used to be here: "Play with A W S E D F T G Y H U J K. Z and X shift octave."
	#
	# Every word of that is now somewhere better. The letters are printed on the keys
	# they play, and the octave buttons carry (Z) and (X) in their tooltips. A sentence
	# in the corner of a panel describing controls that are visible eight inches away,
	# labelled, is the kind of thing a UI accumulates while it is still explaining
	# itself — and the point of getting the keyboard right was to stop needing it.

	return side_panel


## Fills the contextual region: the graph when nothing is selected, otherwise the node.
func _refresh_context() -> void:
	if context_panel == null:
		return
	for child in context_panel.get_children():
		context_panel.remove_child(child)
		child.queue_free()

	var node_id: String = str(inspecting.get("node", ""))
	if node_id == "":
		context_heading.text = "THE GRAPH"
		_fill_graph_context()
	else:
		context_heading.text = "SELECTED NODE"
		_fill_node_context(node_id)


func _node_type(node_id: String) -> String:
	for node in patch.get("nodes", []):
		if str(node["id"]) == node_id:
			return str(node["type"])
	return ""


## What the graph is doing, as something you can point at.
##
## The execution order was a line of grey text. It is the one thing this editor knows that
## a patch cable does not tell you, so it is now a row of chips: hovering one lights the
## node it names, clicking one selects and centres it. The same information, turned from a
## caption into a way of getting around the graph.
func _fill_graph_context() -> void:
	if engine == null or not engine.is_loaded():
		return
	var info: Variant = JSON.parse_string(engine.get_info_json())
	if typeof(info) != TYPE_DICTIONARY:
		return

	context_panel.add_child(_field("Runs in this order"))
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", Design.SPACE_XS)
	flow.add_theme_constant_override("v_separation", Design.SPACE_XS)
	for node in info["nodes"]:
		flow.add_child(_stage_chip(str(node["id"])))
	context_panel.add_child(flow)

	if not info["feedback"].is_empty():
		context_panel.add_child(_field("Feedback"))
		for edge in info["feedback"]:
			context_panel.add_child(_value("%s to %s (previous block)"
				% [edge["from"], edge["to"]], Design.WARNING))

	var cost: Dictionary = info["cost"]
	context_panel.add_child(_field("Cost"))
	context_panel.add_child(_numeric("%d nodes · %d Hz"
		% [int(info["node_count"]), int(info["sample_rate"])]))
	context_panel.add_child(_numeric("cpu %.1f units · state %d B · buffers %.1f KB"
		% [cost["cpu"], int(cost["state_bytes"]), float(cost["heap_bytes"]) / 1024.0]))


func _fill_node_context(node_id: String) -> void:
	var type_name := _node_type(node_id)
	var descriptor: Dictionary = registry.get(type_name, {})

	var title := Label.new()
	title.text = node_id
	title.add_theme_font_override("font", Design.font(Design.WEIGHT_SEMIBOLD))
	title.add_theme_font_size_override("font_size", Design.scale(Design.SIZE_NODE_TITLE))
	title.add_theme_color_override("font_color", Design.INK_BRIGHT)
	context_panel.add_child(title)
	context_panel.add_child(_value("%s · %s"
		% [type_name, str(descriptor.get("category", ""))], Design.INK_SECOND))

	var summary := Label.new()
	summary.text = str(descriptor.get("summary", ""))
	summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	summary.add_theme_font_size_override("font_size", Design.scale(Design.SIZE_SECONDARY))
	summary.add_theme_color_override("font_color", Design.INK_NORMAL)
	context_panel.add_child(summary)

	# Every output, with a click to point the scope at it — "what is this node putting out"
	# answered in one click rather than by hunting for the right port on the node itself.
	var outputs := _port_list(node_id, "outputs")
	if not outputs.is_empty():
		context_panel.add_child(_field("Outputs"))
		for port in outputs:
			context_panel.add_child(_port_row(node_id, port))


## A clickable stage in the execution order.
func _stage_chip(node_id: String) -> Button:
	var chip := Button.new()
	chip.text = node_id
	chip.tooltip_text = "Select and centre %s" % node_id
	chip.add_theme_font_override("font", Design.numeric_font())
	chip.add_theme_font_size_override("font_size", Design.scale(Design.SIZE_SECONDARY))
	chip.add_theme_stylebox_override("normal", Design.padded_panel(
		Design.Surface.RAISED, Design.SPACE_S, Design.SPACE_XS, Design.RADIUS_BUTTON))
	chip.add_theme_stylebox_override("hover", Design.padded_panel(
		Design.Surface.ACTIVE, Design.SPACE_S, Design.SPACE_XS, Design.RADIUS_BUTTON))
	chip.mouse_entered.connect(func() -> void: _highlight([node_id]))
	chip.mouse_exited.connect(func() -> void: _highlight([]))
	chip.pressed.connect(func() -> void: _focus_node(node_id))
	return _defocus(chip) as Button


## Selects a node and brings it into view.
func _focus_node(node_id: String) -> void:
	var widget: GraphNode = widgets.get(node_id)
	if widget == null:
		return
	for other in widgets.values():
		(other as GraphNode).selected = false
	widget.selected = true
	# Against the usable rectangle, not the control. Centring on `size` aims at a point
	# that may be under the minimap, the zoom cluster or a scrollbar.
	graph_edit.centre_on(Rect2(widget.position_offset, widget.size))
	_on_node_selected(widget)


func _port_row(node_id: String, port: Dictionary) -> Control:
	var row := Button.new()
	var unit := str(port.get("unit", ""))
	row.text = str(port["name"]) + ("  (%s)" % unit if unit != "" else "")
	row.alignment = HORIZONTAL_ALIGNMENT_LEFT
	row.tooltip_text = str(port.get("doc", ""))
	row.add_theme_font_size_override("font_size", Design.scale(Design.SIZE_SECONDARY))
	row.pressed.connect(func() -> void:
		inspecting = {"node": node_id, "port": str(port["name"])})
	return _defocus(row)


func _field(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_override("font", Design.font(Design.WEIGHT_MEDIUM))
	label.add_theme_font_size_override("font_size", Design.scale(Design.SIZE_SECONDARY))
	label.add_theme_color_override("font_color", Design.INK_SECOND)
	return label


func _value(text: String, colour: Color = Design.INK_NORMAL) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", Design.scale(Design.SIZE_BODY))
	label.add_theme_color_override("font_color", colour)
	return label


## Figures in the tabular face, so a column of costs lines up.
func _numeric(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_override("font", Design.numeric_font())
	label.add_theme_font_size_override("font_size", Design.scale(Design.SIZE_NUMERIC))
	label.add_theme_color_override("font_color", Design.INK_NORMAL)
	return label


func _section_heading(text: String) -> Label:
	var label := Label.new()
	label.text = text.to_upper()
	label.add_theme_font_override("font", Design.font(Design.WEIGHT_MEDIUM))
	label.add_theme_font_size_override("font_size",
		Design.scale(Design.SIZE_HEADING))
	label.add_theme_color_override("font_color", Design.INK_SECOND)
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


## Stops calling into the extension before the extension goes away.
##
## Every frame this reaches across the GDExtension boundary several times — filling
## the playback, reading the scope, sampling a port for the glow. During teardown the
## tree is dismantled in an order nothing here controls, and a frame that lands after
## the engine has been released is an access violation rather than an error.
##
## The round trip has been failing with exit status 3221225477 — 0xC0000005, a crash
## at shutdown *after* the work succeeded — in roughly one run in five. That predates
## this pass and is documented in current-phase.md, but adding more per-frame calls
## across that boundary can only have made it likelier, so the frames stop first.
## Stops the audio side and lets go of the engine.
##
## Separate from _exit_tree, and public, because _exit_tree runs *inside* free() —
## no frames pass between stopping the player and the engine being destroyed, and
## that gap is exactly what the crash needs. A caller that can await should call this
## first and give it a couple of frames.
##
## What is being avoided: AudioServer mixes on its own thread and holds a reference
## to the generator playback this fills every frame — a clean run leaks it with a
## reference count of 1, which is the audio server still having it. Destroy the
## GDExtension engine while that thread is mid-mix and the process dies with
## 0xC0000005 after all the work has finished. Under --verbose it never reproduces in
## 30 runs, which is how a race announces itself.
func shutdown_audio() -> void:
	set_process(false)
	if engine != null:
		engine.all_notes_off()
	if player != null:
		player.stop()
		player.stream = null
		if player.get_parent() != null:
			player.get_parent().remove_child(player)
		player.free()
		player = null
	playback = null
	engine = null


func _exit_tree() -> void:
	shutdown_audio()


func _process(_delta: float) -> void:
	if engine == null or playback == null:
		return
	if engine.is_loaded():
		engine.fill_playback(playback, playback.get_frames_available())
	_update_scope()
	_update_port_levels(_delta)
	if message_label != null and message_label.text != "" \
			and Time.get_ticks_msec() > _message_clears_at:
		message_label.text = ""


## Measures what every output port is actually carrying, for the signal glow.
##
## One port per frame, round-robin. Reading all of them every frame means a call across
## the extension boundary and a buffer allocation per port per frame, which is real work
## on the audio thread's doorstep for something nobody would notice being a tenth of a
## second stale. A dozen ports at 60fps is still five full sweeps a second.
##
## Levels fall faster than they rise on purpose. A glow that tracked the waveform exactly
## would flicker at audio rate; this is an envelope follower, the same thing a VU meter is.
func _update_port_levels(delta: float) -> void:
	if graph_edit == null or Design.reduced_motion or not engine.is_loaded():
		return

	if _level_targets.is_empty():
		_rebuild_level_targets()
	if _level_targets.is_empty():
		return

	_level_cursor = (_level_cursor + 1) % _level_targets.size()
	var target: Dictionary = _level_targets[_level_cursor]
	var samples: PackedFloat32Array = engine.get_port_signal(target["node"], target["port"])
	var peak := 0.0
	var lowest := INF
	var highest := -INF
	for value in samples:
		peak = maxf(peak, absf(value))
		lowest = minf(lowest, value)
		highest = maxf(highest, value)

	# Audio is judged on level and control on *movement*, and the difference matters.
	#
	# A control wire is not bounded to +/-1 — a frequency sits at 440 whether or not
	# anything is happening — so "is it non-zero" lights every control port in the graph
	# permanently, which is a glow that tells you nothing. What is worth seeing is an
	# envelope opening or an LFO sweeping, and both of those are change over the block.
	# A pitch that is holding steady is not activity, and should not look like it.
	var level := 0.0
	if target["audio"]:
		level = clampf(peak, 0.0, 1.0)
	elif highest > lowest:
		level = clampf(highest - lowest, 0.0, 1.0)

	var widget_name: String = target["widget"]
	if not graph_edit.port_levels.has(widget_name):
		graph_edit.port_levels[widget_name] = {}
	var existing: float = graph_edit.port_levels[widget_name].get(target["index"], 0.0)
	var rate: float = 18.0 if level > existing else 6.0
	graph_edit.port_levels[widget_name][target["index"]] = \
		lerpf(existing, level, clampf(delta * rate, 0.0, 1.0))


## The list of output ports to sweep, rebuilt when the graph changes.
func _rebuild_level_targets() -> void:
	_level_targets.clear()
	_level_cursor = 0
	if graph_edit != null:
		graph_edit.port_levels.clear()
	for node_id in widgets:
		var widget: GraphNode = widgets[node_id]
		var outputs := _port_list(node_id, "outputs")
		for index in outputs.size():
			_level_targets.append({
				"node": node_id,
				"widget": String(widget.name),
				"port": str(outputs[index]["name"]),
				"index": index,
				"audio": str(outputs[index]["type"]) == "audio",
			})


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

	_style_node_title(widget, descriptor)
	# Hover is its own state, distinct from selection.
	#
	# GraphNode has normal and selected and nothing between them, so a node under the
	# pointer looked exactly like one three columns away — and in a patch dense enough
	# to need the mouse, "which node am I about to click" is a real question. One step
	# of border brightening: enough to answer it, not enough to be mistaken for the
	# accent outline that means selected.
	widget.mouse_entered.connect(func() -> void: _set_node_hovered(widget, true))
	widget.mouse_exited.connect(func() -> void: _set_node_hovered(widget, false))

	var inputs: Array = descriptor.get("inputs", [])
	var outputs: Array = descriptor.get("outputs", [])

	# One row per port pair, at a fixed height off the spacing scale. Rows that each took
	# whatever height their label happened to measure is most of what "crowded" meant.
	var rows: int = maxi(inputs.size(), outputs.size())
	for row in rows:
		var line := HBoxContainer.new()
		line.custom_minimum_size.y = Design.scale(Design.NODE_ROW_HEIGHT)
		line.add_theme_constant_override("separation", Design.scale(Design.SPACE_M))
		line.alignment = BoxContainer.ALIGNMENT_CENTER

		# Name and unit as two labels, not one string.
		#
		# "cutoff_mod  (octaves)" gave the unit the same weight and colour as the name,
		# so a column of ports read as a wall of similar-length phrases and the thing you
		# were scanning for — the name — had to be picked out of each one. Same
		# information, ranked: the unit is metadata and now looks like it. Parentheses
		# gone too; they were doing the separating that a colour change does better.
		var left := _port_label(inputs[row] if row < inputs.size() else {}, false)
		line.add_child(left)

		var right := _port_label(outputs[row] if row < outputs.size() else {}, true)
		line.add_child(right)
		# Tagged so the zoom level-of-detail can find the parts of a node worth hiding
		# without having to guess from child order.
		line.set_meta("row", "port")
		left.set_meta("port_label", true)
		right.set_meta("port_label", true)
		widget.add_child(line)

		var has_input := row < inputs.size()
		var has_output := row < outputs.size()
		widget.set_slot(row,
			has_input, _slot_type(inputs[row]["type"]) if has_input else 0,
			TYPE_COLOURS.get(inputs[row]["type"], Color.WHITE) if has_input else Color.WHITE,
			has_output, _slot_type(outputs[row]["type"]) if has_output else 0,
			TYPE_COLOURS.get(outputs[row]["type"], Color.WHITE) if has_output else Color.WHITE)

		# Shape as well as colour. Audio is a filled circle, control a diamond, event a
		# square, note a ring — so the signal type survives a colour-blind viewer, a
		# greyscale printout and a projector that has given up on saturation. Colour was
		# doing this on its own, which meant for some people it was not being done.
		if has_input:
			widget.set_slot_custom_icon_left(row, _port_icon(inputs[row]["type"]))
		if has_output:
			widget.set_slot_custom_icon_right(row, _port_icon(outputs[row]["type"]))

	_add_parameter_rows(widget, node, descriptor)

	graph_edit.add_child(widget)
	widgets[node["id"]] = widget
	ids[widget.name] = node["id"]


## GraphNode draws its title as a plain Label in the titlebar, with no theme entry of its
## own — so a title font and colour set on the theme does nothing at all, which is what the
## previous code did. Styled here instead, and while the titlebar is open, the node's
## category goes in on the right: one quiet word saying what kind of thing this is.
func _style_node_title(widget: GraphNode, descriptor: Dictionary) -> void:
	var titlebar := widget.get_titlebar_hbox()
	if titlebar == null:
		return
	for child in titlebar.get_children():
		var label := child as Label
		if label == null:
			continue
		label.add_theme_font_override("font", Design.font(Design.WEIGHT_SEMIBOLD))
		label.add_theme_font_size_override("font_size", Design.scale(Design.SIZE_NODE_TITLE))
		label.add_theme_color_override("font_color", Design.INK_BRIGHT)
		break

	var category := str(descriptor.get("category", ""))
	if category == "":
		return
	var tag := Label.new()
	tag.text = category.to_upper()
	tag.add_theme_font_override("font", Design.font(Design.WEIGHT_MEDIUM))
	tag.add_theme_font_size_override("font_size", Design.scale(Design.SIZE_HEADING))
	tag.add_theme_color_override("font_color", Design.INK_SECOND)
	tag.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# Right-aligned and last, which reserves that end of the header for node actions
	# later without the category having to move when they arrive.
	tag.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	titlebar.add_child(tag)


## A small texture per signal type, drawn once and shared.
##
## Filled circle for audio, diamond for control, square for event, ring for note. The port
## you see stays around 10px; the region that accepts a drag is set far larger by the
## GraphEdit hotzone constants, so this is about telling the types apart, not about aim.
static var _port_icons: Dictionary = {}

func _port_icon(type_name: String) -> Texture2D:
	if _port_icons.has(type_name):
		return _port_icons[type_name]

	const SIZE := 20
	var image := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))
	var colour: Color = TYPE_COLOURS.get(type_name, Design.INK_NORMAL)
	var centre := Vector2(SIZE * 0.5 - 0.5, SIZE * 0.5 - 0.5)
	var radius := 5.0

	for y in SIZE:
		for x in SIZE:
			var point := Vector2(x, y) - centre
			var distance := 0.0
			match type_name:
				"control":
					distance = absf(point.x) + absf(point.y)          # diamond
				"event":
					distance = maxf(absf(point.x), absf(point.y)) * 1.35   # square
				_:
					distance = point.length()                          # circle
			var edge := radius + 1.0
			if distance > edge:
				continue
			# A dark rim, so a port stays visible against a node body of any lightness.
			var alpha: float = clampf(edge - distance, 0.0, 1.0)
			var fill := colour
			if type_name == "note" and distance < radius - 2.0:
				fill = Design.SURFACES[Design.Surface.NODE]        # ring, not disc
			image.set_pixel(x, y, Color(fill.r, fill.g, fill.b, alpha))

	var texture := ImageTexture.create_from_image(image)
	_port_icons[type_name] = texture
	return texture


## One side of a port row: the name in ordinary ink, the unit behind it in secondary.
func _port_label(port: Dictionary, align_right: bool) -> Control:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.alignment = BoxContainer.ALIGNMENT_END if align_right \
		else BoxContainer.ALIGNMENT_BEGIN
	row.add_theme_constant_override("separation", Design.SPACE_XS)
	if port.is_empty():
		return row

	var doc := str(port.get("doc", ""))
	if bool(port.get("required", false)):
		doc = "Required. " + doc
	row.tooltip_text = doc

	var name_label := Label.new()
	name_label.text = str(port["name"])
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_label.set_meta("port_label", true)
	row.add_child(name_label)

	# Name then unit, always — including on the right-hand side, where the first
	# version put the unit first so that the name would sit nearest its port. It was
	# a reasonable argument about proximity and it produced "Hz frequency", which
	# reads as a typo. Reading order beats proximity when the result is words.
	var unit := str(port.get("unit", ""))
	if unit != "":
		row.add_child(_unit_label(unit))
	return row


func _unit_label(unit: String) -> Label:
	var label := Label.new()
	label.text = unit
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", Design.scale(Design.SIZE_SECONDARY))
	label.add_theme_color_override("font_color", Design.INK_SECOND)
	label.set_meta("port_label", true)
	return label


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
		row.set_meta("row", "parameter")
		widget.add_child(row)
		if index >= always_visible:
			row.visible = false
			# Recorded, not just hidden. The zoom level-of-detail hides parameter rows too,
			# and when it puts them back it must not also un-collapse the ones the reader
			# chose to fold away — two features writing the same `visible` flag with no
			# memory between them is how a node quietly grows every time you zoom.
			row.set_meta("collapsed", true)
			extra.append(row)

	if extra.is_empty():
		return

	# A quiet line of text, not a switch.
	#
	# A CheckButton draws a full-width filled bar with a sliding pill on it, which made
	# the control for hiding two parameters heavier than either of the parameters it
	# was hiding — the loudest thing in the node was the thing that mattered least.
	# Flat, secondary ink, and a caret that says which way it goes.
	var toggle := Button.new()
	toggle.toggle_mode = true
	toggle.flat = true
	toggle.text = "%d more" % extra.size()
	toggle.icon = _icon(Icons.Kind.CARET_RIGHT, Design.INK_SECOND,
		Design.SIZE_SECONDARY)
	toggle.alignment = HORIZONTAL_ALIGNMENT_LEFT
	toggle.add_theme_font_size_override("font_size", Design.scale(Design.SIZE_SECONDARY))
	toggle.add_theme_color_override("font_color", Design.INK_SECOND)
	toggle.add_theme_color_override("font_hover_color", Design.INK_NORMAL)
	toggle.add_theme_color_override("font_pressed_color", Design.INK_SECOND)
	toggle.toggled.connect(func(pressed: bool) -> void:
		for row in extra:
			row.set_meta("collapsed", not pressed)
			row.visible = pressed and graph_edit.detail == PatchGraph.Detail.FULL
		toggle.text = "fewer" if pressed else "%d more" % extra.size()
		toggle.icon = _icon(Icons.Kind.CARET_DOWN if pressed else Icons.Kind.CARET_RIGHT,
			Design.INK_SECOND, Design.SIZE_SECONDARY))
	toggle.set_meta("row", "parameter")
	widget.add_child(_defocus(toggle))


func _build_parameter_row(node: Dictionary, parameter: Dictionary) -> Control:
	var row := HBoxContainer.new()
	# Name, control, value and unit on one line at a fixed height, so a stack of
	# parameters reads as a table rather than as a pile.
	row.custom_minimum_size.y = Design.scale(Design.NODE_ROW_HEIGHT)
	row.add_theme_constant_override("separation", Design.scale(Design.SPACE_M))
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	var name: String = parameter["name"]
	var node_id: String = node["id"]
	var current: float = float(node.get("parameters", {}).get(name, parameter["default"]))

	var label := Label.new()
	label.text = name
	label.custom_minimum_size.x = Design.scale(96)
	label.tooltip_text = str(parameter.get("doc", ""))
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", Design.scale(Design.SIZE_SECONDARY))
	label.add_theme_color_override("font_color", Design.INK_SECOND)
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
	slider.custom_minimum_size.x = Design.scale(112)

	# Bipolar controls show where zero is. Modulation depth, transpose and offsets all
	# have a meaningful centre, and a slider that gives no hint of it makes finding
	# "no modulation" a matter of watching the number. Only when zero really does sit
	# in the middle — an exponential or asymmetric range would put a tick in a place
	# that means nothing, which is worse than no tick at all.
	if float(parameter["min"]) < 0.0 and float(parameter["max"]) > 0.0:
		var centre := _to_position(parameter, 0.0)
		if absf(centre - 0.5) < 0.01:
			slider.tick_count = 3
			slider.ticks_on_borders = false

	# The number is a control, not a caption. A slider 112px wide cannot resolve 20 Hz
	# to 20 kHz — at the bottom of an exponential range one pixel is several hertz —
	# so the only way to ask for exactly 440 was to drag until it happened to say 440.
	# Drag the figure, double click to type it, Alt-click for the default.
	var readout := ValueField.new()
	readout.custom_minimum_size.x = Design.scale(84)
	readout.text = _format_with_unit(parameter, current)
	readout.default_value = float(parameter["default"])
	readout.position_now = _to_position(parameter, current)
	readout.to_value = func(position: float) -> float:
		return _to_value(parameter, position)
	readout.to_position = func(value: float) -> float:
		return _to_position(parameter, value)
	readout.value_submitted.connect(func(value: float) -> void:
		var clamped: float = clampf(value, float(parameter["min"]), float(parameter["max"]))
		slider.set_value_no_signal(_to_position(parameter, clamped))
		readout.position_now = _to_position(parameter, clamped)
		readout.text = _format_with_unit(parameter, clamped)
		_set_parameter(node_id, name, clamped))
	# One gesture is one undo step, whether it moved one pixel or three hundred.
	readout.drag_started.connect(func() -> void: _begin_edit())
	readout.drag_finished.connect(func() -> void: _commit_edit("set %s" % name))

	slider.value_changed.connect(func(position: float) -> void:
		var value := _to_value(parameter, position)
		readout.text = _format_with_unit(parameter, value)
		readout.position_now = position
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
		readout: Control, descriptor: Dictionary) -> void:
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


## The value as somebody would say it out loud: "10 ms", not "0.010".
##
## A patch format stores seconds and hertz, and a person reading a node should not
## have to hold the native representation in their head to know what they are looking
## at. So the unit is always shown, and it changes with the magnitude — milliseconds
## under a second, kilohertz over a thousand — because that is how the number would
## be spoken and written down anywhere else.
func _format_with_unit(parameter: Dictionary, value: float) -> String:
	var unit := str(parameter.get("unit", ""))
	if unit == "s" and absf(value) < 1.0:
		return "%s ms" % _format_value(value * 1000.0)
	if unit == "Hz" and absf(value) >= 1000.0:
		return "%s kHz" % _format_value(value / 1000.0)
	if unit == "":
		return _format_value(value)
	return "%s %s" % [_format_value(value), unit]


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
	_refresh_context()
	_light_signal_path(node_id)


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
	var readout = entry["readout"]
	if readout != null:
		readout.text = _format_with_unit(entry["descriptor"], value)
		if readout is ValueField:
			readout.position_now = _to_position(entry["descriptor"], value)
		if readout is ValueField:
			readout.position_now = _to_position(entry["descriptor"], value)


func _on_rack_node_selected(node_id: String) -> void:
	var outputs := _port_list(node_id, "outputs")
	inspecting = {"node": node_id, "port": outputs[0]["name"]} if not outputs.is_empty() \
		else {}
	_refresh_context()


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


## The strip above the keyboard: where it sits, and how much of it you can see.
##
## Both were already reachable — octave by Z and X, width not at all — and a shortcut
## nobody has been told about is a feature that does not exist. Somebody sitting down at
## this for the first time at a show will not guess Z and X, so the buttons say what they
## do and the shortcut is written on them for whoever wants it afterwards.
## The keyboard, as a dock that can get out of the way.
##
## Its white keys carry more contrast and more apparent mass than anything in the
## graph, so the eye landed on it first and stayed there — it was winning a fight it
## should not have been in. Three things put it back in its place: it collapses to a
## strip, its keys are off-white rather than paper, and its controls sit on the same
## surface as the rest of the chrome instead of looking like a widget from another
## library glued to the bottom of the window.
func _build_keyboard_dock() -> Control:
	keyboard_dock = PanelContainer.new()
	keyboard_dock.add_theme_stylebox_override("panel",
		Design.padded_panel(Design.Surface.NODE, Design.SPACE_M, Design.SPACE_S))

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", Design.SPACE_S)
	keyboard_dock.add_child(column)
	column.add_child(_build_keyboard_bar())

	keyboard = Keyboard.new()
	keyboard.note_pressed.connect(_on_keyboard_pressed)
	keyboard.note_released.connect(_on_keyboard_released)
	column.add_child(keyboard)
	return keyboard_dock


## Collapses the dock to its control strip, or opens it again.
func _set_keyboard_expanded(expanded: bool) -> void:
	keyboard_expanded = expanded
	if keyboard != null:
		# Hidden rather than shrunk: a keyboard two pixels tall is a row of slivers
		# that still take clicks.
		keyboard.visible = expanded
		if not expanded:
			_release_all_notes()
	if keyboard_toggle != null:
		keyboard_toggle.text = "Keyboard"
		keyboard_toggle.icon = _icon(
			Icons.Kind.CARET_DOWN if expanded else Icons.Kind.CARET_RIGHT,
			Design.INK_SECOND)
		keyboard_toggle.tooltip_text = ("Collapse the keyboard" if expanded
			else "Show the keyboard")


func _build_keyboard_bar() -> Control:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", Design.SPACE_XS)

	keyboard_toggle = Button.new()
	keyboard_toggle.pressed.connect(func() -> void:
		_set_keyboard_expanded(not keyboard_expanded))
	bar.add_child(_defocus(keyboard_toggle))

	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(gap)

	var range_label := Label.new()
	range_label.name = "KeyboardRange"
	range_label.custom_minimum_size.x = Design.scale(132)
	range_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	range_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	range_label.add_theme_font_override("font", Design.numeric_font())
	range_label.add_theme_font_size_override("font_size",
		Design.scale(Design.SIZE_NUMERIC))
	range_label.add_theme_color_override("font_color", Design.INK_SECOND)

	var make := func(text: String, tooltip: String, action: Callable) -> Button:
		var button := Button.new()
		button.text = text
		button.tooltip_text = tooltip
		button.custom_minimum_size.x = Design.scale(36)
		button.pressed.connect(action)
		return _defocus(button) as Button

	bar.add_child(range_label)
	bar.add_child(make.call("−8va", "Down an octave  (Z)",
		func() -> void: _shift_octave(-1)))
	bar.add_child(make.call("+8va", "Up an octave  (X)",
		func() -> void: _shift_octave(1)))

	var spacer := Control.new()
	spacer.custom_minimum_size.x = 10
	bar.add_child(spacer)

	bar.add_child(make.call("−", "Show fewer octaves",
		func() -> void: _show_octaves(keyboard_octaves - 1)))
	bar.add_child(make.call("+", "Show more octaves",
		func() -> void: _show_octaves(keyboard_octaves + 1)))

	keyboard_bar = bar
	return bar


## Moves the keyboard, letting go first.
##
## Notes are held by number, so a key still down when the range moves is released as a
## different note and the original never stops. With Z and X that took a deliberate effort;
## with a button under the mouse it would take a moment's inattention, and a stuck note in
## front of an audience is not recoverable by explaining it.
func _shift_octave(delta: int) -> void:
	var moved: int = clampi(octave + delta, 0, 7)
	if moved == octave:
		return
	_release_all_notes()
	octave = moved
	_refresh_keyboard_range()


func _show_octaves(count: int) -> void:
	var wanted: int = clampi(count, 1, 6)
	if wanted == keyboard_octaves:
		return
	# Widening does not move any key that was already showing, so nothing needs releasing.
	# Narrowing takes keys away, and a held note on one of them could never be let go.
	if wanted < keyboard_octaves:
		_release_all_notes()
	keyboard_octaves = wanted
	_refresh_keyboard_range()


func _release_all_notes() -> void:
	for note in held_notes.keys():
		_let_go_note(note)


## The keyboard starts at the octave the computer keys are playing and runs as wide as the
## buttons above it say, with the mapped keys lettered on the keys themselves.
func _refresh_keyboard_range() -> void:
	if keyboard == null:
		return
	var base: int = octave * 12 + 12
	var labels := {}
	for keycode in KEY_NOTES:
		labels[base + KEY_NOTES[keycode]] = OS.get_keycode_string(keycode)
	keyboard.key_labels = labels
	keyboard.set_range(base, keyboard_octaves)
	_refresh_keyboard_label(base)


## Names the range in notes rather than in octave numbers, because "C3 to C5" is something
## you can check against the keys in front of you and "octave 3, 2 wide" is not.
func _refresh_keyboard_label(base: int) -> void:
	if keyboard_bar == null:
		return
	var label := keyboard_bar.get_node_or_null("KeyboardRange") as Label
	if label == null:
		return
	label.text = "%s – %s" % [_note_name(base), _note_name(base + keyboard_octaves * 12)]


func _note_name(note: int) -> String:
	const NAMES := ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
	return "%s%d" % [NAMES[note % 12], note / 12 - 1]


## Names the open document. Called from every route in — the file dialog, the browser's
## file input, the examples menu — so the label cannot go stale by one of them forgetting.
func _set_document_name(name: String) -> void:
	document_name = name if not name.is_empty() else "untitled"
	# Opening or saving a document is the moment it stops being unsaved, and every
	# route in and out already comes through here — which is why the name lives in one
	# function rather than being set at each call site.
	unsaved = false
	_refresh_document_label()


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
	if arrange_popup != null:
		arrange_popup.set_item_disabled(1, _selected_ids().size() < 2)


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
		_say("select two or more nodes to arrange them together")
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
	_say("placed %d node%s" % [
		placed.size(), "" if placed.size() == 1 else "s"])


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


## Whether the document has changed since it was opened or last written out.
##
## "Have I saved this" is one of the few questions an editor should never make
## somebody guess at, and it was not answerable here at all — the toolbar said
## "playing" whatever had happened to the patch.
var unsaved := false:
	set(value):
		unsaved = value
		_refresh_document_label()


func _refresh_document_label() -> void:
	if document_label == null:
		return
	# A dot rather than an asterisk, and the name goes bright rather than gaining
	# punctuation — the change should be noticeable without the label jumping about,
	# and a leading "*" shifts every character along by one.
	document_label.text = document_name + ("  (unsaved)" if unsaved else "")
	document_label.add_theme_color_override("font_color",
		Design.INK_NORMAL if unsaved else Design.INK_SECOND)


func _commit_edit(label: String) -> void:
	if _pending_snapshot.is_empty():
		return
	var before := _pending_snapshot
	_pending_snapshot = {}
	var after := _snapshot()
	if JSON.stringify(before) == JSON.stringify(after):
		return  # a drag that went nowhere is not an edit

	unsaved = true
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
		_refresh_status()
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
	var readout = entry.get("readout")
	if slider is OptionButton:
		slider.selected = clampi(int(round(value)), 0, slider.item_count - 1)
		return
	if slider is HSlider:
		# set_value_no_signal, or restoring a value would look like the user turning it.
		slider.set_value_no_signal(_to_position(entry["descriptor"], value))
	# The same formatter as the row builds with. Two places writing the readout in two
	# different formats would make an undo look like it had changed the units.
	if readout != null:
		readout.text = _format_with_unit(entry["descriptor"], value)


func _undo() -> void:
	if not undo_redo.has_undo():
		return
	var label := undo_redo.get_current_action_name()
	undo_redo.undo()
	_say("undid %s" % label)
	_refresh_undo_buttons()


func _redo() -> void:
	if not undo_redo.has_redo():
		return
	undo_redo.redo()
	_say("redid %s" % undo_redo.get_current_action_name())
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
		# The sweep list names ports by node and index, so it has to be rebuilt whenever
		# the graph is — otherwise the glow keeps lighting ports that no longer exist.
		_rebuild_level_targets()
		_show_info()
		_refresh_status()
	else:
		_refresh_status()


func _show_diagnostics(diagnostics: Array) -> void:
	for child in diagnostics_list.get_children():
		child.queue_free()

	# Valid is the normal state, so it gets one quiet line and no section at all. The
	# old green "No problems." sat under a PROBLEMS heading taking a fifth of the panel
	# to announce that nothing had happened, which is how a reader learns to ignore the
	# place where problems appear.
	_problem_count = diagnostics.size()
	_refresh_status()
	if diagnostics.is_empty():
		health_label.text = "Graph valid"
		health_label.add_theme_color_override("font_color", Design.INK_SECOND)
		diagnostics_heading.visible = false
		_highlight([])
		return

	var errors := 0
	for entry in diagnostics:
		if str(entry.get("severity", "error")) == "error":
			errors += 1
	health_label.text = "%d problem%s" % [diagnostics.size(),
		"" if diagnostics.size() == 1 else "s"]
	health_label.add_theme_color_override("font_color",
		Design.ERROR if errors > 0 else Design.WARNING)
	diagnostics_heading.visible = true

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


## Lights the whole signal path a node sits on.
##
## Selecting a filter tells you where the filter is. What you actually want to know is
## where the sound goes — what feeds this, and what this feeds, all the way to the output.
## In a patch of any size that is the question the cables are there to answer and the one
## they are worst at, because at a glance every cable looks like every other cable.
##
## GraphEdit already has the mechanism: connection activity tints a cable toward the
## theme accent. So the path is simply every connection reachable from the selection in
## either direction, turned up; everything else turned down.
func _light_signal_path(node_id: String) -> void:
	if graph_edit == null:
		return
	var lit := {}
	if node_id != "":
		for id in _reachable_from(node_id, true):
			lit[id] = true
		for id in _reachable_from(node_id, false):
			lit[id] = true

	for connection in graph_edit.connections:
		var from_id: String = ids.get(str(connection["from_node"]), "")
		var to_id: String = ids.get(str(connection["to_node"]), "")
		var on_path := lit.has(from_id) and lit.has(to_id)
		graph_edit.set_connection_activity(connection["from_node"],
			int(connection["from_port"]), connection["to_node"],
			int(connection["to_port"]), 1.0 if on_path else 0.0)


## Every node reachable from this one, following cables downstream or upstream.
func _reachable_from(node_id: String, downstream: bool) -> Array:
	var seen := {node_id: true}
	var queue := [node_id]
	while not queue.is_empty():
		var current: String = queue.pop_back()
		for connection in patch.get("connections", []):
			var from_id := str(connection["from"]["node"])
			var to_id := str(connection["to"]["node"])
			var step := ""
			if downstream and from_id == current:
				step = to_id
			elif not downstream and to_id == current:
				step = from_id
			# The guard is the cycle: a feedback patch would otherwise walk its own loop
			# forever, and feedback is a thing this editor deliberately supports.
			if step != "" and not seen.has(step):
				seen[step] = true
				queue.append(step)
	return seen.keys()


## Applies the graph's current detail level to every node.
##
## Port *rows* are never hidden, only the labels inside them. A GraphNode slot is bound to
## the index of a visible child, so hiding a row would renumber the slots underneath it and
## every cable below that point would attach to the wrong port. Hiding the labels keeps the
## row — and the port — exactly where it was.
func _apply_detail(level: int) -> void:
	var show_parameters := level == PatchGraph.Detail.FULL
	var show_port_names := level != PatchGraph.Detail.TOPOLOGY
	for id in widgets:
		var widget: GraphNode = widgets[id]
		for child in widget.get_children():
			var control := child as Control
			if control == null:
				continue
			match str(control.get_meta("row", "")):
				"parameter":
					control.visible = show_parameters and not control.get_meta("collapsed", false)
				"port":
					# One level deeper than it used to be: a port caption is now a name and a
					# unit in their own box, so the labels are grandchildren of the row.
					for side in control.get_children():
						for part in (side as Control).get_children():
							var label := part as Label
							if label != null and label.has_meta("port_label"):
								label.visible = show_port_names


## Says what a port is, in words, while the pointer is on it.
##
## A jack on a piece of hardware is labelled. Here the node body has the name and the
## colour and shape carry the type, which is fine once you know the vocabulary and no help
## at all on the first day — "cutoff_mod" tells you nothing about what may be plugged into
## it. The tooltip spells out direction, signal type and unit, and then the sentence the
## core already carries for that port. Nothing new is invented here: it is the registry's
## own documentation, shown at the moment it is wanted.
func _on_port_hovered(widget_name: String, side: String, index: int) -> void:
	if graph_edit == null:
		return
	if widget_name == "":
		graph_edit.tooltip_text = ""
		return

	var node_id: String = ids.get(widget_name, "")
	var ports := _port_list(node_id, "inputs" if side == "left" else "outputs")
	if index < 0 or index >= ports.size():
		graph_edit.tooltip_text = ""
		return

	var port: Dictionary = ports[index]
	var unit := str(port.get("unit", ""))
	var parts := [
		"%s.%s" % [node_id, str(port["name"])],
		"%s %s" % [str(port["type"]), "input" if side == "left" else "output"],
	]
	if unit != "":
		parts.append(unit)
	if side == "left" and bool(port.get("required", false)):
		parts.append("required")

	var summary := str(port.get("doc", ""))
	graph_edit.tooltip_text = "  ·  ".join(parts) + ("\n" + summary if summary != "" else "")


## Brightens a node's border while the pointer is on it.
##
## Only the border, and only when the node is not selected: a hover that also changed the
## fill would compete with the selected state, and the whole value of having three states
## is that they are told apart at a glance rather than compared.
func _set_node_hovered(widget: GraphNode, hovered: bool) -> void:
	if widget.selected:
		widget.remove_theme_stylebox_override("panel")
		widget.remove_theme_stylebox_override("titlebar")
		return
	if not hovered:
		widget.remove_theme_stylebox_override("panel")
		widget.remove_theme_stylebox_override("titlebar")
		return

	var body := (theme.get_stylebox("panel", "GraphNode") as StyleBoxFlat).duplicate()
	body.border_color = Design.BORDERS[Design.Surface.ACTIVE]
	widget.add_theme_stylebox_override("panel", body)
	var head := (theme.get_stylebox("titlebar", "GraphNode") as StyleBoxFlat).duplicate()
	head.border_color = Design.BORDERS[Design.Surface.ACTIVE]
	widget.add_theme_stylebox_override("titlebar", head)


## Puts a drawn icon on a control, at the size the ink around it is using.
##
## Every one of these was a Unicode symbol until it turned out that seven of the twelve
## are absent from Atkinson Hyperlegible Next and had been rendering as tofu boxes. A
## missing glyph is not an error in Godot, it is a rectangle, so nothing said so.
func _icon(kind: int, colour: Color = Design.INK_NORMAL, size: int = 0) -> Texture2D:
	return Icons.get_icon(kind, Design.scale(size if size > 0 else Design.SIZE_CONTROL),
		colour)


## A passing remark, shown beside the state strip and taken away again.
##
## Separate from the strip because it answers a different question: the strip says what is
## true now, this says what just happened. Conflating them is how a status line ends up
## claiming the graph is fine because saving was the last thing anybody did.
func _say(message: String) -> void:
	if message_label == null:
		return
	message_label.text = message
	message_label.tooltip_text = message
	_message_clears_at = Time.get_ticks_msec() + 4000


## The status strip: running, valid, and at what rate.
##
## Rebuilt from state rather than written at each event, so it cannot end up saying
## "saved" while the graph is broken — which the old single label could, because whichever
## thing happened last owned the whole line.
func _refresh_status() -> void:
	if status_label == null:
		return
	var running: bool = engine != null and bool(engine.is_loaded())
	var valid := _problem_count == 0

	if transport_dot != null:
		transport_dot.texture = _icon(Icons.Kind.DOT,
			Design.ACCENT if running else Design.INK_DISABLED, Design.SIZE_SECONDARY)
		transport_dot.tooltip_text = "Audio running" if running else "Audio stopped"

	var parts := ["Audio running" if running else "Audio stopped"]
	parts.append("Graph valid" if valid else "%d problem%s"
		% [_problem_count, "" if _problem_count == 1 else "s"])
	if running:
		# "48k" rather than "48 kHz". Six pixels over the 1280px budget is still over it,
		# and the budget is there because the alternative is the inspector going off the
		# side of a laptop screen again. The exact figure is in the tooltip, which is the
		# right home for a number that has never once changed while somebody watched.
		parts.append("48k")
	status_label.text = "  ·  ".join(parts)
	status_label.tooltip_text = ("Audio %s · graph %s · 48000 Hz"
		% ["running" if running else "stopped", "valid" if valid else "has problems"])
	status_label.add_theme_color_override("font_color",
		Design.INK_SECOND if valid else Design.ERROR)


func _highlight(node_ids: Array) -> void:
	for id in widgets:
		var widget: GraphNode = widgets[id]
		widget.modulate = Color(1.0, 0.65, 0.6) if node_ids.has(id) else Color.WHITE


## Kept under its old name because half a dozen places call it after the graph changes.
func _show_info() -> void:
	_refresh_context()


## Where an example actually lives.
##
## The copy under res://examples is mirrored in from examples/patches by the build, which
## means it goes stale the moment a patch is edited without rebuilding the extension —
## and the editor then quietly opens an old layout while the repository has a new one.
## That is a genuinely confusing failure, so the repository copy wins whenever it is
## reachable, and res:// is the fallback for an exported build that has no repository
## around it.
## Builds the examples menu by looking at what is actually there.
##
## Scans the same two places _example_path() does and in the same order, so the menu can
## never offer something that cannot be opened. Sorted within each group, and the groups
## in the order EXAMPLE_GROUPS declares them, so the menu does not reshuffle itself when a
## filesystem hands back a different order.
func _scan_examples() -> void:
	_examples.clear()
	for folder: String in EXAMPLE_GROUPS:
		var prefix: String = EXAMPLE_GROUPS[folder]
		var names := _example_file_names(folder)
		names.sort()
		# Typed, because an untyped loop variable here is a parse error at load and a
		# *hang* in the headless test rather than a message — see docs/current-phase.md.
		for file_name: String in names:
			var label := file_name.get_basename().capitalize()
			if prefix != "":
				label = "%s: %s" % [prefix, file_name.get_basename()]
			_examples[label] = folder.path_join(file_name) if folder != "" else file_name


func _example_file_names(folder: String) -> Array:
	var names: Array = []
	for base: String in [_repository_examples(), "res://examples"]:
		if base == "":
			continue
		var directory := DirAccess.open(base.path_join(folder))
		if directory == null:
			continue
		for file_name: String in directory.get_files():
			if file_name.ends_with(".json") and not names.has(file_name):
				names.append(file_name)
		# The repository copy wins outright when it exists, for the same reason
		# _example_path() prefers it: a half-and-half menu would be worse than either.
		if not names.is_empty():
			break
	return names


func _repository_examples() -> String:
	var path := ProjectSettings.globalize_path("res://").path_join("../examples/patches")
	return path if DirAccess.dir_exists_absolute(path) else ""


func _example_path(file_name: String) -> String:
	var repository := ProjectSettings.globalize_path("res://") \
		.path_join("../examples/patches").path_join(file_name)
	if FileAccess.file_exists(repository):
		return repository
	return "res://examples/" + file_name


func _load_example(name: String) -> void:
	if not _examples.has(name):
		return
	var path := _example_path(_examples[name])
	if _importing_module:
		_importing_module = false
		var module_file := FileAccess.open(path, FileAccess.READ)
		if module_file == null:
			_say("could not read %s" % path)
			return
		_import_module(module_file.get_as_text(), ModuleImport.name_from_path(path))
		return

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_say("could not open %s" % path)
		return
	_set_document_name(path.get_file())
	_load_text(file.get_as_text())


func _on_file_selected(path: String) -> void:
	if file_dialog.file_mode == FileDialog.FILE_MODE_SAVE_FILE:
		_capture_positions()
		var out := FileAccess.open(path, FileAccess.WRITE)
		if out == null:
			_say("could not write %s" % path)
			return
		# Written through the core's serialiser, not Godot's: the patch format is the
		# product, and it should read the same whichever editor saved it.
		out.store_string(engine.format_patch(JSON.stringify(patch, "  ")))
		_set_document_name(path.get_file())
		_say("saved")
		return

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_say("could not open %s" % path)
		return
	# Named, which opening through the dialog never did — the toolbar went on showing
	# whatever had been open before, and the one place that says which file you are
	# editing was quietly lying.
	_set_document_name(path.get_file())
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
		_say("this browser did not expose a file picker")
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
		_say("that file is not a patch")
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
		_say(result.error)
		return

	_rebuild_view()
	_apply()
	_commit_edit("add module %s" % module_name)
	# _apply sets its own status; the import has more to say than "playing".
	_say("%s: %s" % [module_name, result.summary()])


func _web_save() -> void:
	_capture_positions()
	var text: String = engine.format_patch(JSON.stringify(patch, "  "))
	var name: String = patch.get("metadata", {}).get("name", "patch")
	var file_name := name.to_lower().replace(" ", "-") + ".json"
	JavaScriptBridge.download_buffer(text.to_utf8_buffer(), file_name, "application/json")
	_set_document_name(file_name)
	_say("downloaded %s" % file_name)


func _load_text(text: String) -> void:
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		_say("that file is not a patch")
		return
	patch = parsed
	# A freshly opened document has no unsaved changes in it by definition, and every
	# way of opening one lands here — the examples menu, the file dialog, the browser
	# file input and module import all call this.
	unsaved = false
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
		_say("arranged %d nodes — the file had no layout" % patch["nodes"].size())
	elif moved > 0:
		_say("snapped %d node%s to the grid" % [moved, "" if moved == 1 else "s"])


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

	if key.pressed and key.ctrl_pressed and key.keycode == KEY_I:
		_set_side_panel_open(not side_panel_open)
		accept_event()
		return

	# Panic, on the key everybody already tries. A stop control you can only reach
	# with the mouse is one you cannot use while holding a chord down.
	if key.pressed and key.keycode == KEY_ESCAPE:
		_all_notes_off()
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

	# Through the same two functions the buttons call, so the shortcut cannot end up doing
	# something subtly different from the thing sitting next to it saying "(Z)".
	if key.pressed and key.keycode == KEY_Z:
		_shift_octave(-1)
		return
	if key.pressed and key.keycode == KEY_X:
		_shift_octave(1)
		return

	if not KEY_NOTES.has(key.keycode):
		return
	var note: int = octave * 12 + 12 + KEY_NOTES[key.keycode]
	if key.pressed:
		_hold_note(note)
	else:
		_let_go_note(note)
