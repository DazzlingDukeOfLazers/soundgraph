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

# Off-white rather than paper.
#
# At full white the keys carried more contrast and more apparent mass than anything
# in the graph, and the eye went to the bottom of the window and stayed there. This
# is still unmistakably a piano and no longer the brightest thing on screen — the
# graph is the hero. Not dimmed into uselessness either: the held colours are the
# application accent, so what you are playing still reads instantly.
const WHITE := Color("c3c8d2")
## Live, for the same reason the scope's are: a static evaluated at class load keeps
## whatever palette was active then and ignores every switch afterwards.
var WHITE_HELD: Color:
	get: return Design.ACCENT
const BLACK := Color("1b1e24")
var BLACK_HELD: Color:
	get: return Design.ACCENT.darkened(0.35)
const EDGE := Color("101216")
const LABEL := Color("5c6371")

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


func _draw() -> void:
	# The application face, at the size the design system gives secondary text, so the
	# letters on the keys are part of the same type system as everything else rather
	# than whatever the default theme happened to supply.
	var font: Font = Design.font(Design.WEIGHT_MEDIUM)
	if font == null:
		font = get_theme_default_font()
	var white_width := _white_width()

	for index in _white_count():
		var note: int = first_note + (index / WHITE_OFFSETS.size()) * 12 \
			+ WHITE_OFFSETS[index % WHITE_OFFSETS.size()]
		var rect := Rect2(index * white_width, 0.0, white_width - 1.0, size.y)
		draw_rect(rect, WHITE_HELD if held.has(note) else WHITE)
		draw_rect(rect, EDGE, false, 1.0)
		if font == null:
			continue
		# Every C is named, so the octave is readable without counting keys.
		if note % 12 == 0:
			draw_string(font, rect.position + Vector2(4.0, size.y - 6.0),
				"C%d" % (note / 12 - 1), HORIZONTAL_ALIGNMENT_LEFT, -1,
					Design.scale(Design.SIZE_SECONDARY), LABEL)
		if key_labels.has(note):
			var letter: String = key_labels[note]
			var width := font.get_string_size(letter, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
			draw_string(font, rect.position + Vector2((rect.size.x - width) * 0.5,
				size.y - 24.0), letter, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, LABEL)

	var black_width := white_width * 0.62
	var black_height := size.y * 0.62
	for octave in octaves:
		for semitone in BLACK_OFFSETS:
			var note: int = first_note + octave * 12 + semitone
			var centre: float = (octave * WHITE_OFFSETS.size() + float(BLACK_POSITIONS[semitone])) * white_width
			var rect := Rect2(centre - black_width * 0.5, 0.0, black_width, black_height)
			draw_rect(rect, BLACK_HELD if held.has(note) else BLACK)
			draw_rect(rect, EDGE, false, 1.0)
			if font != null and key_labels.has(note):
				var letter: String = key_labels[note]
				var width := font.get_string_size(letter, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
				draw_string(font, rect.position + Vector2((rect.size.x - width) * 0.5,
					black_height - 8.0), letter, HORIZONTAL_ALIGNMENT_LEFT, -1, 12,
					WHITE if not held.has(note) else EDGE)
