extends SceneTree

## What a parameter actually says to the reader at each distance.
##
## 15B's screenshots showed nodes at 66% reading `cutoff` with no number beside it and a
## bare `0.42` with no word beside it, and a screenshot cannot tell you whether that is a
## rendering artefact, a crop, or the system. This asks the renderer.
##
## `ScreenText.fit_for` is the whole screen-space typography decision in one function, and
## the file that holds it says why anything else is worthless: a test that reasons about
## font sizes on its own is a second implementation that can agree with the stylesheet
## while the screen disagrees with both. So every label here is put to that function, and
## what comes back is what the reader receives.
##
##   godot --path editor-godot --script qa_reduced.gd
##
## Prints one line per parameter that arrives incomplete, and a count per band.

const PatchGraph := preload("res://patch_graph.gd")
const PATCH := "res://qa/dense-graph.json"
const ZOOMS := [1.0, 0.66, 0.40, 0.28]

var main: Node
var graph: GraphEdit


func settle(n: int) -> void:
	for i in n:
		await process_frame


## Every parameter cell in a node, wherever the row builder put it.
func cells(from: Node, into: Array = []) -> Array:
	for child in from.get_children():
		var control := child as Control
		if control == null:
			continue
		if str(control.get_meta("cell", "")) == "parameter":
			into.append(control)
		cells(control, into)
	return into


## Whether the cell is showing its value through a dropdown rather than through a label.
## At full detail the chosen option is drawn on the OptionButton itself and the standby
## label is hidden, so a cell counted by its labels alone reports a name with no value —
## which is the measurement being wrong rather than the node.
func value_in_control(cell: Control) -> bool:
	var queue: Array = [cell]
	while not queue.is_empty():
		var next: Node = queue.pop_front()
		for child in next.get_children():
			var control := child as Control
			if control == null:
				continue
			queue.append(control)
			if control is OptionButton and control.is_visible_in_tree():
				return true
	return false


## The value label of a cell, whichever of the two kinds it has: a number in a value field,
## or the chosen option of a dropdown standing in for it at reduced detail.
func value_label(cell: Control) -> Label:
	var enum_value: Label = cell.get_meta("enum_value") \
		if cell.has_meta("enum_value") else null
	if enum_value != null and enum_value.is_visible_in_tree():
		return enum_value
	var field: Control = cell.get_meta("value_field") \
		if cell.has_meta("value_field") else null
	if field == null:
		return null
	for child in field.get_children():
		var label := child as Label
		if label != null and str(label.get_meta("screen_kind", "")) == "value":
			return label
	return null


## Whether a label reaches the reader at this zoom, by the renderer's own reckoning.
func reaches(label: Label, zoom: float) -> bool:
	if label == null or not label.is_visible_in_tree() or label.text.strip_edges() == "":
		return false
	return PatchGraph.ScreenText.fit_for(label, zoom) != PatchGraph.ScreenText.Fit.NO_ROOM


## Containers and text are furniture. Anything else drawn inside the body is a control
## or a picture of one, and neither belongs to a band that says it draws neither.
const FURNITURE := ["VBoxContainer", "HBoxContainer", "MarginContainer", "PanelContainer",
	"CenterContainer", "GridContainer", "Container", "Control", "Label", "TextureRect",
	"Panel", "ScrollContainer", "AspectRatioContainer"]

## Anything a reader could try to aim at, or any picture of one, still drawn where the
## contract says there is nothing to aim at. Counted per node so a single offender is not
## reported as five.
func aimables(widget: GraphNode) -> Array:
	var found: Array = []
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
			# A titlebar button is chrome and belongs to the node at every size; what is
			# being looked for is something in the body that edits or depicts a value.
			if control.get_parent() == widget.get_titlebar_hbox():
				continue
			if FURNITURE.has(control.get_class()) and control.get_script() == null:
				continue
			# A container with a script is still a container; what is being looked for is
			# a leaf that draws or edits something of its own.
			var leaf := true
			for grandchild in control.get_children():
				if grandchild is Control:
					leaf = false
			if not leaf and not (control is BaseButton or control is Range):
				continue
			if control is Label or control is TextureRect:
				continue
			var script: Script = control.get_script()
			found.append(control.get_class() if script == null
				else str(script.resource_path).get_file())
	return found


func _initialize() -> void:
	Settings.isolate()
	DisplayServer.window_set_size(Vector2i(1920, 1200))
	root.content_scale_size = Vector2i(1920, 1200)
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	await settle(16)
	var file := FileAccess.open(PATCH, FileAccess.READ)
	await main._load_text(file.get_as_text())
	await settle(20)
	main._set_roll_open(false)
	graph = main.graph_edit
	main._choose_detail_mode(PatchGraph.DetailMode.ADAPTIVE)
	await settle(10)

	for scale in Design.SCALE_FACTORS.size():
		main._use_ui_scale(scale)
		await settle(8)
		print("")
		print("=== %s ===" % Design.SCALE_NAMES[scale])
		for zoom: float in ZOOMS:
			graph.zoom = zoom
			graph._update_detail()
			main._apply_detail(graph.detail)
			await settle(8)
			var band: String = NodeOptical.name_of(NodeOptical.of(graph.detail))
			var whole := 0
			var orphan_value := 0
			var orphan_name := 0
			var gone := 0
			var examples: Array = []
			var ghosts: Array = []
			for child in graph.get_children():
				var widget := child as GraphNode
				if widget == null or not widget.visible:
					continue
				if band != "FULL":
					var aims := aimables(widget)
					if not aims.is_empty():
						ghosts.append("%s (%d)" % [widget.title, aims.size()])
				for cell: Control in cells(widget):
					if not cell.is_visible_in_tree():
						continue
					var name_label: Label = cell.get_meta("name_label") \
						if cell.has_meta("name_label") else null
					var has_name := reaches(name_label, zoom)
					var has_value := reaches(value_label(cell), zoom) \
						or value_in_control(cell)
					if has_name and has_value:
						whole += 1
					elif has_name:
						orphan_name += 1
						if examples.size() < 4:
							examples.append("%s: '%s' with no value"
								% [widget.title, name_label.text])
					elif has_value:
						orphan_value += 1
						if examples.size() < 4:
							examples.append("%s: '%s' with no name"
								% [widget.title, value_label(cell).text])
					else:
						gone += 1
			print("  %5.0f%%  %-8s  whole %3d   name only %3d   value only %3d   neither %3d"
				% [zoom * 100.0, band, whole, orphan_name, orphan_value, gone])
			for one: String in examples:
				print("           %s" % one)
			if not ghosts.is_empty():
				print("           still aimable at %s: %s" % [band, ", ".join(ghosts)])
	quit()
