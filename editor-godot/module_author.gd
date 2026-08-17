extends RefCounted
const Seams := preload("res://seams.gd")
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
	## What an expansion freed, and what the definition declared before it went. The two
	## together are everything a caller needs to put the module back exactly as it was —
	## which is what makes opening one a view rather than a decision.
	var members: Array = []
	var surface: Dictionary = {}

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
	# The surface, drawn rather than listed.
	#
	# A port used to be an entry in `inputs` saying "gate means env.gate inside". It is now
	# an Input node inside the definition, wired to env.gate — the same fact, in the place
	# the fact is about. Nothing downstream changes: patch-io resolves a port by looking
	# for a seam of that name before it looks in a list, and expansion splices the seam out
	# exactly as it consumed the binding.
	#
	# What it buys is that the boundary is visible from inside. Opening a module now shows
	# its own edges, which is the one part of a subcircuit you need to see while you are
	# wiring in it, and the order they sit in is the port order — so nothing else has to
	# carry that.
	var definition := {
		"nodes": inner_nodes,
		"connections": internal,
	}
	_draw_ports(definition, inputs, outputs)
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


## Turns derived port bindings into the seam nodes that are those ports.
##
## Ids are the port names, because that is what patch-io reads a seam's port name from and
## a second field saying the same thing is a second field to disagree with. Where a port
## name collides with an inner node the seam is qualified instead — a module with a port
## called "gate" and a node called "gate" is not far-fetched, and two nodes with one id is
## a document nothing can load.
static func _draw_ports(definition: Dictionary, inputs: Array, outputs: Array) -> void:
	var nodes: Array = definition["nodes"]
	var connections: Array = definition["connections"]
	var taken := {}
	for node in nodes:
		taken[str(node["id"])] = true

	for side in [[inputs, "Input"], [outputs, "Output"]]:
		for binding: Dictionary in side[0]:
			var seam_id := str(binding["name"])
			if taken.has(seam_id):
				seam_id = _unique_name("%s_port" % str(binding["name"]), taken.keys())
			taken[seam_id] = true
			var seam := {"id": seam_id, "type": str(side[1])}
			# The name carries the port's name when the id could not, so what a patch
			# plugs into is still what the author asked for.
			if seam_id != str(binding["name"]):
				seam["name"] = str(binding["name"])
			nodes.append(seam)
			if str(side[1]) == "Input":
				connections.append({
					"from": {"node": seam_id, "port": "out"},
					"to": {"node": str(binding["node"]), "port": str(binding["port"])},
				})
			else:
				connections.append({
					"from": {"node": str(binding["node"]), "port": str(binding["port"])},
					"to": {"node": seam_id, "port": "in"},
				})


## Puts an instance's insides back on the canvas: the exact inverse of `collapse`.
##
## Not a rendering trick. A module and the nodes it stands for are two notations for one
## graph — that is the claim the stage-3 exit test holds in rendered bytes — so "look
## inside this module" can be the document changing notation rather than the editor
## learning to draw a thing that is not there. Everything else in the editor goes on
## working because what it is looking at is, either way, an ordinary patch.
##
## Inner nodes come back under `instance.inner`, the separator expansion already uses, so
## two instances of one definition can be open at once without their nodes colliding. They
## come back at the positions the definition kept for them — collapse copied those verbatim
## out of the document, so opening a module puts its parts where they were.
##
## The definition stays, even when this was its last instance, and that is the whole of
## how an open module is written down: a definition nothing points at, plus nodes named
## after it. Nothing else has to be remembered anywhere — not in the editor, not in a new
## corner of the file — so an open module survives being saved and reopened, and closing it
## again finds its ports, its exports and its face exactly where it left them.
##
## `keep_definition` false is the other operation, for a caller that means "take this apart
## and stop calling it a thing". Nothing does yet; the argument is here so that when
## something does, it does not have to be told twice.
##
## `Result.surface` carries what was declared either way.
static func expand(patch: Dictionary, instance_id: String,
		keep_definition: bool = true) -> Result:
	var result := Result.new()
	var instance := {}
	for node in patch.get("nodes", []):
		if str(node["id"]) == instance_id:
			instance = node
			break
	if instance.is_empty() or str(instance.get("type", "")) != "module":
		result.error = "%s is not a module instance" % instance_id
		return result
	result.module_name = str(instance.get("module", ""))
	var definition: Dictionary = patch.get("modules", {}).get(result.module_name, {})
	if definition.is_empty():
		result.error = "no definition called '%s'" % result.module_name
		return result
	result.instance_id = instance_id

	var inner_id := func(name: String) -> String:
		return "%s.%s" % [instance_id, name]

	# The values this instance had set, pushed down onto the nodes they belonged to. An
	# instance's parameters are overrides of the definition's own defaults, so on the way
	# out they stop being overrides and become the value.
	var values: Dictionary = instance.get("parameters", {})
	var by_export := {}
	for binding in definition.get("parameters", []):
		by_export[str(binding["name"])] = binding

	# Seams do not come back. A module's seam is its edge, and once the module is open
	# there is no edge — it is the top level, where the scope rule says a seam must carry a
	# host binding. Freeing them would produce a document the loader refuses, which is a
	# strong hint that it would not have meant anything either. So they are spliced exactly
	# as expansion splices them, and drawn again by close_module from the ports it works
	# out. The names survive because those ports keep them.
	var freed: Array = []
	for node in definition.get("nodes", []):
		if Seams.is_port_seam(node):
			continue
		var copy: Dictionary = node.duplicate(true)
		copy["id"] = inner_id.call(str(node["id"]))
		freed.append(copy)
	var by_inner := {}
	for node in freed:
		by_inner[str(node["id"])] = node
	for export_name in values:
		var binding: Dictionary = by_export.get(str(export_name), {})
		if binding.is_empty():
			continue
		var target: Dictionary = by_inner.get(inner_id.call(str(binding["node"])), {})
		if target.is_empty():
			continue
		if not target.has("parameters"):
			target["parameters"] = {}
		target["parameters"][str(binding["parameter"])] = values[export_name]

	# Where each declared port actually lands, so the cables outside can be re-aimed at it.
	var ports := {}
	for side in ["inputs", "outputs"]:
		for binding in Seams.declared_ports(definition, side == "outputs"):
			ports["%s/%s" % [side, str(binding["name"])]] = {
				"node": inner_id.call(str(binding["node"])), "port": str(binding["port"])}

	var seam_ids := {}
	for node in definition.get("nodes", []):
		if Seams.is_port_seam(node):
			seam_ids[str(node["id"])] = true
	var connections: Array = []
	for connection in definition.get("connections", []):
		# The wire from a seam to what it feeds is the splice instruction, not a wire.
		if seam_ids.has(str(connection["from"]["node"])) 				or seam_ids.has(str(connection["to"]["node"])):
			continue
		connections.append({
			"from": {"node": inner_id.call(str(connection["from"]["node"])),
				"port": str(connection["from"]["port"])},
			"to": {"node": inner_id.call(str(connection["to"]["node"])),
				"port": str(connection["to"]["port"])},
		})
	for connection in patch.get("connections", []):
		var copy: Dictionary = connection.duplicate(true)
		# A cable landing on a port the definition never declared is dropped rather than
		# left pointing at a node that has stopped existing. It cannot happen from a
		# document this editor wrote; it can happen from one somebody edited by hand.
		if str(copy["to"]["node"]) == instance_id:
			var landing: Dictionary = ports.get("inputs/%s" % str(copy["to"]["port"]), {})
			if landing.is_empty():
				continue
			copy["to"] = landing.duplicate()
		if str(copy["from"]["node"]) == instance_id:
			var leaving: Dictionary = ports.get("outputs/%s" % str(copy["from"]["port"]), {})
			if leaving.is_empty():
				continue
			copy["from"] = leaving.duplicate()
		connections.append(copy)

	var out: Dictionary = patch.duplicate(true)
	var new_nodes: Array = []
	for node in patch.get("nodes", []):
		if str(node["id"]) == instance_id:
			new_nodes.append_array(freed)
			continue
		new_nodes.append(node.duplicate(true))
	out["nodes"] = new_nodes
	out["connections"] = connections

	# Controls and automation follow their target back down through the facade, the same
	# remapping collapse does on the way up and for the same reason: a knob that stops
	# reaching what it drives is a patch that has quietly lost a control.
	for list_key in ["controls", "automation"]:
		var kept: Array = []
		for item in out.get(list_key, []):
			var copy: Dictionary = item.duplicate(true)
			var target: Dictionary = copy.get("target", {})
			if str(target.get("node", "")) == instance_id:
				var binding: Dictionary = by_export.get(str(target.get("parameter", "")), {})
				if binding.is_empty():
					continue
				copy["target"] = {"node": inner_id.call(str(binding["node"])),
					"parameter": str(binding["parameter"])}
			kept.append(copy)
		if out.has(list_key):
			out[list_key] = kept

	result.surface = {
		"inputs": Seams.declared_ports(definition, false),
		"outputs": Seams.declared_ports(definition, true),
		"parameters": definition.get("parameters", []).duplicate(true),
		"panel": (definition.get("panel", {}) as Dictionary).duplicate(true),
	}
	if not keep_definition:
		var still_used := false
		for node in out["nodes"]:
			if str(node.get("module", "")) == result.module_name:
				still_used = true
		if not still_used:
			(out["modules"] as Dictionary).erase(result.module_name)
			if (out["modules"] as Dictionary).is_empty():
				out.erase("modules")
				out["schema_version"] = 1
	result.patch = out
	result.members = freed.map(func(n): return str(n["id"]))
	return result


## Folds an open module shut again: the other direction of `expand`, and not a new
## authoring decision.
##
## `collapse` is the wrong tool for this even though the shapes rhyme. Collapse invents a
## name, works out a surface and produces a module that did not exist. Closing has all
## three already — they are in the definition the open state left sitting in the file —
## and its job is to put the parts back inside the thing they came out of without changing
## a single declaration. Reusing collapse here would mean renaming the result back
## afterwards and hoping its derived port names happened to match the declared ones, which
## for an imported module they do not.
##
## Whatever was moved, retuned or rewired inside while it was open comes with. That is the
## point of opening one.
static func close_module(patch: Dictionary, module_name: String) -> Result:
	var result := Result.new()
	result.module_name = module_name
	var definition: Dictionary = patch.get("modules", {}).get(module_name, {})
	if definition.is_empty():
		result.error = "no definition called '%s'" % module_name
		return result
	var prefix := module_name + "."

	var inside := {}
	var inner_nodes: Array = []
	for node in patch.get("nodes", []):
		if not str(node["id"]).begins_with(prefix):
			continue
		inside[str(node["id"])] = true
		var copy: Dictionary = node.duplicate(true)
		copy["id"] = str(node["id"]).substr(prefix.length())
		inner_nodes.append(copy)
	if inner_nodes.is_empty():
		result.error = "'%s' has no parts on the canvas to fold back in" % module_name
		return result
	result.instance_id = _unique_name(module_name,
		patch.get("nodes", []).filter(func(n): return not inside.has(str(n["id"]))) \
			.map(func(n): return str(n["id"])))

	# Values that were turned while it was open become the instance's again, and the
	# definition keeps whatever it had as its own default. An export whose knob was never
	# set carries nothing, which is how it was before it was opened.
	var instance_parameters := {}
	var by_id := {}
	for node in inner_nodes:
		by_id[str(node["id"])] = node
	for binding in definition.get("parameters", []):
		var owner: Dictionary = by_id.get(str(binding["node"]), {})
		var value: Variant = owner.get("parameters", {}).get(str(binding["parameter"]), null)
		if value != null:
			instance_parameters[str(binding["name"])] = value

	# Where each declared port sits on the canvas right now, so a cable landing there can
	# be re-aimed at the instance under the name the definition gave it.
	var named := {}
	for side in ["inputs", "outputs"]:
		for binding in Seams.declared_ports(definition, side == "outputs"):
			named["%s/%s.%s/%s" % [side, module_name, str(binding["node"]),
				str(binding["port"])]] = str(binding["name"])

	# The working copy is made before the loop that writes to it: declaring a port on
	# demand appends to the definition's own array, and `get("inputs", [])` on a definition
	# that has none hands back a fresh array nobody is holding.
	var out: Dictionary = patch.duplicate(true)
	var folded: Dictionary = (out["modules"] as Dictionary)[module_name]
	if not folded.has("parameters"):
		folded["parameters"] = []
	# Both spellings in, one spelling out.
	#
	# A port may be a binding in `inputs` or a port node drawn inside the definition, and
	# `named` above reads both through Seams.declared_ports. What redraws them below reads
	# only the binding lists — so seeding those lists from the same place is what stops the
	# two halves disagreeing. They did: a module whose ports were drawn as seams had them
	# named on the outside cables and declared nowhere, because `folded["nodes"]` is
	# replaced with what came back off the canvas a few lines down and the seams went with
	# the old array. The result was a document naming ports the definition did not have,
	# which the loader refuses — and which _apply reports and then quietly declines to load,
	# so the editor went on drawing a patch the engine had stopped following.
	folded["inputs"] = Seams.declared_ports(folded, false)
	folded["outputs"] = Seams.declared_ports(folded, true)

	var internal: Array = []
	var outside: Array = []
	for connection in patch.get("connections", []):
		var from_in: bool = inside.has(str(connection["from"]["node"]))
		var to_in: bool = inside.has(str(connection["to"]["node"]))
		if from_in and to_in:
			internal.append({
				"from": {"node": str(connection["from"]["node"]).substr(prefix.length()),
					"port": str(connection["from"]["port"])},
				"to": {"node": str(connection["to"]["node"]).substr(prefix.length()),
					"port": str(connection["to"]["port"])},
			})
			continue
		if not from_in and not to_in:
			outside.append(connection.duplicate(true))
			continue
		var copy: Dictionary = connection.duplicate(true)
		if to_in:
			var key := "inputs/%s/%s" % [str(connection["to"]["node"]),
				str(connection["to"]["port"])]
			# A cable wired to an inner port while the module was open, landing somewhere
			# the surface never declared, needs a port to survive — the same rule collapse
			# follows at a boundary, and for the same reason: something is plugged in.
			if not named.has(key):
				named[key] = _binding_name(folded["inputs"],
					str(connection["to"]["node"]).substr(prefix.length()),
					str(connection["to"]["port"]))
			copy["to"] = {"node": result.instance_id, "port": named[key]}
		else:
			var key := "outputs/%s/%s" % [str(connection["from"]["node"]),
				str(connection["from"]["port"])]
			if not named.has(key):
				named[key] = _binding_name(folded["outputs"],
					str(connection["from"]["node"]).substr(prefix.length()),
					str(connection["from"]["port"]))
			copy["from"] = {"node": result.instance_id, "port": named[key]}
		outside.append(copy)

	folded["nodes"] = inner_nodes
	folded["connections"] = internal
	# Ports drawn again, from the names this fold worked out. The seams went when the
	# module was opened; this is where they come back, and going through the same helper
	# collapse uses is what keeps a module folded twice identical to one folded once.
	_draw_ports(folded, folded.get("inputs", []), folded.get("outputs", []))
	# Emptied rather than erased: the tidy-up below turns an empty surface into no key at
	# all, and reaching for a key this line had just removed is how the first attempt died.
	folded["inputs"] = []
	folded["outputs"] = []

	var new_nodes: Array = []
	var placed := false
	for node in patch.get("nodes", []):
		if not inside.has(str(node["id"])):
			new_nodes.append(node.duplicate(true))
			continue
		if placed:
			continue
		placed = true
		var instance := {"id": result.instance_id, "type": "module", "module": module_name}
		if not instance_parameters.is_empty():
			instance["parameters"] = instance_parameters
		if node.has("position"):
			instance["position"] = node["position"].duplicate(true)
		new_nodes.append(instance)
	out["nodes"] = new_nodes
	out["connections"] = outside

	var exports := {}
	for binding in definition.get("parameters", []):
		exports["%s%s/%s" % [prefix, str(binding["node"]), str(binding["parameter"])]] = \
			str(binding["name"])
	for list_key in ["controls", "automation"]:
		var kept: Array = []
		for item in out.get(list_key, []):
			var copy: Dictionary = item.duplicate(true)
			var target: Dictionary = copy.get("target", {})
			if inside.has(str(target.get("node", ""))):
				var key := "%s/%s" % [str(target["node"]), str(target.get("parameter", ""))]
				if not exports.has(key):
					# Same argument as the port above: a control aimed at an inner knob is
					# as strong a claim that the knob matters as a value set on it.
					var inner := str(target["node"]).substr(prefix.length())
					exports[key] = _export_for(folded["parameters"],
						instance_parameters, inner, str(target["parameter"]))
				copy["target"] = {"node": result.instance_id, "parameter": exports[key]}
			kept.append(copy)
		if out.has(list_key):
			out[list_key] = kept

	# A surface with nothing in it is written as nothing, not as an empty list. "This
	# module declares no inputs" and "this module declares an empty list of inputs" are the
	# same fact, and a document should have one spelling for one fact.
	for key in ["inputs", "outputs", "parameters"]:
		if (folded[key] as Array).is_empty():
			folded.erase(key)
	out["schema_version"] = maxi(int(patch.get("schema_version", 1)), 2)
	result.patch = out
	result.surface = {
		"inputs": Seams.declared_ports(folded, false),
		"outputs": Seams.declared_ports(folded, true),
		"parameters": folded.get("parameters", []).duplicate(true),
	}
	return result


## Adds a foreign patch to `patch` as a definition plus one instance. The foreign
## patch's terminals become the declared surface: an edge from its NoteInput is an
## input, an edge into its StereoOutput is an output.
## A patch with no module instances left in it: every one expanded where it stood.
##
## Expansion is the operation that already exists — expand() turns one instance into the
## nodes it stood for — so flattening is that, applied until none remain. The `modules`
## block goes with them: once nothing instantiates a definition, keeping it would leave
## the document carrying a definition it does not use.
##
## The bound is not decoration. Nesting is refused everywhere else, so a cycle should be
## impossible, but "should be impossible" is what a loop with no exit is always resting on.
static func flattened(foreign: Dictionary) -> Dictionary:
	var flat: Dictionary = foreign.duplicate(true)
	for _step in 1000:
		var instance_id := ""
		for node in flat.get("nodes", []):
			if str(node.get("type", "")) == "module":
				instance_id = str(node["id"])
				break
		if instance_id == "":
			flat.erase("modules")
			return flat
		var opened := expand(flat, instance_id)
		if not opened.ok():
			return {}
		flat = opened.patch
	return {}


## Splits a host-bound input seam into one port per outlet it actually drives.
##
## A keyboard is not one signal. The seam carries frequency, gate, velocity and trigger,
## and a module port carries one thing — so kept whole it becomes a single `Keyboard`
## port that cannot deliver both the pitch and the gate, and nothing in the host patch can
## drive it. Split, it is a `frequency` port and a `gate` port, each still fanning out to
## all six operators, each drivable by an ordinary control cable.
##
## Only the outlets in use: a port for `velocity` on a voice that ignores velocity would
## be a socket wired to nothing.
##
## Outputs are left whole, and the asymmetry is real rather than an oversight. An input
## seam's outlets are different signals; an output seam's inlets are channels of the same
## one — `left` and `right` here are both the mix — so splitting them would turn one
## output into two sockets carrying identical sound.
static func _split_input_seams(source: Dictionary) -> Dictionary:
	var out: Dictionary = source.duplicate(true)
	var nodes: Array = out.get("nodes", [])
	var connections: Array = out.get("connections", [])
	for index in range(nodes.size() - 1, -1, -1):
		var node: Dictionary = nodes[index]
		if str(node.get("type", "")) != "Input" or str(node.get("host", "")) == "":
			continue
		var seam_id := str(node["id"])
		var used: Array = []
		for wire in connections:
			var from: Dictionary = wire.get("from", {})
			if str(from.get("node", "")) == seam_id \
					and not used.has(str(from.get("port", ""))):
				used.append(str(from.get("port", "")))
		if used.size() < 2:
			# One outlet is already one port; leave the seam and its name alone.
			node.erase("host")
			continue
		nodes.remove_at(index)
		for outlet: String in used:
			nodes.append({"id": "%s_%s" % [seam_id, outlet], "type": "Input",
				"name": outlet, "position": node.get("position", {})})
		for wire in connections:
			var from: Dictionary = wire.get("from", {})
			if str(from.get("node", "")) == seam_id:
				from["node"] = "%s_%s" % [seam_id, str(from.get("port", ""))]
	return out


## Turns another file into a definition of this one, with one instance placed.
##
## A modular source is flattened first rather than refused. It used to say "nesting is not
## supported yet", which is true of the *result* — a definition may not contain module
## instances — but it is a fact about the notation rather than about the patch: a DX7
## voice is six operators however it is written down, and expanding them back into plain
## nodes says the same thing in a form a definition can hold. The instances the source
## used are notation the source chose, and this is a different document.
static func from_patch(patch: Dictionary, foreign: Dictionary, name_hint: String,
		terminal_types: Array) -> Result:
	var result := Result.new()
	var terminals := {}
	var inner_nodes: Array = []
	var uses_modules := false
	for node in foreign.get("nodes", []):
		if str(node.get("type", "")) == "module":
			uses_modules = true
	# A modular source keeps its modules. Flattening was the answer while a definition
	# could not hold instances; now that one can, dissolving them would throw away the
	# notation the source chose — and with it the sharing, since six operators flattened
	# into a voice are six copies of the same five nodes. The definitions travel across
	# beside the new one, and expansion walks down through both levels.
	var carried: Dictionary = (foreign.get("modules", {}) as Dictionary).duplicate(true)
	foreign = _split_input_seams(foreign)
	for node in foreign.get("nodes", []):
		var type_name := str(node.get("type", ""))
		# A seam is already a port, so it survives as one rather than being dissolved into
		# bindings. The difference matters most where a port fans out: this voice's
		# keyboard feeds six operators, and dropping the seam turned one `note` socket
		# into twelve — op6.note, op6.gate, op5.note, and so on — which is a faithful
		# list of the cables and a useless description of the instrument. Kept, it is one
		# `note` port and one `out`, which is what the file was already saying.
		#
		# The host binding goes: inside a module a port is wired by whatever holds the
		# module, and a port still bolted to the machine would be a module that reaches
		# past its own edges for the keyboard.
		if type_name == "Input" or type_name == "Output":
			var port: Dictionary = node.duplicate(true)
			port.erase("host")
			inner_nodes.append(port)
			continue
		if terminal_types.has(type_name):
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
	# The definitions the source's own instances are of, carried across beside the new
	# one. An identical definition already here is reused — importing two DX7 voices
	# should mean one dx7_operator, which is the sharing that flattening used to throw
	# away — and a different one under the same name is renamed, since merging two
	# unrelated definitions because they agree on a word would change what this patch
	# already does. The nodes that name it follow.
	var renamed := {}
	for name in carried:
		var wanted := str(name)
		if out["modules"].has(wanted):
			if JSON.stringify(out["modules"][wanted]) == JSON.stringify(carried[name]):
				continue
			wanted = _unique_name(wanted, out["modules"].keys())
			renamed[str(name)] = wanted
		out["modules"][wanted] = carried[name]
	if not renamed.is_empty():
		for node: Dictionary in inner_nodes:
			if renamed.has(str(node.get("module", ""))):
				node["module"] = renamed[str(node.get("module", ""))]
	result.module_name = _unique_name(name_hint if name_hint != "" else "module",
		out["modules"].keys())
	# The face travels with the definition: a device's panel is the panel its file
	# already drew — same controls, same groups, same order. Every control aimed at
	# an inner node gets an export (on demand, like everything else) so an instance's
	# knobs have a parameter of their own to write; a control aimed at a seam keeps
	# its place on the face but writes nothing, since an instance has no master out
	# of its own.
	var faces: Array = (foreign.get("controls", []) as Array).duplicate(true)
	if not faces.is_empty():
		var inner_ids := {}
		for node in inner_nodes:
			if not str(node.get("type", "")) in ["Input", "Output"]:
				inner_ids[str(node["id"])] = true
		for control: Dictionary in faces:
			var face_target: Dictionary = control.get("target", {})
			if inner_ids.has(str(face_target.get("node", ""))):
				_export_for(exported, {}, str(face_target.get("node", "")),
					str(face_target.get("parameter", "")))

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
	if not faces.is_empty():
		definition["controls"] = faces
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
