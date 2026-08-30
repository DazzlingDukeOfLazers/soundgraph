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
## Applied only to `NodeIdentity.PROVING_GROUND` while the pass is being reviewed; the
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


## The gap between rows, scaled. Godot wants these as ints in theme constants.
static func row_gap() -> int:
	return Design.scale(ROW_GAP)


static func column_gap() -> int:
	return Design.scale(COLUMN_GAP)


## The height a row should stand at, by what it is carrying.
static func row_height(carries_controls: bool) -> int:
	return Design.scale(CELL_ROW if carries_controls else PORT_ROW)
