class_name BrowserItem
extends RefCounted

## One thing the Add Node browser can show, whatever it came from.
##
## Before this, the browser was handed dictionaries that still smelled of where they were
## found: a node carried the core's category, a device carried the prefix on its label,
## and the browser worked out what to do with each as it drew them. That works for two
## sources and stops working at four — the place where the old shapes leak back in is the
## preview pane, which is the next thing being built, so the leak is closed first.
##
## The rule this file exists to hold: `kind` says what the thing is, `category` says where
## the browser puts it. They are different questions and were one field. A bank voice and
## a worked patch are both patches to load; they belong in different rows of the rail. A
## node and a bank voice both drop into the graph as a node; they are not the same kind of
## object at all.
##
## What is deliberately absent: author, rating, complexity, cloud id, and every other
## field a preview mockup might one day want. Fields arrive when something reads them.

## What the object is.
enum Kind {
	NODE,       ## a primitive from the core's registry
	PATCH,      ## a worked patch, a game sound, a synth or drum voice
	BANK_ITEM,  ## one entry of a named library — the node demos, FM, DX7
}

## What can be done with it. Descriptors, not buttons: step 7 is where the browser starts
## honouring them, and until then Enter takes the one route the search palette takes.
enum Action {
	ADD_NODE,         ## drop it into the patch being edited
	LOAD_PATCH,       ## open it as the patch
	OPEN_IN_SANDBOX,  ## open it somewhere that is not the patch being edited
}

const KIND_NAMES := ["NODE", "PATCH", "BANK_ITEM"]
const ACTION_NAMES := ["ADD_NODE", "LOAD_PATCH", "OPEN_IN_SANDBOX"]

## Where a node lands in the rail, by the category dsp-core gives it.
##
## A map of nine core categories rather than a list of fifty node names: a node added to
## the core lands somewhere sensible on its own, where a hand-written list would quietly
## drop it. The rail's names are the editor's — the core has no opinion about whether a
## delay line is an effect, and should not have to.
const CORE_FAMILIES := {
	"Terminals": "MIDI & IO",
	"Sources": "Sources",
	"Filters": "Filters",
	"Time": "Effects",
	"Amplitude": "Mixing",
	"Effects": "Effects",
	"Maths": "Utilities",
	"Utilities": "Utilities",
	"Modulation": "Modulation",
}

## The nodes whose core family is right and whose rail row is not. Envelopes and
## sequencers are modulation as far as the core is concerned, and are their own rows here
## because that is how they are looked for.
const NODE_ROWS := {
	"ADSR": "Envelopes",
	"AhdEnvelope": "Envelopes",
	"StepSequencer": "Sequencers",
	"Euclid": "Sequencers",
	"Arpeggio": "Sequencers",
	"Clock": "Sequencers",
	"Drive": "Effects",
	"Crush": "Effects",
	"MidiCC": "MIDI & IO",
}

## Which bank a device belongs to, by the prefix on its label. Everything else — the
## worked patches, the game sounds, the synth and drum machine voices — is an example.
const DEVICE_ROWS := {
	"Node": "Node bank",
	"FM": "FM bank",
	"DX7": "DX7 bank",
}

## What the browser hands back when the item is taken. Stable, and the only string any
## other part of the editor needs to know.
var id := ""
var display_name := ""
var kind := Kind.NODE
## The rail row this belongs under.
var category := ""
## The landmark it sits under inside a list.
var group := ""
## One sentence, for the preview pane that is coming.
var description := ""
## The item's own words, for a reader.
var tags: PackedStringArray = PackedStringArray()
## The words it should be findable by. The core ranks nodes and knows theirs; a device's
## are its own name.
var search_terms: PackedStringArray = PackedStringArray()
## What the system it came from calls it, which is not always what the browser calls it.
var source_ref := ""
var primary_action := Action.ADD_NODE
var secondary_actions: Array = []


## A primitive from the core's registry.
static func from_node(type_name: String, descriptor: Dictionary) -> BrowserItem:
	var item := BrowserItem.new()
	item.id = type_name
	item.source_ref = type_name
	item.display_name = str(descriptor.get("display_name", type_name))
	item.kind = Kind.NODE
	var family := str(descriptor.get("category", ""))
	item.category = str(NODE_ROWS.get(type_name, CORE_FAMILIES.get(family, "")))
	item.group = item.category if item.category != "" else "Other"
	item.description = str(descriptor.get("summary", ""))
	item.tags = PackedStringArray([family] if family != "" else [])
	for term in descriptor.get("search_terms", []):
		item.search_terms.append(str(term))
	item.primary_action = Action.ADD_NODE
	return item


## A device: a worked patch, a game sound, a voice from one of the banks.
##
## The label carries its family — "FM: accordion" is a shelf and a name — and the row
## only wants the name, because the shelf is already the heading it is sitting under.
static func from_device(label: String, blurb: String) -> BrowserItem:
	var item := BrowserItem.new()
	item.id = "device:%s" % label
	item.source_ref = label
	var family := ""
	var name := label
	if label.contains(":"):
		family = label.get_slice(":", 0)
		name = label.substr(family.length() + 1).strip_edges()
	item.display_name = name
	item.category = str(DEVICE_ROWS.get(family, "Examples"))
	item.kind = Kind.BANK_ITEM if DEVICE_ROWS.has(family) else Kind.PATCH
	item.group = family if family != "" else "Patches"
	item.description = blurb
	item.tags = PackedStringArray([family] if family != "" else [])
	item.search_terms = PackedStringArray(name.split(" ", false))
	# A patch is a thing to load, and a bank voice is a thing to drop in — which is what
	# the two kinds are for. Neither is executed yet; step 7 is where the browser starts
	# reading these, and until then Enter takes the palette's one route for everything.
	if item.kind == Kind.PATCH:
		item.primary_action = Action.LOAD_PATCH
		item.secondary_actions = [Action.OPEN_IN_SANDBOX]
	else:
		item.primary_action = Action.ADD_NODE
		item.secondary_actions = [Action.OPEN_IN_SANDBOX]
	return item


## Whether a query finds this.
##
## One question with two answers behind it. A node is decided by the core's own ranking —
## `ranked` is the set it returned, so "make quieter" finds the same node in the browser
## as on the command line, and the browser does not pretend to know better. Anything else
## is decided here, on every word of the query appearing in the name.
##
## Normalising did not mean throwing the specialised ranking away. It meant the browser
## gets one vocabulary back from both.
func matches(query: String, ranked: Dictionary) -> bool:
	if query == "":
		return true
	if kind == Kind.NODE:
		return ranked.has(id)
	var lowered := display_name.to_lower()
	for word in query.to_lower().split(" ", false):
		if not lowered.contains(str(word)):
			return false
	return true


func kind_name() -> String:
	return KIND_NAMES[kind]


func action_name(action: int) -> String:
	return ACTION_NAMES[action]
