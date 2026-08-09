class_name Design
extends RefCounted
## The one place the editor's surfaces, type, spacing and colour are decided.
##
## Before this there was no system: a font size here, a hardcoded grey there, and the
## result was exactly what you would expect — application chrome, node headers, node
## bodies, canvas and inspector all landing within a few percent of the same lightness,
## and almost every label at the same weight. Everything was legible and nothing was
## ranked, so the eye had nowhere to start.
##
## Four rules, applied everywhere:
##
##   1. Depth is lightness. Four surface levels — canvas, node, raised, active — each a
##      clear step up, with a border that steps with it. Colour is for *meaning* (signal
##      type, error, accent), never for hierarchy.
##   2. Spacing comes from a scale. 4, 8, 12, 16, 24, 32, and nothing in between. Half the
##      "crowded" feeling in a UI is twelve slightly different paddings.
##   3. Hierarchy is weight and size, in that order. Secondary information gets a lighter
##      weight and a calmer colour before it gets made smaller, because unimportant and
##      unreadable are not the same thing.
##   4. Contrast has a floor, and it is tested. See design_test.gd — every text-on-surface
##      pairing this file defines is checked against WCAG, and primary text is held to the
##      enhanced 7:1 rather than the 4.5:1 minimum. A dense tool people stare at for hours
##      should not be designed right against the line.
##
## Atkinson Hyperlegible Next is the family throughout. It ships as a single variable font
## with a 200–800 weight axis, so Regular, Medium and SemiBold all come from one file.

# ---------------------------------------------------------------------------------
# Surfaces
#
# A ladder in lightness, on a dark base — this is an instrument, and the answer to "make
# it accessible" is not "make it white".
#
# The four values are solved rather than picked. Each step is an even 1.23:1 against the
# one below — enough to read as a boundary on a cheap projector, not so much that the app
# turns into stripes — while every text level still clears its contrast floor on all four,
# with margin. Eyeballing this produced steps of 1.11 and 1.13, which is roughly the
# "everything is the same grey" the redesign started from.
# ---------------------------------------------------------------------------------

enum Surface { CANVAS, NODE, RAISED, ACTIVE }

const SURFACES := [
	Color("14161a"),   # CANVAS — the graph background, the floor of the room
	Color("242830"),   # NODE   — anything that holds content: nodes, panels, the dock
	Color("33373f"),   # RAISED — anything you can press: buttons, fields, sliders
	Color("41454d"),   # ACTIVE — pressed, selected, or currently receiving input
]

## Borders step with the surface, which is what keeps a node readable against the canvas
## when its fill alone is only two levels away.
const BORDERS := [
	Color("14161a"),
	Color("3a3e46"),
	Color("494d55"),
	Color("575b63"),
]

# ---------------------------------------------------------------------------------
# Ink
#
# Four levels, and the discipline is that operationally important labels never drop below
# NORMAL. Dimming is for metadata — units already shown elsewhere, hints, counts.
# ---------------------------------------------------------------------------------

const INK_BRIGHT := Color("f7f8fa")     ## Node titles, the value you are dragging
const INK_NORMAL := Color("dfe3ea")     ## Ordinary labels. The default.
const INK_SECOND := Color("b0b8c6")     ## Metadata. Still comfortably above AA.
const INK_DISABLED := Color("6b7382")   ## Genuinely unavailable, and it should look it.

## Meaning, not hierarchy.
const ACCENT := Color("6ee7b7")
const WARNING := Color("ffcb73")
const ERROR := Color("ff8f87")

# ---------------------------------------------------------------------------------
# Spacing
#
# Snap to these. All of them. A row that is 13 tall because that is what the label
# happened to measure is the difference between "designed" and "assembled".
# ---------------------------------------------------------------------------------

const SPACE_XS := 4
const SPACE_S := 8
const SPACE_M := 12
const SPACE_L := 16
const SPACE_XL := 24
const SPACE_XXL := 32

## Node internals. The single biggest readability change in this pass.
const NODE_PADDING_H := 14
const NODE_PADDING_V := 10
const NODE_ROW_HEIGHT := 28

# ---------------------------------------------------------------------------------
# Radii
#
# Restrained on purpose. The rectangular geometry suits a synthesiser; rounding
# everything to 12 turns engineering software into a banking app.
# ---------------------------------------------------------------------------------

const RADIUS_BUTTON := 5
const RADIUS_PANEL := 7
const RADIUS_NODE := 3

# ---------------------------------------------------------------------------------
# Type
# ---------------------------------------------------------------------------------

const FONT_PATH := "res://fonts/AtkinsonHyperlegibleNext.ttf"
## Atkinson Hyperlegible Mono, if somebody drops it in. Numbers fall back to Next with
## tabular figures, which the variable font does carry — so a column of readouts still
## lines up either way, and this is an upgrade rather than a dependency.
const MONO_PATH := "res://fonts/AtkinsonHyperlegibleMono.ttf"

const WEIGHT_REGULAR := 400
const WEIGHT_MEDIUM := 500
const WEIGHT_SEMIBOLD := 600

## Sizes at Comfortable. Everything scales from here; see scale().
const SIZE_APP_TITLE := 20
const SIZE_NODE_TITLE := 17
const SIZE_BODY := 15
const SIZE_CONTROL := 15
const SIZE_NUMERIC := 14
const SIZE_SECONDARY := 13
const SIZE_HEADING := 12          ## Section headings: upper case, letterspaced, dim.

enum Scale { COMPACT, COMFORTABLE, LARGE, XL }

const SCALE_NAMES := ["Compact", "Comfortable", "Large", "XL"]
const SCALE_FACTORS := [0.875, 1.0, 1.15, 1.35]

static var ui_scale: int = Scale.COMFORTABLE


## Rounds so that a scaled size is still a whole pixel — a half-pixel font size is how
## hinting stops working and everything goes soft at exactly the setting somebody chose
## because they were having trouble reading it.
static func scale(value: float) -> int:
	return int(roundf(value * SCALE_FACTORS[ui_scale]))


static var _faces: Dictionary = {}


## A weight of the UI family, cached — a FontVariation per call would rebuild the atlas
## on every widget.
static func font(weight: int = WEIGHT_REGULAR) -> Font:
	if _faces.has(weight):
		return _faces[weight]
	var base := load(FONT_PATH) as Font
	if base == null:
		return null
	var variation := FontVariation.new()
	variation.base_font = base
	variation.variation_opentype = {_weight_tag(): weight}
	_faces[weight] = variation
	return variation


## The OpenType tag for the weight axis, as a number.
##
## This is not a detail. `variation_opentype` keys must be the numeric tag; a StringName
## key like `&"wght"` is accepted, stored, and silently ignored. The editor asked for
## weight 700 that way from the day the font was added and got 400 every time, so the
## entire UI has been one weight while the code said otherwise — which is most of why
## nothing in it looked ranked. Measured, not guessed: at 15px "Handgloves" is 74px at
## weight 200, 78 at 400 and 85 at 800 through this tag, and 78px at all three through
## the StringName. design_test.gd checks SemiBold is still wider than Regular, which is
## the assertion that would have caught it.
static func _weight_tag() -> int:
	return TextServerManager.get_primary_interface().name_to_tag("weight")


## The face for numbers: readouts, frequencies, CPU estimates, note numbers.
##
## Mono if it is installed, otherwise the UI face with `tnum` turned on so every digit
## takes the same width. Without that a readout counting through 111.0 → 888.0 jitters
## sideways, which is the specific thing that makes a live value hard to read.
static func numeric_font() -> Font:
	if _faces.has(&"numeric"):
		return _faces[&"numeric"]
	var variation := FontVariation.new()
	if ResourceLoader.exists(MONO_PATH):
		variation.base_font = load(MONO_PATH) as Font
	else:
		variation.base_font = load(FONT_PATH) as Font
		variation.variation_opentype = {_weight_tag(): WEIGHT_MEDIUM}
		variation.opentype_features = {&"tnum": 1}
	_faces[&"numeric"] = variation
	return variation


static func has_mono() -> bool:
	return ResourceLoader.exists(MONO_PATH)


# ---------------------------------------------------------------------------------
# Style boxes
# ---------------------------------------------------------------------------------

static func panel(level: int, radius: int = RADIUS_PANEL, border: int = 1) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = SURFACES[level]
	box.set_corner_radius_all(radius)
	box.set_border_width_all(border)
	box.border_color = BORDERS[level]
	return box


static func padded_panel(level: int, horizontal: int, vertical: int,
		radius: int = RADIUS_PANEL) -> StyleBoxFlat:
	var box := panel(level, radius)
	box.content_margin_left = scale(horizontal)
	box.content_margin_right = scale(horizontal)
	box.content_margin_top = scale(vertical)
	box.content_margin_bottom = scale(vertical)
	return box


## Marks one button in a group as the primary verb.
##
## Not everything deserves equal weight. A toolbar where thirteen controls look identical
## makes the reader parse all thirteen to find the one they want; giving the main verb a
## filled accent treatment means it is found without reading. Used sparingly — one per
## region, or it stops meaning anything.
static func make_primary(button: Button) -> Button:
	var normal := padded_panel(Surface.RAISED, SPACE_M, SPACE_S, RADIUS_BUTTON)
	normal.bg_color = ACCENT.darkened(0.55)
	normal.border_color = ACCENT
	button.add_theme_stylebox_override("normal", normal)
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = ACCENT.darkened(0.42)
	button.add_theme_stylebox_override("hover", hover)
	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = ACCENT.darkened(0.3)
	button.add_theme_stylebox_override("pressed", pressed)
	button.add_theme_color_override("font_color", INK_BRIGHT)
	button.add_theme_color_override("font_hover_color", INK_BRIGHT)
	button.add_theme_font_override("font", font(WEIGHT_SEMIBOLD))
	return button


## Marks a button as the one that stops everything.
##
## A panic control has to be findable without reading the toolbar, so it gets the only
## error-coloured treatment in the chrome and never moves. Outlined rather than filled: it
## should be unmistakable when looked for, not shouting the whole time.
static func make_panic(button: Button) -> Button:
	var normal := padded_panel(Surface.RAISED, SPACE_M, SPACE_S, RADIUS_BUTTON)
	normal.border_color = ERROR
	button.add_theme_stylebox_override("normal", normal)
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = ERROR.darkened(0.6)
	button.add_theme_stylebox_override("hover", hover)
	var pressed := hover.duplicate() as StyleBoxFlat
	pressed.bg_color = ERROR.darkened(0.45)
	button.add_theme_stylebox_override("pressed", pressed)
	button.add_theme_color_override("font_color", ERROR)
	button.add_theme_color_override("font_hover_color", INK_BRIGHT)
	button.add_theme_font_override("font", font(WEIGHT_MEDIUM))
	return button


## An outline with nothing inside it, for focus rings — drawn over whatever is already
## there so it reads the same on every surface.
static func focus_ring(colour: Color = ACCENT, width: int = 2) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.draw_center = false
	box.set_corner_radius_all(RADIUS_BUTTON)
	box.set_border_width_all(width)
	box.border_color = colour
	box.set_expand_margin_all(1)
	return box


# ---------------------------------------------------------------------------------
# Contrast
#
# Here rather than in the test, because a value the product cannot compute is a value the
# product cannot honour — the high-contrast preset below picks its ink by measuring.
# ---------------------------------------------------------------------------------

# ---------------------------------------------------------------------------------
# Applying it
#
# Every set_* below goes through these three, which check the item name against Godot's
# default theme first. A theme key with a typo in it is accepted and silently ignored —
# the same failure mode as the `wght` StringName, and just as invisible. Anything
# unrecognised is collected in `unknown_items` and reported by design_test.gd rather than
# quietly doing nothing.
# ---------------------------------------------------------------------------------

static var unknown_items: Array[String] = []


static func _known(kind: String, item: String, type_name: String) -> bool:
	var default := ThemeDB.get_default_theme()
	var present := false
	match kind:
		"color": present = default.has_color(item, type_name)
		"constant": present = default.has_constant(item, type_name)
		"stylebox": present = default.has_stylebox(item, type_name)
		"font": present = default.has_font(item, type_name)
		"font_size": present = default.has_font_size(item, type_name)
	if not present:
		unknown_items.append("%s/%s on %s" % [kind, item, type_name])
	return present


static func set_colour(theme: Theme, item: String, type_name: String, value: Color) -> void:
	if _known("color", item, type_name):
		theme.set_color(item, type_name, value)


static func set_constant(theme: Theme, item: String, type_name: String, value: int) -> void:
	if _known("constant", item, type_name):
		theme.set_constant(item, type_name, value)


static func set_box(theme: Theme, item: String, type_name: String, value: StyleBox) -> void:
	if _known("stylebox", item, type_name):
		theme.set_stylebox(item, type_name, value)


## The colour item is named because not every control calls it "font_color" — RichTextLabel
## wants "default_color" and TabBar "font_unselected_color", and setting the wrong one is
## accepted in silence.
static func set_type(theme: Theme, type_name: String, weight: int, size: int,
		colour: Color, colour_item: String = "font_color") -> void:
	if _known("font", "font", type_name):
		theme.set_font("font", type_name, font(weight))
	if _known("font_size", "font_size", type_name):
		theme.set_font_size("font_size", type_name, scale(size))
	if _known("color", colour_item, type_name):
		theme.set_color(colour_item, type_name, colour)


static func relative_luminance(colour: Color) -> float:
	var channels := [colour.r, colour.g, colour.b]
	var linear := []
	for channel: float in channels:
		linear.append(channel / 12.92 if channel <= 0.04045
			else pow((channel + 0.055) / 1.055, 2.4))
	return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]


## WCAG contrast ratio, 1.0 (identical) to 21.0 (black on white).
static func contrast(foreground: Color, background: Color) -> float:
	var a := relative_luminance(foreground)
	var b := relative_luminance(background)
	var lighter: float = maxf(a, b)
	var darker: float = minf(a, b)
	return (lighter + 0.05) / (darker + 0.05)
