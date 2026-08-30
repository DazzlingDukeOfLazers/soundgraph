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

## Where a node lands in the rail, by the category dsp-core gives it.
##
## A map of nine core categories rather than a list of fifty node names: a node added to
## the core lands somewhere sensible on its own, where a hand-written list would quietly
## drop it. The rail's names are the editor's — the core has no opinion about whether a
## delay line is an effect, and should not have to.
const CORE_FAMILIES := {
	"Terminals": "MIDI & IO",
	"Sources": "Oscillators",
	"Filters": "Filters",
	"Time": "Effects",
	"Amplitude": "Mixing",
	"Effects": "Effects",
	"Maths": "Utilities",
	"Utilities": "Utilities",
	"Modulation": "Modulation",
}

## The nodes whose core family is right and whose rail row is not. Envelopes and
## sequencers are modulation as far as the core is concerned, and are their own rows here
## because that is how they are looked for.
##
## The empty strings are the honest ones: three sources that are not oscillators, and no
## row on the rail says what they are. They are findable under All and by name, and the
## rail is frozen, so they are recorded here rather than filed somewhere wrong.
const NODE_ROWS := {
	"ADSR": "Envelopes",
	"AhdEnvelope": "Envelopes",
	"StepSequencer": "Sequencers",
	"Euclid": "Sequencers",
	"Arpeggio": "Sequencers",
	"Clock": "Sequencers",
	"Drive": "Effects",
	"Crush": "Effects",
	"MidiCC": "MIDI & IO",
	"Sampler": "",
	"Speech": "",
	"PluginInstrument": "",
}

## Which bank a device belongs to, by the prefix on its label. Everything else — the
## worked patches, the game sounds, the synth and drum machine voices — is an example.
const DEVICE_ROWS := {
	"Node": "Node bank",
	"FM": "FM bank",
	"DX7": "DX7 bank",
}

## Rows the middle column is built from, handed over by the editor: each is
## {id, name, family, kind}. Step 4 normalises this properly; for now it is the least
## the column needs and the browser does not reach into the registry itself.
var catalogue: Array = []
## The core's own node ranking, so "make quieter" finds the same node here as on the
## command line. Query in, ranked type names out.
var ranker: Callable = Callable()

var search_field: LineEdit
var results_list: VBoxContainer
var selected_item := ""

signal item_activated(id: String)

const RESULT_HEIGHT := 36
const SEARCH_HEIGHT := 42

static var CATEGORY_ORDER: Array = _category_order()

var _results: ScrollContainer
var _result_rows: Array = []


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
	_build_results()
	category_chosen.connect(func(_category: String) -> void: refresh_results())


## The middle column: a search field, then what matches, grouped.
##
## Rows carry a name and nothing else. The old palette put an Add button on every row,
## which is dozens of identical calls to action down a list you are trying to read — the
## row is the target, and what happens when you take it belongs in one place, later.
func _build_results() -> void:
	var field := PanelContainer.new()
	field.custom_minimum_size.y = SEARCH_HEIGHT
	var box := Design.padded_panel(Design.Surface.NODE, Design.SPACE_M, 0,
		Design.RADIUS_BUTTON)
	# An identifying edge rather than the quiet one panels get: this is the object the
	# column is entered through, and it has to look typed into before it is typed into.
	box.border_color = Design.BOUNDARY
	field.add_theme_stylebox_override("panel", box)
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", Design.SPACE_S)
	field.add_child(line)

	var lens := TextureRect.new()
	lens.texture = Icons.get_icon(Icons.Kind.SEARCH, Design.scale(16), Design.INK_SECOND)
	lens.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	line.add_child(lens)

	search_field = LineEdit.new()
	search_field.placeholder_text = "Search nodes"
	search_field.flat = true
	# The frame around it is the PanelContainer's. A LineEdit that draws its own focus
	# box inside somebody else's frame is two borders and a gap.
	search_field.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	search_field.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	search_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	search_field.add_theme_font_size_override("font_size",
		Design.type(Design.SIZE_SECONDARY))
	search_field.text_changed.connect(func(_text: String) -> void: refresh_results())
	# Taken from the field itself, before it can spend them on its caret. A focused
	# LineEdit eats the arrow keys, so unhandled input never sees them — which is why
	# down did nothing at all while the field had the focus it is given on opening.
	search_field.gui_input.connect(_on_search_key)
	line.add_child(search_field)

	# Quiet, and on the right, where a shortcut hint belongs. The browser opens with the
	# field already focused, so this is discoverability rather than instruction.
	var shortcut := Label.new()
	shortcut.text = "Cmd K" if OS.get_name() == "macOS" else "Ctrl K"
	shortcut.add_theme_font_size_override("font_size", Design.type(Design.SIZE_SECONDARY))
	shortcut.add_theme_color_override("font_color",
		Design.INK_SECOND.lerp(Design.SURFACES[Design.Surface.NODE], 0.4))
	line.add_child(shortcut)
	results_column.add_child(field)

	_results = ScrollContainer.new()
	_results.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_results.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	results_column.add_child(_results)
	results_list = VBoxContainer.new()
	results_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	results_list.add_theme_constant_override("separation", 0)
	_results.add_child(results_list)


## Everything the chosen category holds, narrowed by whatever has been typed.
##
## The category is a scope rather than a decoration: a search inside Examples searches
## examples. All is the exception in both directions — with nothing typed it shows the
## node vocabulary alone, because three hundred devices under an empty search buries the
## fifty things you wire together; with something typed it searches everything there is.
func refresh_results() -> void:
	for child in results_list.get_children():
		results_list.remove_child(child)
		child.queue_free()
	_result_rows.clear()

	var query := search_field.text.strip_edges() if search_field != null else ""
	var ranked := {}
	if query != "" and ranker.is_valid():
		for name in ranker.call(query):
			ranked[str(name)] = true

	var groups: Array = []
	var members := {}
	for item: Dictionary in catalogue:
		var kind := str(item.get("kind", ""))
		if selected_category == "All":
			if query == "" and kind != "node":
				continue
		elif row_of(item) != selected_category:
			continue
		if query != "":
			if kind == "node":
				if not ranked.has(str(item.get("id", ""))):
					continue
			elif not _matches(str(item.get("name", "")), query):
				continue
		var group := group_of(item)
		if not members.has(group):
			members[group] = []
			groups.append(group)
		(members[group] as Array).append(item)

	# Nodes land under their own rail row, so All reads down the rail rather than down
	# whatever order the registry happens to be in. Device families keep theirs, which is
	# the shelf order the banks were built in.
	groups.sort_custom(func(a: String, b: String) -> bool:
		var left := CATEGORY_ORDER.find(a)
		var right := CATEGORY_ORDER.find(b)
		if left < 0 and right < 0:
			return false
		return (left if left >= 0 else 99) < (right if right >= 0 else 99))

	# Headings are landmarks, so they earn their line only when there is more than one
	# place to land. A single heading over a single group is a label for the column, and
	# the column already has one.
	var landmarks := groups.size() > 1
	for group: String in groups:
		if landmarks:
			results_list.add_child(_group_heading(group))
		for item: Dictionary in members[group]:
			var row := _result_row(item)
			results_list.add_child(row)
			_result_rows.append(row)

	if _result_rows.is_empty():
		var nothing := Label.new()
		nothing.text = "Nothing here matches that."
		nothing.add_theme_color_override("font_color", Design.INK_SECOND)
		results_list.add_child(nothing)
		select_item("")
		return
	select_item(str((_result_rows[0] as Button).get_meta("id")))


## The landmark an item sits under: its rail row if it is a node, its shelf if it is a
## device. A worked patch has no shelf and no prefix, and Patches is what it is.
func group_of(item: Dictionary) -> String:
	if str(item.get("kind", "")) == "node":
		var row := row_of(item)
		return row if row != "" else "Other"
	var family := str(item.get("family", ""))
	return family if family != "" else "Patches"


## The rail's own order, for sorting the landmarks under All by it.
static func _category_order() -> Array:
	var names: Array = []
	for entry: Variant in CATEGORIES:
		if entry != null:
			names.append(str((entry as Array)[0]))
	names.append("Other")
	return names


## Which rail row an item belongs under.
func row_of(item: Dictionary) -> String:
	var id := str(item.get("id", ""))
	if str(item.get("kind", "")) == "node":
		if NODE_ROWS.has(id):
			return str(NODE_ROWS[id])
		return str(CORE_FAMILIES.get(str(item.get("family", "")), ""))
	return str(DEVICE_ROWS.get(str(item.get("family", "")), "Examples"))


## Every word of the query somewhere in the name. No ranking science: the core does the
## ranking for nodes, and for a list of devices "kit" finding the kits is the whole job.
func _matches(name: String, query: String) -> bool:
	var lowered := name.to_lower()
	for word in query.to_lower().split(" ", false):
		if not lowered.contains(str(word)):
			return false
	return true


func _group_heading(group: String) -> Control:
	var holder := MarginContainer.new()
	holder.add_theme_constant_override("margin_top", Design.SPACE_M)
	holder.add_theme_constant_override("margin_bottom", Design.SPACE_XS)
	holder.add_theme_constant_override("margin_left", Design.scale(Design.SPACE_M))
	var label := Label.new()
	label.text = group.to_upper()
	label.add_theme_font_override("font", Design.font(Design.WEIGHT_SEMIBOLD))
	label.add_theme_font_size_override("font_size", Design.type(Design.SIZE_SECONDARY))
	label.add_theme_color_override("font_color",
		Design.INK_SECOND.lerp(Design.SURFACES[Design.Surface.RAISED], 0.3))
	holder.add_child(label)
	return holder


func _result_row(item: Dictionary) -> Button:
	var row := Button.new()
	row.text = str(item.get("name", ""))
	row.set_meta("id", str(item.get("id", "")))
	row.set_meta("category", str(item.get("id", "")))
	row.custom_minimum_size.y = RESULT_HEIGHT
	row.alignment = HORIZONTAL_ALIGNMENT_LEFT
	row.focus_mode = Control.FOCUS_NONE
	row.clip_text = true
	row.add_theme_font_size_override("font_size", Design.type(Design.SIZE_SECONDARY))
	row.pressed.connect(func() -> void: select_item(str(item.get("id", ""))))
	return row


## The keys the search field would otherwise keep to itself.
func _on_search_key(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed:
		return
	match key.keycode:
		KEY_DOWN:
			step_selection(1)
		KEY_UP:
			step_selection(-1)
		KEY_ENTER, KEY_KP_ENTER:
			activate_selected()
		_:
			return
	search_field.accept_event()


## Lights one result, and keeps it on screen. Keyboard navigation that moves the
## selection somewhere you cannot see is worse than none.
func select_item(id: String) -> void:
	selected_item = id
	for row: Button in _result_rows:
		var chosen := str(row.get_meta("id")) == id
		_dress_row(row, chosen)
		if chosen and _results != null:
			_results.ensure_control_visible(row)


## Enter. What ought to happen to a given kind of item is step seven's question; for now
## it leaves as a signal and the editor answers it the way the palette already does.
func activate_selected() -> void:
	if selected_item != "":
		item_activated.emit(selected_item)


## Moves the lit result, and stops at the ends rather than wrapping.
func step_selection(step: int) -> void:
	if _result_rows.is_empty():
		return
	var at := 0
	for i in _result_rows.size():
		if str((_result_rows[i] as Button).get_meta("id")) == selected_item:
			at = i
	select_item(str((_result_rows[clampi(at + step, 0, _result_rows.size() - 1)]
		as Button).get_meta("id")))


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
	# The rail's rows carry a mark; the results' rows carry a name and nothing else.
	if row.has_meta("mark"):
		row.icon = Icons.get_icon(int(row.get_meta("mark")), Design.scale(ROW_ICON), ink)


## The keyboard model, as far as this step goes: type to search, up and down to move,
## Enter to take the lit row, Ctrl+K back to the field.
##
## Up and down go wherever the focus is. The browser opens with the search field focused,
## so they move the results, which is the flow this column exists for; with the field
## released they walk the rail, which is what step two established. Tab between the
## regions is step eight's, and until it lands the rail's keys are reachable by clicking
## out of the field.
func _unhandled_key_input(event: InputEvent) -> void:
	if not visible:
		return
	var key := event as InputEventKey
	if key == null or not key.pressed:
		return

	if key.keycode == KEY_K and key.is_command_or_control_pressed():
		if search_field != null:
			search_field.grab_focus()
			search_field.select_all()
		get_viewport().set_input_as_handled()
		return
	if key.keycode == KEY_ENTER or key.keycode == KEY_KP_ENTER:
		activate_selected()
		get_viewport().set_input_as_handled()
		return

	var step := 0
	match key.keycode:
		KEY_DOWN:
			step = 1
		KEY_UP:
			step = -1
		_:
			return
	if search_field != null and search_field.has_focus():
		step_selection(step)
	elif not _rows.is_empty():
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
	# Every opening is a fresh look: an old query still in the field is a browser that
	# says there are two oscillators. The field takes the focus, so typing works with
	# nothing clicked first.
	if search_field != null:
		search_field.text = ""
		search_field.grab_focus()
	refresh_results()
	# Asked again after the fact. Showing a popup nudges its position by a few pixels of
	# its own accord, which is invisible on a dialog placed in the middle of a window and
	# is exactly the measurement that matters on one hung off a toolbar button.
	position = at
