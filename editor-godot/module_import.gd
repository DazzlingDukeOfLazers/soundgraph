class_name ModuleImport
extends RefCounted
## Adds an existing patch into the one being edited, as a module.
##
## There is no sub-graph in the patch format and there deliberately is not going to be one:
## a nested graph is a second thing every target has to understand, and the promise is that
## one file runs everywhere. So a module is *inlined* — its nodes are copied in with their
## ids prefixed, and from that moment they are ordinary nodes. The imported patch is a
## starting point, not a live reference, and editing the original later changes nothing
## here. That is a real limitation and the honest one: the alternative is a format where
## opening a patch means resolving links to files you may not have.
##
## What gets left behind: the imported patch's own terminals. A patch that ends in a
## StereoOutput is a finished sound, and pasting a second output into a graph that already
## has one is not a module, it is a collision. The nodes that fed those terminals are the
## module's edges, and wiring them up is the user's job — which is the same job they would
## have with a hardware module, and takes about as long.

## What an import did, so the editor can say it rather than the user having to notice.
class Result extends RefCounted:
	var nodes_added: Array = []       # new ids, in document order
	var terminals_dropped: Array = [] # ["StereoOutput 'out'", ...]
	var connections_dropped: int = 0
	var error := ""

	func ok() -> bool:
		return error.is_empty()

	func summary() -> String:
		if not ok():
			return error
		var text := "added %d node%s" % [nodes_added.size(),
			"" if nodes_added.size() == 1 else "s"]
		if terminals_dropped.size() > 0:
			text += ", left out %s" % ", ".join(terminals_dropped)
		if connections_dropped > 0:
			text += " (%d cable%s to them dropped)" % [connections_dropped,
				"" if connections_dropped == 1 else "s"]
		return text


## Terminals belong to a finished patch, not to a module. Which ones those are comes from
## the registry's own category rather than a list here, so a terminal added to the core
## later is handled without this file changing.
static func _is_terminal(type_name: String, registry: Dictionary) -> bool:
	return str(registry.get(type_name, {}).get("category", "")) == "Terminals"


## Merges `source` into `target`, in place. `prefix` namespaces the imported ids.
static func merge(target: Dictionary, source: Dictionary, prefix: String,
		registry: Dictionary, at: Vector2) -> Result:
	var result := Result.new()

	if typeof(source) != TYPE_DICTIONARY or not source.has("nodes"):
		result.error = "that file is not a patch"
		return result

	# A prefix that is already in use would silently merge two modules into one. Finding a
	# free one is better than refusing: importing the same file twice is a normal thing to
	# want, and "delay/" then "delay-2/" is what a person would have done anyway.
	var unique_prefix := prefix
	var suffix := 2
	while _prefix_in_use(target, unique_prefix):
		unique_prefix = "%s-%d" % [prefix, suffix]
		suffix += 1

	# Terminals are skipped, and their ids remembered so cables to them can be dropped
	# rather than left dangling at a node that does not exist.
	var skipped := {}
	for node in source.get("nodes", []):
		var type_name := str(node.get("type", ""))
		if _is_terminal(type_name, registry):
			skipped[str(node["id"])] = true
			result.terminals_dropped.append("%s '%s'" % [type_name, str(node["id"])])

	# The imported nodes keep their relative layout and are moved as a group, so a module
	# arrives looking like it did in its own file instead of in a heap.
	var origin := Vector2(INF, INF)
	for node in source.get("nodes", []):
		if skipped.has(str(node["id"])):
			continue
		var position: Dictionary = node.get("position", {})
		origin.x = minf(origin.x, float(position.get("x", 0.0)))
		origin.y = minf(origin.y, float(position.get("y", 0.0)))
	if not is_finite(origin.x):
		origin = Vector2.ZERO

	if not target.has("nodes"):
		target["nodes"] = []
	if not target.has("connections"):
		target["connections"] = []

	for node in source.get("nodes", []):
		var old_id := str(node["id"])
		if skipped.has(old_id):
			continue
		var copy: Dictionary = node.duplicate(true)
		copy["id"] = "%s/%s" % [unique_prefix, old_id]
		var position: Dictionary = node.get("position", {})
		copy["position"] = {
			"x": float(position.get("x", 0.0)) - origin.x + at.x,
			"y": float(position.get("y", 0.0)) - origin.y + at.y,
		}
		target["nodes"].append(copy)
		result.nodes_added.append(copy["id"])

	for connection in source.get("connections", []):
		var from_id := str(connection["from"]["node"])
		var to_id := str(connection["to"]["node"])
		if skipped.has(from_id) or skipped.has(to_id):
			result.connections_dropped += 1
			continue
		var copy: Dictionary = connection.duplicate(true)
		copy["from"]["node"] = "%s/%s" % [unique_prefix, from_id]
		copy["to"]["node"] = "%s/%s" % [unique_prefix, to_id]
		target["connections"].append(copy)

	if result.nodes_added.is_empty():
		result.error = "that patch has nothing in it but terminals"
	return result


static func _prefix_in_use(target: Dictionary, prefix: String) -> bool:
	for node in target.get("nodes", []):
		if str(node["id"]).begins_with(prefix + "/"):
			return true
	return false


## A sensible module name from a file name: "delay-echo.json" becomes "delay-echo".
static func name_from_path(path: String) -> String:
	var base := path.get_file().get_basename()
	return base if base != "" else "module"
