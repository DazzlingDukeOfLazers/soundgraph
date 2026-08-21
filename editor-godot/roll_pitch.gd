extends Control
## A sliver of piano standing on end, beside the roll when the roll lies flat.
##
## The vertical orientation needs no pitch reference — its lanes stand directly on
## the keys that play them. Lying flat the roll loses that alignment, so this gutter
## restores it: the same key layout the roll borrows, turned on end with the low
## notes at the bottom, and every C named, because C is where a reading eye finds
## its feet on any keyboard.
##
## And it plays. A piano drawn next to a grid that only the other piano can sound
## would be a diagram wearing an instrument's clothes — these keys press, glide and
## light exactly like the keyboard below, through the same signals.

signal note_pressed(note: int)
signal note_released(note: int)

## The keyboard whose range, layout and held notes this mirrors.
var keyboard: Control

var _mouse_note := -1


func _ready() -> void:
	custom_minimum_size.x = Design.scale(34)
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE


## A note's span up this strip as (start, width) from the bottom — the roll's own
## pitch mapping, so a key here lines up exactly with its lane next door.
func _span(note: int) -> Vector2:
	var first: int = keyboard.first_note
	var octave_count: int = keyboard.octaves
	if note < first or note >= first + octave_count * 12:
		return Vector2.ZERO
	var white_width: float = size.y / float(octave_count * Keyboard.WHITE_OFFSETS.size())
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


## The note under a point: black keys first, since they reach in over the joins —
## but only where they reach, so the white keys' tails stay their own.
func _note_at(point: Vector2) -> int:
	if keyboard == null:
		return -1
	var pitch: float = size.y - point.y
	var first: int = keyboard.first_note
	var octave_count: int = keyboard.octaves
	if point.x >= size.x * (1.0 - Keyboard.BLACK_HEIGHT):
		for note in range(first, first + octave_count * 12):
			if (note - first) % 12 in Keyboard.BLACK_OFFSETS:
				var span := _span(note)
				if pitch >= span.x and pitch < span.x + span.y:
					return note
	for note in range(first, first + octave_count * 12):
		if not (note - first) % 12 in Keyboard.BLACK_OFFSETS:
			var span := _span(note)
			if pitch >= span.x and pitch < span.x + span.y:
				return note
	return -1


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_press(_note_at(event.position))
		else:
			_release()
		accept_event()
	elif event is InputEventMouseMotion:
		var note := _note_at(event.position)
		tooltip_text = Keyboard.note_name(note) if note >= 0 else ""
		if _mouse_note >= 0:
			# Gliding along the strip glides, the same as the keyboard below.
			if note != _mouse_note:
				_press(note)
			accept_event()


func _press(note: int) -> void:
	if note < 0:
		return
	_release()
	_mouse_note = note
	note_pressed.emit(note)
	queue_redraw()


func _release() -> void:
	if _mouse_note < 0:
		return
	note_released.emit(_mouse_note)
	_mouse_note = -1
	queue_redraw()


## A pointer leaving mid-press must let the note go, or it sounds forever.
func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT:
		_release()


## Whether a note is sounding, whatever pressed it — the keyboard's own ledger.
func _held(note: int) -> bool:
	return keyboard != null and keyboard.held.has(note)


func _draw() -> void:
	if keyboard == null:
		return
	var first: int = keyboard.first_note
	var octave_count: int = keyboard.octaves
	var font: Font = Design.font(Design.WEIGHT_SEMIBOLD)
	# Sized to the key it sits on rather than to the type scale: these keys are a
	# fraction of the playing keyboard's height, and a label taller than its key
	# would name the neighbours as much as the C.
	var label_size: int = clampi(int(size.y / float(octave_count * 7) * 0.8), 8, 14)

	for note in range(first, first + octave_count * 12):
		if (note - first) % 12 in Keyboard.BLACK_OFFSETS:
			continue
		var span := _span(note)
		var rect := Rect2(0.0, size.y - span.x - span.y, size.x, span.y - 1.0)
		draw_rect(rect, Design.ACCENT if _held(note) else Design.WHITE_KEY)
		draw_rect(rect, Keyboard.EDGE, false, 1.0)
		if note % 12 == 0:
			# The heavier boundary every C carries on the playing keyboard, plus
			# its name — on the white key's tail, which the black keys' reach
			# never enters, so the name always sits on clean ivory.
			draw_line(rect.position + Vector2(0.0, rect.size.y),
				rect.end, Keyboard.EDGE, 2.5)
			if font != null:
				draw_string(font, Vector2(3.0,
					rect.get_center().y + font.get_ascent(label_size) * 0.35),
					"C%d" % (note / 12 - 1), HORIZONTAL_ALIGNMENT_LEFT, -1,
					label_size, Design.WHITE_KEY_INK)

	for note in range(first, first + octave_count * 12):
		if not (note - first) % 12 in Keyboard.BLACK_OFFSETS:
			continue
		var span := _span(note)
		# Against the roll's edge, the way every sequencer hangs them: the black
		# keys reach in from the grid, and the white keys' tails face the window.
		var rect := Rect2(size.x * (1.0 - Keyboard.BLACK_HEIGHT),
			size.y - span.x - span.y, size.x * Keyboard.BLACK_HEIGHT, span.y)
		draw_rect(rect, Design.ACCENT.darkened(0.35) if _held(note) else Design.BLACK_KEY)
		draw_rect(rect, Keyboard.EDGE, false, 1.0)
