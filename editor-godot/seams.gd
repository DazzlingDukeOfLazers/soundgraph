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
## a seam's terminal, or the type it plainly is.
static func registry_key(node: Dictionary) -> String:
	if str(node.get("type", "")) == "module":
		return "module:%s" % str(node.get("module", ""))
	var seam := terminal_for(node)
	return seam if seam != "" else str(node.get("type", ""))
