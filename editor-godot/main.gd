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
const Seams := preload("res://seams.gd")
const SeamDock := preload("res://seam_dock.gd")
const PatchFace := preload("res://patch_face.gd")
const ModuleFace := preload("res://module_face.gd")

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
var make_module_button: Button
## The container turned over: the file's face, full size, in the Graph tab's slot.
## Same class as the side panel's face — one face, two mountings.
var big_face: PatchFace
var wires_button: Button
## Which open modules are turned over, and the ModuleFace mounted for each. Session
## state, like which side the file's case shows: nothing here is written to the patch.
var flipped_modules := {}
## Closed instance nodes turned over where they stand, keyed by instance id — the
## one-step flip: no need to open a module's wires just to play its panel.
var flipped_nodes := {}
var module_mounts := {}
## Where the face is mounted, in graph coordinates: the case's own corner at the moment
## it was turned over. The graph's camera does the rest.
var face_anchor := Vector2.ZERO

## The file's own face: the knobs somebody plays. See patch_face.gd.
var patch_face: PatchFace
## And one module's, when a module instance is what is selected. See module_face.gd.
var module_face: ModuleFace
var face_heading: Label
var views: TabContainer
var rack: Rack
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
# Wide enough to be a rack rather than a column. The face flows its knobs in blocks one
# knob high, so the room it is given is the room it uses: at 340 a DX7 patch is a tall thin
# list, and dragged out it becomes strips of operators side by side.
#
# The ceiling is high because the panel is the thing somebody plays and the graph is how it
# was built — there are sessions where the face should have most of the window. It costs
# nothing to allow: _fit_side_panel already refuses to take the graph below a usable strip,
# so this is a limit on the setting rather than on the layout.
const SIDE_PANEL_MAX := 1800
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
## The instrument's own volume and mute; see _build_keyboard_bar.
var master_knob
var master_mute: Button
var master_label: Label
var muted := false
## The patch's own edges, drawn on the instrument. See seam_dock.gd.
var note_jacks
var output_jacks
var seam_cables
## The device jack currently in the user's hand, or {} — see _on_jack_grabbed.
var dragging_jack := {}
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
	# Delete over a hovered cable is the same edit as dragging it off: one document
	# change, one undo step, through the one handler that already knows how.
	graph_edit.cable_delete_requested.connect(_on_disconnection_request)
	graph_edit.delete_nodes_request.connect(_on_delete_nodes_request)
	graph_edit.node_selected.connect(_on_node_selected)
	graph_edit.node_selected.connect(func(_n): _refresh_selection_button())
	graph_edit.node_deselected.connect(func(_n): _refresh_selection_button())
	graph_edit.popup_request.connect(_on_graph_popup_request)
	# Node drags and cable drags bracket their own undo entries, so a drag is one step
	# rather than one per pixel of mouse movement.
	graph_edit.detail_changed.connect(_apply_detail)
	# The stored choice, through the same setter the menu uses. ADAPTIVE is the
	# default and the setter refuses a no-op, so a fresh install changes nothing.
	graph_edit.set_detail_mode(int(Settings.fetch("graph_detail_mode", 0)))
	graph_edit.port_hovered.connect(_on_port_hovered)
	graph_edit.ghost_port_picked.connect(_on_ghost_port_picked)
	graph_edit.region_drawn.connect(_on_region_drawn)
	graph_edit.group_closed.connect(func(name: String) -> void: _close_module(name))
	graph_edit.begin_node_move.connect(func() -> void: _begin_edit())
	graph_edit.end_node_move.connect(func() -> void: _commit_edit("move"))
	# The container's own controls: its band switches which way you are looking at it,
	# and dragging that band moves everything mounted in it.
	graph_edit.case_move_started.connect(func() -> void: _begin_edit())
	graph_edit.case_flipped.connect(func() -> void: _flip_container(true))
	graph_edit.group_flip_toggled.connect(func(module_name: String) -> void:
		# The key names either an open group or a flipped instance node; the node case
		# first, since only its WIRES chip arrives here — its FACE control is a real
		# button on the widget.
		if flipped_nodes.has(module_name):
			flipped_nodes.erase(module_name)
			await _rebuild_view()
			return
		if flipped_modules.has(module_name):
			flipped_modules.erase(module_name)
			# Turning back needs the members and cables restored, and the rebuild is
			# the one honest way to get a view that matches the document again.
			await _rebuild_view()
		else:
			flipped_modules[module_name] = true
			_apply_flips())
	graph_edit.face_needs_placing.connect(_place_face)
	# Clicking the container chooses the container: the panel shows its face and the
	# inspector describes the whole patch, exactly as they do when a seam like the
	# keyboard is selected — both are ways of pointing at the file rather than at a
	# part of it. The node selection is cleared first, or the panel would stay on
	# whichever part happened to be selected before.
	graph_edit.case_selected.connect(func() -> void:
		for child in graph_edit.get_children():
			if child is GraphNode:
				(child as GraphNode).selected = false
		inspecting = {}
		_refresh_context())
	graph_edit.case_moved.connect(func() -> void:
		_capture_positions()
		_commit_edit("move %s" % _instrument_name()))
	# A mounted face moves by its band, and the move is the same edit as dragging
	# the node it stands for: begin, drag, write the positions down, one undo step.
	graph_edit.face_move_started.connect(func(_key: String) -> void: _begin_edit())
	graph_edit.face_dragged.connect(_on_face_dragged)
	graph_edit.face_moved.connect(func(key: String) -> void:
		_capture_positions()
		_commit_edit("move %s" % key))
	graph_edit.face_socket_grabbed.connect(_on_face_socket_grabbed)
	graph_edit.cable_drag_started.connect(func() -> void: _begin_edit())

	# Two views of one document, side by side in tabs rather than as a mode: the graph is
	# the honest picture of signal flow, the rack is the picture a musician already knows
	# how to read. Which one leads at Knobcon is a question to settle by watching people.
	views = TabContainer.new()
	views.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# One tab, one canvas, both sides of the container. The graph already owns zoom,
	# pan and the grid, so the face is a tenant on that canvas rather than a rival
	# view: flipping hides the wiring and mounts the face at the case's own spot, and
	# every camera gesture keeps working because it is the same camera.
	var container_tab := Control.new()
	container_tab.name = "Graph"
	graph_edit.name = "Wires"
	graph_edit.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	container_tab.add_child(graph_edit)

	big_face = PatchFace.new()
	big_face.visible = false
	big_face.z_index = 50
	big_face.reordered.connect(_on_panel_reordered)
	big_face.offered.connect(_toggle_control)
	graph_edit.add_child(big_face)

	# The way back, floating over the canvas while the face is up.
	wires_button = Button.new()
	wires_button.text = "WIRES"
	wires_button.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	wires_button.offset_left = -Design.scale(100)
	wires_button.offset_top = Design.scale(10)
	wires_button.offset_right = -Design.scale(14)
	wires_button.offset_bottom = Design.scale(38)
	wires_button.visible = false
	wires_button.pressed.connect(func() -> void: _flip_container(false))
	container_tab.add_child(_defocus(wires_button))
	views.add_child(container_tab)

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
		if sandbox != null and sandbox.is_visible_in_tree():
			sandbox.ensure_sounds_loaded())
	split.add_child(views)

	split.add_child(_build_side_panel())
	_set_side_panel_open(true)

	# Under the tabs rather than inside one: the graph and the rack are two views of the
	# same running patch, and the thing that plays it belongs to neither.
	root.add_child(_build_keyboard_dock())

	# Last, and top-level: the cables between the dock and the graph need one canvas that
	# covers both, and root is the only place both exist. Top-level so the column that
	# lays out the toolbar, the views and the dock does not try to give it a row of its
	# own — see Container, which skips a child that has opted out of being laid out.
	seam_cables = SeamDock.Cables.new()
	seam_cables.set_as_top_level(true)
	root.add_child(seam_cables)

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

	# Collapse is in the Arrange menu because it is a rearrangement of the document;
	# this is out here because it is a gesture, and a gesture buried in a menu is a
	# gesture nobody finds.
	make_module_button = Button.new()
	make_module_button.text = "Make module"
	make_module_button.tooltip_text = "Draw a rectangle round some nodes. What is wholly inside it becomes a module, left open so you can see and arrange its parts."
	make_module_button.pressed.connect(func() -> void: _begin_module_region())
	graph_group.add_child(_defocus(make_module_button))

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
	file_popup.add_item("New", 4)
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
		70 + int(Settings.fetch("graph_detail_mode", 0))), true)
	# Beside the detail pair because the two get reached for together: 1:1 is "show
	# me the real thing" and fit is "show me all of it". An action rather than a
	# state — same framing the toolbar's Fit does, in the menu where the eye already
	# is when choosing how to look at the graph.
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
	if id == 4:
		_new_file()
		return
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
	if id == 72:
		graph_edit.fit_graph()
		return
	if id == 73:
		graph_edit.zoom_actual()
		return
	if id >= 70:
		_choose_detail_mode(id - 70)
		return
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


## One step of a face drag. The hidden widgets move — they are where positions live
## between commits, and _capture_positions reads them back at the drop — and the
## mount, its anchor and its band follow. The key names either a flipped instance
## (one widget) or a turned open group (all its members), the same two owners every
## flip key has.
func _on_face_dragged(key: String, step: Vector2) -> void:
	var members: Array = []
	if flipped_nodes.has(key):
		var widget: GraphNode = widgets.get(key, null)
		if widget != null:
			members = [widget]
	elif graph_edit.groups.has(key):
		for widget_name in graph_edit.groups[key]:
			var member := graph_edit.get_node_or_null(
				NodePath(str(widget_name))) as GraphNode
			if member != null:
				members.append(member)
	for member in members:
		member.position_offset += step
	var mount := module_mounts.get(key, null) as Control
	if mount != null and mount.has_meta("anchor"):
		mount.set_meta("anchor", (mount.get_meta("anchor") as Vector2) + step)
	if graph_edit.flip_frames.has(key):
		var frame: Rect2 = graph_edit.flip_frames[key]
		frame.position += step
		graph_edit.flip_frames[key] = frame
	graph_edit.queue_redraw()


## Documents written before stereo pairs spelled a device's whole out as one port.
## The surface now says left and right, so the old spelling is rewritten on load:
## a cable to a left or right destination keeps its channel, and one to anywhere
## else becomes both channels — which is exactly what the whole-seam port meant.
## patch-io still resolves the old spelling on its own, so this is for the editor's
## widgets, whose ports are the declared surface and nothing else.
func _modernize_stereo_outputs() -> void:
	var modules: Dictionary = patch.get("modules", {})
	if modules.is_empty():
		return
	var rewired: Array = []
	var touched := 0
	for connection in patch.get("connections", []):
		var from_id := str(connection.get("from", {}).get("node", ""))
		var from_port := str(connection.get("from", {}).get("port", ""))
		var module_name := ""
		for node in patch.get("nodes", []):
			if str(node["id"]) == from_id:
				module_name = str(node.get("module", ""))
		var definition: Dictionary = modules.get(module_name, {})
		var legacy := false
		if not definition.is_empty():
			for seam in definition.get("nodes", []):
				if Seams.stereo_pair(definition, seam) \
						and str(seam.get("name", seam.get("id", ""))) == from_port:
					legacy = true
		if not legacy:
			rewired.append(connection)
			continue
		touched += 1
		var to_port := str(connection.get("to", {}).get("port", ""))
		if to_port == "left" or to_port == "right":
			var kept: Dictionary = connection.duplicate(true)
			kept["from"]["port"] = to_port
			rewired.append(kept)
		else:
			for channel in ["left", "right"]:
				var split: Dictionary = connection.duplicate(true)
				split["from"]["port"] = channel
				rewired.append(split)
	if touched > 0:
		patch["connections"] = rewired


## One path for menu and key alike: the mode, the memory, the checkmarks, the word.
func _choose_detail_mode(mode: int) -> void:
	graph_edit.set_detail_mode(mode)
	Settings.store("graph_detail_mode", mode)
	for entry in 2:
		view_popup.set_item_checked(view_popup.get_item_index(70 + entry),
			entry == mode)
	_say("detail: %s" % ("1:1" if mode == PatchGraph.DetailMode.ONE_TO_ONE \
		else "adaptive"))


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
	_say("theme: %s" % Design.PALETTE_NAMES[index])


## Stops every sounding note. Wired to both the panic button and Escape, because a
## panic control that needs the mouse is one you cannot reach while holding a chord.
func _all_notes_off() -> void:
	if engine != null:
		engine.all_notes_off()
	held_notes.clear()
	if keyboard != null:
		keyboard.set_held_notes(held_notes)




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
##
## With only the graph side set to expand, split_offset is measured from the *right*
## edge: -offset is the panel's width, 0 puts the divider hard against it, and positive
## values are meaningless. Measured, not read from a manual — a probe sweeping offsets
## against this exact container is where the rule comes from. This function used to
## write `size.x - wanted - graph_minimum`, a large positive number under that rule,
## and pin the real width with custom_minimum_size instead; the layout looked right and
## every drag started from a garbage baseline, which is why the divider had a dead zone
## hundreds of pixels wide and only tracked the mouse through the minimum-size clamp
## chasing it one event behind.
func _fit_side_panel() -> void:
	if split == null or views == null:
		return
	var wanted := side_panel_width if side_panel_open else SIDE_PANEL_COLLAPSED
	# The narrowest a drag may make it. A floor, not the width: the offset is what holds
	# the width open now, and a minimum equal to the current width is exactly the pin
	# that made shrinking fight the mouse.
	var narrowest := SIDE_PANEL_MIN if side_panel_open else SIDE_PANEL_COLLAPSED
	# Never wider than the room there is. Asking for 340 in a window with 200 left does
	# not give a 340px panel — it gives a layout wider than the window, and everything
	# past the edge simply is not drawn: the order chips ran off the right of the screen
	# and the cost line lost its last words. The panel gives way before the window does,
	# and the graph keeps a usable strip whatever happens.
	if split.size.x > 0.0:
		var graph_minimum := views.get_combined_minimum_size().x
		var room: float = split.size.x - minf(graph_minimum, split.size.x * 0.45)
		wanted = int(clampf(float(wanted), float(SIDE_PANEL_COLLAPSED), maxf(room, 0.0)))
		narrowest = int(clampf(float(narrowest), float(SIDE_PANEL_COLLAPSED),
			maxf(room, 0.0)))
	if side_panel != null:
		side_panel.custom_minimum_size.x = narrowest
	split.split_offset = -wanted


## Reads the width back off the divider after a drag, so dragging *is* the setting.
##
## A separate width control next to a draggable divider is two ways to say the same
## thing, and they disagree the moment either is used. The raw offset arrives here on
## every motion; writing the clamped truth back through _fit_side_panel is stomped by
## the next motion (the dragger works from its own press-time baseline) but sticks
## after the last one — so the divider ends every drag on an honest offset, and the
## next grab starts from where the divider actually is.
func _on_split_dragged(offset: int) -> void:
	if split == null or side_panel == null:
		return
	if not side_panel_open:
		# The divider is not a control while the panel is shut — there is nothing whose
		# width it could honestly be setting. Put it back rather than leaving it
		# wherever the drag dropped it, which is how a shut panel came back open at a
		# width nobody chose.
		_fit_side_panel()
		return
	side_panel_width = clampi(-offset, SIDE_PANEL_MIN, SIDE_PANEL_MAX)
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

	# Padded, because the panel now sits against the window edge rather than inside a
	# fixed-width column — the scope was running right off the side of the screen and
	# every readout in it ended a pixel from the frame. The top margin is here now
	# that nothing else sits above the faces.
	var inset := MarginContainer.new()
	inset.size_flags_vertical = Control.SIZE_EXPAND_FILL
	for edge in ["left", "right", "top"]:
		inset.add_theme_constant_override("margin_" + edge, Design.scale(Design.SPACE_M))
	side_panel.add_child(inset)

	# The collapse control sits *under* everything, and never moves: the faces lead the
	# panel and used to pay a strip of the most valuable row on screen for a button that
	# is pressed a few times an hour. Outside the body on purpose, so the way back is
	# still on screen when the body is hidden.
	var strip := HBoxContainer.new()
	side_panel_toggle = Button.new()
	side_panel_toggle.flat = true
	side_panel_toggle.custom_minimum_size.x = Design.scale(28)
	side_panel_toggle.pressed.connect(func() -> void:
		_set_side_panel_open(not side_panel_open))
	strip.add_child(_defocus(side_panel_toggle))
	side_panel.add_child(strip)

	# The panel scrolls rather than growing past the bottom of the window. Its content
	# is not a fixed list — the run order grows with the patch, the problem list with
	# the mistakes — so on a short window the cost line and everything under it were
	# simply off-screen with no way to reach them. No sideways scrollbar: one under a
	# column of text is a sign that something is too wide, not a way to read it.
	#
	# SHOW_NEVER rather than DISABLED, and the difference is the divider. DISABLED makes
	# the scroller *report* its content's width as its minimum, which the split has to
	# honour — so whenever anything in the panel was wider than the panel, the divider
	# silently stopped moving and the drag went dead in the hand. SHOW_NEVER keeps the
	# bar away and lets content clip instead of taking the divider hostage.
	var body_scroll := ScrollContainer.new()
	body_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	inset.add_child(body_scroll)

	side_panel_body = VBoxContainer.new()
	side_panel_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	side_panel_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	side_panel_body.add_theme_constant_override("separation", Design.SPACE_M)
	body_scroll.add_child(side_panel_body)

	var panel := side_panel_body

	# The face, first and always. It is what the file is *for* — the graph underneath is
	# how it is built — so it leads the panel rather than sitting under the diagnostics.
	#
	# Two of them, one at a time. Which you get is which you are looking at: select a module
	# instance and this is that module's face, select anything else and it is the file's.
	# One column rather than two, because they are the same kind of thing and a person is
	# only ever arranging one of them.
	#
	# No standing title. The file's own face is self-evidently the panel — a label saying
	# "Panel" above a rack of knobs was a row of the best space on screen spent naming the
	# obvious. The heading appears only when the face is a *module's*, where the name is
	# load-bearing: without it there is nothing saying whose knobs these are.
	face_heading = _field("Panel")
	face_heading.visible = false
	panel.add_child(face_heading)
	patch_face = PatchFace.new()
	patch_face.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	patch_face.reordered.connect(_on_panel_reordered)
	patch_face.offered.connect(_toggle_control)
	panel.add_child(patch_face)

	module_face = ModuleFace.new()
	module_face.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	module_face.rearranged.connect(_on_face_rearranged)
	module_face.removed.connect(_on_face_knob_removed)
	module_face.refused.connect(func(reason: String) -> void: _say(reason))
	module_face.visible = false
	panel.add_child(module_face)

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
## Turn the container over: wiring one way, the face the other, in the same place.
##
## Presentation, not document — which side is up is a fact about the session, like the
## scroll position, so nothing is written and nothing lands in the undo history.
## Turn the container over: wiring one way, the face the other, on the same canvas.
##
## Presentation, not document — which side is up is a fact about the session, like the
## scroll position, so nothing is written and nothing lands in the undo history. The
## nodes are hidden and the view's cables cleared (the document keeps every connection);
## turning back rebuilds the view from the document, which restores both.
func _flip_container(show_face: bool) -> void:
	if graph_edit == null or big_face == null:
		return
	if show_face:
		face_anchor = graph_edit.case_box().position
		var footprint: Rect2 = graph_edit.case_box()
		graph_edit.face_up = true
		for child in graph_edit.get_children():
			if child is GraphNode:
				(child as GraphNode).visible = false
		graph_edit.clear_connections()
		for module_name in module_mounts:
			(module_mounts[module_name] as Control).visible = false
		big_face.visible = true
		_refresh_face()
		# As wide as the case it replaces, or its own need if that is more: the face
		# stands where the wiring stood, and its need is the whole rail, ports to
		# ports — a scroller's minimum would crop the instrument mid-panel.
		var natural: Vector2 = big_face.get_combined_minimum_size()
		big_face.size = Vector2(maxf(big_face.full_width(), footprint.size.x),
			natural.y)
		_place_face()
	else:
		graph_edit.face_up = false
		big_face.visible = false
		await _rebuild_view()
	if wires_button != null:
		wires_button.visible = show_face


## Keeps the mounted face under the graph's camera: its position and scale are the
## case's, through the same transform every node uses. Called from the graph each frame
## while the face is up — a canvas tenant has to follow the canvas.
## Reapplies every per-module flip to a freshly built view: hide the members, take
## their cables off the canvas, mount the face over where they stood. Runs at the end of
## every rebuild, because a rebuild restores everything and the flips are session state
## the document knows nothing about.
func _apply_flips() -> void:
	if graph_edit == null:
		return
	graph_edit.flip_frames = {}
	graph_edit.flip_labels = {}
	# A flip for a module that is no longer open — or an instance no longer in the
	# patch — has nothing to stand on.
	for module_name in flipped_modules.keys():
		if not graph_edit.groups.has(module_name):
			flipped_modules.erase(module_name)
	for instance_id in flipped_nodes.keys():
		if not widgets.has(str(instance_id)):
			flipped_nodes.erase(instance_id)
	for key in module_mounts.keys():
		if not flipped_modules.has(key) and not flipped_nodes.has(key):
			(module_mounts[key] as Control).visible = false
	for module_name in flipped_modules:
		var frame: Rect2 = graph_edit.group_box(str(module_name))
		if frame.size.x <= 0.0:
			continue
		var members: Array = graph_edit.groups.get(module_name, [])
		for widget_name in members:
			var member := graph_edit.get_node_or_null(
				NodePath(str(widget_name))) as GraphNode
			if member != null:
				member.visible = false
		for wire in graph_edit.get_connection_list():
			if members.has(String(wire["from_node"])) 					or members.has(String(wire["to_node"])):
				graph_edit.disconnect_node(wire["from_node"], wire["from_port"],
					wire["to_node"], wire["to_port"])
		var shown := _mount_for(str(module_name))
		shown.node_id = ""
		shown.opened_module = str(module_name)
		shown.visible = true
		shown.rebuild()
		var natural: Vector2 = shown.get_combined_minimum_size()
		shown.size = Vector2(maxf(natural.x, frame.size.x), natural.y)
		shown.set_meta("anchor", frame.position)
		graph_edit.flip_frames[str(module_name)] = Rect2(frame.position, shown.size)
	# Flipped instance nodes: the same turn, one widget wide. The node hides, its
	# cables leave the view (the document keeps them), and the module's face stands
	# where the node stood, knobs writing the instance's own parameters.
	for instance_id in flipped_nodes:
		var widget: GraphNode = widgets.get(str(instance_id), null)
		if widget == null:
			continue
		widget.visible = false
		for wire in graph_edit.get_connection_list():
			if String(wire["from_node"]) == String(widget.name) \
					or String(wire["to_node"]) == String(widget.name):
				graph_edit.disconnect_node(wire["from_node"], wire["from_port"],
					wire["to_node"], wire["to_port"])
		var module_name := _module_of(str(instance_id))
		var definition: Dictionary = patch.get("modules", {}).get(module_name, {})
		var shown: Control
		var band_label := ""
		if (definition.get("controls", []) as Array).is_empty():
			# No face in the definition — an older import, or a collapse that never
			# had one. The flat surface of exports is all there is to show.
			var face := _mount_for(str(instance_id))
			face.node_id = str(instance_id)
			face.opened_module = ""
			face.rebuild()
			shown = face
			band_label = module_name
		else:
			# The panel the device's file draws, wearing its own name badge — the
			# band above it needs no second copy.
			shown = _device_panel_for(str(instance_id), module_name, definition)
		shown.visible = true
		var natural: Vector2 = shown.get_combined_minimum_size()
		# The whole panel, input plate to output plate: a PatchFace holds its rail in
		# a scroller, and a scroller's minimum is its readiness to crop, not the
		# instrument's width.
		var wanted: float = natural.x
		if shown is PatchFace:
			wanted = (shown as PatchFace).full_width()
		shown.size = Vector2(maxf(wanted, widget.size.x), natural.y)
		shown.set_meta("anchor", widget.position_offset)
		# The band is keyed by instance so two of the same device turn independently —
		# the key is plumbing, not a label.
		graph_edit.flip_frames[str(instance_id)] = Rect2(widget.position_offset, shown.size)
		graph_edit.flip_labels[str(instance_id)] = band_label


## The full panel a device's file draws, mounted for one instance. The definition is
## a whole document — seams, wiring, and (since it carries the source's controls) the
## face — so the same PatchFace the file itself shows is built from a copy of it. The
## copy carries the instance's own parameter values, and write_as sends every knob's
## writes to the instance's exported parameter, which is the only parameter an
## instance actually has. Reorder and remove gestures stay unconnected on purpose:
## the face belongs to the definition's file, and an instance only plays it.
func _device_panel_for(instance_id: String, module_name: String,
		definition: Dictionary) -> Control:
	var mount: Control = module_mounts.get(instance_id, null)
	if mount != null and not (mount is PatchFace):
		# The same key wore a ModuleFace before the definition had a face to show.
		mount.queue_free()
		module_mounts.erase(instance_id)
		mount = null
	if mount == null:
		mount = PatchFace.new()
		mount.z_index = 50
		graph_edit.add_child(mount)
		module_mounts[instance_id] = mount
	var panel := mount as PatchFace
	var overrides: Dictionary = {}
	for node in patch.get("nodes", []):
		if str(node["id"]) == instance_id:
			overrides = node.get("parameters", {})
	var doc := {
		"schema_version": 2,
		"metadata": {"name": module_name},
		"nodes": (definition.get("nodes", []) as Array).duplicate(true),
		"connections": definition.get("connections", []),
		"controls": definition.get("controls", []),
	}
	var writes := {}
	for binding in definition.get("parameters", []):
		writes["%s.%s" % [str(binding["node"]), str(binding["parameter"])]] = {
			"node": instance_id, "parameter": str(binding["name"])}
		# What the instance has turned lands on the copy, so the knobs stand where
		# this device is actually set rather than where its file was saved.
		if overrides.has(str(binding["name"])):
			for node in doc["nodes"]:
				if str(node["id"]) == str(binding["node"]):
					if not node.has("parameters"):
						node["parameters"] = {}
					node["parameters"][str(binding["parameter"])] = \
						overrides[str(binding["name"])]
	# The definition's seams are unbound by design — the host wires them — so the
	# document's registry has no entry under their keys, and without one the face
	# drops their controls: the OUT knob vanished and took the whole mix strip's
	# terminal standing with it. The face only needs enough to draw them: an entry
	# under the seam's key carrying the parameters the terminals of its type have,
	# which is where a bound seam's level comes from too. The knob is honest now —
	# expansion leaves a trimmed seam behind as a Level node, so the instance's
	# "level" export reaches something that plays.
	var local_registry: Dictionary = registry.duplicate()
	for node in doc["nodes"]:
		var type_name := str(node.get("type", ""))
		if type_name != "Input" and type_name != "Output":
			continue
		var key := Seams.registry_key(node)
		if local_registry.has(key):
			continue
		var entry: Dictionary = registry.get(type_name, {}).duplicate(true)
		var parameters: Array = []
		for terminal_key in Seams.TERMINALS:
			if str(terminal_key).begins_with(type_name + "/"):
				parameters.append_array(registry.get(
					Seams.TERMINALS[terminal_key], {}).get("parameters", []))
		entry["parameters"] = parameters
		# The seam's shape is its cables, exactly as an unbound seam's is at the top
		# level: every wire through it is a socket, named and coloured by what it
		# carries. The generic entry gave every seam one anonymous port, and the
		# plate condensed an instrument's inputs into it.
		var doc_ports: Array = []
		var seen := {}
		for wire in doc["connections"]:
			var mine: Dictionary = {}
			var far: Dictionary = {}
			if str(wire.get("from", {}).get("node", "")) == str(node["id"]):
				mine = wire["from"]
				far = wire["to"]
			elif str(wire.get("to", {}).get("node", "")) == str(node["id"]):
				mine = wire["to"]
				far = wire["from"]
			else:
				continue
			var port_name := str(mine.get("port", ""))
			if seen.has(port_name):
				continue
			seen[port_name] = true
			var flavour := "control"
			var far_side := "inputs" if type_name == "Input" else "outputs"
			for far_node in doc["nodes"]:
				if str(far_node["id"]) != str(far.get("node", "")):
					continue
				for far_port in registry.get(Seams.registry_key(far_node), {}).get(
						far_side, []):
					if str(far_port.get("name", "")) == str(far.get("port", "")):
						flavour = str(far_port.get("type", "control"))
			doc_ports.append({"name": port_name, "signal": flavour})
		entry["outputs" if type_name == "Input" else "inputs"] = doc_ports
		local_registry[key] = entry
	panel.patch = doc
	panel.registry = local_registry
	panel.rack = rack
	panel.title = module_name
	panel.write_as = writes
	panel.rebuild()
	return panel


## The ModuleFace mounted on the canvas for this key — an open module's name or a
## flipped instance's id — made once and reused across rebuilds.
func _mount_for(key: String) -> ModuleFace:
	var mount: Control = module_mounts.get(key, null)
	if mount != null and not (mount is ModuleFace):
		mount.queue_free()
		module_mounts.erase(key)
		mount = null
	if mount == null:
		mount = ModuleFace.new()
		mount.z_index = 50
		(mount as ModuleFace).rearranged.connect(_on_face_rearranged)
		(mount as ModuleFace).removed.connect(_on_face_knob_removed)
		(mount as ModuleFace).refused.connect(
			func(reason: String) -> void: _say(reason))
		graph_edit.add_child(mount)
		module_mounts[key] = mount
	var shown := mount as ModuleFace
	shown.patch = patch
	shown.registry = registry
	shown.rack = rack
	return shown


func _place_face() -> void:
	if graph_edit == null:
		return
	var zoom: float = graph_edit.zoom if graph_edit.zoom > 0.0 else 1.0
	if big_face != null and big_face.visible:
		big_face.position = face_anchor * zoom - graph_edit.scroll_offset
		big_face.scale = Vector2(zoom, zoom)
	for module_name in module_mounts:
		var mount := module_mounts[module_name] as Control
		if mount.visible and mount.has_meta("anchor"):
			mount.position = (mount.get_meta("anchor") as Vector2) * zoom 				- graph_edit.scroll_offset
			mount.scale = Vector2(zoom, zoom)


func _refresh_context() -> void:
	# Which face the panel shows, and which module offers its ghost jacks, both follow the
	# selection — settled here rather than by each of the half-dozen paths that can change
	# what is selected.
	_refresh_face()
	_refresh_ghost_ports()
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
			return _type_key(node)
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

		# The other half of the toggle. The frame round an open module carries its Close;
		# a shut one is a single node with nowhere to put the opposite, so it goes here,
		# beside the name — the two things you can do to a module as a whole.
		var open_button := Button.new()
		open_button.text = "Open on the canvas"
		open_button.tooltip_text = "Put %s's parts on the canvas, inside a frame. " \
			% module_name + "Closing the frame folds them back in."
		open_button.pressed.connect(func() -> void: _open_module(node_id))
		context_panel.add_child(_defocus(open_button))

		_fill_module_contract(module_name)

	# Every output, with a click to point the scope at it — "what is this node putting out"
	# answered in one click rather than by hunting for the right port on the node itself.
	var outputs := _port_list(node_id, "outputs")
	if not outputs.is_empty():
		context_panel.add_child(_field("Outputs"))
		for port in outputs:
			context_panel.add_child(_port_row(node_id, port))


## What a module promises the patches that use it: its ports and its exported knobs.
##
## Listed here, in the inspector, and each with a way to take it back — which is the half of
## surface editing the wand cannot offer. Declaring a port or exporting a knob is safe: a
## cable cannot already be plugged into a port that did not exist, so a click is enough and
## the wand's ghosts are that click. Taking one away is the opposite. A port strands every
## cable in it; an export strands every control and automation lane aimed at it, and every
## value an instance had set through it.
##
## So it is a list with a confirmation rather than a click, and the confirmation says what
## breaks *before* it happens, counted from the document rather than described in general.
## "Remove this port" and "remove this port and the two cables in it" are different offers,
## and only one of them can be accepted honestly.
func _fill_module_contract(module_name: String) -> void:
	var definition: Dictionary = patch.get("modules", {}).get(module_name, {})
	if definition.is_empty():
		return

	# Through Seams.declared_ports, so both spellings appear. A module's port may be a
	# binding in `inputs`/`outputs` or a port node drawn inside the definition, and most of
	# them are the second — a list that showed only the binding list would omit the ports
	# nearly every module actually has, which is worse than having no list.
	for is_output in [false, true]:
		var ports: Array = Seams.declared_ports(definition, is_output)
		if ports.is_empty():
			continue
		context_panel.add_child(_field("Module outputs" if is_output else "Module inputs"))
		for port: Dictionary in ports:
			context_panel.add_child(_contract_row(
				str(port["name"]),
				"%s.%s" % [str(port["node"]), str(port["port"])],
				_cables_into(module_name, str(port["name"])),
				"cable",
				func(): _undeclare_port(module_name, is_output, str(port["name"]))))

	var exports: Array = definition.get("parameters", [])
	if exports.is_empty():
		return
	context_panel.add_child(_field("Knobs"))
	for binding: Dictionary in exports:
		context_panel.add_child(_contract_row(
			str(binding["name"]),
			"%s.%s" % [str(binding["node"]), str(binding["parameter"])],
			_controls_driving(module_name, str(binding["name"])),
			"control",
			func(): _unexport_knob(module_name, str(binding["name"]))))


## One line of the contract: what it is called, what it reaches, and a way to take it off.
func _contract_row(shown: String, inner: String, depends: int, noun: String,
		remove: Callable) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", Design.scale(Design.SPACE_S))

	var name_label := Label.new()
	name_label.text = shown
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.clip_text = true
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	# What it actually reaches, under the name the module gave it — the same pairing the
	# file's own panel draws, so "which inner thing is this" never needs the file open.
	name_label.tooltip_text = inner
	name_label.add_theme_font_size_override("font_size", Design.type(Design.SIZE_CONTROL))
	row.add_child(name_label)

	if depends > 0:
		# The count, before anything is clicked. A number that only appears in the
		# confirmation is a number somebody meets after deciding.
		var uses := Label.new()
		uses.text = "%d %s%s" % [depends, noun, "" if depends == 1 else "s"]
		uses.add_theme_font_size_override("font_size", Design.type(Design.SIZE_SECONDARY))
		uses.add_theme_color_override("font_color", Design.INK_SECOND)
		row.add_child(uses)

	var take_off := Button.new()
	take_off.text = "×"
	take_off.tooltip_text = "Take %s off the module" % shown
	take_off.pressed.connect(func() -> void:
		if depends == 0:
			remove.call()
			return
		_confirm("Take %s off %s?" % [shown, noun],
			"%d %s%s point%s at it and will be removed too. Undo puts everything back."
				% [depends, noun, "" if depends == 1 else "s",
					"s" if depends == 1 else ""],
			remove))
	row.add_child(_defocus(take_off))
	return row


## How many cables are plugged into this port, across every instance of the module.
func _cables_into(module_name: String, port_name: String) -> int:
	var instances := _instances_of(module_name)
	var count := 0
	for connection in patch.get("connections", []):
		for end in ["from", "to"]:
			var side: Dictionary = connection[end]
			if instances.has(str(side["node"])) and str(side["port"]) == port_name:
				count += 1
	return count


## How many controls and automation lanes are aimed at this export.
func _controls_driving(module_name: String, export_name: String) -> int:
	var instances := _instances_of(module_name)
	var count := 0
	for list_key in ["controls", "automation"]:
		for item in patch.get(list_key, []):
			var target: Dictionary = item.get("target", {})
			if instances.has(str(target.get("node", ""))) \
					and str(target.get("parameter", "")) == export_name:
				count += 1
	return count


func _instances_of(module_name: String) -> Dictionary:
	var instances := {}
	for node in patch.get("nodes", []):
		if str(node.get("module", "")) == module_name:
			instances[str(node["id"])] = true
	return instances


## Asks before doing something that cannot be undone by doing it again.
##
## One dialog, rebuilt each time rather than kept: it is shown from a panel that is itself
## rebuilt on every selection change, and a dialog outliving the button that opened it is a
## dialog acting on a module nobody is looking at any more.
func _confirm(title: String, body: String, then: Callable) -> void:
	var dialog := ConfirmationDialog.new()
	dialog.title = title
	dialog.dialog_text = body
	dialog.ok_button_text = "Remove"
	dialog.confirmed.connect(func() -> void:
		then.call()
		dialog.queue_free())
	dialog.canceled.connect(func() -> void: dialog.queue_free())
	add_child(dialog)
	dialog.popup_centered()


## Takes a port off a module, and every cable that was plugged into it.
##
## The cables go rather than being left behind. A connection naming a port the module no
## longer has is a document that will not load — the loader is right to refuse it — so the
## choice is between removing them here, where it can be counted and undone in one step, and
## writing a file that has to be repaired by hand.
func _undeclare_port(module_name: String, is_output: bool, port_name: String) -> void:
	var definition: Dictionary = patch.get("modules", {}).get(module_name, {})
	if definition.is_empty():
		return
	_begin_edit()

	# Both spellings, because a port has two. A seam drawn inside the definition *is* the
	# port, so taking the port away means taking the node away — and the inner wires that
	# ran to it, which would otherwise name a node the definition no longer has.
	var seam_id := ""
	for inner in definition.get("nodes", []):
		if not Seams.is_port_seam(inner):
			continue
		if str(inner.get("type", "")) != ("Output" if is_output else "Input"):
			continue
		var named := str(inner.get("name", ""))
		if named == "":
			named = str(inner["id"])
		if named == port_name:
			seam_id = str(inner["id"])
	if seam_id != "":
		var kept_inner: Array = []
		for inner in definition.get("nodes", []):
			if str(inner["id"]) != seam_id:
				kept_inner.append(inner)
		definition["nodes"] = kept_inner
		var kept_wires: Array = []
		for wire in definition.get("connections", []):
			if str(wire["from"]["node"]) != seam_id and str(wire["to"]["node"]) != seam_id:
				kept_wires.append(wire)
		definition["connections"] = kept_wires

	var side := "outputs" if is_output else "inputs"
	var kept_bindings: Array = []
	for binding in definition.get(side, []):
		if str(binding["name"]) != port_name:
			kept_bindings.append(binding)
	if kept_bindings.is_empty():
		definition.erase(side)
	else:
		definition[side] = kept_bindings

	var instances := _instances_of(module_name)
	var kept: Array = []
	var stranded := 0
	for connection in patch.get("connections", []):
		var gone := false
		for end in ["from", "to"]:
			var at: Dictionary = connection[end]
			if instances.has(str(at["node"])) and str(at["port"]) == port_name:
				gone = true
		if gone:
			stranded += 1
			continue
		kept.append(connection)
	patch["connections"] = kept

	_synthesize_module_descriptors()
	await _rebuild_view()
	_apply()
	_refresh_context()
	_commit_edit("take %s off %s" % [port_name, module_name])
	_say("%s is no longer a port of %s%s" % [port_name, module_name,
		"" if stranded == 0 else " — and %d cable%s had nowhere to land"
			% [stranded, "" if stranded == 1 else "s"]])


## Takes a knob off a module's surface, with everything that was reaching through it.
##
## Unlike the panel, the surface is not presentation: an export is what a patch can set, a
## control can drive and automation can reach. So this drops the panel row too, the controls
## and lanes aimed at it, and any value an instance had set through it — a value nothing
## reads is not an error but it is a lie, and saving it would suggest something does.
func _unexport_knob(module_name: String, export_name: String) -> void:
	var definition: Dictionary = patch.get("modules", {}).get(module_name, {})
	if definition.is_empty():
		return
	_begin_edit()
	var kept_exports: Array = []
	for binding in definition.get("parameters", []):
		if str(binding["name"]) != export_name:
			kept_exports.append(binding)
	if kept_exports.is_empty():
		definition.erase("parameters")
	else:
		definition["parameters"] = kept_exports

	var panel: Dictionary = definition.get("panel", {})
	if panel.has("rows"):
		var rows := ModuleFace.moved(panel["rows"], export_name, {"remove": true})
		if rows.is_empty():
			panel.erase("rows")
		else:
			panel["rows"] = rows
	if panel.has("labels"):
		(panel["labels"] as Dictionary).erase(export_name)
		if (panel["labels"] as Dictionary).is_empty():
			panel.erase("labels")
	if panel.is_empty():
		definition.erase("panel")

	var instances := _instances_of(module_name)
	for node in patch.get("nodes", []):
		if instances.has(str(node["id"])):
			(node.get("parameters", {}) as Dictionary).erase(export_name)

	var dropped := 0
	for list_key in ["controls", "automation"]:
		if not patch.has(list_key):
			continue
		var kept_targets: Array = []
		for item in patch[list_key]:
			var target: Dictionary = item.get("target", {})
			if instances.has(str(target.get("node", ""))) \
					and str(target.get("parameter", "")) == export_name:
				dropped += 1
				continue
			kept_targets.append(item)
		patch[list_key] = kept_targets

	_synthesize_module_descriptors()
	await _rebuild_view()
	_apply()
	_refresh_face()
	_refresh_context()
	_commit_edit("take %s off %s's surface" % [export_name, module_name])
	_say("%s is no longer exported by %s%s" % [export_name, module_name,
		"" if dropped == 0 else " — and %d control%s had nothing left to drive"
			% [dropped, "" if dropped == 1 else "s"]])


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
## ---------------------------------------------------------------------------------
## The killswitch
##
## Builds need the GDExtension DLL, and a running editor holds it — so anything that
## wants to rebuild had to hunt processes. Instead the editor watches for a
## quit-request file in the repo's run/ directory, once a second, and bows out on
## its own: tooling drops the file, waits a breath, builds. Unsaved work is written
## to a rescue file first, because a killswitch that eats work teaches people to
## fear it — and a feared killswitch is one nobody throws.
## ---------------------------------------------------------------------------------
var _quit_poll := 0.0

func _watch_for_quit_request(delta: float) -> void:
	_quit_poll += delta
	if _quit_poll < 1.0:
		return
	_quit_poll = 0.0
	var flag := ProjectSettings.globalize_path("res://").path_join("../run/quit-request")
	if not FileAccess.file_exists(flag):
		return
	DirAccess.remove_absolute(flag)
	if unsaved and not patch.is_empty():
		var rescue := ProjectSettings.globalize_path("res://").path_join(
			"../run/rescued-%d.json" % int(Time.get_unix_time_from_system()))
		var file := FileAccess.open(rescue, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(patch, "  "))
			file.close()
	get_tree().quit()


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
	_watch_for_quit_request(_delta)
	# Before the early return: the dock's cables have to follow the graph as it scrolls,
	# zooms and has nodes dragged under them, and none of that waits for an engine.
	_refresh_seam_cables()
	if engine == null or playback == null:
		return
	if engine.is_loaded():
		engine.fill_playback(playback, playback.get_frames_available())
	_update_scope()
	_update_port_levels(_delta)
	if rack != null and rack.is_visible_in_tree():
		rack.refresh_displays()
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
	# No node, or a node with no port to listen to: the master output, which is the honest
	# answer to "what am I hearing" when nothing narrower has been asked for.
	if not inspecting.has("port"):
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
	# The synthesized descriptors are read from the document, so they are stale the moment
	# it changes. Every caller that edited modules or seams used to remember to rebuild
	# them and every new caller had to be told; doing it here means the widgets are built
	# against the document in front of them, which is the only version that was ever right.
	_synthesize_module_descriptors()
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
	_apply_flips()

	# Fresh widgets are built showing everything, but the zoom has an opinion already.
	# _apply_detail only ran on detail_changed, and a rebuild does not change the
	# detail — so rebuilding while zoomed out (a UI-scale toggle, a palette switch)
	# produced full-detail nodes at 55%, sub-floor text and all, which then snapped
	# back to the honest view on the next zoom step. The level in force gets
	# re-applied to the widgets that were not there when it was announced.
	_apply_detail(graph_edit.detail)

	_refresh_groups()

	# The rack reads the same document, so it is rebuilt from the same place rather than
	# kept in step by hand.
	if rack != null:
		rack.registry = registry
		rack.patch = patch
		rack.rebuild()
	_refresh_face()
	_refresh_master()
	_refresh_seam_dock()


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
## Which registry entry draws this node. One line, because there is one answer and it
## lives in seams.gd — this had its own copy of the rule and went on returning the
## terminal after that rule changed, which is what a second copy is for.
func _type_key(node: Dictionary) -> String:
	return Seams.registry_key(node)





## A descriptor for each seam the patch uses: what the terminal carries, plus the jack the
## machine plugs into.
##
## Synthesized rather than added to dsp-core's registry, for the same reason a module's is:
## dsp-core has never heard of a seam and this design is that it never has to. The editor
## is where a seam is a thing you look at, so the editor is where it gets a face.
##
## The host jack goes first, so it is the top row of the node — the edge of the patch is
## drawn at the edge of the node, and a reader looking for "where does the keyboard go"
## finds it without counting.
## The ports a node is actually wired through, in the order the cables appear, as registry
## port entries. The signal type is taken from the far end, which is the only place that
## knows: a seam carries whatever is plugged into it.
func _wired_ports(node_id: String, leaving: bool) -> Array:
	var seen := {}
	var ports: Array = []
	for wire in patch.get("connections", []):
		var near: Dictionary = wire["from"] if leaving else wire["to"]
		var far: Dictionary = wire["to"] if leaving else wire["from"]
		if str(near["node"]) != node_id:
			continue
		var port_name := str(near["port"])
		if seen.has(port_name):
			continue
		seen[port_name] = true
		ports.append({"name": port_name,
			"type": _far_port_type(str(far["node"]), str(far["port"]), leaving)})
	return ports


## The signal type at the other end of a cable. From the document rather than the widgets:
## this runs while the descriptors are being built, which is before any widget exists.
##
## Falls back to "control", the type that draws plainly and connects to anything, when the
## far end is a node this editor has no descriptor for.
func _far_port_type(node_id: String, port: String, arriving: bool) -> String:
	for node in patch.get("nodes", []):
		if str(node["id"]) != node_id:
			continue
		var descriptor: Dictionary = registry.get(_type_key(node), {})
		for entry in descriptor.get("inputs" if arriving else "outputs", []):
			if str(entry["name"]) == port:
				return str(entry.get("type", "control"))
		return "control"
	return "control"


## The ports this runtime has a machine for, one per host, offered by the palette whether
## or not the open patch uses them. A palette that lists only what you already have is a
## list, not a palette — and a port is how you say where your patch's edges are, which is
## something you decide while building it rather than something you inherit.
const DEVICE_SEAMS := [
	{"type": "Input", "host": "note", "device": "the keyboard"},
	{"type": "Input", "host": "audio", "device": "an audio input"},
	{"type": "Output", "host": "stereo", "device": "the speakers"},
]


func _synthesize_seam_descriptors() -> void:
	for key in registry.keys().filter(func(k): return str(k).begins_with("seam:")):
		registry.erase(key)
	# The machine's own ports first, then whatever the patch turned out to have. Order
	# matters only in that a patch node must not overwrite a device entry with a narrower
	# one: both describe `seam:Input/note`, and the device's description is the one that
	# reads properly in a palette.
	for node in DEVICE_SEAMS + patch.get("nodes", []):
		var type_name := str(node.get("type", ""))
		if type_name != "Input" and type_name != "Output":
			continue
		var key := Seams.registry_key(node)
		if registry.has(key):
			continue
		var terminal := Seams.terminal_for(node)
		var carried: Dictionary = registry.get(terminal, {})
		var host := str(node.get("host", ""))
		# An unbound port has no host to take its shape from, so it takes it from its
		# cables: whatever names they use, it has. Nothing else would do — a port that lost
		# its outlets the moment you unplugged the keyboard would drop four cables with it,
		# and unplugging is meant to be a thing you can undo by plugging back in.
		if host == "":
			var node_id := str(node.get("id", ""))
			carried = {"inputs": _wired_ports(node_id, false),
				"outputs": _wired_ports(node_id, true)}
			# A port with no host and no cables yet is a single port named after itself —
			# which is exactly what a module's port is, and for the same reason: with no
			# host to ask, the only thing it can carry is whatever somebody plugs into it.
			# Without this a freshly added port would have nothing to connect to and could
			# never acquire the wiring it takes its shape from.
			var side := "inputs" if type_name == "Output" else "outputs"
			if (carried[side] as Array).is_empty():
				carried[side] = [{"name": str(node.get("name", node_id)),
					"type": "control"}]
		var inputs: Array = []
		var outputs: Array = []
		if type_name == "Input":
			# What the machine hands in, and what the patch takes from it.
			inputs.append({"name": Seams.HOST_PORT, "type": "control",
				"doc": "Where %s plugs in. Unconnected inside a module: the patch using it "
					% (host if host != "" else "the machine")
					+ "drives this from outside."})
			outputs = carried.get("outputs", []).duplicate(true)
		else:
			inputs = carried.get("inputs", []).duplicate(true)
			outputs.append({"name": Seams.HOST_PORT, "type": "audio",
				"doc": "Where %s listens. Unconnected inside a module: whatever uses it "
					% (host if host != "" else "the machine")
					+ "takes the signal from here."})
		# Named for what plugs into it. "Input port" three times over would make the palette
		# a guessing game, and which host it is carries the whole difference.
		var shown := "%s port" % type_name
		var summary := "A seam: where this graph meets what is outside it."
		var device := str(node.get("device", ""))
		if host != "":
			shown = "%s port · %s" % [type_name, host]
		if device != "":
			summary = "An edge of the patch: where it meets %s. " % device \
				+ "Plug the machine into it to hear the patch from here."
		registry[key] = {
			"name": key,
			"display_name": shown,
			"category": "Terminals",
			"summary": summary,
			"inputs": inputs,
			"outputs": outputs,
			"parameters": carried.get("parameters", []).duplicate(true),
		}


## Builds a registry-shaped descriptor for each module definition, so instances flow
## through every code path a plain node does. Signal types, units and parameter ranges
## come from the inner nodes' own registry entries — the facade renames, it does not
## invent.
func _synthesize_module_descriptors() -> void:
	_synthesize_seam_descriptors()
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
		for binding in Seams.declared_ports(definition, false):
			inputs.append(port_entry.call(binding, "inputs"))
		var outputs: Array = []
		for binding in Seams.declared_ports(definition, true):
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
	# Through Seams, which answers for both spellings of a declared port. Reading the
	# binding lists alone made a module whose ports are *drawn* look as though it declared
	# none — so every port it already had came back as a ghost offering to declare it
	# again. Found by the test that builds one module both ways and demands the editor
	# cannot tell them apart, which is the fourth time this rule has been copied wrong.
	var declared := {}
	for is_output in [false, true]:
		for binding: Dictionary in Seams.declared_ports(definition, is_output):
			declared["%s/%s" % [str(binding["node"]), str(binding["port"])]] = true
	var offers: Array = []
	for node in definition.get("nodes", []):
		# A seam is a port, not a part: offering to expose its innards would be offering
		# to declare a port on a port.
		if Seams.is_port_seam(node) \
				or str(node.get("type", "")) in ["Input", "Output"]:
			continue
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
		# The rack order is keyed by id too, and a stale entry is a module that jumps back
		# to where the layering would have put it the next time the patch is opened.
		var arrangement: Dictionary = patch.get(Rack.ARRANGEMENT_KEY, {})
		var order: Array = arrangement.get(Rack.ORDER_KEY, [])
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
		# Through the shared reader: a module's outputs are drawn as seams now, and a
		# glow that stopped following one would leave every instance port dark with
		# nothing on screen saying why.
		for binding in Seams.declared_ports(definition, true):
			if str(binding["name"]) == port:
				return ["%s.%s" % [node_id, str(binding["node"])], str(binding["port"])]
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

	# A closed module carries its own flip, in the titlebar: the case band and the open
	# frame already have theirs, and a device in a mixed graph is either being patched
	# or being played. The chip turns it over to its panel where it stands, without
	# opening its wires first; WIRES on the mounted panel turns it back.
	if str(node.get("module", "")) != "":
		var flip := Button.new()
		flip.name = "Flip"
		flip.text = "FACE"
		flip.focus_mode = Control.FOCUS_NONE
		flip.tooltip_text = "Turn the module over to its panel. " \
			+ "WIRES on the panel turns it back."
		flip.add_theme_font_size_override("font_size", Design.type(Design.SIZE_SECONDARY))
		flip.add_theme_color_override("font_color", Design.ACCENT)
		# Dressed as the WIRES chip on the panel is dressed — outline and a breath
		# of fill, secondary type, tight margins — so the two ends of the flip read
		# as one control met twice.
		var chip := StyleBoxFlat.new()
		chip.bg_color = Color(Design.ACCENT, 0.16)
		chip.border_color = Color(Design.ACCENT, 0.55)
		chip.set_border_width_all(1)
		chip.content_margin_left = float(Design.scale(Design.SPACE_S))
		chip.content_margin_right = float(Design.scale(Design.SPACE_S))
		chip.content_margin_top = 2.0
		chip.content_margin_bottom = 2.0
		var chip_hover := chip.duplicate() as StyleBoxFlat
		chip_hover.bg_color = Color(Design.ACCENT, 0.28)
		flip.add_theme_stylebox_override("normal", chip)
		flip.add_theme_stylebox_override("hover", chip_hover)
		flip.add_theme_stylebox_override("pressed", chip_hover)
		var instance_id := str(node["id"])
		flip.pressed.connect(func() -> void:
			flipped_nodes[instance_id] = true
			_apply_flips())
		widget.get_titlebar_hbox().add_child(flip)

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
	# The knob grid, as rows.
	#
	# A module with a panel wears the face its panel describes: those knobs, in those rows,
	# under those captions. Everything else it exports is still exported and still settable
	# — the surface is the contract and the panel is presentation — it is simply not on the
	# front, which is the entire point of having said so. Anything without a panel wraps
	# its whole surface PARAMETERS_PER_LINE to a line, as it always did.
	var parameters: Array = descriptor.get("parameters", [])
	var grid: Array = descriptor.get("panel_rows", []).duplicate()
	var shown := 0
	if grid.is_empty():
		var line: Array = []
		for parameter: Dictionary in parameters:
			line.append(parameter)
			if line.size() == PARAMETERS_PER_LINE:
				grid.append(line)
				line = []
		if not line.is_empty():
			grid.append(line)
	for row_of: Array in grid:
		shown += row_of.size()
	var port_rows: int = maxi(inputs.size(), outputs.size())
	var cell_lines: int = grid.size()
	# Progressive complexity, counted in lines: a node shows its common case and says how
	# much it is holding back rather than hiding it silently.
	var always_visible: int = 1 if shown > 3 else cell_lines
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
		if row < grid.size():
			for parameter: Dictionary in grid[row]:
				cells.add_child(_build_parameter_row(node, parameter))
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

	_add_ghost_ports(widget, str(node["id"]), descriptor)
	_add_disclosure(widget, folded)

	graph_edit.add_child(widget)
	widgets[node["id"]] = widget
	ids[widget.name] = node["id"]


## Shows the selected module's ghost jacks and hides everyone else's. There is no mode to
## put down, so the selection is what says which module is being worked on — and therefore
## also what says when none is.
func _refresh_ghost_ports() -> void:
	var selected := str(inspecting.get("node", ""))
	for node_id in widgets:
		for child in (widgets[node_id] as GraphNode).get_children():
			var row := child as Control
			if row != null and not (row.get_meta("ghost_offer", {}) as Dictionary).is_empty():
				row.visible = str(node_id) == selected


## Ghost jacks: inner ports this module could expose and does not.
##
## Rows of their own, appended after every real port row and carrying no slot. That is not
## a style choice — GraphEdit binds a slot to the index of a visible child, so a row with a
## slot inserted anywhere but the end renumbers the slots below it and the cables reattach
## to the wrong ports. Appending slotless rows leaves every existing slot index alone, which
## is what makes it safe to grow and shrink these as the wand goes up and down.
##
## Drawn faint, with the port's own icon, so a ghost reads as an offer rather than as a jack
## that has stopped working. The metadata is what PatchGraph.ghost_port_at looks for.
func _add_ghost_ports(widget: GraphNode, node_id: String, descriptor: Dictionary) -> void:
	# Built for every module, shown for the selected one.
	#
	# Built always, because growing and freeing rows on every selection change would mean a
	# graph rebuild each time somebody clicks a node. Hidden rather than absent, because a
	# row of faint text on every composite in the patch is a lot of furniture for an offer.
	# Hiding is safe where inserting is not: these carry no slot and sit after every row
	# that does, so GraphEdit has no index to renumber either way.
	var offers: Array = descriptor.get("port_offers", [])
	if offers.is_empty():
		return
	for offer: Dictionary in offers:
		var binding: Dictionary = offer.get("offer", {})
		if binding.is_empty():
			continue
		var line := HBoxContainer.new()
		line.add_theme_constant_override("separation", Design.scale(Design.SPACE_S))
		line.alignment = BoxContainer.ALIGNMENT_CENTER
		line.set_meta("row", "ghost")
		line.set_meta("has_slot", false)
		line.set_meta("ghost_offer", binding)
		line.modulate = Color(1.0, 1.0, 1.0, 0.45)
		line.visible = str(inspecting.get("node", "")) == node_id

		var icon := TextureRect.new()
		icon.texture = _port_icon(str(offer.get("type", "control")))
		icon.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		line.add_child(icon)

		var label := Label.new()
		# Where it comes from, not just what it is called. Two inner nodes may both have a
		# "gain", and the name this port would end up with is the document's to choose.
		label.text = "%s.%s" % [str(binding.get("node", "")), str(binding.get("port", ""))]
		label.add_theme_font_size_override("font_size", Design.type(Design.SIZE_SECONDARY))
		label.add_theme_color_override("font_color", Design.INK_SECOND)
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		line.add_child(label)

		line.tooltip_text = "Click to make %s.%s a port of this module" \
			% [str(binding.get("node", "")), str(binding.get("port", ""))]
		widget.add_child(line)


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
	# The caption when a panel gave it one, the binding's own name otherwise. `name` is
	# what the knob writes back through and is never touched by a caption — the two are
	# separate fields precisely so that naming a knob cannot rewire it.
	label.text = str(parameter.get("display_name", "")) \
		if str(parameter.get("display_name", "")) != "" else name
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
	if node_id == "":
		# Still a selection change, even though there is nothing behind it. Returning
		# without saying so left the panel describing whatever was selected before — which
		# was invisible while the panel was only ever the file's own face, and is not now
		# that it can be a module's.
		inspecting = {}
		_refresh_context()
		return
	# The node always; the port only when there is one to scope.
	#
	# These were one thing, and emptying the pair when a node had no outputs meant a node
	# with nothing to listen to also had no name, no rename field and no way to be opened —
	# the inspector showed the whole graph instead, as though nothing were selected. A
	# module that only consumes is unusual but perfectly legal, and it was unreachable.
	var outputs := _port_list(node_id, "outputs")
	inspecting = {"node": node_id}
	if not outputs.is_empty():
		inspecting["port"] = outputs[0]["name"]
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

	# Master volume and mute, on the instrument rather than in the chrome.
	#
	# The volume knob is not a new idea either: it drives the output node's own `level`,
	# the same parameter the panel's Master knob drives when a patch has put one there.
	# What it adds is that the instrument has a volume control whether or not somebody
	# thought to put one on the panel, which is true of every instrument anybody has ever
	# played and was not true of this one.
	#
	# Mute is the exception that does not touch the document. Muting is a thing you do to
	# a room, not to a patch — it should not make the file unsaved, it should not be
	# undoable, and it must not be saved and handed to somebody else silent. So it sets
	# the engine's parameter directly and leaves `level` where it was.
	master_mute = Button.new()
	master_mute.toggle_mode = true
	master_mute.text = "Mute"
	master_mute.tooltip_text = "Silence the output without changing the patch. Nothing " 		+ "about the file changes and the level stays where you left it."
	master_mute.toggled.connect(func(pressed: bool) -> void: _set_muted(pressed))
	bar.add_child(_defocus(master_mute))

	master_knob = Rack.Knob.new()
	master_knob.rack = rack
	master_knob.compact = true
	# A stand-in descriptor before the tree sees it: Knob reads its name and its doc in
	# _ready to build a tooltip, so it cannot be added holding nothing. _refresh_master
	# replaces this with the output node's real one as soon as a patch is open.
	master_knob.descriptor = {"name": "level", "min": 0.0, "max": 1.2, "default": 0.8,
		"scaling": "linear", "unit": "", "doc": "Master output level."}
	master_knob.visible = false
	bar.add_child(master_knob)

	master_label = Label.new()
	master_label.text = "Volume"
	master_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	master_label.add_theme_font_size_override("font_size",
		Design.type(Design.SIZE_SECONDARY))
	master_label.add_theme_color_override("font_color", Design.INK_SECOND)
	bar.add_child(master_label)

	# The keyboard's own jacks, on the keyboard. This is where the cables into the patch
	# come from — see seam_dock.gd for why they cannot be drawn by GraphEdit.
	note_jacks = SeamDock.Jacks.new()
	note_jacks.type_colours = TYPE_COLOURS
	note_jacks.ink = INK
	note_jacks.jack_grabbed.connect(_on_jack_grabbed)
	note_jacks.tooltip_text = "Drag a jack onto an Input port to drive it, " \
		+ "or off the graph to unplug it."
	bar.add_child(note_jacks)

	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(gap)

	# And the output's, at the far end: signal leaves the instrument on the right, the
	# same direction it travels through every graph and rack in this application.
	output_jacks = SeamDock.Jacks.new()
	output_jacks.type_colours = TYPE_COLOURS
	output_jacks.ink = INK
	output_jacks.jack_grabbed.connect(_on_jack_grabbed)
	output_jacks.tooltip_text = "Drag onto an Output port to listen to it, " \
		+ "or off the graph to unplug it."
	bar.add_child(output_jacks)

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


## What the palette may offer, out of everything the registry knows.
##
## Three things are in the registry that are not things you add. A module instance is made
## by collapsing a selection, not by picking a type. A per-node port shape (`seam:Input/@x`)
## describes a port that already exists. And the bare terminals — NoteInput, AudioInput,
## StereoOutput — are the older spelling of the port primitives: still loaded, still
## rendered, but offering both would put two ways to say the same thing side by side in the
## one place a person goes to learn the vocabulary.
##
## The terminal a search turns up is translated rather than dropped, so looking for
## "keyboard" still lands on something: the core ranks NoteInput, and what you get offered
## is the Input port bound to it.
func _addable(names: PackedStringArray) -> PackedStringArray:
	var out := PackedStringArray()
	var seen := {}
	for name in names:
		var key := str(name)
		for device: Dictionary in DEVICE_SEAMS:
			if key == Seams.TERMINALS.get("%s/%s" % [device["type"], device["host"]], ""):
				key = "seam:%s/%s" % [device["type"], device["host"]]
		if key.begins_with("module:") or key.contains("/@") or seen.has(key):
			continue
		seen[key] = true
		out.append(key)
	return out


func _build_result_row(type_name: String) -> Control:
	var descriptor: Dictionary = registry.get(type_name, {})
	if type_name.begins_with("device:"):
		descriptor = {
			"display_name": type_name.trim_prefix("device:"),
			"summary": "device — a whole patch as one node",
			"category": "Devices",
		}

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
	var names: PackedStringArray = engine.search_nodes(query) if query.strip_edges() != "" \
		else PackedStringArray(registry.keys())
	names = _addable(names)

	# Devices beside nodes, because the main way to build is mixing them: a whole patch
	# — a DX7 voice, an effect — drops in as one module node, wired like anything else.
	# Matched by name against the example library, and only on a real query: browsing
	# two hundred devices under an empty search would bury the node vocabulary.
	for label in _matching_devices(query):
		names.append("device:%s" % label)

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

	if type_name.begins_with("device:"):
		var added := await _add_device(type_name.trim_prefix("device:"), spawn)
		if added != "":
			search_hint.text = "Added %s. Keep going, or press Escape when you are done." \
				% added
		return
	var node_id := await _add_node(type_name, spawn)
	search_hint.text = "Added %s. Keep going, or press Escape when you are done." % node_id


## Example patches whose labels match every word of the query, a handful at most.
func _matching_devices(query: String) -> Array:
	var words := query.strip_edges().to_lower().split(" ", false)
	if words.is_empty():
		return []
	var matches: Array = []
	for label in _examples:
		var lowered := str(label).to_lower()
		var all_words := true
		for word in words:
			if not lowered.contains(str(word)):
				all_words = false
		if all_words:
			matches.append(str(label))
		if matches.size() >= 8:
			break
	return matches


## Wires a fresh device to the machine where the names line up, and says what it did.
##
## The gap this closes: an added device sat silent until somebody found its sockets, and
## "added" should be a lot closer to "heard". The rule is deliberately narrow — an input
## port is wired to a host seam outlet with exactly the same name (frequency to
## frequency, gate to gate), and an audio output to a host output inlet only when that
## inlet is unfed, because taking a socket something else is using would change the
## sound that was already there. Everything it declines is left for the hand, and the
## diagnostics already say which sockets still want cables.
##
## Part of the same edit as the add, so one Ctrl+Z removes the device and its cables
## together — the offer is a done thing that costs one undo to refuse.
func _auto_wire_device(instance_id: String, module_name: String) -> Array:
	var wired: Array = []
	var descriptor: Dictionary = registry.get("module:%s" % module_name, {})
	var fed := {}
	for wire in patch.get("connections", []):
		fed["%s/%s" % [str(wire["to"]["node"]), str(wire["to"]["port"])]] = true

	for port: Dictionary in descriptor.get("inputs", []):
		var port_name := str(port.get("name", ""))
		if fed.has("%s/%s" % [instance_id, port_name]):
			continue
		for node in patch.get("nodes", []):
			if str(node.get("type", "")) != "Input" or str(node.get("host", "")) == "":
				continue
			var offers: Dictionary = registry.get(Seams.registry_key(node), {})
			for outlet: Dictionary in offers.get("outputs", []):
				if str(outlet.get("name", "")) == port_name:
					patch["connections"].append({
						"from": {"node": str(node["id"]), "port": port_name},
						"to": {"node": instance_id, "port": port_name}})
					fed["%s/%s" % [instance_id, port_name]] = true
					wired.append("%s → %s" % [str(node.get("name", node["id"])),
						port_name])

	# Where the outs land: a Mixer first, when the graph has one with room for the
	# whole pair — several devices into one mix is what a mixer is for, and wiring
	# past it straight to the speakers would put the device outside the mix. Each
	# out takes one vacant channel, in order; a mixer without room for all of them
	# is passed over rather than splitting a pair across boxes.
	var audio_outs: Array = []
	for port: Dictionary in descriptor.get("outputs", []):
		if str(port.get("type", port.get("signal", ""))) == "audio":
			audio_outs.append(str(port.get("name", "")))
	if not audio_outs.is_empty():
		for node in patch.get("nodes", []):
			if str(node.get("type", "")) != "Mixer":
				continue
			var mixer_id := str(node["id"])
			var vacant: Array = []
			for inlet: Dictionary in registry.get("Mixer", {}).get("inputs", []):
				if str(inlet.get("type", "")) != "audio":
					continue
				var inlet_name := str(inlet.get("name", ""))
				if not fed.has("%s/%s" % [mixer_id, inlet_name]):
					vacant.append(inlet_name)
			if vacant.size() < audio_outs.size():
				continue
			for index in audio_outs.size():
				patch["connections"].append({
					"from": {"node": instance_id, "port": str(audio_outs[index])},
					"to": {"node": mixer_id, "port": str(vacant[index])}})
				fed["%s/%s" % [mixer_id, str(vacant[index])]] = true
				wired.append("%s → %s.%s" % [str(audio_outs[index]), mixer_id,
					str(vacant[index])])
			return wired

	for port: Dictionary in descriptor.get("outputs", []):
		if str(port.get("type", port.get("signal", ""))) != "audio":
			continue
		var port_name := str(port.get("name", ""))
		for node in patch.get("nodes", []):
			if str(node.get("type", "")) != "Output" or str(node.get("host", "")) == "":
				continue
			var takes: Dictionary = registry.get(Seams.registry_key(node), {})
			# A named channel goes to its namesake and nowhere else — left to left,
			# right to right, which is the whole point of the pair. A mono out has
			# no namesake, and takes every vacant inlet: that is what plugging a
			# mono jack into a stereo pair has always meant.
			var named := false
			for inlet: Dictionary in takes.get("inputs", []):
				if str(inlet.get("name", "")) == port_name:
					named = true
			for inlet: Dictionary in takes.get("inputs", []):
				var inlet_name := str(inlet.get("name", ""))
				if named and inlet_name != port_name:
					continue
				if fed.has("%s/%s" % [str(node["id"]), inlet_name]):
					continue
				patch["connections"].append({
					"from": {"node": instance_id, "port": port_name},
					"to": {"node": str(node["id"]), "port": inlet_name}})
				fed["%s/%s" % [str(node["id"]), inlet_name]] = true
				wired.append("%s → %s" % [port_name, inlet_name])
	return wired


## Drops a whole patch onto this one as a single module node — mixed mode's front door.
##
## The second copy shares the first's definition: two DX7 voices in a graph are two
## instances of one dx7_algo_01, not two forty-line definitions that happen to agree.
## The name is the identity, as it is everywhere else in the document.
##
## A file may not be added to itself. The definitional cycle is already refused by
## patch-io, but adding ALGO 01 while editing ALGO 01 is almost never a request for a
## twin — it reads as "put this inside itself", and the honest answer to that is no.
func _add_device(label: String, at_position: Vector2) -> String:
	if not _examples.has(label):
		_say("no device called %s" % label)
		return ""
	var path := _example_path(_examples[label])
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_say("could not read %s" % path)
		return ""
	var text := file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		_say("that file is not a patch")
		return ""

	var device_name := str((parsed as Dictionary).get("metadata", {}).get("name", ""))
	if device_name != "" and device_name == _instrument_name():
		_say("that is this file — a patch cannot contain itself")
		return ""

	var module_name := ModuleImport.name_from_path(path)
	if patch.get("modules", {}).has(module_name):
		# Already aboard: another instance of the definition this document has.
		_begin_edit()
		var taken: Array = patch.get("nodes", []).map(func(n): return str(n["id"]))
		var instance_id := module_name
		var suffix := 2
		while taken.has(instance_id):
			instance_id = "%s-%d" % [module_name, suffix]
			suffix += 1
		patch["nodes"].append({
			"id": instance_id,
			"type": "module",
			"module": module_name,
			"position": {"x": at_position.x, "y": at_position.y},
		})
		var rewired: Array = _auto_wire_device(instance_id, module_name)
		await _rebuild_view()
		_arrive_face_up(instance_id, module_name)
		_apply()
		_commit_edit("add %s" % instance_id)
		if not rewired.is_empty():
			_say("added %s — wired %s" % [instance_id, ", ".join(rewired)])
		return instance_id

	var terminals := _terminal_types()
	var result := ModuleAuthor.from_patch(patch, parsed, module_name, terminals)
	if not result.ok():
		_say(result.error)
		return ""
	_begin_edit()
	patch = result.patch
	for node in patch.get("nodes", []):
		if str(node["id"]) == result.instance_id:
			node["position"] = {"x": at_position.x, "y": at_position.y}
	# Descriptors before wiring: the auto-wire reads the new definition's ports from
	# the registry, and the registry has not met this definition yet.
	_synthesize_module_descriptors()
	var wired: Array = _auto_wire_device(result.instance_id, result.module_name)
	await _rebuild_view()
	_arrive_face_up(result.instance_id, result.module_name)
	_apply()
	_commit_edit("add %s" % result.instance_id)
	if not wired.is_empty():
		_say("added %s — wired %s" % [result.instance_id, ", ".join(wired)])
	return result.instance_id


## A fresh device arrives face up: a device is for playing, and the panel is the
## playing side — the wiring underneath is what the flip is for, the reverse of a
## node's chip. A module exporting nothing stays a node, because an empty plate
## says less than the node's ports do.
func _arrive_face_up(instance_id: String, module_name: String) -> void:
	var exports: Array = registry.get("module:%s" % module_name, {}).get("parameters", [])
	if exports.is_empty():
		return
	flipped_nodes[instance_id] = true
	_apply_flips()


func _add_node(type_name: String, at_position: Vector2) -> String:
	_begin_edit()
	var descriptor: Dictionary = registry.get(type_name, {})

	# A seam is filed under a key that says which host it is — "seam:Input/note" — because
	# that is what decides its shape. The document says it the other way round, as a type
	# and a binding, and the document is the version a person reads.
	var written := type_name
	var host := ""
	if type_name.begins_with("seam:"):
		var parts := type_name.substr(5).split("/")
		written = parts[0]
		host = parts[1] if parts.size() > 1 else ""

	# Named for the host rather than for the type: a patch usually has one of each, and
	# "note" and "stereo" are what the cables coming out of them are about. "input2" would
	# be two guesses away from meaning anything.
	var base: String = (host if host != "" else written).to_snake_case()

	# Inside an open module's frame, the node is part of that module.
	#
	# Membership is the id prefix — ModuleAuthor.close_module folds in exactly the nodes
	# called "<module>.something" — so joining a module *is* being named after it. That is
	# the whole reason an open module needs no extra state: what belongs to it is written in
	# the document, in the same place a reader would look.
	var joining: String = graph_edit.group_at(at_position) if graph_edit != null else ""
	if joining != "":
		base = "%s.%s" % [joining, base]
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

	var added := {
		"id": node_id,
		"type": written,
		"parameters": parameters,
		"position": {
			"x": snappedf(at_position.x, GRID),
			"y": snappedf(at_position.y, GRID),
		},
	}
	if host != "":
		# One host, one port: adding a second keyboard input would leave two nodes claiming
		# the same machine and the loader taking the first. The new one arrives unplugged,
		# which is a state that now means something — drag the jack over when you want it.
		for node in patch.get("nodes", []):
			if str(node.get("host", "")) == host:
				host = ""
				break
	if host != "":
		added["host"] = host
	patch["nodes"].append(added)
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


## The node types that may not live inside a module: the registry's own Terminals, plus
## the two spellings of a seam.
##
## A seam bound to a host *is* a terminal — that is the whole of what the host binding
## means — but its type is "Input", which no registry entry claims. Asking the registry
## alone let a keyboard be collapsed into a module, which is the one thing the rule about
## terminals exists to stop: two instances would both be listening to it.
func _terminal_types() -> Array:
	var terminals: Array = ["Input", "Output"]
	for type_name in registry:
		if str(registry[type_name].get("category", "")) == "Terminals":
			terminals.append(type_name)
	return terminals


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
	var terminals := _terminal_types()
	var picked: Array = []
	var result := ModuleAuthor.collapse(patch, selected, terminals, picked)
	if not result.ok():
		_say(result.error)
		return
	_begin_edit()
	patch = result.patch
	_synthesize_module_descriptors()
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
	var terminals := _terminal_types()
	var made := ModuleAuthor.collapse(patch, chosen, terminals, [])
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
	var was: String = engine.flatten_patch(JSON.stringify(patch, "  "))
	_begin_edit()
	patch = shut.patch
	_synthesize_module_descriptors()
	await _rebuild_view()
	_apply(was)
	_commit_edit("close %s" % module_name)
	_say("'%s' is one node again" % module_name)


## Opens a module instance so its parts are on the canvas.
func _open_module(instance_id: String) -> void:
	var opened := ModuleAuthor.expand(patch, instance_id)
	if not opened.ok():
		_say(opened.error)
		return
	# Taken before the document changes, so _apply can check the claim rather than take it.
	var was: String = engine.flatten_patch(JSON.stringify(patch, "  "))
	_begin_edit()
	patch = opened.patch
	_synthesize_module_descriptors()
	await _rebuild_view()
	_apply(was)
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


## Put this knob on the file's face, or take it off.
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
	# The default becomes theirs the moment they touch it.
	#
	# A file with no `controls` shows every knob it has — see PatchFace.derived. Adding one
	# knob to that would replace sixty with one, which is not what anybody putting a knob on
	# a panel means. So the first deliberate edit writes down what was already on screen and
	# adds to it; from then on the panel is the file's own and this never fires again.
	if controls.is_empty():
		controls = PatchFace.default_controls(patch, registry)
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


## The dock's jacks, and the cables from them into the graph.
##
## Rebuilt from the document each time it changes, and the cable geometry refreshed every
## frame the graph is visible, because both ends move: the graph scrolls and zooms under
## one, and the dock's own layout shifts the other whenever the window resizes.
func _refresh_seam_dock() -> void:
	if note_jacks == null:
		return
	# One jack per device, not per signal. The keyboard is a thing you plug in, and it
	# arrives at a port whole — which is also why an Input port carries whatever its host
	# carries rather than one signal at a time.
	#
	# Per device rather than per binding, which is the difference that makes the jacks
	# draggable. A jack drawn only where a binding exists would vanish the moment you
	# unplugged it, leaving nothing to plug back in; the keyboard is on the machine whether
	# or not this patch is listening to it. So the row is the devices, and each one says
	# which port it currently drives, or "" for none.
	var has_input := false
	var has_output := false
	var plugged := {}
	for node in patch.get("nodes", []):
		var type_name := str(node.get("type", ""))
		if type_name != "Input" and type_name != "Output":
			continue
		has_input = has_input or type_name == "Input"
		has_output = has_output or type_name == "Output"
		var host := str(node.get("host", ""))
		if host != "" and not plugged.has(host):
			plugged[host] = str(node["id"])
	var driving: Array = []
	var listening: Array = []
	# "Audio in" appears only where it is used. A keyboard is worth a permanent socket
	# because every patch with an input might want one; an audio input is a thing you have
	# deliberately built for, and an empty jack for it on every patch is furniture.
	for device: Array in [["note", "Keyboard", "note", has_input],
			["audio", "Audio in", "audio", plugged.has("audio")],
			["stereo", "Speakers", "audio", has_output]]:
		if not bool(device[3]):
			continue
		var socket := {"node": str(plugged.get(device[0], "")), "port": Seams.HOST_PORT,
			"host": str(device[0]), "label": str(device[1]), "type": str(device[2])}
		if str(device[0]) == "stereo":
			listening.append(socket)
		else:
			driving.append(socket)
	note_jacks.ports = driving
	output_jacks.ports = listening
	note_jacks.update_minimum_size()
	output_jacks.update_minimum_size()
	note_jacks.queue_redraw()
	output_jacks.queue_redraw()
	_refresh_seam_cables()


## Where each dock cable runs, in viewport space: from the device's jack to the host side
## of the port it drives.
##
## Not through `connections` — the cable is not in the document. Which port a device drives
## is the port's own host binding, so the cable is drawn from that rather than stored, and
## there is nothing to keep in step.
func _refresh_seam_cables() -> void:
	if seam_cables == null or graph_edit == null:
		return
	seam_cables.size = get_viewport().get_visible_rect().size
	seam_cables.position = Vector2.ZERO
	var runs: Array = []
	if graph_edit.is_visible_in_tree():
		var rect: Rect2 = graph_edit.get_global_rect()
		seam_cables.window = rect
		var scale: float = graph_edit.zoom if graph_edit.zoom > 0.0 else 1.0
		for jacks in [note_jacks, output_jacks]:
			if jacks == null:
				continue
			for socket: Dictionary in jacks.ports:
				# A device plugged into nothing has no cable, and its jack stays on the
				# dock waiting to be plugged into something.
				if str(socket["node"]) == "":
					continue
				var from = jacks.socket_centre(str(socket["port"]), str(socket["node"]))
				var widget: GraphNode = widgets.get(str(socket["node"]))
				# Not the hidden ones: a flipped case hides its nodes, and a hidden
				# GraphNode has no port cache to ask — every frame asked anyway, and the
				# console filled with index errors. No cable runs to what cannot be seen.
				if from == null or widget == null or not widget.visible:
					continue
				var driven: bool = str(socket["type"]) != "audio" 					or jacks == note_jacks
				var index := _input_port_index(str(socket["node"]), Seams.HOST_PORT) 					if driven else _output_port_index(str(socket["node"]), Seams.HOST_PORT)
				if index < 0:
					continue
				var spot: Vector2 = widget.get_input_port_position(index) if driven 					else widget.get_output_port_position(index)
				var landing: Vector2 = rect.position 					+ (widget.position_offset + spot) * scale - graph_edit.scroll_offset
				runs.append([from, landing,
					TYPE_COLOURS.get(str(socket["type"]), INK)])
		# A turned device keeps its wires. The document's cables to a flipped
		# instance have no widget to land on — the flip took it — so they run to
		# the panel instead: into its IN plate, out of its OUT plate. Without this
		# a fresh device played while its panel sat looking unplugged, which on an
		# instrument reads as a lie.
		for connection in patch.get("connections", []):
			# Not the one in the user's hand: its stand-in would be drawn plugged
			# in while the plug is visibly out.
			if dragging_face_socket.has("rewire") \
					and _same_connection(connection, dragging_face_socket["rewire"]):
				continue
			var from_id := str(connection["from"]["node"])
			var to_id := str(connection["to"]["node"])
			if not flipped_nodes.has(from_id) and not flipped_nodes.has(to_id):
				continue
			var start: Variant = _stub_cable_end(from_id,
				str(connection["from"]["port"]), true, rect, scale)
			var finish: Variant = _stub_cable_end(to_id,
				str(connection["to"]["port"]), false, rect, scale)
			if start == null or finish == null:
				continue
			var flavour := ""
			for port in _port_list(from_id, "outputs"):
				if str(port["name"]) == str(connection["from"]["port"]):
					flavour = str(port.get("type", ""))
			runs.append([start, finish, TYPE_COLOURS.get(flavour, INK)])
	else:
		seam_cables.window = Rect2()
	seam_cables.runs = runs
	seam_cables.live = _live_cable()
	seam_cables.queue_redraw()


## Where a stand-in cable meets one end of a document connection, in viewport space —
## or null when that end has nothing to show. A flipped instance answers with its
## panel's port plate (the IN plate for cables arriving, OUT for cables leaving,
## falling back to the mount's own edge when the face has no plates); an ordinary
## node answers with the port itself, exactly where the native cable would end.
func _stub_cable_end(node_id: String, port: String, is_output: bool,
		rect: Rect2, scale: float) -> Variant:
	if flipped_nodes.has(node_id):
		var mount := module_mounts.get(node_id, null) as Control
		if mount == null or not mount.visible:
			return null
		# The named socket itself, when the face has one: the wire into "gate" meets
		# the jack labelled gate, not the middle of the plate. The plate centre is
		# only the fallback for a face without that jack.
		if mount.has_method("socket_centre"):
			var jack: Variant = mount.socket_centre(port, is_output)
			if jack != null:
				return jack
		var plate := mount.get_node_or_null(
			"Case/Rack/Rail/" + ("PortsOut" if is_output else "PortsIn")) as Control
		if plate != null:
			return plate.get_global_rect().get_center()
		var edge := mount.get_global_rect()
		return Vector2(edge.end.x if is_output else edge.position.x,
			edge.get_center().y)
	var widget: GraphNode = widgets.get(node_id, null)
	if widget == null or not widget.visible:
		return null
	var index := _output_port_index(node_id, port) if is_output \
		else _input_port_index(node_id, port)
	if index < 0:
		return null
	var spot: Vector2 = widget.get_output_port_position(index) if is_output \
		else widget.get_input_port_position(index)
	return rect.position + (widget.position_offset + spot) * scale \
		- graph_edit.scroll_offset


## ---------------------------------------------------------------------------------
## Plugging the machine in
##
## Which port a device drives is the port's own host binding, so dragging a jack is not a
## cable edit — it is moving that binding from one port to another, or off every port. The
## second is why patch-io lets a top-level port be unbound: a keyboard you cannot unplug is
## a keyboard soldered on, and the gesture would only ever be a swap.
## ---------------------------------------------------------------------------------

## A cable in hand from a mounted face's plate socket: which instance port it is,
## which way it faces, and where its fixed end sits. Session state, like a jack drag.
var dragging_face_socket: Dictionary = {}


func _on_face_socket_grabbed(mount: Control, socket: Dictionary) -> void:
	for key in module_mounts:
		if module_mounts[key] != mount or not flipped_nodes.has(str(key)):
			continue
		var instance := str(key)
		var port := str(socket["port"])
		var output := bool(socket["output"])
		# A wired socket gives up its plug: the far end stays where it is, the
		# freed end follows the hand — re-plugged somewhere compatible, or dropped
		# on the floor, which is what unplugging is. An unwired socket starts a
		# fresh cable, as before.
		for connection in patch.get("connections", []):
			var mine: Dictionary = connection["from"] if output else connection["to"]
			if str(mine.get("node", "")) != instance or str(mine.get("port", "")) != port:
				continue
			# The quick yank: a double tap on a wired jack pulls the plug and drops
			# it on the floor in one gesture, no drag to carry through.
			if bool(socket.get("double", false)):
				_unplug_face_socket.call_deferred(connection.duplicate(true),
					instance, port)
				return
			var far: Dictionary = connection["to"] if output else connection["from"]
			var anchor: Variant = _stub_cable_end(str(far["node"]), str(far["port"]),
				not output, graph_edit.get_global_rect(), graph_edit.zoom)
			if anchor == null:
				anchor = socket["centre"]
			dragging_face_socket = {"instance": instance, "port": port,
				"output": output, "from": anchor as Vector2,
				"rewire": connection.duplicate(true)}
			graph_edit.queue_redraw()
			return
		dragging_face_socket = {"instance": instance, "port": port,
			"output": output, "from": socket["centre"] as Vector2}
		return


## Takes one cable out of the document: the floor drop and the double-tap yank both
## end here, one edit, one undo step.
func _unplug_face_socket(connection: Dictionary, instance: String, port: String) -> void:
	_begin_edit()
	for index in patch["connections"].size():
		if _same_connection(patch["connections"][index], connection):
			patch["connections"].remove_at(index)
			break
	await _rebuild_view()
	_apply()
	_commit_edit("disconnect")
	_say("unplugged %s.%s" % [instance, port])


## Whether two document cables are the same cable, field by field — Dictionary
## equality is not a thing to lean on for this.
func _same_connection(a: Dictionary, b: Dictionary) -> bool:
	return str(a["from"]["node"]) == str(b["from"]["node"]) \
		and str(a["from"]["port"]) == str(b["from"]["port"]) \
		and str(a["to"]["node"]) == str(b["to"]["node"]) \
		and str(a["to"]["port"]) == str(b["to"]["port"])


## The connectable point under the viewport position, of the wanted kind: a plate
## socket on any turned device first — they sit above the canvas — then a node
## port. {node, port} in document terms, or {} for the floor.
func _patch_point_at(at: Vector2, wants_input: bool) -> Dictionary:
	for key in flipped_nodes:
		var mount := module_mounts.get(str(key), null) as Control
		if mount == null or not mount.visible or not mount.has_method("socket_at"):
			continue
		var socket: Dictionary = mount.socket_at(at)
		if socket.is_empty():
			continue
		# An IN-plate socket is an input of the instance; an OUT-plate socket is an
		# output. The wrong kind under the pointer is a miss, not a fallthrough.
		if bool(socket["output"]) == wants_input:
			return {}
		return {"node": str(key), "port": str(socket["port"])}
	var landed: Dictionary = graph_edit.port_at(at - graph_edit.get_global_rect().position)
	if landed.is_empty():
		return {}
	var target_id: String = ids.get(landed["widget"], "")
	if target_id == "":
		return {}
	var side_wanted := "left" if wants_input else "right"
	if str(landed["side"]) != side_wanted:
		return {}
	var ports := _port_list(target_id, "inputs" if wants_input else "outputs")
	if int(landed["index"]) >= ports.size():
		return {}
	return {"node": target_id, "port": str(ports[int(landed["index"])]["name"])}


## The release that ends a socket drag. A fresh cable plugs the port under the
## pointer into the instance; a plug pulled from a wired socket re-plugs where it
## lands, its far end never having moved — and the floor unplugs it for good,
## which is what letting go of a cable means.
func _drop_face_socket(at: Vector2) -> void:
	var grabbed := dragging_face_socket
	dragging_face_socket = {}
	seam_cables.live = []
	seam_cables.queue_redraw()
	graph_edit.queue_redraw()
	var rewiring: bool = grabbed.has("rewire")
	# What the hand holds decides what it fits. A fresh cable from a socket reaches
	# for the opposite side; a plug pulled out of a socket fits sockets of the same
	# kind it came from.
	var wants_input: bool = not bool(grabbed["output"]) if rewiring \
		else bool(grabbed["output"])
	var landed := _patch_point_at(at, wants_input)
	if landed.is_empty():
		if rewiring:
			await _unplug_face_socket(grabbed["rewire"],
				str(grabbed["instance"]), str(grabbed["port"]))
		return
	var connection: Dictionary
	if rewiring:
		var old: Dictionary = grabbed["rewire"]
		if wants_input:
			connection = {"from": (old["from"] as Dictionary).duplicate(true),
				"to": {"node": str(landed["node"]), "port": str(landed["port"])}}
		else:
			connection = {"from": {"node": str(landed["node"]),
					"port": str(landed["port"])},
				"to": (old["to"] as Dictionary).duplicate(true)}
		if _same_connection(connection, old):
			return
	elif bool(grabbed["output"]):
		connection = {"from": {"node": str(grabbed["instance"]),
				"port": str(grabbed["port"])},
			"to": {"node": str(landed["node"]), "port": str(landed["port"])}}
	else:
		connection = {"from": {"node": str(landed["node"]),
				"port": str(landed["port"])},
			"to": {"node": str(grabbed["instance"]), "port": str(grabbed["port"])}}
	for wire in patch["connections"]:
		if _same_connection(wire, connection):
			return
	_begin_edit()
	if rewiring:
		for index in patch["connections"].size():
			if _same_connection(patch["connections"][index], grabbed["rewire"]):
				patch["connections"].remove_at(index)
				break
	patch["connections"].append(connection)
	await _rebuild_view()
	_apply()
	_commit_edit("reconnect" if rewiring else "connect")
	_say("connected %s.%s → %s.%s" % [str(connection["from"]["node"]),
		str(connection["from"]["port"]), str(connection["to"]["node"]),
		str(connection["to"]["port"])])


## The release that ends a jack drag, wherever it happens.
##
## Here rather than on the Jacks control, because the mouse leaves that control the instant
## the drag begins and Godot delivers the button-up to whatever is under the cursor. `_input`
## sees it first, which is the same trick the wand uses on knobs.
func _input(event: InputEvent) -> void:
	if not dragging_face_socket.is_empty():
		var pull := event as InputEventMouseMotion
		if pull != null:
			seam_cables.live = [dragging_face_socket["from"], pull.position,
				TYPE_COLOURS.get("audio" if bool(dragging_face_socket["output"]) \
					else "control", INK)]
			seam_cables.queue_redraw()
			return
		var let_go := event as InputEventMouseButton
		if let_go != null and let_go.button_index == MOUSE_BUTTON_LEFT \
				and not let_go.pressed:
			# Deferred because the drop awaits a rebuild, and an engine virtual is
			# not a place a coroutine can suspend.
			_drop_face_socket.call_deferred(let_go.position)
			get_viewport().set_input_as_handled()
		return
	if dragging_jack.is_empty():
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT \
		and not event.pressed:
		_drop_jack((event as InputEventMouseButton).position)
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed \
		and (event as InputEventKey).keycode == KEY_ESCAPE:
		# Put it back. A drag you can't call off is a drag you hesitate to start.
		var was := dragging_jack
		dragging_jack = {}
		for jacks in [note_jacks, output_jacks]:
			if jacks != null:
				jacks.release()
		_refresh_seam_cables()
		if not was.is_empty():
			get_viewport().set_input_as_handled()


## The dock jack the user picked up. Nothing is written yet: a press is a question about
## where this is going, and the answer arrives on release.
func _on_jack_grabbed(socket: Dictionary) -> void:
	dragging_jack = socket
	_refresh_seam_cables()


## The port node under a point that would take this host, or "" for none.
##
## The whole node rather than its host jack alone. A jack is seven pixels across and this
## is a drag across the window; asking somebody to land on the socket exactly would make a
## gesture out of a test of aim. There is one host jack per port, so the node is unambiguous.
func _port_under(point: Vector2, host: String) -> String:
	if graph_edit == null or not graph_edit.is_visible_in_tree():
		return ""
	if not graph_edit.get_global_rect().has_point(point):
		return ""
	var wanted := "Output" if host == "stereo" else "Input"
	for node in patch.get("nodes", []):
		if str(node.get("type", "")) != wanted:
			continue
		var widget: GraphNode = widgets.get(str(node["id"]))
		if widget != null and widget.get_global_rect().has_point(point):
			return str(node["id"])
	return ""


## The cable in the user's hand: from its device's jack to the cursor, in the signal's own
## colour over a port that will take it and grey elsewhere, so "will this land" is answered
## while the mouse is still down rather than after it comes up.
func _live_cable() -> Array:
	if dragging_jack.is_empty() or seam_cables == null:
		return []
	var jacks = output_jacks if str(dragging_jack["host"]) == "stereo" else note_jacks
	if jacks == null:
		return []
	var from = jacks.socket_centre(Seams.HOST_PORT, str(dragging_jack["node"]))
	if from == null:
		return []
	var cursor := get_viewport().get_mouse_position()
	var landing := _port_under(cursor, str(dragging_jack["host"]))
	var colour: Color = TYPE_COLOURS.get(str(dragging_jack["type"]), INK) if landing != "" \
		else Color(INK, 0.30)
	return [from, cursor, colour]


## Moves a device's binding to the port it was dropped on, or off every port when it was
## dropped nowhere.
func _drop_jack(point: Vector2) -> void:
	var socket := dragging_jack
	dragging_jack = {}
	for jacks in [note_jacks, output_jacks]:
		if jacks != null:
			jacks.release()
	if socket.is_empty():
		return
	var host := str(socket["host"])
	var landing := _port_under(point, host)
	if landing == str(socket["node"]):
		_refresh_seam_cables()
		return  # back where it started, which is not an edit

	_begin_edit()
	for node in patch.get("nodes", []):
		var type_name := str(node.get("type", ""))
		if type_name != "Input" and type_name != "Output":
			continue
		if str(node["id"]) == landing:
			# One host per port. Plugging the keyboard into a port that was taking audio
			# unplugs the audio, the way one socket takes one plug.
			node["host"] = host
		elif str(node.get("host", "")) == host:
			node.erase("host")
	_commit_edit("Plug in %s" % str(socket.get("label", host)))
	# The graph itself changed shape — a port that was a terminal is now a socket, or the
	# other way round — so this is a rebuild rather than a repaint.
	_rebuild_and_apply()


## The node the instrument comes out of, or "" for a patch that has no output yet.
func _output_node() -> String:
	for node in patch.get("nodes", []):
		# The seam's own key, or the terminal's for a patch written the older way: what
		# this wants to know is which node the sound leaves through.
		if Seams.terminal_for(node) == "StereoOutput" 				or str(node.get("type", "")) == "StereoOutput":
			return str(node["id"])
	return ""


## Points the volume knob at whatever this patch calls its output, and hides the pair
## when there is nothing to turn down. A knob wired to nothing is worse than no knob.
func _refresh_master() -> void:
	if master_knob == null:
		return
	var node_id := _output_node()
	var descriptor := _parameter_descriptor(node_id, "level") if node_id != "" else {}
	var present := node_id != "" and not descriptor.is_empty()
	master_knob.visible = present
	master_mute.visible = present
	master_label.visible = present
	if not present:
		return
	master_knob.node_id = node_id
	master_knob.descriptor = descriptor
	master_knob.set_value_silently(_value_of(node_id, "level",
		float(descriptor.get("default", 0.8))))
	# Re-asserted after every apply, because loading the patch into the engine puts the
	# stored level back — a mute that quietly lifted the first time anybody moved a node
	# would be a mute nobody could trust.
	if muted and engine != null and engine.is_loaded():
		engine.set_parameter(node_id, "level", 0.0)


func _value_of(node_id: String, parameter: String, fallback: float) -> float:
	for node in patch.get("nodes", []):
		if str(node["id"]) == node_id:
			return float(node.get("parameters", {}).get(parameter, fallback))
	return fallback


## Mute, which is the one control here that is not an edit. See _build_keyboard_bar.
func _set_muted(quiet: bool) -> void:
	muted = quiet
	var node_id := _output_node()
	if node_id == "" or engine == null or not engine.is_loaded():
		return
	engine.set_parameter(node_id, "level",
		0.0 if quiet else _value_of(node_id, "level", 0.8))
	_say("output muted" if quiet else "output back on")


## The panel shows one face: the selected module's, or the file's.
##
## Which is decided here rather than by the two controls, so exactly one of them is ever
## visible and neither has to know the other exists. The heading changes with it, because a
## panel labelled "Panel" that is sometimes the file's and sometimes a module's is a panel
## you have to click something to identify.
func _refresh_face() -> void:
	if patch_face == null:
		return
	var showing := ""
	if patch_face != null:
		# What the file's panel offers follows the selection, which is the whole gesture:
		# select a node, the knobs of its that are not on the panel appear under it, drag
		# one up. The same offer a module's face makes, at the file's scale.
		patch_face.offer_node = str(inspecting.get("node", ""))
	if module_face != null:
		module_face.patch = patch
		module_face.registry = registry
		module_face.rack = rack
		module_face.node_id = str(inspecting.get("node", ""))
		# Inside a container, the panel is that container's face. The graph is the inside
		# of the device and the panel is what a player holds, and drilling into a module
		# turns both at once — the graph shows its parts, the panel its knobs. Selecting
		# an instance still wins, because pointing at a thing is more specific than
		# standing inside one.
		module_face.opened_module = ""
		if module_face.module_name() == "" and graph_edit != null:
			for open_name in graph_edit.groups:
				module_face.opened_module = str(open_name)
				break
		showing = module_face.module_name()
		module_face.visible = showing != ""
		if module_face.visible:
			module_face.rebuild()
	patch_face.visible = showing == ""
	if patch_face.visible:
		patch_face.patch = patch
		patch_face.registry = registry
		patch_face.rack = rack
		patch_face.title = _instrument_name()
		patch_face.rebuild()
	# The turned-over container shows the same face at full size, and it follows the
	# document the same way — one face, two mountings, never two states.
	if big_face != null and big_face.visible:
		big_face.patch = patch
		big_face.registry = registry
		big_face.rack = rack
		big_face.title = _instrument_name()
		big_face.rebuild()
	if graph_edit != null:
		# The same name on both boundaries. The graph's case and the panel's are one
		# container drawn twice — as wiring on one side, as knobs on the other — and a
		# container whose two faces disagreed about its name would be two containers.
		graph_edit.case_title = _instrument_name()
	if face_heading != null:
		# Whose face this is — but only when it is a module's. The file's own name is on
		# the case now, printed on the thing it names rather than floating above it, so a
		# heading here as well would be the same word twice in adjacent rows.
		face_heading.text = showing
		face_heading.visible = showing != ""


## What this file calls itself, for the top of its panel.
##
## The document's own metadata name first — that is the name the *patch* claims, and an
## imported DX7 voice carries the name the synth shipped with ("ALGO 01"), which is worth
## more than the path it happens to be saved at. The file name is the fallback, without
## its extension: ".json" is a fact about storage, not about the instrument.
func _instrument_name() -> String:
	var named := str(patch.get("metadata", {}).get("name", "")).strip_edges()
	if named != "":
		return named
	if document_name == "untitled":
		return ""
	return document_name.get_basename()


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


## A ghost jack was clicked: the inner port becomes one of the module's own.
##
## The additive half of what the Builder's port list did, and the only half the wand offers
## — declaring a port is safe, since nothing can yet be plugged into a port that did not
## exist, while *un*declaring one strands whatever is plugged into it. That is an edit worth
## a considered surface rather than a click, and it does not have one yet. See task #61.
func _on_ghost_port_picked(widget_name: String, offer: Dictionary) -> void:
	var node_id: String = ids.get(widget_name, "")
	if node_id == "" or offer.is_empty():
		return
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
	# The inner port's own name where it is free, qualified by its node where it is not —
	# the same rule the export names follow, for the same reason.
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


## A knob was dragged into a new place on a module's face.
##
## It lands on the *definition*, so every instance of that module wears it — which is the
## right answer and worth saying out loud, because the thing being dragged is one instance
## and the thing being edited is what all of them are.
##
## Any labels already on the panel are kept. Moving a knob is not renaming it, and the two
## are separate fields precisely so that one gesture cannot quietly do the other.
func _on_face_rearranged(rows: Array, added: Dictionary = {}) -> void:
	var node_id := str(inspecting.get("node", ""))
	var module_name := _module_of(node_id)
	var definitions: Dictionary = patch.get("modules", {})
	if module_name == "" or not definitions.has(module_name):
		return
	_begin_edit()
	var definition: Dictionary = definitions[module_name]

	# A ghost dragged onto the face was never exported, so it becomes an export on the way
	# in — one edit, because "put this knob on the module" is one thought. The face names it
	# by where it came from; the export name is chosen here, where what is already taken is
	# known, and swapped into the rows so the panel names the binding and not the ghost.
	var gained := ""
	if not added.is_empty() and str(added.get("node", "")) != "":
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


## A knob was dragged off a module's face.
##
## Off the face, still exported. The panel is presentation and the surface is the contract:
## a control or an automation lane pointing at that export goes on working, and the module
## goes on being able to do what it could do. Taking the *export* away is the destructive
## edit, and it is not this gesture — see task #61.
func _on_face_knob_removed(export_name: String) -> void:
	var node_id := str(inspecting.get("node", ""))
	var module_name := _module_of(node_id)
	var definitions: Dictionary = patch.get("modules", {})
	if module_name == "" or not definitions.has(module_name):
		return
	var definition: Dictionary = definitions[module_name]
	# From the rows the face is actually showing, which for a module that has never been
	# arranged is the wrap on screen rather than an empty panel. Taking a knob off a face
	# nobody has arranged has to write down the rest of it or the removal would read as
	# "clear the panel".
	var rows: Array = ModuleFace.moved(module_face.face_rows(), export_name,
		{"remove": true})
	_begin_edit()
	var panel: Dictionary = (definition.get("panel", {}) as Dictionary).duplicate(true)
	panel["rows"] = rows
	definition["panel"] = panel
	_synthesize_module_descriptors()
	await _rebuild_view()
	_apply()
	_commit_edit("take %s off %s's face" % [export_name, module_name])
	_say("'%s' is off %s's face, and still exported" % [export_name, module_name])


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


## The module a node is an instance of, or "".
func _module_of(node_id: String) -> String:
	for node in patch.get("nodes", []):
		if str(node["id"]) == node_id:
			return str(node.get("module", ""))
	return ""


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
## Applies the document to the engine, unless the engine would build the same graph twice.
##
## `same_sound` is the caller saying "this edit was notation" — opening a module, closing
## one — and it is checked rather than believed. The engine flattens both documents and the
## two fingerprints are compared; only an exact match skips the reload. A reload empties
## every delay line and retriggers every oscillator, so peeking inside a reverb while it
## rings used to cut the tail, and there was never any reason for it: expansion and collapse
## are the same graph said two ways, which is the claim the whole modules design rests on
## and which ctest verifies byte-identically across a hundred and sixty patches.
##
## Diagnostics still run either way. Skipping the reload must not skip finding out that the
## document is broken.
func _apply(same_sound_as: String = "") -> void:
	if suppress_reload:
		return
	_capture_positions()
	var text := JSON.stringify(patch, "  ")

	if same_sound_as != "":
		var now: String = engine.flatten_patch(text)
		if now != "" and now == same_sound_as:
			var quiet: Variant = JSON.parse_string(engine.validate_patch(text))
			_show_diagnostics(quiet["diagnostics"] if typeof(quiet) == TYPE_DICTIONARY else [])
			_rebuild_level_targets()
			_show_info()
			_refresh_status()
			return

	var report: Variant = JSON.parse_string(engine.validate_patch(text))
	var diagnostics: Array = report["diagnostics"] if typeof(report) == TYPE_DICTIONARY else []
	_show_diagnostics(diagnostics)

	if typeof(report) == TYPE_DICTIONARY and report["ok"]:
		engine.load_patch(text, 48000.0)
		# Loading puts the stored level back, so a mute has to be re-asserted or it lifts
		# the first time anybody moves a node.
		if muted:
			var muted_output := _output_node()
			if muted_output != "":
				engine.set_parameter(muted_output, "level", 0.0)
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
	var terminals := _terminal_types()
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


## A fresh patch: not an empty document, a bare machine. The keyboard and the speakers
## are already on it, because that is the state where adding one device makes sound —
## and because a case with no jacks is a box, not an instrument. Goes through
## _load_text like every other way a document arrives, so it starts clean and saved.
func _new_file() -> void:
	# Keyboard, mixer, speakers: the machine a first device plugs into and makes
	# sound, with room already set for a second and a third — the auto-wire lands
	# fresh devices on the mixer's channels, and the mixer feeds the out. A bare
	# pair of seams was the earlier answer, and it was right until there were two
	# devices with nowhere to meet.
	_load_text(JSON.stringify({
		"schema_version": 1,
		"metadata": {"name": ""},
		"nodes": [
			{"id": "note", "type": "Input", "host": "note", "name": "Keyboard",
				"position": {"x": 0.0, "y": 0.0}},
			{"id": "mix", "type": "Mixer",
				"position": {"x": 1600.0, "y": 0.0}},
			{"id": "out", "type": "Output", "host": "stereo",
				"position": {"x": 2000.0, "y": 0.0}},
		],
		"connections": [
			{"from": {"node": "mix", "port": "out"},
				"to": {"node": "out", "port": "left"}},
			{"from": {"node": "mix", "port": "out"},
				"to": {"node": "out", "port": "right"}},
		],
	}))
	_set_document_name("")


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
	_modernize_stereo_outputs()
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

	# The end of the view row Ctrl+0 and Ctrl+1 begin: fit, real size, and which
	# drawing. A toggle on one key rather than an accelerator per radio item,
	# because the question has two answers and one hand.
	if key.pressed and key.ctrl_pressed and key.keycode == KEY_2:
		_choose_detail_mode(PatchGraph.DetailMode.ADAPTIVE \
			if graph_edit.detail_mode == PatchGraph.DetailMode.ONE_TO_ONE \
			else PatchGraph.DetailMode.ONE_TO_ONE)
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
