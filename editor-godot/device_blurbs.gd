extends RefCounted
## What the add-node dialog says about each instrument on its shelves.
##
## Every device row used to introduce itself with the same sentence — "device — a
## whole patch as one node" — which is a definition, not an introduction, and two
## hundred instruments wearing one name tag is a wall. The words live here, in the
## editor, rather than in the patch files: half those files are written by importers
## whose descriptions honestly describe the import ("imported by tools/dx7-import.mjs
## from algorithm-demos.syx"), and hand-editing generated files is how generated
## files stop being generated.
##
## Curated where the instrument has a story, derived where a family shares one, and
## searchable either way: the palette matches queries against these words too, so
## "jungle" finds the Break Chopper without anybody knowing its name.


## The instruments with stories of their own.
const BY_LABEL := {
	"First Synth": "Saw, filter, envelope, LFO: the first patch, and still the "
		+ "fastest route to a real sound.",
	"Delay Echo": "Live input through a filter into a feedback delay: say something "
		+ "and the room says it back.",
	"Envelope Amp": "An ADSR and a Gain wearing one face: the four shape knobs that "
		+ "end every synth chain, as a module you can drop anywhere.",
	"Filter Envelope": "A filter and its envelope as one module: cutoff and "
		+ "resonance up top, the sweep that plays them underneath.",
	"Break Chopper": "A Sampler slicing a drum break while a sequencer lane deals "
		+ "the order. Jungle, from four nodes.",
	"Kit Chopper": "Draw drums on the roll, press Capture, and the Sampler starts "
		+ "re-cutting what you played: the kit and the chopper in one patch.",
	"Plucked String": "Karplus-Strong in the open: a burst of noise rings a tuned "
		+ "Comb the way a pick rings a string.",
	"Warehouse": "A stab in a big room: the reverb is a module of Combs and "
		+ "Allpasses, and Size and Damp arrive as signals. Play staccato.",

	"Synth: acid-bass": "A squelch bass: saw and square into a resonant filter with "
		+ "the envelope doing the talking. Add a Step Sequencer and it walks.",
	"Synth: axe": "A lead with the amp already on: saws through Drive, a phaser and "
		+ "a delay putting the hair on it.",
	"Synth: duo-lead": "Saw and square run as a pair with LFOs keeping them moving: "
		+ "a lead built on two voices travelling together.",
	"Synth: mallard": "Filters stacked three deep until the tone quacks — hence the "
		+ "name — with an Arpeggio chirp on the attack.",
	"Synth: ooops-all-rave-stabs": "Four saws and a square shouting one chord "
		+ "through Drive and a phaser: the rave stab, in every preset.",
	"Synth: poly-five": "Five voices of the classic saw-square-filter recipe: the "
		+ "patch to play chords on.",

	"Game: coin": "The pickup blip: two tones up, instantly recognisable as money.",
	"Game: explode": "Noise with a fast fall: the explosion every 8-bit game carries.",
	"Game: hurt": "A downward blip for taking damage, short enough to stay out of "
		+ "the way.",
	"Game: jump": "A rising sweep with legs under it.",
	"Game: jump2": "The jump, second opinion: same rise, different character.",
	"Game: powerup": "A rising arpeggio that says something good just happened.",
	"Game: select": "A menu tick: one tiny neutral blip.",
	"Game: shoot": "A zap with a fast pitch drop: pew, in patch form.",

	"808: kick": "A sine dropping fast into the floor: the boom that named a genre. "
		+ "Tuned to 55 Hz by its author.",
	"808: snare": "Tone plus noise: the crack in the middle of the bar.",
	"808: clap": "Noise through a fast triple envelope: hands, allegedly.",
	"808: hat-closed": "A tick of filtered noise, over immediately.",
	"808: hat-open": "The closed hat's noise, allowed to breathe.",
	"808: cymbal": "Bright filtered noise with a long tail.",
	"808: cowbell": "Two detuned squares in a tin: the cowbell that launched a "
		+ "thousand jokes.",
	"808: clave": "A tuned tick, high and woody.",
	"808: rimshot": "A woody click with a ring to it.",
	"808: conga": "A pitched blip: the 808's idea of a conga.",
	"808: tom": "A falling tone with a skin on it.",
	"808: toms": "The toms as a set, spread across pitches.",
	"808: maracas": "A short shake of high noise.",
	"808: kit": "All the 808 voices in one patch, mapped across trigger pads.",

	"909: kit": "The 909: the house cousin — snappier kick, brighter hats, the "
		+ "hi-hats that count the night in.",
	"606: kit": "The 606: thin, ticky and charming, the drum machine that fits in "
		+ "a pocket.",
	"SDS: kit": "The hex-pad kit: electronic toms that fall through the floor, "
		+ "straight off an eighties record.",
	"Gated: snare": "A big room cut off mid-bloom: the gated snare, the eighties "
		+ "in one hit.",
}

## The OPL2 bank's sixteen families, matched by name. First rule that hits wins,
## so "bassoon" must be claimed by the reeds before "bass" can claim it.
const FM_FAMILIES := [
	[["bassoon", "oboe", "clarinet", "sax", "english"],
		"A reed, as the DOS soundcard heard one"],
	[["piano", "clavi", "harpsi", "honky"], "Keys, two operators at a time"],
	[["glocken", "celesta", "music-box", "vibraphone", "marimba", "xylophone",
		"tubular", "bell", "dulcimer", "kalimba", "crystal"],
		"Something struck and ringing"],
	[["organ", "accordion", "harmonica", "bandoneon"],
		"An organ's held breath, in FM"],
	[["guitar", "ukulele"], "A guitar the size of a register"],
	[["sitar", "banjo", "shamisen", "koto", "bagpipe", "fiddle", "shanai",
		"ocarina"], "A folk instrument crossing the FM bridge"],
	[["bass"], "A bass line's whole wardrobe"],
	[["violin", "viola", "cello", "contrabass", "tremolo", "pizzicato", "harp",
		"strings", "timpani", "orchestra"], "The string section, rendered in sines"],
	[["trumpet", "trombone", "tuba", "horn", "brass"], "Brass with FM shine on it"],
	[["piccolo", "flute", "recorder", "pan-", "blown", "shakuhachi", "whistle"],
		"A pipe: breath first, note second"],
	[["choir", "voice", "vox", "aahs", "oohs"], "A voice, approximately human"],
	[["lead"], "A lead voice built to sit on top"],
	[["pad", "atmosphere", "brightness", "halo", "sweep", "warm", "polysynth",
		"bowed", "metallic", "new-age", "soundtrack", "sci-fi", "echoes", "rain",
		"goblins"], "A pad or a weather system, hard to say which"],
	[["drum", "tom", "taiko", "agogo", "woodblock", "percussion", "cymbal",
		"tinkle"], "Percussion by way of two operators"],
	[["gunshot", "applause", "helicopter", "seashore", "bird", "telephone",
		"breath", "guitar-fret"], "A sound effect the bank kept next to the music"],
]


static func blurb(label: String) -> String:
	if BY_LABEL.has(label):
		return BY_LABEL[label]
	if label.begins_with("DX7: "):
		return _dx7(label.trim_prefix("DX7: "))
	if label.begins_with("FM: "):
		return _fm(label.trim_prefix("FM: "))
	if label.begins_with("Node: "):
		return "The %s node's own demo: the node wired to be heard, with nothing " \
			% label.trim_prefix("Node: ") + "else in the way."
	return "A whole patch as one node, wired like anything else."


## The 32 wirings, introduced honestly: the number is the fact, the two ends of
## the range are the story.
static func _dx7(name: String) -> String:
	var number := int(name.trim_prefix("algo-"))
	if number == 1:
		return "A DX7 voice on algorithm 1: two stacks of three operators, the " \
			+ "workhorse wiring the factory patches lean on."
	if number == 32:
		return "A DX7 voice on algorithm 32: all six operators side by side as " \
			+ "carriers — the additive corner of the instrument."
	return ("A DX7 voice on algorithm %d: six sine operators, rewired — one of "
		+ "the 32 ways the DX7 stacks them.") % number


static func _fm(name: String) -> String:
	var lowered := name.to_lower()
	for rule: Array in FM_FAMILIES:
		for word: String in rule[0]:
			if lowered.contains(word):
				return "%s: an OPL2 FM voice from Freedoom's GENMIDI bank — the " \
					% rule[1] + "DOS soundcard speaking."
	return "An OPL2 FM voice from Freedoom's GENMIDI bank — the DOS soundcard " \
		+ "speaking."
