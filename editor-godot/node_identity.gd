class_name NodeIdentity
extends RefCounted

## What a node is called when there is less room to say it.
##
## A node on the canvas has a name its author gave it — "Amp Envelope", "Main Oscillator"
## — and at some distance that name stops fitting the box it is written in. The editor's
## answer was to cut the name and add an ellipsis, which is how "Amplifier" became
## "Ampli…" and then "Ampl…" and eventually says nothing at all except that something has
## been taken away.
##
## So a second name, written down rather than derived. `compact` is an optical
## representation, not a nickname: it is what this kind of node is called when the label
## has to be short, chosen by somebody rather than produced by a slice.
##
## Keyed by type rather than by the name on the node, for two reasons. A person who
## renames their oscillator "Bass" still gets a compact identity, because what the node
## *is* has not changed. And an author cannot be asked to think of a short form for every
## node they name — the type already knows one.
##
## The compact name is used only when the canonical one will not fit. At every size where
## the real name fits, the real name is what is drawn.

## The types that speak the new language.
##
## It began as three — a proving ground, so that the anatomy could be designed on
## something small enough to look at properly. It is seven now, which is every node in
## First Synth: the first patch where nothing is left over from the old generation and
## the graph can be judged as a composition rather than as three islands.
##
## The last two are seams rather than ordinary types. A patch's edges are nodes like any
## other on the canvas, they are keyed by the port they stand for, and the language does
## not have an opinion about which kind of node it is dressing.
const MIGRATED := ["Gain", "StateVariableFilter", "ADSR",
	"SawOscillator", "LFO", "seam:Input/note", "seam:Output/stereo",
	# The first family batch. Three of the six candidates went in and three did not:
	# SineOscillator, SquareOscillator and OnePoleFilter measure 413, 410 and 405 at the
	# Comfortable scale against a Wide class of 376, and no class holds them. Three
	# independent types inside eight units of each other is evidence for a fourth class
	# rather than for stretching a third, and a new class is a design decision and not
	# something a migration gets to make. See docs/graph-nodes.md.
	"NoiseOscillator", "Noise", "Phaser"]

## Type name -> what to call it when the room runs out.
##
## Three entries, for the three types above. The rest of the library keeps eliding until
## the anatomy is approved and rolled out, which is what the before-and-after is for.
const COMPACT := {
	"Gain": "Amp",
	"StateVariableFilter": "Filter",
	"ADSR": "Envelope",
	# The four that finished First Synth. Two of them have none, and that is an answer
	# rather than an omission: "Keyboard" and "Output" are already the shortest true
	# names those things have, and inventing "Keys" and "Out" would be shortening for
	# its own sake. A type with no compact name simply keeps its canonical one until it
	# stops fitting, and then draws nothing — which is the step 12 rule and is right.
	"SawOscillator": "Oscillator",
	"LFO": "Sweep",
}


## The identity glyphs for the four that finished First Synth, and why each is what it is
## — see `docs/node-glyph-grammar.md` for the family rules they are built from.


## The mark on a node's header, by type.
##
## It answers "what kind of signal operation is this" before the title is read, which is
## why every one of these describes behaviour rather than equipment: a response curve
## rather than a filter, the amplifier symbol rather than an amplifier. A picture of the
## hardware would be the third time this pass has had to walk back out of a rack.
##
## Node identity and port semantics are separate systems, so these are drawn in the
## editor's own identity ink and never in a signal colour — a lowpass is not green
## because audio is green.
const GLYPH := {
	"Gain": Icons.Kind.GAIN_TRIANGLE,
	"StateVariableFilter": Icons.Kind.RESPONSE_LOW,
	"ADSR": Icons.Kind.ENVELOPE,
	# The generator family draws the waveform the node makes, so a SawOscillator wears a
	# sawtooth. That rule is what keeps this apart from the modulator below without
	# either of them needing a distinguishing decoration bolted on.
	"SawOscillator": Icons.Kind.SAW_WAVE,
	# And the control family draws the shape of a value over time. Angular against
	# smooth: the two marks differ in silhouette rather than in a detail, which is rule
	# 9, and it is where the corpus landed independently — everything filed under
	# "modulation" is a sinuous curve and everything under "sawtooth" is a ramp.
	"LFO": Icons.Kind.MODULATION,
	# A seam is the edge of the patch, so it is drawn as an edge: a bar for the boundary
	# and a line for the signal crossing it, mirrored for the direction. Not a keyboard
	# and not a speaker — a seam is not the equipment on the other side of it, and what
	# kind of signal crosses is already said by the socket.
	#
	# A keyboard was tried first and three cuts of it were drawn. All three fill in at
	# header size, and the reason is structural rather than fixable: a keyboard's
	# identity is many parallel elements and the glyph field is seven stroke widths
	# across. See `docs/node-glyph-grammar.md`.
	"seam:Input/note": Icons.Kind.ORIGINATE,
	"seam:Output/stereo": Icons.Kind.TERMINATE,
	# The generator family again, keyed by the waveform each one makes. Noise is the
	# waveform with no period, and both noise sources wear it: they are the same
	# operation and the word beside the mark is what says which.
	"NoiseOscillator": Icons.Kind.NOISE_WAVE,
	"Noise": Icons.Kind.NOISE_WAVE,
	# And the Phaser has none. Its family — things that happen over time — has not been
	# drawn, and the identity cell is reserved whether or not a type has a mark, so a
	# node with no glyph costs nothing and claims nothing. No glyph beats a misleading
	# one, and this is the first type to ship on that rule.
}


## A type may declare **one** parameter whose discrete values change what operation the
## node represents, and choose a mark for each of them.
##
## Narrow on purpose. The general rule "a glyph may depend on a parameter" would let any
## changing value drive identity, and identity would stop being identity — the whole point
## of the mark is that it says what this thing *is* while its knobs move. This says
## something smaller and true: a state-variable filter set to notch is not doing the
## operation a lowpass does, and drawing a falling curve on it is a lie the reader has no
## way to catch. It was one, until this: First Synth's filter happens to be in lowpass
## mode, which is why nobody saw it.
##
## The parameter has to be an enumeration and its options are indexes into the list. Every
## other type stays keyed by type alone unless it declares one of these.
##
## The **name** is not variant. A node stays what its author called it and what its type
## is called — `Filter` in the registry — while the glyph says which response is running
## and the dropdown says it in words. A node that renamed itself when you turned one
## control would look like it had become a different type, which it has not.
const VARIANT := {
	"StateVariableFilter": {
		"parameter": "mode",
		"glyphs": [Icons.Kind.RESPONSE_LOW, Icons.Kind.RESPONSE_HIGH,
			Icons.Kind.RESPONSE_BAND, Icons.Kind.RESPONSE_NOTCH],
	},
	"OnePoleFilter": {
		"parameter": "mode",
		"glyphs": [Icons.Kind.RESPONSE_LOW, Icons.Kind.RESPONSE_HIGH],
	},
}


## The parameter that drives this type's identity, or "" for the types that have none —
## which is nearly all of them.
static func variant_parameter(type_name: String) -> String:
	return str((VARIANT.get(type_name, {}) as Dictionary).get("parameter", ""))


## The glyph for a type, or -1 for one that has none yet. The cell is reserved either
## way: a header whose title starts in a different place depending on whether its type
## has been drawn yet is a graph that jitters as it is rolled out.
##
## `variant` is the value of the type's identity parameter, where it declares one, and is
## ignored otherwise.
static func glyph_of(type_name: String, variant: int = -1) -> int:
	if VARIANT.has(type_name) and variant >= 0:
		var marks: Array = VARIANT[type_name]["glyphs"]
		if variant < marks.size():
			return int(marks[variant])
	return int(GLYPH.get(type_name, -1))


## Whether this type speaks the new language yet.
static func migrated(type_name: String) -> bool:
	return MIGRATED.has(type_name)


## The compact name for a type, or "" when it has none yet.
##
## Empty rather than a guess: a type with no compact name written down has not been
## through the pass, and the honest thing is to say so and let the caller fall back to
## what it did before.
static func compact_of(type_name: String) -> String:
	return str(COMPACT.get(type_name, ""))
