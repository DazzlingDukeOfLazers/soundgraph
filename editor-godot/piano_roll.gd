extends Control
## The piano roll: a step grid whose lanes sit exactly over the keys that play them.
##
## Time runs upward — the bottom row is step one, beside the keys it strikes — and
## pitch runs sideways, borrowed from the keyboard below rather than re-derived: the
## roll asks the keyboard for its range and its key layout every draw, so shifting
## octaves or widening the dock moves the lanes with the keys and the two can never
## disagree about where a note lives. The layout crib is the falling-note school
## (Synthesia, and Bosca Ceoil's pattern grid): white lanes are wide, black lanes
## narrow and shaded, because that is what makes the grid readable as *this* keyboard
## rather than as a spreadsheet.
##
## The roll draws and points; the document and the clock are main's. What is in the
## sequence arrives as the document's own dictionary, a click is only a signal, and
## the playhead is a row index somebody else advances.

signal cell_toggled(step: int, note: int)
signal note_stretched(step: int, note: int, length: int)

## The document's sequence object, shared by reference. Empty means an empty roll.
var sequence: Dictionary = {}

## The keyboard this roll sits above: range and key geometry come from it.
var keyboard: Control

## The row the clock is on, or -1 when stopped. Drawn as a wash over the row.
var playing_step := -1:
	set(value):
		playing_step = value
		queue_redraw()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP


func step_count() -> int:
	return maxi(1, int(sequence.get("steps", 16)))


func _row_height() -> float:
	return size.y / float(step_count())


## The horizontal span of a note's lane, or a zero-width rect when the note is off
## the keyboard's current range. Mirrors the keyboard's own key layout.
func lane(note: int) -> Rect2:
	if keyboard == null:
		return Rect2()
	var first: int = keyboard.first_note
	var octave_count: int = keyboard.octaves
	if note < first or note >= first + octave_count * 12:
		return Rect2()
	var white_width: float = size.x / float(octave_count * Keyboard.WHITE_OFFSETS.size())
	var octave: int = (note - first) / 12
	var semitone: int = (note - first) % 12
	if semitone in Keyboard.BLACK_OFFSETS:
		var centre: float = (octave * Keyboard.WHITE_OFFSETS.size()
			+ float(Keyboard.BLACK_POSITIONS[semitone])) * white_width
		var black_width: float = white_width * Keyboard.BLACK_WIDTH
		return Rect2(centre - black_width * 0.5, 0.0, black_width, size.y)
	var whites_before := 0
	for offset in Keyboard.WHITE_OFFSETS:
		if offset < semitone:
			whites_before += 1
	return Rect2((octave * Keyboard.WHITE_OFFSETS.size() + whites_before) * white_width,
		0.0, white_width, size.y)


## The note under an x position: black lanes first, since they sit over the joins.
func note_at(x: float) -> int:
	if keyboard == null:
		return -1
	var first: int = keyboard.first_note
	var octave_count: int = keyboard.octaves
	for note in range(first, first + octave_count * 12):
		if (note - first) % 12 in Keyboard.BLACK_OFFSETS:
			var span := lane(note)
			if x >= span.position.x and x < span.end.x:
				return note
	for note in range(first, first + octave_count * 12):
		if not (note - first) % 12 in Keyboard.BLACK_OFFSETS:
			var span := lane(note)
			if x >= span.position.x and x < span.end.x:
				return note
	return -1


## The step under a y position. The bottom row is step zero — time rises.
func step_at(y: float) -> int:
	var row := int((size.y - y) / _row_height())
	return clampi(row, 0, step_count() - 1)


## The entry covering a cell — a long note answers for every row it holds.
func _covering(step: int, note: int) -> Dictionary:
	for entry: Dictionary in sequence.get("notes", []):
		if int(entry.get("note", -1)) != note:
			continue
		var from := int(entry.get("step", 0))
		if step >= from and step < from + maxi(1, int(entry.get("length", 1))):
			return entry
	return {}


# The gesture in hand: press anchors a note, dragging upward stretches it, release
# commits. A press that never travels stays a click, which is the toggle.
var _drag_note := -1
var _drag_anchor := -1
var _drag_length := 1
var _drag_moved := false


func _gui_input(event: InputEvent) -> void:
	var motion := event as InputEventMouseMotion
	if motion != null and _drag_note >= 0:
		# Upward only: the anchor is the note's own step, and time rises.
		var row := step_at(motion.position.y)
		var stretched: int = maxi(1, row - _drag_anchor + 1)
		if stretched != _drag_length:
			_drag_length = stretched
			_drag_moved = _drag_moved or stretched > 1
			queue_redraw()
		accept_event()
		return
	var button := event as InputEventMouseButton
	if button == null or button.button_index != MOUSE_BUTTON_LEFT:
		return
	if button.pressed:
		var note := note_at(button.position.x)
		if note < 0:
			return
		var step := step_at(button.position.y)
		# A press on a note's body grabs the whole note by its root, so a long
		# note resizes from where it starts and a click anywhere on it is a click
		# on it, not on the empty row underneath.
		var held := _covering(step, note)
		_drag_note = note
		_drag_anchor = int(held.get("step", step))
		_drag_length = 1
		_drag_moved = false
		accept_event()
		return
	if _drag_note < 0:
		return
	# Release: a travelled press writes the stretched note; a click toggles.
	if _drag_moved:
		note_stretched.emit(_drag_anchor, _drag_note, _drag_length)
	else:
		cell_toggled.emit(_drag_anchor, _drag_note)
	_drag_note = -1
	queue_redraw()
	accept_event()


func _draw() -> void:
	if keyboard == null:
		return
	var rows := step_count()
	var row_height := _row_height()
	var first: int = keyboard.first_note
	var octave_count: int = keyboard.octaves

	# The ground: black lanes shaded the full height, so the keyboard's geography
	# carries up through the grid.
	for note in range(first, first + octave_count * 12):
		if (note - first) % 12 in Keyboard.BLACK_OFFSETS:
			draw_rect(lane(note), Color(0.0, 0.0, 0.0, 0.22))

	# Row lines, with the beat every four steps a shade firmer.
	for row in rows + 1:
		var y: float = size.y - row * row_height
		var beat: bool = row % 4 == 0
		draw_line(Vector2(0.0, y), Vector2(size.x, y),
			Color(1.0, 1.0, 1.0, 0.14 if beat else 0.05), 1.0)
	# Octave seams, so the eye can count columns without counting keys.
	var white_width: float = size.x / float(octave_count * Keyboard.WHITE_OFFSETS.size())
	for octave in octave_count + 1:
		var x: float = octave * Keyboard.WHITE_OFFSETS.size() * white_width
		draw_line(Vector2(x, 0.0), Vector2(x, size.y), Color(1.0, 1.0, 1.0, 0.10), 1.0)

	# The playhead, under the notes: the row being spoken.
	if playing_step >= 0 and playing_step < rows:
		var top: float = size.y - (playing_step + 1) * row_height
		draw_rect(Rect2(0.0, top, size.x, row_height), Color(Design.ACCENT, 0.10))

	# The notes themselves.
	for entry: Dictionary in sequence.get("notes", []):
		var note := int(entry.get("note", -1))
		var span := lane(note)
		if span.size.x <= 0.0:
			continue
		var step := int(entry.get("step", 0))
		var length := maxi(1, int(entry.get("length", 1)))
		var top: float = size.y - float(mini(step + length, rows)) * row_height
		var bottom: float = size.y - float(step) * row_height
		if bottom <= 0.0 or step >= rows:
			continue
		var box := Rect2(span.position.x + 1.0, top + 1.0,
			span.size.x - 2.0, bottom - top - 2.0)
		var sounding: bool = playing_step >= step and playing_step < step + length
		draw_rect(box, Color(Design.ACCENT, 0.9 if sounding else 0.55))
		draw_rect(box, Color(Design.ACCENT, 1.0), false, 1.0)

	# The note in hand, over everything: what release would write, drawn while the
	# drag is still deciding it.
	if _drag_note >= 0 and _drag_moved:
		var held_span := lane(_drag_note)
		if held_span.size.x > 0.0:
			var held_top: float = size.y \
				- float(mini(_drag_anchor + _drag_length, rows)) * row_height
			var held_bottom: float = size.y - float(_drag_anchor) * row_height
			var held_box := Rect2(held_span.position.x + 1.0, held_top + 1.0,
				held_span.size.x - 2.0, held_bottom - held_top - 2.0)
			draw_rect(held_box, Color(Design.ACCENT, 0.35))
			draw_rect(held_box, Color(Design.ACCENT, 1.0), false, 2.0)
