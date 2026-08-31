extends SceneTree

## What width class a type belongs in, measured rather than guessed.
##
## The rollout's own instrument. Hand it a list of types and it reports what each one's
## contents actually want, at every interface scale, with the smallest class that holds
## the worst of them — which is the whole of step 2 on the migration checklist.
##
##   godot --path editor-godot --script width_sheet.gd
##
## with WIDTH_SHEET_TYPES a comma-separated list and WIDTH_SHEET_OUT naming a directory.
## With no list it measures every type that is already migrated, which is the regression
## check: a class assigned from one batch's measurement should still hold in the next.
##
## ## Two rules the harness enforces, both learned the hard way
##
## **A specimen is measured at zoom 1.0 in FULL detail.** A node built while the graph is
## already reduced never reaches its full width: its rows are hidden from the start, so
## the size it settles at is the reduced one and it never grows back — a minimum only
## pushes a Control wider and nothing pulls one down. The first run of the 14C batch
## reported a one-pole filter at 194 when it stands at 405 everywhere a person would see
## it. A node constructed directly in REDUCED or MAP state is not a valid width specimen.
##
## **The binding scale is the smallest one, not the one you happen to be looking at.** A
## class figure scales linearly with the interface scale and the content inside it does
## not, because type sizes stop shrinking at `Design.TYPE_FLOOR`. So the words in a node
## are relatively larger at Comfortable than at XL, and XL — the scale every acceptance in
## this pass has been judged at — is the *most forgiving*. A type is assigned from its
## worst scale.

## Every interface scale, in the order `Design.SCALE_FACTORS` declares them.
const SCALE_NAMES := ["Small", "Comfort", "Large", "XL"]

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


## The smallest declared class that holds a figure, or -1 when none does.
func smallest_class(natural: float) -> int:
	for index in NodeGrid.WIDTHS.size():
		if float(NodeGrid.WIDTHS[index]) >= natural:
			return index
	return -1


func _initialize() -> void:
	DisplayServer.window_set_size(Vector2i(1440, 900))
	root.content_scale_size = Vector2i(1440, 900)
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	await settle(16)

	var types := wanted()
	# A seam is keyed by the port it stands for and cannot be spelt into a document's
	# type field, so it is measured where it already lives rather than in a scratch patch.
	var placeable: Array = []
	for type: String in types:
		if not type.begins_with("seam:"):
			placeable.append(type)

	# Classes off for the whole run. See NodeGrid.measuring for why neither of the two
	# obvious readings works on a node that already has a class.
	NodeGrid.measuring = true
	var natural := {}
	for scale in Design.SCALE_FACTORS.size():
		Design.ui_scale = scale
		var document := {"schema_version": 1, "metadata": {"name": "width sheet"},
			"nodes": [], "connections": []}
		for i in placeable.size():
			(document["nodes"] as Array).append({"id": "n%d" % i,
				"type": placeable[i], "parameters": {},
				"position": {"x": float(i % 5) * 700.0, "y": float(i / 5) * 560.0}})
		await main._load_text(JSON.stringify(document, "  "))
		await settle(16)
		main._set_roll_open(false)
		# Full detail before anything is read. See the note at the top of this file.
		main.graph_edit.zoom = 1.0
		# A scratch patch of unconnected nodes raises genuine unconnected-input
		# warnings, and a warned node carries an alert mark in its header — about
		# twenty units of extra header minimum that has nothing to do with the
		# type. Cleared, or every specimen is measured wearing something no real
		# instance of it would wear.
		main._apply_health({})
		await settle(18)
		for i in placeable.size():
			var widget: GraphNode = main.widgets.get("n%d" % i)
			if widget == null:
				continue
			var wide := widget.size.x
			var type: String = placeable[i]
			if not natural.has(type):
				natural[type] = []
			natural[type].append(wide / Design.SCALE_FACTORS[scale])

	print("%-20s %7s %7s %7s %7s   %7s  %s"
		% ["type", "Small", "Comfort", "Large", "XL", "worst", "class"])
	var record := {}
	for type: String in natural:
		var worst := 0.0
		var line := ""
		for one: float in natural[type]:
			worst = maxf(worst, one)
			line += "%8.1f" % one
		var index := smallest_class(worst)
		var declared: int = int(NodeGrid.WIDTH_CLASS.get(type, -1))
		var verdict: String = "none holds it" if index < 0 \
			else str(NodeGrid.width_class_name(type))
		if index >= 0 and not NodeGrid.WIDTH_CLASS.has(type):
			verdict = ["Narrow", "Standard", "Wide", "Extra"][index]
		# What it needs against what it was given. A mismatch is not automatically wrong
		# — a type may sit in a wider class on purpose — but it is always worth saying.
		if index >= 0 and declared >= 0 and declared != index:
			verdict = "%s, declared %s" % [["Narrow", "Standard", "Wide",
				"Extra"][index], ["Narrow", "Standard", "Wide", "Extra"][declared]]
		print("%-20s%s   %7.1f  %s" % [type, line, worst, verdict])
		record[type] = {"at": natural[type], "worst": snappedf(worst, 0.1),
			"fits": verdict}

	NodeGrid.measuring = false

	# And the other half: with the classes back on, does every node actually stand at the
	# one it was given, at every interface scale? A class assigned from one scale is only
	# a class if it holds at the others, and a content minimum larger than the class
	# pushes the node back out — Godot will not clip it, so the invariant simply breaks
	# quietly at a scale nobody photographed.
	print("")
	print("%-20s %s" % ["type", "stands at its class:  Small  Comfort  Large  XL"])
	for scale in Design.SCALE_FACTORS.size():
		Design.ui_scale = scale
		var document := {"schema_version": 1, "metadata": {"name": "class gate"},
			"nodes": [], "connections": []}
		for i in placeable.size():
			(document["nodes"] as Array).append({"id": "n%d" % i,
				"type": placeable[i], "parameters": {},
				"position": {"x": float(i % 5) * 700.0, "y": float(i / 5) * 560.0}})
		await main._load_text(JSON.stringify(document, "  "))
		await settle(16)
		main._set_roll_open(false)
		main.graph_edit.zoom = 1.0
		# A scratch patch of unconnected nodes raises genuine unconnected-input
		# warnings, and a warned node carries an alert mark in its header — about
		# twenty units of extra header minimum that has nothing to do with the
		# type. Cleared, or every specimen is measured wearing something no real
		# instance of it would wear.
		main._apply_health({})
		await settle(18)
		for i in placeable.size():
			var widget: GraphNode = main.widgets.get("n%d" % i)
			if widget == null:
				continue
			var type: String = placeable[i]
			var declared_width := NodeGrid.width_for(type)
			if not record.has(type):
				record[type] = {}
			if not (record[type] as Dictionary).has("stands"):
				record[type]["stands"] = []
			(record[type]["stands"] as Array).append(
				declared_width <= 0 or is_equal_approx(widget.size.x,
					float(declared_width)))
	for type: String in record:
		var stands: Array = (record[type] as Dictionary).get("stands", [])
		var line := ""
		for ok: bool in stands:
			line += "%9s" % ("ok" if ok else "OVER")
		print("%-20s %s" % [type, line])

	var folder := OS.get_environment("WIDTH_SHEET_OUT")
	if folder.strip_edges() != "":
		DirAccess.make_dir_recursive_absolute(folder)
		var file := FileAccess.open(folder.path_join("widths.json"), FileAccess.WRITE)
		file.store_string(JSON.stringify(record, "  "))
		file.close()
	quit()
