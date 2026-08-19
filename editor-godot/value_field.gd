class_name ValueField
extends Control
## A number you can drag, type into, and put back.
##
## The readout beside a slider was a Label: it showed the value and did nothing. Every
## audio tool of any age lets you grab the number itself, because a slider 112px wide
## cannot resolve 20 Hz to 20 kHz — at the bottom of an exponential range one pixel is
## several hertz, and the only way to ask for exactly 440 was to drag until it said 440.
##
## Three gestures, all of them conventional:
##
##   drag          — coarse by default, ten times finer with Shift held
##   arrow keys    — one step, or ten with Shift; Home and End for the extremes
##   double click  — type it, and units are ignored so "440 Hz" and "440" both work
##   middle click or Alt-click — back to the parameter's default
##
## The keyboard route was the one missing, and it was missing for a reason worth
## writing down: every control in this editor is deliberately unfocusable, because
## the computer keyboard is the piano and a slider that keeps focus after a drag
## silently eats the next note somebody plays. That is a real problem, and the answer
## to it had been to make the whole interface unreachable without a mouse.
##
## The resolution is that focus is taken by Tab and handed straight back after a
## drag. Somebody who tabbed to a parameter is editing it and expects the arrows to
## move it; somebody who dragged it is still playing.
##
## The label still reads the same; it just also does something.

signal value_submitted(value: float)
## While a drag is in progress, so the caller can bracket the whole gesture as one undo
## step rather than one per pixel.
signal drag_started
signal drag_finished

## Pixels of travel for the full range of the parameter. A whole screen width is about
## right for coarse: it makes the gesture feel like a fader rather than a hair trigger.
const DRAG_RANGE := 900.0
const FINE_FACTOR := 0.1

var text: String = "":
	set(value):
		text = value
		if _label != null:
			_label.text = value

var default_value := 0.0

## Centres the number instead of setting it against the right edge.
##
## Right is correct in a row, where a column of values lines up on its last digit and the
## eye can compare magnitudes down the column. It is wrong in a rack cell, where the
## number sits under its own name with nothing to line up against and an off-centre
## figure just looks like it slipped. Set before the field enters the tree.
var centred := false
## Maps a 0..1 position to a value and back, so this stays out of the scaling rules.
var to_value: Callable
var to_position: Callable
var position_now := 0.0

var _label: Label
var _ring: Panel
var _entry: LineEdit
var _dragging := false
var _drag_origin := 0.0
var _position_at_grab := 0.0


## What one arrow press moves, as a fraction of the parameter's whole range.
##
## A fraction rather than a fixed amount, because these ranges run from 0..1 to
## 20..20000 and a step that suits one is useless on the other. A hundred presses
## crosses any parameter; ten with Shift held.
const KEY_STEP := 0.01
const KEY_COARSE := 0.1


## The height of the number this field exists to show.
##
## The inner label is anchored to fill the field, and anchored children contribute
## nothing to a Control's minimum — so this field's minimum height was zero, and any
## container entitled to take it at its word gave it no room at all. The text still
## drew (nothing clips it), which is worse than vanishing: in a knob cell the value
## painted straight across whatever sat below it, and on the node's last row it ran
## off the bottom of the node. The field is exactly one line of numerals tall, so
## that is what it declares.
func _get_minimum_size() -> Vector2:
	var font := Design.numeric_font()
	if font == null:
		return Vector2.ZERO
	return Vector2(0.0, font.get_height(Design.type(Design.SIZE_NUMERIC)))


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_HSIZE
	# Reachable by Tab. See the note at the top of this file for why that is a
	# deliberate exception rather than an oversight corrected.
	focus_mode = Control.FOCUS_ALL
	tooltip_text = "Drag or arrow keys to change · double click to type" \
		+ " · Alt-click for the default"

	_label = Label.new()
	_label.text = text
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER if centred \
		else HORIZONTAL_ALIGNMENT_RIGHT
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.add_theme_font_override("font", Design.numeric_font())
	_label.add_theme_font_size_override("font_size", Design.type(Design.SIZE_NUMERIC))
	_label.add_theme_color_override("font_color", Design.INK_BRIGHT)
	# A parameter's value is operational text, so it is pinned to a readable size in
	# screen space when this field is living on a zoomed-out graph canvas. Marked on the
	# inner label rather than on the field, because the field is a control and what has
	# to stay legible is the word inside it. See PatchGraph.ScreenText.
	_label.set_meta("screen_min", Design.MIN_SCREEN_LABEL)
	_label.set_meta("screen_kind", "value")
	add_child(_label)

	# A ring, because it can hold focus now and a focus you cannot see is a focus that
	# has been lost. Its own state, distinct from hover and from selection.
	_ring = Panel.new()
	_ring.visible = false
	_ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ring.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_ring.add_theme_stylebox_override("panel", Design.focus_ring(Design.FOCUS))
	add_child(_ring)
	focus_entered.connect(func() -> void: _ring.visible = true)
	focus_exited.connect(func() -> void: _ring.visible = false)

	_entry = LineEdit.new()
	_entry.visible = false
	_entry.alignment = HORIZONTAL_ALIGNMENT_CENTER if centred \
		else HORIZONTAL_ALIGNMENT_RIGHT
	_entry.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_entry.add_theme_font_override("font", Design.numeric_font())
	_entry.add_theme_font_size_override("font_size", Design.type(Design.SIZE_NUMERIC))
	_entry.text_submitted.connect(_on_typed)
	_entry.focus_exited.connect(_cancel_typing)
	add_child(_entry)


func _gui_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key != null and key.pressed and has_focus():
		var step := 0.0
		match key.keycode:
			KEY_RIGHT, KEY_UP:
				step = KEY_COARSE if key.shift_pressed else KEY_STEP
			KEY_LEFT, KEY_DOWN:
				step = -(KEY_COARSE if key.shift_pressed else KEY_STEP)
			KEY_PAGEUP:
				step = KEY_COARSE
			KEY_PAGEDOWN:
				step = -KEY_COARSE
			KEY_HOME:
				step = -1.0
			KEY_END:
				step = 1.0
			KEY_ENTER, KEY_KP_ENTER:
				_begin_typing()
				accept_event()
				return
		if step != 0.0:
			nudge(step)
			accept_event()
			return

	var button := event as InputEventMouseButton
	if button != null and button.pressed \
			and button.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		# Ctrl+wheel is the view's zoom, here as on the panel's knobs.
		if button.ctrl_pressed:
			return
		# One notch, one step, the same step an arrow key takes — a wheel is a discrete
		# gesture like a key press rather than a continuous one like a drag, so it borrows
		# the keyboard's numbers rather than the drag's. Accepted whether or not the field
		# has focus: the pointer is over it, which is the whole of what a wheel means.
		var notch: float = KEY_COARSE if button.shift_pressed else KEY_STEP
		nudge(notch if button.button_index == MOUSE_BUTTON_WHEEL_UP else -notch)
		accept_event()
		return

	if button != null and button.pressed:
		if button.button_index == MOUSE_BUTTON_LEFT and button.double_click:
			_begin_typing()
			accept_event()
			return
		# Both, because which one means "reset" depends entirely on what somebody used
		# last. Alt-click is the plugin convention; middle click is the hardware one.
		if button.button_index == MOUSE_BUTTON_MIDDLE \
				or (button.button_index == MOUSE_BUTTON_LEFT and button.alt_pressed):
			drag_started.emit()
			value_submitted.emit(default_value)
			drag_finished.emit()
			accept_event()
			return
		if button.button_index == MOUSE_BUTTON_LEFT:
			_dragging = true
			_drag_origin = button.global_position.x
			_position_at_grab = position_now
			drag_started.emit()
			accept_event()
			return

	if button != null and not button.pressed and button.button_index == MOUSE_BUTTON_LEFT \
			and _dragging:
		_dragging = false
		drag_finished.emit()
		# Handed straight back. A field that kept focus after a mouse drag would eat the
		# next note played, which is the exact failure that made every control in this
		# editor unfocusable in the first place.
		release_focus()
		accept_event()
		return

	var motion := event as InputEventMouseMotion
	if motion != null and _dragging:
		var travel := (motion.global_position.x - _drag_origin) / DRAG_RANGE
		if motion.shift_pressed:
			travel *= FINE_FACTOR
		position_now = clampf(_position_at_grab + travel, 0.0, 1.0)
		if to_value.is_valid():
			value_submitted.emit(to_value.call(position_now))
		accept_event()


## Moves the value by a fraction of its range. One press is one undo step, the same as
## one drag — a held arrow key should not fill the history with three hundred entries.
func nudge(fraction: float) -> void:
	if not to_value.is_valid():
		return
	drag_started.emit()
	position_now = clampf(position_now + fraction, 0.0, 1.0)
	value_submitted.emit(to_value.call(position_now))
	drag_finished.emit()


func _begin_typing() -> void:
	_entry.text = _label.text
	_entry.visible = true
	_label.visible = false
	_entry.grab_focus()
	_entry.select_all()


func _on_typed(entered: String) -> void:
	# Units are stripped rather than rejected. The field displays "440.0 Hz", so the
	# obvious thing to do is edit that string and press return — refusing it because of
	# the unit the field itself put there would be a small cruelty.
	var cleaned := ""
	for character in entered.strip_edges():
		if character in "0123456789.-+eE":
			cleaned += character
		else:
			break
	if cleaned.is_valid_float():
		drag_started.emit()
		value_submitted.emit(cleaned.to_float())
		drag_finished.emit()
	_cancel_typing()


func _cancel_typing() -> void:
	_entry.visible = false
	_label.visible = true
