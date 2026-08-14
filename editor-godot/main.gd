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

# Type lives in Design (design.gd) — sizes, weights and the 14px floor. The constants
# that used to sit here were a second copy from before that file existed, and one of
# them was still quietly styling the search hint: exactly the drift a single source of
# truth is supposed to make impossible, hiding in the file that preached it.

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
## New scripts are preloaded rather than trusted to the class-name cache, which
## headless runs do not refresh.
const ModuleAuthor := preload("res://module_author.gd")
const PatchFace := preload("res://patch_face.gd")

const EXAMPLE_GROUPS := {
	"": "",
	"game": "Game",
	"nodes": "Node",
	"fm": "FM",
	"dx7": "DX7",
}

## Groups this big become submenus rather than flat entries — a bank has a shape, and
## pouring 128 instruments into the top level buried the eight curated examples.
const EXAMPLE_SUBMENU_THRESHOLD := 16

## How many execution-order chips the inspector shows before folding the rest.
## Eight: two rows at the inspector's narrowest. Twelve passed the height budget by
## three pixels, and a budget met by three pixels is a budget about to fail.
const ORDER_CHIP_LIMIT := 8

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
## The face being picked, in the order it was picked, in exactly the shape
## ModuleAuthor.collapse takes: {"kind", "node", "port"/"parameter"}. Stored against patch
## ids rather than against widgets, because a rebuild throws every widget away and renames
## the ones it makes — picks that survive a rebuild are the whole reason this is not just
## a list of Controls.
var wand_picks: Array = []
var wand_button: Button
var wand_confirm: Button
## The file's own face: the knobs somebody plays. See patch_face.gd.
var patch_face: PatchFace
var views: TabContainer
var rack: Rack
var graphrack: GraphRack
var sandbox: Sandbox
var outline: Outline
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
var _importing_definition := false

## Undo works on whole-document snapshots rather than per-operation inverses. A patch is
## a few kilobytes, and the code that turns one into a view is the same well-exercised
## path used for loading — so "undo an edit" reduces to "load the previous document",
## which cannot drift out of step with the operations the way hand-written inverses do.
var undo_redo := UndoRedo.new()
var _pending_snapshot: Dictionary = {}
var toolbar: Control

# ---- the toolbar's responsiveness ------------------------------------------------
#
# The bar wants about 1600px to show everything and windows are not obliged to be that
# wide. What used to happen on a narrower one was not that the bar got smaller: a
# minimum size is a promise the container keeps, so the whole column was forced wider
# than the window and the inspector was pushed off the right-hand edge with its text cut
# through the middle. Nothing was hidden — it was drawn somewhere nobody could see it,
# which is the worst of both.
#
# So the bar gives things up deliberately, in an order decided here rather than by
# whichever control happened to be last. Each rung is a thing the bar can lose without
# losing what it is for, and every one of them stays reachable another way.
## Cheapest loss first, but "cheap" measured in what it costs the reader rather than in
## pixels — and then checked against the pixels, because a rung that buys nothing is a
## rung that makes the next one fire for no reason. Undo and redo come before the
## identity block on both counts: they are worth 140px to the bar against the product
## name's 65, and they are the only two controls here that keep working when they are
## gone, because Ctrl+Z does not need a button to exist.
enum Rung {
	FULL,       ## everything
	STATUS,     ## the status words go; the transport dot and its tooltip stay
	EDIT,       ## undo and redo go; Ctrl+Z and Ctrl+Y do not
	IDENTITY,   ## the product name goes; the document name stays
}
const RUNG_COUNT := 4

var toolbar_identity: VBoxContainer
var toolbar_title: Label
var toolbar_edit_group: HBoxContainer
var toolbar_performance_group: HBoxContainer
var toolbar_rung := Rung.FULL
## Which VSeparator introduces which group, so hiding a group takes its rule with it.
## A group that vanishes and leaves its divider behind reads as an empty slot.
var _toolbar_rules: Dictionary = {}
var _fitting_toolbar := false
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
	editor_theme.default_font_size = Design.type(Design.SIZE_BODY)

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
	# One step under the toolbar. Tabs name places and buttons do things, and the type
	# scale keeps that ranking even for somebody reading only sizes.
	Design.set_type(editor_theme, "TabBar", Design.WEIGHT_MEDIUM, Design.SIZE_TABS,
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

	toolbar = _build_toolbar()
	root.add_child(toolbar)
	# The window resizing is the event the ladder actually cares about. The bar's own
	# resized signal is still connected, for the first layout and for the rebuilds a UI
	# scale change causes, but it does not fire when the window shrinks past the point
	# where the bar stops fitting — by then the bar is already wider than the screen.
	get_viewport().size_changed.connect(_fit_toolbar.bind(-1.0))

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
	graph_edit.port_picked.connect(_on_port_picked)
	graph_edit.parameter_picked.connect(_on_parameter_picked)
	graph_edit.region_drawn.connect(_on_region_drawn)
	graph_edit.group_closed.connect(func(name: String) -> void: _close_module(name))
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
	# The rack asks a question and gets numbers; it never learns what an engine is.
	rack.read_port = func(node_id: String, port: String) -> PackedFloat32Array:
		if engine == null or not engine.is_loaded():
			return PackedFloat32Array()
		var source := _engine_signal_source(node_id, port)
		return engine.get_port_signal(source[0], source[1])
	rack.ink = INK
	rack.ink_dim = INK_DIM
	rack.parameter_changed.connect(_on_rack_parameter_changed)
	rack.edit_started.connect(func() -> void: _begin_edit())
	rack.edit_finished.connect(func(label: String) -> void: _commit_edit(label))
	rack.node_selected.connect(_on_rack_node_selected)
	rack_scroll.add_child(rack)
	views.add_child(rack_scroll)

	# Where the patcher goes next, in a tab of its own so it can be looked at.
	#
	# A copy of the rack today and nothing more — see graphrack.gd. It sits beside the
	# original rather than replacing the Graph tab because the departure is a thing to
	# steer by eye, and a replacement you cannot compare against is not a comparison. The
	# GraphEdit view it is aimed at is preserved at the `graph-refactor` tag.
	var graphrack_column := VBoxContainer.new()
	graphrack_column.name = "Graphrack"
	graphrack_column.add_theme_constant_override("separation", 0)
	views.add_child(graphrack_column)

	var graphrack_scroll := ScrollContainer.new()
	graphrack_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# Auto, not disabled. Zoomed in, the case is wider than the window and a rack you
	# cannot pan sideways is a rack with its right-hand modules amputated.
	graphrack_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	graphrack = GraphRack.new()
	graphrack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	graphrack.type_colours = TYPE_COLOURS
	graphrack.read_port = func(node_id: String, port: String) -> PackedFloat32Array:
		if engine == null or not engine.is_loaded():
			return PackedFloat32Array()
		var source := _engine_signal_source(node_id, port)
		return engine.get_port_signal(source[0], source[1])
	graphrack.ink = INK
	graphrack.ink_dim = INK_DIM
	graphrack.parameter_changed.connect(_on_rack_parameter_changed)
	graphrack.edit_started.connect(func() -> void: _begin_edit())
	graphrack.edit_finished.connect(func(label: String) -> void: _commit_edit(label))
	graphrack.node_selected.connect(_on_rack_node_selected)
	# Jacks take the mouse now, so the case has to do something with a cable dragged
	# between two of them or the gesture would be swallowed here while working next door
	# Patching the document from the rack, which is the only thing that made this view a
	# picture of a patcher rather than a picture of a rack.
	graphrack.connection_made.connect(_on_rack_connection_made)
	graphrack.patch_refused.connect(func(reason: String) -> void: _say(reason))
	graphrack.face_rearranged.connect(_on_face_rearranged)
	graphrack.rearrange_refused.connect(func(reason: String) -> void: _say(reason))
	graphrack.port_declared.connect(_on_port_declared)
	# A plain Control between the scroll container and the rack. Containers reset their
	# children's scale on every layout pass, so a rack parented straight to the scroller
	# could reserve the room for a zoom but never actually draw at it. The holder takes
	# the scaled size; the rack inside it keeps its own transform.
	var graphrack_holder := Control.new()
	graphrack_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	graphrack_holder.add_child(graphrack)
	graphrack_scroll.add_child(graphrack_holder)
	graphrack_column.add_child(_build_graphrack_zoom_bar())
	graphrack_column.add_child(graphrack_scroll)
	# Leftmost, and the one the editor opens on. It was added after the views it is
	# replacing so that it could be compared against them; it leads now, and they stay
	# where they are for as long as the comparison is still worth making.
	views.move_child(graphrack_column, 0)

	# A third view, and a different kind of answer: not how a patch looks, but what it is
	# for. Editing the jump patch in the Graph tab and hearing it change here, without a
	# rebuild, is the argument for shipping instructions rather than recordings.
	sandbox = Sandbox.new()
	sandbox.name = "Sandbox"
	views.add_child(sandbox)

	# The graph as text, and not only for the reason it is usually built.
	#
	# It is keyboard-navigable by construction, it reads aloud sensibly, it holds a
	# patch too large to see at once, and it answers "what is connected to this"
	# faster than tracing a line across a canvas by hand. That last one is a question
	# everybody has, which is why this is a second way to read the program rather than
	# an accommodation bolted to the side of the first.
	outline = Outline.new()
	outline.name = "Outline"
	outline.registry = registry
	outline.read_order = func() -> Array:
		if engine == null or not engine.is_loaded():
			return []
		var info: Variant = JSON.parse_string(engine.get_info_json())
		if typeof(info) != TYPE_DICTIONARY:
			return []
		var ids: Array = []
		for entry in info["nodes"]:
			ids.append(str(entry["id"]))
		return ids
	outline.node_chosen.connect(func(node_id: String) -> void:
		_focus_node(node_id))
	views.add_child(outline)
	views.current_tab = 0
	# Both views start on the style the toolbar says they are on. Worth knowing when
	# comparing them: dragging a cable waypoint is a PCB-mode gesture — a hanging cable
	# has no corners to grab, which is part of what is being traded.
	graph_edit.cable_style = Rack.CableStyle.CATENARY
	# The rack lays out against the width it is given, so it has to be told when the tab
	# is first shown — before that it has no size to flow modules into.
	views.tab_changed.connect(func(_index: int) -> void:
		rack.rebuild()
		graphrack.rebuild()
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
	# Every control that comes through here is a free-standing target in the chrome, so
	# this is also where the hit-area floor lives. The visible button can be whatever the
	# type and padding make it; the thing under the finger aims for ~44px regardless,
	# which is the difference between a toolbar and a test of aim. Node-row controls are
	# deliberately not covered — they trade target size for density, and get their own
	# treatment (the enlarged port targets) where it matters most.
	control.custom_minimum_size.y = maxf(control.custom_minimum_size.y,
		Design.scale(Design.HIT_TARGET))
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
	if not first:
		_toolbar_rules[group] = bar.get_child(bar.get_child_count() - 2)
	return group


func _build_toolbar() -> Control:
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
	title.tooltip_text = _build_description()
	title.mouse_filter = Control.MOUSE_FILTER_STOP
	identity.add_child(title)

	document_label = Label.new()
	document_label.text = document_name
	document_label.tooltip_text = document_name
	document_label.add_theme_font_size_override("font_size",
		Design.type(Design.SIZE_SECONDARY))
	document_label.add_theme_color_override("font_color", Design.INK_SECOND)
	# Trimmed rather than allowed to set the width of the toolbar.
	#
	# A latent version of the bug this budget exists to catch: the file name was free to
	# grow the identity block, so opening something with a long name pushed every control
	# to its right and could walk the inspector off the screen — from a file name. The
	# full name is in the tooltip and in the title bar.
	document_label.clip_text = true
	document_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
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
	# Large groups become submenus so the curated top level survives the banks. Grouping
	# is by the label prefix _scan_examples already assigns, and the submenu wiring is
	# per-group so a second bank costs a table entry, not a copy of this code.
	var grouped: Dictionary = {}
	var top_names: Array = []
	for label in _examples.keys():
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
			_load_example(str(chosen[id])))
	examples_popup.id_pressed.connect(func(id: int) -> void:
		_load_example(str(top_names[id])))
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
	arrange_popup.add_item("Collapse selection into module", 2)
	arrange_popup.set_item_tooltip(0, "Lay the whole graph out left to right. The same "
		+ "patch always lands the same way, wherever things were before.")
	arrange_popup.set_item_tooltip(2, "The selected nodes become a module: one node "
		+ "wearing their boundary as ports and their settings as knobs. Undo undoes it.")
	arrange_popup.set_item_disabled(1, true)
	arrange_popup.set_item_disabled(2, true)
	# if/elif rather than match: a lambda closes with a bracket on the last line, and a
	# match arm followed by ")" is not something the parser will accept.
	arrange_popup.id_pressed.connect(func(id: int) -> void:
		if id == 0:
			_auto_place()
		elif id == 1:
			_arrange_selection()
		elif id == 2:
			_collapse_selection())
	graph_group.add_child(_defocus(arrange_menu))

	# The wand, and the verb it exists to feed.
	#
	# Collapse is in the Arrange menu because it is a rearrangement of the document; the
	# wand is out here because it is a gesture, and a gesture buried in a menu is a gesture
	# nobody finds. Its confirm button appears beside it only while it is up — a permanently
	# greyed "Make module" would be the fourteenth control on this bar earning nothing.
	wand_button = Button.new()
	wand_button.toggle_mode = true
	wand_button.text = "Wand"
	wand_button.tooltip_text = "Point at the jacks and knobs the module should show, in " \
		+ "the order they should appear. Only the selected nodes can be picked, because " \
		+ "only they are going inside. Pick nothing and the module works out its own face."
	wand_button.toggled.connect(func(pressed: bool) -> void: _set_wand(pressed))
	graph_group.add_child(_defocus(wand_button))

	# Its own gesture now, and always available: draw a rectangle round some nodes and
	# what is inside it becomes a module, opened, with its name on the frame. It used to
	# be the wand's confirm button and appeared only while the wand was up, which made the
	# verb this whole feature exists for conditional on a tool being raised.
	wand_confirm = Button.new()
	wand_confirm.text = "Make module"
	wand_confirm.tooltip_text = "Draw a rectangle round some nodes. What is wholly inside it becomes a module, left open so you can see and arrange its parts."
	wand_confirm.pressed.connect(func() -> void: _begin_module_region())
	graph_group.add_child(_defocus(wand_confirm))

	# Fit comes out of that menu and sits beside it, spelled out.
	#
	# It was filed under Arrange, which is where it looks like it belongs and is not where
	# anybody goes for it: arranging moves nodes and is a change to the document, framing
	# moves the camera and changes nothing. One is undoable and the other has nothing to
	# undo. Grouping them meant the recovery move — "I have lost the graph, show me it" —
	# was two clicks inside a menu of edits.
	#
	# A word rather than a glyph. There is no icon for "fit" that anybody reads correctly
	# without a tooltip, and this editor has already paid once for symbols that turned out
	# to be missing from the font.
	var fit_button := Button.new()
	fit_button.text = "Fit"
	fit_button.tooltip_text = "Zoom and scroll so the whole patch is visible, clear of " \
		+ "the minimap and the zoom controls."
	fit_button.pressed.connect(func() -> void: graph_edit.fit_graph())
	graph_group.add_child(_defocus(fit_button))

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
	undo_button.pressed.connect(_undo)
	edit_group.add_child(_defocus(undo_button))

	redo_button = Button.new()
	redo_button.icon = _icon(Icons.Kind.REDO, Design.INK_NORMAL)
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
	file_popup.add_item("Add module as definition…", 3)
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
	view_popup.add_item(_build_description(), 60)
	view_popup.set_item_disabled(view_popup.get_item_index(60), true)
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
	var performance := _toolbar_group(bar)
	toolbar_performance_group = performance

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
		Design.type(Design.SIZE_SECONDARY))
	status_label.add_theme_color_override("font_color", Design.INK_SECOND)
	status_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	status_group.add_child(status_label)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_right", Design.SPACE_M)
	bar.add_child(margin)
	bar.resized.connect(_fit_toolbar)
	return bar


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
	if status_label != null:
		# The dot survives every rung. It is the part that answers "is this running" at a
		# glance, it is the only part that is legible from across a table, and it costs
		# fourteen pixels; the words it stands in for are on its tooltip.
		status_label.visible = toolbar_rung < Rung.STATUS
	if toolbar_title != null:
		toolbar_title.visible = toolbar_rung < Rung.IDENTITY
	if toolbar_identity != null:
		# The floor drops with the title, or the block goes on holding open 120px of
		# nothing and giving the name up buys the bar exactly zero.
		toolbar_identity.custom_minimum_size.x = Design.scale(
			120 if toolbar_rung < Rung.IDENTITY else 72)
	_show_toolbar_group(toolbar_edit_group, toolbar_rung < Rung.EDIT)


## Picks the highest rung the window can afford, from the top.
##
## From the top every time rather than stepping up and down from where it was: a ladder
## that only ever descends never comes back when the window is widened again, and one
## that steps by one has to be run repeatedly to settle.
## A width can be passed in, so a test can ask what a 1280px window would look like
## without owning a 1280px window. Left at -1 it measures the bar it has.
func _fit_toolbar(width: float = -1.0) -> void:
	if toolbar == null or _fitting_toolbar:
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
		if toolbar.get_combined_minimum_size().x <= available:
			break
	_fitting_toolbar = false


## How many parameter cells share a line in a graph node.
const PARAMETERS_PER_LINE := 2

const CASE_LABELS := ["Case: fit window", "Case: 84 HP", "Case: 104 HP", "Case: 168 HP"]
const CASE_WIDTHS := [0, 84, 104, 168]


func _on_file_menu(id: int) -> void:
	_importing_module = id == 1
	_importing_definition = id == 3
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
		file_dialog.title = "Add a patch as a module" if id == 1 else (
			"Add a patch as a module definition" if id == 3 else "Open patch")
	file_dialog.popup_centered_ratio(0.6)


func _on_view_menu(id: int) -> void:
	if id >= 50:
		_use_ui_scale(id - 50)
		return
	if id >= 40:
		Rack.density = id - 40
		Settings.store("rack_density", Rack.density)
		for entry in Rack.DENSITY_NAMES.size():
			view_popup.set_item_checked(view_popup.get_item_index(40 + entry),
				entry == Rack.density)
		rack.rebuild()
		GraphRack.density = Rack.density
		graphrack.rebuild()
		_say("rack: %s" % Rack.DENSITY_NAMES[Rack.density])
		return
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


## Changes the size of the whole interface — text, padding, ports, knobs and hit areas.
##
## Not the graph zoom. Zooming the canvas to compensate for small labels is the workaround
## somebody reaches for when this does not exist, and it makes the patch smaller while
## making the text bigger, which is the opposite of what was wanted. This scales the
## chrome and leaves the graph where it is.
##
## Everything is measured through Design.scale() at construction, so the only honest way to
## apply a new one is to build it again — which is what a reload does anyway, and is fast
## enough that nobody notices.
func _use_ui_scale(index: int) -> void:
	Design.ui_scale = clampi(index, 0, Design.SCALE_FACTORS.size() - 1)
	Settings.store("ui_scale", Design.ui_scale)
	if view_popup != null:
		for entry in Design.SCALE_NAMES.size():
			view_popup.set_item_checked(view_popup.get_item_index(50 + entry),
				entry == Design.ui_scale)

	_apply_theme()
	if graph_edit == null:
		return
	_port_icons.clear()
	for button in _primary_buttons:
		Design.make_primary(button)
	for button in _panic_buttons:
		Design.make_panic(button)
	_rebuild_view()
	_refresh_context()
	_refresh_keyboard_range()
	if rack != null:
		rack.rebuild()
	if graphrack != null:
		graphrack.rebuild()
	if outline != null:
		outline.refresh()
	_say("size: %s" % Design.SCALE_NAMES[Design.ui_scale])


## Switches theme and rebuilds everything that holds a colour.
##
## The theme is a property of the person, not of the patch — opening somebody else's
## file must not change your contrast mode — so it is saved to user settings and nothing
## about it is ever written into a .json.
func _use_palette(index: int) -> void:
	Design.use_palette(index)
	Settings.store("palette", index)
	# Guarded, because this is reachable before the toolbar exists — from settings at
	# startup, and from the screenshot tool, both of which set a palette without a menu
	# to tick.
	if view_popup != null:
		for entry in Design.PALETTE_NAMES.size():
			view_popup.set_item_checked(view_popup.get_item_index(30 + entry),
				entry == index)

	# The theme carries most of it. What it cannot reach is anything styled per widget —
	# node titles, the port icons, the scope — so the graph is rebuilt, which is cheap and
	# is the same path a reload takes.
	_apply_theme()
	# Nothing below exists until the editor has been built, and a palette can be set
	if graph_edit == null:
		return
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
	if graphrack != null:
		graphrack.type_colours = TYPE_COLOURS
		graphrack.rebuild()
	_say("theme: %s" % Design.PALETTE_NAMES[index])


## Stops every sounding note. Wired to both the panic button and Escape, because a
## panic control that needs the mouse is one you cannot reach while holding a chord.
func _all_notes_off() -> void:
	if engine != null:
		engine.all_notes_off()
	held_notes.clear()
	if keyboard != null:
		keyboard.set_held_notes(held_notes)


## The graphrack's zoom strip.
##
## A strip above the case rather than a panel floating over it. The graph's zoom control
## was an overlay pinned to the top-left of the canvas, and in every screenshot taken of
## that view it is sitting on top of a node's port labels — a control for looking at the
## patch, placed so that it covers the patch. There is room for a 30px strip.
func _build_graphrack_zoom_bar() -> Control:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", Design.scale(Design.SPACE_XS))
	bar.alignment = BoxContainer.ALIGNMENT_END

	var readout := Label.new()
	readout.text = "100%"
	readout.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	readout.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	# Held open at the width of the widest reading, so stepping through the ladder does
	# not shuffle the buttons beside it left and right.
	readout.custom_minimum_size.x = Design.scale(48)
	readout.add_theme_font_override("font", Design.numeric_font())
	readout.add_theme_font_size_override("font_size", Design.type(Design.SIZE_SECONDARY))
	readout.add_theme_color_override("font_color", Design.INK_SECOND)
	bar.add_child(readout)

	var out_button := Button.new()
	out_button.text = "−"
	out_button.tooltip_text = "Zoom out"
	out_button.pressed.connect(func() -> void: graphrack.step_zoom(false))
	bar.add_child(_defocus(out_button))

	var reset := Button.new()
	reset.text = "1"
	reset.tooltip_text = "Actual size"
	reset.pressed.connect(func() -> void: graphrack.zoom = 1.0)
	bar.add_child(_defocus(reset))

	var in_button := Button.new()
	in_button.text = "+"
	in_button.tooltip_text = "Zoom in"
	in_button.pressed.connect(func() -> void: graphrack.step_zoom(true))
	bar.add_child(_defocus(in_button))

	var fit := Button.new()
	fit.text = "Fit"
	fit.tooltip_text = "Fit the whole case on screen"
	fit.pressed.connect(func() -> void: graphrack.zoom_to_fit())
	bar.add_child(_defocus(fit))

	graphrack.zoom_changed.connect(func(value: float) -> void:
		readout.text = "%d%%" % int(roundf(value * 100.0))
		_say("graphrack: %d%%" % int(roundf(value * 100.0))))
	return bar


## Selects a view by its tab title.
##
## By name rather than by index. "views.current_tab = 3" meant Outline until a tab was
## added in front of it, at which point it silently meant Sandbox — and the check that
## caught it was a sandbox assertion three hundred lines away, which is a long way from
## the mistake. Tabs are going to keep moving while the patcher is being replaced.
func show_view(title: String) -> bool:
	if views == null:
		return false
	for index in views.get_tab_count():
		if views.get_tab_title(index).to_lower() == title.to_lower():
			views.current_tab = index
			return true
	return false


## Keeps the inspector at a fixed width against the right edge, whatever the window
## is doing, and gives everything else to the graph.
func _fit_side_panel() -> void:
	if split == null or views == null:
		return
	var wanted := side_panel_width if side_panel_open else SIDE_PANEL_COLLAPSED
	var graph_minimum := views.get_combined_minimum_size().x
	# Never wider than the room there is. A minimum size is a promise the container has
	# to keep, so asking for 340 in a window with 200 left does not give a 340px panel —
	# it gives a layout wider than the window, and everything past the edge simply is not
	# drawn: the order chips ran off the right of the screen and the cost line lost its
	# last words. The panel gives way before the window does, and the graph keeps a
	# usable strip whatever happens.
	if split.size.x > 0.0:
		var room: float = split.size.x - minf(graph_minimum, split.size.x * 0.45)
		wanted = int(clampf(float(wanted), float(SIDE_PANEL_COLLAPSED), maxf(room, 0.0)))
	# The minimum size is what actually holds the width open; the split offset alone
	# lets the container squeeze the panel narrower than asked, which clipped the scope
	# and cut the ends off every readout in it.
	if side_panel != null:
		side_panel.custom_minimum_size.x = wanted
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

	# The panel scrolls rather than growing past the bottom of the window. Its content
	# is not a fixed list — the run order grows with the patch, the problem list with
	# the mistakes — so on a short window the cost line and everything under it were
	# simply off-screen with no way to reach them. Vertical only: a sideways scrollbar
	# under a column of text is a sign that something is too wide, not a way to read it.
	var body_scroll := ScrollContainer.new()
	body_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	inset.add_child(body_scroll)

	side_panel_body = VBoxContainer.new()
	side_panel_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	side_panel_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	side_panel_body.add_theme_constant_override("separation", Design.SPACE_M)
	body_scroll.add_child(side_panel_body)

	var panel := side_panel_body

	# The face, first and always. It is what the file is *for* — the graph underneath is
	# how it is built — so it leads the panel rather than sitting under the diagnostics.
	panel.add_child(_field("Panel"))
	patch_face = PatchFace.new()
	patch_face.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	patch_face.reordered.connect(_on_panel_reordered)
	panel.add_child(patch_face)

	# One quiet line, always in the same place. Valid is the normal state and should look
	# like it — a green "No problems." carried as much visual authority as an actual error,
	# so the panel read as urgent when nothing was wrong.
	health_label = Label.new()
	health_label.add_theme_font_size_override("font_size",
		Design.type(Design.SIZE_SECONDARY))
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
		context_heading.text = "The graph"
		_fill_graph_context()
	else:
		context_heading.text = "Selected node"
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
	# A summary, not a census. Chips read well up to a dozen; a 35-node DX7 voice
	# wrapped them into a 428px-tall block, and because nothing in the inspector column
	# scrolls, that became the *minimum height of the editor* — which is how loading a
	# big patch silently pushed the keyboard dock below the bottom of the window. The
	# strip shows the head of the order and folds the rest into one chip that opens the
	# Outline, which is the view built for reading a big graph as a list.
	var order: Array = info["nodes"]
	var shown: int = mini(order.size(), ORDER_CHIP_LIMIT)
	if order.size() == ORDER_CHIP_LIMIT + 1:
		shown = order.size()  # "+1 more" would take the space of the thing it hides
	for index in shown:
		flow.add_child(_stage_chip(str(order[index]["id"])))
	if shown < order.size():
		var more := Button.new()
		more.text = "+%d more" % (order.size() - shown)
		more.tooltip_text = "The full order is in the Outline view."
		more.add_theme_font_size_override("font_size", Design.type(Design.SIZE_SECONDARY))
		more.pressed.connect(func() -> void: show_view("Outline"))
		flow.add_child(_defocus(more))
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
	title.add_theme_font_size_override("font_size", Design.type(Design.SIZE_NODE_TITLE))
	title.add_theme_color_override("font_color", Design.INK_BRIGHT)
	context_panel.add_child(title)
	context_panel.add_child(_value("%s · %s"
		% [type_name, str(descriptor.get("category", ""))], Design.INK_SECOND))

	var summary := Label.new()
	summary.text = str(descriptor.get("summary", ""))
	summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	summary.add_theme_font_size_override("font_size", Design.type(Design.SIZE_SECONDARY))
	summary.add_theme_color_override("font_color", Design.INK_NORMAL)
	context_panel.add_child(summary)

	# A module's name is the document's own, not the registry's, so it is the one thing in
	# this panel that can be typed over. It has to be somewhere: collapse names every fresh
	# definition "part", "part-2", and a patch full of parts is a patch nobody can read.
	#
	# On the instance rather than on a list of definitions, because the instance is the
	# thing on screen — you rename the module by pointing at one of them, the same way you
	# arrange its face by dragging one of them.
	var module_name := _module_of(node_id)
	if module_name != "":
		context_panel.add_child(_field("Module name"))
		var field := LineEdit.new()
		field.text = module_name
		field.add_theme_font_size_override("font_size", Design.type(Design.SIZE_CONTROL))
		field.tooltip_text = "Type a new name and press Enter. Every instance of this " \
			+ "module follows it, and so does an instance still going by the old name."
		# Enter only. A rename that also fired on focus-exit would commit whatever half a
		# name was in the box when somebody clicked away — and the commit rebuilds the
		# panel, so the second path would be reporting focus lost from a freed field.
		field.text_submitted.connect(func(text: String) -> void:
			_on_module_renamed(module_name, text.strip_edges()))
		context_panel.add_child(field)

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
	chip.add_theme_font_size_override("font_size", Design.type(Design.SIZE_TABS))
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
	row.add_theme_font_size_override("font_size", Design.type(Design.SIZE_SECONDARY))
	row.pressed.connect(func() -> void:
		inspecting = {"node": node_id, "port": str(port["name"])})
	return _defocus(row)


func _field(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_override("font", Design.font(Design.WEIGHT_MEDIUM))
	# Body size and normal ink. These name everything in the inspector — "Runs in this
	# order", "Cost" — and they had been a size below and a shade quieter than the graph
	# they describe, which put the panel explaining the instrument behind the instrument.
	label.add_theme_font_size_override("font_size", Design.type(Design.SIZE_BODY))
	label.add_theme_color_override("font_color", Design.INK_NORMAL)
	return label


func _value(text: String, colour: Color = Design.INK_NORMAL) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", Design.type(Design.SIZE_BODY))
	label.add_theme_color_override("font_color", colour)
	return label


## Figures in the tabular face, so a column of costs lines up.
func _numeric(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_override("font", Design.numeric_font())
	label.add_theme_font_size_override("font_size", Design.type(Design.SIZE_NUMERIC))
	label.add_theme_color_override("font_color", Design.INK_NORMAL)
	return label


## A heading in the words it was written in.
##
## These were uppercased here, which turned "The graph" into "THE GRAPH" — small capitals
## used as decoration. Capitals cost the reader the word-shape that lowercase letters
## carry, and this project's typeface was chosen precisely because its lowercase forms
## are unusually distinguishable; setting them in caps at 15px throws away the reason it
## is here. The call sites already pass sentence case, so this only stopped shouting it.
func _section_heading(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_override("font", Design.font(Design.WEIGHT_SEMIBOLD))
	label.add_theme_font_size_override("font_size",
		Design.type(Design.SIZE_HEADING))
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
	if rack != null and rack.is_visible_in_tree():
		rack.refresh_displays()
	if graphrack != null and graphrack.is_visible_in_tree():
		graphrack.refresh_displays()
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
			# Instances glow too: the declared port's signal lives on an inner node in
			# the flattened graph, so the engine-facing source is resolved here, once.
			var source := _engine_signal_source(node_id, str(outputs[index]["name"]))
			_level_targets.append({
				"node": source[0],
				"port": source[1],
				"widget": String(widget.name),
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

	# Fresh widgets are built showing everything, but the zoom has an opinion already.
	# _apply_detail only ran on detail_changed, and a rebuild does not change the
	# detail — so rebuilding while zoomed out (a UI-scale toggle, a palette switch)
	# produced full-detail nodes at 55%, sub-floor text and all, which then snapped
	# back to the honest view on the next zoom step. The level in force gets
	# re-applied to the widgets that were not there when it was announced.
	_apply_detail(graph_edit.detail)

	# Every widget in the marks is now a freed object, and the rows the wand was pointing
	# at went with them. Re-resolving here is what keeps the overlay from drawing against
	# a dangling Control on the frame after a rebuild.
	_refresh_wand()
	_refresh_groups()

	# The rack reads the same document, so it is rebuilt from the same place rather than
	# kept in step by hand.
	if graphrack != null:
		graphrack.registry = registry
		graphrack.patch = patch
		graphrack.rebuild()
	if rack != null:
		rack.registry = registry
		rack.patch = patch
		rack.rebuild()
	_refresh_face()


# ---------------------------------------------------------------------------------
# Modules — stage 2 of docs/modules-design.md.
#
# An instance is one node with the module's declared surface. The editor's whole node
# pipeline — widgets, ports, the rack, the outline, the inspector — consumes registry
# descriptors, so an instance becomes ordinary by synthesizing a descriptor from its
# definition and registering it under "module:<name>". Everything downstream keys on
# _type_key(node) instead of the raw type and never learns anything else. The engine
# knows only the flattened graph, so the two places the editor talks to it about a
# *live* node — setting a parameter, reading a port — translate through the facade
# with _engine_parameter_target and _engine_signal_source.
# ---------------------------------------------------------------------------------

## The registry key a node's descriptor lives under.
func _type_key(node: Dictionary) -> String:
	if str(node.get("type", "")) == "module":
		return "module:%s" % str(node.get("module", ""))
	return str(node.get("type", ""))


## Builds a registry-shaped descriptor for each module definition, so instances flow
## through every code path a plain node does. Signal types, units and parameter ranges
## come from the inner nodes' own registry entries — the facade renames, it does not
## invent.
func _synthesize_module_descriptors() -> void:
	for key in registry.keys().filter(func(k): return str(k).begins_with("module:")):
		registry.erase(key)
	for module_name in patch.get("modules", {}):
		var definition: Dictionary = patch["modules"][module_name]
		var inner := {}
		for node in definition.get("nodes", []):
			inner[node["id"]] = node
		var port_entry := func(binding: Dictionary, list_key: String) -> Dictionary:
			var inner_node: Dictionary = inner.get(binding["node"], {})
			var inner_type: Dictionary = registry.get(str(inner_node.get("type", "")), {})
			for port in inner_type.get(list_key, []):
				if port["name"] == binding["port"]:
					var cloned: Dictionary = port.duplicate()
					cloned["name"] = binding["name"]
					return cloned
			return {"name": binding["name"], "type": "control", "doc": ""}
		var inputs: Array = []
		for binding in definition.get("inputs", []):
			inputs.append(port_entry.call(binding, "inputs"))
		var outputs: Array = []
		for binding in definition.get("outputs", []):
			outputs.append(port_entry.call(binding, "outputs"))
		var parameters: Array = []
		for binding in definition.get("parameters", []):
			var inner_node: Dictionary = inner.get(binding["node"], {})
			var inner_type: Dictionary = registry.get(str(inner_node.get("type", "")), {})
			for parameter in inner_type.get("parameters", []):
				if parameter["name"] == binding["parameter"]:
					var cloned: Dictionary = parameter.duplicate()
					cloned["name"] = binding["name"]
					# The definition's own inner value, when set, is the default the
					# instance starts from — that is what "definition" means.
					var authored: Variant = inner_node.get("parameters", {}) \
						.get(binding["parameter"], null)
					if authored != null:
						cloned["default"] = authored
					parameters.append(cloned)
					break
		var descriptor := {
			"name": "module:%s" % module_name,
			"display_name": _module_display_name(str(module_name)),
			"category": "Modules",
			"summary": str(definition.get("description", "")),
			"inputs": inputs,
			"outputs": outputs,
			"parameters": parameters,
		}
		var panel_rows := _panel_rows(definition, parameters)
		if not panel_rows.is_empty():
			descriptor["panel_rows"] = panel_rows
		descriptor["offers"] = _parameter_offers(definition)
		descriptor["port_offers"] = _port_offers(definition)
		registry["module:%s" % module_name] = descriptor


## Every inner knob this module could show and does not: the surface it has not got.
##
## The wand draws these as ghosts on the face, so putting one on is a drag rather than a
## trip to a list of every parameter in the definition. Descriptor-shaped like the real
## ones, plus the binding it would need, because the thing that draws a knob should not
## have to care which kind it is holding.
func _parameter_offers(definition: Dictionary) -> Array:
	var taken := {}
	for binding in definition.get("parameters", []):
		taken["%s/%s" % [str(binding["node"]), str(binding["parameter"])]] = true
	var offers: Array = []
	for node in definition.get("nodes", []):
		var inner_type: Dictionary = registry.get(str(node.get("type", "")), {})
		for parameter in inner_type.get("parameters", []):
			var key := "%s/%s" % [str(node["id"]), str(parameter["name"])]
			if taken.has(key):
				continue
			var cloned: Dictionary = (parameter as Dictionary).duplicate()
			var authored: Variant = node.get("parameters", {}).get(parameter["name"], null)
			if authored != null:
				cloned["default"] = authored
			cloned["offer"] = {"node": str(node["id"]),
				"parameter": str(parameter["name"])}
			offers.append(cloned)
	return offers


## Every inner port this module could expose and does not.
##
## An input already fed from inside is left out: it has a source, and offering to give it
## a second one is offering to sum two things nobody asked to sum. Outputs are always
## offered — an inner output feeding another inner node can perfectly well also leave the
## module, which is what fan-out is.
func _port_offers(definition: Dictionary) -> Array:
	var fed := {}
	for connection in definition.get("connections", []):
		fed["%s/%s" % [str(connection["to"]["node"]), str(connection["to"]["port"])]] = true
	var declared := {}
	for side in ["inputs", "outputs"]:
		for binding in definition.get(side, []):
			declared["%s/%s" % [str(binding["node"]), str(binding["port"])]] = true
	var offers: Array = []
	for node in definition.get("nodes", []):
		var inner_type: Dictionary = registry.get(str(node.get("type", "")), {})
		for side in ["inputs", "outputs"]:
			for port in inner_type.get(side, []):
				var key := "%s/%s" % [str(node["id"]), str(port["name"])]
				if declared.has(key):
					continue
				if side == "inputs" and fed.has(key):
					continue
				var cloned: Dictionary = (port as Dictionary).duplicate()
				cloned["offer"] = {"node": str(node["id"]), "port": str(port["name"]),
					"is_input": side == "inputs"}
				offers.append(cloned)
	return offers


## The knobs a module's face shows, row by row, resolved against its exports.
##
## `parameters` above is the whole declared surface and stays that way — the inspector
## sets any of it, controls and automation target any of it, the file carries all of it.
## This is only the face. A definition with no panel gets no rows and every consumer falls
## back to laying out the full surface, which is what modules did before panels existed.
##
## A row naming something this module does not export is dropped rather than refused: a
## panel is presentation, and the rule presentation follows here is arrangement's, not the
## surface's. Unlike arrangement.rack_order, exports the panel leaves out are *not*
## appended — leaving a knob off is the whole authoring act.
func _panel_rows(definition: Dictionary, parameters: Array) -> Array:
	var panel: Dictionary = definition.get("panel", {})
	var rows: Array = panel.get("rows", [])
	if rows.is_empty():
		return []
	var by_name := {}
	for parameter: Dictionary in parameters:
		by_name[str(parameter["name"])] = parameter
	var labels: Dictionary = panel.get("labels", {})
	var placed := {}
	var out: Array = []
	for row in rows:
		var resolved: Array = []
		for export_name in row:
			var key := str(export_name)
			if not by_name.has(key) or placed.has(key):
				continue
			placed[key] = true
			# `name` is the binding — the knob writes back through it — so a caption is a
			# second field beside it, never a rename. See Knob._name_text.
			var cloned: Dictionary = (by_name[key] as Dictionary).duplicate(true)
			if labels.has(key) and str(labels[key]) != "":
				cloned["display_name"] = str(labels[key])
			resolved.append(cloned)
		if not resolved.is_empty():
			out.append(resolved)
	return out


## What a module may be called: letters, digits, underscore and hyphen.
##
## Narrower than the schema, which puts no pattern on a definition's key at all, and
## narrower than a node id, which also permits `.` and `:`. Both of those matter after
## expansion — the dot is the separator between an instance and the node inside it — so a
## module called `a.b` would produce ids nobody could read back. A name is refused here
## rather than allowed and regretted at load.
const MODULE_NAME_ALLOWED := "^[A-Za-z0-9_-]+$"


## Renames a definition, and any instance still going by its old name.
##
## The instance rule is the whole reason this exists. ModuleAuthor.collapse names a fresh
## definition "part" and then names the instance after it, so both arrive called the same
## placeholder and the running order reads `part.filter`. Renaming the definition alone
## would fix the half nobody sees and leave the half everything prints. An instance the
## author has already named something else is left alone — that name was a decision, and
## this is not the place to overrule it.
func _on_module_renamed(old_name: String, new_name: String) -> void:
	var definitions: Dictionary = patch.get("modules", {})
	if not definitions.has(old_name) or new_name == old_name:
		_refresh_context()
		return
	if not RegEx.create_from_string(MODULE_NAME_ALLOWED).search(new_name):
		_say("a module name may hold letters, digits, _ and - and nothing else")
		_refresh_context()
		return
	if definitions.has(new_name):
		_say("this patch already has a module called '%s'" % new_name)
		_refresh_context()
		return
	# An instance may only take the new name if nothing else in the document has it.
	var taken := {}
	for node in patch.get("nodes", []):
		taken[str(node["id"])] = true
	var rename_instances: bool = not taken.has(new_name)

	_begin_edit()
	# Rebuilt in order rather than erased and re-added, because a definition that jumped
	# to the end of the file every time it was renamed would make a one-word change look
	# like a rewrite in the diff.
	var renamed_modules := {}
	for key in definitions:
		if str(key) == old_name:
			renamed_modules[new_name] = definitions[key]
		else:
			renamed_modules[key] = definitions[key]
	patch["modules"] = renamed_modules

	var moved := {}
	for node in patch.get("nodes", []):
		if str(node.get("module", "")) == old_name:
			node["module"] = new_name
		if rename_instances and str(node["id"]) == old_name \
				and str(node.get("type", "")) == "module":
			moved[old_name] = new_name
			node["id"] = new_name
	# Everything that refers to an instance by id follows it. Miss one of these and the
	# patch is quietly broken in a way that only shows up as a cable that stopped
	# existing — see the connection, control and automation lists in patch.schema.json.
	if not moved.is_empty():
		for connection in patch.get("connections", []):
			if moved.has(str(connection["from"]["node"])):
				connection["from"]["node"] = moved[str(connection["from"]["node"])]
			if moved.has(str(connection["to"]["node"])):
				connection["to"]["node"] = moved[str(connection["to"]["node"])]
		for control in patch.get("controls", []):
			var control_target: Dictionary = control.get("target", {})
			if moved.has(str(control_target.get("node", ""))):
				control_target["node"] = moved[str(control_target["node"])]
		for lane in patch.get("automation", []):
			var lane_target: Dictionary = lane.get("target", {})
			if moved.has(str(lane_target.get("node", ""))):
				lane_target["node"] = moved[str(lane_target["node"])]
		# Arrangement hints are keyed by id too, and a stale place is a module that jumps
		# back to the seed the next time the patch is opened.
		var arrangement: Dictionary = patch.get(GraphRack.ARRANGEMENT_KEY, {})
		var hints: Dictionary = arrangement.get(GraphRack.PLACES_KEY, {})
		for id in moved:
			if hints.has(id):
				hints[moved[id]] = hints[id]
				hints.erase(id)
		# And the rack order, which is a list of ids rather than a map of them.
		var order: Array = arrangement.get(GraphRack.ORDER_KEY, [])
		for index in order.size():
			if moved.has(str(order[index])):
				order[index] = moved[str(order[index])]
		# The inspector is looking at an instance that has just been renamed underneath
		# it, so it follows rather than emptying — otherwise renaming a module costs you
		# the selection, and the next thing anybody wants after naming a module is to keep
		# working on it.
		if moved.has(str(inspecting.get("node", ""))):
			inspecting["node"] = moved[str(inspecting["node"])]

	_synthesize_module_descriptors()
	await _rebuild_view()
	var still: GraphNode = widgets.get(str(inspecting.get("node", "")))
	if still != null:
		still.selected = true
	_apply()
	_refresh_context()
	_commit_edit("rename %s to %s" % [old_name, new_name])
	if rename_instances:
		_say("renamed '%s' to '%s', and the instance with it" % [old_name, new_name])
	else:
		_say("renamed '%s' to '%s'" % [old_name, new_name])


## A module's name as a person would write it: "dx7_operator" is a DX7 Operator.
##
## capitalize() alone gave "Dx7 Operator", because it has no way to know that dx7 is a
## model number rather than a word. A token carrying a digit is one — dx7, opl2, ym2612 —
## so it goes up in full, and everything else is capitalised normally. The rule is about
## the shape of the token rather than a list of chips, so the next importer's module
## reads correctly without anyone remembering to come back here.
func _module_display_name(module_name: String) -> String:
	var words: Array[String] = []
	for token in module_name.split("_", false):
		var word := str(token)
		var has_digit := false
		for index in word.length():
			if word[index] >= "0" and word[index] <= "9":
				has_digit = true
				break
		words.append(word.to_upper() if has_digit else word.capitalize())
	return " ".join(words)


## What this build is, and when it was made.
##
## Written by tools/stamp-build.mjs at build and export time and read here, never
## committed — see the note in .gitignore for why a checked-in stamp is worse than none.
## When there is no stamp the answer is "development build", which is exactly right for
## a run straight from source: nothing built, nothing to be stale.
const BUILD_STAMP_PATH := "res://build_stamp.json"

var _stamp_cache: Dictionary = {}
var _stamp_read := false

func _build_stamp() -> Dictionary:
	if _stamp_read:
		return _stamp_cache
	_stamp_read = true
	if not FileAccess.file_exists(BUILD_STAMP_PATH):
		return _stamp_cache
	var file := FileAccess.open(BUILD_STAMP_PATH, FileAccess.READ)
	if file == null:
		return _stamp_cache
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if parsed is Dictionary:
		_stamp_cache = parsed
	return _stamp_cache


## The tab or window title carries the version, which is where "am I looking at a bundle
## my browser cached last week" actually gets answered: by glancing at the tab after a
## reload, rather than by opening a menu to check. The document name stays first because
## that is what somebody with six tabs open is picking between.
func _refresh_window_title() -> void:
	var version := str(_build_stamp().get("short", "dev"))
	DisplayServer.window_set_title("%s — SoundGraph %s" % [document_name, version])


## The one-line answer to "am I running a stale build".
##
## Age rather than only a timestamp, because staleness is a question about *elapsed
## time* and making the reader subtract two dates is making them do the work the line
## exists to save. The absolute time comes too, for when the answer is "no, look at it
## yourself".
func _build_description() -> String:
	var stamp := _build_stamp()
	if stamp.is_empty():
		return "development build — running from source, unstamped"
	var parts: Array[String] = [str(stamp.get("short", "unknown"))]
	var built := int(stamp.get("built_unix", 0))
	if built > 0:
		parts.append("built %s ago" % _elapsed(int(Time.get_unix_time_from_system()) - built))
		parts.append(str(stamp.get("built_utc", "")))
	if str(stamp.get("target", "")) != "":
		parts.append(str(stamp["target"]))
	if bool(stamp.get("dirty", false)):
		parts.append("uncommitted changes")
	return "  ·  ".join(parts)


## Coarse on purpose: nobody deciding whether to reload wants "2 days, 4 hours".
func _elapsed(seconds: int) -> String:
	if seconds < 0:
		return "no time at all"
	if seconds < 90:
		return "%d seconds" % seconds
	if seconds < 5400:
		return "%d minutes" % int(round(seconds / 60.0))
	if seconds < 172800:
		return "%d hours" % int(round(seconds / 3600.0))
	return "%d days" % int(round(seconds / 86400.0))


## Where the engine actually hears about an instance's exported parameter.
func _engine_parameter_target(node_id: String, parameter: String) -> Array:
	for node in patch.get("nodes", []):
		if node["id"] != node_id or str(node.get("type", "")) != "module":
			continue
		var definition: Dictionary = patch.get("modules", {}).get(str(node["module"]), {})
		for binding in definition.get("parameters", []):
			if binding["name"] == parameter:
				return ["%s.%s" % [node_id, binding["node"]], binding["parameter"]]
	return [node_id, parameter]


## Where an instance's declared port actually carries signal, for scopes and glow.
func _engine_signal_source(node_id: String, port: String) -> Array:
	for node in patch.get("nodes", []):
		if node["id"] != node_id or str(node.get("type", "")) != "module":
			continue
		var definition: Dictionary = patch.get("modules", {}).get(str(node["module"]), {})
		for binding in definition.get("outputs", []):
			if binding["name"] == port:
				return ["%s.%s" % [node_id, binding["node"]], binding["port"]]
	return [node_id, port]


## How far the graph's world space is stretched relative to the document's.
##
## Node widths scale with the reader's UI preference. The positions in the file do not,
## and must not: they belong to the document, and a patch should not move because the
## person opening it likes larger text. Those two facts together are what put 464px-wide
## nodes 400 units apart at XL — every node overlapping its neighbour by 64 units at
## every zoom — and it presented as a text bug, because what you see is one node's "out"
## printed over the next one's "in". The labels were placed correctly the whole time,
## inside node rectangles that were on top of each other.
##
## So world = document x this, converted at the three places the two spaces meet: making
## a widget, reading a widget back, and dropping a new node where the pointer is.
func _graph_scale() -> float:
	return Design.SCALE_FACTORS[Design.ui_scale]


func _create_widget(node: Dictionary) -> void:
	var type_name: String = _type_key(node)
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
		node.get("position", {}).get("y", 0.0)) * _graph_scale()
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

	# One row carries a port on each flank and a slice of the knob grid between them.
	#
	# This is the rack module's layout, reached without leaving GraphEdit's slot system: a
	# slot anchors its ports at the *row's* vertical centre on the node edge, so a row is
	# free to be as tall as a rack cell and to hold whatever it likes in the middle. Ports
	# used to be rows of their own stacked above the parameters, which is the arrangement
	# that made a graph node read as a different kind of object from the module it stands
	# for — and which spent over half a DX7 operator's height on port rows alone.
	#
	# Rows are max(ports, knob lines) rather than the sum. Surplus ports keep a short
	# jack-only row; surplus knob lines get a row with no slot on it.
	var parameters: Array = descriptor.get("parameters", [])
	var port_rows: int = maxi(inputs.size(), outputs.size())
	var cell_lines: int = int(ceil(float(parameters.size()) / float(PARAMETERS_PER_LINE)))
	# Progressive complexity, counted in lines: a node shows its common case and says how
	# much it is holding back rather than hiding it silently.
	var always_visible: int = 1 if parameters.size() > 3 else cell_lines
	var folded: Array[Control] = []

	for row in maxi(port_rows, cell_lines):
		var line := HBoxContainer.new()
		line.add_theme_constant_override("separation", Design.scale(Design.SPACE_M))
		line.alignment = BoxContainer.ALIGNMENT_CENTER
		line.set_meta("row", "module")
		# A row with a slot on it may never be hidden. GraphEdit binds a slot to the index
		# of a *visible* child, so hiding one renumbers every slot below it and the cables
		# reattach to the wrong ports.
		line.set_meta("has_slot", row < port_rows)

		# Name and unit as two labels, not one string.
		#
		# "cutoff_mod  (octaves)" gave the unit the same weight and colour as the name,
		# so a column of ports read as a wall of similar-length phrases and the thing you
		# were scanning for — the name — had to be picked out of each one. Same
		# information, ranked: the unit is metadata and now looks like it. Parentheses
		# gone too; they were doing the separating that a colour change does better.
		var left := _port_label(inputs[row] if row < inputs.size() else {}, false)
		left.set_meta("port_label", true)
		line.add_child(left)

		var cells := HBoxContainer.new()
		cells.add_theme_constant_override("separation", Design.scale(Design.SPACE_M))
		cells.alignment = BoxContainer.ALIGNMENT_CENTER
		cells.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cells.set_meta("cells", true)
		for column in PARAMETERS_PER_LINE:
			var index: int = row * PARAMETERS_PER_LINE + column
			if index < parameters.size():
				cells.add_child(_build_parameter_row(node, parameters[index]))
		line.add_child(cells)
		line.set_meta("cells_box", cells)

		var right := _port_label(outputs[row] if row < outputs.size() else {}, true)
		right.set_meta("port_label", true)
		line.add_child(right)
		widget.add_child(line)

		if cells.get_child_count() > 0 and row >= always_visible:
			# Recorded, not just hidden. The zoom level-of-detail hides these too, and when
			# it puts them back it must not un-collapse what the reader chose to fold away.
			cells.visible = false
			cells.set_meta("collapsed", true)
			folded.append(cells)
		_fit_row_height(line)

		if row >= port_rows:
			continue
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

	_add_disclosure(widget, folded)

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
		label.add_theme_font_size_override("font_size", Design.type(Design.SIZE_NODE_TITLE))
		label.add_theme_color_override("font_color", Design.INK_BRIGHT)
		# Centred and in capitals, as on the module. A left title with a tag pushed to the
		# right is a software header; a centred legend is a panel, and the whole point of
		# this pass is that the two views are drawings of one object.
		#
		# Upper-cased for display only. The node's name is the reader's own text and is
		# still stored, searched and saved exactly as they typed it.
		label.text = label.text.to_upper()
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		# Findable later: the counter-scaling that keeps titles legible when zoomed out
		# needs this label back without walking the titlebar again on every wheel click.
		widget.set_meta("title_label", label)
		break

	var category := str(descriptor.get("category", ""))
	if category == "":
		return
	var tag := Label.new()
	# Sentence case, not capitals: the same argument as the section headings, and this one
	# was the smallest text on the node while shouting the least important thing on it.
	tag.text = category
	tag.add_theme_font_override("font", Design.font(Design.WEIGHT_SEMIBOLD))
	# Secondary, not heading. The tag shares a line with the node title and is the
	# quieter of the two on purpose; when SIZE_HEADING grew to proper heading size the
	# tag could not follow without arguing with the title six pixels to its left.
	tag.add_theme_font_size_override("font_size", Design.type(Design.SIZE_SECONDARY))
	tag.add_theme_color_override("font_color", Design.INK_SECOND)
	tag.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# Right-aligned and last, which reserves that end of the header for node actions
	# later without the category having to move when they arrive.
	tag.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	# Metadata, and the first thing decluttering drops: it is the one piece of node text
	# that is *not* pinned to a screen minimum, because the honest answer when there is
	# no room for a category is to stop saying the category. The level of detail hides
	# it below FULL rather than drawing it at nine pixels.
	widget.set_meta("category_tag", tag)
	titlebar.add_child(tag)

	# A counterweight the same width as the tag, at the other end.
	#
	# Without it "centred" means centred in whatever half of the bar the tag left over,
	# which is not centred over the node — the first attempt set the alignment, looked
	# right in the code and came out plainly off-centre in the picture. Measured from the
	# text rather than read back from the layout, so it is correct on the first frame.
	var counterweight := Control.new()
	counterweight.custom_minimum_size.x = tag.get_theme_font("font").get_string_size(
		category, HORIZONTAL_ALIGNMENT_LEFT, -1.0,
		tag.get_theme_font_size("font_size")).x
	counterweight.mouse_filter = Control.MOUSE_FILTER_IGNORE
	titlebar.add_child(counterweight)
	titlebar.move_child(counterweight, 0)
	# It exists to balance the tag, so it goes when the tag goes.
	widget.set_meta("category_counterweight", counterweight)


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
	name_label.add_theme_font_override("font", Design.font(Design.WEIGHT_MEDIUM))
	name_label.add_theme_font_size_override("font_size", Design.type(Design.SIZE_BODY))
	name_label.add_theme_color_override("font_color", Design.INK_NORMAL)
	name_label.set_meta("port_label", true)
	# Operational: what is plugged in here is not guessable from the colour alone, so
	# the name is pinned to a readable size in screen space rather than shrinking with
	# the node. See PatchGraph.ScreenText.
	name_label.set_meta("screen_min", Design.MIN_SCREEN_LABEL)
	name_label.set_meta("screen_kind", "port")
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
	# The numeric family, because a unit belongs to the number it annotates — "440.0 Hz"
	# is one phrase and should not change face halfway through. One size and one weight
	# down from the value, which is the whole of its styling: rank carried by type, not
	# by dimming the ink further.
	label.add_theme_font_override("font", Design.unit_font())
	label.add_theme_font_size_override("font_size", Design.type(Design.SIZE_UNIT))
	label.add_theme_color_override("font_color", Design.INK_SECOND)
	label.set_meta("port_label", true)
	label.set_meta("screen_min", Design.MIN_SCREEN_UNIT)
	label.set_meta("screen_kind", "unit")
	return label


## A module row is as tall as what it is carrying, and no taller.
##
## Rows holding knob cells get a rack cell's height; rows down to a pair of jacks get the
## port height back. Called on build and again whenever the cells come and go, because a
## row that kept its tall minimum after its knobs were folded away left a node with a band
## of empty panel where the controls used to be — which is the "full node with pieces
## missing" that the level of detail exists to avoid.
func _fit_row_height(line: Control) -> void:
	var cells: Control = line.get_meta("cells_box") if line.has_meta("cells_box") else null
	var tall: bool = cells != null and cells.visible and cells.get_child_count() > 0
	line.custom_minimum_size.y = Design.scale(
		Design.PARAMETER_CELL_HEIGHT if tall else Design.NODE_ROW_HEIGHT)
	# A row with nothing on it at all disappears — unless it is carrying a slot, in which
	# case it stays whatever else happens, because a hidden row renumbers the cables.
	if not bool(line.get_meta("has_slot", false)):
		line.visible = tall


func _add_disclosure(widget: GraphNode, folded: Array[Control]) -> void:
	if folded.is_empty():
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
	# Parameters, not lines. A line holds two of them, so "1 more" for two hidden knobs
	# is simply untrue — and this label is the only thing telling the reader there is
	# anything behind it.
	var hidden_count := 0
	for hidden_cells in folded:
		hidden_count += (hidden_cells as Control).get_child_count()
	toggle.text = "%d more" % hidden_count
	toggle.icon = _icon(Icons.Kind.CARET_RIGHT, Design.INK_SECOND,
		Design.SIZE_SECONDARY)
	toggle.alignment = HORIZONTAL_ALIGNMENT_LEFT
	toggle.add_theme_font_size_override("font_size", Design.type(Design.SIZE_SECONDARY))
	toggle.add_theme_color_override("font_color", Design.INK_SECOND)
	toggle.add_theme_color_override("font_hover_color", Design.INK_NORMAL)
	toggle.add_theme_color_override("font_pressed_color", Design.INK_SECOND)
	# The cells fold, not the rows. A folded row may still be carrying a port on each
	# flank, and hiding it would take the cables with it — so what collapses is the knob
	# box in the middle, and the row shrinks back to jack height around it.
	toggle.toggled.connect(func(pressed: bool) -> void:
		for cells in folded:
			cells.set_meta("collapsed", not pressed)
			cells.visible = pressed and graph_edit.detail == PatchGraph.Detail.FULL
			var line := cells.get_parent() as Control
			if line != null:
				_fit_row_height(line)
		toggle.text = "fewer" if pressed else "%d more" % hidden_count
		toggle.icon = _icon(Icons.Kind.CARET_DOWN if pressed else Icons.Kind.CARET_RIGHT,
			Design.INK_SECOND, Design.SIZE_SECONDARY))
	toggle.set_meta("row", "disclosure")
	widget.add_child(_defocus(toggle))


## One parameter, as the rack's cell: dial on top, name under it, number under that.
##
## Stacked rather than laid out sideways, which is a reversal of the previous shape and
## the point of the whole exercise — a graph node is meant to read as the same object as
## its rack module, and the cell is the loudest part of that. The horizontal version was
## chosen when the height sums looked bad, on a measurement that held the port rows fixed
## and so compared the wrong thing; ports share these rows now, which is where the height
## comes back from.
##
## Real controls rather than the rack's drawn captions, deliberately. The rack draws its
## own name and value inside Knob._draw, which is cheaper and completely opaque to the
## level of detail — ScreenText compensates *Labels*, and a drawn caption is not one. So
## the cell is a dial with a Label and a ValueField under it: the rack's shape with the
## graph's behaviour, still draggable, still typeable, still legible when zoomed out.
func _build_parameter_row(node: Dictionary, parameter: Dictionary) -> Control:
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 0)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.set_meta("cell", "parameter")
	# What the wand needs to name this knob once somebody points at it. The row is the
	# thing with a rect; without this it is a rect with no idea what it controls.
	row.set_meta("parameter_name", str(parameter["name"]))
	var name: String = parameter["name"]
	var node_id: String = node["id"]
	var current: float = float(node.get("parameters", {}).get(name, parameter["default"]))

	# Full body size and medium weight, the same rank as the value it names. These were a
	# size down, secondary ink and regular — three separate ways of saying "small print"
	# stacked on the words somebody reads *every time* they reach for a knob. Parameter
	# names are operating text; the unit is the metadata here, and it is already smaller.
	var label := Label.new()
	label.text = name
	label.clip_text = true
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.tooltip_text = str(parameter.get("doc", ""))
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_override("font", Design.font(Design.WEIGHT_MEDIUM))
	label.add_theme_font_size_override("font_size", Design.type(Design.SIZE_BODY))
	label.add_theme_color_override("font_color", Design.INK_NORMAL)
	label.set_meta("screen_min", Design.MIN_SCREEN_LABEL)
	label.set_meta("screen_kind", "parameter")

	# Wide enough to still hold this name once the type has hit its screen floor.
	#
	# The name box is what ScreenText compensates *into*: below the full-detail floor the
	# label is redrawn at MIN_SCREEN_LABEL rather than at the zoom, and a box too narrow
	# for that text gets nothing drawn in it at all — a control with no word beside it,
	# which is the one outcome the level of detail may not produce. So the reservation is
	# derived from the worst case rather than picked: the name at its own minimum, over
	# the lowest zoom that still draws a control. A flat 84px was two pixels short of
	# "safety_limit" at 0.90 and dropped it, and the number before that — 96 — was only
	# ever right by accident.
	var floor_zoom: float = maxf(PatchGraph._full_floor(), 0.1)
	var name_font := Design.font(Design.WEIGHT_MEDIUM)
	var name_room: float = name_font.get_string_size(name, HORIZONTAL_ALIGNMENT_LEFT, -1.0,
		Design.screen_minimum(Design.MIN_SCREEN_LABEL)).x / floor_zoom
	# Floored so short names still line up in a column, capped so one very long one cannot
	# set the width of every node it appears in — past the cap the honest drop is correct.
	label.custom_minimum_size.x = clampf(ceilf(name_room), Design.scale(84),
		Design.scale(132))

	# Findable by the level of detail, which gives this label the slider's room once the
	# slider has stopped being worth drawing.
	row.set_meta("name_label", label)

	if parameter.has("enum"):
		# A dropdown sits where the dial sits — on top, with the words under it.
		#
		# Same argument as when the dropdown moved to the left of the horizontal cell: it
		# is the control, so it goes where controls go. Only the direction has changed.
		var options := OptionButton.new()
		for entry in parameter["enum"]:
			options.add_item(str(entry))
		options.selected = clampi(int(round(current)), 0, parameter["enum"].size() - 1)
		options.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		# Wide enough for the widest option, not for the chosen one. An OptionButton
		# measures itself against whatever it is currently showing, so picking "triangle"
		# after "sine" widened the control, which widened the cell, which relaid the line
		# under the pointer that had just clicked it — the same reflow the knob's readout
		# avoids by reserving room for the widest value it could ever show.
		var option_font := Design.font(Design.WEIGHT_MEDIUM)
		var option_size := Design.type(Design.SIZE_CONTROL)
		var widest := 0.0
		for entry in parameter["enum"]:
			widest = maxf(widest, option_font.get_string_size(str(entry),
				HORIZONTAL_ALIGNMENT_LEFT, -1, option_size).x)
		# Text, plus the arrow and the button's own padding.
		options.custom_minimum_size.x = widest + Design.scale(40)
		# The chosen option, in words, for the bands where the dropdown is put away.
		#
		# Without it a compact node showed the word "shape" with nothing beside it and an
		# Output node showed "safety_limit" floating on its own — a label whose value had
		# been hidden with the control that carried it, which is the same failure as an
		# unlabelled slider seen from the other end. A dropdown is a control; the option
		# it is showing is information, and information survives the control.
		var chosen := Label.new()
		chosen.text = str(parameter["enum"][clampi(int(round(current)), 0,
			parameter["enum"].size() - 1)])
		chosen.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		chosen.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		chosen.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		chosen.add_theme_font_override("font", Design.font(Design.WEIGHT_MEDIUM))
		chosen.add_theme_font_size_override("font_size", Design.type(Design.SIZE_NUMERIC))
		chosen.add_theme_color_override("font_color", Design.INK_BRIGHT)
		chosen.set_meta("screen_min", Design.MIN_SCREEN_LABEL)
		chosen.set_meta("screen_kind", "value")
		chosen.visible = false
		options.item_selected.connect(func(index: int) -> void:
			chosen.text = str(parameter["enum"][index])
			_begin_edit()
			_set_parameter(node_id, name, float(index))
			_commit_edit("set %s" % name))

		options.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		row.add_child(_defocus(options))
		row.add_child(label)
		row.add_child(chosen)
		row.set_meta("enum_value", chosen)
		_remember_parameter_widget(node_id, name, options, null, parameter)
		return row

	# The rack's knob, in compact dress. Routed through the rack's own signals rather
	# than through a second copy of the wiring: `parameter_changed` already lands in
	# _on_rack_parameter_changed, which writes the value and syncs whichever widget did
	# not originate it, so the two views cannot drift apart over what a knob means.
	var slider := Rack.Knob.new()
	slider.rack = rack
	# Compact still means "dial only, no drawn captions" — the captions below are real
	# Labels so the level of detail can reach them. Same dial, same size, same keyboard.
	slider.compact = true
	slider.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	slider.node_id = node_id
	slider.descriptor = parameter
	slider.set_value_silently(current)
	slider.tooltip_text = str(parameter.get("doc", ""))


	# The number is a control, not a caption. A slider 112px wide cannot resolve 20 Hz
	# to 20 kHz — at the bottom of an exponential range one pixel is several hertz —
	# so the only way to ask for exactly 440 was to drag until it happened to say 440.
	# Drag the figure, double click to type it, Alt-click for the default.
	var readout := ValueField.new()
	readout.custom_minimum_size.x = Design.scale(72)
	readout.centred = true
	readout.text = _format_with_unit(parameter, current)
	readout.default_value = float(parameter["default"])
	readout.position_now = _to_position(parameter, current)
	readout.to_value = func(position: float) -> float:
		return _to_value(parameter, position)
	readout.to_position = func(value: float) -> float:
		return _to_position(parameter, value)
	readout.value_submitted.connect(func(value: float) -> void:
		var clamped: float = clampf(value, float(parameter["min"]), float(parameter["max"]))
		slider.set_value_silently(clamped)
		readout.position_now = _to_position(parameter, clamped)
		readout.text = _format_with_unit(parameter, clamped)
		_set_parameter(node_id, name, clamped))
	# One gesture is one undo step, whether it moved one pixel or three hundred.
	readout.drag_started.connect(func() -> void: _begin_edit())
	readout.drag_finished.connect(func() -> void: _commit_edit("set %s" % name))

	# No value_changed/drag handlers here: the knob emits on the rack's signals and
	# _on_rack_parameter_changed owns the write and the sync. Wiring it twice would put
	# two writers on one parameter, which is how a drag ends up costing two undo steps.

	# Dial, name, number — top to bottom, the rack's order. The name and the number each
	# get the full width of the cell now rather than sharing a half-width line with the
	# dial, which is also what stops a long name from crowding its own value out of the
	# picture: "safety_limit" and its number no longer compete for the same strip.
	row.add_child(_defocus(slider))
	row.add_child(label)
	row.add_child(readout)
	row.set_meta("value_field", readout)
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
	# The engine runs the flattened graph, so an instance's exported knob reaches it
	# by its inner name; the document records the value on the instance, because the
	# facade is what the file says.
	var target := _engine_parameter_target(node_id, parameter)
	engine.set_parameter(target[0], target[1], value)
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


## The same edit as _on_connection_request, arriving from a rack instead of a GraphEdit.
##
## By port name rather than by index, because that is what a rack has: a jack knows what
## it is called and never learned its position in a slot list. The two paths agree on
## everything that matters — several cables into one input sum, an exact duplicate is a
## slip and is refused.
func _on_rack_connection_made(from_node: String, from_port: String,
		to_node: String, to_port: String) -> void:
	for connection in patch.get("connections", []):
		if str(connection["from"]["node"]) == from_node \
				and str(connection["from"]["port"]) == from_port \
				and str(connection["to"]["node"]) == to_node \
				and str(connection["to"]["port"]) == to_port:
			_say("%s.%s already feeds %s.%s" % [from_node, from_port, to_node, to_port])
			return
	_begin_edit()
	patch["connections"].append({
		"from": {"node": from_node, "port": from_port},
		"to": {"node": to_node, "port": to_port},
	})
	await _rebuild_view()
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
	if control is Rack.Knob:
		# Silently: the knob that emitted this is already where it should be, and the
		# other view's knob has to follow without emitting again and starting a loop.
		control.set_value_silently(value)
	elif control is HSlider:
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
		Design.type(Design.SIZE_NUMERIC))
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
	search_hint.add_theme_font_size_override("font_size", Design.type(Design.SIZE_SECONDARY))
	search_hint.add_theme_color_override("font_color", Design.INK_SECOND)
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
	summary.add_theme_font_size_override("font_size", Design.type(Design.SIZE_SECONDARY))
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
	# Synthesized module descriptors are not addable types; the palette lists the core's
	# vocabulary only.
	var names: PackedStringArray = engine.search_nodes(query) if query.strip_edges() != "" \
		else PackedStringArray(registry.keys().filter(
			func(k): return not str(k).begins_with("module:")))

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
	# Screen to world by the zoom, world to document by the UI scale. Only the first was
	# happening, so at XL a node dropped where the pointer was landed a third of the way
	# further out every time the file was reopened.
	var spawn := (_search_spawn + graph_edit.scroll_offset) / graph_edit.zoom \
		/ _graph_scale()
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
		arrange_popup.set_item_disabled(2, _selected_ids().size() < 2)
	_refresh_wand()


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


## Wiring becomes notation: the selection turns into a definition plus one instance.
## The transform itself lives in ModuleAuthor and never touches the editor; this is
## the ceremony around it — the undo snapshot, the descriptor refresh, the rebuild.
##
## The wand's picks ride along as the nominated surface. Empty, which it is unless
## somebody went and pointed at things, collapse derives a surface exactly as it always
## has — so this stays one verb with one keyboard path whether or not the face was
## designed.
func _collapse_selection() -> void:
	var selected := _selected_ids()
	if selected.size() < 2:
		_say("select two or more nodes to collapse into a module")
		return
	var terminals: Array = []
	for type_name in registry:
		if str(registry[type_name].get("category", "")) == "Terminals":
			terminals.append(type_name)
	var picked: Array = wand_picks.duplicate(true)
	var result := ModuleAuthor.collapse(patch, selected, terminals, picked)
	if not result.ok():
		_say(result.error)
		return
	_begin_edit()
	patch = result.patch
	_synthesize_module_descriptors()
	_set_wand(false)
	await _rebuild_view()
	_apply()
	_commit_edit("collapse into %s" % result.module_name)
	if picked.is_empty():
		_say("collapsed %d nodes into '%s'" % [selected.size(), result.module_name])
	else:
		_say("collapsed %d nodes into '%s', wearing the %d things you picked"
			% [selected.size(), result.module_name, picked.size()])


# ---------------------------------------------------------------------------------
# Open modules
#
# The frames on the canvas are read out of the document rather than remembered here: a
# definition with no instance is an open module, and its parts are the nodes named after
# it. So there is no editor-side state to keep in step, nothing to lose on a reload, and
# an open module that gets saved comes back open.
# ---------------------------------------------------------------------------------

## Arms the rectangle. Making a module is drawing the frame first.
func _begin_module_region() -> void:
	if graph_edit == null:
		return
	if views != null and not graph_edit.is_visible_in_tree():
		show_view("Graph")
	graph_edit.set_drawing(true)
	_say("draw a rectangle round the nodes this module is made of")


## Whatever ended up wholly inside the rectangle becomes a module, and the module is left
## open — because the thing you have just drawn a box around is the thing you want to look
## at, and closing it immediately would hide it at the moment of making it.
func _on_region_drawn(widget_names: Array) -> void:
	var chosen: Array = []
	for widget_name in widget_names:
		var node_id: String = ids.get(str(widget_name), "")
		if node_id != "":
			chosen.append(node_id)
	if chosen.size() < 2:
		_say("draw round two or more nodes — a module of one is the node you started with")
		return
	var terminals: Array = []
	for type_name in registry:
		if str(registry[type_name].get("category", "")) == "Terminals":
			terminals.append(type_name)
	var made := ModuleAuthor.collapse(patch, chosen, terminals, wand_picks.duplicate(true))
	if not made.ok():
		_say(made.error)
		return
	var opened := ModuleAuthor.expand(made.patch, made.instance_id)
	if not opened.ok():
		_say(opened.error)
		return
	_begin_edit()
	patch = opened.patch
	_synthesize_module_descriptors()
	_set_wand(false)
	await _rebuild_view()
	_apply()
	_commit_edit("make %s" % made.module_name)
	_say("'%s' holds %d nodes. Close it to fold them in." % [made.module_name, chosen.size()])


## Folds an open module shut. One edit, undoable like any other — which is the whole cost
## of a peek, and cheap next to the machinery that would have made peeking free.
func _close_module(module_name: String) -> void:
	var shut := ModuleAuthor.close_module(patch, module_name)
	if not shut.ok():
		_say(shut.error)
		return
	_begin_edit()
	patch = shut.patch
	_synthesize_module_descriptors()
	await _rebuild_view()
	_apply()
	_commit_edit("close %s" % module_name)
	_say("'%s' is one node again" % module_name)


## Opens a module instance so its parts are on the canvas.
func _open_module(instance_id: String) -> void:
	var opened := ModuleAuthor.expand(patch, instance_id)
	if not opened.ok():
		_say(opened.error)
		return
	_begin_edit()
	patch = opened.patch
	_synthesize_module_descriptors()
	await _rebuild_view()
	_apply()
	_commit_edit("open %s" % opened.module_name)
	_say("'%s' is open. Close it to fold it back in." % opened.module_name)


## The frames to draw: every definition nothing points at, and the widgets of its parts.
func _refresh_groups() -> void:
	if graph_edit == null:
		return
	var instantiated := {}
	for node in patch.get("nodes", []):
		if str(node.get("type", "")) == "module":
			instantiated[str(node.get("module", ""))] = true
	var frames := {}
	for module_name in patch.get("modules", {}):
		if instantiated.has(str(module_name)):
			continue
		var members: Array = []
		var prefix := "%s." % str(module_name)
		for node in patch.get("nodes", []):
			if str(node["id"]).begins_with(prefix) and widgets.has(str(node["id"])):
				members.append(String((widgets[str(node["id"])] as GraphNode).name))
		if not members.is_empty():
			frames[str(module_name)] = members
	graph_edit.groups = frames


# ---------------------------------------------------------------------------------
# The wand
#
# The argument for it, and how a click reaches a knob at all, are in patch_graph.gd.
# This half is the bookkeeping: what has been picked, in what order, and keeping that
# list honest as the canvas moves under it.
# ---------------------------------------------------------------------------------

## One toggle, two halves of one job — which half you get is whichever view you are in.
##
## In the Graph tab a module does not exist yet, so the wand picks what it will show. In
## the Graphrack tab it does, wearing that face, so the wand moves the knobs around on it.
## Both are "say what this module shows and where", and neither is available in the view
## where it would be meaningless: the Graph tab draws no panel to rearrange, and a module's
## insides are not on the rack to point at.
func _set_wand(active: bool) -> void:
	if graph_edit == null:
		return
	graph_edit.set_wand(active)
	if patch_face != null:
		patch_face.wand = active
	if graphrack != null:
		graphrack.wand = active
		# Rebuilt, because raising the wand grows a ghost on every module face and putting
		# it down takes them away — and a ghost is a Control, not a coat of paint.
		graphrack.rebuild()
	if wand_button != null and wand_button.button_pressed != active:
		wand_button.button_pressed = active
	if not active:
		# Put down, the picks go with it. Keeping them would mean a face being designed
		# with nothing on screen saying so, and the next collapse quietly wearing choices
		# made some minutes ago.
		wand_picks.clear()
		_refresh_wand()
		return
	_refresh_wand()
	# The Graph tab says the rest on the canvas, where there is room for it — see
	# PatchGraph.WandOverlay._draw_hint. This line only has to say the wand is up.
	if graphrack != null and graphrack.is_visible_in_tree():
		_say("wand up: drag a knob to move it, off the panel to take it off the face")
	else:
		_say("wand up")


## Ports are not knobs, and the file's face is made of knobs. `controls` targets a node
## and a parameter and has no spelling for a jack — reasonably, since a panel is what
## somebody turns and a jack is where a cable goes. Said out loud rather than ignored,
## because a click that does nothing is indistinguishable from a tool that is broken.
func _on_port_picked(widget_name: String, side: String, index: int) -> void:
	var node_id: String = ids.get(widget_name, "")
	if node_id == "":
		return
	var ports := _port_list(node_id, "inputs" if side == "left" else "outputs")
	if index < 0 or index >= ports.size():
		return
	_say("%s.%s is a jack — the panel is made of knobs"
		% [node_id, str(ports[index]["name"])])


func _on_parameter_picked(widget_name: String, parameter: String) -> void:
	var node_id: String = ids.get(widget_name, "")
	if node_id == "" or parameter == "":
		return
	_toggle_control(node_id, parameter)


## The wand's whole job now: put this knob on the file's face, or take it off.
##
## One document edit each way, undoable, and it touches nothing but `controls` — so a knob
## can go on and come off again without the graph, the wiring or the sound noticing. That
## is the property that makes the panel worth experimenting with: the worst a wrong face
## costs is a Ctrl-Z.
##
## Appended rather than inserted, because the order knobs go on in is the order somebody
## chose to put them there, and that is as good a statement of intent as any and better
## than most.
func _toggle_control(node_id: String, parameter: String) -> void:
	var controls: Array = patch.get("controls", []).duplicate(true)
	for index in controls.size():
		var target: Dictionary = controls[index].get("target", {})
		if str(target.get("node", "")) == node_id \
				and str(target.get("parameter", "")) == parameter:
			var gone: String = str(controls[index].get("label", parameter))
			controls.remove_at(index)
			_begin_edit()
			if controls.is_empty():
				patch.erase("controls")
			else:
				patch["controls"] = controls
			_refresh_face()
			_apply()
			_commit_edit("take %s off the panel" % gone)
			_say("'%s' is off the panel. Its value is still set; nothing else changed."
				% gone)
			return

	var descriptor := _parameter_descriptor(node_id, parameter)
	if descriptor.is_empty():
		_say("%s has no parameter called %s" % [node_id, parameter])
		return
	var taken := {}
	for control in controls:
		taken[str(control.get("id", ""))] = true
	var control_id := parameter
	if taken.has(control_id):
		control_id = "%s_%s" % [node_id, parameter]
	var entry := {
		"id": control_id,
		"label": str(descriptor.get("name", parameter)).capitalize(),
		"kind": "knob",
		"target": {"node": node_id, "parameter": parameter},
		"min": float(descriptor.get("min", 0.0)),
		"max": float(descriptor.get("max", 1.0)),
		"default": float(descriptor.get("default", 0.0)),
		"scaling": str(descriptor.get("scaling", "linear")),
	}
	controls.append(entry)
	_begin_edit()
	patch["controls"] = controls
	_refresh_face()
	_apply()
	_commit_edit("put %s on the panel" % entry["label"])
	_say("'%s' is on the panel (%d knob%s)"
		% [entry["label"], controls.size(), "" if controls.size() == 1 else "s"])


func _parameter_descriptor(node_id: String, parameter: String) -> Dictionary:
	for parameter_entry in registry.get(_node_type(node_id), {}).get("parameters", []):
		if str(parameter_entry["name"]) == parameter:
			return parameter_entry
	return {}


func _refresh_face() -> void:
	if patch_face == null:
		return
	patch_face.patch = patch
	patch_face.registry = registry
	patch_face.rack = rack
	patch_face.rebuild()


## The panel, in the order somebody dragged it into.
##
## Presentation, like a module's panel rows and for the same reason: `controls` is a list
## and a list has an order, so rearranging it changes which knob is where and nothing else.
## Ids the panel did not mention keep their places at the end rather than being dropped —
## a reorder that could lose a knob would be a reorder nobody dares use.
func _on_panel_reordered(control_ids: Array) -> void:
	var by_id := {}
	for control in patch.get("controls", []):
		by_id[str(control.get("id", ""))] = control
	var ordered: Array = []
	for control_id in control_ids:
		if by_id.has(str(control_id)):
			ordered.append(by_id[str(control_id)])
			by_id.erase(str(control_id))
	for control in patch.get("controls", []):
		if by_id.has(str(control.get("id", ""))):
			ordered.append(control)
	if ordered.size() != patch.get("controls", []).size():
		return
	_begin_edit()
	patch["controls"] = ordered
	_refresh_face()
	_commit_edit("rearrange the panel")
	_say("panel rearranged")


## Pointing at something already picked takes it back off. Without that the only repair
## for a misclick is building the whole face again from the start, and a gesture whose
## mistakes cannot be undone is one people stop making.
func _toggle_pick(pick: Dictionary) -> void:
	var key := _pick_key(pick)
	for index in wand_picks.size():
		if _pick_key(wand_picks[index]) == key:
			wand_picks.remove_at(index)
			_refresh_wand()
			_say("dropped %s — %d left on the face" % [_pick_label(pick), wand_picks.size()])
			return
	wand_picks.append(pick)
	_refresh_wand()
	_say("%d. %s" % [wand_picks.size(), _pick_label(pick)])


func _pick_key(pick: Dictionary) -> String:
	return "%s/%s/%s" % [str(pick.get("kind", "")), str(pick.get("node", "")),
		str(pick.get("port", pick.get("parameter", "")))]


func _pick_label(pick: Dictionary) -> String:
	return "%s.%s" % [str(pick.get("node", "")),
		str(pick.get("port", pick.get("parameter", "")))]


## Resolves the picks against what is on the canvas now, and drops the ones that have
## stopped meaning anything — a node deleted, or one taken back out of the selection.
##
## Dropping rather than dimming, because collapse ignores a nomination from outside the
## selection: a badge left numbered on a deselected node would be promising a knob that
## is not going to be there. Ordinals are assigned here, after the drop, so the numbers
## on screen are always 1..n with nothing missing out of the middle.
func _refresh_wand() -> void:
	if graph_edit == null:
		return
	var kept: Array = []
	var marks: Array = []
	for pick: Dictionary in wand_picks:
		var widget: GraphNode = widgets.get(str(pick.get("node", "")))
		if widget == null or not is_instance_valid(widget) or not widget.selected:
			continue
		var mark := _mark_for(widget, pick)
		if mark.is_empty():
			continue
		kept.append(pick)
		mark["ordinal"] = kept.size()
		marks.append(mark)
	wand_picks = kept
	graph_edit.wand_marks = marks


## Where a pick is drawn: a jack by slot index, a knob by the row that holds it. A folded
## row still resolves — the disclosure triangle hides a knob, it does not un-pick it — and
## the overlay is what declines to draw a badge nobody could see.
func _mark_for(widget: GraphNode, pick: Dictionary) -> Dictionary:
	var kind := str(pick.get("kind", ""))
	var node_id := str(pick.get("node", ""))
	if kind == "parameter":
		var row := _parameter_row(widget, str(pick.get("parameter", "")))
		return {} if row == null else {"row": row}
	var ports := _port_list(node_id, "inputs" if kind == "input" else "outputs")
	for index in ports.size():
		if str(ports[index]["name"]) == str(pick.get("port", "")):
			return {"widget": String(widget.name), "side":
				"left" if kind == "input" else "right", "index": index}
	return {}


## Stores a face somebody just rearranged with their hands.
##
## Presentation only, and that is what makes it worth doing by dragging: the surface is
## untouched, so no cable moves, no control loses its target and nothing about the sound
## can change. The worst a bad arrangement costs is one Ctrl-Z.
##
## It lands on the *definition*, so every instance of that module wears it — which is the
## right answer and worth saying out loud, because the thing being dragged is one instance
## and the thing being edited is what all of them are.
##
## Any labels already on the panel are kept. Moving a knob is not renaming it, and the two
## are separate fields precisely so that one gesture cannot quietly do the other.
func _on_face_rearranged(node_id: String, rows: Array, added: Dictionary = {}) -> void:
	var module_name := _module_of(node_id)
	var definitions: Dictionary = patch.get("modules", {})
	if module_name == "" or not definitions.has(module_name):
		return
	_begin_edit()
	var definition: Dictionary = definitions[module_name]

	# A ghost dragged onto the face was never exported, so it becomes an export on the way
	# in — one edit, because "put this knob on the module" is one thought. The rack names
	# it by where it came from; the export name is chosen here, where what is already taken
	# is known, and swapped into the rows so the panel names the binding and not the ghost.
	var gained := ""
	if not added.is_empty():
		var surface: Array = definition.get("parameters", []).duplicate(true)
		gained = _free_export_name(surface, str(added["node"]), str(added["parameter"]))
		surface.append({"name": gained, "node": str(added["node"]),
			"parameter": str(added["parameter"])})
		definition["parameters"] = surface
		var renamed: Array = []
		for row: Array in rows:
			renamed.append(row.map(func(n): return gained if str(n) == str(added["key"]) \
				else str(n)))
		rows = renamed

	var panel: Dictionary = (definition.get("panel", {}) as Dictionary).duplicate(true)
	panel["rows"] = rows
	definition["panel"] = panel
	_synthesize_module_descriptors()
	await _rebuild_view()
	_apply()
	_commit_edit("rearrange %s" % module_name)
	if gained != "":
		_say("'%s' is on %s's face, and exported so a patch can reach it"
			% [gained, module_name])
	else:
		_say("%s's face is %d row%s now" % [module_name, rows.size(),
			"" if rows.size() == 1 else "s"])


## The module a node is an instance of, or "".
func _module_of(node_id: String) -> String:
	for node in patch.get("nodes", []):
		if str(node["id"]) == node_id:
			return str(node.get("module", ""))
	return ""


## An export name not already spoken for. Same shape as ModuleAuthor's: the inner
## parameter's own name where it is free, qualified by its node where it is not.
func _free_export_name(surface: Array, node_id: String, parameter: String) -> String:
	var taken := {}
	for binding in surface:
		taken[str(binding["name"])] = true
	if not taken.has(parameter):
		return parameter
	var qualified := "%s_%s" % [node_id, parameter]
	if not taken.has(qualified):
		return qualified
	var counter := 2
	while taken.has("%s-%d" % [qualified, counter]):
		counter += 1
	return "%s-%d" % [qualified, counter]


## A ghost jack was clicked: the inner port becomes one of the module's own.
##
## The additive half of what the Builder's port list did, and the only half the wand
## offers — declaring a port is safe, since nothing can yet be plugged into a port that
## did not exist, while *un*declaring one strands whatever is plugged into it. That is an
## edit worth a considered surface rather than a click, and it does not have one yet.
func _on_port_declared(node_id: String, offer: Dictionary) -> void:
	var module_name := _module_of(node_id)
	var definitions: Dictionary = patch.get("modules", {})
	if module_name == "" or not definitions.has(module_name):
		return
	var definition: Dictionary = definitions[module_name]
	var side := "inputs" if bool(offer.get("is_input", true)) else "outputs"
	var bindings: Array = definition.get(side, []).duplicate(true)
	for binding in bindings:
		if str(binding["node"]) == str(offer["node"]) \
				and str(binding["port"]) == str(offer["port"]):
			_say("%s.%s is already a port of %s"
				% [str(offer["node"]), str(offer["port"]), module_name])
			return
	var taken := {}
	for binding in bindings:
		taken[str(binding["name"])] = true
	var port_name := str(offer["port"])
	if taken.has(port_name):
		port_name = "%s_%s" % [str(offer["node"]), str(offer["port"])]
	_begin_edit()
	bindings.append({"name": port_name, "node": str(offer["node"]),
		"port": str(offer["port"])})
	definition[side] = bindings
	_synthesize_module_descriptors()
	await _rebuild_view()
	_apply()
	_commit_edit("declare %s on %s" % [port_name, module_name])
	_say("%s is %s's %s now" % [port_name, module_name,
		"input" if side == "inputs" else "output"])


func _parameter_row(parent: Node, parameter: String) -> Control:
	for child in parent.get_children():
		var control := child as Control
		if control == null:
			continue
		if str(control.get_meta("parameter_name", "")) == parameter:
			return control
		var deeper := _parameter_row(control, parameter)
		if deeper != null:
			return deeper
	return null


func _arrange(movable: Array) -> void:
	if patch.get("nodes", []).is_empty() or movable.is_empty():
		return

	_begin_edit()

	var sizes := {}
	for node in patch["nodes"]:
		var widget: GraphNode = widgets.get(node["id"])
		# Measured in world pixels, handed over in document units, because everything
		# else the layout engine is given — the pitch, the gutter, the grid, the anchors
		# — is in document units. Mixing the two is how the arrangement came out tight at
		# XL and loose at Compact from the same patch.
		sizes[node["id"]] = (widget.size / _graph_scale()) if widget != null \
			else Vector2(240.0, 140.0)

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
	# Every route that renames the document comes through here, so the title follows the
	# name without each of them having to remember to say so.
	_refresh_window_title()
	if document_label == null:
		return
	# A dot rather than an asterisk, and the name goes bright rather than gaining
	# punctuation — the change should be noticeable without the label jumping about,
	# and a leading "*" shifts every character along by one.
	document_label.text = document_name + ("  (unsaved)" if unsaved else "")
	# Because the label is clipped, this is the only place a long name can be read whole.
	document_label.tooltip_text = document_label.text
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
	# A disabled text button dims itself; a disabled icon does not, so an icon-only
	# button stays looking pressable unless the icon is repainted to match.
	undo_button.icon = _icon(Icons.Kind.UNDO,
		Design.INK_DISABLED if undo_button.disabled else Design.INK_NORMAL)
	redo_button.icon = _icon(Icons.Kind.REDO,
		Design.INK_DISABLED if redo_button.disabled else Design.INK_NORMAL)
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
			var offset: Vector2 = widgets[node["id"]].position_offset / _graph_scale()
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
			where.add_theme_font_size_override("font_size", Design.type(Design.SIZE_SECONDARY))
			where.modulate = INK_DIM
			card.add_child(where)

		if diagnostic.has("suggestion"):
			var suggestion := Label.new()
			suggestion.text = diagnostic["suggestion"]
			suggestion.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			suggestion.add_theme_font_size_override("font_size", Design.type(Design.SIZE_SECONDARY))
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

## What a reduced level of detail does inside one parameter cell.
##
## The room the hidden control leaves goes to the *value*, not to the name. Both were
## tried and the pictures settled it: with the control gone and nothing expanding, name
## and value pack up against each other and each is left with only its own shrink-wrapped
## box — at 65% "10.0 ms" fitted and "120.0 ms" did not, so a column of numbers came up
## half empty with no rule a reader could see.
##
## Dials and dropdowns are the controls; everything else in a cell is words, and words
## stay. An enum cell hands its chosen option to a label as the dropdown goes, so it
## never shows a name with nothing beside it — "shape" and "safety_limit" floating alone
## was the same failure as an unlabelled slider, seen from the other end.
func _apply_cell_detail(cell: Control, full: bool) -> void:
	var value_field: Control = cell.get_meta("value_field") 		if cell.has_meta("value_field") else null
	if value_field != null:
		value_field.size_flags_horizontal = Control.SIZE_FILL if full 			else Control.SIZE_EXPAND_FILL
	var enum_value: Label = cell.get_meta("enum_value") 		if cell.has_meta("enum_value") else null
	for part in cell.get_children():
		var piece := part as Control
		if piece == null:
			continue
		if piece is Rack.Knob or piece is HSlider or piece is OptionButton:
			piece.visible = full
		else:
			piece.visible = true
	# By reference rather than by walking the cell's own children: the chosen option now
	# lives inside the name stack, one level down, and the loop above would only ever have
	# shown the stack that contains it.
	if enum_value != null:
		enum_value.visible = not full

func _apply_detail(level: int) -> void:
	var full: bool = level == PatchGraph.Detail.FULL
	# Words out-survive controls, which is the reverse of what this used to do.
	#
	# The old rule kept every slider and hid every word beside it, on the reasoning that
	# the type floor is a rule about text and a slider is geometry. The result at 65% was
	# a node of unlabelled sliders: controls with nothing saying what they controlled,
	# which is not a denser view of a synth so much as a worse one. Between "frequency"
	# and a nameless groove, the word is the part carrying the meaning — the groove is
	# recoverable by zooming in, and at this size it could not be aimed at anyway.
	#
	# So COMPACT keeps the row, keeps the name and the number, and gives the slider's
	# room to the words. The earlier attempt that hid whole rows — the wall of empty
	# aluminium that read as broken — failed because it dropped the words *too*; keeping
	# them is what makes a compact row still look like an instrument.
	var show_rows: bool = level == PatchGraph.Detail.FULL \
		or level == PatchGraph.Detail.COMPACT
	# Port names survive to SUMMARY. They used to hide with the parameters, because at
	# 16px scaled to nine they were smudges pretending to be information — true then,
	# and no longer, now that ScreenText draws them at their own minimum instead of at
	# whatever the zoom left. A summary node is exactly "what is this and what plugs
	# into it", so the names are most of the point of that band.
	var show_port_names: bool = level != PatchGraph.Detail.TOPOLOGY
	for id in widgets:
		var widget: GraphNode = widgets[id]
		# Metadata goes first, and goes entirely: a category drawn at nine pixels is
		# decoration, and there is no size at which it outranks a parameter name.
		var tag: Label = widget.get_meta("category_tag") if widget.has_meta("category_tag") else null
		if tag != null:
			tag.visible = full
		var counterweight: Control = widget.get_meta("category_counterweight") \
			if widget.has_meta("category_counterweight") else null
		if counterweight != null:
			counterweight.visible = full
		# The node gives back the height its controls were using.
		#
		# GraphNode keeps whatever size it was last given, so a compact node used to be a
		# full-height rectangle with its lower half empty — the "loosely positioned text
		# in a large empty box" that made these look like full nodes with pieces missing
		# rather than a drawing of their own. The authored size is remembered so full
		# detail restores exactly what the document asked for, and only the *height* is
		# released: the width is what the value column aligns to, and the ports sit above
		# the parameters, so nothing here moves a cable.
		for child in widget.get_children():
			var control := child as Control
			if control == null:
				continue
			match str(control.get_meta("row", "")):
				"disclosure":
					# A control for secondary parameters, so it goes when they do.
					control.visible = full
				"module":
					# One row, three jobs: a port on each flank and the knob cells between
					# them. The cells fold; the row never does, because it is carrying the
					# slot the cables are attached to.
					var cells: Control = control.get_meta("cells_box") \
						if control.has_meta("cells_box") else null
					if cells != null:
						cells.visible = show_rows \
							and not bool(cells.get_meta("collapsed", false)) \
							and cells.get_child_count() > 0
						for cell_child in cells.get_children():
							var cell := cell_child as Control
							if cell != null:
								_apply_cell_detail(cell, full)
					_fit_row_height(control)
					# A port caption is a name and a unit in their own box, so the labels
					# are grandchildren of the row.
					for side in control.get_children():
						if side == cells:
							continue
						for part in (side as Control).get_children():
							var label := part as Label
							if label == null or not label.has_meta("port_label"):
								continue
							# The unit goes a band before the name it annotates, which is
							# both the priority order — a unit is metadata, a port name is
							# the thing you are looking for — and what makes the name
							# legible at all: packed immediately beside it, the unit was
							# the wall the name's compensated text ran into, so at 65% a
							# node showed "Hz octaves cycles" and not one port's name.
							label.visible = show_port_names \
								and (full or str(label.get_meta("screen_kind", "")) != "unit")


	# The height a node gives back, measured after its contents have changed rather
	# than before. Setting it inside the loop above shrank each node against the
	# contents it still had, so at 51% the bodies kept their full-editor height and the
	# graph read as a pile of overlapping rectangles. A frame is allowed to pass so
	# Godot has recomputed the minimum from the rows that are actually visible.
	await get_tree().process_frame
	for id in widgets:
		var widget: GraphNode = widgets[id]
		if not widget.has_meta("authored_size"):
			widget.set_meta("authored_size", widget.size)
		var authored: Vector2 = widget.get_meta("authored_size")
		widget.size.y = authored.y if full else widget.get_combined_minimum_size().y

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
		# The whole line, not just the transport half. On a narrow window this dot is all
		# that is left of the status strip, and a tooltip that answers only one of the two
		# questions it now stands for would leave "is the graph valid" with no answer
		# anywhere in the chrome.
		transport_dot.tooltip_text = _status_sentence(running, valid)

	var parts := ["Audio running" if running else "Audio stopped"]
	parts.append("Graph valid" if valid else "%d problem%s"
		% [_problem_count, "" if _problem_count == 1 else "s"])
	# The sample rate is not here at all now, having been "48 kHz" and then "48k" on the
	# way out. Its own comment had already made the argument — a number that has never
	# once changed while somebody watched belongs in the tooltip — and the sidebar's Cost
	# line says "48000 Hz" in full a few inches away. Two copies of a constant were paying
	# for themselves in toolbar width, on a bar with eight pixels of room left.
	status_label.text = "  ·  ".join(parts)
	status_label.tooltip_text = _status_sentence(running, valid)
	status_label.add_theme_color_override("font_color",
		Design.INK_SECOND if valid else Design.ERROR)
	# The words just changed width, and on a bar this full that can be the difference
	# between fitting and forcing the window open.
	_fit_toolbar()


## The status strip spelled out, for whichever of its two parts is left to hover.
func _status_sentence(running: bool, valid: bool) -> String:
	return ("Audio %s · graph %s · 48000 Hz"
		% ["running" if running else "stopped", "valid" if valid else "has problems"])


func _highlight(node_ids: Array) -> void:
	for id in widgets:
		var widget: GraphNode = widgets[id]
		widget.modulate = Color(1.0, 0.65, 0.6) if node_ids.has(id) else Color.WHITE


## Kept under its old name because half a dozen places call it after the graph changes.
func _show_info() -> void:
	_refresh_context()
	if outline != null:
		outline.patch = patch
		outline.registry = registry
		outline.refresh()


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
	if _importing_module or _importing_definition:
		var as_definition := _importing_definition
		_importing_module = false
		_importing_definition = false
		var module_file := FileAccess.open(path, FileAccess.READ)
		if module_file == null:
			_say("could not read %s" % path)
			return
		if as_definition:
			_import_module_as_definition(module_file.get_as_text(),
				ModuleImport.name_from_path(path))
		else:
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
	# Both import modes, which this dialog path never actually honoured — "Add module"
	# through the native dialog fell through to a plain open, replacing the document it
	# was meant to add to. Found while wiring the definition sibling in beside it.
	if _importing_module or _importing_definition:
		var as_definition := _importing_definition
		_importing_module = false
		_importing_definition = false
		if as_definition:
			_import_module_as_definition(file.get_as_text(),
				ModuleImport.name_from_path(path))
		else:
			_import_module(file.get_as_text(), ModuleImport.name_from_path(path))
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


## Adds a foreign patch as a module definition plus one instance — the import that
## keeps the patch one thing. Its terminals become the declared ports; ModuleAuthor
## carries the transform, this carries the ceremony.
func _import_module_as_definition(text: String, module_name: String) -> void:
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		_say("that file is not a patch")
		return
	var terminals: Array = []
	for type_name in registry:
		if str(registry[type_name].get("category", "")) == "Terminals":
			terminals.append(type_name)
	var result := ModuleAuthor.from_patch(patch, parsed, module_name, terminals)
	if not result.ok():
		_say(result.error)
		return
	_begin_edit()
	patch = result.patch
	_synthesize_module_descriptors()
	await _rebuild_view()
	_apply()
	_commit_edit("add module %s" % result.module_name)
	_say("added '%s' as a definition with one instance — wire it up" % result.module_name)


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

	# Before any widget is built, so every instance finds its descriptor waiting.
	_synthesize_module_descriptors()

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

	# Frame what was just opened.
	#
	# This was missing, and the default view was the consequence: the first thing anybody
	# saw was first-synth at 100% with the Keyboard cut off the left edge and the Lowpass
	# disappearing under the inspector. Fit existed and worked; it was simply never called
	# unless somebody went looking for it in a menu.
	#
	# A frame is waited for first because the fit is solved against usable_rect(), and the
	# scrollbars and minimap that rectangle subtracts do not exist until the nodes it is
	# being asked to frame have been laid out.
	await get_tree().process_frame
	graph_edit.fit_graph()

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
