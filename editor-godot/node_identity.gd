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

## The proving ground: the three types the node pass is being designed on. Nothing else
## takes the new anatomy until these three are approved, which is the whole point of
## having a proving ground rather than a release.
const PROVING_GROUND := ["Gain", "StateVariableFilter", "ADSR"]

## Type name -> what to call it when the room runs out.
##
## Three entries, for the three types above. The rest of the library keeps eliding until
## the anatomy is approved and rolled out, which is what the before-and-after is for.
const COMPACT := {
	"Gain": "Amp",
	"StateVariableFilter": "Filter",
	"ADSR": "Envelope",
}


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
}


## The glyph for a type, or -1 for one that has none yet. The cell is reserved either
## way: a header whose title starts in a different place depending on whether its type
## has been drawn yet is a graph that jitters as it is rolled out.
static func glyph_of(type_name: String) -> int:
	return int(GLYPH.get(type_name, -1))


## Whether this type is one of the three being designed on.
static func in_proving_ground(type_name: String) -> bool:
	return PROVING_GROUND.has(type_name)


## The compact name for a type, or "" when it has none yet.
##
## Empty rather than a guess: a type with no compact name written down has not been
## through the pass, and the honest thing is to say so and let the caller fall back to
## what it did before.
static func compact_of(type_name: String) -> String:
	return str(COMPACT.get(type_name, ""))
