class_name NodeState
extends RefCounted

## What a graph node looks like when something is true about it.
##
## A node can be under the pointer, selected, invalid and passing signal all at once, and
## a reader has to be able to answer each of those separately. The way that fails is
## always the same: two states reach for the same channel, the louder one wins, and the
## quieter fact stops existing. So the channels are assigned here, once, and each state
## owns exactly one.
##
## [codeblock]
## perimeter colour and weight   selection
## header surface and mark       validity
## body and perimeter value      hover
## port glow                     activity, and it is already there
## the identity glyph            activity, only where activity has stages
## [/codeblock]
##
## Read that as five separate answers rather than five decorations. A selected node has a
## mint edge whether or not it is also broken; a broken node has a warm header whether or
## not it is also selected; a hovered node is a shade lighter than it was whether or not
## it is also either.
##
## The one place a channel is shared is the perimeter, where selection outranks hover.
## That is forced rather than chosen: GraphNode draws a selected node from its `_selected`
## styleboxes and never consults the ordinary ones, so a hover border there would not draw
## at all. The lift still happens, so a selected node under the pointer is not the same
## picture as a selected node beside it.
##
## ## What is deliberately absent
##
## **A node-level connected state.** Step 7 gave connection to the individual port, and
## that is where it belongs: a node with one cable in and five empty sockets is not
## "connected", it is a node with one cable in. Rolling six facts up into one adjective
## loses all six.
##
## **Node-wide activity.** The editor already lights output ports by measured level, and
## that is both local and specific. A node-level treatment on top of it would say
## "something is happening in here", which the ports have already said better. The rule
## the proof settled on:
##
## > Visualise runtime activity at the node level only when the activity has semantic
## > structure beyond "signal exists".
##
## An envelope has four named stages and passes it. An amplifier has a signal going
## through it and does not — a triangle flickering because sound exists is an animation
## with no content, and the cable is a better place to say it anyway.

## How healthy the graph thinks a node is. Ordinary is the overwhelmingly normal case and
## draws nothing, which is the point: a validity channel that is always saying something
## is a channel nobody reads.
enum Health { WELL, WARNING, ERROR }

## How far a hovered node's surfaces move toward the next step up.
##
## A fraction of a step rather than a step. Hover answers "the pointer is on this one" and
## nothing more; at a whole step it starts to look chosen, and the reader who is scanning
## for the selected node finds two of them.
##
## Measured rather than chosen. A third of a step put the hovered header 1.08 times the
## luminance of the plain one, which is under what a large flat field is noticed at, and
## the proof sheet showed two specimens nobody could tell apart. Six tenths gives 1.14 —
## still the smallest change in the state vocabulary, and now a change.
const HOVER_LIFT := 0.6

## How far the accent is walked back for a selection perimeter.
##
## The node is already full of mint — value arcs, active ports, the transport dot — so a
## full-strength edge does not read as "this object is selected", it reads as one more
## mint thing among several. What separates the boundary from the marks inside it is that
## the boundary is continuous and they are not, and a calmer mint lets that do the work.
const SELECTION_CALM := 0.22

## The selected perimeter's weight, against 1 for every other state. The non-colour half
## of selection: mint says which, two pixels says selected, and either one alone would be
## carrying the whole message.
const SELECTION_EDGE := 2

## How far an unwell node's header moves toward its severity colour.
##
## The header and not the node. A whole node washed amber recolours its controls, its
## sockets and the cable ends sitting on them, and the graph's signal vocabulary is not
## available for this — audio is green because it is audio, not because the node it
## leaves is fine. The header is a region big enough to read at any zoom and it contains
## nothing that means anything else.
##
## Low, and the figure is not a preference — it is the largest tint the title survives.
##
## The design system holds body text to 7:1 and the suite enforces it. The binding case is
## a selected broken node, where the header has already been lifted a step before it is
## tinted, and the title lands at 7.27:1 at this figure and 6.95:1 one notch further. The
## first attempt used 0.30, which made a handsome olive slab and put the name at 5.32:1 —
## under the program's own floor, on the node the reader most needs to read.
##
## `design_test.gd` checks every combination in every palette, so this cannot drift back.
const HEALTH_TINT := 0.16


## The perimeter of a node, by what is true about it.
##
## Selection outranks hover deliberately: GraphNode draws a selected node from its
## `_selected` styleboxes and never consults the ordinary ones, so a hover treatment
## there would not draw at all — and it should not, because the two together said nothing
## the accent had not already said.
static func perimeter(selected: bool, hovered: bool) -> Color:
	if selected:
		return Design.ACCENT.lerp(Design.SURFACES[Design.Surface.NODE], SELECTION_CALM)
	if hovered:
		return Design.BORDERS[Design.Surface.ACTIVE]
	return Design.BORDERS[Design.Surface.RAISED]


## A node surface, lifted a fraction of a step under the pointer.
static func surface(level: int, hovered: bool) -> Color:
	var base: Color = Design.SURFACES[level]
	if not hovered or level + 1 >= Design.SURFACES.size():
		return base
	return base.lerp(Design.SURFACES[level + 1], HOVER_LIFT)


## The header's surface, given the state of the node under it.
##
## Selection lifts it a step, which is the one-step body change that makes a selected node
## feel picked up rather than merely outlined. Ill health tints whatever that came out as,
## so the two compose instead of one replacing the other: a selected broken node is a
## lifted amber header inside a mint perimeter, and both facts are legible.
static func header(selected: bool, hovered: bool, health: int) -> Color:
	var base: Color = surface(
		Design.Surface.ACTIVE if selected else Design.Surface.RAISED, hovered)
	return base if health == Health.WELL \
		else base.lerp(severity(health), HEALTH_TINT)


## The body's surface. Health does not reach it — the control region is where the reader
## is looking at numbers, and a tinted ground under a number is a number you have to
## think about.
static func body(selected: bool, hovered: bool) -> Color:
	return surface(Design.Surface.RAISED if selected else Design.Surface.NODE, hovered)


## The colour a severity speaks in. Borrowed from the editor's own warning and error inks
## and from nowhere near the signal palette.
static func severity(health: int) -> Color:
	return Design.ERROR if health == Health.ERROR else Design.WARNING
