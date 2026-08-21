extends Control
## A sliver of piano standing on end, beside the roll when the roll lies flat.
##
## The vertical orientation needs no pitch reference — its lanes stand directly on
## the keys that play them. Lying flat the roll loses that alignment, so this gutter
## restores it: the same key layout the roll borrows, turned on end with the low
## notes at the bottom, and every C named, because C is where a reading eye finds
## its feet on any keyboard.

## The keyboard whose range and layout this mirrors, same as the roll's own.
var keyboard: Control


func _ready() -> void:
	custom_minimum_size.x = Design.scale(34)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


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
		draw_rect(rect, Design.WHITE_KEY)
		draw_rect(rect, Keyboard.EDGE, false, 1.0)
		if note % 12 == 0:
			# The heavier boundary every C carries on the playing keyboard, plus
			# its name — on the right, clear of the black keys' overhang.
			draw_line(rect.position + Vector2(0.0, rect.size.y),
				rect.end, Keyboard.EDGE, 2.5)
			if font != null:
				# On the white key's tail — the left half, which the black keys'
				# reach never enters, so the name always sits on clean ivory.
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
		draw_rect(rect, Design.BLACK_KEY)
		draw_rect(rect, Keyboard.EDGE, false, 1.0)
