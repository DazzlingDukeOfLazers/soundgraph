extends SceneTree

## Derives the post-layout-pass fixtures the routing baseline is measured on.
##
## The state that matters for routing is the one where **every placement operation this
## programme is willing to make has already been asked and has answered**. For babble that
## is: the legalizer correctly does nothing, flow tidy finds one node, and route tidy takes
## it from nine crossings to seven and then declines. What is left is what placement cannot
## reach.
##
##   godot --headless --path editor-godot --script tidy_fixtures.gd
##
## Derived rather than edited in place. `babble.json` is a shipped example and
## `dense-graph-legalized.json` is a witness with its own provenance; overwriting either
## would destroy the evidence they carry. These are new files that say where they came from.

const PatchGraph := preload("res://patch_graph.gd")

const SOURCES := [
	["res://../examples/patches/babble.json", "qa/babble-tidied.json",
		"Babble, tidied",
		"babble after the whole layout pass has been applied and has stopped: the legalizer correctly moves nothing, flow tidy finds one node, and route tidy takes it from nine crossings to seven and then declines. Derived by editor-godot/tidy_fixtures.gd. What remains is what placement cannot reach, which is what makes it the routing pass's hostile specimen."],
	["res://qa/dense-graph-legalized.json", "qa/dense-graph-tidied.json",
		"Dense QA, tidied",
		"The legalized hostile patch after flow tidy and route tidy. Derived by editor-godot/tidy_fixtures.gd. Kept beside the legalized witness rather than replacing it, so the cost of each operation stays separable."],
]

var main: Node
var graph: GraphEdit


func settle(n: int) -> void:
	for i in n:
		await process_frame


func _initialize() -> void:
	Settings.isolate()
	DisplayServer.window_set_size(Vector2i(1920, 1200))
	root.content_scale_size = Vector2i(1920, 1200)
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	await settle(16)
	graph = main.graph_edit
	main._choose_detail_mode(PatchGraph.DetailMode.ADAPTIVE)

	for entry: Array in SOURCES:
		var file := FileAccess.open(str(entry[0]), FileAccess.READ)
		if file == null:
			continue
		var source := file.get_as_text()
		await main._load_text(source)
		await settle(24)
		main._set_roll_open(false)
		graph.zoom = 1.0
		await settle(10)

		# In product order, and reported stage by stage. The operations interact — flow
		# tidy changes the arrangement route tidy then searches — and a single before-and-
		# after figure would hide which one did what.
		var before: int = main._layout_crossings()
		# Both orders, to a fixed point, and the better one kept.
		#
		# The operations are not commutative and it costs a crossing. Route tidy on its own
		# takes babble from nine to seven; run after flow tidy it can do nothing, because
		# flow moves a node without changing any crossing and that move removes the two
		# forty-unit route wins that had been available. Converging in product order lands
		# at eight.
		#
		# The fixture has to be the best placement can reach rather than the best one
		# ordering happens to reach, because the whole claim it exists to support is that
		# the router is not being asked to compensate for a layout problem. So both orders
		# run to their own fixed points, the better is kept, and the difference is recorded
		# rather than smoothed over.
		var best: Dictionary = {}
		var best_crossings := 1 << 30
		var trail: Array = []
		for order in 2:
			await main._load_text(source)
			await settle(24)
			main._set_roll_open(false)
			graph.zoom = 1.0
			await settle(10)
			for pass_number in 5:
				var was := {}
				for id in main.widgets:
					was[str(id)] = (main.widgets[id] as GraphNode).position_offset
				await main._legalize_layout()
				await settle(10)
				if order == 0:
					await main._tidy_flow()
					await settle(10)
					await main._tidy_routes()
				else:
					await main._tidy_routes()
					await settle(10)
					await main._tidy_flow()
				await settle(10)
				var stirred := 0
				for id: String in was:
					if (was[id] as Vector2).distance_to(
							(main.widgets[id] as GraphNode).position_offset) > 0.5:
						stirred += 1
				if stirred == 0:
					break
			var reached: int = main._layout_crossings()
			trail.append("%s %d" % ["flow first" if order == 0 else "routes first",
				reached])
			if reached < best_crossings:
				best_crossings = reached
				best = {}
				for id in main.widgets:
					best[str(id)] = (main.widgets[id] as GraphNode).position_offset
		print("  %s - opened %d, %s" % [str(entry[0]).get_file(), before,
			", ".join(trail)])

		var document: Dictionary = JSON.parse_string(source)
		document["metadata"]["name"] = str(entry[2])
		document["metadata"]["description"] = str(entry[3])
		var moved := 0
		for node: Dictionary in document["nodes"]:
			var id := str(node["id"])
			if not main.widgets.has(id):
				continue
			var at: Vector2 = best.get(id,
				(main.widgets[id] as GraphNode).position_offset)
			var was := Vector2(float(node.get("position", {}).get("x", 0.0)),
				float(node.get("position", {}).get("y", 0.0)))
			if was.distance_to(at) > 0.5:
				moved += 1
			node["position"] = {"x": at.x, "y": at.y}
		var out := FileAccess.open(
			ProjectSettings.globalize_path("res://").path_join(str(entry[1])),
			FileAccess.WRITE)
		out.store_string(JSON.stringify(document, "  "))
		out.close()
		print("%s: %d -> %d crossings, %d nodes differ from the source -> %s"
			% [str(entry[0]).get_file(), before, best_crossings, moved, str(entry[1])])
	quit()
