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
const BROWSER_HEIGHT := 620
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

const Icons := preload("res://icons.gd")


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
		mini(Design.scale(BROWSER_HEIGHT), int(screen.y * 0.84)))
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
