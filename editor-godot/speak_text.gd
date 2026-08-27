# Turning what somebody typed into something the roll can play.
#
# Every nonsense-speech effect in games is this function and a synthesiser. Animal
# Crossing plays a letter's sound; Undertale plays one blip a character; Banjo-Kazooie
# plays recorded fragments. What they share is not the voice, it is the *mapping* — text
# to a rhythm and a pitch — and that is the part worth writing carefully, because a good
# mapping through a rough voice reads as speech and a random rhythm through a perfect
# voice never does.
#
# Deliberately a pure function on a plain dictionary. No engine, no nodes, no editor: it
# takes a string and returns a sequence, which means the interesting half can be tested
# without a sound card and argued about without running anything.
#
# The output is a patch's `sequence` — the same one the piano roll draws and the same one
# Play walks — so speech arrives as notes somebody can see, nudge, delete and capture,
# rather than as a hidden path that only plays.
extends RefCounted

## Steps per beat for spoken text. Sixty-fourths at 120 puts a syllable every 31 ms, and
## the gaps below stretch that to a speaking rhythm; anything coarser cannot hold the
## difference between a syllable and a pause.
const DIVISION := 16
const TEMPO := 120.0

## How long each thing takes, in steps. Speech is mostly regular with the punctuation
## doing the phrasing, which is why the pauses are so much longer than the syllables.
const SYLLABLE_STEPS := 3
const WORD_GAP := 3
const COMMA_GAP := 7
const SENTENCE_GAP := 12

## A minor pentatonic, in semitones. Letters land on scale degrees rather than on raw
## semitones because a random walk through a scale sounds like a voice with a mood and a
## random walk through the chromatic set sounds like a fault.
const SCALE := [0, 3, 5, 7, 10]

## How far the voice moves across a sentence, in semitones. Speech drifts: a statement
## sags towards its full stop and a question climbs to its mark. Without this every
## sentence lands on the same note and the result reads as a list being recited.
const CONTOUR := 5.0


## Text in, a patch `sequence` out.
##
## `base` is the note a mid-range letter lands on; the caller picks it so that one voice
## can be a mouse and another a giant without this function knowing what either is.
##
## `max_steps` is the roll's ceiling. Text is unbounded and the roll is not, so somebody
## pasting three paragraphs has to be told what fitted rather than quietly given the
## first third of it — the count comes back as `dropped`, the same bargain the MIDI
## reader strikes with a tune too long to hold.
static func to_sequence(text: String, base: int = 60, max_steps: int = 2048) -> Dictionary:
	var notes: Array = []
	var step := 0
	var dropped := 0
	# Room for the note itself and the tail below it.
	var ceiling := maxi(max_steps - 4, 8)

	for sentence in _sentences(text):
		var body: String = sentence["text"]
		var ending: String = sentence["ending"]
		# Where in this sentence each syllable falls, 0 to 1, so the contour can be
		# drawn across it rather than across the whole paragraph.
		var speakable := _speakable_count(body)
		var spoken := 0

		for i in body.length():
			var c := body[i].to_lower()
			if c == " ":
				step += WORD_GAP
				continue
			if c == ",":
				step += COMMA_GAP
				continue
			if not _is_speakable(c):
				continue
			if step >= ceiling:
				dropped += 1
				spoken += 1
				continue

			var through := float(spoken) / maxf(1.0, float(speakable - 1))
			notes.append({
				"step": step,
				"note": _pitch(c, base, through, ending),
				"length": 1,
			})
			step += SYLLABLE_STEPS
			spoken += 1

		step += SENTENCE_GAP

	return {
		"tempo": TEMPO,
		"division": DIVISION,
		# A step of tail, so the last syllable is not clipped by the loop coming round.
		"steps": clampi(step + 4, 8, max_steps),
		"notes": notes,
		"dropped": dropped,
	}


## The pitch one letter takes.
##
## Two halves added together: which letter it is, and where in the sentence it sits. The
## letter gives the voice its jitter — the same word says the same thing twice, which is
## what stops it sounding random — and the contour gives the sentence its shape.
static func _pitch(c: String, base: int, through: float, ending: String) -> int:
	var index := c.unicode_at(0) - 97   # "a"
	if index < 0 or index > 25:
		index = 0
	var degree: int = SCALE[index % SCALE.size()]
	var octave: int = (index / SCALE.size()) % 2      # letters late in the alphabet sit higher
	var contour := 0.0
	match ending:
		"?":
			# A question climbs, and climbs most at the end.
			contour = CONTOUR * through
		"!":
			# An exclamation starts high and stays there.
			contour = CONTOUR * 0.8
		_:
			# A statement sags.
			contour = -CONTOUR * through
	return base + degree + octave * 12 + int(round(contour))


## Splits text into sentences, keeping the mark that ends each one, because the mark is
## what decides the shape of the whole line.
static func _sentences(text: String) -> Array:
	var out: Array = []
	var current := ""
	for i in text.length():
		var c := text[i]
		if c == "." or c == "?" or c == "!":
			out.append({"text": current, "ending": c})
			current = ""
		else:
			current += c
	if current.strip_edges() != "":
		out.append({"text": current, "ending": "."})
	return out


static func _is_speakable(c: String) -> bool:
	return c >= "a" and c <= "z"


static func _speakable_count(text: String) -> int:
	var n := 0
	for i in text.length():
		if _is_speakable(text[i].to_lower()):
			n += 1
	return n
