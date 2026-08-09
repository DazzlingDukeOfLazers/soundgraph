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
##   drag         — coarse by default, ten times finer with Shift held
##   double click — type it, and units are ignored so "440 Hz" and "440" both work
##   middle click or Alt-click — back to the parameter's default
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
## Maps a 0..1 position to a value and back, so this stays out of the scaling rules.
var to_value: Callable
var to_position: Callable
var position_now := 0.0

var _label: Label
var _entry: LineEdit
var _dragging := false
var _drag_origin := 0.0
var _position_at_grab := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_HSIZE
	tooltip_text = "Drag to change · double click to type · Alt-click for the default"

	_label = Label.new()
	_label.text = text
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.add_theme_font_override("font", Design.numeric_font())
	_label.add_theme_font_size_override("font_size", Design.scale(Design.SIZE_NUMERIC))
	_label.add_theme_color_override("font_color", Design.INK_BRIGHT)
	add_child(_label)

	_entry = LineEdit.new()
	_entry.visible = false
	_entry.alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_entry.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_entry.add_theme_font_override("font", Design.numeric_font())
	_entry.add_theme_font_size_override("font_size", Design.scale(Design.SIZE_NUMERIC))
	_entry.text_submitted.connect(_on_typed)
	_entry.focus_exited.connect(_cancel_typing)
	add_child(_entry)


func _gui_input(event: InputEvent) -> void:
	var button := event as InputEventMouseButton
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
