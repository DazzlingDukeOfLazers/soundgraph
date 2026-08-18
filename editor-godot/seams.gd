extends RefCounted
## A seam is a graph's edge written as a node — see docs/modules-design.md.
##
## The loader turns a host-bound seam into the terminal it names before anything
## downstream sees the document, so nothing in patch-io or dsp-core knows the word. The
## editor is the exception: it parses patches itself rather than through the loader, so it
## meets seams face to face and has to know what they are.
##
## One place, because there are half a dozen questions in this editor that mean "what
## registry entry is this node" — the port list, the rack's ordering, whether a selection
## may be collapsed, which node is the output — and every one of them got the answer wrong
## the first time by reading `node["type"]` straight. This is a second copy of patch-io's
## table and there is no third.

const TERMINALS := {
	"Input/note": "NoteInput",
	"Input/audio": "AudioInput",
	"Output/stereo": "StereoOutput",
}


## The terminal a host-bound seam is, or "" when this node is not one.
static func terminal_for(node: Dictionary) -> String:
	var type_name := str(node.get("type", ""))
	if type_name != "Input" and type_name != "Output":
		return ""
	return str(TERMINALS.get("%s/%s" % [type_name, str(node.get("host", ""))], ""))


## The registry key a node should be looked up under: a module's synthesized descriptor,
## a seam's own, or the type it plainly is.
##
## A seam has a descriptor of its own rather than borrowing the terminal's, because it is
## not the terminal: it carries the same signals *plus* the jack the machine plugs into.
## That extra jack is the whole point of drawing a port — it is where "and this is how you
## test it" attaches, and inside a module it is where the parent patch attaches.
static func registry_key(node: Dictionary) -> String:
	if str(node.get("type", "")) == "module":
		return "module:%s" % str(node.get("module", ""))
	var type_name := str(node.get("type", ""))
	if type_name == "Input" or type_name == "Output":
		var host := str(node.get("host", ""))
		# A bound port's shape comes from its host: every Input bound to `note` carries the
		# four the keyboard has, so they share one entry. An unbound one has no host to ask,
		# and its shape is whatever it is wired as — which is its own business, so it gets
		# its own key. That is also what keeps unplugging non-destructive: pulling the
		# keyboard out changes which entry the port uses, not how many outlets it has.
		if host == "":
			return "seam:%s/@%s" % [type_name, str(node.get("id", ""))]
		return "seam:%s/%s" % [type_name, host]
	return type_name


## The name of the jack a host plugs into. One name, both directions: on an Input it is an
## inlet the machine drives, on an Output an outlet the machine listens to, and calling
## them the same thing is what makes "the host side" a phrase somebody can learn once.
const HOST_PORT := "host"


## A definition's declared ports, in the order a reader meets them.
##
## Two spellings, one answer. Seams come first, in the order they appear among the
## definition's nodes — which is the whole reason to draw a port rather than list one:
## where it sits is what says where it sits. Binding-list entries follow, minus any name a
## seam already claimed, because patch-io resolves a port by looking for a seam of that
## name before it looks in the list and the editor must agree with the loader about what a
## module's surface is.
##
## `{"name", "node", "port"}` either way, so a caller cannot tell which spelling it came
## from. A seam feeding several inner ports reports the first: the entry exists to say
## what kind of signal the port carries, and fan-out is expansion's business.
static func declared_ports(definition: Dictionary, is_output: bool) -> Array:
	var wanted := "Output" if is_output else "Input"
	var ports: Array = []
	var claimed := {}
	for node: Dictionary in definition.get("nodes", []):
		if str(node.get("type", "")) != wanted or str(node.get("host", "")) != "":
			continue
		# A stereo pair answers to its channels: left and right are ports of the
		# instance in their own right, which is what keeps channel identity — one
		# port for the whole seam summed left into right at every destination.
		# Mirrors patch-io's seam_is_stereo, and the spelling guard holds both to it.
		if is_output and stereo_pair(definition, node):
			for channel in ["left", "right"]:
				for wire: Dictionary in definition.get("connections", []):
					if str(wire["to"]["node"]) == str(node["id"]) \
							and str(wire["to"]["port"]) == channel:
						ports.append({"name": channel,
							"node": str(wire["from"]["node"]),
							"port": str(wire["from"]["port"])})
						claimed[channel] = true
						break
			continue
		var port_name := str(node.get("name", ""))
		if port_name == "":
			port_name = str(node["id"])
		for wire: Dictionary in definition.get("connections", []):
			var end: Dictionary = wire["from"] if is_output else wire["to"]
			var seam_end: Dictionary = wire["to"] if is_output else wire["from"]
			if str(seam_end["node"]) != str(node["id"]):
				continue
			ports.append({"name": port_name, "node": str(end["node"]),
				"port": str(end["port"])})
			claimed[port_name] = true
			break
	for binding: Dictionary in definition.get("inputs" if not is_output else "outputs", []):
		if claimed.has(str(binding["name"])):
			continue
		ports.append({"name": str(binding["name"]), "node": str(binding["node"]),
			"port": str(binding["port"])})
	return ports


## Whether this Output seam is a stereo pair: wired through exactly "left" and
## "right". The same recognition patch-io uses, spelled once per language.
static func stereo_pair(definition: Dictionary, seam: Dictionary) -> bool:
	if str(seam.get("type", "")) != "Output":
		return false
	var inlets := {}
	for wire: Dictionary in definition.get("connections", []):
		if str(wire["to"]["node"]) == str(seam["id"]):
			inlets[str(wire["to"]["port"])] = true
	return inlets.size() == 2 and inlets.has("left") and inlets.has("right")


## True when this node is one of a definition's own edges rather than a part of it. Used
## wherever a definition's contents are counted or drawn: a seam is the boundary, and
## counting it as a node makes a two-node module look like a three-node one.
static func is_port_seam(node: Dictionary) -> bool:
	var type_name := str(node.get("type", ""))
	return (type_name == "Input" or type_name == "Output") \
		and str(node.get("host", "")) == ""
