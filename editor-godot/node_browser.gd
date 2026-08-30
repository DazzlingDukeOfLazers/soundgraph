extends PopupPanel

## The Add Node browser: one place to search, scan, understand and act from.
##
## Step 1 of docs/add-node-browser.md builds the shell and nothing else — three columns,
## the dividers between them, and a close button that works. The categories, the results,
## the preview and every behaviour they imply arrive in their own steps, each rendered and
## reviewed before the next is started, because the whole point of the sequence is that
## no single review has six changes in it.
##
## Its own file rather than more of main.gd, which is where the editor's other surfaces
## live: the rack, the schematic, the face, the outline. A browser that will grow a data
## model, a keyboard model and three panes is a surface, not a popup.
##
## What it deliberately is not, yet: the way to add a node. The search palette still is,
## on Ctrl+Space, and stays until this can do the job — replacing a working path with a
## scaffold would make the application worse in exchange for a screenshot.

## The spec's column figures, in real pixels rather than scaled ones — the same choice
## the search palette makes for its own 600x540, and for the same reason: these are
## proportions between three columns, not a text size somebody asked to be bigger. The
## type and the spacing inside still go through the tokens, so an XL reader gets XL text
## in a browser that still fits on the screen.
const COLUMN_CATEGORIES := 220
const COLUMN_RESULTS := 320
const COLUMN_PREVIEW := 360
## Real pixels, like the width and for the same reason — and set above the window cap
## below, so the cap is what decides the height at every UI scale. The rail's contents do
## not scale, so a height that did meant the browser was tall enough for fourteen
## categories at one setting and showed eleven and a scrollbar at another.
const BROWSER_HEIGHT := 800
## How much of the window the browser may take. Raised from 0.84, which left the rail
## twenty pixels short of its fourteen rows: the row height is what the eye is being
## asked about, so the panel is what gave way.
const HEIGHT_SHARE := 0.88
## The gutter the shadow falls into, inside the popup's own rectangle.
const SHADOW := 14
## How far the panel's visible top edge sits below the toolbar button that opened it.
const DROP := 14
## Padding either side plus two column gaps: 964, inside the spec's 900-1000.
const WIDTH := COLUMN_CATEGORIES + COLUMN_RESULTS + COLUMN_PREVIEW + GUTTER * 4
## Panel padding, column gap and section spacing are one figure, as the spec asks. The
## design system already calls 16 SPACE_L; this names it for the places that read as
## "the browser's gutter" rather than as "a spacing step".
const GUTTER := Design.SPACE_L

## The three column bodies, for the steps that fill them.
var categories_column: VBoxContainer
var results_column: VBoxContainer
var preview_column: VBoxContainer

var _close_button: Button

## What the rail holds, in order: a name and its mark, or null for a rule between
## families. Three families, and the rules are what say so — the primitive node classes,
## then the examples, then the banks. Deliberately not section headings: CATEGORIES is
## already a heading, and a heading under a heading over three rows is a hierarchy
## announcing itself rather than being read.
const CATEGORIES: Array = [
	["All", Icons.Kind.GRID],
	["Oscillators", Icons.Kind.WAVE],
	["Filters", Icons.Kind.FUNNEL],
	["Envelopes", Icons.Kind.ENVELOPE],
	["Modulation", Icons.Kind.ZIGZAG],
	["Utilities", Icons.Kind.SPLIT],
	["Mixing", Icons.Kind.FADERS],
	["Effects", Icons.Kind.ECHO],
	["MIDI & IO", Icons.Kind.PLUG],
	["Sequencers", Icons.Kind.STEPS],
	null,
	["Examples", Icons.Kind.EXAMPLE],
	null,
	["Node bank", Icons.Kind.BANK],
	["FM bank", Icons.Kind.BANK],
	["DX7 bank", Icons.Kind.BANK],
]

## Room to scan, and not scaled with the UI. Fourteen rows at an XL scale factor is more
## rail than there is browser, and the one thing this must not do is rebuild the scrolling
## pile it exists to replace. The text inside still scales.
const ROW_HEIGHT := 36
const ROW_ICON := 20
## Above and below a rule between families. Enough to read as a break, and no more: the
## rail's budget is the whole reason the rows are not taller.
const RULE_AIR := 6
## What the rail has to fit into, in pixels, at the tightest supported combination:
## a 1440x900 window at XL, where the panel's own furniture — padding, title row, column
## heading — takes 193 of the 738 the window cap allows. Comfortable and Compact leave
## six and eight more. Measured windowed, because a popup that is never drawn has no
## size, which is also why the suite checks the rail's content against this figure rather
## than against the scrollbar.
const RAIL_BUDGET := 545

## Which row is lit. The middle column will read it in step 3; nothing does yet, and the
## signal is here so that when something does, the rail does not have to be rewritten.
var selected_category := "All"

signal category_chosen(category: String)

var _rows: Array = []
var _rail: ScrollContainer
var _rail_stack: VBoxContainer


func _ready() -> void:
	# A dark elevated surface with a thin border and a 12px radius, from the editor's own
	# tokens rather than from figures of its own: the spec's last instruction is that the
	# browser must not become a second visual language, and the cheapest way to obey that
	# is to never write a colour down here.
	var frame := Design.padded_panel(Design.Surface.RAISED, GUTTER + SHADOW,
		GUTTER + SHADOW, 12)
	# A popup is a window and clips to its own rectangle, so a shadow drawn outside the
	# panel is a shadow nobody ever sees. The panel is drawn inset instead — negative
	# expand margins pull the paint in by SHADOW on every side, the content margins put
	# the gutter back so the columns do not move, and the shadow falls into the gap.
	frame.expand_margin_left = -float(Design.scale(SHADOW))
	frame.expand_margin_right = -float(Design.scale(SHADOW))
	frame.expand_margin_top = -float(Design.scale(SHADOW))
	frame.expand_margin_bottom = -float(Design.scale(SHADOW))
	frame.shadow_size = Design.scale(SHADOW - 4)
	frame.shadow_offset = Vector2(0.0, Design.scale(4))
	frame.shadow_color = Color(0.0, 0.0, 0.0, 0.45)
	add_theme_stylebox_override("panel", frame)

	var body := VBoxContainer.new()
# No FULL_RECT preset: PopupPanel lays its own single child out inside the panel's
# margins, and a child that also anchors to the whole popup gets counted twice —
# the panel came out 48px larger than it was asked for in both directions.
	# Nothing under the title row: the row is already taller than its text — the close
	# button sets its height — and a gap on top of that put the column headings far
	# enough below the title that the browser read as a large blank dialog waiting for
	# content. The columns carry their own spacing under their own headings.
	body.add_theme_constant_override("separation", 0)
	add_child(body)

	# The title row carries the close button. Esc and a click outside close it too; the
	# button is there because a floating panel with no visible way out is one people
	# click around the edges of hoping.
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", Design.SPACE_S)
	var title := Label.new()
	title.text = "Add node"
	title.add_theme_font_override("font", Design.font(Design.WEIGHT_SEMIBOLD))
	title.add_theme_font_size_override("font_size", Design.type(Design.SIZE_HEADING))
	title.add_theme_color_override("font_color", Design.INK_BRIGHT)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	_close_button = Button.new()
	_close_button.flat = true
	_close_button.icon = Icons.get_icon(Icons.Kind.CROSS, Design.scale(18),
		Design.INK_SECOND)
	_close_button.tooltip_text = "Close (Esc)"
	_close_button.focus_mode = Control.FOCUS_NONE
	_close_button.pressed.connect(hide)
	head.add_child(_close_button)
	body.add_child(head)

	var columns := HBoxContainer.new()
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	columns.add_theme_constant_override("separation", GUTTER)
	body.add_child(columns)

	categories_column = _column(columns, COLUMN_CATEGORIES, "CATEGORIES", true)
	results_column = _column(columns, COLUMN_RESULTS, "NODES", true)
	preview_column = _column(columns, COLUMN_PREVIEW, "PREVIEW & DETAILS", false)
	_build_rail()


## The left rail: three families of category, one rule between each.
##
## Rows are buttons because a row is a thing you press, and a Button already knows what
## hover and press look like on this machine. Nothing about a row suggests a submenu —
## no chevron, no disclosure, no hover-to-open. Pressing one changes the middle column,
## which is the whole of the interaction and the reason the old menu is going.
func _build_rail() -> void:
	_rail = ScrollContainer.new()
	_rail.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_rail.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	# It is sized so that it does not scroll — but a short window is not an excuse to
	# clip the banks off the bottom.
	categories_column.add_child(_rail)
	var stack := VBoxContainer.new()
	stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# No air between rows: fourteen of them plus two rules have to fit without the rail
	# scrolling, and a category list you scroll is the thing this browser exists to stop
	# being. Each row carries its own padding, so they do not touch.
	stack.add_theme_constant_override("separation", 0)
	_rail.add_child(stack)
	_rail_stack = stack

	for entry: Variant in CATEGORIES:
		if entry == null:
			# A rule and the air around it, doing the work a section heading would
			# otherwise do more loudly.
			var margin := MarginContainer.new()
			margin.add_theme_constant_override("margin_top", RULE_AIR)
			margin.add_theme_constant_override("margin_bottom", RULE_AIR)
			var rule := Panel.new()
			rule.custom_minimum_size.y = 1
			var line := StyleBoxFlat.new()
			line.bg_color = Design.BORDERS[Design.Surface.RAISED].lerp(
				Design.SURFACES[Design.Surface.RAISED], 0.3)
			rule.add_theme_stylebox_override("panel", line)
			margin.add_child(rule)
			stack.add_child(margin)
			continue

		var row := Button.new()
		var name := str((entry as Array)[0])
		row.text = name
		row.set_meta("category", name)
		row.set_meta("mark", int((entry as Array)[1]))
		row.custom_minimum_size.y = ROW_HEIGHT
		row.alignment = HORIZONTAL_ALIGNMENT_LEFT
		row.focus_mode = Control.FOCUS_NONE
		row.add_theme_constant_override("h_separation", Design.SPACE_M)
		row.add_theme_font_size_override("font_size", Design.type(Design.SIZE_SECONDARY))
		row.pressed.connect(func() -> void: select_category(name))
		stack.add_child(row)
		_rows.append(row)

	select_category(selected_category)


## Lights one row and leaves the rest alone.
func select_category(category: String) -> void:
	selected_category = category
	for row: Button in _rows:
		_dress_row(row, str(row.get_meta("category")) == category)
	if _rail != null:
		for row: Button in _rows:
			if str(row.get_meta("category")) == category:
				_rail.ensure_control_visible(row)
	category_chosen.emit(category)


## A row in its two states.
##
## Selected is a tint of the accent rather than the accent: a rail of fourteen rows with
## one of them painted mint is a button somebody put in a list. The fill says where you
## are, the edge holds it together, and the ink and the mark carry the colour.
func _dress_row(row: Button, chosen: bool) -> void:
	var surface: Color = Design.SURFACES[Design.Surface.RAISED]
	var quiet := StyleBoxFlat.new()
	quiet.bg_color = Color(surface, 0.0)
	quiet.set_corner_radius_all(Design.RADIUS_BUTTON)
	quiet.content_margin_left = Design.scale(Design.SPACE_M)
	quiet.content_margin_right = Design.scale(Design.SPACE_M)
	var hover := quiet.duplicate() as StyleBoxFlat
	hover.bg_color = surface.lerp(Design.INK_NORMAL, 0.07)

	var ink: Color = Design.INK_SECOND
	if chosen:
		var lit := quiet.duplicate() as StyleBoxFlat
		lit.bg_color = surface.lerp(Design.ACCENT, 0.16)
		lit.set_border_width_all(1)
		lit.border_color = Design.ACCENT.lerp(surface, 0.45)
		ink = Design.ACCENT
		row.add_theme_stylebox_override("normal", lit)
		row.add_theme_stylebox_override("hover", lit)
		row.add_theme_stylebox_override("pressed", lit)
	else:
		row.add_theme_stylebox_override("normal", quiet)
		row.add_theme_stylebox_override("hover", hover)
		row.add_theme_stylebox_override("pressed", hover)
	row.add_theme_color_override("font_color", ink)
	row.add_theme_color_override("font_hover_color",
		ink if chosen else Design.INK_NORMAL)
	row.add_theme_color_override("font_pressed_color", ink)
	row.icon = Icons.get_icon(int(row.get_meta("mark")), Design.scale(ROW_ICON), ink)


## Up and down move the lit row, skipping the rules between families.
func _unhandled_key_input(event: InputEvent) -> void:
	if not visible or _rows.is_empty():
		return
	var key := event as InputEventKey
	if key == null or not key.pressed:
		return
	var step := 0
	match key.keycode:
		KEY_DOWN:
			step = 1
		KEY_UP:
			step = -1
		_:
			return
	var at := 0
	for i in _rows.size():
		if str((_rows[i] as Button).get_meta("category")) == selected_category:
			at = i
	select_category(str((_rows[clampi(at + step, 0, _rows.size() - 1)] as Button)
		.get_meta("category")))
	get_viewport().set_input_as_handled()


## One column: a heading, the body the later steps fill, and the hairline that separates
## it from the next. The divider belongs to the column on its left, so the last one has
## none and the panel does not end in a rule.
func _column(row: HBoxContainer, width: int, heading: String,
		divided: bool) -> VBoxContainer:
	var holder := VBoxContainer.new()
	holder.custom_minimum_size.x = width * 0.55
	holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	holder.size_flags_stretch_ratio = float(width)
	holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	holder.add_theme_constant_override("separation", Design.SPACE_M)
	var label := Label.new()
	label.text = heading
	label.add_theme_font_override("font", Design.font(Design.WEIGHT_SEMIBOLD))
	label.add_theme_font_size_override("font_size", Design.type(Design.SIZE_SECONDARY))
	label.add_theme_color_override("font_color", Design.INK_SECOND)
	holder.add_child(label)
	var content := VBoxContainer.new()
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", Design.SPACE_XS)
	holder.add_child(content)
	row.add_child(holder)

	if divided:
		var rule := Panel.new()
		rule.custom_minimum_size.x = 1
		rule.size_flags_vertical = Control.SIZE_EXPAND_FILL
		var hairline := StyleBoxFlat.new()
		# Softer than the panel's own border. At full border strength a divider between
		# three empty columns is the strongest thing in the body, which makes the browser
		# read as rails rather than as structure; once the columns carry lists it should
		# recede under them.
		hairline.bg_color = Design.BORDERS[Design.Surface.RAISED].lerp(
			Design.SURFACES[Design.Surface.RAISED], 0.45)
		rule.add_theme_stylebox_override("panel", hairline)
		row.add_child(rule)
	return content


## Opens near the control that asked for it, and inside the window wherever that lands.
##
## `anchor` is in the editor's own coordinates — the frame a Control's global_rect is in.
## Not the desktop's: an embedded popup positions itself against its parent viewport, and
## DisplayServer's window size is a different number again once the OS has had its say
## about borders and DPI. Asking the wrong one put the browser's corner off the top-left
## of the screen while the toolbar button sat three hundred pixels away.
func open_beside(anchor: Rect2i) -> void:
	var screen := Vector2i(get_tree().root.get_visible_rect().size)
	# It floats over the editor, so it never takes the whole of it: a browser that
	# covers the patch it is adding to has stopped being a panel and become a mode.
	# The columns share what is left by ratio, so a small window narrows the browser
	# rather than pushing its close button off the edge.
	var outer := Vector2i(mini(WIDTH, int(screen.x * 0.86)),
		mini(BROWSER_HEIGHT, int(screen.y * HEIGHT_SHARE)))
	# A PopupPanel is sized by its contents plus its own frame, so what it is handed is
	# the content box and the padding lands outside it. Handing it the outer figure gave
	# a panel wider than the cap it had just been given — which on a small window is the
	# difference between floating over the editor and covering it. The frame is measured
	# from the theme rather than written down, so different padding cannot quietly
	# reintroduce the overflow.
	var frame := Vector2i(get_theme_stylebox("panel").get_minimum_size())
	size = outer - frame

	# The visible edge sits DROP below the button, not the window's edge: the shadow
	# gutter lives inside the popup's rectangle, so a drop measured from the window
	# would land the panel that much further down again. It should read as the Add node
	# control unfolding from the toolbar rather than as a dialog arriving in the middle
	# of the editor.
	var at := Vector2i(anchor.position.x,
		anchor.end.y + Design.scale(DROP) - Design.scale(SHADOW))
	var margin := Design.scale(Design.SPACE_M)
	at.x = clampi(at.x, margin, maxi(margin, screen.x - outer.x - margin))
	at.y = clampi(at.y, margin, maxi(margin, screen.y - outer.y - margin))
	popup(Rect2i(at, outer - frame))
	# Asked again after the fact. Showing a popup nudges its position by a few pixels of
	# its own accord, which is invisible on a dialog placed in the middle of a window and
	# is exactly the measurement that matters on one hung off a toolbar button.
	position = at
