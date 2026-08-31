class_name LayoutFit
extends RefCounted

## Whether a node is actually laid out correctly at the width it has been given.
##
## The one definition of "valid", shared by the width harness and the inventory so the two
## cannot drift. It answers the question a width class is really about:
##
## > How narrow can this node be and still be right?
##
## Which is not how wide it makes itself when nothing constrains it. A Godot container
## will happily ask for the width of its most comfortable arrangement while the formal
## columns and gutters still fit perfectly at less — the state-variable filter preferred
## 411 and required 416, and the live editor sat it at 376 without complaint. Three
## numbers, and only one of them is the contract.
##
## Everything here is judged at zoom 1.0 in FULL detail. A node in REDUCED or MAP has
## hidden its rows and collapsed its minimum; it fits anything, and a check run there
## passes by measuring nothing.

## Every reason a width would be wrong, as a list of complaints. Empty means the node is
## genuinely laid out correctly at the width it is standing at.
##
## `tall` is the node's height before the width was forced, or 0 to skip the reflow test.
static func complaints(widget: GraphNode, forced: float, tall: float) -> Array:
	var bad: Array = []

	# The first and bluntest test. A minimum only pushes a Control wider and nothing pulls
	# one back, so a node still over the width it was handed is a node Godot refused: the
	# contents genuinely do not fit and no other question is worth asking.
	if widget.size.x > forced + 0.5:
		bad.append("refused, stands at %.0f" % widget.size.x)
		return bad

	# A node that got taller when it was made narrower has reflowed — a row wrapped, or a
	# label took a second line. How many parameters share a line is the grid's business
	# and not something width is allowed to change.
	if tall > 0.0 and widget.size.y > tall + 0.5:
		bad.append("grew %.0f taller" % (widget.size.y - tall))

	var frame := widget.get_global_rect()
	var queue: Array = [widget]
	while not queue.is_empty():
		var next: Node = queue.pop_front()
		for child in next.get_children():
			var control := child as Control
			if control == null:
				continue
			queue.append(control)
			if not control.is_visible_in_tree():
				continue
			# Every label got at least the room it asked for. This catches a clipped word
			# and an ellipsis the body layout caused rather than the zoom.
			if control is Label:
				var asked_for := control.get_combined_minimum_size().x
				if control.size.x + 0.5 < asked_for:
					bad.append("'%s' clipped by %.0f"
						% [(control as Label).text, asked_for - control.size.x])
			# And nothing hangs outside the node it belongs to.
			var rect := control.get_global_rect()
			if rect.position.x + 0.5 < frame.position.x or rect.end.x > frame.end.x + 0.5:
				bad.append("%s reaches outside the node" % control.get_class())

	# Nothing on a row overlaps anything else on it. Controls sitting on top of each other
	# is the failure that looks fine in a screenshot until somebody tries to aim.
	for child in widget.get_children():
		var line := child as Control
		if line == null or not line.is_visible_in_tree():
			continue
		var seen: Array = []
		for kid in line.get_children():
			var control := kid as Control
			if control == null or not control.is_visible_in_tree():
				continue
			var rect := control.get_global_rect()
			for other: Rect2 in seen:
				if rect.position.x < other.end.x - 0.5 \
						and other.position.x < rect.end.x - 0.5:
					bad.append("two controls overlap on one row")
					break
			seen.append(rect)
	return bad
