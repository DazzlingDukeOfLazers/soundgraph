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
enum Width { NARROW, STANDARD, WIDE }
const WIDTHS := [176, 296, 376]

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
## the eight the figure would be **416**. It is not added here, because a new class is a
## design decision and a migration does not get to make one — the three types are held out
## of `NodeIdentity.MIGRATED` until it is taken.
const WIDTH_CLASS := {
	"Gain": Width.NARROW,
	"ADSR": Width.STANDARD,
	"SawOscillator": Width.STANDARD,
	"StateVariableFilter": Width.WIDE,
	"seam:Output/stereo": Width.WIDE,
	"LFO": Width.WIDE,
	"seam:Input/note": Width.WIDE,
	# The first family batch, measured at Comfortable because that is the binding scale.
	"Noise": Width.STANDARD,
	"Phaser": Width.WIDE,
	"NoiseOscillator": Width.WIDE,
}


## The width a type stands at, scaled, or 0 for a type with no class yet.
static func width_for(type_name: String) -> int:
	if not WIDTH_CLASS.has(type_name):
		return 0
	return Design.scale(WIDTHS[int(WIDTH_CLASS[type_name])])


## What a class is called, for the record and for anything that reports on it.
static func width_class_name(type_name: String) -> String:
	if not WIDTH_CLASS.has(type_name):
		return ""
	return ["Narrow", "Standard", "Wide"][int(WIDTH_CLASS[type_name])]


## The gap between rows, scaled. Godot wants these as ints in theme constants.
static func row_gap() -> int:
	return Design.scale(ROW_GAP)


static func column_gap() -> int:
	return Design.scale(COLUMN_GAP)


## The height a row should stand at, by what it is carrying.
static func row_height(carries_controls: bool) -> int:
	return Design.scale(CELL_ROW if carries_controls else PORT_ROW)
