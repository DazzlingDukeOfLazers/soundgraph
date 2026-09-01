extends SceneTree

## Which width class a type belongs in, decided by whether it *works* at that width.
##
## The rollout's instrument, and the second version of it. The first measured how wide a
## node makes itself when nothing constrains it, and reported a state-variable filter
## wanting 411 against a Wide class of 376 — while the same node in a live patch sat at
## 376 and looked perfectly correct. Both numbers were real. They answer different
## questions:
##
##   how wide does this node make itself when nobody asks?      preferred
##   how narrow can it be and still be laid out correctly?      required
##
## A width class is a claim about the second. Classifying the first would classify
## preferences: a Godot container will happily request the width of its most comfortable
## arrangement while the formal columns and gutters still fit perfectly at less.
##
##   godot --path editor-godot --script width_sheet.gd
##
## with WIDTH_SHEET_TYPES a comma-separated list, or nothing to re-check every migrated
## type, and WIDTH_SHEET_OUT naming a directory.
##
## ## How it decides
##
## For each type, each class from the narrowest upward: force the node to that width, let
## the layout settle, and ask whether anything broke. The first class that survives is the
## class. Preferred width is still reported, as diagnosis rather than as the selector.
##
## ## Two rules it enforces, both learned the hard way
##
## **Everything is judged at zoom 1.0 in FULL detail.** A node in REDUCED or MAP has hidden
## its rows and collapsed its minimum; it then fits anything, and a check run there passes
## by measuring nothing. The suite's own class check was doing exactly that.
##
## **And at every interface scale.** A class figure scales linearly and the content inside
## it does not, because type sizes stop shrinking at `Design.TYPE_FLOOR`. The words in a
## node are relatively larger at Compact than at XL, so XL — the scale every acceptance in
## this pass has been judged at — is the most forgiving one there is.

const HarnessExit := preload("res://harness_exit.gd")
const SCALE_NAMES := ["Compact", "Comfortable", "Large", "XL"]
## From NodeGrid, so this cannot drift from the ladder it reports on.
const CLASS_NAMES := NodeGrid.CLASS_NAMES

## Frames to let a forced width propagate. Generous on purpose: the detail level is polled
## in `_process` and the rows are put back in a deferred pass after it, so a node read too
## early is still half reduced.
const SETTLE := 14

var main: Node


func settle(n: int) -> void:
	for i in n:
		await process_frame


func wanted() -> Array:
	var asked := OS.get_environment("WIDTH_SHEET_TYPES")
	if asked.strip_edges() == "":
		return NodeIdentity.MIGRATED.duplicate()
	var types: Array = []
	for one: String in asked.split(","):
		if one.strip_edges() != "":
			types.append(one.strip_edges())
	return types


## Kept in `LayoutFit` so this harness and `inventory.gd` cannot drift apart about what
## "valid" means.


func build(types: Array) -> void:
	var document := {"schema_version": 1, "metadata": {"name": "width sheet"},
		"nodes": [], "connections": []}
	for i in types.size():
		(document["nodes"] as Array).append({"id": "n%d" % i, "type": types[i],
			"parameters": {},
			"position": {"x": float(i % 5) * 900.0, "y": float(i / 5) * 700.0}})
	await main._load_text(JSON.stringify(document, "  "))
	await settle(16)
	main._set_roll_open(false)
	main.graph_edit.zoom = 1.0
	await settle(SETTLE)


func _initialize() -> void:
	DisplayServer.window_set_size(Vector2i(1440, 900))
	root.content_scale_size = Vector2i(1440, 900)
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	await settle(16)

	var types := wanted()
	# A seam is keyed by the port it stands for and cannot be spelt into a document's type
	# field, so it is left to be checked where it already lives.
	var placeable: Array = []
	for type: String in types:
		if not type.begins_with("seam:"):
			placeable.append(type)

	var record := {}
	for type: String in placeable:
		record[type] = {"prefers": [], "needs": [], "why": ""}

	for scale in Design.SCALE_FACTORS.size():
		Design.ui_scale = scale

		# The preferred width first, with the classes suppressed. Diagnosis, not the
		# selector: a classed node cannot be measured for this, because its width is
		# pinned to its class and reading it back reports the class.
		NodeGrid.measuring = true
		await build(placeable)
		for i in placeable.size():
			var free: GraphNode = main.widgets.get("n%d" % i)
			if free != null:
				(record[placeable[i]]["prefers"] as Array).append(
					free.size.x / Design.SCALE_FACTORS[scale])

		# Then each class from the narrowest up, and the first that survives.
		var settled := {}
		for index in NodeGrid.WIDTHS.size():
			var forced := float(NodeGrid.scaled(int(NodeGrid.WIDTHS[index])))
			await build(placeable)
			for i in placeable.size():
				var type: String = placeable[i]
				if settled.has(type):
					continue
				var widget: GraphNode = main.widgets.get("n%d" % i)
				if widget == null:
					continue
				var tall := widget.size.y
				widget.custom_minimum_size.x = forced
				widget.size.x = forced
				await settle(6)
				var bad := LayoutFit.complaints(widget, forced, tall)
				if bad.is_empty():
					settled[type] = index
				elif index == NodeGrid.WIDTHS.size() - 1:
					settled[type] = -1
					record[type]["why"] = str(bad[0])
		NodeGrid.measuring = false
		for type: String in placeable:
			(record[type]["needs"] as Array).append(int(settled.get(type, -1)))

	print("")
	print("%-20s %8s  %-14s %-10s %-14s %s" % ["type", "prefers", "needs worst",
		"declared", "verdict", "Compact   Comfort   Large     XL"])
	for type: String in record:
		var entry: Dictionary = record[type]
		var prefers := 0.0
		for one: float in entry["prefers"]:
			prefers = maxf(prefers, one)
		# The worst scale decides, and -1 (nothing holds it) is worse than any class.
		var needs := 0
		for one: int in entry["needs"]:
			needs = -1 if one < 0 or needs < 0 else maxi(needs, one)
		var declared: int = int(NodeGrid.WIDTH_CLASS.get(type, -1))
		var verdict := "-"
		if needs < 0:
			verdict = "NO CLASS FITS"
		elif declared >= 0:
			verdict = "ok" if needs == declared \
				else ("TOO NARROW" if needs > declared else "roomy")
		# Per scale, because which scale a type fails at is the whole diagnosis.
		var per := ""
		for one: int in entry["needs"]:
			per += "%-10s" % ("none" if one < 0 else CLASS_NAMES[one])
		print("%-20s %8.1f  %-14s %-10s %-14s %s" % [type, prefers,
			"none holds it" if needs < 0 else CLASS_NAMES[needs],
			"-" if declared < 0 else CLASS_NAMES[declared], verdict, per])
		entry["prefers_worst"] = snappedf(prefers, 0.1)
		entry["verdict"] = verdict

	var folder := OS.get_environment("WIDTH_SHEET_OUT")
	if folder.strip_edges() != "":
		DirAccess.make_dir_recursive_absolute(folder)
		var file := FileAccess.open(folder.path_join("widths.json"), FileAccess.WRITE)
		file.store_string(JSON.stringify(record, "  "))
		file.close()
	await HarnessExit.finish(self, main)
