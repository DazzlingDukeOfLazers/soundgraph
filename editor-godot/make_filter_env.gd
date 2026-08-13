extends SceneTree
## One-off: builds the filter+envelope combo the way the builder does, and saves it.
##
## Driven through the real operations rather than by writing JSON — ModuleAuthor.collapse
## for the factoring, PanelBuilder's own list and to_panel() for the face — so what comes
## out is what somebody clicking through the tab would get, and if either path is broken
## this refuses to produce a file rather than producing a plausible one.

const OUT := "res://../examples/patches/filter-envelope.json"
const ModuleAuthor := preload("res://module_author.gd")


func _initialize() -> void:
	var main = load("res://main.tscn").instantiate()
	root.add_child(main)
	for i in 20:
		await process_frame

	# A plain patch first: keyboard, saw, filter swept by an envelope, out.
	main.patch = {
		"schema_version": 1,
		"metadata": {"name": "Filter envelope"},
		"nodes": [
			{"id": "kb", "type": "NoteInput", "position": {"x": 0, "y": 0}},
			{"id": "osc", "type": "SawOscillator", "parameters": {"frequency": 110},
				"position": {"x": 560, "y": 0}},
			{"id": "env", "type": "ADSR", "parameters": {"attack": 0.005, "decay": 0.35,
				"sustain": 0.25, "release": 0.4}, "position": {"x": 560, "y": 360}},
			{"id": "filter", "type": "StateVariableFilter",
				"parameters": {"cutoff": 800.0, "resonance": 0.6, "mode": 0,
					"cutoff_sweep": 0.0},
				"position": {"x": 1120, "y": 0}},
			{"id": "out", "type": "StereoOutput",
				"parameters": {"level": 0.8, "safety_limit": 1},
				"position": {"x": 1680, "y": 0}},
		],
		"connections": [
			{"from": {"node": "kb", "port": "frequency"},
				"to": {"node": "osc", "port": "frequency"}},
			{"from": {"node": "kb", "port": "gate"}, "to": {"node": "env", "port": "gate"}},
			{"from": {"node": "osc", "port": "out"}, "to": {"node": "filter", "port": "in"}},
			{"from": {"node": "env", "port": "out"},
				"to": {"node": "filter", "port": "cutoff_mod"}},
			{"from": {"node": "filter", "port": "out"},
				"to": {"node": "out", "port": "left"}},
			{"from": {"node": "filter", "port": "out"},
				"to": {"node": "out", "port": "right"}},
		],
	}

	# The Arrange-menu operation, called the way the menu calls it.
	var terminals: Array = []
	for type_name in main.registry:
		if str(main.registry[type_name].get("category", "")) == "Terminals":
			terminals.append(type_name)
	var result = ModuleAuthor.collapse(main.patch, ["env", "filter"], terminals)
	if not result.ok():
		printerr("collapse refused: %s" % result.error)
		quit(1)
		return
	main.patch = result.patch

	# collapse names a fresh definition "part". A combo people are meant to reach for
	# deserves a name, and renaming a definition is a key move plus the instances that
	# point at it — which is exactly why the builder should grow a rename field.
	var definition: Dictionary = main.patch["modules"][result.module_name]
	main.patch["modules"].erase(result.module_name)
	main.patch["modules"]["filter_env"] = definition
	for node in main.patch["nodes"]:
		if str(node.get("module", "")) == result.module_name:
			node["module"] = "filter_env"
	# And the instance, which collapse names after the definition and so also calls
	# "part". Nothing shows it on the panel — the face takes its title from the module —
	# but it is what the running order and every diagnostic say, and "part.filter" tells
	# a reader nothing about which part.
	for node in main.patch["nodes"]:
		if str(node.get("id", "")) == result.instance_id:
			node["id"] = "voice"
	for connection in main.patch["connections"]:
		if str(connection["from"]["node"]) == result.instance_id:
			connection["from"]["node"] = "voice"
		if str(connection["to"]["node"]) == result.instance_id:
			connection["to"]["node"] = "voice"
	main._synthesize_module_descriptors()
	await main._rebuild_view()

	print("derived surface: %s" % str(definition.get("parameters", [])
		.map(func(p): return str(p["name"]))))
	print("derived ports: in %s out %s"
		% [str(definition.get("inputs", []).map(func(p): return str(p["name"]))),
			str(definition.get("outputs", []).map(func(p): return str(p["name"])))])

	# Now the face, through the builder's own list rather than by writing a panel object.
	main.show_view("Builder")
	for i in 8:
		await process_frame
	var builder: PanelBuilder = main.builder
	builder.patch = main.patch
	builder.module_name = "filter_env"
	builder.rebuild()
	await process_frame

	# Two rows: what the filter is doing, then what the envelope is doing to it. `mode`
	# and `cutoff_sweep` come off the face and stay exported — a patch can still set them,
	# they are simply not what somebody plays.
	var face := {"cutoff": "Freq", "resonance": "Q"}
	var wanted := ["cutoff", "resonance", "attack", "decay", "sustain", "release"]
	var ordered: Array = []
	for name in wanted:
		for entry in builder._entries:
			if str(entry["name"]) == name:
				entry["on"] = true
				entry["caption"] = str(face.get(name, ""))
				entry["breaks"] = name == "cutoff" or name == "attack"
				ordered.append(entry)
	for entry in builder._entries:
		if not ordered.has(entry):
			entry["on"] = false
	builder._entries = ordered + builder._entries.filter(
		func(e): return not ordered.has(e))
	builder._commit("face")
	for i in 8:
		await process_frame

	var panel: Dictionary = main.patch["modules"]["filter_env"].get("panel", {})
	print("panel rows: %s" % str(panel.get("rows", [])))
	print("panel labels: %s" % str(panel.get("labels", {})))
	if panel.get("rows", []).size() != 2:
		printerr("the builder did not produce two rows; not writing a file")
		quit(1)
		return

	main.patch["metadata"] = {
		"name": "Filter envelope",
		"description": "A state-variable filter and an ADSR as one module: cutoff and "
			+ "resonance on the top row, the envelope shaping them underneath. Built "
			+ "through the Builder tab — collapse, then prune the face.",
		"tags": ["module", "panel"],
	}
	var file := FileAccess.open(OUT, FileAccess.WRITE)
	if file == null:
		printerr("could not write %s" % OUT)
		quit(1)
		return
	file.store_string(JSON.stringify(main.patch, "  ") + "\n")
	file.close()
	print("wrote %s" % OUT)
	quit(0)
