extends Control
## The piano roll: a step grid whose lanes sit exactly over the keys that play them.
##
## In its vertical orientation — the default — time runs upward: the bottom row is
## step one, beside the keys it strikes, and pitch runs sideways, borrowed from the
## keyboard below rather than re-derived: the roll asks the keyboard for its range and
## its key layout every draw, so shifting octaves or widening the dock moves the lanes
## with the keys and the two can never disagree about where a note lives. The layout
## crib is the falling-note school (Synthesia, and Bosca Ceoil's pattern grid): white
## lanes are wide, black lanes narrow and shaded, because that is what makes the grid
## readable as *this* keyboard rather than as a spreadsheet.
##
## Horizontal is the other school — the DAW's: time runs left to right, pitch climbs
## the left edge with the low notes at the bottom. It trades the lanes-over-keys
## alignment for the shape most sequencers have taught, which is a real trade and the
## user's to make. Everything below speaks in two axes — pitch and time — and maps
## them to x and y at the last moment, so the two orientations are one grid.
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

## Which way time runs: "vertical" rises over the keys, "horizontal" runs rightward.
var orientation := "vertical"

## The row the clock is on, or -1 when stopped. Drawn as a wash over the row, and
## followed: when the playhead leaves the window, the window turns the page.
var playing_step := -1:
	set(value):
		playing_step = value
		if playing_step >= 0 and (playing_step < scroll_step
				or playing_step >= scroll_step + view_rows):
			scroll_step = playing_step - playing_step % view_rows
		queue_redraw()

## The window onto a longer piece: how many rows are on screen, and which absolute
## step sits at the window's start. A sequence is up to sixteen bars; the view shows
## from half of one up to eight of them, and the wheel walks the rest.
const MAX_STEPS := 256
var view_rows := 16
var scroll_step := 0


func set_view_rows(rows: int) -> void:
	view_rows = clampi(rows, 8, 128)
	scroll_step = clampi(scroll_step, 0, MAX_STEPS - view_rows)
	queue_redraw()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP


func step_count() -> int:
	return maxi(1, int(sequence.get("steps", 16)))


## The two axes' lengths in pixels, before either is bolted to x or y.
func _pitch_extent() -> float:
	return size.x if orientation == "vertical" else size.y


func _time_extent() -> float:
	return size.y if orientation == "vertical" else size.x


func _row_height() -> float:
	return _time_extent() / float(view_rows)


## A note's span along the pitch axis, as (start, width) measured from the low end.
## Mirrors the keyboard's own key layout, whichever way that axis is lying.
func _pitch_span(note: int) -> Vector2:
	if keyboard == null:
		return Vector2.ZERO
	var first: int = keyboard.first_note
	var octave_count: int = keyboard.octaves
	if note < first or note >= first + octave_count * 12:
		return Vector2.ZERO
	var white_width: float = _pitch_extent() \
		/ float(octave_count * Keyboard.WHITE_OFFSETS.size())
	var octave: int = (note - first) / 12
	var semitone: int = (note - first) % 12
	if semitone in Keyboard.BLACK_OFFSETS:
		var centre: float = (octave * Keyboard.WHITE_OFFSETS.size()
			+ float(Keyboard.BLACK_POSITIONS[semitone])) * white_width
		var black_width: float = white_width * Keyboard.BLACK_WIDTH
		return Vector2(centre - black_width * 0.5, black_width)
	var whites_before := 0
	for offset in Keyboard.WHITE_OFFSETS:
		if offset < semitone:
			whites_before += 1
	return Vector2((octave * Keyboard.WHITE_OFFSETS.size() + whites_before) * white_width,
		white_width)


## The horizontal span of a note's lane in the vertical orientation, or a zero-width
## rect when the note is off the keyboard's current range. The tests speak this.
func lane(note: int) -> Rect2:
	var span := _pitch_span(note)
	return Rect2(span.x, 0.0, span.y, size.y)


## A rectangle in control coordinates covering one pitch span between two moments,
## where t is pixels from the window's start. This is the whole orientation switch:
## vertical stands time on end with later further up, horizontal lays it rightward
## and hangs the pitch axis with the low notes at the bottom.
func _box(span: Vector2, t0: float, t1: float) -> Rect2:
	if orientation == "vertical":
		return Rect2(span.x, size.y - t1, span.y, t1 - t0)
	return Rect2(t0, size.y - span.x - span.y, t1 - t0, span.y)


## The note at a position along the pitch axis, measured from the low end: black
## lanes first, since they sit over the joins.
func note_at(p: float) -> int:
	if keyboard == null:
		return -1
	var first: int = keyboard.first_note
	var octave_count: int = keyboard.octaves
	for note in range(first, first + octave_count * 12):
		if (note - first) % 12 in Keyboard.BLACK_OFFSETS:
			var span := _pitch_span(note)
			if p >= span.x and p < span.x + span.y:
				return note
	for note in range(first, first + octave_count * 12):
		if not (note - first) % 12 in Keyboard.BLACK_OFFSETS:
			var span := _pitch_span(note)
			if p >= span.x and p < span.x + span.y:
				return note
	return -1


## A control-space point's coordinate along the pitch axis, from the low end.
func _pitch_of(point: Vector2) -> float:
	return point.x if orientation == "vertical" else size.y - point.y


## The step at a position along the time axis, in the coordinate that axis uses on
## screen: y in the vertical orientation (the bottom of the window is `scroll_step`),
## x in the horizontal (the left edge is).
func step_at(along: float) -> int:
	var row: int
	if orientation == "vertical":
		row = int((size.y - along) / _row_height())
	else:
		row = int(along / _row_height())
	return clampi(scroll_step + row, scroll_step,
		mini(scroll_step + view_rows - 1, MAX_STEPS - 1))


func _along_time(point: Vector2) -> float:
	return point.y if orientation == "vertical" else point.x


## The entry covering a cell — a long note answers for every row it holds.
func _covering(step: int, note: int) -> Dictionary:
	for entry: Dictionary in sequence.get("notes", []):
		if int(entry.get("note", -1)) != note:
			continue
		var from := int(entry.get("step", 0))
		if step >= from and step < from + maxi(1, int(entry.get("length", 1))):
			return entry
	return {}


# The gesture in hand: press anchors a note, dragging toward later time stretches it,
# release commits. A press that never travels stays a click, which is the toggle.
var _drag_note := -1
var _drag_anchor := -1
var _drag_length := 1
var _drag_moved := false


func _gui_input(event: InputEvent) -> void:
	var wheel := event as InputEventMouseButton
	if wheel != null and wheel.pressed and _drag_note < 0 \
			and wheel.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		# The wheel walks the piece a beat at a time. Standing up, wheel-up is
		# later — the direction the notes already read. Lying flat the same gesture
		# is a scroll, and a scroll pulls the page the other way: wheel-down leans
		# into the piece.
		var toward_later := wheel.button_index == MOUSE_BUTTON_WHEEL_UP
		if orientation == "horizontal":
			toward_later = not toward_later
		var walked := 4 if toward_later else -4
		scroll_step = clampi(scroll_step + walked, 0, MAX_STEPS - view_rows)
		queue_redraw()
		accept_event()
		return
	var motion := event as InputEventMouseMotion
	if motion != null and _drag_note >= 0:
		# Toward later only: the anchor is the note's own step.
		var row := step_at(_along_time(motion.position))
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
		var note := note_at(_pitch_of(button.position))
		if note < 0:
			return
		var step := step_at(_along_time(button.position))
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


## An absolute step's start, in pixels from the window's own start.
func _time_of(step: int) -> float:
	return float(step - scroll_step) * _row_height()


## A line across the whole pitch axis at one moment — a row line, whichever way the
## rows are lying.
func _time_line(t: float, colour: Color, width: float) -> void:
	if orientation == "vertical":
		var y := size.y - t
		draw_line(Vector2(0.0, y), Vector2(size.x, y), colour, width)
	else:
		draw_line(Vector2(t, 0.0), Vector2(t, size.y), colour, width)


## A line down the whole time axis at one pitch — an octave seam.
func _pitch_line(p: float, colour: Color, width: float) -> void:
	if orientation == "vertical":
		draw_line(Vector2(p, 0.0), Vector2(p, size.y), colour, width)
	else:
		var y := size.y - p
		draw_line(Vector2(0.0, y), Vector2(size.x, y), colour, width)


func _draw() -> void:
	if keyboard == null:
		return
	var row_height := _row_height()
	var first: int = keyboard.first_note
	var octave_count: int = keyboard.octaves
	var window_end := scroll_step + view_rows
	var full := Vector2(0.0, _pitch_extent())

	# The ground: black lanes shaded the full length, so the keyboard's geography
	# carries through the grid.
	for note in range(first, first + octave_count * 12):
		if (note - first) % 12 in Keyboard.BLACK_OFFSETS:
			draw_rect(_box(_pitch_span(note), 0.0, _time_extent()),
				Color(0.0, 0.0, 0.0, 0.22))
	# Steps past the piece's current end are dimmed, not fenced: a click out there
	# grows the piece, and the wash says "room" rather than "wall".
	if step_count() < window_end:
		draw_rect(_box(full, maxf(0.0, _time_of(step_count())), _time_extent()),
			Color(0.0, 0.0, 0.0, 0.25))

	# Row lines: the beat every four steps a shade firmer, the bar every sixteen
	# firmer still — a long piece needs the eye to land on bars, not count rows.
	for row in view_rows + 1:
		var absolute := scroll_step + row
		var alpha := 0.05
		if absolute % 16 == 0:
			alpha = 0.24
		elif absolute % 4 == 0:
			alpha = 0.12
		_time_line(row * row_height, Color(1.0, 1.0, 1.0, alpha), 1.0)
	# Octave seams, so the eye can count columns without counting keys.
	var white_width: float = _pitch_extent() \
		/ float(octave_count * Keyboard.WHITE_OFFSETS.size())
	for octave in octave_count + 1:
		_pitch_line(octave * Keyboard.WHITE_OFFSETS.size() * white_width,
			Color(1.0, 1.0, 1.0, 0.10), 1.0)

	# The playhead, under the notes: the row being spoken.
	if playing_step >= scroll_step and playing_step < window_end:
		draw_rect(_box(full, _time_of(playing_step), _time_of(playing_step + 1)),
			Color(Design.ACCENT, 0.10))

	# The notes themselves, clipped to the window.
	for entry: Dictionary in sequence.get("notes", []):
		var note := int(entry.get("note", -1))
		var span := _pitch_span(note)
		if span.y <= 0.0:
			continue
		var step := int(entry.get("step", 0))
		var length := maxi(1, int(entry.get("length", 1)))
		if step >= window_end or step + length <= scroll_step:
			continue
		var box := _box(span, _time_of(maxi(step, scroll_step)),
			_time_of(mini(step + length, window_end)))
		box = Rect2(box.position + Vector2.ONE, box.size - Vector2.ONE * 2.0)
		var sounding: bool = playing_step >= step and playing_step < step + length
		draw_rect(box, Color(Design.ACCENT, 0.9 if sounding else 0.55))
		draw_rect(box, Color(Design.ACCENT, 1.0), false, 1.0)

	# The note in hand, over everything: what release would write, drawn while the
	# drag is still deciding it.
	if _drag_note >= 0 and _drag_moved:
		var held_span := _pitch_span(_drag_note)
		if held_span.y > 0.0:
			var held_box := _box(held_span, _time_of(maxi(_drag_anchor, scroll_step)),
				_time_of(mini(_drag_anchor + _drag_length, window_end)))
			held_box = Rect2(held_box.position + Vector2.ONE,
				held_box.size - Vector2.ONE * 2.0)
			draw_rect(held_box, Color(Design.ACCENT, 0.35))
			draw_rect(held_box, Color(Design.ACCENT, 1.0), false, 2.0)
