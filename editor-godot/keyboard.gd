class_name Keyboard
extends Control
## An on-screen piano, and a window onto whether the editor is hearing anything.
##
## The computer keyboard is the instrument, which works until it does not: a slider that
## kept focus, a tab that took the keys, a browser that never got a click. When nothing
## happens there is no way to tell whether the patch is silent or the keypress never
## arrived, and the two have nothing to do with each other.
##
## So this does two jobs. It plays notes with the mouse, which needs no focus and cannot be
## stolen. And it lights up every held note whatever pressed it — mouse, computer keyboard,
## anything — so a key that stays dark says "the editor never heard you" and a key that
## lights up but stays quiet says "the editor heard you and the patch is the problem".
##
## The letters on the keys are the computer-keyboard mapping, which was previously written
## down in a README and nowhere the user could see it while playing.

signal note_pressed(note: int)
signal note_released(note: int)

const WHITE_OFFSETS := [0, 2, 4, 5, 7, 9, 11]
const BLACK_OFFSETS := [1, 3, 6, 8, 10]
## Where each black key sits, as a fraction of a white key's width from the octave's left.
const BLACK_POSITIONS := {1: 0.7, 3: 1.7, 6: 3.7, 8: 4.7, 10: 5.7}

# The keys are genuinely light and genuinely dark now, and their ink is genuinely dark
# and genuinely light. They used to be off-white with grey letters, on the argument that
# full white "carried more apparent mass than anything in the graph" and pulled the eye
# to the bottom of the window. That was a real observation about attention and the wrong
# trade to make with it: the letters ended up at 3.6:1 — half this project's own floor
# for text — on the surface whose whole job is to be read while your hands are busy.
#
# Attention is bought back where it should have been in the first place: the dock frames
# the piano, so the instrument is contained rather than dimmed.
#
# Live properties rather than constants, for the same reason the scope's are: a static
# evaluated at class load keeps whatever palette was active then and ignores every
# switch afterwards.
var WHITE: Color:
	get: return Design.WHITE_KEY
var WHITE_INK: Color:
	get: return Design.WHITE_KEY_INK
var WHITE_HELD: Color:
	get: return Design.ACCENT
var BLACK: Color:
	get: return Design.BLACK_KEY
var BLACK_INK: Color:
	get: return Design.BLACK_KEY_INK
var BLACK_HELD: Color:
	get: return Design.ACCENT.darkened(0.35)
const EDGE := Color("101216")

var first_note := 48
var octaves := 2

## note -> true, whatever pressed it. Set by the editor so keys light up for the computer
## keyboard as well as for the mouse.
var held: Dictionary = {}

## note -> the computer key that plays it, drawn on the key itself.
var key_labels: Dictionary = {}

var _mouse_note := -1


func _ready() -> void:
	custom_minimum_size.y = Design.scale(96)
	mouse_filter = Control.MOUSE_FILTER_STOP
	# Never takes focus. Taking it is the exact failure this exists to diagnose.
	focus_mode = Control.FOCUS_NONE


func set_held_notes(notes: Dictionary) -> void:
	held = notes
	queue_redraw()


func set_range(start_note: int, octave_count: int) -> void:
	first_note = start_note
	octaves = maxi(1, octave_count)
	queue_redraw()


func _white_count() -> int:
	return octaves * WHITE_OFFSETS.size()


func _white_width() -> float:
	return size.x / float(maxi(1, _white_count()))


## The note under a point, black keys first because they sit on top of the white ones.
func _note_at(point: Vector2) -> int:
	var white_width := _white_width()
	var black_width := white_width * 0.62
	var black_height := size.y * 0.62

	if point.y <= black_height:
		for octave in octaves:
			for semitone in BLACK_OFFSETS:
				var x: float = (octave * WHITE_OFFSETS.size() + float(BLACK_POSITIONS[semitone])) * white_width
				if point.x >= x - black_width * 0.5 and point.x <= x + black_width * 0.5:
					return first_note + octave * 12 + semitone

	var index := int(point.x / white_width)
	if index < 0 or index >= _white_count():
		return -1
	return first_note + (index / WHITE_OFFSETS.size()) * 12 \
		+ WHITE_OFFSETS[index % WHITE_OFFSETS.size()]


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_press(_note_at(event.position))
		else:
			_release()
		accept_event()
	elif event is InputEventMouseMotion and _mouse_note >= 0:
		# Dragging across the keys glides, which is what a piano does and what makes it
		# obvious the thing is live.
		var note := _note_at(event.position)
		if note != _mouse_note:
			_press(note)
		accept_event()


func _press(note: int) -> void:
	if note < 0:
		return
	_release()
	_mouse_note = note
	note_pressed.emit(note)


func _release() -> void:
	if _mouse_note < 0:
		return
	note_released.emit(_mouse_note)
	_mouse_note = -1


## A pointer leaving mid-press must let the note go, or it sounds forever.
func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT:
		_release()


## The sizes the letters and landmarks are drawn at. Through the type scale, so they
## follow the UI-scale setting like everything else, and floored so that setting can
## never take them under what somebody has to read mid-performance.
static func keycap_size() -> int:
	return maxi(Design.type(Design.SIZE_KEYCAP), Design.MIN_SCREEN_KEYCAP)


static func octave_size() -> int:
	return maxi(Design.type(Design.SIZE_OCTAVE), Design.MIN_SCREEN_OCTAVE)


## A held key changes in two ways, not one.
##
## It used to change colour and nothing else, which is the single cue an accessibility
## brief asks you not to rely on — and the one a colour-blind reader, a projector or a
## sunlit screen is most likely to take away. The fill still changes; a thick inset
## outline changes with it, so the state survives in greyscale.
const HELD_INSET := 3.0

func _draw() -> void:
	var font: Font = Design.font(Design.WEIGHT_SEMIBOLD)
	if font == null:
		font = get_theme_default_font()
	var white_width := _white_width()
	var keycap := keycap_size()
	var octave_text := octave_size()

	for index in _white_count():
		var note: int = first_note + (index / WHITE_OFFSETS.size()) * 12 \
			+ WHITE_OFFSETS[index % WHITE_OFFSETS.size()]
		var rect := Rect2(index * white_width, 0.0, white_width - 1.0, size.y)
		var down: bool = held.has(note)
		draw_rect(rect, WHITE_HELD if down else WHITE)
		draw_rect(rect, EDGE, false, 1.0)
		if down:
			draw_rect(Rect2(rect.position + Vector2(HELD_INSET, HELD_INSET),
				rect.size - Vector2(HELD_INSET, HELD_INSET) * 2.0),
				Design.WHITE_KEY_INK, false, HELD_INSET)
		# Every C gets a heavier boundary as well as its name: an octave you can find
		# without reading is an octave you can find while looking somewhere else.
		if note % 12 == 0:
			draw_line(rect.position, rect.position + Vector2(0.0, size.y), EDGE, 2.5)
		if font == null:
			continue
		var ink: Color = Design.WHITE_KEY_INK
		if note % 12 == 0:
			draw_string(font, rect.position + Vector2(4.0, size.y - 6.0),
				"C%d" % (note / 12 - 1), HORIZONTAL_ALIGNMENT_LEFT, -1,
					octave_text, ink)
		if key_labels.has(note):
			# The cap takes the colour of the key *as it is now*, held or not. Drawing it
			# in the resting colour left a white box sitting on a lit green key, which
			# reads as a rendering fault rather than as a keycap.
			_draw_keycap(font, key_labels[note], keycap,
				Vector2(rect.position.x + rect.size.x * 0.5,
					size.y - 12.0 - octave_text), ink,
				WHITE_HELD if down else WHITE)

	var black_width := white_width * 0.62
	var black_height := size.y * 0.62
	for octave in octaves:
		for semitone in BLACK_OFFSETS:
			var note: int = first_note + octave * 12 + semitone
			var centre: float = (octave * WHITE_OFFSETS.size() + float(BLACK_POSITIONS[semitone])) * white_width
			var rect := Rect2(centre - black_width * 0.5, 0.0, black_width, black_height)
			var down: bool = held.has(note)
			draw_rect(rect, BLACK_HELD if down else BLACK)
			draw_rect(rect, EDGE, false, 1.0)
			if down:
				draw_rect(Rect2(rect.position + Vector2(HELD_INSET, HELD_INSET),
					rect.size - Vector2(HELD_INSET, HELD_INSET) * 2.0),
					Design.BLACK_KEY_INK, false, HELD_INSET)
			if font != null and key_labels.has(note):
				_draw_keycap(font, key_labels[note], keycap,
					Vector2(rect.position.x + rect.size.x * 0.5,
						black_height - 10.0),
					Design.BLACK_KEY_INK if not down else Design.WHITE_KEY_INK,
					BLACK_HELD if down else BLACK)


## One computer-key letter, in a keycap.
##
## The outline is not decoration: it is what says "this letter is a key on your computer"
## rather than "this is the name of the note", which are two different things that were
## previously distinguished only by position and size. A shape carries that distinction
## where a colour would not survive a greyscale print or a colour-blind reader.
func _draw_keycap(font: Font, letter: String, size_px: int, centre: Vector2,
		ink: Color, behind: Color) -> void:
	var text := font.get_string_size(letter, HORIZONTAL_ALIGNMENT_LEFT, -1, size_px)
	var pad := Vector2(size_px * 0.34, size_px * 0.18)
	var box := Rect2(centre - Vector2(text.x * 0.5, font.get_ascent(size_px)) - pad,
		Vector2(text.x, font.get_ascent(size_px) + font.get_descent(size_px)) + pad * 2.0)
	# A cap the colour of the key it sits on keeps the letter's own contrast intact —
	# the outline does the separating, so nothing is drawn on a third background whose
	# pairing with the ink nobody has checked.
	draw_rect(box, behind)
	draw_rect(box, ink, false, 1.0)
	draw_string(font, centre - Vector2(text.x * 0.5, 0.0), letter,
		HORIZONTAL_ALIGNMENT_LEFT, -1, size_px, ink)
