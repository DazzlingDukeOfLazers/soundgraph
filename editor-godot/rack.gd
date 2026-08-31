class_name Rack
extends Control

const ModuleThemes := preload("res://module_themes.gd")
const Faceplate := preload("res://faceplate.gd")
const Seams := preload("res://seams.gd")
## Graphrack — the same patch, drawn as a Eurorack case.
##
## This is a *view*, not a second editor. It reads the same document, the same registry
## descriptors and the same layering as the graph view, and writes parameter changes back
## through the same path. Nothing here knows anything about audio that the core has not
## published, and there is no second copy of the node vocabulary: a module's knobs and
## jacks are whatever the descriptor says the node has.
##
## Why it exists: a signal-flow graph is the honest picture, but a rack is the picture
## musicians already know how to read, and it is the one that stops people walking past a
## stand. Both are true at once, so both are drawn, and which one leads at Knobcon is a
## question to answer by watching people rather than by arguing.
##
## Layout is deliberately not free-form. Modules are ordered by the layering the graph view
## already computed — signal flows left to right — and then flowed into rack rows. A real
## case has no coordinates either; you slide modules along a rail.

const Layout := preload("res://layout.gd")
const CableArt := preload("res://cable_art.gd")

signal parameter_changed(node_id: String, parameter: String, value: float)
signal edit_started()

## Ctrl-click on a knob: bind the next MIDI CC the hardware sends to it.
signal learn_requested(node_id: String, parameter: String)
signal edit_finished(label: String)
signal node_selected(node_id: String)
## Somebody right-clicked a panel and wants to repaint that one. The rack does not own
## the menu: what themes exist and how an edit is recorded are the editor's business, and
## a view that opened its own popup would be deciding both.
signal theme_requested(node_id: String, at: Vector2)

## Cable rendering. The A/B is the point: a hanging cable reads as a real instrument, an
## orthogonal one reads as a circuit, and it is not obvious which wins in front of people.
## CATENARY hangs a cable under its own weight; PCB routes it in lanes; PHYSICAL is the
## illustrated patch cord — the same hang, drawn as an object with a plug in a socket.
##
## Three styles rather than a replacement, because the point of the A/B is that the
## catenary is not obviously worse. It is cheaper, it is already tuned, and on a dense
## rack the extra material may cost more legibility than it buys.
enum CableStyle { CATENARY, PCB, PHYSICAL }

## Where a cable's colour comes from.
##
## TYPE is what the rack has always done: audio one colour, control another, so the
## picture says something true about the patch. With two signal types in the whole
## vocabulary that means a rack is two colours, and the physical renderer turns that into
## a wall of yellow — which is a fact about the palette test, not about the palette.
##
## CABLE is what a real case looks like. You reach into the bag and take whatever is
## there, so colour carries no meaning at all and the eight candy colours are all in play.
## Nothing has been decided here; it exists so the question can be looked at rather than
## argued about, and the stress patch is rendered both ways.
enum CableColouring { TYPE, CABLE }

## The bag, in a fixed order. A cable takes its colour from where it sits in the document,
## so a patch keeps the same colours every time it is opened.
const CABLE_BAG: Array[String] = ["cyan", "amber", "magenta", "chartreuse", "violet",
	"orange", "teal", "coral"]

# Eurorack geometry, in pixels rather than millimetres. HP is the real horizontal pitch
# unit; module widths are whole numbers of it, which is what makes a wall of modules line
# up the way a real case does.
const HP := 24.0
const MIN_HP := 6
## How tall a module is, in three settings.
##
## It was a flat 404 for everything, so a Gain with one knob got the same panel as a
## filter with six and spent most of it empty — half a screen of blank aluminium per
## module. Height comes from content now: title, however many knob rows there are,
## two rows of jacks, and a per-density allowance for the space between them.
##
## Compact spends nothing on that space. Instrument leaves a modest band, which is
## what makes a rack read as hardware rather than as a list. Analysis leaves room for
## a module to show what it is doing — and a simple oscillator stays short in all
## three, because the point is not to fill the space but to stop reserving it.
enum Density { COMPACT, INSTRUMENT, ANALYSIS }

const DENSITY_NAMES := ["Compact", "Instrument", "Analysis"]
const DENSITY_BAND := [0.0, 54.0, 150.0]

static var density: int = Density.INSTRUMENT

## The floor, so a module with no knobs at all is still a module.
const MODULE_MIN_HEIGHT := 190.0

## The height every module in this rack shares, worked out from the busiest one.
##
## Uniform on purpose: modules in a real case share a rail, and a rack of ragged
## panels stops looking like hardware. What was wrong was not that they matched, it
## was that they matched a constant — so a patch of two-knob oscillators reserved the
## same 404px as a patch with a six-parameter filter in it, and spent the difference
## on nothing.
## The height a rack module has before any patch has been measured — and the height the
## file's panel holds its blocks to. The rack recomputes module_height from the busiest
## module because a rail must fit its tallest occupant; the panel keeps the default and
## spends *width* instead, spilling a busy node into another bank of knobs sideways.
const DEFAULT_HEIGHT := 404.0

static var module_height := DEFAULT_HEIGHT


## The height a module needs for its own content, before the density band.
##
## The jacks used to be stacked under the knobs and cost two rows of height on every
## module whether it had four ports or one. They are beside them now — inputs down the
## left edge, outputs down the right — so the height is whichever of the two columns is
## taller, and a two-knob oscillator is a short module again.
static func content_height(parameters: int, ports: int = 0) -> float:
	var knob_rows: int = int(ceil(parameters / 2.0))
	return TITLE_BAND + KNOB_PAD * 2.0 + maxf(knob_rows * KNOB_CELL.y,
		ports * JACK_ROW_HEIGHT)


## Recomputed whenever the rack is rebuilt or the density changes.
static func measure(patch_nodes: Array, registry: Dictionary) -> float:
	var tallest := MODULE_MIN_HEIGHT
	for node in patch_nodes:
		var type_key: String = Seams.registry_key(node)
		var descriptor: Dictionary = registry.get(type_key, {})
		tallest = maxf(tallest, content_height(
			int(descriptor.get("parameters", []).size()),
			maxi(int(descriptor.get("inputs", []).size()),
				int(descriptor.get("outputs", []).size()))))
	# Scaled once, here, rather than at each term. The shared height has to be at least
	# what the tallest module's own contents ask for, and those grow with the reader's
	# size preference; left unscaled, every module at XL outgrew the shared height
	# individually and the rack went ragged, which is the one thing a rack must not be.
	return Design.scale(tallest + DENSITY_BAND[density])


const RAIL := 16.0
const ROW_GAP := 34.0
const CASE_MARGIN := 26.0

const TITLE_BAND := 40.0
const JACK_RADIUS := 11.0
const JACK_ROW_HEIGHT := 46.0
const KNOB_RADIUS := 21.0
const KNOB_CELL := Vector2(66.0, 78.0)

## Breathing room inside a knob cell, and between the knob grid and the panel edges.
##
## The cell used to be a constant 66px and the name and the value were drawn centred at
## whatever width they happened to measure, with no bound at all — so "cutoff_sweep" ran
## straight over "mode" on the next knob and "safety_limit" left the panel entirely. A
## cell is now as wide as the widest thing in it, which is what the padding is measured
## from rather than added to.
const KNOB_PAD := 10.0

## How much of a port name a panel shows before eliding it. The full name is on the
## tooltip; what the panel owes the reader is enough to tell one jack from the next.
const JACK_LABEL_MAX := 92.0


## The knob and the socket, after the reader's size preference.
##
## Geometry was the one part of this panel that ignored the setting: at XL the labels
## grew 35% and the thing they label stayed 21px, so the knobs read as undersized
## controls on an oversized panel — and at Compact the socket was a smaller target than
## the hit-size rule allows anywhere else in the application.
static func knob_radius() -> float:
	return Design.scale(KNOB_RADIUS)


static func jack_radius() -> float:
	return Design.scale(JACK_RADIUS)

# Cable sag, as a fraction of the horizontal span, clamped so that a very short patch still
# droops and a very long one does not fall off the case.
const SAG_FRACTION := 0.30
const SAG_MIN := 46.0
const SAG_MAX := 260.0

const PANEL := Color(0.157, 0.169, 0.200)
const PANEL_LOW := Color(0.125, 0.137, 0.165)
const PANEL_EDGE := Color(1, 1, 1, 0.07)
const RAIL_COLOUR := Color(0.086, 0.094, 0.110)
const RAIL_EDGE := Color(1, 1, 1, 0.05)
const SCREW := Color(0.42, 0.45, 0.50)
## Steel, lit from above. Two tones: the face and the shaded rim under it.
##
## Darker than the first attempt, which put a 0.64 steel under a 40% highlight and made
## every screw the brightest thing on the panel - four white dots per module, pulling the
## eye to the corners and away from the knobs. A screw should be findable and never
## looked at.
## One place the size is written down, so a call site cannot fall behind it.
const SCREW_RADIUS := 6.8
const SCREW_STEEL := Color(0.52, 0.55, 0.60)
const SCREW_STEEL_LOW := Color(0.26, 0.29, 0.34)
const JACK_RING := Color(0.62, 0.65, 0.70)
const JACK_HOLE := Color(0.055, 0.06, 0.07)
const KNOB_BODY := Color(0.235, 0.251, 0.290)
const KNOB_TRACK := Color(1, 1, 1, 0.13)


## Whether the faceplate is a light material.
##
## Everything the case draws on top of itself has to know: a white 13% track reads as a
## groove on anodised black and as nothing at all on ivory, and the answer is not two sets
## of constants but one question asked of the panel.
static func panel_is_light() -> bool:
	return PANEL.get_luminance() > 0.42


## A wash over the faceplate — the light or dark that lies on top of it, whichever the
## material calls for, at the given strength.
static func on_panel(alpha: float) -> Color:
	return Color(0, 0, 0, alpha) if panel_is_light() else Color(1, 1, 1, alpha)


## Ink that can be read on this faceplate. 1.0 is the panel legend, lower is secondary.
static func panel_ink(strength := 1.0) -> Color:
	var full: Color = Color(0.09, 0.09, 0.10) if panel_is_light() \
		else Color(0.96, 0.96, 0.97)
	return PANEL.lerp(full, clampf(strength, 0.0, 1.0))
const SELECTED := Color(0.43, 0.91, 0.72)

# Category tints, deliberately muted.
#
# These were at full saturation, which put a red AMPLIFIER stripe and an orange
# FILTERS stripe in direct competition with the mint audio cable and the blue
# modulation cable — two colour languages at the same volume, and the reader has to
# keep them apart. The highest saturation in this application belongs to signal
# semantics; a category is a hint about what a module is for, and a hint should look
# like one. Colour was never the only carrier here anyway: every module is titled and
# every jack is labelled.
const CATEGORY_SATURATION := 0.42

const CATEGORY_TINT := {
	"Terminals": Color(0.55, 0.72, 1.00),
	"Sources": Color(0.43, 0.91, 0.72),
	"Filters": Color(1.00, 0.80, 0.45),
	"Time": Color(0.80, 0.66, 1.00),
	"Amplitude": Color(1.00, 0.62, 0.60),
	"Modulation": Color(0.55, 0.86, 0.95),
	"Maths": Color(0.72, 0.76, 0.84),
}


## The colours a module is painted in, resolved from its theme.
##
## Every drawing routine below takes one of these rather than reaching for the constants
## directly, so that "what colour is a knob" has exactly one answer per module and the
## default is still the constants it always was.
##
## The category theme returns today's panel unchanged - this is the same rack it has
## always been until somebody asks for something else.
static func skin(key: String) -> Dictionary:
	if key == "" or key == ModuleThemes.CATEGORY or not ModuleThemes.THEMES.has(key):
		return {
			"panel": PANEL, "panel_low": PANEL_LOW, "panel_edge": PANEL_EDGE,
			"legend": Color(0, 0, 0, 0),   # empty: the rack's own ink is used
			"highlight": Color(0, 0, 0, 0), "muted": Color(0, 0, 0, 0),
			"accent": Color(0, 0, 0, 0), "hardware": Color(0, 0, 0, 0),
			"hardware_hi": Color(0, 0, 0, 0),
			"knob": KNOB_BODY, "pointer": Color(0, 0, 0, 0),
			"jack": JACK_HOLE, "ring": JACK_RING, "screw": SCREW,
			"stripe": true, "finish": "", "grain": 0.0,
		}
	var face := ModuleThemes.token(key, "faceplate")
	var grain: float = float(ModuleThemes.THEMES[key].get("grain", 0.05))
	return {
		"panel": face,
		"panel_low": ModuleThemes.token(key, "edge"),
		# The highlight along the left edge, scaled by how rough the finish is meant to
		# be. A matte panel catches less light than a machined one.
		"panel_edge": Color(1, 1, 1, clampf(grain, 0.02, 0.14)),
		"legend": ModuleThemes.token(key, "legend"),
		# The lit top of the plate, the thinner ink, the one functional colour, and the
		# moulded black every board in the family puts its knobs in. Carried on the skin
		# rather than looked up at each drawing site, so that a panel drawn in the rack
		# and the same panel drawn in the graph cannot drift apart.
		"highlight": ModuleThemes.token(key, "highlight"),
		"muted": ModuleThemes.token(key, "muted"),
		"accent": ModuleThemes.token(key, "accent"),
		"hardware": ModuleThemes.token(key, "hardware"),
		"hardware_hi": ModuleThemes.token(key, "hardware_hi"),
		"knob": ModuleThemes.token(key, "knob"),
		"pointer": ModuleThemes.token(key, "pointer"),
		"jack": ModuleThemes.token(key, "jack"),
		"ring": ModuleThemes.token(key, "ring"),
		"screw": ModuleThemes.token(key, "screw"),
		# The category stripe is the default theme's way of saying what a module is. A
		# painted panel says it a different way, and two of them at once is noise.
		"stripe": false,
		"finish": str(ModuleThemes.THEMES[key].get("finish", "matte")),
		"grain": grain,
	}


## A category colour, quietened so the signal colours keep the loudest voice.
static func category_tint(category: String) -> Color:
	var base: Color = CATEGORY_TINT.get(category, Color(0.72, 0.76, 0.84))
	var muted := Color.from_hsv(base.h, base.s * CATEGORY_SATURATION, base.v)
	return muted

var registry: Dictionary = {}
var patch: Dictionary = {}
var type_colours: Dictionary = {}


## What colour a signal is drawn in, after the patch's theme has had its say.
##
## A theme carries four cable colours and there are four kinds of signal, so they are
## handed out in order rather than scattered: the theme changes what the language looks
## like without changing that there is one. Following audio by its colour still works on
## a mustard rack; it is simply a different colour.
##
## Cables take the *patch's* theme, never a module's. A cable between a teal panel and an
## orange one has no business being two colours, and a rack's wiring is one system
## however the panels are painted.
const SIGNAL_ORDER := ["audio", "control", "event", "note"]

## The cable-colour override for diagnostic nodes, in one place so the rack, the graph
## and the landing marks cannot disagree about what a lane wears.
##
## A cable leaving a CableTest output takes the candy palette by lane — out1 wears the
## first cable colour, out8 the eighth — overriding the signal-type colour entirely.
## That is the node's whole job: two of them wired straight across show every cable
## colour once, in order, and a rendering change that costs a colour its identity shows
## up as two cables that suddenly match. Transparent means no override.
static func cable_override(from_type: String, output_index: int) -> Color:
	if from_type != "CableTest" or output_index < 0:
		return Color(0, 0, 0, 0)
	return CableArt.PALETTE[CableArt.PALETTE_ORDER[
		output_index % CableArt.PALETTE_ORDER.size()]]


## A named output's position among its type's outputs, from the registry. -1 for a port
## the registry does not know, which no override should touch.
func output_index(type_name: String, port: String) -> int:
	var outputs: Array = registry.get(type_name, {}).get("outputs", [])
	for index in outputs.size():
		if str((outputs[index] as Dictionary).get("name", "")) == port:
			return index
	return -1


func node_type(node_id: String) -> String:
	for node in patch.get("nodes", []):
		if str((node as Dictionary).get("id", "")) == node_id:
			return str((node as Dictionary).get("type", ""))
	return ""

func signal_colour(type_name: String, fallback: Color = Color.WHITE) -> Color:
	var palette: Array = ModuleThemes.cables(
		str(patch.get("arrangement", {}).get("theme", "")))
	var index := SIGNAL_ORDER.find(type_name)
	if not palette.is_empty() and index >= 0 and index < palette.size():
		return palette[index]
	return type_colours.get(type_name, fallback)
## TYPE or CABLE. See CableColouring.
var cable_colouring: int = CableColouring.TYPE:
	set(value):
		cable_colouring = value
		redraw_cables()

## Returns the samples on a node's output, or an empty array. Set by the editor.
##
## A callable rather than a reference to the engine, so the rack goes on knowing
## nothing about the extension — it asks a question and gets numbers back, which is
## also what makes it testable without an audio device.
var read_port: Callable = Callable()
## Where a knob's double tap goes: (node_id, parameter_name, fallback) -> float,
## answered by the editor from the values the node entered the document with. Left
## unset, the descriptor's factory default stands.
var home_lookup: Callable = Callable()
var ink: Color = Rack.panel_ink(1.0)
var ink_dim: Color = Rack.panel_ink(0.62)

## PHYSICAL by default: this is the physical lens, and the cords — the landing marks,
## the material stack, the crossing occlusion — are its cable language. The thin
## catenary and PCB modes remain reachable in code for the lab and for tests, but the
## app itself no longer starts the rack in a diagram style. Which is exactly how weeks
## of cord work stayed invisible: every render script flipped this to PHYSICAL by hand,
## the menu only offered the other two, and the default made the screenshots a fiction.
var cable_style: int = CableStyle.PHYSICAL:
	set(value):
		cable_style = value
		redraw_cables()

## Case width in HP, or 0 to fill whatever space there is.
##
## Filling the window is the default because the window is the case: on a wide screen a
## fixed width leaves a stripe of empty rail doing nothing. But a real rack does have a
## width — 84 HP and 104 HP are the common ones — and building a patch that would actually
## fit a case you own is a reasonable thing to want, so it stays available.
var case_hp: int = 0:
	set(value):
		case_hp = value
		_relayout()

## How far away the viewer stands. 1.0 is workbench distance; a 168 HP case on a
## laptop needs the room. Purely visual — layout happens in unscaled units and the
## wrap width is the case's, not the window's.
var view_zoom := 1.0:
	set(value):
		view_zoom = clampf(value, 0.25, 1.0)
		scale = Vector2(view_zoom, view_zoom)
		_relayout()


## The zoom at which the whole case width fits the window, chosen when a case is
## picked so the answer to "does my patch fit an 84 HP case" is visible immediately.
func fit_case() -> void:
	if case_hp <= 0:
		view_zoom = 1.0
		return
	# The window is the scroll container, not this control: once a case is set the
	# rack is exactly as wide as the case, and measuring yourself answers 1.0 forever.
	var scroll: Control = get_parent()
	if scroll != null and scroll.get_parent() is Control:
		scroll = scroll.get_parent()
	var window := maxf(scroll.size.x if scroll != null else size.x, 200.0)
	view_zoom = window / (case_hp * HP + CASE_MARGIN * 2.0)

var selected_id := ""

## Which cable the pointer is over, as an index into cable_endpoints(), or -1.
var hovered_cable := -1

## A cable held in view until something else is asked for. Selection is persistent hover:
## the same hierarchy, kept, because tracing a cable across a rack usually means looking
## away from it — at the module it lands on — and a highlight that dies on mouse-out is no
## use for the one job it exists to do.
var selected_cable := -1:
	set(value):
		selected_cable = value
		redraw_cables()

## The jack under the pointer, as {"node": id, "port": name, "input": bool}, or empty.
##
## Hovering a plugged jack asks the same question as hovering the cable — where does this
## go — from the other end, and it is the end you are usually looking at when you ask.
var hovered_jack: Dictionary = {}:
	set(value):
		hovered_jack = value
		redraw_cables()

## A module whose panel is being read, so the cables lying across it stand down.
##
## Set on hover, after a pause. Without the pause every sweep of the pointer across the
## case flickers half the patch, and a cue that fires when you were not asking is worse
## than no cue.
var inspected_id := "":
	set(value):
		inspected_id = value
		redraw_cables()

## Every cable out of the way at once, while a key is held.
##
## The panel-first view without leaving the instrument for the diagram. Temporary on
## purpose: a mode you can be in without noticing is how the physical renderer would end
## up quietly abandoned.
var cables_ghosted := false:
	set(value):
		if cables_ghosted == value:
			return
		cables_ghosted = value
		redraw_cables()

var _inspect_candidate := ""

## Where a hand-set rack order lives in the document.
##
## Under "arrangement" rather than "metadata". Metadata is what a person wrote about the
## patch — its name, who made it, what it is for — and a list of node ids is not that.
## Arrangement is declared in the schema as presentation-only, so anything that just wants
## to make sound can skip the whole object and lose nothing.
##
## A separate .rack file was the other candidate and is worse: the browser has no
## filesystem, so Open is a file picker and Save is a download, and a sidecar would mean
## two of each and a patch that arrives without its layout whenever somebody forgets the
## second file. One file that carries its own presentation travels properly.
const ARRANGEMENT_KEY := "arrangement"
const ORDER_KEY := "rack_order"

## Explicit rack order, set by dragging. Empty means "use the layering", which is the
## default and what a freshly loaded patch gets.
var _order_override: Array = []

var _modules: Dictionary = {}          # node id -> RackModule
var _knobs: Dictionary = {}            # node id -> {parameter name -> Knob}
var _cables: CableLayer
var _content_size := Vector2.ZERO


func _ready() -> void:
	# The ghost modifier is a key held anywhere over the case, not a click on a control,
	# so it comes through _input rather than _gui_input.
	set_process_input(true)
	_cables = CableLayer.new()
	_cables.rack = self
	_cables.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# The cable layer is decoration over the top of the modules; it must never take a click
	# that was meant for a knob underneath it.
	_cables.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_cables)
	resized.connect(_relayout)


# ---------------------------------------------------------------------------------
# Building
# ---------------------------------------------------------------------------------

## Redraws the analysis displays. Called by the editor while the rack is on screen.
##
## Every third frame rather than every one: this is a meter, and a meter that updates
## twenty times a second is already faster than anybody can read. Doing it per frame
## would mean a call across the extension boundary per module per frame for a picture
## nobody could tell apart from this one.
var _display_tick := 0

## The module showing a given patch node, or null.
func module_for(node_id: String):
	for child in get_children():
		if child is RackModule and (child as RackModule).node_id == node_id:
			return child
	return null


func refresh_displays() -> void:
	if density != Density.ANALYSIS:
		return
	_display_tick += 1
	if _display_tick % 3 != 0:
		return
	for child in get_children():
		if child is RackModule:
			(child as RackModule).accumulate()
			child.queue_redraw()


func rebuild() -> void:
	# The cables are redrawn again once this has settled: they are drawn between jacks,
	# and the jacks do not know where they are until the layout that follows this call.
	redraw_cables_when_settled()
	# Before anything is placed, because every module is built against it.
	module_height = measure(patch.get("nodes", []), registry)
	for child in get_children():
		if child is RackModule:
			remove_child(child)
			child.queue_free()
	_modules.clear()
	_knobs.clear()
	# A different document is a different rack. Order set by hand does not carry over.
	if _order_override.size() > 0:
		var still_here: Array = []
		for id in _order_override:
			for node in patch.get("nodes", []):
				if str(node["id"]) == id:
					still_here.append(id)
					break
		_order_override = still_here

	# A document arriving with a remembered order takes it, so loading a patch puts the
	# modules back where they were left.
	if _order_override.is_empty():
		var stored: Array = patch.get(ARRANGEMENT_KEY, {}).get(ORDER_KEY, [])
		if not stored.is_empty():
			var present := {}
			for node in patch.get("nodes", []):
				present[str(node["id"])] = true
			# Ids that are no longer in the patch are skipped, and nodes missing from the
			# list are appended by _module_order. An out-of-date hint degrades rather than
			# breaks, which is the only sane behaviour for something optional.
			for id in stored:
				if present.has(str(id)):
					_order_override.append(str(id))

	for node in patch.get("nodes", []):
		var module := RackModule.new()
		module.rack = self
		module.node_id = str(node["id"])
		module.type_name = Seams.registry_key(node)
		module.descriptor = registry.get(module.type_name, {})
		var given_name: String = str(node.get("name", ""))
		module.title = given_name if given_name != "" else \
			str(module.descriptor.get("display_name", module.type_name))
		module.tooltip_text = str(module.descriptor.get("summary", ""))
		add_child(module)
		_modules[module.node_id] = module
		_knobs[module.node_id] = module.build(node)

	# The cable layer is added first but must draw last, over every module.
	move_child(_cables, get_child_count() - 1)
	_relayout()


## Module order comes from the graph view's own layering rather than a second algorithm.
## A rack has no coordinates — you slide modules along a rail — so all that is wanted from
## the layout is the reading order, which is exactly what the layering gives: signal left
## to right, and within a column the ordering that minimises crossings.
func _module_order() -> Array:
	var ids: Array = []
	var sizes: Dictionary = {}
	for node in patch.get("nodes", []):
		var id := str(node["id"])
		ids.append(id)
		var module: RackModule = _modules.get(id)
		sizes[id] = module.size if module != null else Vector2(144, module_height)
	if ids.is_empty():
		return []

	var edges: Array = []
	for connection in patch.get("connections", []):
		var from_id := str(connection["from"]["node"])
		var to_id := str(connection["to"]["node"])
		# Same weighting the graph view uses: the audio path is the spine, modulation hangs
		# off it. Without this an LFO can push the signal chain out of line.
		var weight := 1.0
		var descriptor: Dictionary = registry.get(_type_of(from_id), {})
		for port in descriptor.get("outputs", []):
			if str(port.get("name", "")) == str(connection["from"]["port"]):
				weight = 8.0 if str(port.get("type", "")) == "audio" else 1.0
		edges.append([from_id, to_id, weight])

	# A hand-set order wins. Anything added since is appended, so a new node appears at the
	# end rather than silently reshuffling everything that was placed deliberately.
	if _order_override.size() > 0:
		var ordered: Array = []
		for id in _order_override:
			if ids.has(id):
				ordered.append(id)
		for id in ids:
			if not ordered.has(id):
				ordered.append(id)
		return ordered

	var placed: Dictionary = Layout.arrange({
		"nodes": ids, "edges": edges, "sizes": sizes,
		"grid": 40.0, "column_pitch": 400.0, "column_gutter": 80.0, "row_step": 200.0,
	})

	# Sort by the laid-out position, then by id so the result is stable when two modules
	# land in the same place.
	ids.sort_custom(func(a: String, b: String) -> bool:
		var pa: Vector2 = placed.get(a, Vector2.ZERO)
		var pb: Vector2 = placed.get(b, Vector2.ZERO)
		if not is_equal_approx(pa.x, pb.x):
			return pa.x < pb.x
		if not is_equal_approx(pa.y, pb.y):
			return pa.y < pb.y
		return a < b)
	return ids


func _type_of(node_id: String) -> String:
	for node in patch.get("nodes", []):
		if str(node["id"]) == node_id:
			# Instances resolve to their synthesized descriptor key and seams to the
			# terminal they are, so this view treats both like any node without ever
			# learning what either one is.
			return Seams.registry_key(node)
	return ""


## Flow the modules into rack rows, wrapping at the case width. A module is never split
## across rows and never resized to fit — a rack that reflows by stretching its modules
## would not look like a rack.
func _relayout() -> void:
	# A chosen case is exactly as wide as it says, even when the window is not:
	# the point of picking 84 HP is seeing what fits in 84 HP, and clamping to the
	# window silently answered a different question. The window catches up through
	# view_zoom instead. The span comes from the holder — this control sizes itself.
	var host := get_parent() as Control
	var span: float = host.size.x if host != null else size.x
	# A hidden tab's holder may not have been laid out yet; walk up to whatever has
	# real width rather than wrapping the whole rack at the 200px floor.
	if span <= 1.0 and host != null and host.get_parent() is Control:
		span = (host.get_parent() as Control).size.x
	if span <= 1.0:
		span = maxf(size.x, get_viewport_rect().size.x if is_inside_tree() else 0.0)
	var available := maxf(span / maxf(view_zoom, 0.01) - CASE_MARGIN * 2.0, 200.0)
	if case_hp > 0:
		available = case_hp * HP
	var x := CASE_MARGIN
	var y := CASE_MARGIN + RAIL
	var row_widest := 0.0

	for id in _module_order():
		var module: RackModule = _modules.get(id)
		if module == null:
			continue
		if x > CASE_MARGIN and x + module.size.x > CASE_MARGIN + available:
			x = CASE_MARGIN
			y += module_height + RAIL * 2.0 + ROW_GAP
		module.position = Vector2(x, y)
		x += module.size.x
		row_widest = maxf(row_widest, x)

	# Room below the last row for cables to hang into. Without it a catenary between two
	# modules on the bottom row is clipped off by the scroll extent.
	if case_hp > 0:
		row_widest = maxf(row_widest, CASE_MARGIN + case_hp * HP)
	_content_size = Vector2(row_widest + CASE_MARGIN,
		y + module_height + RAIL + CASE_MARGIN + SAG_MAX * 0.5)
	# Outside a container, this control sizes itself; the holder carries the scaled
	# footprint into the scroll area's arithmetic.
	size = Vector2(maxf(_content_size.x, span / maxf(view_zoom, 0.01)), _content_size.y)
	if host != null:
		host.custom_minimum_size = Vector2(
			_content_size.x * view_zoom if case_hp > 0 else 0.0,
			_content_size.y * view_zoom)
	queue_redraw()
	redraw_cables()


## Moves a module to the slot nearest a point, in rack coordinates.
func move_module_to(node_id: String, at: Vector2) -> void:
	var order: Array = _module_order()
	var from := order.find(node_id)
	if from < 0:
		return

	# The target slot is whichever module currently covers that point, by centre distance.
	# Comparing centres rather than edges is what makes a drag land where it looks like it
	# should when modules are different widths.
	# Taken out of the running first. Comparing the drop point against every module
	# *including the one being dropped* only ever finds that module — it is sitting under
	# the cursor at distance zero — so the answer was always "where it already was" and
	# every drag snapped back.
	order.remove_at(from)

	# Where it lands is the first slot that reads as *after* the drop point: a row below,
	# or further right on the same row. Reading order rather than nearest centre, because
	# a rack is a sequence and dropping between two modules should mean between them.
	var insert_at := order.size()
	for index in order.size():
		var module: RackModule = _modules.get(order[index])
		if module == null:
			continue
		var centre := module.position + module.size * 0.5
		var a_row_below := centre.y > at.y + module_height * 0.5
		var further_right := absf(centre.y - at.y) <= module_height * 0.5 and centre.x > at.x
		if a_row_below or further_right:
			insert_at = index
			break

	order.insert(insert_at, node_id)
	_order_override = order
	_store_order()
	_relayout()


## Back to the order the layering gives, which is what a freshly loaded patch shows.
func clear_order_override() -> void:
	_order_override.clear()
	if patch.has(ARRANGEMENT_KEY):
		patch[ARRANGEMENT_KEY].erase(ORDER_KEY)
		if patch[ARRANGEMENT_KEY].is_empty():
			patch.erase(ARRANGEMENT_KEY)
	_relayout()


## Writes the order into the document so that saving keeps it.
func _store_order() -> void:
	if not patch.has(ARRANGEMENT_KEY):
		patch[ARRANGEMENT_KEY] = {}
	patch[ARRANGEMENT_KEY][ORDER_KEY] = _order_override.duplicate()


func select(node_id: String) -> void:
	selected_id = node_id
	for id in _modules:
		_modules[id].queue_redraw()
	# The cables care too, now that selecting a module turns down everything it is not
	# connected to. They live in their own layer, so redrawing the modules misses them.
	redraw_cables()


## Called when a value changed somewhere else — the graph view's slider, an undo, a reload —
## so the two views cannot drift apart. Deliberately does not emit: this is a display
## update, not an edit.
func show_parameter(node_id: String, parameter: String, value: float) -> void:
	var knobs: Dictionary = _knobs.get(node_id, {})
	var knob: Knob = knobs.get(parameter)
	if knob != null:
		knob.set_value_silently(value)


# ---------------------------------------------------------------------------------
# The case itself
# ---------------------------------------------------------------------------------

func _draw() -> void:
	# Rails behind every row, drawn the full width so the case reads as continuous even
	# where a row is not full.
	var row_pitch := module_height + RAIL * 2.0 + ROW_GAP
	var rows := int(ceil(maxf(_content_size.y - CASE_MARGIN, 1.0) / row_pitch))
	# Rails span the case when one is chosen — a rail that stopped at the window's
	# edge would deny the case its width — and the window otherwise.
	var rail_width: float = (_content_size.x - CASE_MARGIN * 0.5 \
		if case_hp > 0 else size.x / maxf(view_zoom, 0.01) - CASE_MARGIN)
	for row in maxi(rows, 1):
		var top := CASE_MARGIN + row * row_pitch
		_draw_rail(Rect2(CASE_MARGIN * 0.5, top, rail_width, RAIL))
		_draw_rail(Rect2(CASE_MARGIN * 0.5, top + RAIL + module_height,
			rail_width, RAIL))
	if case_hp > 0:
		_draw_hp_ruler(rows, row_pitch)


## Tick marks along each top rail, in HP: a small tick every two, a numbered one
## every eight, and a bright cap at the case's exact end. This is what makes "84 HP"
## read as a measurement instead of a mood — the same reason a real rail has holes.
func _draw_hp_ruler(rows: int, row_pitch: float) -> void:
	var font := Design.numeric_font()
	var font_size := Design.scale(11)
	var end_x := CASE_MARGIN + case_hp * HP
	for row in maxi(rows, 1):
		var top := CASE_MARGIN + row * row_pitch
		for hp in range(0, case_hp + 1, 2):
			var x := CASE_MARGIN + hp * HP
			var major := hp % 8 == 0
			var tick := RAIL * (0.6 if major else 0.3)
			draw_line(Vector2(x, top + RAIL - tick), Vector2(x, top + RAIL),
				Color(Design.INK_SECOND.r, Design.INK_SECOND.g, Design.INK_SECOND.b, 0.5 if major else 0.25), 1.0)
			if major and hp > 0 and hp < case_hp:
				draw_string(font, Vector2(x + 3.0, top + RAIL - 2.0), str(hp),
					HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size,
					Color(Design.INK_SECOND.r, Design.INK_SECOND.g, Design.INK_SECOND.b, 0.55))
		# The end of the case, capped bright: the wall a patch does or does not fit.
		draw_line(Vector2(end_x, top), Vector2(end_x, top + RAIL * 2.0 + module_height),
			Color(Design.BOUNDARY.r, Design.BOUNDARY.g, Design.BOUNDARY.b, 0.8), 2.0)


func _draw_rail(rect: Rect2) -> void:
	Rack.draw_rail(self, rect)


## One mounting rail: the strip, its lit edge, and the threaded holes along it.
##
## Shared, like the plate and the socket, because the file's panel is a case too — the
## rack draws rails between rows and the panel draws them above and below its own, and a
## rail that looked different in the two places would be saying they were different rails.
static func draw_rail(canvas: CanvasItem, rect: Rect2) -> void:
	canvas.draw_rect(rect, RAIL_COLOUR)
	canvas.draw_line(rect.position, rect.position + Vector2(rect.size.x, 0.0),
		RAIL_EDGE, 1.0)
	# The threaded strip along a rail, suggested rather than drawn to scale.
	var slot := rect.position + Vector2(14.0, rect.size.y * 0.5)
	while slot.x < rect.end.x - 8.0:
		canvas.draw_circle(slot, 1.6, on_panel(0.06))
		slot.x += 24.0


# ---------------------------------------------------------------------------------
# Cables
# ---------------------------------------------------------------------------------

## Every cable, as [from_position, to_position, colour]. Positions are in rack space.
## Mouse motion over the case itself — which is where the cables are.
##
## The modules take their own input, so this only sees the gaps between them, and the
## gaps are exactly where a hanging cable is. A cable that runs behind a module is
## unreachable, which is correct: you cannot touch it there either.
func _gui_input(event: InputEvent) -> void:
	var motion := event as InputEventMouseMotion
	if motion != null:
		_update_cable_hover(motion.position)
	# A click on the case selects the cable under it, or clears the selection when there
	# is none. Selection is persistent hover, so it is picked up the same way.
	var click := event as InputEventMouseButton
	if click != null and click.pressed and click.button_index == MOUSE_BUTTON_LEFT \
			and not click.ctrl_pressed:
		selected_cable = cable_at(click.position)
		accept_event()
	# Ctrl+wheel is the view's zoom gesture here as on the graph. Claimed loudly, or
	# the ScrollContainer would spend the same notches scrolling.
	var wheel := event as InputEventMouseButton
	if wheel != null and wheel.pressed and wheel.ctrl_pressed:
		if wheel.button_index == MOUSE_BUTTON_WHEEL_UP:
			view_zoom = view_zoom * 1.1
			accept_event()
		elif wheel.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			view_zoom = view_zoom / 1.1
			accept_event()


## Nothing under the pointer means nothing highlighted, and leaving the case entirely
## has to count — otherwise the last cable hovered stays lit for ever.
func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT and hovered_cable != -1:
		hovered_cable = -1
		redraw_cables()
	# A modifier held while the window goes away is never released, because the key-up
	# lands somewhere else. Focus leaving is the only notice we get that it happened.
	elif what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		cables_ghosted = false


## Held, to see the rack under the cables.
##
## The action rather than the key. Which key it is belongs in the input map, where it can
## differ by platform and be remapped without editing a renderer — and the current binding
## is provisional: it is Alt, which is Option on macOS, where it composes characters and
## is spoken for by parts of the window manager. Ctrl was already the zoom gesture here
## and the MIDI-learn click, and Shift is the usual multi-select modifier to leave alone,
## but that reasoning belongs to the binding and not to this file.
##
## Watched as events rather than polled so it releases the moment the key does.
func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ghost_cables"):
		cables_ghosted = true
	elif event.is_action_released("ghost_cables"):
		cables_ghosted = false


## The cable nearest a point, or -1 if none is close enough.
##
## Measured against the drawn curve rather than the straight line between the ends,
## because in this view they are nowhere near each other — a catenary sags a couple
## of hundred pixels below its own chord, so hit-testing the chord would highlight
## whichever cable happened to pass overhead rather than the one under the pointer.
func cable_at(point: Vector2) -> int:
	var cables := cable_endpoints()
	var lane_step := 13.0
	var best := -1
	# A little wider than the cable is drawn, so it can be caught without precision.
	var best_distance := 12.0
	for index in cables.size():
		var entry: Array = cables[index]
		var a: Vector2 = entry[0]
		var b: Vector2 = entry[1]
		var points: PackedVector2Array
		if cable_style == CableStyle.CATENARY:
			var span := absf(b.x - a.x)
			var sag := clampf(span * SAG_FRACTION, SAG_MIN, SAG_MAX)
			points = catenary(a, b, sag)
		else:
			points = pcb_route(a, b, maxf(a.y, b.y) + 34.0 + index * lane_step)
		for i in points.size() - 1:
			var segment := points[i + 1] - points[i]
			var length_squared := segment.length_squared()
			var along: float = 0.0 if length_squared <= 0.0 else clampf(
				(point - points[i]).dot(segment) / length_squared, 0.0, 1.0)
			var distance := point.distance_to(points[i] + segment * along)
			if distance < best_distance:
				best_distance = distance
				best = index
	return best


## Whether a cable should be drawn at full strength rather than turned down.
##
## Hovering beats selection. A pointer resting on a cable is a direct question about that
## one cable, and answering it with "and also everything else touching the selected module"
## answers a question nobody asked.
##
## With nothing hovered and nothing selected everything stays bright: dimming only means
## something when there is something to pick out, and a rack that is permanently three
## quarters faded has just been drawn badly.
##
## Pass the endpoints in if you already have them — the drawing does, and re-reading the
## patch once per cable would make painting the case quadratic in the number of cables.
func cable_related(index: int, cables: Array = []) -> bool:
	return cable_dim_target(index, cables) == 0.0


## The contrast floor a cable should be held at, or 0.0 for full strength.
##
## Stated as a floor rather than an opacity because that is the only form of the
## instruction that survives five palettes — a fixed mix lands at 4.2:1 on Lab and 2.5:1
## on Paper Lab, one inside the readable range and one under it.
##
## The order is the order of how direct the question was. A pointer resting on a cable, or
## on one of its jacks, is a question about that cable; a selected module is a question
## about a handful; and the ghost key is not a question about cables at all, so it beats
## everything and turns the lot down.
func cable_dim_target(index: int, cables: Array = []) -> float:
	if cables_ghosted:
		return CableLayer.GHOST_TARGET

	var entries: Array = cables if not cables.is_empty() else cable_endpoints()
	if index < 0 or index >= entries.size():
		return CableLayer.DIM_TARGET
	var entry: Array = entries[index]

	if hovered_cable >= 0:
		return 0.0 if index == hovered_cable else CableLayer.TRACE_TARGET
	if not hovered_jack.is_empty():
		return 0.0 if _touches_jack(entry, hovered_jack) else CableLayer.TRACE_TARGET
	if selected_cable >= 0:
		return 0.0 if index == selected_cable else CableLayer.TRACE_TARGET
	if selected_id != "":
		var mine: bool = str(entry[3]) == selected_id or str(entry[4]) == selected_id
		return 0.0 if mine else CableLayer.DIM_TARGET
	return 0.0


## Whether one cable in particular is being asked about, by any of the three routes.
##
## Which is what decides both the z-raise and the endpoint marks: a cable held at full
## strength while its neighbours recede is being traced, however the question was put —
## pointer on the cable, pointer on one of its jacks, or a selection made earlier.
func tracing() -> bool:
	return hovered_cable >= 0 or selected_cable >= 0 or not hovered_jack.is_empty()


## Whether a cable ends at a particular jack. Ports as well as nodes: a module with four
## inputs would otherwise light all four cables for whichever one is under the pointer.
func _touches_jack(entry: Array, jack: Dictionary) -> bool:
	var node: String = str(jack.get("node", ""))
	var port: String = str(jack.get("port", ""))
	if bool(jack.get("input", true)):
		return str(entry[4]) == node and str(entry[7]) == port
	return str(entry[3]) == node and str(entry[6]) == port


## Repaint the cables.
##
## Because queue_redraw() on the rack does not: the cables are a child layer, and a
## Control's redraw does not descend. Dragging a module repainted the case and left every
## cable attached to where the module used to be until some unrelated event repainted the
## layer, which looked like the cables had come unplugged.
func redraw_cables() -> void:
	if _cables != null:
		_cables.queue_redraw()


## Draw the cables again once the modules have finished being placed.
##
## A cable is drawn between two jacks, and a jack does not know where it is until the
## containers above it have laid it out — which happens after the frame a rebuild is
## asked for. Draw in that frame and every jack answers with the position it has before
## layout, which is its module's top-left corner. The cables then sit along the top edge
## of each panel, plugged into nothing, and stay there, because nothing asks the layer to
## think again once the real positions exist.
##
## That is what "cables appear to originate from anonymous points along the top edge" was.
## Not a rendering grammar to be retired — a redraw that was one frame early, in a view
## that only redraws when something asks it to. Two frames, because the first settles the
## modules and the second settles the jacks inside them.
func redraw_cables_when_settled() -> void:
	for _frame in 2:
		await get_tree().process_frame
	redraw_cables()


## Whether the surface the cables are lying on is a light one.
##
## Not Rack.panel_is_light(), which asks the default case and is a constant: since the
## faceplate merge that static has answered "dark" for every patch ever loaded, so the
## light-surface cable response has never once fired. Ivory Lab racks have been drawing
## their cables with the construction tuned for anodised black, which is exactly the
## kind of thing a stress test exists to find.
##
## The patch's own panel style decides, because that is what most of the surface under
## a cable is. A rack with per-module overrides is approximated by its prevailing
## theme, which is the honest answer short of asking each cable what it crosses — and
## that question belongs with the stand-down work, where it is already noted.
##
## The approximation has one measured edge, found by the integration sweep and left
## deliberately unfixed. A cable crosses cream panels *and* the dark canvas in the gaps
## between rack rows, and it is built once for the whole run. On Ivory Lab, whose audio
## lead is a near-black 1a1a1a chosen to look like a real black patch cord on cream —
## which it does, beautifully — that lead measures 1.43:1 against the canvas while it
## is in a gap. Its red neighbours measure 4.6:1 and are fine, and no other theme
## carries a near-black cable, so this is one lead of one palette for the width of a
## rail.
##
## Every available fix reopens something already settled: the glint strength Goal 9
## approved, the palette Goal 9 froze, or the per-surface sampling that was deliberately
## deferred as a much larger rendering problem. So it is written down rather than
## patched around, which is the cheaper mistake to undo.
func cables_on_light_panel() -> bool:
	var theme := str(patch.get("arrangement", {}).get("theme", ""))
	if theme == "" or theme == ModuleThemes.CATEGORY:
		return Rack.panel_is_light()
	return ModuleThemes.token(theme, "faceplate").get_luminance() > 0.42


## The panel being read, in rack space, or an empty rect.
func inspected_rect() -> Rect2:
	if inspected_id == "":
		return Rect2()
	var module: RackModule = _modules.get(inspected_id)
	if module == null:
		return Rect2()
	return Rect2(module.position, module.size)


## A module has been under the pointer long enough to count as being read.
##
## The pause is the whole design. Firing on entry means every sweep of the pointer across
## the case flickers half the patch, and a cue that answers a question nobody asked is
## worse than no cue — so the pointer has to stay put, and leaving cancels it.
func inspect_after_pause(node_id: String) -> void:
	_inspect_candidate = node_id
	await get_tree().create_timer(0.45).timeout
	if _inspect_candidate == node_id:
		inspected_id = node_id


func cancel_inspection(node_id: String) -> void:
	if _inspect_candidate == node_id:
		_inspect_candidate = ""
	if inspected_id == node_id:
		inspected_id = ""


## Tracks the cable under the pointer.
func _update_cable_hover(point: Vector2) -> void:
	var found := cable_at(point)
	if found == hovered_cable:
		return
	hovered_cable = found
	redraw_cables()


func cable_endpoints() -> Array:
	var cables: Array = []
	for connection in patch.get("connections", []):
		var from_module: RackModule = _modules.get(str(connection["from"]["node"]))
		var to_module: RackModule = _modules.get(str(connection["to"]["node"]))
		if from_module == null or to_module == null:
			continue
		var a: Variant = from_module.jack_position(str(connection["from"]["port"]), false)
		var b: Variant = to_module.jack_position(str(connection["to"]["port"]), true)
		if a == null or b == null:
			continue
		var signal_type := from_module.port_type(str(connection["from"]["port"]), false)
		# The node ids travel with the geometry, so the layer can tell which cables
		# belong to what without going back to the patch for every one of them.
		# The tighter of the two ends: one style is built per cable, and a plug that fits
		# at one end and overlaps the jack below at the other is still wrong.
		var ink: Color = signal_colour(signal_type)
		var from_port_name := str(connection["from"]["port"])
		var override := Rack.cable_override(node_type(str(connection["from"]["node"])),
			output_index(node_type(str(connection["from"]["node"])), from_port_name))
		if override.a > 0.0:
			ink = override
		if cable_colouring == CableColouring.CABLE:
			# One colour per cable rather than per signal type, taken from the patch's
			# own palette. It reached into CableArt.PALETTE for a bag of candy names,
			# which is a second styling system living beside the first: a rack painted
			# Bakelite Brown would have drawn neon chartreuse leads because the bag said
			# so. The theme already carries four cable colours; this mode cycles them.
			var palette: Array = ModuleThemes.cables(
				str(patch.get("arrangement", {}).get("theme", "")))
			if palette.is_empty():
				palette = []
				for kind: String in SIGNAL_ORDER:
					palette.append(signal_colour(kind))
			ink = palette[cables.size() % palette.size()]
		cables.append([a, b, ink,
			str(connection["from"]["node"]), str(connection["to"]["node"]),
			minf(from_module.jack_pitch(), to_module.jack_pitch()),
			str(connection["from"]["port"]), str(connection["to"]["port"])])
	return cables


## A real catenary: the curve a cable takes under its own weight, y = a·cosh(x/a).
##
## The parabola everyone reaches for is close enough to fool the eye, but the shape is the
## whole reason this view exists — a patch cable that hangs correctly is what makes a rack
## read as an instrument rather than a diagram — so it is worth solving properly. `a` is
## found by bisection from the sag we want at the midpoint; there is no closed form.
static func catenary(a_point: Vector2, b_point: Vector2, sag: float,
		segments: int = 28) -> PackedVector2Array:
	var points := PackedVector2Array()
	var span := absf(b_point.x - a_point.x)
	if span < 1.0 or sag <= 0.0:
		# Vertical or near-vertical: hang straight down and back up.
		points.append(a_point)
		points.append(Vector2((a_point.x + b_point.x) * 0.5,
			maxf(a_point.y, b_point.y) + sag))
		points.append(b_point)
		return points

	# sag = a·(cosh(span / 2a) − 1). Monotonically decreasing in a, so bisect.
	var low := 0.01
	var high := maxf(span, sag) * 40.0
	for _i in 60:
		var mid := (low + high) * 0.5
		var s: float = mid * (cosh(span / (2.0 * mid)) - 1.0)
		if s > sag:
			low = mid
		else:
			high = mid
	var a := (low + high) * 0.5

	# The curve is computed about its own low point, then sheared so the ends meet the two
	# jacks even when they sit at different heights.
	#
	# Strictly, a cable between two unequal points is still a plain catenary with its low
	# point off-centre, not a sheared symmetric one — solving that properly means finding
	# the curve of a given arc length through both points, which is a second numerical
	# solve for a difference no one can see at these spans. The shear keeps the ends exact
	# and the sag honest at the midpoint, which is what the eye is actually reading.
	var left := a_point if a_point.x <= b_point.x else b_point
	var right := b_point if a_point.x <= b_point.x else a_point
	for i in segments + 1:
		var t := float(i) / float(segments)
		var x := (t - 0.5) * span
		var drop: float = a * (cosh(x / a) - cosh(span / (2.0 * a)))
		var point := Vector2(left.x + t * span, lerpf(left.y, right.y, t) - drop)
		points.append(point)
	if a_point.x > b_point.x:
		points.reverse()
	return points


## The other half of the A/B: an orthogonal run, the way a patchbay or a board is wired.
## Each cable gets its own horizontal lane below the row so parallel runs do not overlap.
static func pcb_route(a_point: Vector2, b_point: Vector2, lane: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	points.append(a_point)
	points.append(Vector2(a_point.x, lane))
	points.append(Vector2(b_point.x, lane))
	points.append(b_point)
	return _chamfer(points, 10.0)


static func _chamfer(points: PackedVector2Array, radius: float) -> PackedVector2Array:
	if points.size() < 3:
		return points
	var out := PackedVector2Array()
	out.append(points[0])
	for i in range(1, points.size() - 1):
		var previous := points[i - 1]
		var corner := points[i]
		var next := points[i + 1]
		var into := (corner - previous)
		var away := (next - corner)
		var r := minf(radius, minf(into.length(), away.length()) * 0.5)
		if r <= 0.5:
			out.append(corner)
			continue
		out.append(corner - into.normalized() * r)
		out.append(corner + away.normalized() * r)
	out.append(points[points.size() - 1])
	return out


class CableLayer extends Control:
	const CableArt := preload("res://cable_art.gd")

	var rack: Control

	## How far a cable is turned down when it has nothing to do with what is selected.
	##
	## The contrast floors, from the palette's own scale.
	##
	## Named there rather than here because none of this is about cables: a floor is how
	## far anything is asked to stand down, and the cables were only the first thing that
	## needed four different amounts of it. See Design.STAND_DOWN.
	const DIM_TARGET: float = Design.STAND_DOWN["ASIDE"]
	const TRACE_TARGET: float = Design.STAND_DOWN["TRACE"]
	const INSPECT_TARGET: float = Design.STAND_DOWN["BEHIND"]
	const GHOST_TARGET: float = Design.STAND_DOWN["GHOST"]

	## The mix that goes with each floor, by the floor's own value. Looked up rather than
	## passed around, so a caller that knows how far to stand something down does not also
	## have to know the second half of what that means.
	static func stand_down(ink: Color, surface: Color, target: float) -> Color:
		for level: String in Design.STAND_DOWN:
			if is_equal_approx(Design.STAND_DOWN[level], target):
				return Design.recede(ink, surface, target,
					Design.STAND_DOWN_MIX[level])
		return Design.recede(ink, surface, target)

	## A dimmed cable is drawn thinner as well as quieter.
	##
	## Because contrast alone cannot carry this on every palette. Paper Lab's signal
	## colours start at about 6.5:1 against its case, so once a dimmed one is held at the
	## 3.6 floor there is only 1.8 times left between them — where Lab has 2.6. Rather
	## than let the effect be strong on the dark themes and weak on the light one, some of
	## the work goes to a cue that does not vary with the palette at all.
	##
	## It is also the cue that survives the reader: somebody who cannot separate mint from
	## blue can still see which cable is thinner.
	const DIM_WIDTH := 0.8

	## The shadow under a dimmed cable, as a fraction of the one under a lit cable.
	##
	## Not zero. The dark pass is what gives a cable its drawn width, so multiplying it by
	## the same amount as the colour cost dimmed cables ~40% of their thickness as well as
	## their contrast — two cues collapsing together, which is how a cable stopped reading
	## as a cable. Kept faint so the weight holds without the dim ones looking heavy.
	const DIM_SHADOW := 0.4

	func _draw() -> void:
		if rack == null:
			return
		var cables: Array = rack.cable_endpoints()
		var lane_step := 13.0

		if rack.cable_style == Rack.CableStyle.PHYSICAL:
			_draw_physical_all(cables)
			return

		# The rack draws its own cables, which is why the dimming half of this is here
		# and not in the graph view: GraphEdit paints connections itself and offers no
		# per-cable alpha, so there the best available answer was to brighten a path and
		# leave the rest alone. Here every cable is ours to turn down.
		for index in cables.size():
			var entry: Array = cables[index]
			var a: Vector2 = entry[0]
			var b: Vector2 = entry[1]
			var colour: Color = entry[2]

			var hovered: bool = index == rack.hovered_cable
			var related: bool = rack.cable_related(index, cables)

			var points: PackedVector2Array
			if rack.cable_style == Rack.CableStyle.CATENARY:
				var span := absf(b.x - a.x)
				var sag := clampf(span * Rack.SAG_FRACTION, Rack.SAG_MIN, Rack.SAG_MAX)
				points = Rack.catenary(a, b, sag)
			else:
				var lane := maxf(a.y, b.y) + 34.0 + index * lane_step
				points = Rack.pcb_route(a, b, lane)

			if rack.cable_style == Rack.CableStyle.PHYSICAL:
				continue

			var width: float = 5.0 if hovered else 4.0
			if not related:
				width *= DIM_WIDTH
			var ink: Color = colour if related \
				else stand_down(colour, Rack.PANEL, DIM_TARGET)
			var shadow: float = 0.45 if related else 0.45 * DIM_SHADOW

			# Drawn twice: a dark, slightly wider pass underneath reads as the shadow side
			# of a round cable and keeps overlapping cables legible against each other.
			draw_polyline(points, Color(0, 0, 0, shadow), width + 3.0, true)
			draw_polyline(points, ink, width, true)
			draw_circle(a, 5.0, ink)
			draw_circle(b, 5.0, ink)

			# Both ends of the hovered cable, because a brightened curve still has to be
			# followed by eye to find where it lands — which in a rack means across a
			# tangle of other cables doing the same thing.
			if hovered:
				for spot: Vector2 in [a, b]:
					draw_arc(spot, 12.0, 0.0, TAU, 28, colour, 2.0, true)

	## Every physical cable, in document order, with the crossings marked as they arrive.
	##
	## The whole set is planned before anything is drawn, because a cable cannot know it is
	## passing over another one until the other one's path exists. Document order is the
	## z-order: later cables lie on top, which is arbitrary but stable, and stability is
	## what the eye needs from it — a crossing that swapped which cable was on top between
	## redraws would be worse than no cue at all.
	func _draw_physical_all(cables: Array) -> void:
		var paths: Array[PackedVector2Array] = []
		var styles: Array = []
		var inks: PackedColorArray = PackedColorArray()
		# The rack's own panel, not the editor's canvas. Those are different surfaces and
		# on a light palette they disagree by everything: a cable asked to stand down was
		# mixed towards cream while lying on a dark faceplate, which made it paler and
		# more assertive rather than quieter. Receding means going towards what is behind
		# the thing, and what is behind a cable is the module it crosses.
		var canvas: Color = Rack.PANEL
		var inspect: Rect2 = rack.inspected_rect()

		for index in cables.size():
			var entry: Array = cables[index]
			var dim: float = rack.cable_dim_target(index, cables)
			var style: CableArt.Style = _physical_style(
				index == rack.hovered_cable or index == rack.selected_cable,
				dim, float(entry[5]))
			var ink: Color = entry[2]
			var out := Vector2.DOWN
			# Seeded from the endpoints, so a cable keeps its own hang between redraws and
			# two cables between the same pair of modules do not lie on top of each other.
			var seed := "%d:%d" % [int(entry[0].x) * 31 + int(entry[0].y),
				int(entry[1].x) * 31 + int(entry[1].y)]
			# Slack follows the span. A neighbour-to-neighbour cable at the full 0.82
			# drooped into a little hanging loop — a folded dart between two jacks a
			# module apart — where a real short patch lead pulls almost straight. Long
			# runs keep the full drape.
			var slack := clampf(entry[0].distance_to(entry[1]) / 420.0, 0.18, 0.82)
			var path := CableArt.cable_path(entry[0], out, entry[1], out, slack, style, seed)
			# Anything lying across the panel stands down, including the module's own
			# cables. They cross it too — a cable plugged into this module leaves towards
			# the viewer and falls straight over the legend it is nearest. The question
			# being asked is about what is on top, not about what belongs to what, and a
			# rule that exempted the module's own connections would leave the cables
			# closest to its labels exactly where they were.
			if inspect.has_area() and _crosses(path, inspect):
				dim = maxf(dim, INSPECT_TARGET) if dim > 0.0 else INSPECT_TARGET
				style = _physical_style(false, dim, float(entry[5]))
				path = CableArt.cable_path(entry[0], out, entry[1], out, slack, style, seed)
			if dim > 0.0:
				ink = stand_down(ink, canvas, dim)
			paths.append(path)
			styles.append(style)
			inks.append(ink)

		# Document order, except that whatever is being traced goes last. Order is
		# otherwise the connection order in the file and nothing else — a z-order that
		# reshuffled when unrelated state changed would make crossings swap under the
		# pointer, which is worse than an arbitrary order held steady.
		var order: Array[int] = []
		var raised: Array[int] = []
		var tracing: bool = rack.tracing()
		for index in paths.size():
			if tracing and rack.cable_dim_target(index, cables) == 0.0:
				raised.append(index)
			else:
				order.append(index)
		order.append_array(raised)

		var drawn: Array[int] = []
		for index in order:
			var style: CableArt.Style = styles[index]
			# Under this cable, where it lies across the ones already down.
			for earlier in drawn:
				for at: Vector2 in CableArt.crossings(paths[index], paths[earlier]):
					CableArt.draw_crossing_shadow(self, paths[index], at, style)
			CableArt.draw_cable(self, paths[index], inks[index], style)
			for side in 2:
				_draw_landing(cables[index][side], inks[index], style)
			drawn.append(index)

		# The traced cable's ends, last of all. A brightened curve still has to be followed
		# by eye to find where it lands, which in a rack means across a tangle of others
		# doing the same thing — so both ends are marked and the eye can jump.
		for index in raised:
			for spot: Vector2 in [cables[index][0], cables[index][1]]:
				draw_arc(spot, 12.0, 0.0, TAU, 28,
					Color(cables[index][2], 0.75), 1.5, true)

	## The endpoint: a cable arriving cleanly at a socket, and nothing more.
	##
	## This replaces the plug. The plug was built to say "the cable goes into the
	## hardware", and it did — at the cost of a barrel, a collar band, a strain relief
	## and an occlusion lip at every end of every cable, which together were a
	## miniature hardware rendering exercise fighting the flat language of the merged
	## faceplates. The whole message fits in two marks: the socket's mouth filled with
	## the cable's own colour, and a collar ring of that colour around it. An occupied
	## jack reads as lit by its cable; an empty one keeps its plain ring, so occupancy
	## is readable across the rack at a glance. Depth budget goes to the cable body,
	## which is the thing you actually trace.
	func _draw_landing(at: Vector2, ink: Color, style: CableArt.Style) -> void:
		var radius := Rack.jack_radius()
		# The mouth as the cable's cut end — dark rim, lighter tube face — the same two
		# marks the graph draws, so the transition is one grammar in both views. Goal 5
		# aligned this; before it the rack's mouth was a single flat darkened disc.
		draw_circle(at, style.thickness * 0.62, CableArt.darken(ink, 0.35))
		draw_circle(at, style.thickness * 0.38, ink.lightened(0.12))
		# The collar: the occupancy cue, and the only ring the endpoint needs. Inside
		# the module's own metal ring, so the hardware stays the hardware and the
		# colour reads as something seated in it.
		draw_arc(at, radius * 0.62, 0.0, TAU, 24, ink,
			maxf(style.thickness * 0.4, 2.0), true)


	## Whether a cable passes across a module's panel.
	static func _crosses(path: PackedVector2Array, rect: Rect2) -> bool:
		for point: Vector2 in path:
			if rect.has_point(point):
				return true
		return false

	## A cable as an illustrated object: plug, collar, relief, body, and a hang of its own.
	##
	## The path comes from cable_art rather than from Rack.catenary, because the plug has
	## to agree with where the cable actually leaves — the whole point of the lead-out is
	## that the plug's angle and the cable's fall are separate, and a curve computed
	## elsewhere cannot know about either.
	##
	## Cables leave a faceplate towards the viewer, which in this projection is down. Not
	## along the line to the other jack: a cable that exits sideways is a cable entering
	## the module's edge, which is the thing the whole exercise exists to avoid.
	func _physical_style(traced: bool, dim: float, pitch: float) -> CableArt.Style:
		var style: CableArt.Style = CableArt.Style.new()
		# A cord, not a line. The material stack was always four passes — shadow, dark
		# same-hue edge, saturated body, same-hue highlight — and at five pixels of body
		# every pass but the body was subliminal: the edge crescent was under a pixel,
		# the highlight a thread, and the whole thing read as a flat spline wearing a
		# description of juiciness. Eight and a half gives the passes room to exist,
		# and the offsets and widths below scale with the body instead of being fixed
		# figures tuned for the thin one.
		style.thickness = 10.0 if traced else 8.5
		style.edge_offset = Vector2(1.3, 1.5)
		# Goal 2: the shell does the form work. The body keeps 84% of the width and
		# the dark same-hue shell takes the rest, a shade deeper than before — 0.42
		# keeps every hue obviously itself while making the tube read as a volume.
		style.body_core = 0.84
		style.edge_darken = 0.42
		# Goal 3: the highlight narrows and commits to its direction. At 2.2 wide it
		# read as a stripe painted along the tube; at 1.5, pushed further toward the
		# upper-left where the light actually is, it reads as the sheen on a curved
		# surface. It kisses the top of the body into the shell — 3.8px of reach
		# against the 4.25px envelope — so it stays inside the silhouette Goal 1
		# froze. Width and position only: lighten, alpha, and everything Goal 2
		# settled are untouched.
		style.highlight_width = 1.5
		style.highlight_offset = Vector2(-2.0, -2.3)
		# Goal 4: the cast shadow seats the cable. At 0.2 alpha a black shadow on a
		# near-black canvas was a rumour, and the cable floated; denser, a step
		# tighter, and pushed further lower-right — opposite the highlight, one light
		# — it reads as a cord hanging just off the surface. Shadow family only:
		# everything above this line is frozen where Goals 1-3 left it.
		style.shadow_alpha = 0.32
		style.shadow_width = 9.5
		style.shadow_offset = Vector2(2.0, 2.8)
		style.highlight_alpha = 0.6
		# What the plug has to fit inside. Measured, not assumed: it is the difference
		# between a rack whose modules have four ports in a column and one whose modules
		# have two, and the renderer should not have to be retuned when that changes.
		if pitch > 0.0:
			style.max_reach = pitch - Rack.jack_radius()
		# The rack zooms by scaling itself, so everything above is in rack pixels and the
		# tier has to be decided in screen ones. The floor has to come back the other way:
		# a 2.75 px minimum cable is 2.75 px of glass, which at half zoom is 5.5 of ours.
		var zoom: float = maxf(get_global_transform().get_scale().x, 0.01)
		style.screen_scale = zoom
		style.panel_is_light = rack.cables_on_light_panel()
		# Goal 9: the same hue on every surface, and only the material response adapts.
		#
		# A candy cable on cream loses its silhouette long before it loses its identity,
		# so the shell works harder, the sheen stands down — a bright glint against a
		# bright plate is one more light thing on a light thing — and the shadow holds
		# its ground, since on cream it is doing more of the separating than it does on
		# black. Three strengths, and nothing else: the mass, the shell geometry, the
		# glint geometry, the shadow geometry, the hang, the fan, the crossings and the
		# hues are all as frozen.
		#
		# Chartreuse is the one that decides these numbers. It is the closest of the
		# four to cream in luminance and the temptation is to darken the body until it
		# separates, which turns it olive and throws away the one thing it is for. The
		# core stays radioactive; the shell earns the contrast.
		if style.panel_is_light:
			style.edge_darken = 0.55
			style.highlight_alpha = 0.38
			style.shadow_alpha = 0.30
		style.thickness = maxf(style.thickness, style.min_thickness / zoom)
		if dim > 0.0:
			style.thickness *= DIM_WIDTH
			style.shadow_alpha *= DIM_SHADOW
		return style


# ---------------------------------------------------------------------------------
# A module
# ---------------------------------------------------------------------------------

class RackModule extends Control:
	var rack: Control
	var node_id := ""
	var type_name := ""
	var title := ""
	var descriptor: Dictionary = {}

	## The theme this module wears, resolved once per draw rather than stored, so that
	## changing the patch's theme repaints every module without anybody having to
	## remember to tell them.
	##
	## Its own theme wins, then the patch's, then the category colouring. A name from a
	## newer editor falls through to the patch's rather than drawing nothing.
	func theme_key() -> String:
		var mine := ""
		var patch_theme := ""
		if rack != null:
			for node in rack.patch.get("nodes", []):
				if str((node as Dictionary).get("id", "")) == node_id:
					mine = str((node as Dictionary).get("theme", ""))
					break
			patch_theme = str(rack.patch.get("arrangement", {}).get("theme", ""))
		return ModuleThemes.resolve(mine, patch_theme)

	func skin() -> Dictionary:
		return Rack.skin(theme_key())

	var _jacks: Array = []   # Jack controls, both columns
	var _grid: GridContainer = null
	var _dragging := false
	var _grab_offset := Vector2.ZERO

	## Signal in on the left, controls in the middle, signal out on the right.
	##
	## The jacks were in two rows across the bottom, which is where a Eurorack module puts
	## them and which costs this one the two things the arrangement is supposed to buy. On
	## real hardware the patch cables are in front of the panel and you read the labels
	## around them; here the cables are drawn *over* the module, so a bottom row put every
	## cable across the face of the thing it belongs to. And a rack module whose signal
	## runs left to right is the same object as a graph node, which is what lets the two
	## views share a layout instead of arguing about one.
	##
	## Built out of containers rather than arithmetic. Every overlap on this panel came
	## from a hand-computed offset that did not know how wide the text next to it was.
	func build(node: Dictionary) -> Dictionary:
		var inputs: Array = descriptor.get("inputs", [])
		var outputs: Array = descriptor.get("outputs", [])
		var parameters: Array = descriptor.get("parameters", [])

		var frame := MarginContainer.new()
		frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		frame.add_theme_constant_override("margin_left", int(Rack.KNOB_PAD))
		frame.add_theme_constant_override("margin_right", int(Rack.KNOB_PAD))
		frame.add_theme_constant_override("margin_top", int(Rack.TITLE_BAND))
		frame.add_theme_constant_override("margin_bottom", int(Rack.KNOB_PAD) + 8)
		# So a drag still begins anywhere on bare panel: the layout is scaffolding, and
		# scaffolding that swallowed the mouse would take the one gesture the rack has.
		frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(frame)

		var body := HBoxContainer.new()
		body.add_theme_constant_override("separation", Design.SPACE_M)
		body.mouse_filter = Control.MOUSE_FILTER_IGNORE
		frame.add_child(body)

		_jacks.clear()
		body.add_child(_jack_column(inputs, true))

		# The knobs take the middle and sit in the middle of it. A GridContainer has no
		# alignment of its own, so left to itself it packs against the input jacks and
		# leaves the gap on the outside — which reads as a module that has been assembled
		# wrong rather than one with room to spare.
		var centre := CenterContainer.new()
		centre.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
		body.add_child(centre)

		var grid := GridContainer.new()
		grid.columns = 1 if parameters.size() <= 2 else 2
		grid.add_theme_constant_override("h_separation", 0)
		grid.add_theme_constant_override("v_separation", 0)
		grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
		centre.add_child(grid)
		_grid = grid

		var knobs: Dictionary = {}
		for parameter: Dictionary in parameters:
			var knob := Knob.new()
			knob.rack = rack
			knob.skin = skin()
			knob.node_id = node_id
			knob.descriptor = parameter
			knob.set_value_silently(float(node.get("parameters", {})
				.get(str(parameter["name"]), parameter["default"])))
			grid.add_child(knob)
			knobs[str(parameter["name"])] = knob

		body.add_child(_jack_column(outputs, false))

		# Whole HP, from what the contents actually measure. A module with more to say is
		# wider, which is also true of the real thing — but "more to say" now includes a
		# long parameter name, which is what used to overflow instead of widening.
		var wanted: float = frame.get_combined_minimum_size().x + Rack.KNOB_PAD * 2.0
		var hp := maxi(Rack.MIN_HP, int(ceil(wanted / Rack.HP)))
		custom_minimum_size = Vector2(hp * Rack.HP,
			maxf(Rack.module_height, frame.get_combined_minimum_size().y))
		size = custom_minimum_size
		return knobs

	## One edge of the panel: its jacks, stacked, centred against the knobs.
	func _jack_column(ports: Array, is_input: bool) -> Control:
		var column := VBoxContainer.new()
		column.alignment = BoxContainer.ALIGNMENT_CENTER
		column.add_theme_constant_override("separation", 0)
		column.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		column.mouse_filter = Control.MOUSE_FILTER_IGNORE
		for port: Dictionary in ports:
			var jack := Jack.new()
			jack.rack = rack
			jack.skin = skin()
			jack.node_id = node_id
			jack.port_name = str(port["name"])
			jack.face_label = Rack.face_text(port)
			jack.type_name = str(port.get("type", ""))
			jack.is_input = is_input
			column.add_child(jack)
			_jacks.append(jack)
		return column

	func port_type(port_name: String, is_input: bool) -> String:
		for jack: Jack in _jacks:
			if jack.port_name == port_name and jack.is_input == is_input:
				return jack.type_name
		return ""

	## Centre of a jack, in rack space, or null when this module has no such port.
	## The vertical room one jack has before the next one starts.
	##
	## The jacks are stacked in a VBoxContainer with no separation, so the pitch is simply
	## a jack's own height — but it is the number that decides whether an illustrated plug
	## fits, and nothing outside this class knows it.
	func jack_pitch() -> float:
		var pitch := INF
		for jack: Jack in _jacks:
			pitch = minf(pitch, jack.size.y)
		return pitch if pitch < INF else 0.0

	## Where a jack's socket is, in the rack's own coordinates.
	##
	## Through the transforms rather than by adding positions up. The arithmetic version —
	## module position plus the jack's global offset from the module — is only correct
	## while nothing between the jack and the rack is scaled, and the rack zooms by
	## scaling itself: a global-space delta is then twice a local one, so at 2x every
	## cable landed short of the jack it was plugged into by half the distance from the
	## rack's own corner. Which looks like a rendering bug and is an arithmetic one.
	func jack_position(port_name: String, is_input: bool):
		for jack: Jack in _jacks:
			if jack.port_name == port_name and jack.is_input == is_input:
				var point: Vector2 = jack.get_global_transform() * jack.socket_centre()
				return rack.get_global_transform().affine_inverse() * point
		return null

	## Resting on a module asks to read its panel, so the cables lying across it stand down.
	##
	## After a pause, and only while the pointer stays: see Rack.inspect_after_pause. The
	## cables are not moved and nothing is put in front of them permanently — the physical
	## layering is the metaphor, and a schematic editor where every label floats on top is
	## the thing this view exists not to be. It is a way of looking through the patch cords
	## for as long as you are looking.
	func _notification(what: int) -> void:
		if rack == null:
			return
		if what == NOTIFICATION_MOUSE_ENTER:
			rack.inspect_after_pause(node_id)
		elif what == NOTIFICATION_MOUSE_EXIT:
			rack.cancel_inspection(node_id)

	# Dragging slides a module along the rail — the one thing you can do to a real rack
	# that the graph view has no equivalent for. Knobs sit on top and take their own input
	# first, so a drag can only begin on bare panel, which is also true of the hardware.
	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT 				and event.pressed:
			rack.select(node_id)
			rack.node_selected.emit(node_id)
			rack.theme_requested.emit(node_id, get_global_mouse_position())
			accept_event()
			return
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				rack.select(node_id)
				rack.node_selected.emit(node_id)
				_dragging = true
				_grab_offset = event.position
				z_index = 1              # above its neighbours while it moves
			elif _dragging:
				_dragging = false
				z_index = 0
				rack.move_module_to(node_id, position + size * 0.5)
			accept_event()
		elif event is InputEventMouseMotion and _dragging:
			position += event.position - _grab_offset
			rack.queue_redraw()
			rack.redraw_cables()
			accept_event()

	## What this module is doing, in the band Analysis density reserves.
	##
	## The whole argument for a hardware metaphor is that hardware tells you something
	## by being looked at — a meter moves, a scope draws, an envelope lamp dims. A
	## panel that only holds knobs is a picture of hardware rather than an instrument,
	## and the blank middle of these modules was the clearest evidence of it.
	##
	## Read from the running graph's own buffers, like the scope in the inspector: this
	## draws what is on the wire rather than a guess at what ought to be.
	## How much history each display keeps.
	##
	## A single read returns one processing block — 64 samples. At 110 Hz that is a
	## seventh of a cycle, so a sawtooth drew as a straight diagonal and every display
	## looked like a ramp regardless of what was actually on the wire. Six blocks is
	## about a cycle at the low end and several at the top, which is enough to see the
	## shape of the thing.
	const HISTORY := 384

	var _history := PackedFloat32Array()

	## Pulls the latest block onto the end of the history and drops the oldest.
	func accumulate() -> void:
		if rack == null or not rack.read_port.is_valid():
			return
		var outputs: Array = descriptor.get("outputs", [])
		if outputs.is_empty():
			return
		var block: PackedFloat32Array = rack.read_port.call(node_id,
			str(outputs[0]["name"]))
		if block.is_empty():
			return
		_history.append_array(block)
		if _history.size() > HISTORY:
			_history = _history.slice(_history.size() - HISTORY)


	func _draw_analysis() -> void:
		if Rack.density != Rack.Density.ANALYSIS or rack == null:
			return
		if not rack.read_port.is_valid():
			return
		var outputs: Array = descriptor.get("outputs", [])
		if outputs.is_empty():
			return

		# Under whatever the layout actually did, rather than under a re-derivation of it.
		# The old version counted knob rows and multiplied by a cell height to guess where
		# the knobs ended, which was a second copy of the layout kept in step by hand.
		if _grid == null:
			return
		var top: float = _grid.global_position.y - global_position.y + _grid.size.y + 10.0
		var bottom: float = size.y - Rack.KNOB_PAD - 10.0
		if bottom - top < 24.0:
			return
		var area := Rect2(Rack.KNOB_PAD + 4.0, top, size.x - Rack.KNOB_PAD * 2.0 - 8.0,
			bottom - top)

		# Recessed into the panel, the way a display on a real module is.
		draw_rect(area, Rack.JACK_HOLE)
		draw_rect(area, Rack.PANEL_EDGE, false, 1.0)

		var samples := _history
		var colour: Color = rack.signal_colour(str(outputs[0]["type"]),
			Design.INK_NORMAL)
		if samples.size() < 2:
			return

		# Audio is drawn against a fixed full scale so two modules can be compared.
		# Control is drawn against its own range, because a frequency wire sits at 440
		# and would otherwise be a flat line pinned to the top of every display.
		var is_audio := str(outputs[0]["type"]) == "audio"
		var low := INF
		var high := -INF
		for value in samples:
			low = minf(low, value)
			high = maxf(high, value)
		if is_audio:
			low = -1.0
			high = 1.0
		elif high - low < 1e-6:
			# A control that is holding still is a flat line through the middle, which is
			# the truth about it and reads better than a full-scale line at the top.
			low -= 1.0
			high += 1.0

		var middle := area.position.y + area.size.y * 0.5
		draw_line(Vector2(area.position.x, middle),
			Vector2(area.end.x, middle), Rack.KNOB_TRACK, 1.0)

		var points := PackedVector2Array()
		points.resize(samples.size())
		var step := area.size.x / float(samples.size() - 1)
		for i in samples.size():
			var t: float = inverse_lerp(low, high, clampf(samples[i], low, high))
			points[i] = Vector2(area.position.x + i * step,
				area.end.y - 3.0 - t * (area.size.y - 6.0))
		draw_polyline(points, colour, 1.5, true)


	func _draw() -> void:
		var font: Font = Design.font(Design.WEIGHT_MEDIUM)
		if font == null:
			font = get_theme_default_font()
		var tint: Color = Rack.category_tint(str(descriptor.get("category", "")))
		var paint := skin()
		Rack.draw_plate(self, Rect2(Vector2.ZERO, size), Rack.TITLE_BAND, tint, paint)

		if font != null:
			var label := title.to_upper()
			var width := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
			# A long user-given name is clipped rather than shrunk, so every module's title
			# sits on the same baseline at the same size, as a row of panels does.
			var legend: Color = paint.get("legend", Color(0, 0, 0, 0))
			draw_string(font, Vector2((size.x - width) * 0.5, 26.0), label,
				HORIZONTAL_ALIGNMENT_LEFT, size.x - 12.0, 14,
				rack.ink if legend.a <= 0.0 else legend)

		_draw_analysis()
		# Radius left to the default. It was pinned at 3.4 here when the skin argument
		# went in, which quietly made the default meaningless for the rack - the size was
		# changed twice and this call went on drawing the original.
		Rack.draw_screws(self, Rect2(Vector2.ZERO, size), Rack.SCREW_RADIUS, true, paint)

		if rack != null and rack.selected_id == node_id:
			draw_rect(Rect2(Vector2.ZERO, size), Rack.SELECTED, false, 2.0)


# ---------------------------------------------------------------------------------
# A jack
# ---------------------------------------------------------------------------------

## One socket and its name, as a control that knows how much room it needs.
##
## It was drawn straight onto the panel at a computed centre, with the name clipped to a
## fixed 42px column — which is why every port on the keyboard read "freque", "gatı",
## "velocit", "trigge". A control can ask for the width its own text wants, and the
## column it sits in can be as wide as its widest member. That is the whole fix.
class Jack extends Control:
	var rack: Control
	## Set by the module that owns it: a jack belongs to a panel, and the panel decides
	## what colour its hardware is.
	var skin: Dictionary = {}
	## Which module this jack belongs to. A port name alone does not identify a jack —
	## half the rack has a port called `in` — and the cable being asked about is the one
	## that ends at this module's copy of it.
	var node_id := ""
	var port_name := ""
	## What is printed beside the socket. port_name stays the lookup key — jack_position
	## and the hover dictionary match on it — so the two must never be conflated.
	var face_label := ""
	var type_name := ""
	var is_input := true

	func _ready() -> void:
		# The full name, always, whatever the panel had room to print.
		tooltip_text = port_name
		mouse_filter = Control.MOUSE_FILTER_PASS

	## Hovering a plugged jack asks where its cable goes, from the end you are looking at.
	##
	## An empty jack invents nothing: there is no connection to emphasise, and lighting up
	## the rack's other cables because the pointer crossed a hole would be an answer to a
	## question that was not asked. The rack works out whether anything lands here.
	func _notification(what: int) -> void:
		if rack == null:
			return
		if what == NOTIFICATION_MOUSE_ENTER:
			rack.hovered_jack = {"node": node_id, "port": port_name, "input": is_input}
		elif what == NOTIFICATION_MOUSE_EXIT and rack.hovered_jack.get("node", "") == node_id \
				and rack.hovered_jack.get("port", "") == port_name:
			rack.hovered_jack = {}

	func _label_font() -> Font:
		return Design.font(Design.WEIGHT_MEDIUM)

	func _label_size() -> int:
		return Design.type(Design.SIZE_SECONDARY)

	func _text_width() -> float:
		var font := _label_font()
		if font == null:
			return 0.0
		return minf(font.get_string_size(face_label if face_label != "" else port_name,
			HORIZONTAL_ALIGNMENT_LEFT, -1,
			_label_size()).x, Design.scale(Rack.JACK_LABEL_MAX))

	func _get_minimum_size() -> Vector2:
		return Vector2(Rack.jack_radius() * 2.0 + 6.0 + _text_width(),
			maxf(Rack.jack_radius() * 2.0 + 6.0, float(_label_size()) + 12.0))

	## Where the cable lands, in this control's own space. The socket hugs the outer edge
	## so a cable leaves the panel rather than crossing it.
	func socket_centre() -> Vector2:
		return Vector2(Rack.jack_radius() if is_input else size.x - Rack.jack_radius(),
			size.y * 0.5)

	func _draw() -> void:
		var centre := socket_centre()
		Rack.draw_socket(self, centre, Rack.jack_radius(), is_input,
			rack.signal_colour(type_name), skin)

		var font := _label_font()
		if font == null:
			return
		var room := size.x - Rack.jack_radius() * 2.0 - 6.0
		if room <= 4.0:
			return
		var text := Rack.elided(font, face_label if face_label != "" else port_name,
			_label_size(), room)
		var baseline := size.y * 0.5 + float(_label_size()) * 0.36
		draw_string(font,
			Vector2(Rack.jack_radius() * 2.0 + 6.0 if is_input else 0.0, baseline), text,
			HORIZONTAL_ALIGNMENT_LEFT if is_input else HORIZONTAL_ALIGNMENT_RIGHT,
			room, _label_size(),
			rack.ink_dim if _legend().a <= 0.0 else _legend())

	## The panel's lettering colour, at full strength - see the note on Knob._legend for
	## why a painted panel does not get to fade its secondary text.
	func _legend() -> Color:
		return skin.get("legend", Color(0, 0, 0, 0))


# ---------------------------------------------------------------------------------
# A knob
# ---------------------------------------------------------------------------------

## Vertical drag, because that is what a knob does under a mouse — a rotary gesture is
## unpleasant to perform and worse to aim. Fine control on Shift. The whole drag is one
## undo step, matching the sliders in the graph view.
class Knob extends Control:
	const SWEEP := TAU * 0.75          # 270°, the usual pot travel
	const START := PI * 0.75           # pointing down-left at minimum

	var rack: Control
	## Set by the module that owns it, like the jacks'.
	var skin: Dictionary = {}

	## The panel's lettering, or the rack's ink where the panel has no opinion.
	##
	## A knob prints its name and its value straight onto the faceplate, so both are
	## panel text and neither may keep using the rack's light ink once the panel is
	## cream. On Ivory Lab and Frosted Ice that is near-white on near-white: the title
	## and the jack labels were themed and these two were missed, which is exactly the
	## sort of thing that survives a contrast test aimed at the wrong pair.
	## Not dimmed, on a painted panel.
	##
	## The rack fades a knob's name against its value, which works on graphite because
	## there is contrast to spend. A faceplate often has none: Safety Orange gives black
	## lettering 4.9:1 at full strength, so anything faded is below the bar whatever the
	## fade, and no amount of tuning fixes a ceiling. The hierarchy is carried by size and
	## weight instead - the name is Medium at the secondary size, the value is larger and
	## tabular - which is what was separating them anyway.
	func _legend(dim: bool) -> Color:
		var legend: Color = skin.get("legend", Color(0, 0, 0, 0))
		if legend.a <= 0.0:
			return rack.ink_dim if dim else rack.ink
		return legend
	var node_id := ""
	var descriptor: Dictionary = {}

	## Dial only, with the name and the value left to whatever is placing it.
	##
	## The graph view puts the name above the number beside the dial rather than below
	## it, and that is the whole difference between the two views' cells. Stacking them
	## as the rack does makes a cell 99px tall; a graph node with four of those is taller
	## than the sliders it replaced, which is the opposite of the point. Same control,
	## same keyboard, same signal path — one draws its own caption and one does not.
	var compact := false
	## Drawn as a diagram rather than as a piece of hardware.
	##
	## The rack's knob is a moulded part: collar, cap, moulding line, sheen, a shadow
	## under it and a printed scale around it. That is right on a faceplate and wrong in
	## the graph, which is a drawing of the patch rather than a photograph of it — and
	## the detail does not survive being shrunk anyway. Nine primitives at 100% become
	## a textured grey circle at 40%.
	##
	## The diagram keeps what says where the knob is set and drops everything that says
	## what it is made of.
	var diagram := false
	## Whether the diagram prints three reference marks. Off by default: see the proof
	## sheet in docs/graph-nodes.md — at the size a graph node actually draws a knob, the
	## marks are three grey pixels that read as dirt on the glass.
	var diagram_ticks := false

	## Dial size, as a fraction of the rack's. The panel packs knobs three to a module
	## where the rack fits two, and it gets the room by shrinking the dial rather than
	## the text — a smaller circle is still a circle, but a smaller label is a squint.
	var dial := 1.0

	func _radius() -> float:
		return Rack.knob_radius() * dial

	var _position := 0.0               # 0..1 along the parameter's own scaling
	var _dragging := false
	var _drag_origin := 0.0
	var _drag_from := 0.0

	func _ready() -> void:
		mouse_default_cursor_shape = Control.CURSOR_VSIZE
		# Reachable by Tab, and announced as the control it is rather than as a drawing.
		focus_mode = Control.FOCUS_ALL
		# The ring is drawn by _draw, and _draw does not run again on its own when focus
		# moves — so without these the ring appeared on the first knob to be focused and
		# then never moved.
		focus_entered.connect(queue_redraw)
		focus_exited.connect(queue_redraw)
		# The name in full ahead of the documentation, because the panel may only have
		# had room for "cutoff_sw…" and the first question a truncated label raises is
		# what it was truncated from.
		var doc := str(descriptor.get("doc", ""))
		tooltip_text = str(descriptor["name"]) + ("\n" + doc if doc != "" else "")

	func _name_text() -> String:
		# A caption somebody typed on the face wins; then the registry's label; then the
		# name, read aloud rather than as an identifier.
		if str(descriptor.get("display_name", "")) != "":
			return str(descriptor["display_name"])
		return Rack.face_text(descriptor)

	func _value_text() -> String:
		# Without its unit: a faceplate says the unit once, under the name, the way a
		# panel does. The graph says it beside the number because a graph node has no
		# legend to put it on.
		return ValueText.number(descriptor, value())

	## The widest this knob's value will ever be, so the cell does not resize while it is
	## being turned.
	##
	## Measuring the *current* value would make the grid reflow mid-drag — the panel
	## breathing in and out under the pointer as 9.99 became 10.0 — and would let a knob
	## that happens to be sitting at 0 claim a cell too narrow for the number it is about
	## to show.
	func _widest_value() -> String:
		if descriptor.has("enum"):
			var longest := ""
			for option in descriptor["enum"]:
				if str(option).length() > longest.length():
					longest = str(option)
			return longest
		# Not the longer of the two ends. Once trailing zeros are gone the ends are often
		# the *shortest* readings a parameter has — a gain of 0 to 4 writes them as "0"
		# and "4" while everything between writes "0.75" — so a cell sized on the ends
		# would be too narrow for almost every value it goes on to hold.
		return ValueText.widest(descriptor, false)

	func _get_minimum_size() -> Vector2:
		if compact:
			# The dial plus the arc that rides five px outside it — the first version
			# measured the dial alone and the arc shaved its top on the cell edge.
			# The hit area still has to clear the rule every other control obeys.
			# Room for the printed scale, which sits nine px past the body — the old 17
			# was measured against a value arc five px out and nothing beyond it.
			var across := _radius() * 2.0 + 22.0
			return Vector2(across, maxf(across, Design.scale(Design.HIT_TARGET)))
		var label_font: Font = Design.font(Design.WEIGHT_MEDIUM)
		var label_size := Design.type(Design.SIZE_SECONDARY)
		var value_font: Font = Design.numeric_font()
		var value_size := Design.type(Design.SIZE_NUMERIC)
		var widest := Rack.knob_radius() * 2.0 + 12.0
		if label_font != null:
			widest = maxf(widest, minf(label_font.get_string_size(_name_text(),
				HORIZONTAL_ALIGNMENT_LEFT, -1, label_size).x,
				Design.scale(Rack.JACK_LABEL_MAX)))
		if value_font != null:
			widest = maxf(widest, value_font.get_string_size(_widest_value(),
				HORIZONTAL_ALIGNMENT_LEFT, -1, value_size).x)
		return Vector2(widest + Rack.KNOB_PAD * 2.0,
			maxf(Rack.KNOB_CELL.y, Rack.knob_radius() * 2.0 + 14.0
				+ float(label_size) + float(value_size) + 10.0))

	func value() -> float:
		var raw := _to_value(_position)
		# A mode switch has positions, not a range. A filter set to 1.7 is not a thing, and
		# a knob that can produce one would be a quiet way to corrupt a patch.
		if descriptor.has("enum"):
			var options: Array = descriptor["enum"]
			return float(clampi(int(round(raw)), 0, options.size() - 1))
		return raw

	func set_value_silently(value: float) -> void:
		_position = _to_position(value)
		queue_redraw()

	# Scaling comes from the descriptor the core publishes, exactly as the graph view's
	# sliders do. Two views disagreeing about what the middle of a knob means would be a
	# bug nobody would find quickly.
	func _to_value(at: float) -> float:
		var low: float = descriptor["min"]
		var high: float = descriptor["max"]
		match str(descriptor.get("scaling", "linear")):
			"exponential":
				if low > 0.0 and high > 0.0:
					return low * pow(high / low, at)
			"logarithmic":
				return low + (high - low) * at * at
		return low + (high - low) * at

	func _to_position(value: float) -> float:
		var low: float = descriptor["min"]
		var high: float = descriptor["max"]
		if is_equal_approx(low, high):
			return 0.0
		match str(descriptor.get("scaling", "linear")):
			"exponential":
				if low > 0.0 and high > 0.0 and value > 0.0:
					return clampf(log(value / low) / log(high / low), 0.0, 1.0)
			"logarithmic":
				return clampf(sqrt(maxf(0.0, (value - low) / (high - low))), 0.0, 1.0)
		return clampf((value - low) / (high - low), 0.0, 1.0)

	## How far the pointer travels to cross the whole range, in pixels.
	##
	## A fixed distance for a dial, because a dial has no visible travel to match: its
	## pointer sweeps 270° whatever size the circle is drawn at, so there is no length on
	## screen that a drag could honestly correspond to, and a constant that feels right is
	## the best available answer. Shift multiplies it, here and in everything that
	## overrides this, so fine adjustment is one gesture across the application.
	func _drag_span() -> float:
		return 160.0

	## One step of the keyboard, as a fraction of the knob's travel. The same numbers the
	## graph view's readout uses, because a reader who has learned that Left is a small
	## step and Shift+Left a large one has learned it for the application, not for a
	## widget.
	const KEY_STEP := 0.01
	const KEY_COARSE := 0.1

	## Moves the knob by a fraction of its travel and reports it, as one undo step.
	##
	## Presses are their own edit rather than being folded into a drag: a drag has a
	## beginning and an end the mouse announces, and a key press has neither.
	func nudge(fraction: float) -> void:
		var before := _position
		_position = clampf(_position + fraction, 0.0, 1.0)
		if is_equal_approx(before, _position):
			return
		rack.edit_started.emit()
		rack.parameter_changed.emit(node_id, str(descriptor["name"]), value())
		rack.edit_finished.emit("set %s" % str(descriptor["name"]))
		queue_redraw()

	func _gui_input(event: InputEvent) -> void:
		# A knob you cannot reach from the keyboard is a knob half the people who might
		# use this cannot reach at all. The graph view's sliders and readouts have taken
		# arrow keys since the accessibility pass; this is the same control wearing a
		# different picture, so it takes them too.
		if event is InputEventKey and event.pressed:
			var step: float = KEY_COARSE if event.shift_pressed else KEY_STEP
			if event.keycode == KEY_LEFT or event.keycode == KEY_DOWN:
				nudge(-step)
				accept_event()
				return
			if event.keycode == KEY_RIGHT or event.keycode == KEY_UP:
				nudge(step)
				accept_event()
				return
			if event.keycode == KEY_HOME:
				nudge(-1.0)
				accept_event()
				return
			if event.keycode == KEY_END:
				nudge(1.0)
				accept_event()
				return
		# The wheel, one notch to a step. A wheel is a discrete gesture like a key press
		# rather than a continuous one like a drag, so it takes the keyboard's step rather
		# than the drag's distance — and Shift means coarse here, as it does on the arrow
		# keys, rather than fine as it does on a drag. That split is the gesture's, not
		# this control's: stepping asks "how big a step" and dragging asks "how far to
		# travel", and Shift answers each in the direction that gesture needs.
		#
		# No focus required: the pointer is over the control, which is the whole of what a
		# wheel means. Accepted either way, so the panel behind it does not scroll while
		# somebody is setting a value.
		if event is InputEventMouseButton and event.pressed \
				and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			# Ctrl+wheel belongs to the view, not the value: it zooms the graph and the
			# turned-over face alike, so a knob that swallowed it would make zoom stop
			# working exactly where the knobs are.
			if event.ctrl_pressed:
				return
			var notch: float = KEY_COARSE if event.shift_pressed else KEY_STEP
			nudge(notch if event.button_index == MOUSE_BUTTON_WHEEL_UP else -notch)
			accept_event()
			return
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				# Ctrl-click arms MIDI learn: the next CC the hardware sends
				# becomes this knob's. Checked before the double tap, so a
				# quick Ctrl-double-click does not also send the knob home.
				if event.ctrl_pressed:
					rack.learn_requested.emit(node_id, str(descriptor["name"]))
					accept_event()
					return
				# The double tap sends it home: the value the node entered the
				# document with, or the descriptor's factory default when the
				# document never set one. One undo step, reported the way every
				# other gesture reports. Already home, it does nothing — a reset
				# that writes an empty edit teaches undo to lie.
				if event.double_click:
					var before := _position
					var home: float = float(descriptor.get("default", value()))
					if rack.home_lookup.is_valid():
						home = float(rack.home_lookup.call(node_id,
							str(descriptor["name"]), home))
					set_value_silently(home)
					if not is_equal_approx(before, _position):
						rack.edit_started.emit()
						rack.parameter_changed.emit(node_id,
							str(descriptor["name"]), value())
						rack.edit_finished.emit("set %s" % str(descriptor["name"]))
					_dragging = false
					accept_event()
					return
				# So the arrow keys go to the knob that was just touched, rather than to
				# whatever held focus before it.
				grab_focus()
				_dragging = true
				_drag_origin = event.position.y
				_drag_from = _position
				rack.edit_started.emit()
			elif _dragging:
				_dragging = false
				rack.edit_finished.emit("set %s" % str(descriptor["name"]))
			accept_event()
		elif event is InputEventMouseMotion and _dragging:
			var travel: float = _drag_origin - event.position.y
			var span: float = _drag_span() * (4.0 if event.shift_pressed else 1.0)
			_position = clampf(_drag_from + travel / maxf(span, 1.0), 0.0, 1.0)
			rack.parameter_changed.emit(node_id, str(descriptor["name"]), value())
			queue_redraw()
			accept_event()

	func _draw() -> void:
		var font: Font = get_theme_default_font()
		var radius := _radius()
		var centre := Vector2(size.x * 0.5,
			size.y * 0.5 if compact else radius + 6.0)
		var angle := START + SWEEP * _position
		if diagram:
			_draw_diagram(centre, radius, angle)
			return

		# Printed ticks around the travel, the way a panel marks a pot's range.
		#
		# Eleven, because a scale wants a middle and an odd count gives it one — a knob
		# at noon should be pointing at a mark. Drawn in the panel's own thinner ink
		# where it has one.
		#
		# The first version put them in the gap between the body and the value arc,
		# where they were a pixel and a half long and gone by 75% zoom. A detail that
		# only exists at 100% is not a detail, it is a rumour: the scale is outside the
		# arc now, where a panel actually prints it, longer, and with the extremes and
		# the centre marked heavier than the rest — the three positions anybody reads a
		# pot against.
		var marks: Color = skin.get("muted", Color(0, 0, 0, 0))
		if marks.a <= 0.0:
			marks = Color(rack.ink_dim, 0.7)
		const TICKS := 11
		for tick in TICKS:
			var at := START + SWEEP * (float(tick) / float(TICKS - 1))
			var out := Vector2(cos(at), sin(at))
			var cardinal: bool = tick == 0 or tick == TICKS - 1 or tick == (TICKS - 1) / 2
			draw_line(centre + out * (radius + 6.0),
				centre + out * (radius + (9.0 if cardinal else 7.6)),
				marks, 1.8 if cardinal else 1.2, true)

		# The value ring, brought in to hug the body. It used to sit five px out, in the
		# middle of the space the scale wants, so the two rings competed and neither read
		# as belonging to the knob.
		draw_arc(centre, radius + 3.0, START, START + SWEEP, 40,
			Rack.KNOB_TRACK, 2.5, true)
		draw_arc(centre, radius + 3.0, START, angle, 40,
			Rack.SELECTED, 2.5, true)

		# Focus is drawn around the whole cell, not around the dial: the name and the
		# value are part of what is focused, and a ring that hugged the circle looked
		# like a selected knob rather than a keyboard position.
		if has_focus():
			draw_rect(Rect2(Vector2.ONE, size - Vector2.ONE * 2.0), Design.FOCUS,
				false, 2.0)

		var body: Color = skin.get("knob", Rack.KNOB_BODY)
		# Sitting on the panel rather than printed on it: a short dense shadow under the
		# body, offset down because the light on these panels comes from the top. It is
		# the same argument as the module's own shadow, one size down.
		draw_circle(centre + Vector2(0.0, 2.0), radius + 1.0, Color(0.0, 0.0, 0.0, 0.34))
		# The collar the shaft comes through, in the same moulded black as every other
		# piece of hardware on these panels. It is what makes a knob look bolted through
		# the plate rather than laid on top of it, and it is the widest thing here, so
		# it is what carries the silhouette when everything else has shrunk away.
		var collar: Color = skin.get("hardware", Color(0, 0, 0, 0))
		if collar.a > 0.0:
			draw_circle(centre, radius + 1.6, collar)
			draw_arc(centre, radius + 1.6, 0.0, TAU, 48,
				skin.get("hardware_hi", collar.lightened(0.25)), 1.0, true)
		draw_circle(centre, radius, body)
		draw_circle(centre, radius, Color(0, 0, 0, 0.5), false, 1.0)
		# The cap catches the light. A pale knob is lit by darkening rather than
		# lightening it, or a cream bakelite cap turns into a white disc with no edge.
		# The moulding line, then the cap. A knob is two pieces — a skirt you grip and a
		# top face — and the step between them is what says so. It was a lightened disc
		# with no edge, which reads as a lit sphere rather than as a moulded part.
		var cap := body.darkened(0.10) if body.get_luminance() > 0.5 \
			else body.lightened(0.14)
		draw_arc(centre - Vector2(0.0, 1.0), radius - 4.0, 0.0, TAU, 40,
			Color(0.0, 0.0, 0.0, 0.45), 1.4, true)
		draw_circle(centre - Vector2(0, 1), radius - 5.0, cap)
		# One short highlight across the top left of the cap, and no more than one. This
		# is where a knob turns into a 2010 gel button if it is overdone: the reference
		# is small moulded hardware under diffuse light, which has a soft sheen on one
		# side and nothing anywhere else.
		draw_arc(centre - Vector2(0.0, 1.0), radius - 6.5, PI * 1.08, PI * 1.62, 12,
			Color(1.0, 1.0, 1.0, 0.10 if body.get_luminance() > 0.5 else 0.16),
			1.6, true)
		# The pointer, which is what actually tells you where the knob is set, and the
		# one part of a knob that has to be visible from across a desk.
		# The pointer, which is what actually tells you where the knob is set, and the
		# one part of a knob that has to survive being shrunk. It runs from the middle of
		# the cap to its edge — not from a third of the way out — and it is drawn on its
		# own dark line so that a pale pointer on a pale cap still has an edge.
		var pointer: Color = skin.get("pointer", Color(0, 0, 0, 0))
		var index := Vector2(cos(angle), sin(angle))
		var from := centre - Vector2(0.0, 1.0) + index * 2.5
		var to := centre - Vector2(0.0, 1.0) + index * (radius - 3.5)
		draw_line(from, to, Color(0.0, 0.0, 0.0, 0.45), 4.4, true)
		draw_line(from, to, rack.ink if pointer.a <= 0.0 else pointer, 2.8, true)

		# Compact draws the dial and stops: its name and its number belong to whatever
		# placed it, and drawing them here too would print one over the other.
		if font == null or compact:
			return
		# Names in Medium at the secondary size, values in the tabular face at the
		# numeric size — which is larger, not smaller.
		#
		# Both were 11px, and the value was being treated as metadata attached to the
		# name. It is the other way round: the name tells you which knob this is, which
		# you learn once, and the value tells you where it is set, which is what you came
		# to read and what changes while you watch. At 11px it was the weakest text in
		# the application.
		# Both bounded by the cell, which is itself as wide as the wider of them. Drawn
		# with an explicit width and centred alignment rather than by subtracting a
		# measured half-width from the middle: the old version had no bound at all, so a
		# name wider than its cell simply printed over the knob beside it.
		var label_font: Font = Design.font(Design.WEIGHT_MEDIUM)
		var label_size := Design.type(Design.SIZE_SECONDARY)
		var room := size.x - Rack.KNOB_PAD * 2.0
		var value_font: Font = Design.numeric_font()
		var value_size := Design.type(Design.SIZE_NUMERIC)
		var value_baseline := size.y - Rack.KNOB_PAD * 0.5
		var name_baseline := value_baseline - float(value_size) - 4.0
		draw_string(label_font, Vector2(Rack.KNOB_PAD, name_baseline),
			Rack.elided(label_font, _name_text(), label_size, room),
			HORIZONTAL_ALIGNMENT_CENTER, room, label_size, _legend(true))
		draw_string(value_font, Vector2(Rack.KNOB_PAD, value_baseline),
			Rack.elided(value_font, _value_text(), value_size, room),
			HORIZONTAL_ALIGNMENT_CENTER, room, value_size, _legend(false))


	## The knob as a diagram: four marks, and every one of them says where it is set.
	##
	##   track     where it can go        one thin arc, quiet
	##   arc       where it is            the same arc in mint, from the minimum
	##   body      the control itself     one disc, one edge
	##   pointer   where it is, again     the strongest thing on it
	##
	## The value is said twice on purpose — by the arc's length, which is readable at a
	## glance and at any size, and by the pointer, which is readable precisely. That
	## redundancy is the whole reason this survives being shrunk while nine layers of
	## moulding did not.
	##
	## What is gone: the collar, the cast shadow, the cap, the moulding line, the sheen,
	## the dark under-stroke on the pointer and the eleven printed ticks. None of them
	## carried state.
	func _draw_diagram(centre: Vector2, radius: float, angle: float) -> void:
		# The body first, so the arcs outside it read as a scale around a control rather
		# than as a ring with something in the middle.
		var body: Color = skin.get("knob", Rack.KNOB_BODY)
		draw_circle(centre, radius, body)
		draw_arc(centre, radius, 0.0, TAU, 40, Color(0.0, 0.0, 0.0, 0.35), 1.0, true)

		# Travel, then value. Two pixels of arc rather than two and a half, hugging the
		# body at the same distance the rack's does, so a knob is the same object in both
		# views even though it is drawn differently.
		var track_width := maxf(radius * 0.14, 2.0)
		draw_arc(centre, radius + 3.0, START, START + SWEEP, 40, Rack.KNOB_TRACK,
			track_width, true)
		if _position > 0.001:
			draw_arc(centre, radius + 3.0, START, angle, 40, Rack.SELECTED,
				track_width, true)

		if diagram_ticks:
			var marks: Color = skin.get("muted", Color(0, 0, 0, 0))
			if marks.a <= 0.0:
				marks = Color(rack.ink_dim, 0.7)
			for tick in 3:
				var at := START + SWEEP * (float(tick) * 0.5)
				var out := Vector2(cos(at), sin(at))
				draw_line(centre + out * (radius + 6.0),
					centre + out * (radius + 9.0), marks, 1.4, true)

		# The pointer, which is the one part that has to survive everything. From the
		# middle to the edge, in the ink the panel letters with, and thick enough that
		# shrinking it leaves a line rather than a suggestion — a fifth of the radius,
		# floored at two pixels, where the rack's was a fixed 2.8 over a dark 4.4 and
		# became a grey smudge on top of a darker smudge.
		var pointer: Color = skin.get("pointer", Color(0, 0, 0, 0))
		var index := Vector2(cos(angle), sin(angle))
		draw_line(centre + index * radius * 0.18, centre + index * (radius - 1.5),
			rack.ink if pointer.a <= 0.0 else pointer,
			maxf(radius * 0.2, 2.0), true)


## A vertical fader: the same control as Knob wearing a different picture.
##
## Envelopes read as heights side by side — four sliders labelled A D S R *are* the
## envelope's shape, which four dials never quite manage. Everything that makes a knob a
## knob is inherited: the descriptor's scaling, the write path through the rack's edit
## signals, the keyboard, the drag (up is more, Shift is fine). Only the drawing and the
## footprint differ, which is exactly the relationship Knob already has with its own
## compact mode.
class Fader extends Knob:
	## The letter on the panel. The full parameter name stays in the tooltip, where the
	## knobs already keep theirs — "A" is readable at a glance precisely because it is
	## not trying to say "attack".
	var label := ""

	const THUMB := Vector2(15.0, 6.0)

	func _ready() -> void:
		super()
		# The number lives here now that it is not printed under the letter. An
		# envelope is read as a shape and set by ear; the exact seconds are something
		# you ask for, not something you need on screen four times per operator.
		tooltip_text = "%s\n%s" % [str(descriptor["name"]), _value_text()]

	func _get_minimum_size() -> Vector2:
		# Narrow on purpose: four of these sit in the width of two knob cells. The
		# height is a floor, not a size — the row that places a fader stretches it
		# into whatever the block has left.
		#
		# Short on purpose too, and this is a floor rather than the size it will get:
		# the envelope stretches into whatever the block has spare, so on a tall panel
		# these are tall. What the floor decides is whether two operators fit on screen
		# at all, which is the only reason it is this low — a fader is read as a height
		# against its three neighbours, and four of them say the same shape small.
		return Vector2(Design.scale(26),
			Design.scale(26) + float(Design.type(Design.SIZE_SECONDARY)))

	## Where the thumb may sit, as (top, bottom) in local coordinates.
	##
	## One definition, two readers: the drawing puts the thumb here and the drag measures
	## its travel by it. Kept together because they are the same claim — that this strip
	## of the control is the range — and a drawing whose thumb outran the pointer would be
	## the plainest possible way to break a fader.
	func _track() -> Vector2:
		var foot := size.y - Rack.KNOB_PAD * 0.4 \
			- float(Design.type(Design.SIZE_SECONDARY)) - 6.0
		return Vector2(Rack.KNOB_PAD * 0.5, foot)

	## The track's own length: on a fader the travel is visible, so the thumb follows the
	## pointer rather than a distance chosen in the abstract. Drag from the foot of the
	## track to its head and the value crosses its whole range, which is the one thing a
	## fader promises by looking like one — and it means a tall panel gives fine control
	## and a short one coarse, for the same reason a long fader does on a desk.
	func _drag_span() -> float:
		var track := _track()
		return maxf(track.y - track.x, 1.0)

	func _draw() -> void:
		var label_font: Font = Design.font(Design.WEIGHT_MEDIUM)
		var label_size := Design.type(Design.SIZE_SECONDARY)
		var label_baseline := size.y - Rack.KNOB_PAD * 0.4
		var track := _track()
		var track_top := track.x
		var track_bottom := track.y
		if track_bottom <= track_top:
			return
		var x := size.x * 0.5
		var at_y := track_bottom - (track_bottom - track_top) * _position

		draw_line(Vector2(x, track_top), Vector2(x, track_bottom),
			Rack.KNOB_TRACK, 3.0, true)
		# Filled from the bottom, the way a level reads.
		draw_line(Vector2(x, track_bottom), Vector2(x, at_y), Rack.SELECTED, 3.0, true)
		var thumb := Rect2(Vector2(x, at_y) - THUMB * 0.5, THUMB)
		draw_rect(thumb, Rack.KNOB_BODY)
		draw_rect(thumb, Color(0, 0, 0, 0.5), false, 1.0)

		if has_focus():
			draw_rect(Rect2(Vector2.ONE, size - Vector2.ONE * 2.0), Design.FOCUS,
				false, 2.0)

		if label_font != null and label != "":
			draw_string(label_font, Vector2(0.0, label_baseline), label,
				HORIZONTAL_ALIGNMENT_CENTER, size.x, label_size, _legend(true))


## A module's aluminium: the plate, its edges, and the category stripe under the title.
##
## Shared between the rack view and the file's panel so the two cannot drift. A panel block
## and a rack module are the same object seen twice — one arranged by signal flow, one
## arranged by the player — and if they stopped looking alike, that would be a claim about
## them being different things, which they are not.
##
## The title is left to the caller: the rack draws its own into the band, the panel gives
## the band to a Label so it can clip and ellipsise like every other name in the inspector.
## What the panel prints for a port or a parameter: the registry's label where it has
## one, the stable name with its underscores read as spaces where it does not.
##
## The name is wiring identity and never changes for presentation; the label is
## presentation and never participates in wiring. Every view asks this one question in
## this one place, so the graph, the rack and anything drawn later cannot drift into
## calling the same jack two things.
static func face_text(descriptor: Dictionary) -> String:
	var label := str(descriptor.get("label", ""))
	if label != "":
		return label
	return str(descriptor.get("name", "")).replace("_", " ")


static func draw_plate(canvas: CanvasItem, rect: Rect2, band: float,
		tint: Color, skin_colours: Dictionary = {}) -> void:
	var face: Color = skin_colours.get("panel", PANEL)
	var low: Color = skin_colours.get("panel_low", PANEL_LOW)
	var edge: Color = skin_colours.get("panel_edge", PANEL_EDGE)

	# Macro-flat. The plate used to be eight stacked rects lerping from the faceplate
	# all the way down to the edge colour, which is not a gradient — it is eight
	# horizontal strips with visible boundaries, and on orange or mustard it read as
	# exactly that. A painted panel is one colour first and a material second, so the
	# field is flat, and the drift below is the only interior shading left.
	canvas.draw_rect(rect, face)

	# One broad luminance drift, about two percent corner to corner, lit from the top
	# left like everything else in the rack. Drawn as a single polygon with per-vertex
	# colours so the interpolation happens in the renderer: there are no stops, so
	# there is nothing to point at where one tone becomes the next.
	canvas.draw_polygon(PackedVector2Array([rect.position,
		Vector2(rect.end.x, rect.position.y), rect.end,
		Vector2(rect.position.x, rect.end.y)]),
		PackedColorArray([face.lightened(0.02), face.lightened(0.008),
			face.darkened(0.025), face.darkened(0.008)]))

	# The finish, over the colour and under everything else. Tiled rather than stretched,
	# so a tall module and a short one have the same size of grain - a stretched texture
	# would make the finish a property of the module's height, which it is not. The alpha
	# is the shared formula, so the rack and the graph cannot disagree about how grainy a
	# style is.
	var finish := str(skin_colours.get("finish", ""))
	if finish != "":
		var grain := float(skin_colours.get("grain", 0.06))
		canvas.draw_texture_rect(Faceplate.texture(finish), rect, true,
			Color(1, 1, 1, Faceplate.veil_alpha(finish, grain)))
		if finish == "worn":
			_draw_wear(canvas, rect)

	# Depth lives at the perimeter now: a hairline of light along the top and left where
	# the plate faces the light, a hairline of dark along the bottom and right where it
	# turns away. The edge does the work the interior stripes used to fail at.
	canvas.draw_line(Vector2(rect.position.x, rect.position.y + 0.5),
		Vector2(rect.end.x, rect.position.y + 0.5), Color(1, 1, 1, 0.10), 1.0)
	canvas.draw_line(Vector2(rect.position.x + 0.5, rect.position.y),
		Vector2(rect.position.x + 0.5, rect.end.y), edge, 1.0)
	canvas.draw_line(Vector2(rect.position.x, rect.end.y - 0.5),
		Vector2(rect.end.x, rect.end.y - 0.5), Color(low, 0.8), 1.5)
	canvas.draw_line(Vector2(rect.end.x - 0.5, rect.position.y),
		Vector2(rect.end.x - 0.5, rect.end.y), Color(0, 0, 0, 0.35), 1.0)

	# Category stripe under the title, a module's only use of colour for identity — the
	# title says the same thing in words.
	if band > 0.0 and bool(skin_colours.get("stripe", true)):
		canvas.draw_rect(Rect2(rect.position.x + 10.0,
			rect.position.y + band - 7.0, rect.size.x - 20.0, 2.0),
			Color(tint.r, tint.g, tint.b, 0.85))


## One socket: the nut, the hole, and the ring or pip that says which way it faces.
##
## Shared with the file's panel for the same reason draw_plate is — a port on the panel
## and a port on a rack module are the same socket seen twice, and if they stopped
## looking alike that would be a claim about them being different things. An input and an
## output differ by the marking rather than only by which edge they sit on, which is what
## makes the symbol readable away from the module that gave it a side.
static func draw_socket(canvas: CanvasItem, centre: Vector2, radius: float,
		is_input: bool, colour: Color, skin_colours: Dictionary = {}) -> void:
	# The nut around the hole. Every theme in the family has a black jack field, so this
	# is the ring colour brought most of the way down to the panel rather than a token of
	# its own - a metal collar catching a little of whatever it is screwed into.
	var ring: Color = skin_colours.get("ring", Color(0, 0, 0, 0))
	var nut := Color(0.20, 0.21, 0.24) if ring.a <= 0.0 else ring.darkened(0.72)
	canvas.draw_circle(centre, radius, nut)
	canvas.draw_circle(centre, radius, Color(0, 0, 0, 0.55), false, 1.0)
	canvas.draw_circle(centre, radius - radius * 0.27, skin_colours.get("jack", JACK_HOLE))
	if is_input:
		canvas.draw_circle(centre, radius - radius * 0.14, colour, false,
			maxf(radius * 0.18, 1.0))
	else:
		canvas.draw_circle(centre, radius - radius * 0.5, colour)


## Worn edges: a panel that has been in and out of a case rubs bright at its corners and
## dark along its sides.
##
## Drawn rather than baked into the tile because it is a fact about the *edge* of a panel,
## and a tiled texture has no idea where the edge is. Nested rectangles rather than a
## gradient: a handful of one-pixel outlines at decreasing alpha is the same picture and
## costs nothing, where a real gradient here would mean a second texture per module size.
static func _draw_wear(canvas: CanvasItem, rect: Rect2) -> void:
	for i in 5:
		var inset := float(i)
		var fade := (1.0 - inset / 5.0) * 0.10
		canvas.draw_rect(Rect2(rect.position + Vector2.ONE * inset,
			rect.size - Vector2.ONE * inset * 2.0), Color(1, 1, 1, fade * 0.45), false, 1.0)
	# And the rub along the two long sides, where a rack module is actually handled.
	for i in 3:
		var inset := float(i)
		canvas.draw_line(
			Vector2(rect.position.x + inset + 0.5, rect.position.y + 6.0),
			Vector2(rect.position.x + inset + 0.5, rect.end.y - 6.0),
			Color(1, 1, 1, 0.05 * (1.0 - inset / 3.0)), 1.0)
		canvas.draw_line(
			Vector2(rect.end.x - inset - 0.5, rect.position.y + 6.0),
			Vector2(rect.end.x - inset - 0.5, rect.end.y - 6.0),
			Color(0, 0, 0, 0.10 * (1.0 - inset / 3.0)), 1.0)


## The mounting screws, in the rail above and below.
##
## `both_rails` off leaves the lower pair out, for a plate whose bottom rail is doing
## something else — the panel's blocks run their envelope down to the edge, and a screw
## through a fader's label is not a detail, it is a collision.
static func draw_screws(canvas: CanvasItem, rect: Rect2, radius: float = SCREW_RADIUS,
		both_rails: bool = true, skin_colours: Dictionary = {}) -> void:
	# The inset multiplier came down as the radius went up. It was 3.2 for a 3.4 radius,
	# which is a centre 10.9 from the edge and a 7.5 gap; keeping it would have put a
	# doubled screw 21.8 in, most of the way to the knobs. Two-times leaves the same gap
	# and — because 6.8 x 2 x 0.8 is 10.9 — the same distance down from the rail as
	# before, so the title sits exactly where it did.
	var inset := radius * 2.0
	var points := [Vector2(rect.position.x + inset, rect.position.y + inset * 0.8),
		Vector2(rect.end.x - inset, rect.position.y + inset * 0.8)]
	if both_rails:
		points.append(Vector2(rect.position.x + inset, rect.end.y - inset * 0.8))
		points.append(Vector2(rect.end.x - inset, rect.end.y - inset * 0.8))
	for point: Vector2 in points:
		draw_screw(canvas, point, radius, skin_colours)


## One screw: a cross-head in steel, lit from above, sitting on its own shadow.
##
## It was a flat disc with a ring around it, which at four per module is a lot of
## repetitions of something that reads as a hole rather than as hardware. A screw is the
## smallest thing on the panel and the one there are most of, so it is worth the dozen
## draw calls: the head catches light along its top, the cross is cut into it, and the
## shadow underneath is what puts it in front of the panel rather than in it.
##
## Steel, whatever the panel is painted. Screws are the one part of a module nobody
## finishes to match - the theme's own colour tints this by a third, so a brass-ish rack
## keeps a hint of its warmth without the hardware ceasing to be metal.
static func draw_screw(canvas: CanvasItem, centre: Vector2, radius: float,
		skin_colours: Dictionary = {}) -> void:
	var tint: Color = skin_colours.get("screw", SCREW_STEEL)
	var steel := SCREW_STEEL.lerp(tint, 0.30)
	var shade := SCREW_STEEL_LOW.lerp(tint, 0.30)

	# The shadow it casts, below it, because the light is above it. Slightly wider than
	# the head and soft-edged by being drawn twice.
	canvas.draw_circle(centre + Vector2(0.0, radius * 0.5), radius * 1.05,
		Color(0, 0, 0, 0.14))
	canvas.draw_circle(centre + Vector2(0.0, radius * 0.35), radius * 0.98,
		Color(0, 0, 0, 0.20))

	# The rim, then the face sitting a little high in it: a bevel, seen from straight on.
	canvas.draw_circle(centre, radius, shade)
	canvas.draw_circle(centre - Vector2(0.0, radius * 0.10), radius * 0.86, steel)

	# The lit crescent along the top of the head, and the darker one under it.
	var thickness := maxf(radius * 0.24, 0.9)
	canvas.draw_arc(centre, radius * 0.70, PI * 1.12, PI * 1.88, 14,
		steel.lightened(0.22), thickness * 0.85, true)
	canvas.draw_arc(centre, radius * 0.74, PI * 0.15, PI * 0.85, 14,
		Color(0, 0, 0, 0.22), thickness * 0.8, true)

	# The cross, cut in. Each arm is a dark groove with a lit lower edge - the wall the
	# light from above actually falls on.
	var arm := radius * 0.60
	var groove := maxf(radius * 0.20, 1.0)
	var offset := maxf(groove * 0.55, 0.7)
	canvas.draw_line(centre - Vector2(arm, 0.0), centre + Vector2(arm, 0.0),
		Color(0, 0, 0, 0.60), groove, true)
	canvas.draw_line(centre - Vector2(arm, -offset), centre + Vector2(arm, -offset),
		Color(1, 1, 1, 0.20), groove * 0.5, true)
	canvas.draw_line(centre - Vector2(0.0, arm), centre + Vector2(0.0, arm),
		Color(0, 0, 0, 0.60), groove, true)
	canvas.draw_line(centre - Vector2(-offset, arm), centre + Vector2(-offset, arm),
		Color(1, 1, 1, 0.14), groove * 0.5, true)


## Trims text to the room there is, with an ellipsis to say it was trimmed.
##
## An ellipsis rather than a hard cut, because "cutoff_mo" and "cutoff_mod" are two
## plausible port names and the reader cannot tell which one they are looking at.
static func elided(font: Font, text: String, size: int, room: float) -> String:
	if font == null or room <= 0.0:
		return ""
	if font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x <= room:
		return text
	var kept := text
	while kept.length() > 1:
		kept = kept.substr(0, kept.length() - 1)
		if font.get_string_size(kept + "…", HORIZONTAL_ALIGNMENT_LEFT, -1,
				size).x <= room:
			return kept + "…"
	return "…"



