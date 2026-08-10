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

## How wide a black key is against a white one. A real piano is 13.7mm on 23.5mm, which
## is 0.583; a little wider here because these carry a letter.
const BLACK_WIDTH := 0.62

## The white keys each black key sits between — which is the whole point of where it
## sits. One key is the sharp of the note below it and the flat of the note above, and it
## can only say so by straddling the join between them.
const BLACK_BETWEEN := {1: ["C", "D"], 3: ["D", "E"], 6: ["F", "G"], 8: ["G", "A"],
	10: ["A", "B"]}

## Where each black key's centre sits, in white-key widths from the octave's left edge.
##
## Derived, because the five numbers this replaces (0.7, 1.7, 3.7, 4.7, 5.7) were picked
## by hand and put every black key almost entirely *over* the white key to its left: at
## 0.62 wide, the C# at 0.7 spanned 0.39 to 1.01 and so merely touched the C|D join
## rather than crossing it. A piano's black keys cross it. That is what makes the 2-and-3
## grouping legible at a glance, and it is why a player can find F# without counting.
##
## The rule is the instrument's own: within a group of white keys — C-D-E, then F-G-A-B —
## the black keys and the narrowed white tops divide the group evenly, which leaves the
## group symmetric about its middle. Two black keys over three whites, three over four.
static func black_centres() -> Dictionary:
	var centres := {}
	for group in [{"start": 0, "whites": 3, "blacks": [1, 3]},
			{"start": 3, "whites": 4, "blacks": [6, 8, 10]}]:
		var whites: float = float(group["whites"])
		var top: float = (whites - (whites - 1.0) * BLACK_WIDTH) / whites
		var index := 0.0
		for semitone in group["blacks"]:
			centres[semitone] = float(group["start"]) + top * (index + 1.0) \
				+ BLACK_WIDTH * (index + 0.5)
			index += 1.0
	return centres

static var BLACK_POSITIONS: Dictionary = black_centres()

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
var WHITE_HELD: Color:
	get: return Design.ACCENT
var BLACK: Color:
	get: return Design.BLACK_KEY
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
	custom_minimum_size.y = Design.scale(112)
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
	var black_width := white_width * BLACK_WIDTH
	var black_height := size.y * BLACK_HEIGHT

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
	elif event is InputEventMouseMotion:
		var note := _note_at(event.position)
		# The name under the pointer, said both ways on the black keys. A key that
		# straddles the join between two white ones *is* two names for one pitch, and
		# until now the layout implied that and nothing ever said it.
		tooltip_text = note_name(note) if note >= 0 else ""
		if _mouse_note >= 0:
			# Dragging across the keys glides, which is what a piano does and what makes
			# it obvious the thing is live.
			if note != _mouse_note:
				_press(note)
			accept_event()


## What a key is called. Black keys carry both names, because they have both: the sharp
## of the white key below and the flat of the one above, which is exactly the pair the
## key is drawn across.
static func note_name(note: int) -> String:
	var octave: int = note / 12 - 1
	var semitone: int = note % 12
	if not BLACK_BETWEEN.has(semitone):
		const WHITE_NAMES := {0: "C", 2: "D", 4: "E", 5: "F", 7: "G", 9: "A", 11: "B"}
		return "%s%d" % [WHITE_NAMES[semitone], octave]
	var pair: Array = BLACK_BETWEEN[semitone]
	return "%s♯%d  ·  %s♭%d" % [pair[0], octave, pair[1], octave]


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

## How far down the black keys reach, and what is left under them.
##
## The strip below the black keys is the only full-width part of a white key, so it is
## the only place a letter can be centred without disappearing under an overhang — which
## is where they were: a 17px keycap on a 96px-tall piano had its box top at 53px against
## black keys reaching 59px, so every white key's letter was tucked behind the black key
## above it. The dock is a little taller now and the black keys a little shorter, which
## is what pays for the bigger type rather than the type simply being asked to fit.
const BLACK_HEIGHT := 0.60

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
		# The octave name sits on the floor of the key; the letter sits in the strip
		# between the black keys and that name. Both are measured from the black keys
		# rather than from the bottom, so neither can end up behind an overhang when the
		# dock is resized or the UI scale changes the type.
		var floor_y: float = size.y - 6.0
		if note % 12 == 0:
			draw_string(font, Vector2(rect.position.x + 5.0, floor_y),
				"C%d" % (note / 12 - 1), HORIZONTAL_ALIGNMENT_LEFT, -1,
					octave_text, ink)
		if key_labels.has(note):
			var strip_top: float = size.y * BLACK_HEIGHT
			var strip_bottom: float = floor_y - octave_text
			# The cap takes the colour of the key *as it is now*, held or not. Drawing it
			# in the resting colour left a white box sitting on a lit green key, which
			# reads as a rendering fault rather than as a keycap.
			_draw_keycap(font, key_labels[note], keycap,
				Vector2(rect.position.x + rect.size.x * 0.5,
					(strip_top + strip_bottom) * 0.5 + font.get_ascent(keycap) * 0.5),
				ink, WHITE_HELD if down else WHITE)

	var black_width := white_width * BLACK_WIDTH
	var black_height := size.y * BLACK_HEIGHT
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
						black_height - keycap * 0.62),
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
