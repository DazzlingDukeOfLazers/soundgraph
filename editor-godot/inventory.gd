extends SceneTree

## Every runtime node type, and what the cosmopolitan system has done with it.
##
## The migration was run family by family, from the registry read by eye. This is the
## denominator: the actual list, enumerated rather than remembered, with every type
## classified and nothing left unaccounted for.
##
## It also measures the thing the width classes were guessed from three specimens and are
## now answerable from forty: the **narrowest width at which each type is still valid**,
## found by binary search rather than by trying the four classes. That is what a histogram
## needs — class membership only tells you which of four buckets a type fell into, and the
## question is whether those four buckets are where the corpus actually clusters.
##
##   godot --headless --path editor-godot --script inventory.gd
##
## with INVENTORY_OUT naming a directory for the JSON.
##
## Nothing is migrated or redesigned here. It reads.

## From NodeGrid, so this cannot drift from the ladder it reports on.
const CLASS_NAMES := NodeGrid.CLASS_NAMES
const SCALE_NAMES := ["Compact", "Comfortable", "Large", "XL"]

## The search window for a minimum valid width, in base units, and how fine it goes. Eight
## is the grid everything else in the node is built on, so a figure between two multiples
## of eight would be a figure nothing could be built at.
const SEARCH_LOW := 120
const SEARCH_HIGH := 720
const SEARCH_STEP := 8

## Frames to let a forced width settle. The layout is recomputed on the next pass and the
## detail level is polled in _process, so a node read too early is still mid-flight.
const SETTLE := 5

var main: Node
var _explained := 0


func settle(n: int) -> void:
	for i in n:
		await process_frame


## The narrowest multiple of eight at which this node is still valid, by binary search.
## Returns -1 when even the top of the window fails.
func narrowest(widget: GraphNode) -> int:
	var tall := widget.size.y
	var low := SEARCH_LOW
	var high := SEARCH_HIGH
	# The top of the window has to work or the search means nothing.
	widget.custom_minimum_size.x = float(NodeGrid.scaled(high))
	widget.size.x = float(NodeGrid.scaled(high))
	await settle(SETTLE)
	var top := LayoutFit.complaints(widget, float(NodeGrid.scaled(high)), tall)
	if not top.is_empty():
		if _explained < 4:
			_explained += 1
			print("  %s will not fit %d: %s" % [widget.title, high, str(top)])
		return -1
	while high - low > SEARCH_STEP:
		var middle := int(roundf(float(low + high) * 0.5 / float(SEARCH_STEP))) \
			* SEARCH_STEP
		if middle <= low or middle >= high:
			break
		var forced := float(NodeGrid.scaled(middle))
		widget.custom_minimum_size.x = forced
		widget.size.x = forced
		await settle(SETTLE)
		if LayoutFit.complaints(widget, forced, tall).is_empty():
			high = middle
		else:
			low = middle
	return high


func status_of(type: String) -> String:
	if not NodeIdentity.migrated(type):
		return "HELD"
	if NodeIdentity.glyph_of(type) >= 0 or NodeIdentity.VARIANT.has(type):
		return "MIGRATED"
	return "MIGRATED / RESERVED GLYPH"


func _initialize() -> void:
	DisplayServer.window_set_size(Vector2i(1440, 900))
	root.content_scale_size = Vector2i(1440, 900)
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	await settle(16)

	var types: Array = main.registry.keys()
	types.sort()
	# Seams are keyed by the port they stand for and cannot be spelt into a document's
	# type field, so they are counted and reported without being measured here.
	var placeable: Array = []
	for type: String in types:
		if not type.begins_with("seam:"):
			placeable.append(type)

	var record := {}
	for type: String in types:
		record[type] = {
			"display_name": str((main.registry[type] as Dictionary).get("display_name",
				type)),
			"category": str((main.registry[type] as Dictionary).get("category", "")),
			"compact": NodeIdentity.compact_of(type),
			"width_class": NodeGrid.width_class_name(type),
			"glyph": NodeIdentity.glyph_of(type),
			"variant": NodeIdentity.variant_parameter(type),
			"status": status_of(type),
			"narrowest": [],
		}

	# The measurement, at every interface scale. The classes are suppressed throughout:
	# what is being found is what a type requires, not what it was given.
	NodeGrid.measuring = true
	for scale in Design.SCALE_FACTORS.size():
		Design.ui_scale = scale
		var document := {"schema_version": 1, "metadata": {"name": "inventory"},
			"nodes": [], "connections": []}
		for i in placeable.size():
			(document["nodes"] as Array).append({"id": "n%d" % i, "type": placeable[i],
				"parameters": {},
				"position": {"x": float(i % 6) * 1100.0,
					"y": float(i / 6) * 900.0}})
		await main._load_text(JSON.stringify(document, "  "))
		await settle(18)
		main._set_roll_open(false)
		main.graph_edit.zoom = 1.0
		await settle(18)
		for i in placeable.size():
			var widget: GraphNode = main.widgets.get("n%d" % i)
			if widget == null:
				continue
			(record[placeable[i]]["narrowest"] as Array).append(await narrowest(widget))
	NodeGrid.measuring = false

	print("")
	print("%-22s %-20s %-11s %-9s %-6s %-8s %s" % ["registry key", "display name",
		"category", "class", "glyph", "needs", "status"])
	var buckets := {}
	var counts := {"MIGRATED": 0, "MIGRATED / RESERVED GLYPH": 0, "HELD": 0}
	for type: String in types:
		var entry: Dictionary = record[type]
		# Zero, not -1. Seeded at -1 the accumulator poisons itself on its own first
		# comparison and every type reports "none" — which is what the first run of this
		# said about all forty-nine of them.
		var worst := 0
		for one: int in entry["narrowest"]:
			worst = -1 if one < 0 or worst < 0 else maxi(worst, one)
		entry["needs"] = worst
		counts[entry["status"]] = int(counts[entry["status"]]) + 1
		print("%-22s %-20s %-11s %-9s %-6s %-8s %s" % [type,
			str(entry["display_name"]).substr(0, 20), str(entry["category"]).substr(0, 11),
			str(entry["width_class"]) if str(entry["width_class"]) != "" else "-",
			str(entry["glyph"]) if int(entry["glyph"]) >= 0 else "-",
			"none" if worst < 0 else str(worst), entry["status"]])
		if worst > 0:
			var bucket := int(worst / 40) * 40
			buckets[bucket] = int(buckets.get(bucket, 0)) + 1

	print("")
	print("%d runtime types: %d migrated, %d migrated with a reserved glyph, %d held"
		% [types.size(), counts["MIGRATED"], counts["MIGRATED / RESERVED GLYPH"],
			counts["HELD"]])
	print("registry runtime types = migrated + held: %s"
		% ("yes" if types.size() == counts["MIGRATED"]
			+ counts["MIGRATED / RESERVED GLYPH"] + counts["HELD"] else "NO"))

	print("")
	print("what the corpus actually requires, in base units:")
	var edges: Array = buckets.keys()
	edges.sort()
	for edge: int in edges:
		print("  %3d-%3d  %s (%d)" % [edge, edge + 39,
			"#".repeat(int(buckets[edge])), buckets[edge]])
	print("  the declared classes are %s" % str(NodeGrid.WIDTHS))

	var folder := OS.get_environment("INVENTORY_OUT")
	if folder.strip_edges() != "":
		DirAccess.make_dir_recursive_absolute(folder)
		var file := FileAccess.open(folder.path_join("inventory.json"), FileAccess.WRITE)
		file.store_string(JSON.stringify(record, "  "))
		file.close()
	quit()
