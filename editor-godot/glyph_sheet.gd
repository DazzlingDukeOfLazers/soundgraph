extends SceneTree

## Step 10's proof sheet: does the icon grammar produce families, or one-off pictures?
##
## Renders every identity glyph at the four sizes that matter, straight out of
## `Icons.get_icon` so the sheet cannot drift from what a node header actually draws — the
## step 1 baseline learned that lesson by reimplementing an elision and reporting changes
## in nodes nothing had touched.
##
## One PNG per mark per size, on the header's own surface in the header's own ink, because
## a glyph judged on white is judged in a place it will never be seen. The contact sheet is
## assembled from these afterwards; this script's job is to be the renderer, not the
## typesetter.
##
##   godot --headless --path editor-godot --script glyph_sheet.gd
##
## with GLYPH_SHEET_OUT naming a directory.

## Master, then the three sizes a node header goes through. `Design.scale(18)` is the
## identity cell at XL, which is 24 — the tightest interface scale and the one every
## acceptance in this pass has been measured at. The other two are that cell at the zooms
## the detail bands change on.
##
## 40% is below where the glyph actually survives: the title falls to the compensation
## overlay at 66% and the mark stands down with it, so nothing draws a 10px glyph today.
## It is on the sheet anyway, because "the mark would be unreadable there" is the claim
## that rule 7 rests on and a claim like that should be looked at rather than assumed.
const SIZES := [96, 24, 16, 10]

## The two families being proved, and the three approved specimens they have to sit beside
## without looking like a different set.
const SPECIMENS := ["GAIN_TRIANGLE", "RESPONSE_LOW", "ENVELOPE"]
const FILTERS := ["RESPONSE_LOW", "RESPONSE_HIGH", "RESPONSE_BAND", "RESPONSE_NOTCH"]
const ROUTING := ["ROUTE_SPLIT", "ROUTE_MERGE", "ROUTE_SWITCH"]

## The four that finished First Synth, shown beside the three they have to sit with. The
## pair to look at is the sawtooth against the modulation wave: two signal generators, one
## angular and one smooth, and the whole question is whether that reads at header size.
const FIRST_SYNTH := ["SAW_WAVE", "MODULATION", "ORIGINATE", "TERMINATE"]

## The generator family, and the pair the rollout has to settle: a sine oscillator and a
## modulation wave are both a sine, and the only thing between them is that one repeats.
const GENERATORS := ["SINE_WAVE", "SQUARE_WAVE", "SAW_WAVE", "NOISE_WAVE", "MODULATION"]

## The temporal family, which is the same question asked of control rather than of audio.
## The pairs to look at: the clock against the noise bars, which differ by regularity, and
## the held staircase against the sequencer's steps, which differ by whether the risers
## are drawn.
const TEMPORAL := ["PULSE_TRAIN", "HELD", "STEPS_ORDERED", "SLIDE", "FLAT", "ENVELOPE"]

## Where signals meet, against the routing marks they have to be told apart from — and
## against the dismiss cross, because a node wearing a close button is a node somebody
## will try to close.
const COMBINING := ["ROUTE_MERGE", "ROUTE_SPLIT", "SUM_JUNCTION", "PRODUCT",
	"GAIN_TRIANGLE", "CROSS"]

## Time and response shapes, each against the mark it is most likely to be confused with.
## Delay against the clock it is a decaying version of and the staircase it is not; comb
## against the square and the sequencer; formant against the single bandpass peak.
const EFFECTS := ["ECHO_TRAIN", "PULSE_TRAIN", "HELD", "RESPONSE_COMB", "SQUARE_WAVE",
	"STEPS_ORDERED", "RESPONSE_FORMANT", "RESPONSE_BAND", "FLAT"]

## The maths candidates, each against the chrome and the response shape it is most likely
## to be mistaken for. The chrome rows are the point: a mathematically correct symbol that
## looks like an application command is not acceptable, whatever it means.
const MATHS := ["CLIP_CURVE", "RESPONSE_HIGH", "SLIDE", "RECTIFIED", "RESPONSE_NOTCH",
	"THRESHOLD", "CROSS", "ARROW_RIGHT", "EXTREMUM_HIGH", "EXTREMUM_LOW",
	"CHEVRON_RIGHT", "TICK"]

## The specialty batch's one candidate, against the two marks it could be mistaken for:
## the transport's pause, which is also a pair of uprights, and the sine it contains.
const SPECIALTY := ["SAMPLE", "PAUSE", "SINE_WAVE", "ORIGINATE"]

## The dynamics candidates against what they could be mistaken for: the compressor's
## narrowing bounds against the chevron and the funnel it must not become, and the
## crusher's regular staircase against the sample-and-hold's irregular one.
const DYNAMICS := ["NARROWING", "CHEVRON_RIGHT", "FUNNEL", "QUANTISED", "HELD",
	"STEPS_ORDERED", "CLIP_CURVE", "SQUARE_WAVE", "ENVELOPE"]

## The two doubtful candidates from the event batch, each against the mark it is nearest.
const EVENTS := ["ONE_STEP", "SQUARE_WAVE", "HELD", "SPREAD", "PULSE_TRAIN",
	"ECHO_TRAIN"]

## The contact sheet's own geometry. Every mark is shown at the same drawn size whatever
## it was rendered at, which is the only way four sizes can be compared: the 10-pixel cut
## and the 96-pixel one differ in how they are drawn, not in how big they are on the page.
const MAGNIFY := 3
const PAD := 16


func out_dir() -> String:
	var asked := OS.get_environment("GLYPH_SHEET_OUT")
	return asked if asked != "" else ProjectSettings.globalize_path("res://")


func _initialize() -> void:
	Design.use_palette(Design.Palette.LAB)
	Design.ui_scale = Design.Scale.XL
	var ground: Color = Design.SURFACES[Design.Surface.RAISED]
	var ink: Color = Design.INK_SECOND
	var folder := out_dir()
	DirAccess.make_dir_recursive_absolute(folder)

	var names: Array = []
	for group: Array in [EVENTS, DYNAMICS, SPECIALTY, MATHS, EFFECTS, COMBINING, GENERATORS, TEMPORAL, SPECIMENS,
			FIRST_SYNTH, FILTERS, ROUTING]:
		for one: String in group:
			if not names.has(one):
				names.append(one)

	var written := 0
	for one: String in names:
		var kind: int = Icons.Kind[one]
		for size: int in SIZES:
			# The glyph over the surface it is drawn on, flattened, so what lands on disk
			# is what the eye gets rather than ink on a checkerboard.
			var plate := Image.create(size, size, false, Image.FORMAT_RGBA8)
			plate.fill(ground)
			var mark: Image = Icons.get_icon(kind, size, ink).get_image()
			mark.convert(Image.FORMAT_RGBA8)
			plate.blend_rect(mark, Rect2i(0, 0, size, size), Vector2i.ZERO)
			plate.save_png("%s/glyph-%s-%d.png" % [folder, one.to_lower(), size])
			written += 1

	# And the contact sheet itself, so the proof is one file and reproducible from this
	# repository rather than assembled by hand somewhere else. No labels: the row order is
	# the order above and it is written down in docs/node-glyph-grammar.md, where a reader
	# who needs the names is already standing.
	var cell := SIZES[0] * MAGNIFY + PAD
	var sheet := Image.create(SIZES.size() * cell + PAD,
		names.size() * cell + PAD, false, Image.FORMAT_RGBA8)
	sheet.fill(Design.SURFACES[Design.Surface.CANVAS])
	for row in names.size():
		for column in SIZES.size():
			var size: int = SIZES[column]
			# Nearest neighbour, on purpose. A 10-pixel mark shown at 10 pixels cannot be
			# judged and a smoothed one is a picture of a different glyph; magnifying the
			# pixels is how small type has always been proofed.
			var step: int = int(float(SIZES[0]) * MAGNIFY / float(size))
			var plate := Image.create(size, size, false, Image.FORMAT_RGBA8)
			plate.fill(ground)
			var mark: Image = Icons.get_icon(int(Icons.Kind[names[row]]), size,
				ink).get_image()
			mark.convert(Image.FORMAT_RGBA8)
			plate.blend_rect(mark, Rect2i(0, 0, size, size), Vector2i.ZERO)
			var drawn := size * step
			plate.resize(drawn, drawn, Image.INTERPOLATE_NEAREST)
			var corner := Vector2i(PAD + column * cell + (cell - PAD - drawn) / 2,
				PAD + row * cell + (cell - PAD - drawn) / 2)
			sheet.blit_rect(plate, Rect2i(0, 0, drawn, drawn), corner)
	sheet.save_png("%s/glyph-proof.png" % folder)

	print("%d marks, %d sizes, %d files + the sheet -> %s" % [names.size(), SIZES.size(),
		written, folder])
	quit()
