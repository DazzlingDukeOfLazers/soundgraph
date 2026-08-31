class_name NodeOptical
extends RefCounted

## What a node is at each distance, as a contract rather than as behaviour.
##
## The machinery already existed and works: `PatchGraph.Detail` has four bands, they are
## chosen by measured floors rather than by taste, and the step 1 baseline showed the
## editor already shedding parameter rows and then the whole control panel as the zoom
## falls. What it never had was a statement of what each band is *for* — and behaviour
## without a statement is behaviour nobody can hold to account, which is how a level of
## detail acquires a tiny knob that is technically drawable.
##
## Three states, mapped onto the four bands that produce them. No new thresholds: the
## names are put on what is already there.
##
## [codeblock]
## FULL      Detail.FULL                  the working node, edited in place
## REDUCED   Detail.COMPACT               still a node, secondary information gone
## MAP       Detail.SUMMARY, TOPOLOGY     a symbol in a signal-flow diagram
## [/codeblock]
##
## MAP is two bands because it has two cuts of one idea: SUMMARY keeps the port names,
## TOPOLOGY has not the room. Neither draws a control, which is what makes both of them
## MAP rather than a smaller REDUCED.
##
## ## What each state may contain
##
## [codeblock]
## FULL      identity glyph, canonical title, controls, parameter labels and values,
##           dropdowns, port labels, ports, every interaction and validity state.
##           The complete steps 3-11 node.
##
## REDUCED   title, ports and their connection, values and control state as words,
##           port labels. No aiming at anything: the controls have given their room
##           to the words that say what they were.
##
## MAP       silhouette, identity, perimeter sockets, cables, selection, validity.
##           Port names while they fit. Nothing else.
## [/codeblock]
##
## The rule underneath all three, which is step 5's and is load-bearing:
##
## > Font size participates in the level of detail. When room runs out, remove
## > lower-priority information rather than shrink required information below its floor.
##
## ## Identity, deterministically
##
## Canonical name if it fits at the legibility floor; the type's written-down compact
## name if it does not; an ellipsis only if neither. `ScreenText._name_for` is the one
## implementation. For a type that has been through the pass, a cut name is a **failure**
## and `optical_sheet.gd` counts them — there should be none, at any zoom, ever.

## Preloaded rather than named: `patch_graph.gd` has no `class_name`, and every other
## file that needs its bands reaches it the same way.
const PatchGraph := preload("res://patch_graph.gd")

enum State { FULL, REDUCED, MAP }

## Which state a detail band is an instance of.
static func of(detail: int) -> int:
	match detail:
		PatchGraph.Detail.FULL:
			return State.FULL
		PatchGraph.Detail.COMPACT:
			return State.REDUCED
	return State.MAP


static func name_of(state: int) -> String:
	return ["FULL", "REDUCED", "MAP"][state]


## What survives into each state, as the table rather than as an impression.
##
## `true` is a promise, `false` is a promise too, and "optional" means the renderer may
## keep it while it reads and may drop it when it stops. The point of writing it down is
## that the last row is a deliberate absence: nothing is added anywhere purely so that
## every state can survive every level.
##
## [codeblock]
##                     FULL      REDUCED     MAP
## selection           yes       yes         yes
## validity            yes       yes         yes
## hover               yes       simplified  minimal
## connected socket    yes       yes         yes
## activity            yes       optional    only where still useful
## controls            yes       no          no
## parameter values    yes       as words    no
## port labels         yes       yes         while they fit
## identity glyph      see below
## [/codeblock]
##
## Selection and validity survive everywhere because they are the two facts a reader
## navigates by, and both are carried by colour over a region — a perimeter and a header
## — which is the one thing that does not get smaller.
##
## **The glyph is not on the band ladder at all**, and the step 12 sweep is what found
## that. It stands down with the title Label at the title's own compensation boundary,
## which at XL is around a zoom of 0.90 — inside FULL, above the FULL/REDUCED line at
## 0.875. So for the bottom slice of FULL the node has no mark, and the first draft of
## this table said it did. Two systems keyed to two different thresholds, which is the
## thing this step exists to notice.
##
## It is written down rather than corrected. The behaviour is right — a mark that has
## stopped reading should go — and moving either threshold to make a table look tidy is
## what the brief said not to do.
##
## ## Two departures the dense-graph QA found, at 15B
##
## Written down for the same reason, and neither of them corrected here.
##
## **Six controls survive into MAP.** The plugin host's three buttons, the MIDI CC learn
## button, the Speech words button and the Step Sequencer's step grid are still drawn at
## 40% and 28%, at every interface scale, and the table above says a MAP node draws no
## control. Every one of them is a control the row system never owned, so `_apply_detail`
## was never asked about it: the rule is right and is not reaching them. `editor_test.gd`
## holds the count at the known figure so a sixth cannot arrive unnoticed.
##
## **At REDUCED a parameter can arrive as half a pair.** The table says values survive "as
## words", and what a reader gets at 66% is sometimes a name with no number and sometimes
## a bare number with no name — 13% of cells at Comfortable and 29% at Compact, measured
## by `qa_reduced.gd` through the renderer's own `ScreenText.fit_for`. The cause is that
## `Fit.NO_ROOM` decides **per label** while a parameter is **a pair**, and nothing states
## what the unit of removal is. That is a gap in the rule rather than a slip against it,
## which is why it is the one finding of 15B entitled to reopen the frozen system. See
## docs/graph-nodes.md.
const SURVIVAL := {
	"selection": [true, true, true],
	"validity": [true, true, true],
	"connected_socket": [true, true, true],
	"controls": [true, false, false],
}


## Zooms that land squarely inside each state at the current interface scale, for a proof
## sheet that wants one specimen per state rather than one per boundary.
##
## Midpoints rather than the boundaries themselves: a picture taken on a threshold is a
## picture of the threshold, and what a state looks like is a question about its middle.
static func sample_zooms() -> Array:
	var full: float = PatchGraph._full_floor()
	var compact: float = PatchGraph.compact_floor()
	var summary: float = PatchGraph.summary_floor()
	return [
		minf(1.0, (full + 1.0) * 0.5),
		(compact + full) * 0.5,
		maxf(0.25, summary * 0.75),
	]
