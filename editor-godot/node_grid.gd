class_name NodeGrid
extends RefCounted

## The spacing system inside a graph node.
##
## Every figure the inside of a node is built from, written down once. Before this they
## were spread through the builder as `Design.SPACE_M` here and a bare `0` there and a
## height that happened to be 74, and the result was what you would expect: controls that
## had each been nudged until they looked right on the node somebody was looking at, and
## two nodes that could not be said to share a layout.
##
## Everything is a multiple of eight, or of four where a gap is inside one object rather
## than between two. The exceptions are named and there are none.
##
## Applied only to `NodeIdentity.MIGRATED` while the pass is being reviewed; the
## rest of the library keeps the old figures, which is what makes the difference visible
## in one patch.

## Between the body's edge and anything inside it. The same figure the header's name is
## inset by, so the name and the first control stand on one line.
const INSET_X := 12
## Under the header's rule, before the first row.
const INSET_TOP := 8
## Under the last row, before the body's foot. A node that ends flush with its own edge
## reads as cut off rather than finished.
const INSET_BOTTOM := 8

## Between one row and the next.
const ROW_GAP := 8
## Between two controls on the same row, and between a port's label and the controls.
const COLUMN_GAP := 16
## One control column. Cells share it, so the control in the second row lands under the
## control in the first instead of wherever centring left it — which is the whole
## difference between two rows and four islands.
##
## The builder already floors a name box at 84 and caps it at 132, so 84 is the width the
## cells were standing at anyway — the column is not here to make them wider, it is here
## to make them the same. 104 was tried first and widened all three nodes by twelve to
## eighteen pixels, which is a width class arriving early in a step that is about spacing.
const COLUMN := 84

## The port gutters are equal within a node and measured from that node's own longest
## port label — a rule rather than a number, because both halves of it matter.
##
## Equal, because this is what was actually wrong with the Lowpass: the controls sat in a
## box that expands to fill, centred between two labels of different lengths, so "mod" on
## one row and "cutoff Hz" on the next moved the whole control block sideways and two tidy
## rows read as four islands. Equal gutters give the control region one left edge and one
## right edge on every row.
##
## Measured per node, because a fixed figure is a width class in disguise. Eighty-eight
## pixels was tried, and the Amplifier — two short port names and one knob — went from 219
## to 314 to hold two gutters sized for a node it is not.

## Inside one cell: control to its name.
const LABEL_GAP := 4
## Inside one cell: name to its value. One micro unit today, the same as LABEL_GAP —
## its own name because step 5 is where the two may want to differ, and a token that
## does not exist cannot be changed.
const VALUE_GAP := 4

## A row carrying controls, and a row carrying only ports. Both on the eight, where the
## first was 74 and the second 28 — near enough to the rhythm to look deliberate and far
## enough off it to stop every row below them landing on the grid.
const CELL_ROW := 72
const PORT_ROW := 24


## What a node is allowed to let one port label do to its width. The Lowpass's longest
## gutter is 74 at base scale, so this does not bind today; it is here so that the first
## node with a genuinely long port name is clipped and recorded rather than dragging the
## whole system wider. A compact-label policy is a later question and this is the ceiling
## that keeps it from being answered by accident.
const PORT_GUTTER_MAX := 96

## The width classes, derived from the three specimens rather than chosen for them.
##
## Measured under the frozen step 3-7 language, at base scale: Gain stands at 170, ADSR at
## 294, StateVariableFilter at 368. The classes are those figures rounded up onto the
## eight, which is what the rest of the node is built on — 176, 296, 376. They are not
## equal increments and there is no reason they should be: a class exists to give the
## graph a rhythm of a few repeated widths, not to make a table of round numbers.
##
## There is no fourth class yet. One arrives when a node earns it, measured the same way.
##
## ## What the figure measures
##
## The **outer footprint** of the node in graph space, at base interface scale: the whole
## box a reader sees and a cable lands on, border and content margins included, before
## `Design.scale()` multiplies it by the interface scale. So a Standard node at XL stands
## at 400 real pixels and there is nothing else to add or subtract.
##
## ## And it is a width, not a minimum
##
## A declared class is the width the node is drawn at, full stop. That has to be said
## because Godot cannot say it: a `custom_minimum_size` only ever pushes a Control wider
## and nothing pulls one back down, so a node whose child asked for an extra pixel during
## construction and then settled stood a pixel over its class for good — the Output seam
## at 401 against a class of 400, while its own combined minimum agreed with the class the
## whole time. The width is therefore set as well as floored, once the tree has settled.
##
## One pixel does not matter. The invariant does: fifty more types would reintroduce
## emergent widths one pixel at a time, and a class system whose members are approximately
## their class is a set of suggestions.
##
## If a node's contents genuinely will not fit its class, Godot pushes it back out and
## `editor_test.gd` reports the node and the overflow. That is evidence for another class
## or another layout policy — a design question, raised rather than absorbed.
## ## Two rungs added from the inventory
##
## The class set was three specimens, then four types, and is now answerable from fifty.
## `inventory.gd` measured the narrowest valid width of every runtime type and two gaps
## in the ladder turned out to be real.
##
## **208**, from a three-type cluster in the widest hole there was: Trigger Bus at 184,
## Stereo Level at 192 and Sample & Hold at 200, every one of them paying about a hundred
## units of slack to sit in Standard. A hundred and twenty units between Narrow and
## Standard was the largest gap in the ladder and three types were sitting in it.
##
## **448**, from Arpeggio at 432 and Slide at 440 — eight units apart, both blocked by the
## same upper edge of Extra and by nothing else. Two types is thinner evidence than the
## three that earned Extra, and these two agree to within one grid unit and are otherwise
## finished, which is the difference between a cluster and a coincidence.
##
## Narrow, Standard, Wide and Extra were left alone. The histogram shows the lower two
## sitting on real peaks and the upper two cutting a flat continuum from 320 to 439 — but
## a class does not have to be a statistical mode. Its job is to give the graph a few
## repeatable footprints with tolerable slack, and those two are doing it.
enum Width { NARROW, SNUG, STANDARD, WIDE, EXTRA, BROAD }
const WIDTHS := [176, 208, 296, 376, 416, 448]

## Written once so the harnesses cannot drift from the ladder they are reporting on.
const CLASS_NAMES := ["Narrow", "Snug", "Standard", "Wide", "Extra", "Broad"]

## Which class a type belongs to. Metadata, decided here — a width that emerges from
## whatever minimum sizes the controls happened to ask for is not a class, it is an
## accident with a name.
## Measured, then rounded up to the smallest class that holds them. The four that
## finished First Synth all fitted classes that already existed, which is the first real
## evidence that three is enough — a class system whose first four arrivals each need a
## new class is not a class system.
##
## [codeblock]
## type                  natural   class
## SawOscillator           253     Standard
## LFO                     326     Wide
## seam:Input/note         350     Wide
## seam:Output/stereo      286     Wide      -- and this one is the interesting case
## [/codeblock]
##
## The Output seam measures 286 at XL, which is comfortably inside Standard, and it is
## Wide anyway. At the Comfortable interface scale its contents want 299 against a class
## of 296 — it fits at one scale and not at another, and the gate caught it.
##
## **A class has to be decided at a type's worst interface scale, not at whichever one
## somebody measured at.** The class figure scales linearly and the content does not: type
## sizes stop shrinking at `Design.TYPE_FLOOR`, so at the smaller scales the words inside
## a node are relatively larger than the box around them. Comfortable and Small are
## usually the binding cases, and XL — the scale every acceptance in this pass has been
## judged at — is usually the most forgiving.
##
## The other thing that says: **Standard has almost no headroom.** It was derived from one
## specimen, the ADSR at 294, and rounded to 296. The very next type to arrive wanted 299.
## A batch that puts several types in the 296-to-330 range is evidence to re-derive it
## rather than to keep sending them all to Wide.
##
## ## The fourth class the first batch asked for
##
## Wide has the same problem and the evidence arrived immediately. Measured at Comfortable:
##
## [codeblock]
## Noise                 290     Standard
## Phaser                326     Wide
## NoiseOscillator       354     Wide
## OnePoleFilter         405     -- no class holds it
## SquareOscillator      410     -- no class holds it
## SineOscillator        413     -- no class holds it
## [/codeblock]
##
## Three independent types inside eight units of each other, all just past Wide. That is
## the cluster that earns a class rather than one node being awkward, and rounded up onto
## the eight it is **416** — `Width.EXTRA`, added on that evidence and named plainly,
## because the useful thing is the metric and the assignment rather than a taxonomy.
##
## Which is the rule the class set is grown by, now that it has been grown once:
##
## > Classes are discovered from clusters of actual requirement across the corpus, not
## > chosen in advance and not stretched to fit one awkward node.
##
## ## And how a type is assigned to one
##
## > Assign the smallest class at which the node is still **valid** in FULL detail, at its
## > worst interface scale.
##
## Valid, not preferred. `width_sheet.gd` forces a node to each class in turn and asks
## whether anything actually broke — a refused width, a clipped label, a child reaching
## outside its node, two controls overlapping on a row, a body that reflowed and grew
## taller. The first class that survives is the class.
##
## The distinction is not academic and it cost a day. The old harness measured how wide a
## node makes itself when nothing constrains it and reported the state-variable filter
## wanting 411 against a Wide class of 376; the live editor showed the same node sitting
## at 376 and looking correct. Both numbers were real and **neither was the answer**. 411
## was a preference — a container asking for its most comfortable arrangement. 376 was
## only "Godot did not push it back out", which is not the same as laid out correctly. The
## forced-width validator says the requirement is 416, which is what it now has.
##
## Natural width is still reported, as diagnosis. It is not the selector.
##
## Sending three types to a class 130 units wider than they need, to preserve a set
## inferred from three initial specimens, would be the tail wagging the dog.
const WIDTH_CLASS := {
	"Gain": Width.NARROW,
	"ADSR": Width.STANDARD,
	"SawOscillator": Width.STANDARD,
	# Extra rather than Wide. It was assigned from an XL measurement, where it stands at
	# 368; at Comfortable its contents need 416 and the forced-width harness refuses 376.
	# XL is the most forgiving scale and every early assignment was made there.
	"StateVariableFilter": Width.EXTRA,
	"seam:Output/stereo": Width.WIDE,
	"LFO": Width.WIDE,
	"seam:Input/note": Width.WIDE,
	# The first family batch, measured at Comfortable because that is the binding scale.
	"Noise": Width.STANDARD,
	"Phaser": Width.WIDE,
	"NoiseOscillator": Width.WIDE,
	# 14C, measured at Comfortable. Four of the seven landed in the class the previous
	# batch's evidence created, which is the first sign it was the right rung: Clock at
	# 388, OnePoleFilter at 405, SquareOscillator at 410 and SineOscillator at 413.
	"Constant": Width.NARROW,
	"StepSequencer": Width.WIDE,
	"Clock": Width.EXTRA,
	"OnePoleFilter": Width.EXTRA,
	"SquareOscillator": Width.EXTRA,
	"SineOscillator": Width.EXTRA,
	# 14D, by the forced-width validator: the smallest class each is still valid at, at
	# its worst interface scale. Every one of them fitted a class that already existed.
	"Add": Width.NARROW,
	"Multiply": Width.NARROW,
	"Level": Width.NARROW,
	"Mixer": Width.STANDARD,
	# 14E, by the validator. Nothing here needed a class that did not exist either.
	"Allpass": Width.STANDARD,
	"Formant": Width.STANDARD,
	"Delay": Width.WIDE,
	"Comb": Width.WIDE,
	# 14F, by the validator.
	"Compare": Width.NARROW,
	"Abs": Width.NARROW,
	"Clip": Width.STANDARD,
	"MinMax": Width.WIDE,
	# 14G, by the validator.
	"AudioInput": Width.NARROW,
	"CableTest": Width.NARROW,
	"PluginInstrument": Width.STANDARD,
	"Sampler": Width.WIDE,
	"Speech": Width.WIDE,
	"PluginEffect": Width.WIDE,
	# 14H.1, by the validator.
	"Drive": Width.NARROW,
	"Crush": Width.STANDARD,
	"AhdEnvelope": Width.STANDARD,
	"Compressor": Width.WIDE,
	# 14H.2, by the validator. Arpeggio and Scale Quantizer are absent on purpose: no
	# class holds them, they are a hundred and fifty units apart, and two outliers are
	# not a cluster.
	"MidiCC": Width.STANDARD,
	"NoteTriggers": Width.STANDARD,
	"Retrigger": Width.WIDE,
	"Euclid": Width.WIDE,
	# 15A.1. The Snug cluster the inventory found, and a fourth member measured after it:
	# Trigger Bus 184, Stereo Level 192, Sample & Hold 200, the audio input seam 195.
	"TriggerBus": Width.SNUG,
	"StereoLevel": Width.SNUG,
	"SampleHold": Width.SNUG,
	"seam:Input/audio": Width.SNUG,
	# The bare registry keys for terminals whose seam forms were already migrated.
	"StereoOutput": Width.STANDARD,
	"NoteInput": Width.WIDE,
	# And the two that were only ever waiting on the rung above Extra.
	"Arpeggio": Width.BROAD,
	"Slide": Width.BROAD,
}


## Set by `width_sheet.gd` while it measures, and by nothing else.
##
## A classed node cannot be measured: its width is pinned to its class, so reading it back
## reports the class. And the other obvious reading — emptying the minimum and asking for
## the combined minimum — measures how far the contents can be *squeezed*, which is a
## different and useless number. What a type actually wants is the width it settles at
## when no class is imposed, so the harness suppresses the classes and rebuilds.
##
## A measurement hook rather than a feature. Nothing in the editor sets it.
static var measuring := false


## The width a type stands at, scaled, or 0 for a type with no class yet.
##
## Scaled up and never down, which is the same rule `Design.screen_minimum` already uses
## and for the same reason. A class figure multiplied by 0.875 hands a Wide node 329 real
## pixels instead of 376, while the text inside it barely shrinks at all — `Design.type`
## floors every size at `TYPE_FLOOR`, so at the Compact interface scale the words are
## relatively *larger* than the box around them. The forced-width harness found five types
## that fit no class at all at Compact and fit perfectly at every other scale, which is
## not five awkward types; it is a box being shrunk out from under its own contents.
##
## A class is a width in base units. A reader who asks for smaller interface text is not
## asking for narrower nodes.
static func width_for(type_name: String) -> int:
	if measuring or not WIDTH_CLASS.has(type_name):
		return 0
	return scaled(int(WIDTHS[int(WIDTH_CLASS[type_name])]))


## A class figure in real pixels: up with the interface scale, never down. Shared with
## `width_sheet.gd` so the harness tests the widths the editor actually uses.
static func scaled(base: int) -> int:
	return int(roundf(float(base) * maxf(1.0, Design.SCALE_FACTORS[Design.ui_scale])))


## What a class is called, for the record and for anything that reports on it.
static func width_class_name(type_name: String) -> String:
	if not WIDTH_CLASS.has(type_name):
		return ""
	return CLASS_NAMES[int(WIDTH_CLASS[type_name])]


## What a control puts around its own text: the padded panel `_dress_option` gives it on
## both sides, plus the caret and the gap before it. Measured against the tokens those are
## actually built from rather than guessed, so the two cannot drift.
static func control_chrome() -> float:
	return float(Design.scale(Design.SPACE_M) * 2 + Design.scale(14)
		+ Design.scale(Design.SPACE_S))


## Whether a parameter's control needs more room than one standard column can give it.
##
## The general rule, and the one thing the packing loop asks:
##
## > A parameter whose control cannot validly inhabit one standard column spans the full
## > control region for its row.
##
## Not keyed to a type, a node, a parameter name or a class of Control. It asks the
## descriptor how wide the widest thing the control will ever show is — which for an
## enumeration is its longest option and for everything else is a number — and measures
## that string in the font the control draws it in.
##
## The Scale Quantizer is what found it. Its scale parameter is an enumeration whose
## longest option is "minor pentatonic", so its dropdown wants 224 where a column is 84;
## the root note beside it wants 90; and the two of them on one line made the node 530
## wide. The node was never big. It had one control two and a half columns across, and
## the chassis was paying for it.
static func spans(descriptor: Dictionary) -> bool:
	# Only a control whose width is driven by its *content* can exceed a column, and
	# today that means an enumeration. A knob is a dial of a fixed diameter and a value
	# written under it; it fits a column by construction and always did.
	#
	# The first version of this asked the question of every parameter and charged all of
	# them the dropdown's chrome — two paddings, a caret and its gap, which is well over
	# half a column on its own. Thirty-two of the fifty-one types reflowed to one
	# parameter a row, every node in the program got narrower and taller, and the fix for
	# one node had quietly become a redesign of all of them.
	if not descriptor.has("enum"):
		return false
	var widest := ValueText.widest(descriptor, false)
	if widest == "":
		return false
	# Predicted, and the prediction is the weak part of this. A dressed OptionButton's
	# real minimum for "minor pentatonic" is 224; the estimate below says 168. Godot adds
	# internals to a Button that the styleboxes do not describe, and the gap is a third.
	#
	# The criterion is supposed to be the control's *measured* requirement, which means
	# the packing loop has to build its cells before it groups them into rows rather than
	# deciding the rows first. That is a restructure of the row builder and it is not
	# smuggled in at the end of a width change. Until then the threshold is set where the
	# estimate is safe rather than where it is right, and Scale Quantizer stays held.
	var face := Design.font(Design.WEIGHT_MEDIUM)
	var wanted := face.get_string_size(widest, HORIZONTAL_ALIGNMENT_LEFT, -1.0,
		Design.type(Design.SIZE_CONTROL)).x + control_chrome()
	# Two columns, not one, and the second attempt at this figure.
	#
	# A column is the *minimum* a cell may be, not what one gets: on a real node the two
	# cells share the control region and are far wider than 84. Measured against a bare
	# column the threshold landed absurdly low — a dropdown's own chrome is over half a
	# column, so almost any option word cleared it, six types reflowed and two shipped
	# example patches ended up with overlapping nodes because their nodes had each gained
	# a row.
	#
	# What the rule is actually for is a control that cannot share a row with anything,
	# and that is one wanting more than the whole of a two-cell region's fair half. Under
	# it, "minor pentatonic" at 224 spans and "lowpass" at about a hundred does not —
	# which is the distinction the Scale Quantizer showed and the one worth drawing.
	return wanted > float(Design.scale(COLUMN)) * 2.0


## The gap between rows, scaled. Godot wants these as ints in theme constants.
static func row_gap() -> int:
	return Design.scale(ROW_GAP)


static func column_gap() -> int:
	return Design.scale(COLUMN_GAP)


## The height a row should stand at, by what it is carrying.
static func row_height(carries_controls: bool) -> int:
	return Design.scale(CELL_ROW if carries_controls else PORT_ROW)
