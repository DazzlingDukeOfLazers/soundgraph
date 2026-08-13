extends RefCounted
## Turns wiring into notation: the authoring half of docs/modules-design.md, stage 3.
##
## Two entry points, one builder. `collapse()` takes a selection inside the current
## patch and factors it into a definition plus one instance — the inverse of what
## patch-io's expansion does, which is exactly what the stage-3 exit test holds it to:
## collapse, save, load, expand, and the wiring comes back identical. `from_patch()`
## takes a *foreign* patch and does what the copy-import never could: keeps it one
## thing. Its terminals become the declared ports, because the edges where a NoteInput
## and a StereoOutput used to be are precisely where the outside world was always
## attached.
##
## The declared surface is derived, not designed: boundary connections become ports
## named after the port they land on, and every parameter the author explicitly set
## becomes an exported knob. That errs toward exporting too much — but a surface you
## prune is authorship, and a surface you have to build by hand is homework.

## What a collapse or import produced, or why it refused.
class Result extends RefCounted:
	var patch: Dictionary = {}
	var module_name := ""
	var instance_id := ""
	var error := ""

	func ok() -> bool:
		return error.is_empty()


## Factors `selected` node ids out of `patch` into a module definition and an instance.
## `terminal_types` names the node types that may not live inside a module (the
## caller reads them from the registry's Terminals category — this class stays
## registry-blind).
##
## `nominated` is an optional surface the author picked by hand, in the order they picked
## it: an array of {"kind": "input"|"output"|"parameter", "node": id, "port"/"parameter":
## name}. Given one, it is used verbatim and nothing is derived — which is the difference
## between a module whose face was designed and one whose face was inferred. The order
## survives into the panel, because the order somebody clicked things in is the only
## statement of intent available at that moment and throwing it away to re-derive one
## would be perverse.
##
## Left empty, everything below derives as it always has: boundary connections become
## ports, authored parameters become knobs. That is still the right answer for collapsing
## a working circuit, where the wiring already says where the edges are.
static func collapse(patch: Dictionary, selected: Array, terminal_types: Array,
		nominated: Array = []) -> Result:
	var result := Result.new()
	if selected.size() < 2:
		result.error = "select two or more nodes to collapse into a module"
		return result

	var chosen := {}
	for id in selected:
		chosen[str(id)] = true
	var inner_nodes: Array = []
	for node in patch.get("nodes", []):
		if not chosen.has(str(node["id"])):
			continue
		if str(node.get("type", "")) == "module":
			result.error = "modules may not contain modules yet — see docs/modules-design.md"
			return result
		if terminal_types.has(str(node.get("type", ""))):
			result.error = "%s is a terminal; a module is a subcircuit, not a finished patch" \
				% str(node["id"])
			return result
		inner_nodes.append(node.duplicate(true))
	if inner_nodes.size() != selected.size():
		result.error = "selection includes nodes the document does not"
		return result

	result.module_name = _unique_name("part", patch.get("modules", {}).keys())
	result.instance_id = _unique_name(result.module_name,
		patch.get("nodes", []).map(func(n): return str(n["id"])))

	var internal: Array = []
	var inputs: Array = []            # declared input bindings
	var outputs: Array = []           # declared output bindings
	var exported: Array = []          # declared parameter bindings
	var instance_parameters := {}
	var rewritten: Array = []         # the document's connections, post-collapse
	var inner_by_id := {}
	for node in inner_nodes:
		inner_by_id[str(node["id"])] = node

	# ---- the author's own surface, first and in the order they picked it -------------
	# Before the boundary analysis rather than after, so a connection crossing the edge
	# onto a port they already nominated finds that binding and reuses its name instead
	# of declaring a second port for the same place. It also means the panel needs no
	# statement of its own: declared order is click order, and the face is drawn in
	# declared order.
	for pick: Dictionary in nominated:
		var pick_node := str(pick.get("node", ""))
		if not chosen.has(pick_node):
			continue
		match str(pick.get("kind", "")):
			"input":
				_binding_name(inputs, pick_node, str(pick.get("port", "")))
			"output":
				_binding_name(outputs, pick_node, str(pick.get("port", "")))
			"parameter":
				var parameter := str(pick.get("parameter", ""))
				var export_name := _export_for(exported, instance_parameters, pick_node,
					parameter)
				var authored: Variant = inner_by_id.get(pick_node, {}) \
					.get("parameters", {}).get(parameter, null)
				if authored != null:
					instance_parameters[export_name] = authored

	# ---- boundary analysis: connections crossing the selection edge become ports -----
	# A boundary connection still declares a port even when the author nominated a
	# surface and left this one out. The alternative is dropping a cable somebody had
	# wired, which is a worse answer than a module having one more port than was asked
	# for — and the port is genuinely needed, because something is plugged into it.
	for connection in patch.get("connections", []):
		var from_in: bool = chosen.has(str(connection["from"]["node"]))
		var to_in: bool = chosen.has(str(connection["to"]["node"]))
		if from_in and to_in:
			internal.append(connection.duplicate(true))
			continue
		if not from_in and not to_in:
			rewritten.append(connection.duplicate(true))
			continue
		var copy: Dictionary = connection.duplicate(true)
		if to_in:
			var port_name := _binding_name(inputs, str(connection["to"]["node"]),
				str(connection["to"]["port"]))
			copy["to"] = {"node": result.instance_id, "port": port_name}
		else:
			var port_name := _binding_name(outputs, str(connection["from"]["node"]),
				str(connection["from"]["port"]))
			copy["from"] = {"node": result.instance_id, "port": port_name}
		rewritten.append(copy)

	# ---- exports: every knob the author had touched --------------------------------
	# Only when they nominated nothing. "Every parameter that was set" is a good guess at
	# what matters and a bad substitute for being told: it is the rule that makes a
	# collapsed module arrive with thirty knobs. Where there is a nomination, it is the
	# whole answer.
	if nominated.is_empty():
		for node in inner_nodes:
			for parameter_name in node.get("parameters", {}):
				var export_name := str(parameter_name)
				for existing in exported:
					if existing["name"] == export_name:
						export_name = "%s_%s" % [str(node["id"]), parameter_name]
						break
				exported.append({"name": export_name, "node": str(node["id"]),
					"parameter": str(parameter_name)})
				instance_parameters[export_name] = node["parameters"][parameter_name]

	# ---- controls and automation follow their targets through the facade -------------
	# First Synth's cutoff knob targets the filter; after the filter moves inside a
	# module, the knob must target the instance's exported parameter instead. A target
	# whose parameter was never authored gets exported on demand — a control is as
	# strong a claim of "this knob matters" as a set value is.
	var remapped_controls: Array = []
	for control in patch.get("controls", []):
		var copy: Dictionary = control.duplicate(true)
		var target: Dictionary = copy.get("target", {})
		if chosen.has(str(target.get("node", ""))):
			var export_name := _export_for(exported, instance_parameters,
				str(target["node"]), str(target.get("parameter", "")))
			copy["target"] = {"node": result.instance_id, "parameter": export_name}
		remapped_controls.append(copy)
	var remapped_automation: Array = []
	for lane in patch.get("automation", []):
		var copy: Dictionary = lane.duplicate(true)
		var target: Dictionary = copy.get("target", {})
		if chosen.has(str(target.get("node", ""))):
			var export_name := _export_for(exported, instance_parameters,
				str(target["node"]), str(target.get("parameter", "")))
			copy["target"] = {"node": result.instance_id, "parameter": export_name}
		remapped_automation.append(copy)

	# ---- the reshaped document -------------------------------------------------------
	var out: Dictionary = patch.duplicate(true)
	out["schema_version"] = maxi(int(patch.get("schema_version", 1)), 2)
	if not out.has("modules"):
		out["modules"] = {}
	var definition := {
		"nodes": inner_nodes,
		"connections": internal,
	}
	if not inputs.is_empty():
		definition["inputs"] = inputs
	if not outputs.is_empty():
		definition["outputs"] = outputs
	if not exported.is_empty():
		definition["parameters"] = exported
	out["modules"][result.module_name] = definition

	var new_nodes: Array = []
	var instance_placed := false
	for node in patch.get("nodes", []):
		if not chosen.has(str(node["id"])):
			new_nodes.append(node.duplicate(true))
			continue
		if instance_placed:
			continue
		instance_placed = true
		var instance := {
			"id": result.instance_id,
			"type": "module",
			"module": result.module_name,
		}
		if not instance_parameters.is_empty():
			instance["parameters"] = instance_parameters
		if node.has("position"):
			instance["position"] = node["position"].duplicate(true)
		new_nodes.append(instance)
	out["nodes"] = new_nodes
	out["connections"] = rewritten
	if not remapped_controls.is_empty():
		out["controls"] = remapped_controls
	if not remapped_automation.is_empty():
		out["automation"] = remapped_automation
	result.patch = out
	return result


## Adds a foreign patch to `patch` as a definition plus one instance. The foreign
## patch's terminals become the declared surface: an edge from its NoteInput is an
## input, an edge into its StereoOutput is an output.
static func from_patch(patch: Dictionary, foreign: Dictionary, name_hint: String,
		terminal_types: Array) -> Result:
	var result := Result.new()
	var terminals := {}
	var inner_nodes: Array = []
	for node in foreign.get("nodes", []):
		if str(node.get("type", "")) == "module":
			result.error = "that patch already uses modules; nesting is not supported yet"
			return result
		if terminal_types.has(str(node.get("type", ""))):
			terminals[str(node["id"])] = true
		else:
			inner_nodes.append(node.duplicate(true))
	if inner_nodes.size() < 1:
		result.error = "that patch has nothing but terminals"
		return result

	var internal: Array = []
	var inputs: Array = []
	var outputs: Array = []
	for connection in foreign.get("connections", []):
		var from_terminal: bool = terminals.has(str(connection["from"]["node"]))
		var to_terminal: bool = terminals.has(str(connection["to"]["node"]))
		if from_terminal and to_terminal:
			continue
		if not from_terminal and not to_terminal:
			internal.append(connection.duplicate(true))
			continue
		if from_terminal:
			# The outside used to feed this port; name the input after what fed it,
			# because "frequency" and "gate" say what to plug in and "in" does not.
			_binding_name(inputs, str(connection["to"]["node"]),
				str(connection["to"]["port"]), str(connection["from"]["port"]))
		else:
			_binding_name(outputs, str(connection["from"]["node"]),
				str(connection["from"]["port"]))

	var exported: Array = []
	for node in inner_nodes:
		for parameter_name in node.get("parameters", {}):
			var export_name := str(parameter_name)
			for existing in exported:
				if existing["name"] == export_name:
					export_name = "%s_%s" % [str(node["id"]), parameter_name]
					break
			exported.append({"name": export_name, "node": str(node["id"]),
				"parameter": str(parameter_name)})

	var out: Dictionary = patch.duplicate(true)
	out["schema_version"] = maxi(int(patch.get("schema_version", 1)), 2)
	if not out.has("modules"):
		out["modules"] = {}
	result.module_name = _unique_name(name_hint if name_hint != "" else "module",
		out["modules"].keys())
	var definition := {
		"nodes": inner_nodes,
		"connections": internal,
	}
	var description := str(foreign.get("metadata", {}).get("description", ""))
	if description != "":
		definition["description"] = description
	if not inputs.is_empty():
		definition["inputs"] = inputs
	if not outputs.is_empty():
		definition["outputs"] = outputs
	if not exported.is_empty():
		definition["parameters"] = exported
	out["modules"][result.module_name] = definition

	result.instance_id = _unique_name(result.module_name,
		out.get("nodes", []).map(func(n): return str(n["id"])))
	out["nodes"].append({
		"id": result.instance_id,
		"type": "module",
		"module": result.module_name,
		"position": {"x": 0.0, "y": 0.0},
	})
	result.patch = out
	return result


## The exported name for an inner (node, parameter), exporting on demand.
static func _export_for(exported: Array, instance_parameters: Dictionary,
		node_id: String, parameter: String) -> String:
	for entry in exported:
		if entry["node"] == node_id and entry["parameter"] == parameter:
			return str(entry["name"])
	var export_name := parameter
	for entry in exported:
		if entry["name"] == export_name:
			export_name = "%s_%s" % [node_id, parameter]
			break
	exported.append({"name": export_name, "node": node_id, "parameter": parameter})
	return export_name


## Finds or creates the declared port for an (inner node, port) pair. Bindings are
## deduplicated — two outside sources feeding one inner port share one declared input,
## which is what keeps summing semantics identical after expansion.
static func _binding_name(bindings: Array, node_id: String, port: String,
		preferred := "") -> String:
	for binding in bindings:
		if binding["node"] == node_id and binding["port"] == port:
			return binding["name"]
	var name := preferred if preferred != "" else port
	for binding in bindings:
		if binding["name"] == name:
			name = "%s_%s" % [node_id, port]
			break
	bindings.append({"name": name, "node": node_id, "port": port})
	return name


static func _unique_name(base: String, taken: Array) -> String:
	if not taken.has(base):
		return base
	var counter := 2
	while taken.has("%s-%d" % [base, counter]):
		counter += 1
	return "%s-%d" % [base, counter]
