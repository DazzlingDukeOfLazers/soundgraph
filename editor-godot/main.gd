extends Control
const PluginPicker := preload("res://plugin_picker.gd")
const PluginWindow := preload("res://plugin_window.gd")

## How much of a plugin's own state a patch will carry, in base64 characters — four
## mebibytes, or about three of the plugin's own bytes for every four of these.
##
## A number with a measurement behind it rather than a feeling: Surge XT's initial patch
## is 50 KB of state, Dexed's is 6 KB, Surge's effects rack 1 KB. Four mebibytes is
## eighty Surges, which leaves room for the wavetable synth nobody here has tested while
## keeping a patch a document somebody can open, read and send to a friend. Raise it when
## a real plugin is measured needing more, not before.
const MAX_PLUGIN_STATE_CHARS := 4 * 1024 * 1024
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
## The Add Node browser.
const NodeBrowser := preload("res://node_browser.gd")
## The generated faceplate finishes, so a panel in the graph is grained like the same
## panel on the rack.
const Faceplate := preload("res://faceplate.gd")
## The edges, the grain and the screws — everything about a faceplate that a stylebox
## cannot draw.
const PanelHardware := preload("res://panel_hardware.gd")

## A panel's own geometry, which is not the editor's.
##
## The editor's node radius is 3 and its padding is set for a dense information view. A
## faceplate is an object with a thickness: too little rounding and it is a sticker, too
## much and it is a bubble. Six, and room around the lettering, is what the reference
## boards are drawn at.
const PANEL_RADIUS := 6
const PANEL_PADDING := 15

## How many parameter cells share a line in a graph node.
## How many knobs sit on a line before the next one starts.
##
## Two. Three was tried, for the Keyboard: three parameters and four outputs put the
## controls in the top half and left the bottom half of a very large orange rectangle
## holding four right-aligned words. Laying them three across did compact the rows — one
## tall row instead of two — and made the module 678px wide doing it, wider than the
## whole column pitch, so it ran straight through the panel beside it. Height was never
## the problem. This module is wide because "0.000 semitones" is wide, and no repacking
## of the same cells fixes that.
const PARAMETERS_PER_LINE := 2
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
const PianoRoll := preload("res://piano_roll.gd")
const RollPitch := preload("res://roll_pitch.gd")
const StepGrid := preload("res://step_grid.gd")
const DeviceBlurbs := preload("res://device_blurbs.gd")
const FeedbackSubmitter := preload("res://feedback_submitter.gd")
const WavImport := preload("res://wav_import.gd")
const MidiImport := preload("res://midi_import.gd")
const Transcribe := preload("res://transcribe.gd")
const ModuleThemes := preload("res://module_themes.gd")
const Schematic := preload("res://schematic.gd")
const SpeakText := preload("res://speak_text.gd")
const ProbeScope := preload("res://probe_scope.gd")

const EXAMPLE_GROUPS := {
	"": "",
	"game": "Game",
	"nodes": "Node",
	"fm": "FM",
	"dx7": "DX7",
	"drums": "808",
	"drums909": "909",
	"drums606": "606",
	"drumssds": "SDS",
	"drumsgated": "Gated",
	"synths": "Synth",
}

## Groups this big become submenus rather than flat entries — a bank has a shape, and
## pouring 128 instruments into the top level buried the eight curated examples.

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
var _plugin_scan: Array = []           # what this machine has, asked once
var _plugin_face: Window = null        # the one plugin panel that is open, if any
var _subwindows_were_embedded := false  # what to put back when that panel closes
# Plugin key -> the plugin's own state, base64, as last captured from the running graph.
# Kept beside the document rather than in it: the plugin's own doing is not an editor
# gesture, so it does not belong on the undo stack, and it must not change the flattened
# fingerprint that decides whether an edit needs a reload at all. It joins the document
# at the two moments that matter — reloading, and saving.
var _plugin_states: Dictionary = {}
# What the graph's own output latency is, in frames. Zero for every patch without a
# hosted plugin in it, which is almost all of them.
var _latency_frames := 0
var widgets: Dictionary = {}           # patch node id -> GraphNode
var ids: Dictionary = {}               # GraphNode.name -> patch node id

var graph_edit: GraphEdit
## The face being picked, in the order it was picked, in exactly the shape
## ModuleAuthor.collapse takes: {"kind", "node", "port"/"parameter"}. Stored against patch
## ids rather than against widgets, because a rebuild throws every widget away and renames
## the ones it makes — picks that survive a rebuild are the whole reason this is not just
## a list of Controls.
## The container turned over: the file's face, full size, in the Graph tab's slot.
## Same class as the side panel's face — one face, two mountings.
var big_face: PatchFace

## One patch, multiple representations. The view switch changes the lens, not the
## object being worked on — that sentence is the whole architecture, and this enum is
## its state. Rack, Graph, Schematic and Face are four drawings of the same patch;
## everything else (Sandbox, Outline) is a different workspace, not a different lens.
enum PatchView { RACK, GRAPH, SCHEMATIC, FACE }
var patch_view: int = PatchView.GRAPH
## Face's interaction state. Edit is a mode of Face, not a fifth view: it decides how
## you touch the faceplates, not which representation you are looking at.
var face_edit_mode := false
## The semantic selection, shared by every lens. A view highlights this module in its
## own vocabulary; none of them owns it.
var selected_module := ""
var rack_scroll: ScrollContainer
var container_of_views: Control
var view_switch: HBoxContainer
var lens_bar: HBoxContainer
var face_mode_switch: HBoxContainer
var _view_buttons: Dictionary = {}
var _face_mode_buttons: Dictionary = {}
## The third way of looking at a patch: not where somebody dragged things, and not the
## instrument, but the graph itself on a grid nobody has moved. See schematic.gd.
var schematic: Schematic
## The clipped region the schematic is mounted in. See where it is built.
var mount_area: Control
var schematic_up := false
## Which open modules are turned over, and the ModuleFace mounted for each. Session
## state, like which side the file's case shows: nothing here is written to the patch.
var flipped_modules := {}
## Closed instance nodes turned over where they stand, keyed by instance id — the
## one-step flip: no need to open a module's wires just to play its panel.
var flipped_nodes := {}

## Where the editor has dived from: one frame per level, holding the host document,
## its history, its name and its unsaved flag. Diving makes the module's definition
## the open document — full editing, full sound, since a definition carries its own
## seams — and climbing writes the edits back into the host as one undo step.
var dive_stack: Array = []
var climb_button: Button

# The piano roll and its transport. The clock lives here with the engine; the roll
# itself only draws and points.
var piano_roll: PianoRoll
var roll_row: HBoxContainer
var roll_scroll: VScrollBar
var roll_pitch: Control
var _roll_scroll_syncing := false
var roll_button: MenuButton
# What was last said, so that asking twice does not mean typing it twice. Deliberately
# not in the document: it is a thing about this session, not about the patch.
var say_text := "hello there, how are you today?"
var roll_play: Button
var roll_capture: Button
var roll_tempo: ValueField
var roll_division: ValueField
var roll_bars_menu: PopupMenu
var midi_dialog: FileDialog
var audio_dialog: FileDialog
var roll_open := false
var roll_playing := false
var _roll_clock := 0.0
var _roll_step := -1
var _roll_sounding: Dictionary = {}
var module_mounts := {}
## Where the face is mounted, in graph coordinates: the case's own corner at the moment
## it was turned over. The graph's camera does the rest.
var face_anchor := Vector2.ZERO

## The file's own face: the knobs somebody plays. See patch_face.gd.
var patch_face: PatchFace
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
var view_zoom_slider: HSlider
var view_zoom_readout: Label
var _zoom_slider_syncing := false
var scope_probe: ProbeScope
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
var keyboard_toggle: MenuButton
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
## "full", "mini" or "hide" — how much room the keys take. Mini keeps them playable
## at half height; hide leaves only the strip, with the way back on the same menu.
var keyboard_mode := "full"
## What is open, shown so "which patch am I looking at" is never a guess.
var document_label: RichTextLabel
var document_name := "untitled"
var diagnostics_list: VBoxContainer
## Round-robin state for the signal glow; see _update_port_levels().
var _level_targets: Array = []
var _level_cursor := 0

var health_label: Label
var diagnostics_heading: Label
var search_popup: PopupPanel
## The Add Node browser. Its own surface, like the rack and the schematic.
var node_browser: NodeBrowser
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

## Every node's parameters as they entered the document, keyed by node id: where a
## knob's double tap goes home to. The 808's kick is tuned to 55 Hz by its author,
## and a double tap that sent it to the oscillator's factory 440 was a reset to the
## wrong origin. Recorded once per node and never overwritten, so twiddling does
## not drag home along; cleared on load and carried across a dive like the history.
var _home_values: Dictionary = {}

## Which page of each bank is showing, keyed "" for the file's own bank and by
## module name for a device's. Held here rather than on the faces because the
## same bank can be open on two mountings — the side panel and a flipped case —
## and two faces disagreeing about the page is how "next" turns to the wrong one.
var preset_pages: Dictionary = {}

## MIDI learn state: the control id waiting for the next CC, or empty.
var _learning: Dictionary = {}

## The CC undo bracket: a hardware sweep is dozens of events with no gesture
## end, so the edit opens on the first and commits after a beat of silence.
var _cc_editing := false
var _cc_commit: Timer = null
var _pending_snapshot: Dictionary = {}
var toolbar: EditorToolbar

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
# The rungs live with the ladder now; these keep every caller's spelling working.
const Rung = EditorToolbar.Rung
const RUNG_COUNT = EditorToolbar.RUNG_COUNT

var toolbar_menu_button: MenuButton
var toolbar_menu_popup: PopupMenu
var toolbar_qr: TextureRect
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

	# Hardware MIDI in: the OS's ports open here, and InputEventMIDI arrives in
	# _input like any other event. Nothing to configure — plug in and play.
	OS.open_midi_inputs()
	_cc_commit = Timer.new()
	_cc_commit.one_shot = true
	_cc_commit.wait_time = 0.6
	_cc_commit.timeout.connect(_commit_cc)
	add_child(_cc_commit)
	var midi_inputs := OS.get_connected_midi_inputs()
	if not midi_inputs.is_empty():
		print("MIDI in: ", ", ".join(midi_inputs))

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
	# A patch carried here from /soundgraph wins over the default example: somebody who
	# pressed "open in the full editor" asked for their patch, and opening First Synth over
	# it would throw away the thing they had just made.
	if not _load_handed_off_patch():
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
	# The map floor is the darkest surface, so the node fills Godot copies from the
	# graph (which are panel-dark) still read against it.
	Design.set_box(editor_theme, "panel", "GraphEditMinimap",
		Design.panel(Design.Surface.CANVAS, Design.RADIUS_PANEL))
	# Godot fills each minimap square with the node's own panel colour, which on an
	# instrument-black theme is a dark square on a dark map — the minimap read as a
	# few floating cables. The border is ours to keep: a bright outline survives the
	# fill being copied, so every module shows as a lit frame wherever it sits.
	var minimap_node := Design.panel(Design.Surface.ACTIVE, 0, 0)
	minimap_node.set_border_width_all(1)
	minimap_node.border_color = Design.INK_SECOND
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

	_scan_examples()
	toolbar = EditorToolbar.new(_examples, _build_description())
	toolbar.is_muted = func() -> bool: return muted
	# Add node opens the browser; Ctrl+Space still opens the search palette. The browser
	# is a shell until its own steps fill it, and retiring a working path in favour of a
	# scaffold would make the editor worse in exchange for a screenshot. See
	# docs/add-node-browser.md — the palette goes when the browser can do its job.
	toolbar.add_node_requested.connect(_open_node_browser)
	toolbar.feedback_requested.connect(_open_feedback)
	toolbar.undo_requested.connect(_undo)
	toolbar.redo_requested.connect(_redo)
	toolbar.example_chosen.connect(_load_example)
	toolbar.file_action.connect(_on_file_menu)
	toolbar.view_action.connect(_on_view_menu)
	toolbar.arrange_action.connect(func(id: int) -> void:
		if id == 0:
			_auto_place()
		elif id == 1:
			_arrange_selection()
		elif id == 2:
			_collapse_selection())
	toolbar.make_module_requested.connect(func() -> void: _begin_module_region())
	toolbar.mute_toggled.connect(func() -> void:
		if master_mute != null:
			master_mute.button_pressed = not muted
		else:
			_set_muted(not muted))
	# The names the rest of this file and the tests already speak.
	toolbar_menu_button = toolbar.toolbar_menu_button
	toolbar_menu_popup = toolbar.toolbar_menu_popup
	_sync_view_menu()
	toolbar_qr = toolbar.toolbar_qr
	transport_dot = toolbar.transport_dot
	message_label = toolbar.message_label
	view_popup = toolbar.view_popup
	arrange_popup = toolbar.arrange_popup
	undo_button = toolbar.undo_button
	redo_button = toolbar.redo_button
	_primary_buttons = toolbar._primary_buttons
	root.add_child(toolbar)

	split = HSplitContainer.new()
	# The split lives inside a plain holder rather than in the column directly, so
	# its children's minimum heights never reach the column's arithmetic. That is the
	# guarantee the keyboard needed: on a short window the canvas and the bench clip
	# inside this holder, and the piano keeps every pixel it asked for — a user who
	# wants the graph taller makes the keyboard mini themselves, from a keyboard they
	# can see. Not knowing there is a keyboard is the one failure this must not have.
	var middle := Control.new()
	middle.size_flags_vertical = Control.SIZE_EXPAND_FILL
	middle.custom_minimum_size.y = Design.scale(120)
	middle.clip_contents = true
	root.add_child(middle)
	split.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	middle.add_child(split)
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
	# Zero: the CordLayer draws every cable as a cord along the same routes, and the
	# native line cannot be layered under it — GraphEdit's internal connection layer
	# renders after regular children, so any native width rides on top of the cord as
	# a tramline stripe. The routes, the picking and the waypoints all still work;
	# only GraphEdit's own drawing stands down.
	graph_edit.connection_lines_thickness = 0.0
	graph_edit.connection_lines_antialiased = true
	# The minimap was a flat grey rectangle sitting over the canvas with no border and
	# no relationship to anything else on screen — it read as a panel that had failed
	# to draw. Smaller, and on the same surface ladder as everything else.
	# Far enough out to see a whole DX7 import as one shape. The default floor was
	# about a quarter scale; adaptive detail is what makes a tenth still readable.
	graph_edit.zoom_min = 0.1
	graph_edit.minimap_enabled = true
	graph_edit.minimap_size = Vector2(220, 136)
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
	# Face edit, beside the zoom controls it shares a bar with: a mode, so a toggle,
	# and it lives on the graph because the graph is where the pointing happens.
	# Face edit and Schematic used to live here, beside the zoom cluster. They are on the
	# case band now, next to Face view: all three answer "how am I looking at this
	# patch", and two of them above the canvas with the third on the case meant the set
	# never read as a set. See _case_chip_rects in patch_graph.gd.
	# Fit, beside the zoom controls: framing is a camera move, so it lives with the
	# camera. It spent time in the toolbar and before that in the Arrange menu; this
	# strip is the first home where its neighbours are also about looking.
	var fit_button := Button.new()
	fit_button.text = "Fit"
	fit_button.tooltip_text = "Zoom and scroll so the whole patch is visible, clear of " \
		+ "the minimap and the zoom controls."
	fit_button.pressed.connect(func() -> void: graph_edit.fit_graph())
	graph_edit.get_menu_hbox().add_child(_defocus(fit_button))
	graph_edit.face_cell_toggled.connect(_on_face_cell_toggled)
	graph_edit.face_port_toggled.connect(_on_face_port_toggled)
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
	# The stored choice, through the same setter the menu uses. The photograph is
	# the default and the setter refuses a no-op, so a fresh install changes
	# nothing. The key retired "graph_detail_mode": that one had ADAPTIVE stamped
	# into existing installs, and a default you cannot reach is not a default.
	graph_edit.set_detail_mode(int(Settings.fetch("graph_detail",
		PatchGraph.DetailMode.ONE_TO_ONE)))
	graph_edit.port_hovered.connect(_on_port_hovered)
	graph_edit.ghost_port_picked.connect(_on_ghost_port_picked)
	graph_edit.region_drawn.connect(_on_region_drawn)
	graph_edit.group_closed.connect(func(name: String) -> void: _close_module(name))
	graph_edit.begin_node_move.connect(func() -> void: _begin_edit())
	graph_edit.end_node_move.connect(func() -> void: _commit_edit("move"))
	# The container's own controls: its band switches which way you are looking at it,
	# and dragging that band moves everything mounted in it.
	graph_edit.case_move_started.connect(func() -> void: _begin_edit())
	# The case chips are gone: view switching lives in one stationary segmented control
	# above the canvas, so changing lenses never means finding a different door in each
	# room. See _set_patch_view.
	graph_edit.group_flip_toggled.connect(func(module_name: String) -> void:
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
	graph_edit.face_rename_requested.connect(_begin_face_rename)
	# The band's DIVE chip names the instance directly; a faceless module's node
	# answers to a double tap on its title. A non-module title dives nowhere,
	# which _dive_into already says by doing nothing.
	graph_edit.face_dive_requested.connect(_dive_into)
	graph_edit.node_dive_requested.connect(func(widget_name: String) -> void:
		_dive_into(ids.get(widget_name, "")))
	# The band's ✕ deletes through the same path the Delete key takes: node,
	# cables, controls and automation together, one undo step.
	graph_edit.face_remove_requested.connect(func(key: String) -> void:
		var widget: GraphNode = widgets.get(key, null)
		if widget == null:
			return
		# Typed to the handler's own signature: a deferred call does not coerce,
		# and a plain Array died at the boundary with the least helpful of errors.
		var doomed: Array[StringName] = [StringName(widget.name)]
		_on_delete_nodes_request.call_deferred(doomed))
	graph_edit.cable_drag_started.connect(func() -> void: _begin_edit())

	# Two views of one document, side by side in tabs rather than as a mode: the graph is
	# the honest picture of signal flow, the rack is the picture a musician already knows
	# how to read. Which one leads at Knobcon is a question to settle by watching people.
	views = TabContainer.new()
	views.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# The breadcrumb rides the tab strip's right edge: the tabs say which view, the
	# path says which document and how deep — one row answers both questions. The
	# label owns only the right half of the strip, so the tabs keep every click
	# that belongs to them.
	document_label = RichTextLabel.new()
	document_label.bbcode_enabled = true
	document_label.fit_content = true
	document_label.scroll_active = false
	document_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	document_label.add_theme_font_size_override("normal_font_size",
		Design.type(Design.SIZE_SECONDARY))
	document_label.add_theme_color_override("default_color", Design.INK_SECOND)
	document_label.clip_contents = true
	document_label.meta_clicked.connect(func(meta: Variant) -> void:
		var level := int(str(meta))
		_climb_levels.call_deferred(dive_stack.size() - level))
	document_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	document_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	# The path and its way back share one row: the breadcrumb names where you are,
	# the climb button is the step home, and both live where the question lives.
	var crumb_row := HBoxContainer.new()
	crumb_row.anchor_left = 0.45
	crumb_row.anchor_right = 1.0
	crumb_row.anchor_top = 0.0
	crumb_row.anchor_bottom = 1.0
	crumb_row.offset_right = -float(Design.scale(Design.SPACE_M))
	crumb_row.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	crumb_row.add_theme_constant_override("separation", Design.SPACE_S)
	# The lens switch: one segmented control, one place, every view. Navigation between
	# representations rather than a row of actions, so it is quiet — the selected
	# segment carries weight and an accent underline, the rest are muted text. Two cues
	# beyond colour (weight and the underline), so the selection survives a monochrome
	# screen and a colour-blind reader.
	view_switch = HBoxContainer.new()
	view_switch.add_theme_constant_override("separation", 0)
	var lens_group := ButtonGroup.new()
	var lens_names := {PatchView.RACK: "Rack", PatchView.GRAPH: "Graph",
		PatchView.SCHEMATIC: "Schematic", PatchView.FACE: "Face"}
	for lens in [PatchView.RACK, PatchView.GRAPH, PatchView.SCHEMATIC, PatchView.FACE]:
		var segment := Button.new()
		segment.text = lens_names[lens]
		segment.toggle_mode = true
		segment.button_group = lens_group
		segment.flat = true
		segment.tooltip_text = "%s — %d" % [lens_names[lens], int(lens) + 1] \
			if lens != PatchView.RACK else "Rack — 1"
		segment.add_theme_font_size_override("font_size",
			Design.type(Design.SIZE_CONTROL))
		segment.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		var chosen := int(lens)
		segment.pressed.connect(func() -> void: _set_patch_view(chosen))
		view_switch.add_child(segment)
		_view_buttons[lens] = segment
	# Face's own mode, visibly subordinate: smaller, quieter, and only present while
	# Face is the lens. View and Edit are how you touch the faceplates, not where you
	# are.
	face_mode_switch = HBoxContainer.new()
	face_mode_switch.add_theme_constant_override("separation", 0)
	face_mode_switch.visible = false
	var mode_group := ButtonGroup.new()
	for mode in ["View", "Edit"]:
		var mode_button := Button.new()
		mode_button.text = mode
		mode_button.toggle_mode = true
		mode_button.button_group = mode_group
		mode_button.flat = true
		mode_button.add_theme_font_size_override("font_size",
			Design.type(Design.SIZE_SECONDARY))
		mode_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		var wants_edit: bool = mode == "Edit"
		mode_button.pressed.connect(func() -> void: _set_face_mode(wants_edit))
		face_mode_switch.add_child(mode_button)
		_face_mode_buttons[mode] = mode_button
	# Its own bar, centred over the canvas inside the Patch tab — not in the breadcrumb
	# strip, which it overflowed straight across the workspace tabs the first time. The
	# tab owns it, so it exists exactly when the Patch workspace does and sits in the
	# same pixel through every lens change, which is the whole point of it.
	lens_bar = HBoxContainer.new()
	# Right-aligned: the canvas's own zoom cluster owns the top-left corner in every
	# graph-camera lens, and a centred bar ran its first segment straight into it. The
	# top-right corner belongs to nobody, in all four lenses.
	lens_bar.alignment = BoxContainer.ALIGNMENT_END
	lens_bar.anchor_left = 0.0
	lens_bar.anchor_right = 1.0
	lens_bar.anchor_top = 0.0
	lens_bar.anchor_bottom = 0.0
	lens_bar.offset_top = float(Design.scale(Design.SPACE_S))
	lens_bar.offset_right = -float(Design.scale(Design.SPACE_M))
	lens_bar.offset_bottom = float(Design.scale(44))
	lens_bar.mouse_filter = Control.MOUSE_FILTER_PASS
	lens_bar.add_theme_constant_override("separation", Design.scale(Design.SPACE_S))
	lens_bar.add_child(view_switch)
	lens_bar.add_child(face_mode_switch)
	# The zoom, as furniture: Ctrl+wheel exists, but a gesture nobody is told about
	# is a feature that does not exist, and the strip beside the tabs is where the
	# eye already is when choosing how to look. One slider serves whichever view is
	# in front — the graph and the rack each keep their own value and range.
	view_zoom_slider = HSlider.new()
	view_zoom_slider.custom_minimum_size = Vector2(Design.scale(110), 0)
	view_zoom_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	view_zoom_slider.step = 0.01
	view_zoom_slider.visible = false
	view_zoom_slider.tooltip_text = "How close you stand to this view. The graph and " \
		+ "the rack each remember their own distance."
	view_zoom_slider.value_changed.connect(_on_view_zoom_slider)
	# Not through _defocus: its 44px hit floor would make this the tallest thing in
	# a strip of tabs and shove the row over the canvas. The strip is the target.
	view_zoom_slider.focus_mode = Control.FOCUS_NONE
	crumb_row.add_child(view_zoom_slider)
	view_zoom_readout = Label.new()
	view_zoom_readout.add_theme_font_override("font", Design.numeric_font())
	view_zoom_readout.add_theme_font_size_override("font_size",
		Design.type(Design.SIZE_SECONDARY))
	view_zoom_readout.add_theme_color_override("font_color", Design.INK_SECOND)
	view_zoom_readout.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	view_zoom_readout.custom_minimum_size.x = Design.scale(44)
	view_zoom_readout.visible = false
	crumb_row.add_child(view_zoom_readout)
	crumb_row.add_child(document_label)
	climb_button = Button.new()
	climb_button.visible = false
	climb_button.add_theme_font_size_override("font_size",
		Design.type(Design.SIZE_SECONDARY))
	climb_button.pressed.connect(_climb_up)
	crumb_row.add_child(_defocus(climb_button))
	views.get_tab_bar().add_child(crumb_row)
	# One tab, one canvas, both sides of the container. The graph already owns zoom,
	# pan and the grid, so the face is a tenant on that canvas rather than a rival
	# view: flipping hides the wiring and mounts the face at the case's own spot, and
	# every camera gesture keeps working because it is the same camera.
	var container_tab := Control.new()
	# Patch, not Graph: this tab holds every representation of the patch — graph, rack,
	# schematic, face — and the segmented switch chooses among them. Sandbox and Outline
	# stay tabs, because they are different workspaces, not different lenses.
	container_tab.name = "Patch"
	# Clipped to the work area.
	#
	# GraphEdit clips its own nodes, but the face and the schematic are tenants of this
	# container rather than children of the graph, and a plain Control does not clip. So
	# a mount wider than the viewport drew straight over the inspector beside it — the
	# schematic's last card sat on top of "point the probe at a wire". Whatever is
	# mounted here is looking at the patch, and the patch's window ends where the panel
	# begins.
	container_tab.clip_contents = true
	graph_edit.name = "Wires"
	graph_edit.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	container_tab.add_child(graph_edit)

	# The region a mount is allowed to occupy: the graph's usable rectangle, which is its
	# own size less the scrollbars and the zoom cluster.
	#
	# Clipping the whole tab was not enough. The tab includes the gutters, so a schematic
	# wider than the view stopped being drawn over the inspector and started disappearing
	# *underneath the scrollbars* instead — still the wrong picture, just a smaller wrong.
	# Sized from usable_rect() every frame, the same rectangle fit_to() frames against, so
	# what arrives fitted stays fitted.
	mount_area = Control.new()
	mount_area.name = "MountArea"
	mount_area.clip_contents = true
	mount_area.mouse_filter = Control.MOUSE_FILTER_IGNORE
	container_tab.add_child(mount_area)

	schematic = Schematic.new()
	schematic.visible = false
	schematic.z_index = 50
	schematic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mount_area.add_child(schematic)

	big_face = PatchFace.new()
	big_face.visible = false
	big_face.z_index = 50
	big_face.reordered.connect(_on_panel_reordered)
	big_face.offered.connect(_toggle_control)
	# The graph's face is the only face now — the side panel's copy is gone, so the
	# whole preset machinery wires here. patch_face stays the name the rest of this
	# file and the tests speak; it simply points at the face on the canvas.
	big_face.preset_applied.connect(
		func(index: int, writes: Array) -> void:
			_apply_preset(index, writes, big_face, ""))
	big_face.preset_saved.connect(
		func(values: Dictionary) -> void:
			_save_preset(values, big_face, ""))
	big_face.morph_started.connect(func() -> void: _begin_edit())
	big_face.preset_morphed.connect(_write_morph)
	big_face.morph_finished.connect(func() -> void: _commit_edit("morph"))
	big_face.preset_renamed.connect(
		func(index: int, wanted: String) -> void:
			_rename_preset(index, wanted, big_face, ""))
	big_face.preset_reordered.connect(
		func(from_index: int, to_index: int) -> void:
			_reorder_preset(from_index, to_index, big_face, ""))
	big_face.preset_deleted.connect(
		func(index: int) -> void:
			_delete_preset(index, big_face, ""))
	patch_face = big_face
	graph_edit.add_child(big_face)

	# The way back, floating over the canvas while the face is up.
	container_of_views = container_tab
	views.add_child(container_tab)

	rack_scroll = ScrollContainer.new()
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
	rack.home_lookup = _knob_home
	rack.learn_requested.connect(_on_learn_requested)
	rack.parameter_changed.connect(_on_rack_parameter_changed)
	rack.edit_started.connect(func() -> void: _begin_edit())
	rack.edit_finished.connect(func(label: String) -> void: _commit_edit(label))
	rack.node_selected.connect(_on_rack_node_selected)
	rack.theme_requested.connect(_on_module_theme_requested)
	# A plain Control between the scroll container and the rack, because a Container
	# resets its children's scale on every layout pass — fit_child_in_rect wipes it —
	# so a zoomed rack that is a direct child snaps back to 1.0 the moment anything
	# breathes. The holder takes the layout; the rack keeps its scale.
	var rack_holder := Control.new()
	rack_holder.mouse_filter = Control.MOUSE_FILTER_PASS
	rack_scroll.add_child(rack_holder)
	rack_holder.add_child(rack)
	rack_holder.resized.connect(rack._relayout)
	# Inside the Patch tab, not a tab of its own. The rack is a representation of the
	# patch, and putting it beside Sandbox made two different kinds of thing look like
	# peers. It sits over the canvas and shows when the switch says RACK.
	rack_scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	rack_scroll.visible = false
	container_tab.add_child(rack_scroll)
	container_tab.add_child(lens_bar)

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
		if patch_view == PatchView.RACK:
			rack.rebuild()
		_sync_view_switch()
		_refresh_view_zoom_slider()
		if sandbox != null and sandbox.is_visible_in_tree():
			sandbox.ensure_sounds_loaded())
	split.add_child(views)

	split.add_child(_build_side_panel())
	_set_side_panel_open(true)
	# Once, at the end of construction: before this the slider has no range, and a
	# range being set fires value_changed — which must not be allowed to zoom the
	# graph to the slider's uninitialised floor.
	_refresh_view_zoom_slider.call_deferred()

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

	_set_keyboard_mode(str(Settings.fetch("keyboard_mode", "full")))
	_set_key_hints(bool(Settings.fetch("keyboard_hints", true)))
	_set_roll_orientation(str(Settings.fetch("roll_orientation", "vertical")))
	for key in Settings.fetch("loved_nodes", []):
		_loved_nodes[str(key)] = true
	feedback_submitter = FeedbackSubmitter.new()
	feedback_submitter.endpoint = FEEDBACK_ENDPOINT
	feedback_submitter.outbox_path = feedback_outbox
	feedback_submitter.finished.connect(_on_feedback_flushed)
	add_child(feedback_submitter)
	# The dock has its own vertical ladder, and the window resizing is its signal —
	# same reasoning as the toolbar's: the dock's own size stops changing exactly
	# when the window gets too short for it.
	get_viewport().size_changed.connect(_fit_keyboard_dock.bind(-1.0))
	_fit_keyboard_dock.call_deferred()
	_refresh_keyboard_range()
	_build_search_popup()
	node_browser = NodeBrowser.new()
	node_browser.ranker = Callable(engine, "search_nodes")
	node_browser.facts = _browser_facts
	node_browser.item_activated.connect(_from_browser)
	add_child(node_browser)

	file_dialog = FileDialog.new()
	file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	file_dialog.add_filter("*.json", "SoundGraph patch")
	file_dialog.file_selected.connect(_on_file_selected)
	add_child(file_dialog)

	midi_dialog = FileDialog.new()
	midi_dialog.access = FileDialog.ACCESS_FILESYSTEM
	# Opening, not saving — which has to be said: a fresh FileDialog is a save
	# dialog, and an importer wearing a Save button reads as a trap.
	midi_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	midi_dialog.add_filter("*.mid,*.midi", "Standard MIDI file")
	midi_dialog.title = "Import MIDI into the piano roll"
	midi_dialog.file_selected.connect(_import_midi_file)
	add_child(midi_dialog)

	audio_dialog = FileDialog.new()
	audio_dialog.access = FileDialog.ACCESS_FILESYSTEM
	audio_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	for filter in Transcribe.FILTERS:
		var halves: PackedStringArray = str(filter).split(" ; ")
		audio_dialog.add_filter(halves[0], halves[1])
	audio_dialog.title = "Transcribe a recording into the piano roll"
	audio_dialog.file_selected.connect(_transcribe_audio_file)
	add_child(audio_dialog)

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


## The ladder itself lives in toolbar.gd; these keep the callers' spelling.
var toolbar_rung: int:
	get:
		return toolbar.toolbar_rung if toolbar != null else 0


func _apply_toolbar_rung(rung: int) -> void:
	toolbar._apply_toolbar_rung(rung)


func _fit_toolbar(width: float = -1.0) -> void:
	toolbar._fit_toolbar(width)


## Which of the zoomable views is in front, or "" when the front view has no zoom.
## Changes the lens. The patch stays where it is; every path in here is "put away what
## the old lens mounted, bring out what the new one draws", and the switch, the camera
## and the selection all follow.
##
## Cameras are per-view and semantic context is shared: the graph, schematic and face
## share one canvas camera by construction, the rack keeps its own zoom and scroll, and
## none of them is forced into another's coordinates. What travels is the selection —
## _reveal_selected asks the destination view to show the same module its own way.
func _set_patch_view(view: int) -> void:
	show_view("Patch")
	patch_view = view
	_sync_view_switch()
	# A short dissolve — same patch, different representation. Content-only and brief,
	# so rapid switching never waits on a spectacle.
	if container_of_views != null:
		container_of_views.modulate.a = 0.55
		create_tween().tween_property(container_of_views, "modulate:a", 1.0, 0.12)
	match view:
		PatchView.RACK:
			if graph_edit.face_edit:
				await _set_face_edit(false)
			await _show_graph()
			graph_edit.visible = false
			rack_scroll.visible = true
			rack.rebuild()
		PatchView.GRAPH:
			rack_scroll.visible = false
			graph_edit.visible = true
			if graph_edit.face_edit:
				await _set_face_edit(false)
			await _show_graph()
		PatchView.SCHEMATIC:
			rack_scroll.visible = false
			graph_edit.visible = true
			await _show_schematic(true)
		PatchView.FACE:
			rack_scroll.visible = false
			graph_edit.visible = true
			if face_edit_mode:
				await _show_graph()
				await _set_face_edit(true)
			else:
				if graph_edit.face_edit:
					await _set_face_edit(false)
				await _flip_container(true)
	_reveal_selected()
	_refresh_view_zoom_slider()


## Face's interaction state. Edit dresses the faceplates by clicking the controls on
## the wiring — the fitting room — and View mounts the finished face. Choosing either
## takes you to Face; they are its modes, not places of their own.
func _set_face_mode(edit: bool) -> void:
	face_edit_mode = edit
	await _set_patch_view(PatchView.FACE)


## The switch always tells the truth about the lens, whoever changed it.
func _sync_view_switch() -> void:
	var on_patch: bool = views != null \
		and views.get_tab_title(views.current_tab) == "Patch"
	if view_switch != null:
		view_switch.visible = on_patch
		for lens in _view_buttons:
			var segment: Button = _view_buttons[lens]
			var selected: bool = int(lens) == patch_view
			segment.set_pressed_no_signal(selected)
			_dress_segment(segment, selected)
	if face_mode_switch != null:
		face_mode_switch.visible = on_patch and patch_view == PatchView.FACE
		for mode in _face_mode_buttons:
			var mode_button: Button = _face_mode_buttons[mode]
			var chosen: bool = (mode == "Edit") == face_edit_mode
			mode_button.set_pressed_no_signal(chosen)
			_dress_segment(mode_button, chosen)


## One strong selected cue and one quiet one: an accent underline and semibold text on
## the chosen segment, muted regular text on the rest. No boxes — four outlined boxes
## is a row of buttons, and this is navigation.
func _dress_segment(segment: Button, selected: bool) -> void:
	segment.add_theme_font_override("font",
		Design.font(Design.WEIGHT_SEMIBOLD if selected else Design.WEIGHT_REGULAR))
	for state in ["font_color", "font_hover_color", "font_pressed_color",
			"font_focus_color"]:
		segment.add_theme_color_override(state,
			Design.INK_BRIGHT if selected else Design.INK_SECOND)
	if selected:
		var underline := StyleBoxFlat.new()
		underline.bg_color = Color(Design.ACCENT, 0.08)
		underline.border_width_bottom = maxi(Design.scale(2), 2)
		underline.border_color = Design.ACCENT
		underline.content_margin_left = Design.scale(Design.SPACE_S)
		underline.content_margin_right = Design.scale(Design.SPACE_S)
		underline.content_margin_top = Design.scale(Design.SPACE_XS)
		underline.content_margin_bottom = Design.scale(Design.SPACE_XS)
		for state in ["normal", "hover", "pressed"]:
			segment.add_theme_stylebox_override(state, underline)
	else:
		for state in ["normal", "hover", "pressed"]:
			segment.remove_theme_stylebox_override(state)


## Shows the shared selection the way the current lens shows anything: the graph
## centres the node, the rack scrolls to the module and marks it, the schematic
## outlines its card. Context travels; camera coordinates do not.
func _reveal_selected() -> void:
	if schematic != null:
		schematic.selected_id = selected_module
		schematic.queue_redraw()
	if selected_module == "":
		return
	match patch_view:
		PatchView.GRAPH:
			if widgets.has(selected_module):
				_focus_node(selected_module)
		PatchView.RACK:
			rack.select(selected_module)
			var module = rack.module_for(selected_module)
			if module != null and rack_scroll != null:
				rack_scroll.scroll_vertical = maxi(0,
					int(module.position.y * rack.view_zoom) - Design.scale(40))


func _zoomable_view() -> String:
	if views == null or views.get_tab_title(views.current_tab) != "Patch":
		return ""
	# The rack has its own camera; the graph, schematic and face share the canvas's.
	return "Rack" if patch_view == PatchView.RACK else "Graph"


## Points the slider at the front view's range and value. Hidden on views with no
## zoom, because a control that does nothing teaches that the whole strip does nothing.
func _refresh_view_zoom_slider() -> void:
	if view_zoom_slider == null:
		return
	# Range setters clamp, and clamping emits value_changed: without the flag,
	# pointing the slider at a view zooms that view to the slider's old floor.
	_zoom_slider_syncing = true
	var which := _zoomable_view()
	view_zoom_slider.visible = which != ""
	view_zoom_readout.visible = which != ""
	if which == "Graph":
		view_zoom_slider.min_value = graph_edit.zoom_min
		view_zoom_slider.max_value = graph_edit.zoom_max
		view_zoom_slider.set_value_no_signal(graph_edit.zoom)
	elif which == "Rack":
		view_zoom_slider.min_value = 0.25
		view_zoom_slider.max_value = 1.0
		view_zoom_slider.set_value_no_signal(rack.view_zoom)
	if which != "":
		view_zoom_readout.text = "%d%%" % roundi(view_zoom_slider.value * 100.0)
	_zoom_slider_syncing = false


## What every panel wears unless it says otherwise.
##
## Stored in the document rather than in the settings, because it is a fact about this
## patch: a rack somebody painted mustard should open mustard on the next machine, the
## same way its module positions travel. The category default is stored as *nothing* —
## a patch that has never been repainted carries no theme key at all.
func _set_patch_theme(key: String) -> void:
	_begin_edit()
	var arrangement: Dictionary = patch.get("arrangement", {})
	if key == ModuleThemes.CATEGORY:
		arrangement.erase("theme")
	else:
		arrangement["theme"] = key
	if arrangement.is_empty():
		patch.erase("arrangement")
	else:
		patch["arrangement"] = arrangement
	_commit_edit("panels")
	_repaint_rack()
	_say("panels: %s" % ModuleThemes.display_name(key))


## One panel, repainted on its own. Empty puts it back on the rack's.
func _set_module_theme(node_id: String, key: String) -> void:
	# Looked up before the edit is opened: there is no cancel on a begun edit, and
	# starting one for a node that is not there would leave an empty step in the history.
	var target: Dictionary = {}
	for node in patch.get("nodes", []):
		if str((node as Dictionary).get("id", "")) == node_id:
			target = node
			break
	if target.is_empty():
		return
	_begin_edit()
	if key == "":
		target.erase("theme")
	else:
		target["theme"] = key
	_commit_edit("panel")
	_repaint_rack()
	_say("%s: %s" % [node_id, "the patch's panels" if key == ""
		else ModuleThemes.display_name(key)])


## The rack draws from the document by reference, so a repaint is a rebuild.
func _repaint_rack() -> void:
	# The graph wears the styles too, so a change has to reach both views. Restyled in
	# place rather than by rebuilding the graph: a rebuild would drop the selection and
	# the camera, and repainting a node is not a change to the graph's structure.
	for node_id in widgets:
		_style_widget(widgets[node_id] as GraphNode, str(node_id))
	# The view fingerprint cannot see paint — a repaint moves nothing and changes no
	# count — so the overlays that draw from the styles are told directly.
	graph_edit.paint_stamp += 1
	if rack == null:
		return
	rack.patch = patch
	rack.rebuild()
	_sync_panels_menu()


## What the menu says the program is set to, from what the program is actually set to.
##
## The menu used to tick itself as it was built, from whatever each setting's default
## happened to be, and then only the settings somebody changed by hand were ever right:
## the theme restored from the file on startup left every theme unticked, because the
## palette is chosen before the toolbar that shows it exists. One pass, after the menu
## exists, reading the live values.
func _sync_view_menu() -> void:
	if toolbar == null:
		return
	toolbar.tick_one_of([0, 1], graph_edit.cable_style if graph_edit != null else 0)
	toolbar.tick_one_of([70, 71],
		70 + int(Settings.fetch("graph_detail", PatchGraph.DetailMode.ONE_TO_ONE)))
	var width := 0
	for index in EditorToolbar.CASE_WIDTHS.size():
		if rack != null and EditorToolbar.CASE_WIDTHS[index] == rack.case_hp:
			width = index
	toolbar.tick_one_of(range(10, 10 + EditorToolbar.CASE_LABELS.size()), 10 + width)
	toolbar.tick_one_of(range(40, 40 + Rack.DENSITY_NAMES.size()), 40 + Rack.density)
	toolbar.tick_one_of(range(50, 50 + Design.SCALE_NAMES.size()), 50 + Design.ui_scale)
	toolbar.tick_one_of(range(30, 30 + Design.PALETTE_NAMES.size()), 30 + Design.palette)
	toolbar.tick(20, Design.reduced_motion)
	_sync_panels_menu()


func _sync_panels_menu() -> void:
	if toolbar == null:
		return
	var panels := toolbar.menu_named("PanelsMenu")
	if panels == null:
		return
	var current := str(patch.get("arrangement", {}).get("theme", ""))
	for index in panels.item_count:
		var id := panels.get_item_id(index)
		if id < 200:
			continue
		var key: String = ModuleThemes.CATEGORY if id == 200 \
			else str(ModuleThemes.ORDER[id - 201])
		var wanted: String = ModuleThemes.resolve("", current)
		panels.set_item_checked(index, key == wanted)


## Right-click on a panel: the same list, plus the way back to the rack's own.
## Which panel style a node is wearing: its own, then the patch's, then the category
## colouring. The same question the rack asks, asked from here.
func _panel_style_of(node_id: String) -> String:
	var mine := ""
	for node in patch.get("nodes", []):
		if str((node as Dictionary).get("id", "")) == node_id:
			mine = str((node as Dictionary).get("theme", ""))
			break
	return ModuleThemes.resolve(mine,
		str(patch.get("arrangement", {}).get("theme", "")))


## Dresses one graph node: its panel style, whether the pointer is on it, and whether it
## is selected, decided together and written once.
##
## Together because they are three opinions about the same two styleboxes, and they were
## held by two functions that did not know about each other. Hover replaced the header
## with a copy of the editor theme's, and un-hover removed the override outright, so a
## painted module lost its colour the moment the pointer crossed it and got it back when
## the pointer left. That is what "the panel setting turns off and on" was. It also read
## as a style that never arrived: the pointer is on the module you have just picked a
## style for, so the paint was undone before it was ever seen.
##
## The style is a fact about the module, so it shows wherever the module is drawn. The
## node keeps its shape: this is paint, not geometry, exactly as it is on a rack panel.
##
## The category default removes the overrides rather than writing the default colours
## back, so an unpainted node is drawn by the editor theme and follows the palette when
## somebody changes it.
func _style_widget(widget: GraphNode, node_id: String) -> void:
	var key := _panel_style_of(node_id)
	var title_label := _title_label(widget)
	var hovered: bool = widget.has_meta("hovered") and bool(widget.get_meta("hovered"))
	# GraphNode draws a selected node from panel_selected and titlebar_selected, so an
	# override on the ordinary two is not consulted at all while it is selected. The
	# hover outline stands down there for the same reason: selection already draws one,
	# and the two together said nothing the accent had not already said.
	var lit := hovered and not widget.selected

	# Everything written on the node is relettered from the style before the body is
	# painted, so the paint never lands on ink that has not moved yet.
	_letter_widget(widget, key)

	if key == ModuleThemes.CATEGORY:
		# No skin on the widget means no plugs at its ports: the flat type-shapes are
		# the graph's own grammar and the physical one arrives with the faceplate.
		widget.remove_meta("skin")
		if lit:
			var plain := (theme.get_stylebox("panel", "GraphNode")
				as StyleBoxFlat).duplicate()
			plain.border_color = Design.BORDERS[Design.Surface.ACTIVE]
			widget.add_theme_stylebox_override("panel", plain)
		else:
			widget.remove_theme_stylebox_override("panel")
		widget.remove_theme_stylebox_override("panel_selected")
		widget.remove_theme_stylebox_override("titlebar_selected")
		if lit:
			var bar := (theme.get_stylebox("titlebar", "GraphNode")
				as StyleBoxFlat).duplicate()
			bar.border_color = Design.BORDERS[Design.Surface.ACTIVE]
			widget.add_theme_stylebox_override("titlebar", bar)
		else:
			widget.remove_theme_stylebox_override("titlebar")
		# Put back rather than removed. Removing it took the node title's own styling
		# with it — _style_node_title puts INK_BRIGHT on this same Label — so a module
		# sent back to the patch's panels came away lettered in the plain Label colour
		# while every module that had never been painted kept the bright one.
		if title_label != null:
			title_label.add_theme_color_override("font_color", Design.INK_BRIGHT)
		return

	# The body takes the faceplate, and the hover outline goes round it rather than over
	# it: the style says which module this is, the outline says the pointer is here, and
	# both are wanted at once.
	#
	# The header was the whole of this for a day, on the argument that a graph node is
	# mostly text and a pale plate under the editor's light ink is the rack's
	# knob-lettering bug in the wordiest view in the app. The argument was sound and the
	# conclusion was not: the text can move too. It is a module either way, and the two
	# views are supposed to be drawings of one object.
	var face := Design.padded_panel(Design.Surface.NODE, PANEL_PADDING,
		PANEL_PADDING, PANEL_RADIUS)
	face.bg_color = ModuleThemes.token(key, "faceplate")
	# Borderless, both halves. See panel_hardware.gd: the outline is drawn round the
	# whole module in one run, because two boxes meeting in the middle of a panel cannot
	# be given borders without ruling a line across the join.
	face.set_border_width_all(0)
	# Short and dense rather than large and fuzzy. A module sits on the canvas; it does
	# not hover a centimetre above it, and a soft wide shadow is what makes a rectangle
	# read as a floating card rather than as an object lying on a surface.
	# Offset by its own size, so the shadow starts at the box's top edge and none of it
	# is drawn above. The body box begins halfway down the module — the titlebar box is
	# the half above it — so a shadow that reached upward laid a dark line straight
	# across the panel under the title. That is the rule this pass removed, put back by
	# accident and found at 75%.
	face.shadow_size = Design.scale(5)
	face.shadow_offset = Vector2(0.0, Design.scale(5))
	face.shadow_color = Color(0.0, 0.0, 0.0, 0.42)
	# The body is the lower half of one plate, so it is not rounded or ruled along the
	# top: the titlebar's box sits directly above it and the two have to read as one
	# piece of metal. A border across the top here is a rule under the title by another
	# name, which is the thing being removed.
	face.corner_radius_top_left = 0
	face.corner_radius_top_right = 0
	face.border_width_top = 0
	widget.add_theme_stylebox_override("panel", face)
	widget.add_theme_stylebox_override("panel_selected", face.duplicate())

	# The title is printed onto the plate. There is no header — but there is still a box
	# up there, and it is the top half of the same plate.
	#
	# Drawing nothing at all was the first attempt and the screenshot killed it in one
	# look: a GraphNode's panel covers the content area only, so an empty titlebar left
	# the module's name floating on the canvas above its own faceplate, in dark ink on a
	# dark background. The band was never the box. The band was the rule under it and
	# the change of colour across it — take those away and what is left is a plate with
	# a name printed at the top of it, which is what the reference boards are.
	var head := Design.padded_panel(Design.Surface.RAISED, PANEL_PADDING,
		Design.SPACE_S, PANEL_RADIUS)
	head.bg_color = ModuleThemes.token(key, "faceplate")
	head.corner_radius_bottom_left = 0
	head.corner_radius_bottom_right = 0
	head.set_border_width_all(0)
	widget.add_theme_stylebox_override("titlebar", head)
	# And a selected module is drawn the same way, which needs saying separately because
	# the selected header is a different stylebox. Without this a selected node gets the
	# editor's own title bar back — the band, on top of the plate — for as long as it is
	# selected, which is most of the time somebody is working on one.
	widget.add_theme_stylebox_override("titlebar_selected", head.duplicate())
	# The title is a Label in the titlebar rather than a themed colour on the node, so
	# add_theme_color_override("title_color", ...) on the GraphNode silently does
	# nothing — which is how FILTER SWEEP came to be drawn in white on cream.
	if title_label != null:
		title_label.add_theme_color_override("font_color",
			ModuleThemes.token(key, "legend"))

	# For the plug overlay and anything else that draws from the panel rather than
	# painting it: the resolved skin, carried on the widget it describes.
	widget.set_meta("skin", Rack.skin(key))
	_finish_widget(widget, key)
	_socket_widget(widget, key)


## Re-cuts a node's sockets in its panel style.
##
## The port icon is the whole of the jack: GraphEdit centres it on the slot anchor and
## draws the cables underneath the nodes, so a socket drawn here sits over the end of its
## own cable and the anchor, the hitbox and the routing are all untouched. That is the
## reason the jacks are icons rather than something drawn over the panel — the brief asks
## for the graph anchor to stay exactly where it is, and this way nothing had to move.
func _socket_widget(widget: GraphNode, key: String) -> void:
	if not widget.has_meta("left_types"):
		return
	var left: PackedStringArray = widget.get_meta("left_types")
	var right: PackedStringArray = widget.get_meta("right_types")
	for slot in left.size():
		if str(left[slot]) != "":
			widget.set_slot_custom_icon_left(slot, _port_icon(str(left[slot]), key))
		if str(right[slot]) != "":
			widget.set_slot_custom_icon_right(slot, _port_icon(str(right[slot]), key))


## Gives a node the parts of a faceplate a stylebox cannot draw: the finish, the lit top
## edge, the dark sidewall, and the screws holding it in.
##
## See panel_hardware.gd for why all of it rides above the node's own drawing, and why
## that is safe. The layer is an internal child, which matters more than it sounds: a
## GraphNode binds each slot to the index of a visible child, so an ordinary child added
## here would renumber every port below it and the cables would reattach to the wrong
## ones. An internal child is not laid out, not counted, and not returned by
## get_children() — which is also why the lettering walk never tries to reletter it.
func _finish_widget(widget: GraphNode, key: String) -> void:
	var layer: PanelHardware = widget.get_meta("finish") as PanelHardware \
		if widget.has_meta("finish") else null
	if key == ModuleThemes.CATEGORY:
		if layer != null:
			layer.visible = false
		return
	if layer == null:
		layer = PanelHardware.new()
		widget.add_child(layer, false, Node.INTERNAL_MODE_FRONT)
		widget.set_meta("finish", layer)
	layer.dress(Rack.skin(key), float(Design.scale(PANEL_RADIUS)),
		Design.BORDERS[Design.Surface.ACTIVE] if widget.selected \
			or (widget.has_meta("hovered") and bool(widget.get_meta("hovered"))) \
			else ModuleThemes.token(key, "edge"))
	layer.visible = true


## Letters a node in its panel style: every label on it, and every knob.
##
## Not dimmed, on a painted panel. The editor ranks a port's name above its unit partly
## by ink, and that ranking cannot survive here: Safety Orange gives its black lettering
## 4.9:1 at full strength, so anything faded is under the bar whatever the fade, and no
## amount of tuning fixes a ceiling. The rank is carried by size and weight instead — the
## unit is already a size and a weight down from the name — which is what was separating
## them anyway. Rack.Knob reached this conclusion first and for the same reason; this is
## the same decision applied to the labels the graph draws outside the dial.
##
## Each label's editor ink is kept the first time it is touched, so a module put back on
## the patch's panels is relettered in the colour it was built with rather than in a
## guess at what that colour was.
func _letter_widget(widget: GraphNode, key: String) -> void:
	var painted := key != ModuleThemes.CATEGORY
	var ink: Color = ModuleThemes.token(key, "legend") if painted else Color.WHITE
	var skin := Rack.skin(key)
	var title_label := _title_label(widget)
	var queue: Array = widget.get_children()
	while not queue.is_empty():
		var next: Node = queue.pop_back()
		for child in next.get_children():
			queue.append(child)
		var knob := next as Rack.Knob
		if knob != null:
			# The same knob class the rack uses, so it already knows how to wear a skin
			# — it was simply never handed one down here.
			knob.skin = skin
			knob.queue_redraw()
			continue
		var chooser := next as OptionButton
		if chooser != null:
			_mount_chooser(chooser, key, skin)
			continue
		var label := next as Label
		if label == null or label == title_label:
			continue
		if not label.has_meta("editor_ink"):
			label.set_meta("editor_ink", label.get_theme_color("font_color"))
		label.add_theme_color_override("font_color",
			ink if painted else label.get_meta("editor_ink"))


## Mounts a dropdown in the panel instead of leaving it dressed as a form field.
##
## A shape selector on a faceplate is a switch cut into the metal: a dark inset field the
## same height as the knobs beside it, with the chosen setting printed in it. What was
## there instead was the editor's own button chrome — a rounded slab a shade lighter than
## the surface behind it — which on a cream lab panel is the one control that still says
## "web form" out loud.
##
## Inset rather than raised, which is the whole difference. A raised control sits on the
## panel and belongs to the application; a recessed one is cut into the panel and belongs
## to the instrument. It is the same trick as the jack: the darkness is the depth.
##
## Its own lettering, and not the plate's: the field is the hardware colour in every
## style, so its text is light in every style, and the legend that reads on the faceplate
## would be black on black half the time.
func _mount_chooser(chooser: OptionButton, key: String, skin: Dictionary) -> void:
	if key == ModuleThemes.CATEGORY:
		for state in ["normal", "hover", "pressed", "focus", "disabled"]:
			chooser.remove_theme_stylebox_override(state)
		for state in ["font_color", "font_hover_color", "font_pressed_color",
				"font_focus_color"]:
			chooser.remove_theme_color_override(state)
		chooser.remove_theme_font_override("font")
		if chooser.has_meta("lip"):
			(chooser.get_meta("lip") as Panel).visible = false
		return
	var field: Color = skin.get("hardware", Color(0.13, 0.13, 0.14))
	var wall: Color = skin.get("hardware_hi", Color(0.3, 0.31, 0.33))
	for state in ["normal", "hover", "pressed", "focus", "disabled"]:
		var box := StyleBoxFlat.new()
		box.bg_color = field.lightened(0.10) if state == "hover" else field
		# Barely rounded. A recess is cut with a tool and has corners; the four-pixel
		# radius it had is the radius of a button, and it was doing as much to keep this
		# looking like a form control as the colour was.
		box.set_corner_radius_all(maxi(Design.scale(2), 1))
		box.content_margin_top = Design.scale(Design.SPACE_XS)
		box.content_margin_bottom = Design.scale(Design.SPACE_XS)
		box.content_margin_left = Design.scale(Design.SPACE_S)
		box.content_margin_right = Design.scale(Design.SPACE_XS)
		# The lip of the recess, all the way round rather than a line along the top.
		# Dark where the cut catches no light, pale along the bottom where the far wall
		# of the recess faces up into it — the panel's own top-lighting, read inside
		# out. One border colour is all a stylebox has, so the pale wall is a second box
		# and this is the dark one.
		box.set_border_width_all(maxi(Design.scale(1), 1))
		box.border_color = field.darkened(0.55)
		box.shadow_size = 0
		if state == "focus":
			box.border_color = Design.FOCUS
		chooser.add_theme_stylebox_override(state, box)
	# The perimeter's lit half, drawn as a second control behind the first: a Panel one
	# pixel down carrying the pale wall, which shows only along the bottom edge where the
	# field above does not cover it.
	var lip: Panel = chooser.get_meta("lip") as Panel \
		if chooser.has_meta("lip") else null
	if lip == null:
		lip = Panel.new()
		lip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		lip.show_behind_parent = true
		lip.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		lip.offset_top = 1.0
		lip.offset_bottom = 2.0
		chooser.add_child(lip, false, Node.INTERNAL_MODE_FRONT)
		chooser.set_meta("lip", lip)
	var wall_box := StyleBoxFlat.new()
	wall_box.bg_color = Color(wall, 0.5)
	wall_box.set_corner_radius_all(maxi(Design.scale(2), 1))
	lip.add_theme_stylebox_override("panel", wall_box)

	# Set like a legend rather than like a menu: the same weight the panel prints its
	# control names in, so the chosen setting reads as something stamped in the recess.
	var printed := Color(1.0, 1.0, 1.0, 1.0).lerp(wall, 0.18)
	chooser.add_theme_font_override("font", Design.font(Design.WEIGHT_SEMIBOLD))
	for state in ["font_color", "font_hover_color", "font_pressed_color",
			"font_focus_color"]:
		chooser.add_theme_color_override(state, printed)


## A GraphNode's title is a Label the node builds for itself, and it is reached through
## the titlebar rather than through the theme.
func _title_label(widget: GraphNode) -> Label:
	var bar := widget.get_titlebar_hbox()
	if bar == null:
		return null
	for child in bar.get_children():
		var label := child as Label
		if label != null:
			return label
	return null


func _on_module_theme_requested(node_id: String, at: Vector2) -> void:
	var menu := PopupMenu.new()
	menu.add_item("Use the patch's panels", 0)
	menu.add_separator()
	for index in ModuleThemes.ORDER.size():
		var key: String = ModuleThemes.ORDER[index]
		menu.add_item(ModuleThemes.display_name(key), 1 + index)
	menu.id_pressed.connect(func(id: int) -> void:
		_set_module_theme(node_id, "" if id == 0 else str(ModuleThemes.ORDER[id - 1]))
		menu.queue_free())
	menu.close_requested.connect(func() -> void: menu.queue_free())
	add_child(menu)
	menu.popup(Rect2i(Vector2i(at), Vector2i(1, 1)))


func _on_view_zoom_slider(value: float) -> void:
	if view_zoom_readout == null or _zoom_slider_syncing:
		return
	var which := _zoomable_view()
	if which == "Graph":
		graph_edit.zoom = value
	elif which == "Rack":
		rack.view_zoom = value
	view_zoom_readout.text = "%d%%" % roundi(value * 100.0)


func _on_file_menu(id: int) -> void:
	if id == 4:
		_new_file()
		return
	if id == 5:
		if _on_web():
			_say("MIDI import is desktop-only for now")
			return
		midi_dialog.popup_centered_ratio(0.6)
		return
	if id == 6:
		if _on_web():
			_say("transcribing is desktop-only — it runs a separate program")
			return
		if Transcribe.binary_path() == "":
			_say("no transcriber built — see tools/sg-transcribe/README.md")
			return
		audio_dialog.popup_centered_ratio(0.6)
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
	# Panels first, because the detail modes below catch everything from 70 up and these
	# ids are above that.
	if id >= 200 and id <= 200 + ModuleThemes.ORDER.size():
		_set_patch_theme(ModuleThemes.CATEGORY if id == 200
			else str(ModuleThemes.ORDER[id - 201]))
		return
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
		toolbar.tick_one_of(range(40, 40 + Rack.DENSITY_NAMES.size()),
			40 + Rack.density)
		rack.rebuild()
		_say("rack: %s" % Rack.DENSITY_NAMES[Rack.density])
		return
	if id >= 30:
		_use_palette(id - 30)
		return
	if id == 20:
		Design.reduced_motion = not Design.reduced_motion
		Settings.store("reduced_motion", Design.reduced_motion)
		toolbar.tick(20, Design.reduced_motion)
		if Design.reduced_motion and graph_edit != null:
			# Cleared rather than frozen, or the last frame of glow would sit there
			# forever looking like a port that is stuck on.
			graph_edit.port_levels.clear()
			graph_edit.queue_redraw()
		return
	if id < 10:
		toolbar.tick_one_of([0, 1], id)
		# The graph's routing only. The rack keeps its physical cords: yoking both
		# views to one menu id is how choosing PCB for the diagram silently stripped
		# the rack back to thin lines.
		graph_edit.cable_style = id
		graph_edit.refresh_cables()
		return
	var choice := id - 10
	toolbar.tick_one_of(range(10, 10 + EditorToolbar.CASE_LABELS.size()), id)
	rack.case_hp = EditorToolbar.CASE_WIDTHS[choice]
	# Picking a case answers "does my patch fit it" — so show the whole case at once.
	rack.fit_case()


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
	Settings.store("graph_detail", mode)
	toolbar.tick_one_of([70, 71], 70 + mode)
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
	if toolbar != null:
		toolbar.tick_one_of(range(50, 50 + Design.SCALE_NAMES.size()),
			50 + Design.ui_scale)

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
	if toolbar != null:
		toolbar.tick_one_of(range(30, 30 + Design.PALETTE_NAMES.size()), 30 + index)

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
	if roll_pitch != null:
		roll_pitch.queue_redraw()




## Selects a view by its tab title.
##
## By name rather than by index. "views.current_tab = 3" meant Outline until a tab was
## added in front of it, at which point it silently meant Sandbox — and the check that
## caught it was a sandbox assertion three hundred lines away, which is a long way from
## the mistake. Tabs are going to keep moving while the patcher is being replaced.
func show_view(title: String) -> bool:
	if views == null:
		return false
	# Two levels, one verb. Lenses route through the patch-view state; workspaces are
	# still tabs. "Rack" stopped being a tab when it became a lens, and every caller
	# that asks for it by name should not have to know that happened.
	var lenses := {"rack": PatchView.RACK, "graph": PatchView.GRAPH,
		"schematic": PatchView.SCHEMATIC, "face": PatchView.FACE}
	var wanted := title.to_lower()
	if lenses.has(wanted):
		if patch_view != lenses[wanted] or views.get_tab_title(views.current_tab) != "Patch":
			_set_patch_view(lenses[wanted])
		return true
	for index in views.get_tab_count():
		if views.get_tab_title(index).to_lower() == wanted:
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
## Which side view is out: the panel that plays the file, or the scope that
## troubleshoots it. The probe only spends engine time while it is the one showing.


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
	if scope_probe != null:
		# The probe folds with the panel: it is the panel now.
		scope_probe.visible = open
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

	# The panel and the probe scope share the side column: the panel is what the
	# file is for, the scope is the bench instrument you clip onto a wire when a
	# signal is not doing what it should. Tabs, because they are different jobs.
	var side_column := VBoxContainer.new()
	side_column.size_flags_vertical = Control.SIZE_EXPAND_FILL
	side_column.add_theme_constant_override("separation", Design.SPACE_S)
	inset.add_child(side_column)
	# One job now: the bench. The Panel tab is gone — the face lives on the canvas
	# behind the Face toggle, the presets travel with it, and Graph valid reads out
	# of the menu — so the side column is the probe scope, with the health line and
	# the problem list underneath, appearing only when there are problems to list.
	scope_probe = ProbeScope.new()
	scope_probe.size_flags_vertical = Control.SIZE_EXPAND_FILL
	side_column.add_child(scope_probe)

	side_panel_body = VBoxContainer.new()
	side_panel_body.add_theme_constant_override("separation", Design.SPACE_S)
	side_column.add_child(side_panel_body)

	# The collapse control sits under everything, and never moves: the way back has
	# to be on screen when the body is hidden.
	var strip := HBoxContainer.new()
	side_panel_toggle = Button.new()
	side_panel_toggle.flat = true
	side_panel_toggle.custom_minimum_size.x = Design.scale(28)
	side_panel_toggle.pressed.connect(func() -> void:
		_set_side_panel_open(not side_panel_open))
	strip.add_child(_defocus(side_panel_toggle))
	side_panel.add_child(strip)

	health_label = Label.new()
	health_label.add_theme_font_size_override("font_size",
		Design.type(Design.SIZE_SECONDARY))
	side_panel_body.add_child(health_label)

	diagnostics_heading = _section_heading("Problems")
	side_panel_body.add_child(diagnostics_heading)
	diagnostics_list = VBoxContainer.new()
	diagnostics_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	diagnostics_list.add_theme_constant_override("separation", Design.SPACE_S)
	side_panel_body.add_child(diagnostics_list)

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
		# The schematic is a mount on this canvas too, and turning to the face does not
		# displace it by itself: both would be visible, the panel drawn on top of the
		# grid. Every other pair of these views already cleared each other and this one
		# was missed, because it is the transition nobody makes while building the view
		# they are working on.
		if schematic_up:
			await _show_schematic(false)
		face_anchor = graph_edit.case_box().position
		graph_edit.face_up = true
		for child in graph_edit.get_children():
			if child is GraphNode:
				(child as GraphNode).visible = false
		graph_edit.clear_connections()
		for module_name in module_mounts:
			(module_mounts[module_name] as Control).visible = false
		big_face.visible = true
		_refresh_face()
		# As wide as its panels need and no wider.
		#
		# It used to stretch to the case it replaced, on the reasoning that the face
		# stands where the wiring stood. But a graph is usually far wider than the
		# instrument dressed out of it — 2812 units against 513 on first-synth — and
		# everything positioned against that width went out into empty canvas with it.
		# The band's chips sat two thousand units right of the panel, and the face's own
		# name is a centred label, so it drew halfway across a rectangle nobody can see.
		#
		# full_width() is the whole rail, ports to ports, which is the thing that must
		# not be cropped. The empty stretch beyond it was never doing anything.
		var natural: Vector2 = big_face.get_combined_minimum_size()
		big_face.size = Vector2(maxf(big_face.full_width(), 1.0), natural.y)
		_place_face()
	else:
		graph_edit.face_up = false
		graph_edit.mount_box = Rect2()
		big_face.visible = false
		await _rebuild_view()


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
	graph_edit.flip_deletable = {}
	# A flip for a module that is no longer open — or an instance no longer in the
	# patch — has nothing to stand on.
	for module_name in flipped_modules.keys():
		if not graph_edit.groups.has(module_name):
			flipped_modules.erase(module_name)
	for instance_id in flipped_nodes.keys():
		if not widgets.has(str(instance_id)):
			flipped_nodes.erase(instance_id)
	# Devices are panels, full stop: an instance whose definition carries a face
	# mounts it, on arrival and on load alike. The node form still exists
	# underneath — position, deletion and the document live on it — but the canvas
	# shows the instrument; WIRES went, and DIVE is the way into the wiring. A
	# module with no face — a collapsed subcircuit — stays a node, where the wand,
	# the ghost jacks and the open frame all still mean something.
	for node in patch.get("nodes", []):
		var faced_module := str(node.get("module", ""))
		if faced_module == "" or not widgets.has(str(node["id"])):
			continue
		var faced: Dictionary = patch.get("modules", {}).get(faced_module, {})
		if not (faced.get("controls", []) as Array).is_empty():
			flipped_nodes[str(node["id"])] = true
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
		# The band is a title bar, not a wash over the face's first row: the face
		# mounts one band-height lower and the frame wraps band and face both.
		# Overlapped, the band's drag handle claimed every press on the face's top
		# row — the preset strip — ahead of the GUI pass, so the strip's arrows
		# only answered on the sliver that poked out below the band.
		var band_height := float(Design.scale(26.0))
		shown.set_meta("anchor", widget.position_offset + Vector2(0.0, band_height))
		# The band is keyed by instance so two of the same device turn independently —
		# the key is plumbing, not a label.
		graph_edit.flip_frames[str(instance_id)] = Rect2(widget.position_offset,
			shown.size + Vector2(0.0, band_height))
		graph_edit.flip_labels[str(instance_id)] = band_label
		graph_edit.flip_deletable[str(instance_id)] = true


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
		# The mounted face's bank lives in the module definition, so its pages
		# are saved there — every instance of the device shares one bank, the
		# way every unit of a hardware run ships the same ROM.
		var strip_face := mount as PatchFace
		strip_face.preset_applied.connect(
			func(index: int, writes: Array) -> void:
				_apply_preset(index, writes, strip_face, module_name))
		strip_face.preset_saved.connect(
			func(values: Dictionary) -> void:
				_save_preset(values, strip_face, module_name))
		strip_face.morph_started.connect(func() -> void: _begin_edit())
		strip_face.preset_morphed.connect(_write_morph)
		strip_face.morph_finished.connect(func() -> void: _commit_edit("morph"))
		strip_face.preset_renamed.connect(
			func(index: int, wanted: String) -> void:
				_rename_preset(index, wanted, strip_face, module_name))
		strip_face.preset_reordered.connect(
			func(from_index: int, to_index: int) -> void:
				_reorder_preset(from_index, to_index, strip_face, module_name))
		strip_face.preset_deleted.connect(
			func(index: int) -> void:
				_delete_preset(index, strip_face, module_name))
	var panel := mount as PatchFace
	panel.preset_index = int(preset_pages.get(module_name, -1))
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
		# The bank came along with the face when the device was imported; without
		# this line every mounted device's strip said "no presets yet" while the
		# file it came from held five pages.
		"presets": definition.get("presets", []),
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

func _on_face_rearranged(rows: Array, added: Dictionary = {},
		mount: ModuleFace = null) -> void:
	# The emitting mount knows whose face it is; the selection no longer has to —
	# an open, flipped module has no instance node to select.
	var module_name := mount.module_name() if mount != null 		else _module_of(str(inspecting.get("node", "")))
	var definitions: Dictionary = patch.get("modules", {})
	if module_name == "" or not definitions.has(module_name):
		return
	_begin_edit()
	var definition: Dictionary = definitions[module_name]

	# A ghost dragged onto the face was never exported, so it becomes an export on the way
	# in â€” one edit, because "put this knob on the module" is one thought. The face names it
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
	_refresh_context()
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
## edit, and it is not this gesture â€” see task #61.


func _on_face_knob_removed(export_name: String, mount: ModuleFace = null) -> void:
	var module_name := mount.module_name() if mount != null 		else _module_of(str(inspecting.get("node", "")))
	var definitions: Dictionary = patch.get("modules", {})
	if module_name == "" or not definitions.has(module_name):
		return
	var definition: Dictionary = definitions[module_name]
	# From the rows the face is actually showing, which for a module that has never been
	# arranged is the wrap on screen rather than an empty panel. Taking a knob off a face
	# nobody has arranged has to write down the rest of it or the removal would read as
	# "clear the panel".
	var rows: Array = ModuleFace.moved(
		mount.face_rows() if mount != null else [], export_name, {"remove": true})
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


func _mount_for(key: String) -> ModuleFace:
	var mount: Control = module_mounts.get(key, null)
	if mount != null and not (mount is ModuleFace):
		mount.queue_free()
		module_mounts.erase(key)
		mount = null
	if mount == null:
		mount = ModuleFace.new()
		mount.z_index = 50
		var shown_mount := mount as ModuleFace
		shown_mount.rearranged.connect(func(rows: Array, added: Dictionary = {}) -> void:
			_on_face_rearranged(rows, added, shown_mount))
		shown_mount.removed.connect(func(export_name: String) -> void:
			_on_face_knob_removed(export_name, shown_mount))
		(mount as ModuleFace).refused.connect(
			func(reason: String) -> void: _say(reason))
		graph_edit.add_child(mount)
		module_mounts[key] = mount
	var shown := mount as ModuleFace
	shown.patch = patch
	shown.registry = registry
	shown.rack = rack
	return shown


## Turns the canvas to the schematic and back.
##
## Session state, like the face flip: which way you are looking at a patch is not a fact
## about the patch, so nothing is written and nothing lands in undo.
##
## The nodes are hidden rather than moved. A schematic that dragged the real nodes onto
## its grid would be an edit — it would dirty the document, land in the history, and
## leave somebody who only wanted a look at it with a patch they have to undo.
func _show_schematic(on: bool) -> void:
	if graph_edit == null or schematic == null:
		return
	schematic_up = on
	graph_edit.schematic_on = on
	if on:
		# Face edit is a thing you do to the wiring, and there is no wiring here.
		if graph_edit.face_edit:
			graph_edit.face_edit = false
			graph_edit.face_edit_on = false
			_say("face edit: off — the schematic has no knobs to dress")
		if big_face != null and big_face.visible:
			await _flip_container(false)
		face_anchor = graph_edit.case_box().position
		for child in graph_edit.get_children():
			if child is GraphNode:
				(child as GraphNode).visible = false
		graph_edit.clear_connections()
		for module_name in module_mounts:
			(module_mounts[module_name] as Control).visible = false
		schematic.patch = patch
		schematic.registry = registry
		schematic.type_colours = TYPE_COLOURS
		schematic.rebuild()
		schematic.visible = true
		# So the canvas keeps placing it. Without this the schematic is positioned once
		# and then sits there while the camera moves underneath it - fixed on screen
		# while everything else zooms, which is exactly as wrong as it sounds.
		graph_edit.mount_up = true
		# So the case band still has something to measure, and the way out is still on
		# screen: with the nodes hidden there is nothing else for it to sit above.
		graph_edit.mount_box = Rect2(face_anchor, schematic.content_size())
		# A frame is waited for before framing. fit_to measures usable_rect(), and that
		# rectangle is not the truth until the canvas has been laid out at its current
		# size - ask too early and it answers with a viewport taller than the one on
		# screen, which fits the schematic to a window that is not there. The same
		# reasoning, and the same fix, as the wait before fit_graph() in _load_text.
		await get_tree().process_frame
		# Framed on arrival. The schematic is anchored where the case stood, and its grid
		# is a different shape and usually a different size from the drawing it replaces
		# - so without this it opens wherever the old layout happened to leave the camera,
		# which at any zoom but the one you were on is off the side of the window.
		graph_edit.fit_to(Rect2(face_anchor, schematic.content_size()))
		_place_face()
		_say("schematic: %d nodes on the grid" % (patch.get("nodes", []) as Array).size())
	else:
		schematic.visible = false
		graph_edit.mount_up = false
		graph_edit.mount_box = Rect2()
		await _rebuild_view()


## Back to the wiring from wherever, and a no-op when already there.
##
## Not a toggle, unlike the two modes: the graph is the view the others are departures
## from, so pressing it twice means the same as pressing it once.
func _show_graph() -> void:
	if schematic_up:
		await _show_schematic(false)
	if graph_edit.face_up:
		await _flip_container(false)


func _place_face() -> void:
	if graph_edit == null:
		return
	var zoom: float = graph_edit.zoom if graph_edit.zoom > 0.0 else 1.0
	if big_face != null and big_face.visible:
		big_face.position = face_anchor * zoom - graph_edit.scroll_offset
		big_face.scale = Vector2(zoom, zoom)
		# The band is measured from the nodes, and the face hides them, so it is told
		# where the face is instead. Every frame rather than once at the flip: the face
		# settles to its own size a frame or two later, and a rectangle taken before that
		# left the chips floating in empty canvas beside the panel they belong to.
		# Its own width, not its stretched one. The face is sized to at least the case it
		# replaces, so on a wide patch most of that is empty canvas to the right of the
		# panel — and a band measured from it put the chips out there on their own,
		# nowhere near the thing they belong to.
		graph_edit.mount_box = Rect2(face_anchor,
			Vector2(maxf(big_face.full_width(), 1.0), big_face.size.y))
	if schematic != null and schematic.visible and mount_area != null:
		# The mount area tracks the usable rectangle, and the schematic is placed inside
		# it — so its offset is the canvas transform less where that area begins.
		var area: Rect2 = graph_edit.usable_rect()
		mount_area.position = area.position
		mount_area.size = area.size
		schematic.position = face_anchor * zoom - graph_edit.scroll_offset - area.position
		schematic.scale = Vector2(zoom, zoom)
	for module_name in module_mounts:
		var mount := module_mounts[module_name] as Control
		if mount.visible and mount.has_meta("anchor"):
			mount.position = (mount.get_meta("anchor") as Vector2) * zoom 				- graph_edit.scroll_offset
			mount.scale = Vector2(zoom, zoom)


## Selection or document changed: everything that follows them catches up. The
## context panel this used to feed is gone with the side Panel; what remains is the
## face's offer, the ghost jacks, and the outline — kept under the old names because
## a dozen places call them after the graph changes.
func _refresh_context() -> void:
	_refresh_face()
	_refresh_ghost_ports()


func _show_info() -> void:
	# Selection paths call _refresh_context; only document changes come through here,
	# because rebuilding the outline's tree inside its own selection signal is a
	# clear-during-emit, and Godot answers that with a hang rather than an error.
	_refresh_context()
	if outline != null:
		outline.patch = patch
		outline.registry = registry
		outline.refresh()


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
	_refresh_context()
	_refresh_face()
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
	# Before the engine goes: the panel is drawn by a plugin the engine owns.
	_close_plugin_face()
	# The sandbox's voices first: eight more players and engines with the same race,
	# and a teardown that only remembered the editor's own was half a teardown.
	if sandbox != null and sandbox.sounds != null:
		sandbox.sounds.shutdown()
	if engine != null:
		engine.all_notes_off()
	if player != null:
		# The mixer runs on its own thread and can be mid-block inside this player's
		# playback at any moment; stop() alone does not wait for it. The lock does:
		# nothing mixes while it is held, so after unlock the stopped, streamless
		# player is genuinely untouched and freeing it is safe. Windows Error
		# Reporting had the receipts — the same fault offset inside Godot's audio
		# thread on run after run, usually landing just after the verdict had
		# flushed, occasionally just before, which is all a "flake" ever was.
		AudioServer.lock()
		player.stop()
		player.stream = null
		AudioServer.unlock()
		if player.get_parent() != null:
			player.get_parent().remove_child(player)
		player.free()
		player = null
	playback = null
	engine = null


func _exit_tree() -> void:
	shutdown_audio()


## The histories are Objects, not RefCounteds, so they are freed by hand or not at all.
##
## One was always outliving the editor: the dive out of a module frees the history it
## made on the way in, and nothing freed the one still in use when the program ended.
## That is the "1 ObjectDB instance was leaked at exit" the suite has printed for as long
## as anyone has looked, and the suspected reason it segfaulted at teardown perhaps a
## third of the time - a leaked object is destroyed during cleanup in no particular
## order, and this one holds callables bound to nodes and to the extension's own objects,
## which by then may be gone.
##
## PREDELETE rather than _exit_tree: leaving the tree is not the same as ceasing to
## exist, and a node that is re-parented would otherwise come back holding a freed
## history.
func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE:
		return
	if is_instance_valid(undo_redo):
		undo_redo.free()
	# Any level still stacked underneath, if the editor ends mid-dive.
	for frame in dive_stack:
		var history: Variant = (frame as Dictionary).get("history", null)
		if history is UndoRedo and is_instance_valid(history):
			(history as UndoRedo).free()
	dive_stack.clear()


func _process(_delta: float) -> void:
	_watch_for_quit_request(_delta)
	# The roll's scrollbar follows the roll however the roll moved — wheel, page
	# turn, a menu changing the window. Guarded, because resizing the range can
	# clamp the value and echo back as a user gesture.
	if roll_scroll != null and roll_scroll.is_visible_in_tree() and piano_roll != null:
		_roll_scroll_syncing = true
		var reach := maxi(piano_roll.step_count() + 16,
			piano_roll.scroll_step + piano_roll.view_rows)
		roll_scroll.max_value = reach
		roll_scroll.page = piano_roll.view_rows
		var want := float(reach - piano_roll.view_rows - piano_roll.scroll_step)
		if absf(roll_scroll.value - want) > 0.5:
			roll_scroll.set_value_no_signal(want)
		_roll_scroll_syncing = false

	# The slider follows the view when zoom changes by any other hand — Ctrl+wheel,
	# the graph's own buttons, a fitted case. Cheap, and quiet: no_signal, so the
	# follow never argues with the drag.
	if view_zoom_slider != null and view_zoom_slider.visible:
		var which := _zoomable_view()
		var actual: float = graph_edit.zoom if which == "Graph" \
			else (rack.view_zoom if which == "Rack" else -1.0)
		if actual > 0.0 and absf(actual - view_zoom_slider.value) > 0.005:
			view_zoom_slider.set_value_no_signal(actual)
			view_zoom_readout.text = "%d%%" % roundi(actual * 100.0)
	# Before the early return: the dock's cables have to follow the graph as it scrolls,
	# zooms and has nodes dragged under them, and none of that waits for an engine.
	_refresh_seam_cables()
	if engine == null or playback == null:
		return
	if engine.is_loaded():
		engine.fill_playback(playback, playback.get_frames_available())
	_update_port_levels(_delta)
	_advance_roll(_delta)
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


func _slot_type(signal_type: String) -> int:
	match signal_type:
		"audio": return SLOT_AUDIO
		"control": return SLOT_CONTROL
		"event": return SLOT_EVENT
		_: return SLOT_NOTE


## The value a knob returns to on a double tap: the one its node entered the
## document with, falling back to the descriptor's factory default for a parameter
## the document never set.
func _knob_home(node_id: String, parameter_name: String, fallback: float) -> float:
	var recorded: Dictionary = _home_values.get(node_id, {})
	return float(recorded.get(parameter_name, fallback))


func _rebuild_view() -> void:
	# The synthesized descriptors are read from the document, so they are stale the moment
	# it changes. Every caller that edited modules or seams used to remember to rebuild
	# them and every new caller had to be told; doing it here means the widgets are built
	# against the document in front of them, which is the only version that was ever right.
	_synthesize_module_descriptors()
	# Any node seen here for the first time is entering the document — off a loaded
	# file, out of the add menu, or expanded from a module — and the values it
	# arrives with are its home.
	for node in patch.get("nodes", []):
		var arrived := str(node["id"])
		if not _home_values.has(arrived):
			_home_values[arrived] = 				(node.get("parameters", {}) as Dictionary).duplicate(true)
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
	# Freshly built widgets carry no face badges; while face edit is on, an undo or
	# reload must not leave the overlay reading last document's dress.
	if graph_edit != null and graph_edit.face_edit:
		_refresh_face_edit_badges()
	# The probe scope's wire list follows the document, and its taps re-resolve in
	# the engine on every load — a probe pointing at a deleted node goes quiet.
	if scope_probe != null:
		scope_probe.engine = engine
		var probe_sources: Array = []
		var probe_gates: Array = []
		for node in patch.get("nodes", []):
			var node_id := str(node.get("id", ""))
			for outlet: Dictionary in _port_list(node_id, "outputs"):
				var entry := {"node": node_id, "port": str(outlet.get("name", ""))}
				probe_sources.append(entry)
				if str(outlet.get("type", "")) != "audio":
					probe_gates.append(entry)
		scope_probe.refresh_sources(probe_sources, probe_gates)
	# The roll reads the document by reference, and the document was just replaced.
	if piano_roll != null:
		piano_roll.sequence = patch.get("sequence", {})
		_refresh_roll_tempo_text()
		piano_roll.queue_redraw()


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
	# Above the cord layer (z 1): a cable passes behind the panels. See CordLayer.
	widget.z_index = 2
	widget.set_meta("type", type_name)

	_style_node_title(widget, descriptor)

	# Hover is its own state, distinct from selection.
	#
	# GraphNode has normal and selected and nothing between them, so a node under the
	# pointer looked exactly like one three columns away — and in a patch dense enough
	# to need the mouse, "which node am I about to click" is a real question. One step
	# of border brightening: enough to answer it, not enough to be mistaken for the
	# accent outline that means selected.
	# Right-click for the panel style, the same menu the rack offers on its modules. A
	# style is a fact about the module rather than about a view, so it is changed by
	# pointing at the module — in whichever view you happen to be looking at it.
	widget.gui_input.connect(func(event: InputEvent) -> void:
		var press := event as InputEventMouseButton
		if press != null and press.pressed \
				and press.button_index == MOUSE_BUTTON_RIGHT:
			_on_module_theme_requested(str(widget.get_meta("patch_id")),
				widget.get_global_mouse_position())
			widget.accept_event())
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
	# The Step Sequencer wears a bar of piano roll instead of sixteen number
	# cells: length keeps its cell up here, the steps become the grid appended
	# below the port rows. See step_grid.gd for why.
	var step_lane: bool = str(node.get("type", "")) == "StepSequencer" and grid.is_empty()
	if step_lane:
		for parameter: Dictionary in parameters:
			if str(parameter["name"]) == "length":
				grid = [[parameter]]
	# A module with one knob and an input of the same name puts the knob on that input's
	# row. The Amplifier is the case in point: its gain knob sat on the top row while the
	# gain input sat below it, so the panel's one relationship — this socket feeds this
	# control — was the one thing the layout did not say. Empty lines pad the grid down
	# to the port's row; a padded line is a short row holding only its ports, which is
	# exactly what the rows above the knob should be.
	if grid.is_empty() and parameters.size() == 1:
		for port_index in inputs.size():
			if str(inputs[port_index]["name"]) == str(parameters[0]["name"]):
				for _pad in port_index:
					grid.append([])
				grid.append([parameters[0]])
				break

	if grid.is_empty():
		var per_line := PARAMETERS_PER_LINE
		var line: Array = []
		for parameter: Dictionary in parameters:
			line.append(parameter)
			if line.size() == per_line:
				grid.append(line)
				line = []
		if not line.is_empty():
			grid.append(line)
	var port_rows: int = maxi(inputs.size(), outputs.size())
	var cell_lines: int = grid.size()

	# Whether this module is a rail module: one side is mostly ports and the other is
	# mostly empty. The Keyboard is the type specimen — three knobs, four outputs — and
	# on such a module the centred knob column reads as three knobs stranded on a field,
	# because the centre of the panel is the one place nothing else is. Clustering the
	# knobs against the quiet edge turns the same rows into a control block facing an
	# I/O rail, which is the composition a real panel would have.
	#
	# Judged from the shape, not named per module, so the next node with this shape
	# composes itself the same way. Modules with balanced sides keep the centred column.
	var rail_right: bool = outputs.size() - cell_lines >= 2 and inputs.size() <= 1
	var rail_left: bool = inputs.size() - cell_lines >= 2 and outputs.size() <= 1

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
		cells.alignment = BoxContainer.ALIGNMENT_BEGIN if rail_right \
			else BoxContainer.ALIGNMENT_END if rail_left \
			else BoxContainer.ALIGNMENT_CENTER
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

		# Every line stays visible. The old "progressive complexity" folded everything
		# past the first line behind an "n more" click, which taxed every look at a
		# freshly loaded patch — the way to see less of a module is to zoom out, not
		# to unwrap it knob by knob.
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
			widget.set_slot_custom_icon_left(row,
				_port_icon(inputs[row]["type"], _panel_style_of(str(node["id"]))))
		if has_output:
			widget.set_slot_custom_icon_right(row,
				_port_icon(outputs[row]["type"], _panel_style_of(str(node["id"]))))

	if str(node.get("type", "")) in ["PluginEffect", "PluginInstrument"]:
		var plugin_line := HBoxContainer.new()
		plugin_line.set_meta("row", "steps")
		plugin_line.set_meta("has_slot", false)
		plugin_line.alignment = BoxContainer.ALIGNMENT_CENTER
		var chosen := str(node.get("plugin", ""))
		var entry: Dictionary = patch.get("plugins", {}).get(chosen, {})
		var choose := Button.new()
		choose.text = "Choose plugin…" if chosen == "" else str(entry.get("name", chosen))
		choose.tooltip_text = "Pick an installed VST3 or CLAP for this node. The patch " 			+ "remembers it by identity, so it still opens where the plugin is absent — " 			+ "the audio passes through and the patch says so."
		var choose_id := str(node["id"])
		choose.pressed.connect(func() -> void: _choose_plugin_for(choose_id))
		plugin_line.add_child(_defocus(choose))
		if chosen != "":
			var slots := Button.new()
			slots.text = "Slots…"
			slots.tooltip_text = "Say which of the plugin's own controls each slot " 				+ "drives. A bound slot is an ordinary control input, so an LFO or a " 				+ "MidiCC node can move it."
			slots.pressed.connect(func() -> void: _bind_plugin_slots(choose_id))
			plugin_line.add_child(_defocus(slots))
			# Offered whenever this build can host at all, rather than only when the
			# plugin turns out to have a panel. Asking would mean a loaded graph and a
			# resolved plugin, and widgets are built at times when neither is true yet —
			# so the question is asked on the press, where a plain sentence can be the
			# answer.
			if engine != null and engine.can_host_plugins():
				var face := Button.new()
				face.text = "Panel"
				face.tooltip_text = "Show the plugin's own panel, in a window of its " 					+ "own. Everything it changes there belongs to the plugin, and " 					+ "travels with the patch as its state."
				face.pressed.connect(func() -> void: _open_plugin_face(choose_id))
				plugin_line.add_child(_defocus(face))
		widget.add_child(plugin_line)

	if str(node.get("type", "")) == "MidiCC":
		var learn_line := HBoxContainer.new()
		learn_line.set_meta("row", "steps")
		learn_line.set_meta("has_slot", false)
		learn_line.alignment = BoxContainer.ALIGNMENT_CENTER
		var learn := Button.new()
		learn.text = "Learn"
		learn.tooltip_text = "Arm, then turn the hardware knob you mean: the next " 			+ "controller heard becomes this node's number. Escape cancels."
		var learn_id := str(node["id"])
		learn.pressed.connect(func() -> void: _learn_midicc_node(learn_id))
		learn_line.add_child(_defocus(learn))
		widget.add_child(learn_line)

	if str(node.get("type", "")) == "Speech":
		var words_line := HBoxContainer.new()
		words_line.set_meta("row", "steps")
		words_line.set_meta("has_slot", false)
		words_line.alignment = BoxContainer.ALIGNMENT_CENTER
		var words := Button.new()
		words.text = "Words…"
		words.tooltip_text = "Put words in this node's mouth: type a sentence for " \
			+ "the computer's own voice, or feed it a WAV, and either way it is " \
			+ "crushed to a few hundred bytes of chip-speak carried in the patch."
		var words_id := str(node["id"])
		words.pressed.connect(func() -> void: _open_speech_words(words_id))
		words_line.add_child(_defocus(words))
		widget.add_child(words_line)

	if step_lane:
		var lane_line := HBoxContainer.new()
		# Its own row kind, not "module": the detail pass runs _fit_row_height over
		# module rows, and that helper hides any slotless row without parameter
		# cells — which is this row exactly, and its whole job is what it carries.
		lane_line.set_meta("row", "steps")
		lane_line.set_meta("has_slot", false)
		var lane := StepGrid.new()
		lane.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var lane_id := str(node["id"])
		lane.read = func() -> Dictionary:
			for entry: Dictionary in patch.get("nodes", []):
				if str(entry["id"]) == lane_id:
					var held: Dictionary = entry.get("parameters", {})
					var values: Array = []
					for i in StepGrid.STEPS:
						values.append(float(held.get("step%d" % (i + 1), 0.0)))
					return {"length": float(held.get("length", 8.0)), "values": values}
			return {"length": 8.0, "values": []}
		lane.paint_started.connect(func() -> void: _begin_edit())
		lane.step_painted.connect(func(index: int, value: float) -> void:
			_set_parameter(lane_id, "step%d" % (index + 1), value))
		lane.paint_finished.connect(func() -> void: _commit_edit("draw steps"))
		lane_line.add_child(lane)
		widget.add_child(lane_line)
		# Not through _fit_row_height: that helper hides any slotless row without
		# parameter cells, and this row's whole job is to be the thing it carries.

	# What each slot carries, so its socket can be re-cut in a new style without taking
	# the node apart. Read back from the widget rather than from the document because
	# this is a fact about the built rows, and the rows are what have slots.
	var left_types := PackedStringArray()
	var right_types := PackedStringArray()
	for slot in maxi(inputs.size(), outputs.size()):
		left_types.append(str(inputs[slot]["type"]) if slot < inputs.size() else "")
		right_types.append(str(outputs[slot]["type"]) if slot < outputs.size() else "")
	widget.set_meta("left_types", left_types)
	widget.set_meta("right_types", right_types)

	_add_ghost_ports(widget, str(node["id"]), descriptor)

	graph_edit.add_child(widget)
	# Dressed last, and after the node is in the tree rather than merely built.
	#
	# Twice now this has been too early. Before the rows were added it painted a node
	# with nothing written on it; before add_child it still missed every value readout,
	# because ValueField builds the Label inside it in _ready and _ready does not run
	# until the node has a parent. Both times a fresh graph came up in the editor's ink
	# and took its lettering at the next repaint, which looks exactly like a style that
	# did not apply.
	_style_widget(widget, str(node["id"]))
	# Deferred, because the honest minimums need the tree: an OptionButton measured
	# before the theme reaches it reports the fallback theme's width, and a column
	# sized to that lie is a column that falls back out of register one frame later.
	_size_cell_columns.call_deferred(widget)
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

	# No category tag beside the title. It shared the bar as "KEYBOARD  Terminals",
	# "ENVELOPE  Modulation" — the smallest text on the node saying the least
	# important thing on it, and the reader asked for it gone. The category still
	# does its work where somebody is choosing a node: the Add-node search and the
	# descriptor keep it; the panel legend does not repeat it.


## A small texture per signal type, drawn once and shared.
##
## Filled circle for audio, diamond for control, square for event, ring for note. The port
## you see stays around 10px; the region that accepts a drag is set far larger by the
## GraphEdit hotzone constants, so this is about telling the types apart, not about aim.
static var _port_icons: Dictionary = {}

func _port_icon(type_name: String, key: String = ModuleThemes.CATEGORY) -> Texture2D:
	var cached := "%s/%s" % [type_name, key]
	if _port_icons.has(cached):
		return _port_icons[cached]

	# A socket mounted in the panel, on every node — painted or not.
	#
	# The grammar used to arrive with the faceplate: painted modules got sockets and
	# the unpainted graph kept flat type-shapes, which was defensible while the cables
	# were flat too. The cords ended that. A cord entering a flat diamond is exactly
	# the decorated-connection-point read the socket exists to kill, and the cable
	# reference sheet draws its grommets on an unpainted panel for the same reason. An
	# unpainted node now wears a steel grommet — the rack's own hardware colours — and
	# a painted one wears its theme's ring, so the difference paint makes is the trim,
	# never the grammar.
	#
	# The signal type is still carried by a shape: it moves from being the whole port
	# to being the pip in the mouth of one, which is how the type survives a
	# colour-blind reader, a greyscale printout and a projector that has given up on
	# saturation. This is the icon only — GraphEdit centres it on the slot anchor, so
	# nothing about the row, the port position or the cable moves.
	const SIZE := 26
	var image := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))
	var colour: Color = TYPE_COLOURS.get(type_name, Design.INK_NORMAL)
	var centre := Vector2(SIZE * 0.5 - 0.5, SIZE * 0.5 - 0.5)

	var painted := key != ModuleThemes.CATEGORY
	var skin := Rack.skin(key)
	var ring: Color = skin.get("ring", Color(0.7, 0.7, 0.7)) if painted \
		else Rack.JACK_RING
	var hole: Color = skin.get("jack", Color(0.07, 0.07, 0.07)) if painted \
		else Rack.JACK_HOLE
	var nut := ring.darkened(0.55)
	# The seat takes the editor surface rather than a constant, so switching palettes
	# re-cuts the icon — which is also what the suite checks.
	var shade: Color = Design.SURFACES[Design.Surface.NODE].darkened(0.35)

	# Four rings, and the money is in the middle two: the hole, the collar, the wide
	# top-lit nut, and the seat. The nut band widened in the grommet pass — the metal
	# is what says "hardware", and at the old two pixels of band it said "border".
	const RIM := 12.6
	const NUT := 11.2
	const RING := 8.0
	const HOLE := 5.8
	for y in SIZE:
		for x in SIZE:
			var point := Vector2(x, y) - centre
			var distance := point.length()
			if distance > RIM:
				continue
			# Lit from the top left, like everything else on these panels: the metal
			# lifts where it faces the light and drops where it turns away.
			var lift: float = clampf(-(point.x + point.y) / 22.0, -0.28, 0.32)
			var fill := shade
			if distance <= HOLE:
				fill = hole
			elif distance <= RING:
				fill = ring.lightened(maxf(lift, 0.0)) if lift > 0.0 \
					else ring.darkened(-lift)
			elif distance <= NUT:
				fill = nut.lightened(maxf(lift, 0.0)) if lift > 0.0 \
					else nut.darkened(-lift)
			# The pip: the signal's own shape in the signal's own colour, sitting in
			# the mouth of the socket.
			var pip := 0.0
			match type_name:
				"control":
					pip = absf(point.x) + absf(point.y)
				"event":
					pip = maxf(absf(point.x), absf(point.y)) * 1.35
				_:
					pip = distance
			# 3.6, up from 3.0: at three pixels a diamond and a circle differ by eight
			# pixels of corner, which is a shape distinction in name only — and the pip
			# is the whole of how a signal type reaches a colour-blind reader.
			if pip <= 3.6 and not (type_name == "note" and pip < 1.9):
				fill = colour
			image.set_pixel(x, y, Color(fill.r, fill.g, fill.b,
				clampf(RIM - distance, 0.0, 1.0)))

	var texture := ImageTexture.create_from_image(image)
	_port_icons[cached] = texture
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
	name_label.text = Rack.face_text(port)
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
	# A labelled port prints its label and nothing else. The unit was the half of
	# "fm octaves" that made the row read as an identifier with its type exposed; the
	# doc already says what the wire is measured in, and the readouts keep their units
	# where a number needs one.
	var unit := str(port.get("unit", ""))
	if unit != "" and not port.has("label"):
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


## ---- face edit ---------------------------------------------------------------------
## The mode where the graph is a fitting room: clicking a knob cell puts that
## parameter on the document's face or takes it off, and the overlay lights the
## frames of what the face is wearing. Ports are shown but not toggled — a port is
## on the plates because its seam exists, so the wand is the tool that moves them.

## Dressing the face is done from the wiring, so turning it on turns the schematic off.
##
## The two are not compatible and never were: face edit works by clicking the knobs on
## the nodes, and the schematic hides the nodes. Left to themselves they would produce a
## mode that is lit and does nothing, which is worse than a mode that is unavailable.
func _set_face_edit(on: bool) -> void:
	if on and schematic_up:
		await _show_schematic(false)
	# Same reasoning as the schematic: the knobs you click to dress a face are the ones
	# on the nodes, and the face is covering them.
	if on and graph_edit.face_up:
		await _flip_container(false)
	graph_edit.face_edit = on
	graph_edit.face_edit_on = on
	if on:
		_refresh_face_edit_badges()
	_say("face edit: %s" % ("on — click a knob to dress the face" if on else "off"))


func _on_face_cell_toggled(node_id: String, parameter_name: String) -> void:
	if node_id == "" or parameter_name == "":
		return
	_begin_edit()
	if not patch.has("controls"):
		patch["controls"] = []
	var controls: Array = patch["controls"]
	var removed := false
	for index in range(controls.size() - 1, -1, -1):
		var target: Dictionary = (controls[index] as Dictionary).get("target", {})
		if str(target.get("node", "")) == node_id \
				and str(target.get("parameter", "")) == parameter_name:
			controls.remove_at(index)
			removed = true
	if not removed:
		controls.append(_face_control_entry(node_id, parameter_name))
	_commit_edit("face: %s %s" % ["remove" if removed else "add", parameter_name])
	rack.rebuild()
	_refresh_face_edit_badges()
	_say("%s %s the face" % [parameter_name, "leaves" if removed else "joins"])


## A port click in face edit exposes or trims a seam — the same toggle the knob
## cells have, in plate terms. On a seam node any port is the seam itself: the
## click takes the whole seam out, wires and all. On a regular node, a port a seam
## is already serving gets unplugged from it (and a seam left serving nothing goes
## too); a bare port gets a fresh seam named after it, wired in, placed beside the
## node, unbound — the seam dock is where a binding is chosen. One undo step each.
func _on_face_port_toggled(widget_name: String, side: String, index: int) -> void:
	var node_id: String = ids.get(widget_name, "")
	if node_id == "":
		return
	var node: Dictionary = {}
	for candidate in patch.get("nodes", []):
		if str(candidate.get("id", "")) == node_id:
			node = candidate
			break
	var ports := _port_list(node_id, "inputs" if side == "left" else "outputs")
	if index >= ports.size():
		return
	var port_name := str(ports[index]["name"])
	var node_type := str(node.get("type", ""))

	_begin_edit()
	if node_type in ["Input", "Output"]:
		_drop_seam(node_id)
		_commit_edit("trim seam %s" % node_id)
		_say("seam %s trimmed from the face" % node_id)
	else:
		var serving := _seam_serving(node_id, port_name, side)
		if serving != "":
			var trimmed := _unplug_seam(serving, node_id, port_name, side)
			_commit_edit("trim seam %s" % serving)
			_say("%s unplugged from %s%s" % [port_name, serving,
				", and the empty seam went with it" if trimmed else ""])
		else:
			var seam_id := _expose_seam(node, port_name, side)
			_commit_edit("expose %s" % port_name)
			_say("%s exposed on the face as %s" % [port_name, seam_id])
	await _rebuild_and_apply()
	_refresh_face_edit_badges()


## The seam wired to this exact port, or "".
func _seam_serving(node_id: String, port_name: String, side: String) -> String:
	var seam_ids := {}
	for node in patch.get("nodes", []):
		if str(node.get("type", "")) in ["Input", "Output"]:
			seam_ids[str(node["id"])] = true
	for connection in patch.get("connections", []):
		if side == "left" and str(connection["to"]["node"]) == node_id \
				and str(connection["to"]["port"]) == port_name \
				and seam_ids.has(str(connection["from"]["node"])):
			return str(connection["from"]["node"])
		if side == "right" and str(connection["from"]["node"]) == node_id \
				and str(connection["from"]["port"]) == port_name \
				and seam_ids.has(str(connection["to"]["node"])):
			return str(connection["to"]["node"])
	return ""


## Takes a seam node out entirely, with every wire it carried.
func _drop_seam(seam_id: String) -> void:
	var kept_nodes: Array = []
	for node in patch.get("nodes", []):
		if str(node.get("id", "")) != seam_id:
			kept_nodes.append(node)
	patch["nodes"] = kept_nodes
	var kept: Array = []
	for connection in patch.get("connections", []):
		if str(connection["from"]["node"]) != seam_id \
				and str(connection["to"]["node"]) != seam_id:
			kept.append(connection)
	patch["connections"] = kept


## Unplugs one port from the seam serving it; a seam left with no wires at all is
## taken out too. Returns whether the seam itself went.
func _unplug_seam(seam_id: String, node_id: String, port_name: String,
		side: String) -> bool:
	var kept: Array = []
	for connection in patch.get("connections", []):
		var mine: bool
		if side == "left":
			mine = str(connection["from"]["node"]) == seam_id \
				and str(connection["to"]["node"]) == node_id \
				and str(connection["to"]["port"]) == port_name
		else:
			mine = str(connection["to"]["node"]) == seam_id \
				and str(connection["from"]["node"]) == node_id \
				and str(connection["from"]["port"]) == port_name
		if not mine:
			kept.append(connection)
	patch["connections"] = kept
	for connection in patch["connections"]:
		if str(connection["from"]["node"]) == seam_id \
				or str(connection["to"]["node"]) == seam_id:
			return false
	_drop_seam(seam_id)
	return true


## A fresh seam for a bare port: named after the port, placed beside its node on
## the grid, wired in. Returns the seam's id.
func _expose_seam(node: Dictionary, port_name: String, side: String) -> String:
	var taken := {}
	for other in patch.get("nodes", []):
		taken[str(other.get("id", ""))] = true
	var seam_id := port_name
	var suffix := 2
	while taken.has(seam_id):
		seam_id = "%s_%d" % [port_name, suffix]
		suffix += 1
	var at: Dictionary = node.get("position", {"x": 0.0, "y": 0.0})
	var seam_x: float = float(at.get("x", 0.0)) + (-440.0 if side == "left" else 440.0)
	var seam_y: float = float(at.get("y", 0.0))
	# Not on top of somebody: a seam born exactly on another node reads as a fault.
	# Positions are all the document records, so the dodge is coarse — step down a
	# couple of rows until the nearest node is a comfortable stride away.
	var crowded := true
	while crowded:
		crowded = false
		for other in patch.get("nodes", []):
			var spot: Dictionary = other.get("position", {})
			if absf(float(spot.get("x", 1.0e9)) - seam_x) < 320.0 \
					and absf(float(spot.get("y", 1.0e9)) - seam_y) < 200.0:
				crowded = true
				seam_y += 200.0
				break
	var seam := {
		"id": seam_id,
		"type": "Input" if side == "left" else "Output",
		"position": {"x": seam_x, "y": seam_y},
	}
	patch["nodes"].append(seam)
	var node_id := str(node.get("id", ""))
	if side == "left":
		patch["connections"].append({
			"from": {"node": seam_id, "port": "out"},
			"to": {"node": node_id, "port": port_name},
		})
	else:
		patch["connections"].append({
			"from": {"node": node_id, "port": port_name},
			"to": {"node": seam_id, "port": "in"},
		})
	return seam_id


## A face control built from what the graph already knows: the parameter's own
## descriptor supplies the range and scaling, the node's current value becomes the
## default, and the id stays out of the way of every control already there.
func _face_control_entry(node_id: String, parameter_name: String) -> Dictionary:
	var node: Dictionary = {}
	for candidate in patch.get("nodes", []):
		if str(candidate.get("id", "")) == node_id:
			node = candidate
			break
	var descriptor: Dictionary = {}
	for parameter in registry.get(_type_key(node), {}).get("parameters", []):
		if str(parameter.get("name", "")) == parameter_name:
			descriptor = parameter
			break
	var taken := {}
	for control: Dictionary in patch.get("controls", []):
		taken[str(control.get("id", ""))] = true
	var identity := "%s_%s" % [node_id, parameter_name]
	var suffix := 2
	while taken.has(identity):
		identity = "%s_%s_%d" % [node_id, parameter_name, suffix]
		suffix += 1
	return {
		"id": identity,
		"label": parameter_name.capitalize(),
		"kind": "knob",
		"target": {"node": node_id, "parameter": parameter_name},
		"min": descriptor.get("min", 0.0),
		"max": descriptor.get("max", 1.0),
		"default": node.get("parameters", {}).get(parameter_name,
			descriptor.get("default", 0.0)),
		"scaling": descriptor.get("scaling", "linear"),
	}


## Writes what the face is wearing onto the widgets, where the overlay reads it:
## "on_face" on each knob cell, "face_seam" on the widgets whose ports are plates.
func _refresh_face_edit_badges() -> void:
	var worn := {}
	for control: Dictionary in patch.get("controls", []):
		var target: Dictionary = control.get("target", {})
		worn["%s|%s" % [target.get("node", ""), target.get("parameter", "")]] = true
	var seams := {}
	for node in patch.get("nodes", []):
		if str(node.get("type", "")) in ["Input", "Output"]:
			seams[str(node["id"])] = true
	# The ports a seam is serving on regular nodes, as "left:N"/"right:N" per node,
	# so the overlay rings exactly where the next click would trim.
	var served := {}
	for connection in patch.get("connections", []):
		var from_id := str(connection["from"]["node"])
		var to_id := str(connection["to"]["node"])
		if seams.has(from_id) and not seams.has(to_id):
			var inputs := _port_list(to_id, "inputs")
			for index in inputs.size():
				if str(inputs[index]["name"]) == str(connection["to"]["port"]):
					if not served.has(to_id):
						served[to_id] = {}
					served[to_id]["left:%d" % index] = true
		if seams.has(to_id) and not seams.has(from_id):
			var outputs := _port_list(from_id, "outputs")
			for index in outputs.size():
				if str(outputs[index]["name"]) == str(connection["from"]["port"]):
					if not served.has(from_id):
						served[from_id] = {}
					served[from_id]["right:%d" % index] = true
	for id in widgets:
		var widget: GraphNode = widgets[id]
		widget.set_meta("face_seam", seams.has(str(id)))
		widget.set_meta("face_served", served.get(str(id), {}))
		for child in widget.get_children():
			var line := child as Control
			if line == null or not line.has_meta("cells_box"):
				continue
			for cell_child in (line.get_meta("cells_box") as Control).get_children():
				var cell := cell_child as Control
				if cell == null:
					continue
				cell.set_meta("on_face", worn.has("%s|%s"
					% [id, cell.get_meta("parameter_name", "")]))


## One width per column of cells, so the knobs stack on shared axes.
##
## A cell used to be as wide as its own contents, and each row centres its cells as
## a group — so a row holding a wide dropdown packed its neighbour a few pixels
## differently than the all-knob row below it, and the rate dial sat visibly off
## the amount dial's axis. A column is as wide as its widest cell — per column, not
## per node, so the node grows no wider than its widest row already made it — and
## the centring zones and full-width captions absorb the difference inside each
## cell.
func _size_cell_columns(widget: GraphNode) -> void:
	if not is_instance_valid(widget):
		return
	var columns: Array[float] = []
	var rows: Array = []
	# The flanks count as much as the cells: a row's knob group is centred in the
	# room its port labels leave, so a row flanked by "rate Hz" and a row flanked by
	# nothing centred their knobs over different spans — equal cell widths alone
	# still left the dials off axis. Every cell row gets the widest flank on each
	# side, so every row's group is centred over the same span.
	var left_flank := 0.0
	var right_flank := 0.0
	var flanks: Array = []
	for child in widget.get_children():
		var line := child as Control
		if line == null or not line.has_meta("cells_box"):
			continue
		var box: Control = line.get_meta("cells_box")
		var cells: Array = box.get_children()
		if cells.is_empty():
			continue
		rows.append(cells)
		var before_cells := true
		for part in line.get_children():
			var side := part as Control
			if side == box:
				before_cells = false
				continue
			if side == null or not side.has_meta("port_label"):
				continue
			# Measured over the content, not over what a previous pass pinned — a
			# rebuilt row must be able to shrink back as well as grow.
			side.custom_minimum_size.x = 0.0
			var side_need: float = side.get_combined_minimum_size().x
			if before_cells:
				left_flank = maxf(left_flank, side_need)
			else:
				right_flank = maxf(right_flank, side_need)
			flanks.append([side, before_cells])
		for index in cells.size():
			var cell := cells[index] as Control
			if cell == null:
				continue
			cell.custom_minimum_size.x = 0.0
			var need: float = cell.get_combined_minimum_size().x
			if index >= columns.size():
				columns.append(need)
			else:
				columns[index] = maxf(columns[index], need)
	for entry in flanks:
		(entry[0] as Control).custom_minimum_size.x = left_flank if entry[1] else right_flank
	for cells in rows:
		for index in cells.size():
			var cell := cells[index] as Control
			if cell != null:
				cell.custom_minimum_size.x = columns[index]


## One line of numerals, the height every cell's value slot shares.
func _numeric_line_height() -> float:
	var font := Design.numeric_font()
	return font.get_height(Design.type(Design.SIZE_NUMERIC)) if font != null else 0.0


## The top slot of every parameter cell: a fixed-height box with the control centred
## in it. The height is the compact knob's whatever the control actually is — a
## dropdown is shorter than a dial, and left to their own heights the two kinds of
## cell floated at different centres with their captions on different lines, which
## is the "nothing quite lines up" a mixed row used to show.
func _control_zone(control: Control) -> Control:
	var zone := CenterContainer.new()
	zone.custom_minimum_size.y = maxf(Rack.knob_radius() * 2.0 + 8.0,
		Design.scale(Design.HIT_TARGET))
	zone.set_meta("control_zone", true)
	zone.add_child(control)
	return zone


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
	# And whose knob it is, so face edit can name the target from the cell alone.
	row.set_meta("node_id", str(node["id"]))
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
		if str(parameter.get("display_name", "")) != "" else Rack.face_text(parameter)
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
		row.add_child(_control_zone(_defocus(options)))
		row.add_child(label)
		# The value line an enum cell would not otherwise have. Empty at full detail
		# — the dropdown already says which option — but present, so an enum cell is
		# the same three-line skeleton as a knob cell and a mixed row's captions sit
		# on one baseline instead of each cell centring its own shorter stack.
		var chosen_line := Control.new()
		chosen_line.custom_minimum_size.y = _numeric_line_height()
		chosen_line.mouse_filter = Control.MOUSE_FILTER_IGNORE
		chosen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		chosen_line.add_child(chosen)
		row.add_child(chosen_line)
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
	# Seventy-two pixels, which is not wide enough for every reading this can show and
	# is left alone deliberately.
	#
	# "0.000 semitones" is half as wide again and prints past its cell into whatever
	# slack its neighbours are carrying — which, at two knobs to a line, there always is.
	# Reserving the true width fixes the overflow and widens every cell holding a long
	# unit, and four of the shipped Game examples then open with their nodes overlapping.
	# The overflow is latent at this packing and the fix is not, so it belongs with the
	# composition work that would move those columns, not ahead of it.
	readout.custom_minimum_size.x = Design.scale(72)
	readout.centred = true
	readout.text = _format_with_unit(parameter, current)
	readout.default_value = _knob_home(node_id, name, float(parameter["default"]))
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
	row.add_child(_control_zone(_defocus(slider)))
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
	# Voices is structural: the engine only grows or sheds voice copies on a
	# rebuild, so the live set below cannot express it. The commit that ends this
	# gesture rebuilds instead.
	if parameter == "voices":
		_voices_touched = true
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


## The value a control's target currently holds in the document, for the bank.
func _current_parameter(node_id: String, parameter: String, fallback: float) -> float:
	for node in patch.get("nodes", []):
		if str(node["id"]) == node_id:
			return float(node.get("parameters", {}).get(parameter, fallback))
	return fallback


## Turns the bank to one page: the face resolved which parameters the page
## means — its own nodes or an instance's exports — and this writes them, as
## one undo step. A control the preset does not mention keeps its position, the
## way hardware leaves unswept knobs where they stand.
func _apply_preset(index: int, writes: Array, face: Control, bank: String) -> void:
	var presets: Array = face.patch.get("presets", [])
	if index < 0 or index >= presets.size():
		return
	var name := str((presets[index] as Dictionary).get("name", "preset"))
	_begin_edit()
	for write in writes:
		# The knob path, not a bare document write: engine, document and the
		# graph view's widgets all move together.
		_on_rack_parameter_changed(str(write.get("node", "")),
			str(write.get("parameter", "")), float(write.get("value", 0.0)))
	_commit_edit("preset %s" % name)
	preset_pages[bank] = index
	face.preset_index = index
	# A page turn changes values, never structure, so the faces refresh in place.
	# The full view rebuild this used to do put an async gap between click and
	# strip, and a second click in that gap landed on a freed button — which is
	# what "next doesn't work consistently" feels like from the chair.
	_apply_flips()
	_refresh_face()
	_say("preset: %s" % name)


## The morph slider mid-drag: the interpolated surface, written live through
## the knob path. The undo bracket is the drag's, so a whole sweep is one step.
func _write_morph(writes: Array) -> void:
	for write in writes:
		_on_rack_parameter_changed(str(write.get("node", "")),
			str(write.get("parameter", "")), float(write.get("value", 0.0)))


## Gives one page of a bank a new name — the patch's own bank, or the module
## definition's for a device. A name is a performance direction, and this is
## how a bank stops being a list of Preset 7s.
func _rename_preset(index: int, wanted: String, face: Control, bank_module: String) -> void:
	var store: Dictionary = patch if bank_module == "" 		else patch.get("modules", {}).get(bank_module, {})
	var presets: Array = store.get("presets", [])
	if wanted == "" or index < 0 or index >= presets.size():
		return
	var was := str((presets[index] as Dictionary).get("name", ""))
	if wanted == was:
		return
	_begin_edit()
	(presets[index] as Dictionary)["name"] = wanted
	_commit_edit("rename preset to %s" % wanted)
	_apply_flips()
	_refresh_face()
	_say("preset renamed: %s" % wanted)


## Where an index lands after a page moves from one slot to another.
func _index_after_move(tracked: int, from_index: int, to_index: int) -> int:
	if tracked == from_index:
		return to_index
	if from_index < tracked and tracked <= to_index:
		return tracked - 1
	if to_index <= tracked and tracked < from_index:
		return tracked + 1
	return tracked


## Moves one page to a new slot: the set order, in the set's own hands. The
## showing page and deck B both follow the page they were pointing at.
func _reorder_preset(from_index: int, to_index: int, face: Control,
		bank_module: String) -> void:
	var store: Dictionary = patch if bank_module == "" \
		else patch.get("modules", {}).get(bank_module, {})
	var presets: Array = store.get("presets", [])
	if from_index == to_index or from_index < 0 or to_index < 0 \
			or from_index >= presets.size() or to_index >= presets.size():
		return
	_begin_edit()
	var moving: Dictionary = presets.pop_at(from_index)
	presets.insert(to_index, moving)
	_commit_edit("move %s in the bank" % str(moving.get("name", "preset")))
	var showing := int(preset_pages.get(bank_module, -1))
	if showing >= 0:
		preset_pages[bank_module] = _index_after_move(showing, from_index, to_index)
	face.preset_index = int(preset_pages.get(bank_module, face.preset_index))
	if int(face.morph_b) >= 0:
		face.morph_b = _index_after_move(int(face.morph_b), from_index, to_index)
	_apply_flips()
	_refresh_face()
	_say("moved %s" % str(moving.get("name", "")))


## Strikes one page from the bank, as one undo step. The showing page slides
## to keep naming the same sound; striking the showing page leaves no page
## showing, which is the truth.
func _delete_preset(index: int, face: Control, bank_module: String) -> void:
	var store: Dictionary = patch if bank_module == "" \
		else patch.get("modules", {}).get(bank_module, {})
	var presets: Array = store.get("presets", [])
	if index < 0 or index >= presets.size():
		return
	_begin_edit()
	var gone: Dictionary = presets.pop_at(index)
	_commit_edit("remove %s from the bank" % str(gone.get("name", "preset")))
	var showing := int(preset_pages.get(bank_module, -1))
	if showing == index:
		preset_pages[bank_module] = -1
	elif showing > index:
		preset_pages[bank_module] = showing - 1
	face.preset_index = int(preset_pages.get(bank_module, -1))
	if int(face.morph_b) == index:
		face.morph_b = -1
		face.morph_b_picked = false
	elif int(face.morph_b) > index:
		face.morph_b = int(face.morph_b) - 1
	_apply_flips()
	_refresh_face()
	_say("removed %s" % str(gone.get("name", "")))


## Writes a face's current positions into its bank as a new page — the patch's
## own bank, or the module definition's when the face belongs to a device.
func _save_preset(values: Dictionary, face: Control, bank_module: String) -> void:
	_begin_edit()
	var store: Dictionary = patch if bank_module == "" 		else patch.get("modules", {}).get(bank_module, {})
	if store.is_empty():
		_commit_edit("save preset")
		return
	if not store.has("presets"):
		store["presets"] = []
	var page := (store["presets"] as Array).size() + 1
	store["presets"].append({"name": "Preset %d" % page, "values": values})
	_commit_edit("save preset")
	preset_pages[bank_module] = (store["presets"] as Array).size() - 1
	face.preset_index = (store["presets"] as Array).size() - 1
	_apply_flips()
	_refresh_face()
	# Straight into the name field: a fresh page called "Preset 7" is a map
	# with no street name, and the moment of saving is the moment the sound's
	# direction is clearest in the mind of whoever shaped it.
	face.rename_showing()
	_say("saved preset %d" % page)


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
	if node_id != "":
		selected_module = node_id
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
	selected_module = node_id
	var outputs := _port_list(node_id, "outputs")
	inspecting = {"node": node_id, "port": outputs[0]["name"]} if not outputs.is_empty() \
		else {}
	_refresh_context()


func _on_keyboard_pressed(note: int) -> void:
	_hold_note(note)


func _on_keyboard_released(note: int) -> void:
	_let_go_note(note)


## The full descriptor a control means: the registry's parameter overlaid with
## the control's own curation — the same rule the face's knobs draw by, needed
## here so a CC's 0..127 maps through the right range and scaling.
func _control_descriptor(control: Dictionary) -> Dictionary:
	var target: Dictionary = control.get("target", {})
	var descriptor: Dictionary = {}
	for node in patch.get("nodes", []):
		if str(node["id"]) != str(target.get("node", "")):
			continue
		for parameter in registry.get(Seams.registry_key(node), {}).get("parameters", []):
			if str(parameter["name"]) == str(target.get("parameter", "")):
				descriptor = (parameter as Dictionary).duplicate(true)
		break
	if descriptor.is_empty():
		return {}
	for curated in ["min", "max", "default", "scaling"]:
		if control.has(curated):
			descriptor[curated] = control[curated]
	return descriptor


## Ctrl-click on a face knob landed here: arm the learn, if the knob is on the
## file's face. The next CC the hardware sends becomes the binding.
func _on_learn_requested(node_id: String, parameter: String) -> void:
	for control in patch.get("controls", []):
		var target: Dictionary = control.get("target", {})
		if str(target.get("node", "")) == node_id \
				and str(target.get("parameter", "")) == parameter:
			_learning = {"id": str(control.get("id", ""))}
			_say("MIDI learn: move a controller knob to bind %s — Escape cancels"
				% str(control.get("label", control.get("id", ""))))
			return
	_say("that knob is not on the file's face, so there is nothing to bind")


## A MidiCC node's Learn button landed here: the next CC the hardware sends
## becomes the node's controller number.
## Offers what this machine has, and writes the choice into the patch.
##
## The scan is remembered for the session because it opens every plugin installed, which
## is slow and is the one part of this feature that can misbehave — it happens in
## sg-host, out of process, so the worst a bad plugin can do to the editor is fail to
## appear in a list.
func _choose_plugin_for(node_id: String) -> void:
	if _plugin_scan.is_empty():
		_plugin_scan = PluginPicker.scan()
	if _plugin_scan.is_empty():
		if PluginPicker.host_path() == "":
			_say("No plugin scanner here — this build has no sg-host to ask.")
		else:
			_say("No VST3 or CLAP plugins found on this machine.")
		return

	var dialog := ConfirmationDialog.new()
	dialog.title = "Choose a plugin"
	dialog.ok_button_text = "Use this one"
	var list := ItemList.new()
	list.custom_minimum_size = Vector2(420, 320)
	for entry in _plugin_scan:
		var vendor := str(entry.get("vendor", ""))
		var label := str(entry["name"]) + ("" if vendor == "" else "  —  " + vendor)
		list.add_item(label + "   [" + str(entry["format"]) + "]")
	dialog.add_child(list)
	dialog.confirmed.connect(func() -> void:
		var picked := list.get_selected_items()
		if not picked.is_empty():
			_use_plugin(node_id, _plugin_scan[picked[0]])
		dialog.queue_free())
	dialog.canceled.connect(func() -> void: dialog.queue_free())
	add_child(dialog)
	dialog.popup_centered()


## Asks every hosted plugin in the running graph what it currently considers itself.
##
## Called before a reload and before a save, which are the only two moments the answer is
## needed. Not on a timer: assembling a preset is real work — Surge XT's is fifty
## kilobytes — and a plugin has better things to do between frames.
func _capture_plugin_states() -> void:
	if engine == null or not engine.is_loaded() or not engine.can_host_plugins():
		return
	for node in patch.get("nodes", []):
		var key := str(node.get("plugin", ""))
		if key == "":
			continue
		var captured: String = engine.plugin_state(str(node.get("id", "")))
		if captured == "":
			continue
		if captured.length() > MAX_PLUGIN_STATE_CHARS:
			# Refused rather than truncated: half a preset is not a smaller preset, it is
			# a corrupt one, and a plugin handed it may do anything at all.
			_plugin_states.erase(key)
			_say("%s keeps more state than a patch can carry (%d KB) — it will open at its defaults."
				% [key, captured.length() / 1024])
			continue
		_plugin_states[key] = captured


## The patch as text, with each plugin's captured state written into it.
##
## A copy, always: the document itself never carries state between an edit and a save,
## because a plugin quietly rewriting the patch on every graph change would make every
## edit look like two.
func _patch_text_with_plugin_states() -> String:
	if _plugin_states.is_empty():
		return JSON.stringify(patch, "  ")
	var copy: Dictionary = patch.duplicate(true)
	var table: Dictionary = copy.get("plugins", {})
	for key in table.keys():
		if _plugin_states.has(key):
			table[key]["state"] = _plugin_states[key]
	copy["plugins"] = table
	return JSON.stringify(copy, "  ")


## Opens the plugin's own panel for a node, in a window of its own.
##
## One at a time: the editor has one place to put such a window, and a second press is
## much more likely to mean "show me this one" than "show me both".
func _open_plugin_face(node_id: String) -> void:
	if engine == null or not engine.is_loaded():
		_say("The graph is not running, so there is no plugin to show.")
		return
	if not engine.plugin_has_gui(node_id):
		# Three different situations, deliberately one sentence: the node names no
		# plugin, the plugin is not on this machine, or it genuinely has no panel. The
		# first two already say so elsewhere — a missing plugin is a diagnostic on the
		# node — so repeating them here would only be louder, not clearer.
		_say("No panel to show: either the plugin is not on this machine, or it draws none.")
		return

	_close_plugin_face()

	# Godot draws its own subwindows inside the main viewport by default, and an
	# embedded subwindow has no operating-system window behind it — nothing to lend.
	# Turned off for as long as a panel is open, and put back after, because the rest of
	# this editor's dialogs were designed embedded and look wrong as loose windows.
	_subwindows_were_embedded = get_tree().root.gui_embed_subwindows
	get_tree().root.gui_embed_subwindows = false

	var name := node_id
	var chosen := ""
	for node in patch.get("nodes", []):
		if str(node.get("id", "")) == node_id:
			chosen = str(node.get("plugin", ""))
	if chosen != "":
		name = str(patch.get("plugins", {}).get(chosen, {}).get("name", node_id))

	var face: Window = PluginWindow.new()
	face.setup(engine, node_id, name)
	face.attach_failed.connect(func(reason: String) -> void:
		_say(reason)
		_close_plugin_face())
	# The window can also go without this editor being asked — the user closes it. The
	# embedding setting has to come back either way, so the tidying hangs off the window
	# actually leaving rather than off any one of the ways it can be told to.
	face.tree_exited.connect(_plugin_face_gone)
	_plugin_face = face
	add_child(face)
	face.move_to_center()


## Puts any open plugin panel away.
##
## Called wherever the graph is about to be replaced or dropped. load_patch() acquires
## new plugin instances, so the panel would otherwise be showing a plugin that no longer
## exists — and closing it is not reopening it: the new graph may not have that node.
## `announce` when the closing is a side effect of something else the user did, because
## a panel that vanishes on its own is a bug until it is explained.
func _close_plugin_face(announce: bool = false) -> void:
	if _plugin_face == null:
		return
	if is_instance_valid(_plugin_face):
		_plugin_face.hide()
		_plugin_face.queue_free()
		if announce:
			_say("Editing the graph reloads the plugin, so its panel closed.")
	_plugin_face = null


## After the panel has genuinely gone, whichever way it went.
##
## Separate from closing it because freeing is deferred: Godot refuses to change the
## embedding setting while a child window is still displayed, so restoring it in the same
## breath as queue_free() prints a warning and does nothing. This runs on tree_exited,
## which is late enough.
func _plugin_face_gone() -> void:
	_plugin_face = null
	if get_tree() != null:
		get_tree().root.gui_embed_subwindows = _subwindows_were_embedded


## Writes a chosen plugin into the patch: one table entry, one node field, one undo step.
func _use_plugin(node_id: String, entry: Dictionary) -> void:
	_begin_edit()
	var table: Dictionary = patch.get("plugins", {})
	var key := PluginPicker.table_key(entry)
	# One entry per node, even when two nodes name the same plugin.
	#
	# This used to reuse an existing entry for the same identity, on the grounds that a
	# patch should not accumulate near-identical rows. That was an argument about
	# tidiness, and state settles it against them: an entry carries the plugin's own
	# preset and its slot bindings, so two Surges sharing one row cannot have two
	# different sounds — and two Surges with two different sounds is the whole reason a
	# patch has two of them. An entry is an instance, not a kind.
	var unique := key
	var n := 2
	while table.has(unique):
		unique = key + "-" + str(n)
		n += 1
	table[unique] = PluginPicker.table_entry(entry)
	var existing := unique
	patch["plugins"] = table
	var replaced := ""
	for node in patch.get("nodes", []):
		if str(node.get("id", "")) == node_id:
			replaced = str(node.get("plugin", ""))
			node["plugin"] = existing
			break
	# One entry per node cuts both ways: changing a node's mind leaves the old row behind
	# unless somebody sweeps it, and a patch that grows a dead plugin entry every time
	# the user browses is worse than the duplicates this replaced.
	if replaced != "" and replaced != existing:
		var still_used := false
		for node in patch.get("nodes", []):
			if str(node.get("plugin", "")) == replaced:
				still_used = true
				break
		if not still_used:
			table.erase(replaced)
			_plugin_states.erase(replaced)
	# Schema 4 is where a patch may name a plugin; a reader that predates it must refuse
	# rather than quietly drop the node that makes the sound.
	patch["schema_version"] = maxi(int(patch.get("schema_version", 1)), 4)
	_commit_edit("choose %s" % str(entry.get("name", "plugin")))
	_apply()
	_say("%s plays through %s now" % [node_id, str(entry.get("name", "the plugin"))])


## Says which of the plugin's own controls each slot drives.
##
## Sixteen rows because there are sixteen slots, each an ordinary control input once it
## is bound — which is the point of the feature: an LFO modulating a stranger's synth
## needs no special case anywhere.
func _bind_plugin_slots(node_id: String) -> void:
	var chosen := ""
	for node in patch.get("nodes", []):
		if str(node.get("id", "")) == node_id:
			chosen = str(node.get("plugin", ""))
			break
	var table: Dictionary = patch.get("plugins", {})
	if chosen == "" or not table.has(chosen):
		return
	var entry: Dictionary = table[chosen]

	# The parameter list comes from the scan, matched by identity — the patch remembers
	# what the plugin is, not what its knobs are called.
	var parameters: Array = []
	for scanned in _plugin_scan:
		if str(scanned.get("identity", "")) == str(entry.get("identity", "")):
			parameters = scanned.get("parameters", [])
			break
	if parameters.is_empty():
		_say("Rescan needed: this machine has not been asked what %s offers."
			% str(entry.get("name", chosen)))
		return

	var dialog := ConfirmationDialog.new()
	dialog.title = "Slots on " + str(entry.get("name", chosen))
	dialog.ok_button_text = "Bind"
	var grid := GridContainer.new()
	grid.columns = 2
	var pickers: Array = []
	var slots: Array = entry.get("slots", [])
	for slot in 16:
		var label := Label.new()
		label.text = "slot%d" % (slot + 1)
		grid.add_child(label)
		var option := OptionButton.new()
		option.add_item("—", 0)          # unbound, and the default
		for i in parameters.size():
			option.add_item(str(parameters[i]["name"]), i + 1)
		var current := int(slots[slot]) if slot < slots.size() else -1
		for i in parameters.size():
			if int(parameters[i]["id"]) == current:
				option.select(i + 1)
				break
		grid.add_child(option)
		pickers.append(option)
	dialog.add_child(grid)
	dialog.confirmed.connect(func() -> void:
		var bound: Array = []
		for slot in 16:
			var index: int = pickers[slot].get_selected_id()
			# -1 is the only value that means unbound. A real parameter id is a uint32
			# and is very often negative through an int, which is a distinction the
			# provider learned the hard way.
			bound.append(-1 if index <= 0 else int(parameters[index - 1]["id"]))
		_set_plugin_slots(chosen, bound)
		dialog.queue_free())
	dialog.canceled.connect(func() -> void: dialog.queue_free())
	add_child(dialog)
	dialog.popup_centered()


## Writes a slot table, trimmed of the trailing unbound slots nobody chose.
func _set_plugin_slots(plugin_id: String, bound: Array) -> void:
	while not bound.is_empty() and int(bound[bound.size() - 1]) == -1:
		bound.remove_at(bound.size() - 1)
	_begin_edit()
	var table: Dictionary = patch.get("plugins", {})
	if table.has(plugin_id):
		table[plugin_id]["slots"] = bound
	patch["plugins"] = table
	_commit_edit("bind plugin slots")
	_apply()
	_say("%d slot(s) bound" % bound.size())


func _learn_midicc_node(node_id: String) -> void:
	_learning = {"node": node_id}
	_say("MIDI learn: turn the knob you mean — the next controller heard becomes "
		+ "this node's number. Escape cancels.")


## The armed learn meets its CC. Two kinds of learner share the arm: a face
## control writes the binding into its own `binding.midi_cc` field, a MidiCC
## node writes its `cc` parameter — each as one undo step.
func _bind_learned(cc: int) -> void:
	var node_id := str(_learning.get("node", ""))
	var wanted := str(_learning.get("id", ""))
	_learning = {}
	if node_id != "":
		_begin_edit()
		_set_parameter(node_id, "cc", float(cc))
		_commit_edit("learn CC %d" % cc)
		_apply()
		_say("CC %d is this node's knob now" % cc)
		return
	for control in patch.get("controls", []):
		if str(control.get("id", "")) != wanted:
			continue
		_begin_edit()
		control["binding"] = {"midi_cc": cc}
		_commit_edit("bind CC %d" % cc)
		_say("CC %d drives %s now" % [cc, str(control.get("label", wanted))])
		return


## A CC arrives for whatever controls claim it. 0..127 maps through each
## control's own range and scaling — the same curve its knob sweeps — and the
## write rides the knob path so engine, document and widgets move together.
func _apply_cc(event: InputEventMIDI) -> void:
	for control in patch.get("controls", []):
		var binding: Dictionary = control.get("binding", {})
		if int(binding.get("midi_cc", -1)) != event.controller_number:
			continue
		if binding.has("midi_channel") \
				and int(binding["midi_channel"]) != event.channel + 1:
			continue
		var descriptor := _control_descriptor(control)
		if descriptor.is_empty():
			continue
		var value := _to_value(descriptor, float(event.controller_value) / 127.0)
		_cc_touch()
		var target: Dictionary = control.get("target", {})
		_on_rack_parameter_changed(str(target.get("node", "")),
			str(target.get("parameter", "")), value)


func _cc_touch() -> void:
	if not _cc_editing:
		_begin_edit()
		_cc_editing = true
	if _cc_commit != null:
		_cc_commit.start()


## The beat of silence after a CC sweep: the whole sweep lands as one undo step.
func _commit_cc() -> void:
	if not _cc_editing:
		return
	_cc_editing = false
	_commit_edit("midi cc")


## Hardware MIDI. Notes ride the same funnel the on-screen keys use, so the
## screen lights up with what the hands are doing; program change turns the
## preset strip to that page — the message patch buttons and pedal program
## knobs have sent since the DX7 put pages behind a button row. A program past
## the bank's last page is ignored rather than wrapped: asking for page 90 of
## an eight-page bank means the pedal is set up for some other instrument.
func _on_midi(event: InputEventMIDI) -> void:
	match event.message:
		MIDI_MESSAGE_NOTE_ON:
			# Note-on at velocity zero is the wire's other spelling of note-off.
			if event.velocity > 0:
				_hold_note(event.pitch, float(event.velocity) / 127.0)
			else:
				_let_go_note(event.pitch)
		MIDI_MESSAGE_NOTE_OFF:
			_let_go_note(event.pitch)
		MIDI_MESSAGE_PROGRAM_CHANGE:
			var presets: Array = patch.get("presets", [])
			if event.instrument >= 0 and event.instrument < presets.size():
				patch_face._turn_to(event.instrument)
		MIDI_MESSAGE_CONTROL_CHANGE:
			# The engine's controller surface hears every CC regardless of learns
			# and bindings: MidiCC nodes read it as a signal, and a knob that is
			# both bound to a face control and picked up by a node should drive
			# both, because that is what the hand did.
			if engine != null:
				engine.control_change(event.controller_number,
					float(event.controller_value) / 127.0)
			if not _learning.is_empty():
				_bind_learned(event.controller_number)
			else:
				_apply_cc(event)
		MIDI_MESSAGE_PITCH_BEND:
			# The joystick's sideways axis, wearing controller number 128 so one
			# table serves the whole surface. 14-bit, centre at 0.5.
			if engine != null:
				engine.control_change(128, float(event.pitch) / 16383.0)


## Every note goes through these two, whether a mouse or a computer key started it. The
## on-screen keyboard lights up from held_notes rather than from its own clicks, so what
## you see is what the engine was actually told.
func _hold_note(note: int, velocity: float = 0.9) -> void:
	if engine == null or held_notes.has(note):
		return
	held_notes[note] = true
	engine.note_on(note, velocity)
	if keyboard != null:
		keyboard.set_held_notes(held_notes)
	if roll_pitch != null:
		roll_pitch.queue_redraw()


func _let_go_note(note: int) -> void:
	if engine == null or not held_notes.has(note):
		return
	held_notes.erase(note)
	engine.note_off(note)
	if keyboard != null:
		keyboard.set_held_notes(held_notes)
	if roll_pitch != null:
		roll_pitch.queue_redraw()


## ---- the piano roll ----------------------------------------------------------------
## The grid is the roll's; the document and the clock are here. Notes the roll plays
## go through the same _hold_note/_let_go_note the keys use, so the keyboard lights
## and the engine hears exactly what a hand would have played.

## The document's sequence, made real the first time anything writes to it.
func _roll_sequence() -> Dictionary:
	if not patch.has("sequence"):
		patch["sequence"] = {"tempo": 120.0, "steps": 16, "notes": []}
	if not patch["sequence"].has("notes"):
		patch["sequence"]["notes"] = []
	return patch["sequence"]


## `remember` writes the fold down as the preference. A person reaching for the Roll
## menu is stating one; a document that happens to carry a tune is not, so opening the
## roll to show one must not quietly redecide what every future session starts as.
func _set_roll_open(open: bool, remember := true) -> void:
	roll_open = open
	# The Roll menu alone governs the roll. The keyboard's own size menu used to
	# take the roll down with it, which read as one control quietly overruling
	# another — hiding the piano is about the piano.
	roll_row.visible = open
	roll_play.visible = open
	roll_capture.visible = open
	roll_tempo.visible = open
	roll_division.visible = open
	if remember:
		Settings.store("piano_roll", open)
	_sync_roll_menu()
	piano_roll.sequence = patch.get("sequence", {})
	_refresh_roll_tempo_text()
	piano_roll.queue_redraw()
	if not open and roll_playing:
		roll_play.button_pressed = false


func _on_roll_cell_toggled(step: int, note: int) -> void:
	_begin_edit()
	var notes: Array = _roll_sequence()["notes"]
	# A long note answers for every row it holds, so a click anywhere on its body
	# clears it — the roll anchors presses to the covering note's own step.
	var removed := false
	for index in range(notes.size() - 1, -1, -1):
		var entry: Dictionary = notes[index]
		if int(entry.get("note", -1)) != note:
			continue
		var from := int(entry.get("step", -1))
		if step >= from and step < from + maxi(1, int(entry.get("length", 1))):
			notes.remove_at(index)
			removed = true
	if not removed:
		notes.append({"step": step, "note": note, "length": 1})
		_grow_roll_to(step + 1)
	_commit_edit("roll: %s %s" % ["clear" if removed else "place", Keyboard.note_name(note)])
	piano_roll.sequence = patch["sequence"]
	piano_roll.queue_redraw()


## A drag wrote a length: resize the note at that anchor, or place it held.
func _on_roll_note_stretched(step: int, note: int, length: int) -> void:
	_begin_edit()
	var notes: Array = _roll_sequence()["notes"]
	var found := false
	for entry: Dictionary in notes:
		if int(entry.get("step", -1)) == step and int(entry.get("note", -1)) == note:
			entry["length"] = length
			found = true
	if not found:
		notes.append({"step": step, "note": note, "length": length})
	_grow_roll_to(step + length)
	_commit_edit("roll: hold %s" % Keyboard.note_name(note))
	piano_roll.sequence = patch["sequence"]
	piano_roll.queue_redraw()


func _set_roll_playing(playing: bool) -> void:
	roll_playing = playing
	if roll_play != null:
		roll_play.icon = _icon(Icons.Kind.PAUSE if playing else Icons.Kind.PLAY)
	if playing:
		# Primed so the very first tick speaks step zero rather than a beat of silence.
		_roll_step = -1
		_roll_clock = _roll_step_seconds()
	else:
		for note in _roll_sounding:
			_let_go_note(int(note))
		_roll_sounding.clear()
		piano_roll.playing_step = -1


## How long one step of the roll lasts.
##
## Four steps to the beat was hard-coded, which put the shortest note at 62 ms even with
## the tempo against its ceiling — comfortable for drums and far too slow for typing,
## where the whole point is a burst of keys faster than a beat. The division is part of
## the document now, so a roll can be sixteenths, thirty-seconds or sixty-fourths and
## still say what it is when it is opened somewhere else.
func _roll_step_seconds() -> float:
	var sequence: Dictionary = patch.get("sequence", {})
	var tempo: float = float(sequence.get("tempo", 120.0))
	var division: float = float(sequence.get("division", 4))
	return 60.0 / clampf(tempo, 40.0, 240.0) / clampf(division, 1.0, 16.0)


## Steps to the beat: 4 is sixteenths, 8 thirty-seconds, 16 sixty-fourths.
func _roll_division() -> int:
	return int(clampi(int(_roll_sequence().get("division", 4)), 1, 16))


func _set_roll_division(value: float) -> void:
	_begin_edit()
	# Powers of two only. The roll is drawn on a grid and the grid is drawn in halves;
	# a division of five would be a lattice nobody asked for.
	var wanted := int(round(clampf(value, 1.0, 16.0)))
	var allowed := [1, 2, 4, 8, 16]
	var nearest: int = allowed[0]
	for option in allowed:
		if absi(option - wanted) < absi(nearest - wanted):
			nearest = option
	_roll_sequence()["division"] = nearest
	_commit_edit("roll division")
	_refresh_roll_tempo_text()
	piano_roll.sequence = patch.get("sequence", {})
	piano_roll.queue_redraw()
	_say("%s to the bar" % _division_name(nearest))


func _division_name(division: int) -> String:
	match division:
		1: return "quarter notes"
		2: return "eighths"
		4: return "sixteenths"
		8: return "thirty-seconds"
		16: return "sixty-fourths"
	return "%d to the beat" % division


## The roll, rendered instead of played: a second engine walks the same steps the
## Play transport would, offline, and the bar lands in the patch as the "capture"
## buffer. Draw drums, press this, and a Sampler with slices chops your own playing --
## the hybrid the drum kit and the break chopper make together.
func _capture_roll() -> void:
	var sequence: Dictionary = patch.get("sequence", {})
	var notes: Array = sequence.get("notes", [])
	if notes.is_empty():
		_say("the roll is empty — draw some drums first")
		return
	var text := JSON.stringify(patch, "  ")
	var offline: Object = ClassDB.instantiate("SoundGraphEngine")
	var report: Variant = JSON.parse_string(offline.validate_patch(text))
	if typeof(report) != TYPE_DICTIONARY or not report["ok"]:
		_say("the patch does not validate, so there is nothing true to capture")
		return
	offline.load_patch(text, 48000.0)
	if not offline.is_loaded():
		_say("the offline engine refused the patch")
		return
	var steps: int = maxi(1, int(sequence.get("steps", 16)))
	var step_frames := int(round(_roll_step_seconds() * 48000.0))
	var pcm := PackedByteArray()
	var sounding: Dictionary = {}
	for step in steps:
		# The same order Play uses: what ends on this step lets go before what
		# begins on it, so back-to-back retriggers survive the capture too.
		var still: Dictionary = {}
		for note in sounding:
			var remaining: int = int(sounding[note]) - 1
			if remaining <= 0:
				offline.note_off(int(note))
			else:
				still[note] = remaining
		sounding = still
		for entry: Dictionary in notes:
			if int(entry.get("step", -1)) != step:
				continue
			var note := int(entry.get("note", -1))
			if note >= 0 and not sounding.has(note):
				offline.note_on(note, 0.9)
				sounding[note] = maxi(1, int(entry.get("length", 1)))
		var block: PackedFloat32Array = offline.render_block(step_frames)
		for sample in block:
			var value := int(round(clampf(sample, -1.0, 1.0) * 32767.0))
			pcm.append(value & 0xFF)
			pcm.append((value >> 8) & 0xFF)
	_begin_edit()
	if int(patch.get("schema_version", 1)) < 3:
		patch["schema_version"] = 3
	var buffers: Dictionary = patch.get("buffers", {})
	buffers["capture"] = {"sample_rate": 48000, "channels": 1, "format": "pcm16",
		"data": Marshalls.raw_to_base64(pcm)}
	patch["buffers"] = buffers
	_commit_edit("capture roll")
	_apply()
	var bars := ceili(float(steps) / 16.0)
	var plays_it := false
	for node: Dictionary in patch.get("nodes", []):
		if str(node.get("buffer", "")) == "capture":
			plays_it = true
	_say("captured %d bar%s of the roll%s" % [bars, "s" if bars > 1 else "",
		"" if plays_it else " — add a Sampler with buffer \"capture\" to play it"])


func _set_roll_tempo(value: float) -> void:
	_begin_edit()
	_roll_sequence()["tempo"] = clampf(value, 40.0, 240.0)
	_commit_edit("roll tempo")
	_refresh_roll_tempo_text()


func _refresh_roll_tempo_text() -> void:
	if roll_tempo == null:
		return
	var tempo: float = float(patch.get("sequence", {}).get("tempo", 120.0))
	roll_tempo.text = "%d bpm" % int(round(tempo))
	roll_tempo.position_now = roll_tempo.to_position.call(tempo)
	if roll_division != null:
		var division := _roll_division()
		roll_division.text = "1/%d" % (division * 4)
		roll_division.position_now = roll_division.to_position.call(float(division))
		roll_division.tooltip_text = ("%s: %d ms a step at this tempo. Typing wants "
			+ "thirty-seconds or faster; drums rarely do.") % [
				_division_name(division).capitalize(),
				int(round(_roll_step_seconds() * 1000.0))]


## Nonsense speech, typed. Every letter becomes a note and the punctuation becomes the
## pauses and the tune; the mapping itself lives in speak_text.gd, on its own, where it
## can be tested without an editor. This is only the asking and the committing.
func _ask_what_to_say() -> void:
	var dialog := ConfirmationDialog.new()
	dialog.title = "Say something"
	dialog.ok_button_text = "Write it into the roll"
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", Design.scale(8))
	var blurb := Label.new()
	blurb.text = ("Every letter becomes a note; spaces and punctuation become the pauses "
		+ "between them. A full stop falls, a question mark climbs. Point the roll at a "
		+ "babbling voice and press Play.")
	blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	blurb.custom_minimum_size = Vector2(Design.scale(400), 0)
	column.add_child(blurb)
	var field := LineEdit.new()
	field.text = say_text
	field.custom_minimum_size = Vector2(Design.scale(400), 0)
	# Return is the obvious way to finish a one-line question, and a dialog that ignores
	# it makes somebody reach for a mouse they had no reason to touch.
	field.text_submitted.connect(func(_t: String) -> void:
		dialog.confirmed.emit()
		dialog.hide())
	column.add_child(field)
	dialog.add_child(column)
	dialog.confirmed.connect(func() -> void:
		_say_into_roll(field.text)
		dialog.queue_free())
	dialog.canceled.connect(func() -> void: dialog.queue_free())
	add_child(dialog)
	dialog.popup_centered()
	field.grab_focus()
	field.select_all()


## One undo step, roll opened on it — the same bargain the MIDI reader strikes.
func _say_into_roll(text: String) -> void:
	if text.strip_edges() == "":
		_say("nothing to say")
		return
	say_text = text
	# Middle C. A voice meant to be a mouse or a giant says so through its own Voice
	# knob, which is a transpose — the driver picks a sensible middle, the instrument
	# moves it.
	var spoken: Dictionary = SpeakText.to_sequence(text, 60, PianoRoll.MAX_STEPS)
	_begin_edit()
	# Only the sequence's own keys: `dropped` is a note to the person, not document.
	patch["sequence"] = {"tempo": spoken["tempo"], "division": spoken["division"],
		"steps": spoken["steps"], "notes": spoken["notes"]}
	_commit_edit("say something")
	if not roll_open:
		_set_roll_open(true)
	piano_roll.sequence = patch["sequence"]
	piano_roll.scroll_step = 0
	_refresh_roll_tempo_text()
	piano_roll.queue_redraw()
	var syllables := (spoken["notes"] as Array).size()
	_say("%d syllable%s of \"%s\"%s — press Play" % [syllables,
		"" if syllables == 1 else "s", text.strip_edges().left(28),
		" — %d past the end stayed behind" % int(spoken["dropped"])
			if int(spoken["dropped"]) > 0 else ""])


## A recording becomes the roll. One undo step, roll opened on it, the same bargain the
## MIDI reader and the text driver both strike.
##
## The tempo and division already on the roll are what the transcription is laid against,
## because they are what the person has been working in. The model hears absolute time;
## something has to decide the grid, and the roll's own settings are a better guess than
## anything this could invent.
func _transcribe_audio_file(path: String) -> void:
	_say("listening to %s…" % path.get_file())
	# Godot has no way to paint before a blocking call returns, and this one takes a
	# second or two on a long recording. The line above is posted, the frame is let
	# through, and only then does the process start - otherwise the first thing anybody
	# sees is the result, and the editor looks frozen in between.
	await get_tree().process_frame

	var tempo: float = float(patch.get("sequence", {}).get("tempo", 120.0))
	var heard: Dictionary = Transcribe.run(path, tempo, _roll_division())
	if not bool(heard["ok"]):
		_say(str(heard["error"]))
		return

	var sequence: Dictionary = heard["sequence"]
	_begin_edit()
	patch["sequence"] = sequence
	_commit_edit("transcribe %s" % path.get_file())
	if not roll_open:
		_set_roll_open(true)
	piano_roll.sequence = patch["sequence"]
	piano_roll.scroll_step = 0
	_refresh_roll_tempo_text()
	piano_roll.queue_redraw()

	var notes: Array = sequence.get("notes", [])
	var lowest := 127
	var highest := 0
	for note in notes:
		lowest = mini(lowest, int(note["note"]))
		highest = maxi(highest, int(note["note"]))
	_say("%d note%s from %s, %s to %s — press Play" % [notes.size(),
		"" if notes.size() == 1 else "s", path.get_file(),
		_note_name(lowest), _note_name(highest)])


## The piece grows a bar at a time under notes placed past its end: the window can
## look sixteen bars out, and a click out there is a request for more piece, not a
## mistake to clamp away.
func _grow_roll_to(needed_steps: int) -> void:
	var sequence: Dictionary = _roll_sequence()
	if needed_steps > int(sequence.get("steps", 16)):
		sequence["steps"] = clampi(ceili(float(needed_steps) / 16.0) * 16, 16,
			PianoRoll.MAX_STEPS)


## A Standard MIDI File lands in the roll: notes and tempo through the reader,
## quantised to sixteenths, first sixteen bars. One undo step, roll opened on it.
func _import_midi_file(path: String) -> void:
	var sung: Dictionary = MidiImport.read(path)
	if sung.is_empty():
		_say("that file is not a MIDI tune this reader can hold")
		return
	_begin_edit()
	patch["sequence"] = {"tempo": sung["tempo"], "steps": sung["steps"],
		"notes": sung["notes"]}
	_commit_edit("import midi")
	if not roll_open:
		_set_roll_open(true)
	piano_roll.sequence = patch["sequence"]
	piano_roll.scroll_step = 0
	_refresh_roll_tempo_text()
	piano_roll.queue_redraw()
	var bars := ceili(float(int(sung["steps"])) / 16.0)
	_say("%d notes over %d bars at %d bpm%s" % [(sung["notes"] as Array).size(), bars,
		int(round(float(sung["tempo"]))),
		" — %d notes past bar sixteen stayed behind" % int(sung["dropped"])
			if int(sung["dropped"]) > 0 else ""])


func _advance_roll(delta: float) -> void:
	if not roll_playing or engine == null:
		return
	_roll_clock += delta
	while _roll_clock >= _roll_step_seconds():
		_roll_clock -= _roll_step_seconds()
		_roll_tick()


func _roll_tick() -> void:
	var sequence: Dictionary = patch.get("sequence", {})
	var rows: int = maxi(1, int(sequence.get("steps", 16)))
	_roll_step = (_roll_step + 1) % rows
	# What ends on this step lets go before what begins on it: the same note can
	# retrigger back-to-back without the second onset being swallowed.
	var still: Dictionary = {}
	for note in _roll_sounding:
		var remaining: int = int(_roll_sounding[note]) - 1
		if remaining <= 0:
			_let_go_note(int(note))
		else:
			still[note] = remaining
	_roll_sounding = still
	for entry: Dictionary in sequence.get("notes", []):
		if int(entry.get("step", -1)) != _roll_step:
			continue
		var note := int(entry.get("note", -1))
		if note >= 0 and not _roll_sounding.has(note):
			_hold_note(note)
			_roll_sounding[note] = maxi(1, int(entry.get("length", 1)))
	piano_roll.playing_step = _roll_step


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
	# The strip clips rather than insisting. Its natural width was the widest thing
	# in the editor — 874px of buttons — which meant every window narrower than that
	# overflowed the whole column and cropped the top row's right edge, hamburger
	# included. Clipped, the column can follow the window down; the strip loses its
	# own right end on a tiny window instead, which is the honest trade until this
	# row's own redesign reaches it.
	var strip := ScrollContainer.new()
	strip.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	strip.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var keyboard_bar := _build_keyboard_bar()
	keyboard_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	strip.add_child(keyboard_bar)
	strip.custom_minimum_size.y = keyboard_bar.get_combined_minimum_size().y
	column.add_child(strip)

	keyboard = Keyboard.new()
	keyboard.note_pressed.connect(_on_keyboard_pressed)
	keyboard.note_released.connect(_on_keyboard_released)

	# The roll sits between the bar and the keys, folded away until asked for, its
	# lanes borrowed live from the keyboard below it. It shares its row with two
	# gutters on the left: a scrollbar up the piece while the roll stands upright,
	# and a sliver of piano marking the pitches while it lies flat.
	roll_row = HBoxContainer.new()
	roll_row.add_theme_constant_override("separation", Design.SPACE_XS)
	roll_row.visible = false

	roll_scroll = VScrollBar.new()
	roll_scroll.min_value = 0.0
	# Wide enough to hit — the stock bar is eight pixels of target — and stepped
	# by the beat, because the default step of a hundredth made the wheel over it
	# move the view by nothing anyone could see.
	roll_scroll.custom_minimum_size.x = Design.scale(14)
	roll_scroll.step = 4.0
	roll_scroll.tooltip_text = "Where in the piece the roll is looking. " \
		+ "Up is later, the way the notes read."
	roll_scroll.value_changed.connect(_on_roll_scroll)
	roll_row.add_child(roll_scroll)

	piano_roll = PianoRoll.new()
	piano_roll.keyboard = keyboard
	piano_roll.custom_minimum_size.y = Design.scale(150)
	piano_roll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	piano_roll.cell_toggled.connect(_on_roll_cell_toggled)
	piano_roll.note_stretched.connect(_on_roll_note_stretched)

	roll_pitch = RollPitch.new()
	roll_pitch.keyboard = keyboard
	roll_pitch.visible = false
	roll_pitch.note_pressed.connect(_on_keyboard_pressed)
	roll_pitch.note_released.connect(_on_keyboard_released)
	roll_pitch.octave_shifted.connect(_shift_octave)
	roll_row.add_child(roll_pitch)

	roll_row.add_child(piano_roll)
	column.add_child(roll_row)

	column.add_child(keyboard)
	# The stored fold, through the same door the menu uses.
	_set_roll_open(bool(Settings.fetch("piano_roll", false)))
	return keyboard_dock


## Draws or hides the computer-key letters on the piano. The octave names stay:
## C3 is what the key is, the letter is only how a computer reaches it.
func _set_key_hints(on: bool) -> void:
	Settings.store("keyboard_hints", on)
	if keyboard != null:
		keyboard.show_key_labels = on
		keyboard.queue_redraw()
	if keyboard_toggle != null:
		var menu := keyboard_toggle.get_popup()
		menu.set_item_checked(menu.get_item_index(3), on)


## Which way time runs across the roll: vertical rises over the keys, horizontal
## runs left to right the way most sequencers have taught.
func _set_roll_orientation(which: String) -> void:
	Settings.store("roll_orientation", which)
	if piano_roll != null:
		piano_roll.orientation = which
		piano_roll.queue_redraw()
	# Standing, the piece needs a scrollbar; lying flat, the pitches need naming.
	if roll_scroll != null:
		roll_scroll.visible = which == "vertical"
	if roll_pitch != null:
		roll_pitch.visible = which == "horizontal"
		roll_pitch.queue_redraw()
	_sync_roll_menu()


## The scrollbar speaks top-down and the roll bottom-up, so the value inverts:
## the thumb at the top is the far end of the piece.
func _on_roll_scroll(value: float) -> void:
	if _roll_scroll_syncing or piano_roll == null:
		return
	piano_roll.scroll_step = clampi(
		int(roll_scroll.max_value - piano_roll.view_rows - value),
		0, PianoRoll.MAX_STEPS - piano_roll.view_rows)
	piano_roll.queue_redraw()


## The Roll menu's radios say what the roll is doing: Hide when it is away, and
## whichever way it is lying when it is out.
func _sync_roll_menu() -> void:
	if roll_button == null:
		return
	var menu := roll_button.get_popup()
	var which: String = piano_roll.orientation if piano_roll != null else "vertical"
	menu.set_item_checked(menu.get_item_index(0), roll_open and which == "vertical")
	menu.set_item_checked(menu.get_item_index(1), roll_open and which == "horizontal")
	menu.set_item_checked(menu.get_item_index(2), not roll_open)


## How much of the piece the roll windows at once, chosen from the Bars submenu —
## the item ids are the row counts themselves.
func _set_roll_bars(rows: int) -> void:
	if piano_roll != null:
		piano_roll.set_view_rows(rows)
	if roll_bars_menu != null:
		for index in roll_bars_menu.item_count:
			roll_bars_menu.set_item_checked(index,
				roll_bars_menu.get_item_id(index) == rows)


## Collapses the dock to its control strip, or opens it again.
func _set_keyboard_mode(mode: String) -> void:
	keyboard_mode = mode
	keyboard_expanded = mode != "hide"
	Settings.store("keyboard_mode", mode)
	if keyboard != null:
		# Hidden rather than shrunk past playing: a keyboard two pixels tall is a row
		# of slivers that still take clicks. Mini stays a keyboard — half the height,
		# every key still a target a finger can mean.
		keyboard.visible = keyboard_expanded
		keyboard.custom_minimum_size.y = Design.scale(112 if mode == "full" else 56)
		if not keyboard_expanded:
			_release_all_notes()
	if keyboard_toggle != null:
		keyboard_toggle.text = "Keyboard"
		keyboard_toggle.icon = _icon(
			Icons.Kind.CARET_DOWN if keyboard_expanded else Icons.Kind.CARET_RIGHT,
			Design.INK_SECOND)
		var menu := keyboard_toggle.get_popup()
		for index in menu.item_count:
			# Radios only: the same popup carries the Key hints checkbox, whose
			# state is no business of the size.
			if menu.is_item_radio_checkable(index):
				menu.set_item_checked(index, menu.get_item_text(index).to_lower() == mode)
	_fit_keyboard_dock()


## The dock's vertical ladder: the keys are the instrument, so they yield last. On
## a short window the roll gives up height first, then a full keyboard drops to mini
## height on its own — the stored mode is the user's answer, this is the window's,
## and the roll rendering while the piano fell off the bottom was the exact bug that
## earned this function.
func _fit_keyboard_dock(height: float = -1.0) -> void:
	if keyboard == null:
		return
	var available := height
	if available <= 0.0:
		var view := get_viewport()
		available = view.get_visible_rect().size.y if view != null else 0.0
	if available <= 0.0:
		return
	var tight := available < 700.0
	var cramped := available < 560.0
	if piano_roll != null:
		piano_roll.custom_minimum_size.y = Design.scale(90 if tight else 150)
	if keyboard_mode == "full":
		keyboard.custom_minimum_size.y = Design.scale(56 if cramped else 112)
	# The bench yields too: its display's floor was tall enough to shove the whole
	# column past the window's bottom on its own, and a shorter trace that shows is
	# worth more than a taller one that pushed the piano off the screen.
	if scope_probe != null and scope_probe.display != null:
		scope_probe.display.custom_minimum_size.y = Design.scale(
			52 if cramped else (90 if tight else 160))


## Kept for the callers that speak in booleans; the menu speaks in modes.
func _set_keyboard_expanded(expanded: bool) -> void:
	_set_keyboard_mode(keyboard_mode if expanded and keyboard_mode != "hide" 		else ("full" if expanded else "hide"))


func _build_keyboard_bar() -> Control:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", Design.SPACE_XS)

	# The keyboard's own jacks, on the keyboard. This is where the cables into the patch
	# come from — see seam_dock.gd for why they cannot be drawn by GraphEdit.
	note_jacks = SeamDock.Jacks.new()
	note_jacks.type_colours = TYPE_COLOURS
	note_jacks.ink = INK
	note_jacks.jack_grabbed.connect(_on_jack_grabbed)
	note_jacks.tooltip_text = "Drag a jack onto an Input port to drive it, " \
		+ "or off the graph to unplug it."
	bar.add_child(note_jacks)

	# A menu, not a toggle: full, mini and hide are three sizes of the same answer
	# to "how much of my screen is a piano", and a toggle can only say two of them.
	keyboard_toggle = MenuButton.new()
	keyboard_toggle.flat = false
	var size_menu := keyboard_toggle.get_popup()
	size_menu.add_radio_check_item("Full", 0)
	size_menu.add_radio_check_item("Mini", 1)
	size_menu.add_radio_check_item("Hide", 2)
	size_menu.add_separator()
	# The letters on the keys are training wheels: the mapping stays live either
	# way, and somebody who knows where D is by now can have the piano back.
	size_menu.add_check_item("Key hints", 3)
	size_menu.set_item_checked(size_menu.get_item_index(3), true)
	size_menu.id_pressed.connect(func(id: int) -> void:
		if id <= 2:
			_set_keyboard_mode(["full", "mini", "hide"][id])
		else:
			_set_key_hints(not size_menu.is_item_checked(size_menu.get_item_index(3))))
	bar.add_child(_defocus(keyboard_toggle))

	# The roll's fold and transport: Roll opens the grid, Play runs it, and the
	# pace is a draggable number like every other value here.
	# A menu, like the keyboard's: choosing an orientation brings the roll out
	# lying that way, Hide puts it away, and Bars is how much of the piece shows.
	roll_button = MenuButton.new()
	roll_button.flat = false
	roll_button.text = "Roll"
	roll_button.tooltip_text = "A step grid over the keys: click a lane to place a " 		+ "note, click it again to take it away. Vertical rises over the keys that " 		+ "play it; horizontal runs left to right the way most sequencers do; Bars " 		+ "is how much of the piece is on screen — the wheel walks through the rest."
	var roll_menu := roll_button.get_popup()
	roll_menu.add_radio_check_item("Vertical", 0)
	roll_menu.add_radio_check_item("Horizontal", 1)
	roll_menu.add_radio_check_item("Hide", 2)
	roll_menu.set_item_checked(2, true)
	roll_menu.add_separator()
	roll_bars_menu = PopupMenu.new()
	for rows: int in [8, 16, 32, 64, 128, 256, 512, 1024, 2048]:
		roll_bars_menu.add_radio_check_item("½ bar" if rows == 8
			else "%d bar%s" % [rows / 16, "s" if rows > 16 else ""], rows)
	roll_bars_menu.set_item_checked(1, true)
	roll_bars_menu.id_pressed.connect(_set_roll_bars)
	roll_menu.add_submenu_node_item("Bars", roll_bars_menu)
	roll_menu.add_separator()
	# Speech lands in the roll rather than down a private path that only plays: notes
	# somebody can see, nudge, delete and capture, like anything else drawn there.
	roll_menu.add_item("Say Something…", 3)
	roll_menu.id_pressed.connect(func(id: int) -> void:
		if id == 2:
			_set_roll_open(false)
		elif id == 3:
			_ask_what_to_say()
		else:
			_set_roll_orientation("vertical" if id == 0 else "horizontal")
			_set_roll_open(true))
	bar.add_child(_defocus(roll_button))
	roll_play = Button.new()
	roll_play.toggle_mode = true
	# The transport pair every recorder since tape has taught: a triangle to run,
	# two uprights to rest. The word "Play" said less in more room.
	roll_play.icon = _icon(Icons.Kind.PLAY)
	roll_play.tooltip_text = "Loop the roll through the patch, exactly as the keys play."
	roll_play.visible = false
	roll_play.toggled.connect(_set_roll_playing)
	bar.add_child(_defocus(roll_play))
	roll_capture = Button.new()
	roll_capture.text = "Capture"
	roll_capture.tooltip_text = "Render the roll into the patch's \"capture\" buffer " \
		+ "— one pass, offline, exactly as Play sounds it. A Sampler whose buffer is " \
		+ "\"capture\" starts chopping what you drew."
	roll_capture.visible = false
	roll_capture.pressed.connect(_capture_roll)
	bar.add_child(_defocus(roll_capture))
	roll_tempo = ValueField.new()
	roll_tempo.centred = true
	roll_tempo.custom_minimum_size.x = Design.scale(84)
	roll_tempo.text = "120 bpm"
	roll_tempo.default_value = 120.0
	roll_tempo.position_now = (120.0 - 40.0) / 200.0
	roll_tempo.to_value = func(position: float) -> float:
		return 40.0 + 200.0 * clampf(position, 0.0, 1.0)
	roll_tempo.to_position = func(value: float) -> float:
		return clampf((value - 40.0) / 200.0, 0.0, 1.0)
	roll_tempo.value_submitted.connect(_set_roll_tempo)
	roll_tempo.visible = false
	bar.add_child(roll_tempo)

	# Beside the tempo, because they are the same question asked twice: how fast, and how
	# finely. Typing wants the second one and drums rarely do, which is why it defaults to
	# the sixteenths everything was already using.
	roll_division = ValueField.new()
	roll_division.centred = true
	roll_division.custom_minimum_size.x = Design.scale(84)
	roll_division.text = "1/16"
	roll_division.default_value = 4.0
	roll_division.position_now = 0.5
	roll_division.to_value = func(position: float) -> float:
		return 1.0 + 15.0 * clampf(position, 0.0, 1.0)
	roll_division.to_position = func(value: float) -> float:
		return clampf((value - 1.0) / 15.0, 0.0, 1.0)
	roll_division.value_submitted.connect(_set_roll_division)
	roll_division.visible = false
	bar.add_child(roll_division)
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(gap)

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
	# Sized to sit inside the strip with air around it, and centred in the row: a
	# dial as tall as the row it lives in reads as jammed, not mounted.
	master_knob.dial = 0.72
	master_knob.size_flags_vertical = Control.SIZE_SHRINK_CENTER
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

	# And the output's, past the room controls: mute, then volume, then the jack the
	# signal actually leaves through — the same direction it travels through every
	# graph and rack in this application.
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
	# The readout is prose and the ±8va pair is machinery; a thumb's width apart,
	# or the label reads as the buttons' caption.
	var range_gap := Control.new()
	range_gap.custom_minimum_size.x = Design.scale(Design.SPACE_M)
	bar.add_child(range_gap)
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
	# The roll's lanes are the keys' columns, so they move together — and the
	# pitch sliver is the same window stood on end.
	if piano_roll != null:
		piano_roll.queue_redraw()
	if roll_pitch != null:
		roll_pitch.queue_redraw()
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
	search_popup.size = Vector2i(600, 540)

	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	search_field = LineEdit.new()
	search_field.placeholder_text = "What do you want to do?  e.g. \"remove high frequencies\""
	search_field.text_changed.connect(_on_search_changed)
	search_field.text_submitted.connect(func(_text: String) -> void: _add_first_result())
	box.add_child(search_field)

	# The shelves. Search answers "I know what I want"; the chips answer "show me
	# what there is" — the banks a person actually thinks in, plus the heart, which
	# is the shelf they curate themselves by loving nodes below.
	var chip_row := HBoxContainer.new()
	chip_row.add_theme_constant_override("separation", Design.SPACE_S)
	for tag: Array in [["favorites", ""], ["synth", "Synth"], ["drums", "Drums"],
			["dx7", "DX7"], ["clones", "Clones"], ["nodes", "Nodes"]]:
		var chip := Button.new()
		chip.toggle_mode = true
		if str(tag[1]) == "":
			chip.icon = _icon(Icons.Kind.HEART, Design.ACCENT)
			chip.tooltip_text = "Only what you have loved. Love a node with the " \
				+ "heart on its row."
		else:
			chip.text = str(tag[1])
		chip.toggled.connect(func(_on: bool) -> void:
			_set_search_tag(str(tag[0])))
		search_tag_chips[str(tag[0])] = chip
		chip_row.add_child(_defocus(chip))
	box.add_child(chip_row)

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
		var device_label := type_name.trim_prefix("device:")
		descriptor = {
			"display_name": device_label,
			"summary": DeviceBlurbs.blurb(device_label),
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

	var heart := Button.new()
	heart.flat = true
	heart.icon = _icon(Icons.Kind.HEART,
		Design.ACCENT if _loved_nodes.has(type_name) else Color(Design.INK_SECOND, 0.35))
	heart.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	heart.tooltip_text = "Love it. Loved nodes gather under the heart chip and " \
		+ "surface first when browsing."
	heart.pressed.connect(func() -> void: _toggle_loved(type_name))
	line.add_child(_defocus(heart))

	var add := Button.new()
	add.text = "Add"
	add.custom_minimum_size = Vector2(72, 40)
	add.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	add.tooltip_text = "Add a %s to the patch" % descriptor.get("display_name", type_name)
	add.pressed.connect(func() -> void: _add_from_search(type_name))
	line.add_child(_defocus(add))

	row.add_child(line)
	return row


# ---- feedback -----------------------------------------------------------------
# One server serves several products; what keeps this product's reports its own is
# the envelope's `app` field, an install id living in *this* project's settings,
# and an outbox under *this* project's user:// — no code or state shared with any
# other application posting to the same service.
const FEEDBACK_ENDPOINT := "https://feedback.mutantfactory.net"
var feedback_outbox := "user://feedback/outbox.jsonl"
var feedback_submitter: Node
var feedback_popup: PopupPanel
var feedback_note: TextEdit
var feedback_shot_check: CheckBox
var feedback_send: Button
var _feedback_shot: Image

# ---- the speak pipeline: text or a WAV, into a Speech node's buffer ------------
var words_popup: PopupPanel
var words_text: TextEdit
var words_hint: Label
var words_wav_dialog: FileDialog
var _words_node := ""

var _search_spawn := Vector2.ZERO
var _search_top_result := ""
var _added_since_open := 0

## Which shelf of the vocabulary the dialog is showing: "" is everything, the rest
## are the chips across its top. The families are the example banks' own prefixes.
var _search_tag := ""
var search_tag_chips: Dictionary = {}
const SEARCH_TAG_FAMILIES := {
	"synth": ["Synth:"],
	"drums": ["808:", "909:", "606:", "SDS:", "Gated:"],
	"dx7": ["DX7:"],
	"clones": ["FM:", "909:", "606:", "SDS:", "Gated:"],
}

## type names and device labels somebody has loved, key -> true. Loves persist:
## a vocabulary this size needs the reader's own dog-ears.
var _loved_nodes: Dictionary = {}


## One shelf at a time: choosing a chip puts the others back, choosing the chosen
## one returns to everything.
func _set_search_tag(tag: String) -> void:
	_search_tag = "" if _search_tag == tag else tag
	for key in search_tag_chips:
		(search_tag_chips[key] as Button).set_pressed_no_signal(str(key) == _search_tag)
	_on_search_changed(search_field.text)


## Toggles a love and remembers it. The heart is the reader's own mark: it never
## changes what a node does, only how fast its owner can find it again.
func _toggle_loved(key: String) -> void:
	if _loved_nodes.has(key):
		_loved_nodes.erase(key)
	else:
		_loved_nodes[key] = true
	Settings.store("loved_nodes", _loved_nodes.keys())
	_on_search_changed(search_field.text)


## Device labels under the given family prefixes whose text holds every query word.
## No cap: a chip is a request to browse the whole shelf, and the list scrolls.
func _family_devices(prefixes: Array, query: String) -> Array:
	var words := query.to_lower().split(" ", false)
	var matches: Array = []
	for label in _examples:
		var text := str(label)
		var in_family := prefixes.is_empty()
		for prefix: String in prefixes:
			if text.begins_with(prefix):
				in_family = true
		if not in_family:
			continue
		var lowered := ("%s %s" % [text, DeviceBlurbs.blurb(text)]).to_lower()
		var all_words := true
		for word in words:
			if not lowered.contains(str(word)):
				all_words = false
		if all_words:
			matches.append(text)
	matches.sort()
	return matches


## This install's stable anonymous name for the feedback service: it groups one
## reporter's history without an account. Generated once, kept in this project's
## own settings — a different id from every other product on this machine.
func _feedback_install_id() -> String:
	var id := str(Settings.fetch("install_id", ""))
	if id == "":
		id = Crypto.new().generate_random_bytes(8).hex_encode()
		Settings.store("install_id", id)
	return id


func _open_feedback() -> void:
	# The screenshot is taken NOW, before the dialog covers what the report is
	# about. Held in memory; nothing is written unless Send is pressed with the
	# box still ticked.
	_feedback_shot = get_viewport().get_texture().get_image()
	if feedback_popup == null:
		_build_feedback_popup()
	feedback_note.text = ""
	feedback_send.disabled = true
	feedback_popup.popup_centered()
	feedback_note.grab_focus()
	# Opening the dialog is the moment somebody is demonstrably here and likely
	# online — the polite time to deliver anything an offline session left behind.
	feedback_submitter.flush()


func _build_feedback_popup() -> void:
	feedback_popup = PopupPanel.new()
	feedback_popup.size = Vector2i(540, 400)
	# An opaque panel of its own: the theme leaves PopupPanel see-through, which the
	# search dialog gets away with behind its rows and a form does not.
	feedback_popup.add_theme_stylebox_override("panel",
		Design.padded_panel(Design.Surface.NODE, Design.SPACE_M, Design.SPACE_M))
	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.add_theme_constant_override("separation", Design.SPACE_S)

	var heading := Label.new()
	heading.text = "Send feedback"
	heading.add_theme_font_override("font", Design.font(Design.WEIGHT_SEMIBOLD))
	box.add_child(heading)

	feedback_note = TextEdit.new()
	feedback_note.placeholder_text = "What were you doing, and what went sideways? " 		+ "A note with [deleteme] in it tests the pipes and is thrown away."
	feedback_note.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	feedback_note.custom_minimum_size.y = Design.scale(120)
	feedback_note.size_flags_vertical = Control.SIZE_EXPAND_FILL
	feedback_note.text_changed.connect(func() -> void:
		feedback_send.disabled = feedback_note.text.strip_edges() == "")
	box.add_child(feedback_note)

	feedback_shot_check = CheckBox.new()
	feedback_shot_check.text = "Include a screenshot of the editor"
	feedback_shot_check.tooltip_text = "The editor as it looked when this dialog " 		+ "opened — untick to send the note alone."
	feedback_shot_check.button_pressed = true
	box.add_child(feedback_shot_check)

	# The whole privacy surface, stated where the choice is made: the report says
	# what it carries, and the reporter can put the picture down.
	var carries := Label.new()
	carries.text = "Sends your note, the build (%s), your platform, which view " 		% str(_build_stamp().get("short", "dev")) 		+ "you were in, and a random install id. Offline, it waits in an outbox " 		+ "and goes when it can."
	carries.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# Pinned width, because an autowrap label with none reports its minimum height
	# as if wrapped at nothing — which inflated this dialog to the window's full
	# height the first time it opened.
	carries.custom_minimum_size = Vector2(Design.scale(480), 0)
	carries.add_theme_font_size_override("font_size",
		Design.type(Design.SIZE_SECONDARY))
	carries.add_theme_color_override("font_color", Design.INK_SECOND)
	box.add_child(carries)

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_END
	buttons.add_theme_constant_override("separation", Design.SPACE_S)
	var cancel := Button.new()
	cancel.text = "Cancel"
	cancel.pressed.connect(func() -> void: feedback_popup.hide())
	buttons.add_child(_defocus(cancel))
	feedback_send = Button.new()
	feedback_send.text = "Send"
	feedback_send.disabled = true
	feedback_send.pressed.connect(_send_feedback)
	buttons.add_child(_defocus(feedback_send))
	box.add_child(buttons)

	feedback_popup.add_child(box)
	add_child(feedback_popup)


## Writes one envelope line to the outbox and asks the submitter to drain it. The
## outbox is the deliverable — the network is the submitter's problem, later if
## need be — so this function succeeds offline, on purpose.
func _send_feedback() -> void:
	var note := feedback_note.text.strip_edges()
	if note == "":
		return
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(feedback_outbox.get_base_dir()))
	var record := {
		"v": 1,
		"app": "SoundGraph",
		"app_version": str(_build_stamp().get("short", "dev")),
		"platform": OS.get_name(),
		"install_id": _feedback_install_id(),
		"ts": Time.get_datetime_string_from_system(true),
		"text": note,
		"element_key": "view/%s" % views.get_tab_title(views.current_tab).to_lower(),
	}
	if note.contains("[deleteme]"):
		record["test"] = true
	var attached := false
	if feedback_shot_check.button_pressed and _feedback_shot != null:
		var shot_name := "shot-%d.png" % int(Time.get_unix_time_from_system() * 1000.0)
		if _feedback_shot.save_png(feedback_outbox.get_base_dir().path_join(shot_name)) == OK:
			record["shot"] = shot_name
			attached = true
	record["shot_attached"] = attached
	var file: FileAccess
	if FileAccess.file_exists(feedback_outbox):
		file = FileAccess.open(feedback_outbox, FileAccess.READ_WRITE)
		if file != null:
			file.seek_end()
	else:
		file = FileAccess.open(feedback_outbox, FileAccess.WRITE)
	if file == null:
		_say("could not write the feedback outbox — nothing was sent")
		return
	file.store_line(JSON.stringify(record))
	file.close()
	feedback_popup.hide()
	_say("thank you — sending…")
	feedback_submitter.flush()


func _on_feedback_flushed(sent: int, discarded: int, failed: int) -> void:
	if discarded > 0 and sent == 0 and failed == 0:
		_say("test report accepted and thrown away, exactly as designed")
	elif sent > 0 and failed == 0:
		_say("feedback sent — thank you")
	elif sent > 0:
		_say("some feedback sent; the rest waits in the outbox")
	elif failed > 0:
		_say("feedback is waiting in the outbox — it goes out when the service "
			+ "is reachable")


func _open_speech_words(node_id: String) -> void:
	_words_node = node_id
	if words_popup == null:
		_build_words_popup()
	words_hint.text = "The words go through the OS voice, then through the same " \
		+ "encoder a WAV goes through. Either way the patch carries only the bytes."
	words_popup.popup_centered()
	words_text.grab_focus()


func _build_words_popup() -> void:
	words_popup = PopupPanel.new()
	words_popup.size = Vector2i(520, 300)
	words_popup.add_theme_stylebox_override("panel",
		Design.padded_panel(Design.Surface.NODE, Design.SPACE_M, Design.SPACE_M))
	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.add_theme_constant_override("separation", Design.SPACE_S)

	var heading := Label.new()
	heading.text = "Words"
	heading.add_theme_font_override("font", Design.font(Design.WEIGHT_SEMIBOLD))
	box.add_child(heading)

	words_text = TextEdit.new()
	words_text.placeholder_text = "what should it say?\none line per phrase — " \
		+ "the root note says the first, each semitone up says the next"
	words_text.custom_minimum_size.y = Design.scale(96)
	words_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(words_text)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", Design.SPACE_S)
	var say := Button.new()
	say.text = "Say it"
	say.tooltip_text = "Through the computer's own voice, then into the chip."
	say.pressed.connect(_speak_typed)
	buttons.add_child(_defocus(say))
	var from_wav := Button.new()
	from_wav.text = "From a WAV…"
	from_wav.tooltip_text = "Any 16-bit recording: your voice, somebody's sample " \
		+ "pack, this program's own render."
	from_wav.pressed.connect(_pick_speech_wav)
	buttons.add_child(_defocus(from_wav))
	box.add_child(buttons)

	words_hint = Label.new()
	words_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# Pinned, as every wrapping label in a size-to-content popup must be.
	words_hint.custom_minimum_size = Vector2(Design.scale(460), 0)
	words_hint.add_theme_font_size_override("font_size",
		Design.type(Design.SIZE_SECONDARY))
	words_hint.add_theme_color_override("font_color", Design.INK_SECOND)
	box.add_child(words_hint)

	words_popup.add_child(box)
	add_child(words_popup)


## Text through the operating system's own voice, one line per phrase: each line
## becomes its own stop-delimited entry in the bank, and the note input picks one —
## the root note says the first, each semitone up the next. The OS voice is the one
## platform-specific seam, and it degrades to a message rather than a mystery.
func _speak_typed() -> void:
	var phrases: Array = []
	for line in words_text.text.split("\n"):
		if str(line).strip_edges() != "":
			phrases.append(str(line).strip_edges())
	if phrases.is_empty():
		words_hint.text = "Type something first."
		return
	var bank := PackedByteArray()
	var wav_path := ProjectSettings.globalize_path("user://words-tts.wav")
	for phrase: String in phrases:
		var status := -1
		match OS.get_name():
			"Windows":
				var script := "Add-Type -AssemblyName System.Speech; " \
					+ "$s = New-Object System.Speech.Synthesis.SpeechSynthesizer; " \
					+ "$f = New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo(" \
					+ "22050, [System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen, " \
					+ "[System.Speech.AudioFormat.AudioChannel]::Mono); " \
					+ "$s.SetOutputToWaveFile('%s', $f); " % wav_path.replace("'", "''") \
					+ "$s.Speak('%s'); $s.Dispose()" % phrase.replace("'", "''")
				status = OS.execute("powershell", ["-NoProfile", "-Command", script])
			"macOS":
				status = OS.execute("say",
					["-o", wav_path, "--data-format=LEI16@22050", phrase])
			_:
				words_hint.text = "No system voice on this platform — feed a WAV instead."
				return
		if status != 0 or not FileAccess.file_exists(wav_path):
			words_hint.text = "The system voice did not answer — feed a WAV instead."
			return
		var wav := WavImport.read(wav_path)
		DirAccess.remove_absolute(wav_path)
		if wav.is_empty():
			words_hint.text = "The system voice wrote a file this reader cannot hold."
			return
		bank.append_array(engine.lpc_encode(wav["samples"], float(wav["rate"])))
	_write_speech_buffer(_words_node, bank, phrases.size())


func _pick_speech_wav() -> void:
	if words_wav_dialog == null:
		words_wav_dialog = FileDialog.new()
		words_wav_dialog.access = FileDialog.ACCESS_FILESYSTEM
		words_wav_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		words_wav_dialog.filters = ["*.wav ; WAV audio"]
		words_wav_dialog.file_selected.connect(func(path: String) -> void:
			_import_speech_wav(_words_node, path))
		add_child(words_wav_dialog)
	words_wav_dialog.popup_centered(Vector2i(700, 500))


## The WAV half: one file, one phrase. WAV to floats (wav_import), floats to
## bitstream (the engine's encoder — no DSP in GDScript), into the bank.
func _import_speech_wav(node_id: String, path: String) -> void:
	var wav := WavImport.read(path)
	if wav.is_empty():
		_say("that file is not a 16-bit WAV this reader can hold")
		if words_hint != null:
			words_hint.text = "That file is not a 16-bit WAV this reader can hold."
		return
	_write_speech_buffer(node_id,
		engine.lpc_encode(wav["samples"], float(wav["rate"])), 1)


## Bytes into the patch as a buffer, the node bound to it, one undo step. Same
## shape as Capture, whatever spoke the bytes.
func _write_speech_buffer(node_id: String, bytes: PackedByteArray, phrases: int) -> void:
	if bytes.size() <= 3:
		_say("the encoder heard nothing worth keeping in that recording")
		return
	var pcm := PackedByteArray()
	for byte in bytes:
		pcm.append(byte)
		pcm.append(0)
	_begin_edit()
	if int(patch.get("schema_version", 1)) < 3:
		patch["schema_version"] = 3
	var name := ""
	for node: Dictionary in patch.get("nodes", []):
		if str(node["id"]) == node_id:
			name = str(node.get("buffer", ""))
	if name == "" or name == "capture":
		name = "words-%s" % node_id
	var buffers: Dictionary = patch.get("buffers", {})
	buffers[name] = {"sample_rate": 8000, "channels": 1, "format": "pcm16",
		"data": Marshalls.raw_to_base64(pcm)}
	patch["buffers"] = buffers
	for node: Dictionary in patch.get("nodes", []):
		if str(node["id"]) == node_id:
			node["buffer"] = name
	_commit_edit("speak words")
	_apply()
	if words_popup != null:
		words_popup.hide()
	_say("%d phrase%s, %d bytes of chip-speak in buffer \"%s\" — the root note " \
		% [phrases, "s" if phrases > 1 else "", bytes.size(), name] \
		+ "says the first, each semitone up the next")


## What a patch is made of, for the browser's preview pane.
##
## Read from the file when somebody looks at it. The alternative is opening three hundred
## patches to draw a list of their names, which is the sort of eager work that turns a
## browser into a wait.
func _browser_facts(item: BrowserItem) -> PackedStringArray:
	var lines := PackedStringArray()
	if not _examples.has(item.source_ref):
		return lines
	var file := FileAccess.open(_example_path(_examples[item.source_ref]),
		FileAccess.READ)
	if file == null:
		return lines
	var patch_file: Variant = JSON.parse_string(file.get_as_text())
	if not (patch_file is Dictionary):
		return lines
	var nodes: Array = (patch_file as Dictionary).get("nodes", [])
	var wires: Array = (patch_file as Dictionary).get("connections", [])
	lines.append("%d node%s" % [nodes.size(), "" if nodes.size() == 1 else "s"])
	lines.append("%d connection%s" % [wires.size(), "" if wires.size() == 1 else "s"])
	# What it plays through, from its own terminals rather than from a guess: the host on
	# an Input or Output node is the seam it is wired to.
	var terminals := {}
	for node: Dictionary in nodes:
		var host := str(node.get("host", ""))
		match "%s/%s" % [str(node.get("type", "")), host]:
			"Input/note":
				terminals["Keyboard input"] = true
			"Input/audio":
				terminals["Audio input"] = true
			"Output/stereo":
				terminals["Audio output"] = true
	for terminal in terminals:
		lines.append(str(terminal))
	return lines


## Taking something from the browser: the action the item asked for.
##
## Two routes, both of which the editor already had. Adding is the palette's, and loading
## is the toolbar example menu's — which loads straight into the patch with no
## confirmation, so this does too rather than inventing a convention for one entry point.
## The browser closes on a load and stays open on an add: a patch replaces what you were
## looking at, and nodes are added several at a time.
func _from_browser(id: String, action: int) -> void:
	if action == BrowserItem.Action.LOAD_PATCH:
		node_browser.hide()
		await _load_example(id.trim_prefix("device:"))
		return
	_search_spawn = graph_edit.size * 0.5
	await _add_from_search(id)


## Opens the browser under the control that asked for it.
##
## The toolbar button's own rectangle, in viewport coordinates, so the panel arrives
## where the hand already is rather than at a corner the editor picked.
func _open_node_browser() -> void:
	var anchor := Rect2i(Vector2i(Design.scale(120), Design.scale(60)), Vector2i.ZERO)
	if toolbar != null and toolbar.toolbar_add_button != null:
		var button: Button = toolbar.toolbar_add_button
		anchor = Rect2i(button.get_global_rect())
	# Rebuilt on every opening: the example shelf and the registry can both have grown
	# since the last one — a plugin scan, a device saved. Which node names can be added is
	# the editor's rule about its own graph, so it is answered here and handed over.
	node_browser.catalogue = BrowserCatalogue.build(registry,
		_addable(PackedStringArray(registry.keys())), _examples)
	node_browser.open_beside(anchor)


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

	var trimmed := query.strip_edges()
	var names := PackedStringArray()

	# The ranking is the core's, so "make quieter" finds the same node here, in the
	# browser, and on the command line. Atomic nodes appear on every shelf except
	# the device banks' own.
	if _search_tag in ["", "nodes", "favorites"]:
		var node_names: PackedStringArray = engine.search_nodes(query) if trimmed != "" \
			else PackedStringArray(registry.keys())
		names = _addable(node_names)

	# Devices beside nodes, because the main way to build is mixing them: a whole patch
	# — a DX7 voice, an effect — drops in as one module node, wired like anything else.
	# Under no chip they appear only on a real query, since browsing two hundred
	# devices under an empty search would bury the node vocabulary — which is exactly
	# what the chips are for: a bank chip lays out its whole shelf.
	if _search_tag == "":
		for label in _matching_devices(query):
			names.append("device:%s" % label)
	elif _search_tag == "favorites":
		for label in _family_devices([], trimmed):
			names.append("device:%s" % label)
	elif SEARCH_TAG_FAMILIES.has(_search_tag):
		for label in _family_devices(SEARCH_TAG_FAMILIES[_search_tag], trimmed):
			names.append("device:%s" % label)

	if _search_tag == "favorites":
		var kept := PackedStringArray()
		for name in names:
			if _loved_nodes.has(str(name)):
				kept.append(name)
		names = kept
	elif trimmed == "":
		# Browsing, not searching: what you love surfaces first, the way a worn
		# tool drifts to the top of the box.
		var loved := PackedStringArray()
		var rest := PackedStringArray()
		for name in names:
			if _loved_nodes.has(str(name)):
				loved.append(name)
			else:
				rest.append(name)
		loved.append_array(rest)
		names = loved

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
		var lowered := "%s %s" % [str(label), DeviceBlurbs.blurb(str(label))]
		lowered = lowered.to_lower()
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
	_apply()
	_commit_edit("add %s" % result.instance_id)
	if not wired.is_empty():
		_say("added %s — wired %s" % [result.instance_id, ", ".join(wired)])
	return result.instance_id


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
		# The double tap on an unwired jack plugs it into the obvious place — the
		# same answer the auto-wire gives a fresh device, one port at a time.
		if bool(socket.get("double", false)):
			var obvious := _obvious_end(instance, port, output)
			if obvious.is_empty():
				_say("nothing obvious to plug %s into" % port)
				return
			var quick: Dictionary
			if output:
				quick = {"from": {"node": instance, "port": port},
					"to": {"node": str(obvious["node"]), "port": str(obvious["port"])}}
			else:
				quick = {"from": {"node": str(obvious["node"]),
						"port": str(obvious["port"])},
					"to": {"node": instance, "port": port}}
			_connect_face_socket.call_deferred(quick)
			return
		dragging_face_socket = {"instance": instance, "port": port,
			"output": output, "from": socket["centre"] as Vector2}
		return


## Descends into a module: its definition becomes the open document. The definition
## is already a whole patch — nodes, wiring, seams, controls — so the editor edits
## it exactly as it edits a file, and the seams mean it plays standalone under the
## keyboard. The host document, its history and its name wait on the dive stack.
func _dive_into(instance_id: String) -> void:
	var module_name := _module_of(instance_id)
	var definition: Dictionary = patch.get("modules", {}).get(module_name, {})
	if definition.is_empty():
		return
	var doc := {
		"schema_version": 2,
		"metadata": {"name": module_name},
		"nodes": (definition.get("nodes", []) as Array).duplicate(true),
		"connections": (definition.get("connections", []) as Array).duplicate(true),
		"modules": {},
	}
	# The definitions its own instances stand on come along — a dive that lost
	# dx7_operator would show six unbuildable nodes. The dived definition itself
	# cannot appear below: patch-io already refuses the cycle.
	for name in patch.get("modules", {}):
		if str(name) != module_name:
			doc["modules"][str(name)] = (patch["modules"][name] as Dictionary) \
				.duplicate(true)
	if definition.has("controls"):
		doc["controls"] = (definition["controls"] as Array).duplicate(true)
	# Placed before loading: a node without a position trips the loader's
	# auto-arrange, which commits an edit — and an untouched dive must not come
	# home carrying one. A plain rank is enough; the arrange button remains for
	# anyone who wants better.
	var unplaced := 0
	for node in doc["nodes"]:
		if not node.has("position"):
			node["position"] = {"x": 420.0 * float(unplaced % 6),
				"y": 760.0 * float(unplaced / 6 + 1)}
			unplaced += 1
	dive_stack.append({
		"patch": patch,
		"module": module_name,
		"definition": definition.duplicate(true),
		"name": document_name,
		"unsaved": unsaved,
		"history": undo_redo,
		"home": _home_values,
	})
	undo_redo = UndoRedo.new()
	_load_text(JSON.stringify(doc))
	# The title bar is the breadcrumb: each frame stores the name at its level, so
	# the path grows one segment per dive and shrinks itself on the climb —
	# "first-synth > algo-01 > dx7_operator" says where you are and how you got
	# there. An ASCII separator, because a path drawn in tofu is no path at all.
	_set_document_name("%s > %s" % [str(dive_stack.back()["name"]), module_name])
	unsaved = false
	if climb_button != null:
		climb_button.text = "Climb to %s" % _dive_leaf(str(dive_stack.back()["name"]))
		climb_button.visible = true
	_refresh_undo_buttons()
	_say("dived into %s" % module_name)


## Back up one level. Edits made below are written into the host's definition as a
## single undo step; a dive that touched nothing changes nothing.
func _climb_up() -> void:
	if dive_stack.is_empty():
		return
	var edited: Dictionary = patch
	var touched: bool = unsaved
	var frame: Dictionary = dive_stack.pop_back()
	patch = frame["patch"]
	undo_redo.free()
	undo_redo = frame["history"]
	_home_values = frame.get("home", {})
	_set_document_name(str(frame["name"]))
	unsaved = bool(frame["unsaved"])
	if climb_button != null:
		climb_button.visible = not dive_stack.is_empty()
		if not dive_stack.is_empty():
			climb_button.text = "Climb to %s" \
				% _dive_leaf(str(dive_stack.back()["name"]))
	if touched:
		_begin_edit()
		patch["modules"][str(frame["module"])] = _definition_from_document(edited,
			frame["definition"] as Dictionary)
		# Definitions edited further down the stack ride back up too.
		for name in edited.get("modules", {}):
			patch["modules"][str(name)] = edited["modules"][name]
	await _rebuild_view()
	_apply()
	if touched:
		_commit_edit("edit %s" % str(frame["module"]))
		_say("climbed up — %s carries the edits" % str(frame["module"]))
	else:
		_refresh_undo_buttons()
		_say("climbed up")


## Climbs several levels as one gesture — what clicking a breadcrumb segment asks
## for. Each level is still its own climb, so each writes its own edit into its own
## host, exactly as climbing by hand would.
func _climb_levels(hops: int) -> void:
	for hop in maxi(hops, 0):
		await _climb_up()


## The last segment of a breadcrumb: what the climb button names, since "Climb to
## first-synth > algo-01" would quote the whole journey to describe one step.
func _dive_leaf(path: String) -> String:
	var segments := path.split(" > ")
	return segments[segments.size() - 1]


## A definition rebuilt from the document its dive produced. Structure maps one to
## one; the exported surface keeps every old export whose node survived — instance
## overrides and controls name those exports, and renaming them would orphan both —
## and grows exports for anything newly written or newly on the face, by the same
## on-demand rule the importer uses.
func _definition_from_document(doc: Dictionary, old: Dictionary) -> Dictionary:
	var definition := {
		"nodes": (doc.get("nodes", []) as Array).duplicate(true),
		"connections": (doc.get("connections", []) as Array).duplicate(true),
	}
	if str(old.get("description", "")) != "":
		definition["description"] = old["description"]
	var alive := {}
	for node in definition["nodes"]:
		alive[str(node["id"])] = true
	var exported: Array = []
	for binding in old.get("parameters", []):
		if alive.has(str(binding["node"])):
			exported.append((binding as Dictionary).duplicate(true))
	for node in definition["nodes"]:
		for parameter_name in node.get("parameters", {}):
			ModuleAuthor._export_for(exported, {}, str(node["id"]),
				str(parameter_name))
	var faces: Array = (doc.get("controls", []) as Array).duplicate(true)
	if not faces.is_empty():
		var inner := {}
		for node in definition["nodes"]:
			if not str(node.get("type", "")) in ["Input", "Output"]:
				inner[str(node["id"])] = true
		for control: Dictionary in faces:
			var target: Dictionary = control.get("target", {})
			if inner.has(str(target.get("node", ""))):
				ModuleAuthor._export_for(exported, {}, str(target.get("node", "")),
					str(target.get("parameter", "")))
		definition["controls"] = faces
	elif old.has("controls"):
		definition["controls"] = (old["controls"] as Array).duplicate(true)
	if not exported.is_empty():
		definition["parameters"] = exported
	for carried in ["inputs", "outputs"]:
		if old.has(carried):
			definition[carried] = (old[carried] as Array).duplicate(true)
	return definition


## An inline name field over the turned container's band: Enter commits through the
## same handler the inspector's rename uses, Escape or clicking away cancels. The
## field is screen furniture, not document state — nothing happens until Enter.
func _begin_face_rename(key: String) -> void:
	var module_name := _module_of(key)
	if module_name == "" and patch.get("modules", {}).has(key):
		module_name = key
	if module_name == "":
		return
	var frame: Rect2 = graph_edit.flip_frames.get(key, Rect2())
	if frame.size.x <= 0.0:
		return
	var zoom: float = graph_edit.zoom if graph_edit.zoom > 0.0 else 1.0
	var field := LineEdit.new()
	field.text = module_name
	field.add_theme_font_size_override("font_size", Design.type(Design.SIZE_CONTROL))
	field.position = frame.position * zoom - graph_edit.scroll_offset
	field.size = Vector2(minf(frame.size.x * zoom, 320.0),
		maxf(float(Design.scale(26.0)) * zoom, 28.0))
	field.z_index = 120
	field.tooltip_text = "Enter renames the module; Escape leaves it alone."
	graph_edit.add_child(field)
	field.select_all()
	field.grab_focus()
	var closing := [false]
	field.text_submitted.connect(func(text: String) -> void:
		if closing[0]:
			return
		closing[0] = true
		var wanted := text.strip_edges()
		field.queue_free()
		_on_module_renamed(module_name, wanted))
	field.focus_exited.connect(func() -> void:
		if closing[0]:
			return
		closing[0] = true
		field.queue_free())
	field.gui_input.connect(func(event: InputEvent) -> void:
		var pressed := event as InputEventKey
		if pressed != null and pressed.pressed and pressed.keycode == KEY_ESCAPE \
				and not closing[0]:
			closing[0] = true
			field.queue_free())


## The obvious other end for one port of a device, by the same rules the auto-wire
## uses when a device arrives: an input takes the host outlet of its own name; an
## output takes the first vacant mixer channel, or the vacant machine inlet of its
## own name. {} when nothing obvious exists, which is an honest answer.
func _obvious_end(instance_id: String, port: String, output: bool) -> Dictionary:
	var fed := {}
	for wire in patch.get("connections", []):
		fed["%s/%s" % [str(wire["to"]["node"]), str(wire["to"]["port"])]] = true
	if not output:
		for node in patch.get("nodes", []):
			if str(node.get("type", "")) != "Input" or str(node.get("host", "")) == "":
				continue
			for outlet: Dictionary in registry.get(
					Seams.registry_key(node), {}).get("outputs", []):
				if str(outlet.get("name", "")) == port:
					return {"node": str(node["id"]), "port": port}
		return {}
	for node in patch.get("nodes", []):
		if str(node.get("type", "")) != "Mixer":
			continue
		for inlet: Dictionary in registry.get("Mixer", {}).get("inputs", []):
			if str(inlet.get("type", "")) != "audio":
				continue
			var inlet_name := str(inlet.get("name", ""))
			if not fed.has("%s/%s" % [str(node["id"]), inlet_name]):
				return {"node": str(node["id"]), "port": inlet_name}
	for node in patch.get("nodes", []):
		if str(node.get("type", "")) != "Output" or str(node.get("host", "")) == "":
			continue
		for inlet: Dictionary in registry.get(
				Seams.registry_key(node), {}).get("inputs", []):
			if str(inlet.get("name", "")) == port \
					and not fed.has("%s/%s" % [str(node["id"]), port]):
				return {"node": str(node["id"]), "port": port}
	return {}


## Puts one cable into the document: the double-tap's auto-plug lands here.
func _connect_face_socket(connection: Dictionary) -> void:
	for wire in patch["connections"]:
		if _same_connection(wire, connection):
			return
	_begin_edit()
	patch["connections"].append(connection)
	await _rebuild_view()
	_apply()
	_commit_edit("connect")
	_say("connected %s.%s → %s.%s" % [str(connection["from"]["node"]),
		str(connection["from"]["port"]), str(connection["to"]["node"]),
		str(connection["to"]["port"])])


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
	# Hardware MIDI, first and unconditionally: it is never part of a mouse
	# gesture, and a pedal mid-drag still means what it means.
	var midi := event as InputEventMIDI
	if midi != null:
		_on_midi(midi)
		return
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
	# One face now, mounted on the canvas. It follows the document and the selection
	# here — offer, pages, patch, rebuild — but never its own visibility: the Face
	# toggle owns that. Rebuilt even while hidden, so flipping shows the current
	# document instantly instead of the one from the last flip.
	patch_face.offer_node = str(inspecting.get("node", ""))
	patch_face.preset_index = int(preset_pages.get("", patch_face.preset_index))
	patch_face.patch = patch
	patch_face.registry = registry
	patch_face.rack = rack
	patch_face.title = _instrument_name()
	patch_face.rebuild()
	if graph_edit != null:
		# The same name on both boundaries: the graph's case and the face are one
		# container drawn twice, and two names would be two containers.
		graph_edit.case_title = _instrument_name()

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
	var shown := document_name + ("  (unsaved)" if unsaved else "")
	if dive_stack.is_empty():
		document_label.text = "[right]%s[/right]" % shown
	else:
		# Every ancestor is a link back to its level; the last segment is where
		# you already stand, and a link to where you are would only lie about it.
		var segments := document_name.split(" > ")
		var parts := PackedStringArray()
		for index in segments.size():
			if index < segments.size() - 1:
				parts.append("[url=%d]%s[/url]" % [index, segments[index]])
			else:
				parts.append(segments[index])
		document_label.text = "[right]%s%s[/right]" % [" > ".join(parts),
			"  (unsaved)" if unsaved else ""]
	# Because the label is clipped, this is the only place a long name can be read whole.
	document_label.tooltip_text = shown
	document_label.add_theme_color_override("default_color",
		Design.INK_NORMAL if unsaved else Design.INK_SECOND)


var _voices_touched := false


func _commit_edit(label: String) -> void:
	if _pending_snapshot.is_empty():
		return
	var before := _pending_snapshot
	_pending_snapshot = {}
	var after := _snapshot()
	var touched_voices := _voices_touched
	_voices_touched = false
	if JSON.stringify(before) == JSON.stringify(after):
		return  # a drag that went nowhere is not an edit
	if touched_voices:
		# The gesture is over and the document really changed: this is the moment
		# the voice count becomes real. Deferred, so the commit stays synchronous
		# for UndoRedo while the engine catches up on its own frame.
		_rebuild_and_apply.call_deferred()

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
			# Voices survives the strip: it is structural — the engine grows a copy
			# of the note-driven cone per voice — so undoing a voices change must
			# take the rebuild path, not the moved-knob one.
			var parameters: Dictionary = node.get("parameters", {})
			if parameters.has("voices"):
				node["parameters"] = {"voices": parameters["voices"]}
			else:
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
		# The plugins are asked what they are *before* the graph that owns them is
		# rebuilt, and the answers go back in with the patch. Without this every edit
		# anywhere in the graph would return every hosted plugin to its defaults, which
		# for a user who has spent ten minutes in Surge is not a reload, it is a loss.
		_capture_plugin_states()
		_close_plugin_face(true)
		engine.load_patch(_patch_text_with_plugin_states(), 48000.0)
		_note_latency()
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
		# The control zone goes as one piece — the centring box and the knob or
		# dropdown inside it — so reduced detail releases the zone's height too.
		if bool(piece.get_meta("control_zone", false)):
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
				"module":
					# One row, three jobs: a port on each flank and the knob cells between
					# them. The cells go with the detail level; the row never does,
					# because it is carrying the slot the cables are attached to.
					var cells: Control = control.get_meta("cells_box") \
						if control.has_meta("cells_box") else null
					if cells != null:
						cells.visible = show_rows and cells.get_child_count() > 0
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
## Records that the pointer is on a node, and has it redressed.
##
## The dressing is not done here any more. This function used to write the two
## styleboxes straight from the editor theme, which meant every module the pointer
## touched was repainted by something that had never heard of panel styles.
func _set_node_hovered(widget: GraphNode, hovered: bool) -> void:
	widget.set_meta("hovered", hovered)
	_style_widget(widget, str(widget.get_meta("patch_id")))


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
## The QR at a size a phone across the room can actually read.


func _refresh_status() -> void:
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
	# And they are said in one place. These two used to be written into the menu as
	# disabled items — "Audio running", "Graph valid" — which is a state filed under
	# commands, read only by somebody who opened a menu to look for it. The dot above
	# carries the whole sentence in its tooltip, and it is legible from across a table.
	_status_line = " · ".join(parts)


## What the status dot is currently saying, in words. Read by the suite, and by anything
## that wants the sentence without recomputing it.
var _status_line := ""


## The status strip spelled out, for whichever of its two parts is left to hover.
func _status_sentence(running: bool, valid: bool) -> String:
	var sentence := ("Audio %s · graph %s · 48000 Hz"
		% ["running" if running else "stopped", "valid" if valid else "has problems"])
	# Only when there is something to say. The toolbar has eight pixels of room and a
	# number that reads "0 frames late" in every patch anybody has ever opened would be
	# spending them on nothing.
	if _latency_frames > 0:
		sentence += " · %d frames late (%.1f ms)" % [_latency_frames, _latency_ms()]
	return sentence


func _latency_ms() -> float:
	return 1000.0 * float(_latency_frames) / 48000.0


## Reads the graph's output latency, and mentions it the once, when it changes.
##
## Said out loud rather than left in a tooltip because it is a consequence the user did
## not ask for: a plugin with lookahead in it makes the whole patch late, the graph lines
## its own paths up but cannot hand back samples that do not exist yet, and anything
## playing alongside SoundGraph has to be told. Once per change, not once per edit —
## a number that has not moved is not news.
func _note_latency() -> void:
	if engine == null or not engine.is_loaded():
		return
	var info: Variant = JSON.parse_string(engine.get_info_json())
	var now := 0
	if typeof(info) == TYPE_DICTIONARY:
		now = int(info.get("latency_frames", 0))
	if now == _latency_frames:
		return
	_latency_frames = now
	if now > 0:
		_say("A plugin puts this patch %d frames (%.1f ms) behind; the graph lines its own paths up."
			% [now, _latency_ms()])


func _highlight(node_ids: Array) -> void:
	for id in widgets:
		var widget: GraphNode = widgets[id]
		widget.modulate = Color(1.0, 0.65, 0.6) if node_ids.has(id) else Color.WHITE


## Kept under its old name because half a dozen places call it after the graph changes.


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
	for base: String in [_repository_examples(), "res://examples-mirror"]:
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
	return "res://examples-mirror/" + file_name


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
		#
		# The plugins are asked what they are on the way out. A saved patch that reopens
		# with every hosted plugin back at its defaults has not saved the sound, and the
		# sound is what a patch is for.
		_capture_plugin_states()
		out.store_string(engine.format_patch(_patch_text_with_plugin_states()))
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


## Picks up a patch handed over by the lite page at /soundgraph.
##
## The two surfaces share an origin, so they share localStorage, and the patch itself is
## the whole protocol — both read the same file and ask the same core about it, so there is
## nothing else to agree on. `soundgraph.handoff.v1` is deliberately not the key the lite
## page saves to: this one is consumed and cleared, and clobbering somebody's saved work
## with a patch they were only passing through would be a poor trade.
##
## Returns true when a patch was loaded, so the caller knows not to open the default.
func _load_handed_off_patch() -> bool:
	if not _on_web():
		return false

	# Read and clear in one step. A handoff that survived its own load would reopen on
	# every later visit, quietly overriding whatever the person had gone on to make.
	var raw: Variant = JavaScriptBridge.eval("""
		(function () {
			try {
				const held = window.localStorage.getItem('soundgraph.handoff.v1');
				if (!held) { return ''; }
				window.localStorage.removeItem('soundgraph.handoff.v1');
				return held;
			} catch (error) {
				return '';   // storage refused; there is simply no handoff
			}
		})();
	""", true)

	if typeof(raw) != TYPE_STRING or str(raw).is_empty():
		return false

	var envelope: Variant = JSON.parse_string(str(raw))
	if typeof(envelope) != TYPE_DICTIONARY or not envelope.has("text"):
		return false

	var carried_name := str(envelope.get("name", "")).strip_edges()
	var file_name := "handed-over.json"
	if not carried_name.is_empty():
		file_name = "%s.json" % carried_name.to_lower().replace(" ", "-")

	_set_document_name(file_name)
	_load_text(str(envelope["text"]))
	_say("opened %s from the browser page" %
		(carried_name if not carried_name.is_empty() else "a patch"))

	# Exposed for the same reason `window.soundgraph` is in the lite page: from outside the
	# canvas there is otherwise no way to tell a patch that arrived from one that was
	# dropped. Consuming the handoff key proves the read ran, not that the document loaded —
	# and those are exactly the two things worth telling apart when this breaks.
	JavaScriptBridge.eval("window.soundgraphEditor = %s;" % JSON.stringify({
		"document": document_name,
		"nodes": patch.get("nodes", []).size(),
		"from": "handoff",
	}), true)
	return true


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
	# The browser cannot host a plugin, so there is never anything to capture here — but
	# a patch opened on the desktop, edited in a browser and saved back should not lose
	# the state it arrived with, and going through the same path is what keeps it.
	_capture_plugin_states()
	var text: String = engine.format_patch(_patch_text_with_plugin_states())
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
			# Eight voices out of the box: enough for two hands or a piano-roll
			# chord with tails, and the knob turns it down for a lean MCU deploy.
			# Shipped examples stay mono — their goldens are byte-pinned — but a
			# fresh machine should play a chord without reading the manual.
			{"id": "note", "type": "Input", "host": "note", "name": "Keyboard",
				"parameters": {"voices": 8},
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
	_home_values.clear()
	# Captured state belongs to the document it came out of. The keys are the patch's own
	# short names — "surge", "verb" — so two unrelated patches will collide on them
	# sooner rather than later, and a Surge preset from the last file arriving in this one
	# is the kind of wrong that looks like the editor inventing sounds.
	_plugin_states.clear()
	_latency_frames = 0
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
	# A fresh document starts on no page of anyone's bank, with deck B unpicked.
	preset_pages.clear()
	if patch_face != null:
		patch_face.preset_index = -1
		patch_face.morph_b = -1
		patch_face.morph_b_picked = false

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

	# A document that arrives carrying notes shows them. The roll's fold is a stored
	# preference that starts closed, so a patch shipping a tune opened onto silence and
	# an empty stage: the notes were in the file, the transport was hidden, and the only
	# way to find out either existed was to go looking in a menu. Same shape of bug as
	# the framing above — the feature worked and was simply never reached.
	if not roll_open and not (patch.get("sequence", {}).get("notes", []) as Array).is_empty():
		_set_roll_open(true, false)

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
	if not _learning.is_empty() and key.pressed and key.keycode == KEY_ESCAPE:
		_learning = {}
		_say("learn cancelled")
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

	# The four lenses on the plain number row, tooltips say so. Only while the Patch
	# tab is up and nothing has keyboard focus — a 3 typed into a value field is a
	# number, not a request for the schematic.
	if key.pressed and not key.ctrl_pressed and not key.alt_pressed \
			and get_viewport().gui_get_focus_owner() == null \
			and views != null and views.get_tab_title(views.current_tab) == "Patch":
		var lens_keys := {KEY_1: PatchView.RACK, KEY_2: PatchView.GRAPH,
			KEY_3: PatchView.SCHEMATIC, KEY_4: PatchView.FACE}
		if lens_keys.has(key.keycode):
			_set_patch_view(lens_keys[key.keycode])
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
