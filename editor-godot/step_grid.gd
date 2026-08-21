extends Control
## The Step Sequencer's face: a bar of piano roll instead of sixteen number cells.
##
## A column of "step7: 0.25" fields is faithful to the data and mute about the
## music — the one question anyone asks a sequencer lane, "what shape is this
## line", took sixteen small acts of reading to answer. Drawn as a grid it answers
## at a glance: steps run left to right, pitch climbs the left edge past a sliver
## of keyboard, and the lane's melody is a skyline.
##
## The lane speaks octaves, like every pitch wire here, so the rows are semitones:
## painting a cell writes semitone/12. Values that were never pitches — a chopper
## lane's slice offsets, a filter lock — still draw honestly at their exact height,
## between rows when they fall between notes; the grid stretches from one octave
## each way to two when a value lives out there.
##
## Drawing and pointing only: the document is read fresh through `read` every
## frame, so undo, presets and file loads are always already reflected, and edits
## leave through the paint signals for main to write.

signal paint_started
signal step_painted(index: int, value: float)
signal paint_finished

const STEPS := 16

## Supplied by main: () -> {"length": float, "values": Array}. The document is the
## only truth this control has.
var read: Callable

var _painting := false
var _last_painted := Vector2i(-1, 999)
## Semitones each way. Stretches when the lane holds a value beyond an octave.
var _span := 12


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	custom_minimum_size = Vector2(Design.scale(330), Design.scale(150))
	tooltip_text = "One lane, drawn as a roll: click or drag to write steps. " \
		+ "Rows are semitones — the lane speaks octaves, so a row is 1/12."


func _process(_delta: float) -> void:
	# The document can change under this control — undo, a preset, a reload — and
	# polling sixteen floats is cheaper than teaching every one of those to knock.
	if is_visible_in_tree():
		queue_redraw()


func _state() -> Dictionary:
	if read.is_valid():
		return read.call()
	return {"length": 8.0, "values": []}


func _keys_width() -> float:
	return Design.scale(24)


func _row_count() -> int:
	return _span * 2 + 1


func _row_h() -> float:
	return size.y / float(_row_count())


func _col_w() -> float:
	return (size.x - _keys_width()) / float(STEPS)


func _refresh_span(values: Array) -> void:
	var wide := false
	for value in values:
		if absf(float(value)) > 1.001:
			wide = true
	_span = 24 if wide else 12


## The marker's vertical centre for a value, exact rather than snapped: a value
## between notes draws between rows, which is the honest place for it.
func _centre_y(value: float) -> float:
	return (float(_span) - clampf(value * 12.0, -float(_span), float(_span))
		+ 0.5) * _row_h()


func _paint(point: Vector2) -> void:
	var index := clampi(int((point.x - _keys_width()) / _col_w()), 0, STEPS - 1)
	var semitone := clampi(_span - int(point.y / _row_h()), -_span, _span)
	if Vector2i(index, semitone) == _last_painted:
		return
	_last_painted = Vector2i(index, semitone)
	step_painted.emit(index, semitone / 12.0)


func _gui_input(event: InputEvent) -> void:
	var button := event as InputEventMouseButton
	if button != null and button.button_index == MOUSE_BUTTON_LEFT:
		if button.pressed:
			_painting = true
			_last_painted = Vector2i(-1, 999)
			paint_started.emit()
			_paint(button.position)
		elif _painting:
			_painting = false
			paint_finished.emit()
		accept_event()
		return
	var motion := event as InputEventMouseMotion
	if motion != null and _painting:
		_paint(motion.position)
		accept_event()


## A pointer leaving mid-paint commits what it painted, or the edit never closes.
func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT and _painting:
		_painting = false
		paint_finished.emit()


func _draw() -> void:
	var state := _state()
	var values: Array = state.get("values", [])
	_refresh_span(values)
	var length := clampi(int(state.get("length", 8.0) + 0.5), 1, STEPS)
	var keys := _keys_width()
	var row_h := _row_h()
	var col_w := _col_w()
	var font: Font = Design.font(Design.WEIGHT_SEMIBOLD)

	# The rows, and the sliver of keyboard naming them. Pitch class relative to
	# whatever plays the patch: the lane is an offset, so the keyboard is one too,
	# with the octave marks counting from 0 rather than naming C3.
	for r in _row_count():
		var semitone := _span - r
		var cls := ((semitone % 12) + 12) % 12
		var dark := cls in Keyboard.BLACK_OFFSETS
		draw_rect(Rect2(keys, r * row_h, size.x - keys, row_h),
			Color(0.0, 0.0, 0.0, 0.22) if dark else Color(1.0, 1.0, 1.0, 0.03))
		draw_rect(Rect2(0.0, r * row_h, keys, row_h - 1.0),
			Design.BLACK_KEY if dark else Design.WHITE_KEY)
		if cls == 0:
			# Every octave line carries across the grid, and its key says how far
			# from home it is.
			draw_line(Vector2(keys, (r + 1) * row_h), Vector2(size.x, (r + 1) * row_h),
				Color(1.0, 1.0, 1.0, 0.18), 1.0)
			if font != null and row_h >= 7.0:
				var mark := "%+d" % (semitone / 12) if semitone != 0 else "0"
				draw_string(font, Vector2(2.0, (r + 0.5) * row_h + 3.0), mark,
					HORIZONTAL_ALIGNMENT_LEFT, -1, 8, Design.WHITE_KEY_INK)

	# Step columns: the beat every four a shade firmer, like the roll's rows.
	for i in STEPS + 1:
		var x := keys + i * col_w
		draw_line(Vector2(x, 0.0), Vector2(x, size.y),
			Color(1.0, 1.0, 1.0, 0.16 if i % 4 == 0 else 0.06), 1.0)

	# Past the lane's length: room, dimmed, exactly like the roll past its piece.
	if length < STEPS:
		draw_rect(Rect2(keys + length * col_w, 0.0,
			(STEPS - length) * col_w, size.y), Color(0.0, 0.0, 0.0, 0.35))

	for i in STEPS:
		var value := float(values[i]) if i < values.size() else 0.0
		var centre := _centre_y(value)
		var box := Rect2(keys + i * col_w + 1.0, centre - row_h * 0.5 + 1.0,
			col_w - 2.0, row_h - 2.0)
		draw_rect(box, Color(Design.ACCENT, 0.85 if i < length else 0.30))
		draw_rect(box, Color(Design.ACCENT, 1.0 if i < length else 0.4), false, 1.0)
