class_name Outline
extends Control
## The graph as text: every node, in the order it runs, with what feeds it and what it feeds.
##
## The canvas is a good way to understand a patch and it is not the only way, and for some
## people it is not a way at all. A graph laid out in space needs a pointer to explore, eyes
## to follow a cable across it, and a screen big enough to hold it — and a screen reader has
## nothing to say about a picture of a curve between two circles.
##
## This is the same program as a list. It is keyboard-navigable by construction, it reads
## aloud sensibly, it holds a patch far too large to see at once, and it is the fastest way
## to answer "what is actually connected to this" — which on a busy canvas means tracing a
## line by hand. That last part is why this is not only an accommodation: it is a better
## tool for a specific question, and everybody has that question sometimes.
##
## Nothing here is a second source of truth. The order comes from the engine's own schedule,
## the connections from the patch, and the descriptions from the registry — the same three
## places the canvas reads.

signal node_chosen(node_id: String)

var registry: Dictionary = {}
var patch: Dictionary = {}
## Returns the engine's execution order as an Array of node ids, or an empty array.
var read_order: Callable = Callable()

var _tree: Tree
var _summary: Label


func _ready() -> void:
	var inset := MarginContainer.new()
	inset.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for edge in ["left", "right", "top", "bottom"]:
		inset.add_theme_constant_override("margin_" + edge, Design.scale(Design.SPACE_M))
	add_child(inset)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", Design.SPACE_S)
	inset.add_child(column)

	_summary = Label.new()
	_summary.add_theme_font_size_override("font_size", Design.scale(Design.SIZE_SECONDARY))
	_summary.add_theme_color_override("font_color", Design.INK_SECOND)
	column.add_child(_summary)

	_tree = Tree.new()
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.hide_root = true
	_tree.allow_reselect = true
	# Deliberately focusable, unlike almost everything else in this editor. The whole point
	# is that somebody can reach it with Tab and drive it with the arrow keys.
	_tree.focus_mode = Control.FOCUS_ALL
	_tree.add_theme_font_override("font", Design.font(Design.WEIGHT_REGULAR))
	_tree.add_theme_font_size_override("font_size", Design.scale(Design.SIZE_BODY))
	_tree.add_theme_color_override("font_color", Design.INK_NORMAL)
	_tree.item_selected.connect(_on_item_selected)
	column.add_child(_tree)


## Rebuilds the list. Cheap enough to do on every graph change.
func refresh() -> void:
	if _tree == null:
		return
	_tree.clear()
	var root := _tree.create_item()

	var nodes: Array = patch.get("nodes", [])
	var connections: Array = patch.get("connections", [])

	# Execution order if the engine will give it, document order otherwise. The order is
	# the interesting part — it is the one thing the canvas cannot show you directly.
	var order: Array = []
	if read_order.is_valid():
		order = read_order.call()
	if order.is_empty():
		for node in nodes:
			order.append(str(node["id"]))

	_summary.text = "%d nodes, %d connections, in the order they run" % [
		nodes.size(), connections.size()]

	for position in order.size():
		var node_id: String = str(order[position])
		var type_name := _type_of(node_id)
		if type_name == "":
			continue
		var descriptor: Dictionary = registry.get(type_name, {})

		var item := _tree.create_item(root)
		# The number is not decoration: it is the answer to "when does this run", which is
		# what decides whether a modulation arrives this block or the next one.
		item.set_text(0, "%d.  %s  is a  %s" % [position + 1, node_id, type_name])
		item.set_metadata(0, node_id)
		item.set_tooltip_text(0, str(descriptor.get("summary", "")))
		item.set_custom_color(0, Design.INK_BRIGHT)

		var inbound := 0
		for connection in connections:
			if str(connection["to"]["node"]) != node_id:
				continue
			inbound += 1
			var line := item.create_child()
			# Words, not arrows, and for two reasons. The font has no U+2192 — the editor
			# already had seven glyphs rendering as tofu boxes for exactly that reason —
			# and a screen reader announces an arrow as "right arrow" or skips it, while
			# "from" and "to" are the words somebody would use out loud anyway. This is the
			# view built to be read aloud; it should read.
			line.set_text(0, "        in    from  %s.%s  to  %s" % [
				str(connection["from"]["node"]), str(connection["from"]["port"]),
				str(connection["to"]["port"])])
			line.set_metadata(0, str(connection["from"]["node"]))
			line.set_custom_color(0, Design.INK_SECOND)

		var outbound := 0
		for connection in connections:
			if str(connection["from"]["node"]) != node_id:
				continue
			outbound += 1
			var line := item.create_child()
			line.set_text(0, "        out   %s  to  %s.%s" % [
				str(connection["from"]["port"]), str(connection["to"]["node"]),
				str(connection["to"]["port"])])
			line.set_metadata(0, str(connection["to"]["node"]))
			line.set_custom_color(0, Design.INK_SECOND)

		# A node connected to nothing is worth saying out loud rather than leaving as an
		# absence — on the canvas it is a card sitting on its own, which reads as a mistake
		# only if you happen to look at it.
		if inbound == 0 and outbound == 0:
			var alone := item.create_child()
			alone.set_text(0, "        not connected to anything")
			alone.set_custom_color(0, Design.WARNING)

		item.collapsed = false


func _type_of(node_id: String) -> String:
	for node in patch.get("nodes", []):
		if str(node["id"]) == node_id:
			return str(node["type"])
	return ""


func _on_item_selected() -> void:
	var item := _tree.get_selected()
	if item == null:
		return
	var node_id: Variant = item.get_metadata(0)
	if typeof(node_id) == TYPE_STRING and node_id != "":
		node_chosen.emit(str(node_id))
