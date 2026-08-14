extends SceneTree
## One-off: builds the filter+envelope combo and saves it as an example.
##
## The factoring goes through ModuleAuthor.collapse, the same call the Graph tab makes, so
## the definition and its derived surface are what somebody selecting the pair would get —
## and if that path breaks, this refuses to produce a file rather than producing a
## plausible one. The face is written as a panel object, which is what the wand's drag
## writes one knob at a time.

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

	# collapse names a fresh definition "part", and the instance after it, so both arrive
	# as the same placeholder. Renamed here by hand rather than through the editor: this
	# generator owns the whole document at this point, and nothing else points at it yet.
	var definition: Dictionary = main.patch["modules"][result.module_name]
	main.patch["modules"].erase(result.module_name)
	main.patch["modules"]["filter_env"] = definition
	for node in main.patch["nodes"]:
		if str(node.get("module", "")) == result.module_name:
			node["module"] = "filter_env"
		# The instance collapse made is named after the definition, so it carries the
		# placeholder too — and a file where the one node is called "part" reads as
		# unfinished whatever its module is called.
		if str(node["id"]) == result.instance_id:
			node["id"] = "filter_env"
	for connection in main.patch.get("connections", []):
		for end in ["from", "to"]:
			if str(connection[end]["node"]) == result.instance_id:
				connection[end]["node"] = "filter_env"

	print("derived surface: %s" % str(definition.get("parameters", [])
		.map(func(p): return str(p["name"]))))
	print("derived ports: in %s out %s"
		% [str(definition.get("inputs", []).map(func(p): return str(p["name"]))),
			str(definition.get("outputs", []).map(func(p): return str(p["name"])))])

	# Two rows: what the filter is doing, then what the envelope is doing to it. `mode`
	# and `cutoff_sweep` come off the face and stay exported — a patch can still set them,
	# they are simply not what somebody plays. Written as a panel object directly, which
	# is what the wand's drag writes one knob at a time.
	var exported := {}
	for binding in definition.get("parameters", []):
		exported[str(binding["name"])] = true
	var rows := [["cutoff", "resonance"], ["attack", "decay", "sustain", "release"]]
	for row in rows:
		for name in row:
			if not exported.has(str(name)):
				printerr("%s is not exported; not writing a file" % str(name))
				quit(1)
				return
	definition["panel"] = {"rows": rows, "labels": {"cutoff": "Freq", "resonance": "Q"}}
	print("panel rows: %s" % str(rows))

	main.patch["metadata"] = {
		"name": "Filter envelope",
		"description": "A state-variable filter and an ADSR as one module: cutoff and "
			+ "resonance on the top row, the envelope shaping them underneath. Built "
			+ "by collapsing the pair and then arranging the face.",
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
