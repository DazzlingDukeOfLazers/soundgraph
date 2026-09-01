extends SceneTree

## Goal 3.0: what signal classes does this program actually have?
##
## Goal 3 asked the cable renderer to distinguish three classes and the hostile patch
## produced two — eighteen audio cables, seventeen control, zero event. Before a third
## visual grammar is drawn, the question is whether there is a third semantic class to draw.
##
## The invariant this establishes, and it is the point of the whole audit:
##
## > **Cable type is derived from signal semantics in the graph model, never inferred from
## > socket shape or colour.**
##
## That keeps the visual system downstream of the truth rather than repairing a taxonomy
## with paint. A cable that is amber because a socket is a square, on a port the runtime
## treats as a float stream, is a picture of something that is not there.
##
##   godot --headless --path editor-godot --script signal_audit.gd
##
## with SIGNAL_AUDIT_OUT naming a directory for the JSON.
##
## ## What the model says
##
## `dsp-core/include/soundgraph/types.h` is unambiguous, and it is the ground truth:
##
##     audio and control are both sample streams and interconvert freely.
##     event and note carry discrete messages and require an exact type match.
##
## So there are two *transport* classes and four declared types. `signal_types_compatible`
## enforces it: audio and control connect to each other freely, and event and note connect
## only to their own kind. The distinction is real in the runtime, not decorative.
##
## Which makes the question narrow. Every port on every runtime type is enumerated below
## with what it declares, what socket shape that produces, what colour, and what cable class
## — and the three possible answers are:
##
##   A  event is real and some ports are declared control by mistake     a data bug
##   B  event exists in the socket vocabulary and not in the model       do not draw it
##   C  event is real and deliberately transported as control            document it

## From main.gd, so the audit reports the shapes the editor actually cuts.
const HarnessExit := preload("res://harness_exit.gd")
const SHAPES := ["circle", "diamond", "square", "ring"]
const CLASSES := ["audio", "control", "event", "note"]

var main: Node


func out_dir() -> String:
	var asked := OS.get_environment("SIGNAL_AUDIT_OUT")
	return asked if asked != "" else ProjectSettings.globalize_path("res://")


func settle(n: int) -> void:
	for i in n:
		await process_frame


## The socket shape a declared type produces, by the editor's own mapping.
func shape_of(declared: String) -> String:
	match declared:
		"audio": return SHAPES[0]
		"control": return SHAPES[1]
		"event": return SHAPES[2]
	return SHAPES[3]


func _initialize() -> void:
	Settings.isolate()
	DisplayServer.window_set_size(Vector2i(1440, 900))
	root.content_scale_size = Vector2i(1440, 900)
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	await settle(16)

	var ports: Array = []
	var by_type := {}
	var by_node := {}
	for type_name: String in main.registry:
		var descriptor: Dictionary = main.registry[type_name]
		for side in ["inputs", "outputs"]:
			for port: Variant in descriptor.get(side, []):
				var entry: Dictionary = port
				# "control" is the registry's own fallback for a port that does not say,
				# and the audit has to be able to tell a declared control from an assumed
				# one — the difference is exactly answer A against answer C.
				var declared := str(entry.get("type", ""))
				var assumed := declared == ""
				if assumed:
					declared = "control"
				ports.append({
					"node": type_name, "port": str(entry.get("name", "")),
					"side": "in" if side == "inputs" else "out",
					"declared": declared, "assumed": assumed,
					"shape": shape_of(declared),
					"colour": str(Design.signal_colour(declared).to_html(false)),
				})
				by_type[declared] = int(by_type.get(declared, 0)) + 1
				if declared == "event" or declared == "note":
					if not by_node.has(type_name):
						by_node[type_name] = []
					by_node[type_name].append("%s %s"
						% [str(entry.get("name", "")), "in" if side == "inputs" else "out"])

	print("")
	print("%d ports across %d runtime types" % [ports.size(), main.registry.size()])
	print("")
	print("%-10s %8s %10s %12s   %s" % ["declared", "count", "shape", "colour",
		"transport"])
	for declared: String in CLASSES:
		if not by_type.has(declared):
			continue
		# The transport class, which is what the runtime actually distinguishes: audio and
		# control interconvert freely, event and note require an exact match.
		var transport := "stream" if declared == "audio" or declared == "control" \
			else "message"
		print("%-10s %8d %10s %12s   %s" % [declared, int(by_type[declared]),
			shape_of(declared), str(Design.signal_colour(declared).to_html(false)),
			transport])

	var assumed := 0
	for entry: Dictionary in ports:
		if bool(entry["assumed"]):
			assumed += 1
	print("")
	print("%d of those declare no type at all and fall back to control" % assumed)

	print("")
	print("types carrying a message port at all:")
	if by_node.is_empty():
		print("  none")
	for type_name: String in by_node:
		print("  %-20s %s" % [type_name, ", ".join(by_node[type_name])])

	# And what the hostile patch actually contains, since that is where goal 3 stalled.
	var file := FileAccess.open("res://qa/dense-graph.json", FileAccess.READ)
	var used := {}
	if file != null:
		await main._load_text(file.get_as_text())
		await settle(20)
		for connection in main.graph_edit.get_connection_list():
			var widget := main.graph_edit.get_node_or_null(
				NodePath(str(connection["from_node"]))) as GraphNode
			if widget == null:
				continue
			var slot := int(widget.get_output_port_type(int(connection["from_port"])))
			used[CLASSES[clampi(slot, 0, 3)]] = int(used.get(
				CLASSES[clampi(slot, 0, 3)], 0)) + 1
	print("")
	print("cables in the hostile patch, by class: %s" % str(used))

	var record := {"ports": ports, "by_declared": by_type, "assumed": assumed,
		"message_ports": by_node, "dense_graph_cables": used}
	var folder := out_dir()
	DirAccess.make_dir_recursive_absolute(folder)
	var out := FileAccess.open(folder.path_join("signal-taxonomy.json"), FileAccess.WRITE)
	out.store_string(JSON.stringify(record, "  "))
	out.close()
	print("")
	print("-> %s" % folder.path_join("signal-taxonomy.json"))
	await HarnessExit.finish(self, main)
