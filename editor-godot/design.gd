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
# Palettes
#
# Components do not know colours. They ask for a token — canvas, panel, text, audio,
# trigger — and a palette decides what that means. The point is not skinning: it is that
# "audio signal" stays one idea with one name however the editor looks, so a theme can
# change everything about the appearance without changing what anything *means*.
#
# What deliberately does not move between palettes is the semantic mapping. Mint is audio,
# blue is control, amber is gate and trigger, in every one of them. A palette adjusts
# luminance and saturation to keep its contrast, but somebody switching themes should not
# have to relearn the patch language — and Paper does exactly that, using dark signal
# colours instead of the bright ones, because the dark-theme mint would vanish on white.
#
# Every pairing below is checked by design_test.gd against thresholds deliberately above
# the WCAG minimums: 7:1 for operating text where AA asks 4.5, 4.5:1 for semantic coloured
# text, and 3.25:1 for the boundaries of controls where AA asks 3. Designing exactly at a
# cutoff leaves nothing for a bad screen or a bright room to take away.
# ---------------------------------------------------------------------------------

enum Surface { CANVAS, NODE, RAISED, ACTIVE }

enum Palette { LAB, NIGHT_FLIGHT, TAPE, PAPER, MAXIMUM }

const PALETTE_NAMES := ["Lab", "Night Flight", "Tape", "Paper", "Maximum contrast"]

## Each entry is the whole token set. Written out rather than derived, because a derived
## palette is one where a single tweak silently moves eleven other things.
const PALETTES := [
	{   # Lab — instrument black, graphite panels. The default, and the grown-up version
		# of what this editor already looked like.
		"canvas": "0f1318", "panel": "1b212a", "raised": "252d38", "active": "333c4a",
		"border_node": "3a4351", "border_raised": "4a5666", "border_active": "627384", "boundary": "7a90a5",
		"text": "f4f7fa", "text_muted": "b7c0cc", "text_disabled": "6e7887",
		"accent": "57e3b4", "on_accent": "0f1318", "focus": "ffffff",
		"audio": "57e3b4", "control": "8fb8ff", "trigger": "f6c85f",
		"warning": "f6c85f", "danger": "ff7a7a",
	},
	{   # Night Flight — colder blue-black, for OLEDs and for sitting beside a DAW without
		# looking like one.
		"canvas": "0b1020", "panel": "151d31", "raised": "202a42", "active": "2c3856",
		"border_node": "35415f", "border_raised": "455373", "border_active": "60718c", "boundary": "768bac",
		"text": "f7f9ff", "text_muted": "b9c3d6", "text_disabled": "6d778c",
		"accent": "63e6be", "on_accent": "0b1020", "focus": "ffffff",
		"audio": "63e6be", "control": "8cb4ff", "trigger": "ffd166",
		"warning": "ffd166", "danger": "ff808e",
	},
	{   # Tape — brown-black rather than blue-black, creamy text, amber triggers. An old
		# laboratory instrument without the skeuomorphism.
		"canvas": "171311", "panel": "241d1a", "raised": "332923", "active": "43362e",
		"border_node": "473a32", "border_raised": "5d4c41", "border_active": "806b5c", "boundary": "9f8572",
		"text": "fff8f1", "text_muted": "cdbeb0", "text_disabled": "8a7768",
		"accent": "70e0c1", "on_accent": "171311", "focus": "fff8f1",
		"audio": "70e0c1", "control": "93b8ff", "trigger": "ffca66",
		"warning": "ffca66", "danger": "ff8585",
	},
	{   # Paper — not "light mode" but a legibility mode for daylight, classrooms,
		# screenshots and projectors. The signal colours are dark here on purpose: the
		# dark-theme mint would disappear against white.
		"canvas": "f4f2ec", "panel": "ffffff", "raised": "e8e5de", "active": "d8d4cb",
		"border_node": "c9c5bb", "border_raised": "9ba0a8", "border_active": "777e87", "boundary": "6a7078",
		"text": "15171a", "text_muted": "3a3e44", "text_disabled": "767c85",
		"accent": "00543f", "on_accent": "ffffff", "focus": "15171a",
		"audio": "00543f", "control": "0053b3", "trigger": "7a4a00",
		"warning": "8a5400", "danger": "a61b29",
	},
	{   # Maximum contrast — an accessibility mode rather than a look. Minimal gradients,
		# no reliance on subtle borders, very strong focus.
		"canvas": "000000", "panel": "101010", "raised": "202020", "active": "303030",
		"border_node": "6a6a6a", "border_raised": "8a8a8a", "border_active": "b0b0b0", "boundary": "8a8a8a",
		"text": "ffffff", "text_muted": "d1d1d1", "text_disabled": "8f8f8f",
		"accent": "63ffd1", "on_accent": "000000", "focus": "ffffff",
		"audio": "63ffd1", "control": "93c5fd", "trigger": "ffd75f",
		"warning": "ffd75f", "danger": "ff8a8a",
	},
]

static var palette: int = Palette.LAB

# The live token set. Static vars rather than constants, because a palette that cannot
# change is not a palette — and every existing call site keeps the name it already used.
static var SURFACES: Array = []
static var BORDERS: Array = []

static var INK_BRIGHT := Color("f4f7fa")
static var INK_NORMAL := Color("f4f7fa")
static var INK_SECOND := Color("b7c0cc")
static var INK_DISABLED := Color("6e7887")

static var ACCENT := Color("57e3b4")
## Text and icons *on* a filled accent button. Not white by default: white on mint is a
## poor pairing, while the canvas colour on mint is 11.6:1 in Lab.
static var ON_ACCENT := Color("0f1318")
## Keyboard focus, kept distinct from selection so the two are different states rather
## than the same effect twice.
static var FOCUS := Color("ffffff")

## The boundary that identifies a control, held to 3.25:1 against every surface it can be
## drawn over — including ACTIVE, which is the lightest, because a pressed button has an
## ACTIVE fill and this border around it. Solved rather than picked: the values from the
## brief clear 3.3 against the *panel* and only 2.3 against a pressed control, which is
## precisely the state where seeing the edge matters most. Each was walked along its own
## hue until it just cleared, so the palettes keep their character.
##
## The rest of the sentence, kept because it is the distinction that matters: the boundary
## sits on. Distinct from BORDERS, which are the quiet separations between
## panels — WCAG 1.4.11 is about the edge that tells you a thing is a control,
## not about every hairline in a layout, and holding decorative separations to
## the same bar would produce an interface drawn entirely in outlines.
static var BOUNDARY := Color("627384")

## Signal semantics. These are the highest-saturation colours in the system and nothing
## else may use them — a category strip or a decorative header competing at the same
## saturation creates a second colour language for the reader to keep separate.
static var AUDIO := Color("57e3b4")
static var CONTROL := Color("8fb8ff")
static var TRIGGER := Color("f6c85f")

static var WARNING := Color("f6c85f")
static var ERROR := Color("ff7a7a")
## Panic is not an error and does not borrow the colour of one: red on a control promises
## deletion or reports a fault, and silence is the loud thing stopping.
static var PANIC := Color("f6c85f")


## Switches palette and rebuilds every token from it.
static func use_palette(index: int) -> void:
	palette = clampi(index, 0, PALETTES.size() - 1)
	var set: Dictionary = PALETTES[palette]
	SURFACES = [Color(set["canvas"]), Color(set["panel"]), Color(set["raised"]),
		Color(set["active"])]
	# The canvas has no border of its own; it is the floor.
	BORDERS = [Color(set["canvas"]), Color(set["border_node"]), Color(set["border_raised"]),
		Color(set["border_active"])]
	INK_BRIGHT = Color(set["text"])
	# Normal and bright are the same value in these palettes and differ by weight instead.
	# Two greys a few percent apart are a distinction nobody can use; a Regular and a
	# SemiBold at the same colour is one anybody can.
	INK_NORMAL = Color(set["text"])
	INK_SECOND = Color(set["text_muted"])
	INK_DISABLED = Color(set["text_disabled"])
	ACCENT = Color(set["accent"])
	ON_ACCENT = Color(set["on_accent"])
	FOCUS = Color(set["focus"])
	BOUNDARY = Color(set["boundary"])
	AUDIO = Color(set["audio"])
	CONTROL = Color(set["control"])
	TRIGGER = Color(set["trigger"])
	WARNING = Color(set["warning"])
	ERROR = Color(set["danger"])
	PANIC = Color(set["warning"])
	_faces.erase(&"numeric")


## The colour a signal type is drawn in, so no component keeps its own copy of the map.
static func signal_colour(type_name: String) -> Color:
	match type_name:
		"audio": return AUDIO
		"control": return CONTROL
		"event", "note": return TRIGGER
		_: return INK_NORMAL

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

## What a free-standing control offers a finger or a shaky pointer, whatever the visible
## part measures. 44 is the number every platform guideline converges on, and it is a
## statement about the target, not the paint: the button can look 38px tall while the
## pressable rectangle underneath reaches this.
const HIT_TARGET := 44

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

## The three weights, and only these three. No 300 — light text is the one that goes
## first on a projector or a cheap panel, which is the audience this editor is for.
## 700 and up is reserved for exceptional emphasis and is currently used by nothing;
## if everything is bold, the one thing that needs to be has nowhere left to go.
const WEIGHT_REGULAR := 400
const WEIGHT_MEDIUM := 500
const WEIGHT_SEMIBOLD := 600

## Sizes at Comfortable. Everything scales from here; see type() and scale().
const SIZE_APP_TITLE := 21        ## semibold
const SIZE_NODE_TITLE := 17       ## semibold
const SIZE_BODY := 16             ## regular — sidebar prose, lists, menus
const SIZE_CONTROL := 16          ## medium — toolbar buttons and fields
const SIZE_TABS := 15             ## medium — the view tabs, one step under the toolbar
const SIZE_NUMERIC := 16          ## medium, numeric face — parameter values
const SIZE_UNIT := 14             ## regular, numeric face — Hz, ms, octaves
const SIZE_SECONDARY := 14        ## regular — status lines, captions, document name
const SIZE_HEADING := 15          ## semibold — section headings

## No operating text below this, at any UI scale.
##
## The floor is what turns "prefer spacing and weight over shrinking text" from advice
## into a property: Compact tightens the interface by 12.5%, and without a floor that
## quietly took the 14px sizes to 12 — so the scale preset for fitting more on screen
## was also, silently, the preset for worse legibility. Sizes above the floor still
## compress; the ones already at it hold, and Compact saves its space on spacing.
const TYPE_FLOOR := 14

## What the reader must actually receive, after the graph zoom has had its say.
##
## TYPE_FLOOR is a floor on what the type scale may *ask for*. On the canvas that is not
## the same question: GraphEdit scales its nodes geometrically, so a 16px label sitting
## inside a graph at 65% arrives as 10.4 real pixels while its declaration still says 16.
## The design system was telling the truth about the stylesheet and the wrong thing about
## the screen.
##
## These are the sizes below which text is not rendered at all — it is drawn in screen
## space at the minimum instead, or dropped by the level of detail. Geometry may shrink
## without limit; words may not. Per role, because a unit really can go a size under a
## value without becoming decoration, and a node title really does need to survive the
## zoom at which everything else has gone.
const MIN_SCREEN_NODE_TITLE := 15
const MIN_SCREEN_LABEL := 14      ## port names, parameter names, parameter values
const MIN_SCREEN_UNIT := 13
const MIN_SCREEN_META := 12       ## category tags — the first thing decluttering drops

enum Scale { COMPACT, COMFORTABLE, LARGE, XL }

const SCALE_NAMES := ["Compact", "Comfortable", "Large", "XL"]
const SCALE_FACTORS := [0.875, 1.0, 1.15, 1.35]

static var ui_scale: int = Scale.COMFORTABLE

## Turns off everything that moves on its own: the signal glow and the grid fade.
##
## Motion in an interface is a cost some people pay and others do not notice, and an
## accessibility feature that only exists as a hope is not one. Nothing here depends
## on animation to be usable — the glow says "this is running", which the transport
## also says in words.
static var reduced_motion := false


## Rounds so that a scaled size is still a whole pixel — a half-pixel font size is how
## hinting stops working and everything goes soft at exactly the setting somebody chose
## because they were having trouble reading it.
static func scale(value: float) -> int:
	return int(roundf(value * SCALE_FACTORS[ui_scale]))


## scale() with the TYPE_FLOOR under it — the function every font size goes through.
##
## Two functions rather than a floor inside scale(), because scale() also sizes spacing,
## icons and hit targets, and a 12px gap is not a legibility problem the way 12px text is.
static func type(value: float) -> int:
	return maxi(scale(value), TYPE_FLOOR)


## True when `logical` px of type, once `zoom` has scaled it, lands under `minimum` real
## pixels. The half-pixel of slack keeps a size that rounds to exactly the minimum from
## flickering in and out of compensation as the zoom jitters.
static func below_screen_minimum(logical: int, zoom: float, minimum: int) -> bool:
	return float(logical) * zoom < float(minimum) - 0.5


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


## The face for units — Hz, ms, octaves — one size down and one weight down from the
## value they annotate.
##
## The same family as the numbers so "440.0 Hz" reads as one phrase, but regular where
## the value is medium: the unit is metadata, and the ranking should survive somebody
## who cannot see the colour difference.
static func unit_font() -> Font:
	if _faces.has(&"unit"):
		return _faces[&"unit"]
	var variation := FontVariation.new()
	if ResourceLoader.exists(MONO_PATH):
		variation.base_font = load(MONO_PATH) as Font
	else:
		variation.base_font = load(FONT_PATH) as Font
		variation.opentype_features = {&"tnum": 1}
	_faces[&"unit"] = variation
	return variation


static func has_mono() -> bool:
	return ResourceLoader.exists(MONO_PATH)


# ---------------------------------------------------------------------------------
# Style boxes
# ---------------------------------------------------------------------------------

## A surface with a quiet separation around it — panels, docks, anything you read.
static func panel(level: int, radius: int = RADIUS_PANEL, border: int = 1) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = SURFACES[level]
	box.set_corner_radius_all(radius)
	box.set_border_width_all(border)
	box.border_color = BORDERS[level]
	return box


## A surface with an *identifying* edge — anything you operate.
##
## The difference is the whole reason BOUNDARY exists as its own token. A panel needs
## separating from what is behind it, which a hairline does. A button needs to be
## recognisable as a button, which is what WCAG 1.4.11 asks 3:1 for, and which is the
## entire substance of the Maximum Contrast palette — without this the high-contrast
## theme was a slightly darker Lab, because every edge in it still came from the
## decorative border and the loud token went unused.
static func control(level: int, radius: int = RADIUS_BUTTON) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = SURFACES[level]
	box.set_corner_radius_all(radius)
	box.set_border_width_all(1)
	box.border_color = BOUNDARY
	return box


static func padded_panel(level: int, horizontal: int, vertical: int,
		radius: int = RADIUS_PANEL, identifying: bool = false) -> StyleBoxFlat:
	var box := control(level, radius) if identifying else panel(level, radius)
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
	# Filled with the accent itself, not a darkened version of it.
	#
	# It used to be ACCENT.darkened(0.55), which is a different colour from the one
	# ON_ACCENT was measured against — so the label was being paired with a fill nobody
	# had checked it against, and came out at 3.71:1 in every palette. A filled accent
	# button should be filled with the accent; that is the pairing the token is for,
	# and it is 11.6:1 in Lab.
	var normal := padded_panel(Surface.RAISED, SPACE_M, SPACE_S, RADIUS_BUTTON)
	normal.bg_color = ACCENT
	normal.border_color = ACCENT
	button.add_theme_stylebox_override("normal", normal)
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = ACCENT.lightened(0.12)
	hover.border_color = hover.bg_color
	button.add_theme_stylebox_override("hover", hover)
	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = ACCENT.darkened(0.12)
	pressed.border_color = pressed.bg_color
	button.add_theme_stylebox_override("pressed", pressed)
	# ON_ACCENT, not INK_BRIGHT. This is the whole reason that token exists and I used
	# the wrong one anyway: on Paper the bright ink is near-black, so the one filled
	# button in the chrome rendered its label in near-black on dark green and Add node
	# was an unreadable slab. The contrast test passed the entire time, because it was
	# checking the token rather than what the button did with it.
	button.add_theme_color_override("font_color", ON_ACCENT)
	button.add_theme_color_override("font_hover_color", ON_ACCENT)
	button.add_theme_color_override("font_pressed_color", ON_ACCENT)
	button.add_theme_font_override("font", font(WEIGHT_SEMIBOLD))
	return button


## Marks a button as the one that stops everything.
##
## A panic control has to be findable without reading the toolbar, so it gets the only
## error-coloured treatment in the chrome and never moves. Outlined rather than filled: it
## should be unmistakable when looked for, not shouting the whole time.
static func make_panic(button: Button) -> Button:
	var normal := padded_panel(Surface.RAISED, SPACE_M, SPACE_S, RADIUS_BUTTON)
	normal.border_color = PANIC
	button.add_theme_stylebox_override("normal", normal)
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = PANIC.darkened(0.6)
	button.add_theme_stylebox_override("hover", hover)
	var pressed := hover.duplicate() as StyleBoxFlat
	pressed.bg_color = PANIC.darkened(0.45)
	button.add_theme_stylebox_override("pressed", pressed)
	button.add_theme_color_override("font_color", PANIC)
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
		theme.set_font_size("font_size", type_name, type(size))
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
## The quietest version of a colour that still reads against a surface.
##
## For de-emphasis — a rack cable that has nothing to do with the selected module, and
## anything else that should fall behind without leaving. Mixes toward the surface rather
## than fading to transparent, which is not the same thing: transparency assumes what is
## behind is dark, and on Paper Lab a receding colour has to get *lighter*.
##
## The amount of mixing is found rather than fixed, because how much a colour can give up
## depends on how much it had. A fixed 45% put mint at 4.2:1 on Lab and 2.5:1 on Paper —
## the same instruction, one result inside the floor and one under it. Asking for a target
## contrast instead gives the same legibility on every palette and takes whatever mixing
## that happens to need.
##
## A colour already at or below the target is returned untouched. There is nothing to take.
static func recede(ink: Color, surface: Color, target := 3.6) -> Color:
	var key := "%s|%s|%.2f" % [ink.to_html(), surface.to_html(), target]
	if _receded.has(key):
		return _receded[key]
	var result := ink
	if contrast(ink, surface) > target:
		# Contrast falls monotonically as the mix goes up, so a bisection is exact enough
		# in a dozen steps and there is no closed form worth deriving for it.
		var low := 0.0
		var high := 1.0
		for i in 14:
			var middle := (low + high) * 0.5
			if contrast(ink.lerp(surface, middle), surface) >= target:
				low = middle
			else:
				high = middle
		result = ink.lerp(surface, low)
	_receded[key] = result
	return result


static var _receded: Dictionary = {}


static func contrast(foreground: Color, background: Color) -> float:
	var a := relative_luminance(foreground)
	var b := relative_luminance(background)
	var lighter: float = maxf(a, b)
	var darker: float = minf(a, b)
	return (lighter + 0.05) / (darker + 0.05)
