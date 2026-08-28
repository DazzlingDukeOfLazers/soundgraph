# What a module looks like.
#
# Not what it does: every theme here changes faceplate, knobs, jack rings and cable
# colours and nothing else. The geometry is shared, so a Filter is the same shape and the
# same size whatever it is wearing, and a patch means exactly what it meant before
# somebody repainted it.
#
# One theme is not in the list. "Category" is the default and is what this editor has
# always drawn: one graphite panel for every module, with a two-pixel stripe under the
# title in the colour of what the module is. It stays the default because that stripe
# means something and a repaint does not.
#
# Every theme is checked by design_test.gd for the same thing the palettes are: that the
# legend on the faceplate can be read. A mustard panel with white lettering looks lovely
# in a mock-up and is unreadable on a laptop in a bright room.
extends RefCounted

## The one that means something. Faceplate comes from the module's category, so the rack
## stays readable at a glance; everything else follows the editor palette.
const CATEGORY := "category"


## Each theme is a flat token set, written out rather than derived.
##
## `faceplate` is the panel. `legend` is the lettering on it and must contrast with it.
## `knob` and `pointer` are the body and the index mark. `jack` is the socket field —
## black in every one of these, which is the family resemblance — and `ring` is the
## colour around it.
##
## `cables` is the candy, and it is four colours because there are four kinds of signal.
## They are handed to audio, control, trigger and note in that order rather than being
## sprinkled about: a theme is allowed to change what the signal language looks like, and
## not allowed to abolish it. Following a cable by its colour has to keep working, or the
## rack has stopped being a diagram and become a poster.
const THEMES := {
	# ---- the current family ------------------------------------------------------
	"oxide-teal": {
		"name": "Oxide Teal",
		"blurb": "Deep teal matte, worn edges, soft grain.",
		"finish": "worn",
		"faceplate": "1d4f4a", "edge": "16403c", "grain": 0.06,
		"legend": "eef6f4", "knob": "17191a", "pointer": "5fd3c2",
		"jack": "121415", "ring": "c9b380", "screw": "8fa3a0",
		"cables": ["ff3ea5", "b6ff3e", "3ed8ff", "ffd23e"],
	},
	"acid-mustard": {
		"name": "Acid Mustard",
		"blurb": "Mustard yellow, slightly dirty lab finish.",
		"finish": "dirty",
		"faceplate": "b8912a", "edge": "9c7a1f", "grain": 0.09,
		"legend": "1a1608", "knob": "24242a", "pointer": "f2d14b",
		"jack": "121212", "ring": "f2d14b", "screw": "6b5a20",
		"cables": ["3ed8ff", "ff3ea5", "b6ff3e", "ff8a24"],
	},
	"ultraviolet": {
		"name": "Ultraviolet",
		"blurb": "Saturated purple, subtle halftone grain.",
		"finish": "halftone",
		"faceplate": "6b34b8", "edge": "56289a", "grain": 0.07,
		"legend": "f6eeff", "knob": "16121c", "pointer": "cbb0f5",
		"jack": "110e16", "ring": "ffd23e", "screw": "9d86c4",
		"cables": ["3ee8d8", "b6ff3e", "ff7ac2", "ffb43e"],
	},
	"carbon-utility": {
		"name": "Carbon Utility",
		"blurb": "Charcoal graphite, industrial finish.",
		"finish": "industrial",
		"faceplate": "2a2c2f", "edge": "1e2023", "grain": 0.05,
		"legend": "f2f4f6", "knob": "141516", "pointer": "e8ecef",
		"jack": "0e0f10", "ring": "8b9298", "screw": "7e868d",
		"cables": ["24f0ff", "3eff8a", "ff3ea5", "ffd23e"],
	},
	"moss-machine": {
		"name": "Moss Machine",
		"blurb": "Dark olive green, utilitarian synth-lab feel.",
		"finish": "matte",
		"faceplate": "4a5228", "edge": "3a411f", "grain": 0.07,
		"legend": "f3f5e6", "knob": "17190f", "pointer": "b9c76a",
		"jack": "111208", "ring": "e3c73f", "screw": "97a06a",
		"cables": ["ffd23e", "3ed8ff", "ff7ac2", "b6ff3e"],
	},

	# ---- the expanded brainstorm ---------------------------------------------------
	"ivory-lab": {
		"name": "Ivory Lab",
		"blurb": "Warm ivory, black legends, scientific lab look.",
		"finish": "matte",
		"faceplate": "e9e2d0", "edge": "d3ccb9", "grain": 0.04,
		"legend": "17150f", "knob": "1a1a1c", "pointer": "e9e2d0",
		"jack": "141414", "ring": "b84a4a", "screw": "9a9384",
		"cables": ["1a1a1a", "d33b3b", "2a5fd6", "e0a02a"],
	},
	"safety-orange": {
		"name": "Safety Orange",
		"blurb": "Matte safety orange, warning-label energy.",
		"finish": "matte",
		"faceplate": "d95a10", "edge": "b8480a", "grain": 0.06,
		"legend": "1a0d04", "knob": "1c1c1e", "pointer": "ffffff",
		"jack": "121212", "ring": "f2f2f2", "screw": "8a4410",
		"cables": ["1a1a1a", "ffd23e", "3ed8ff", "9aa3a8"],
	},
	"bakelite-brown": {
		"name": "Bakelite Brown",
		"blurb": "Deep brown-burgundy, cream legends.",
		"finish": "dirty",
		"faceplate": "42211c", "edge": "331a15", "grain": 0.08,
		"legend": "f0e2cb", "knob": "e2d3b4", "pointer": "42211c",
		"jack": "120c0a", "ring": "b58a4a", "screw": "8a6a52",
		"cables": ["d9a52a", "f0e2cb", "8f2020", "2a8f86"],
	},
	"anodized-blue": {
		"name": "Anodized Blue",
		"blurb": "Electric anodized blue, machined look.",
		"finish": "machined",
		"faceplate": "1546c8", "edge": "0f37a4", "grain": 0.05,
		"legend": "f0f5ff", "knob": "141519", "pointer": "cfd6e0",
		"jack": "0e1016", "ring": "c2cbd6", "screw": "93a3c4",
		"cables": ["ffffff", "3ed8ff", "9a5cff", "b6ff3e"],
	},
	"frosted-ice": {
		"name": "Frosted Ice",
		"blurb": "Pale grey-blue, calm and minimal.",
		"finish": "matte",
		"faceplate": "ccd6dd", "edge": "b4c0c9", "grain": 0.03,
		"legend": "13181c", "knob": "8e9aa3", "pointer": "13181c",
		"jack": "16191c", "ring": "5fb8e8", "screw": "8a949c",
		"cables": ["ffffff", "5fe8c2", "5fc2ff", "ff7a6b"],
	},
	"monochrome-zine": {
		"name": "Monochrome Zine",
		"blurb": "Black and off-white, photocopied poster.",
		"finish": "photocopy",
		"faceplate": "141414", "edge": "0a0a0a", "grain": 0.12,
		"legend": "f2f0ea", "knob": "0e0e0e", "pointer": "f2f0ea",
		"jack": "060606", "ring": "f2f0ea", "screw": "9a9a9a",
		"cables": ["c6ff2e", "3ed8ff", "ff3ea5", "f2f0ea"],
	},
}


## The order they are offered in, which is the order they were drawn in rather than
## alphabetical: the first five are a family and read as one.
const ORDER := [
	"oxide-teal", "acid-mustard", "ultraviolet", "carbon-utility", "moss-machine",
	"ivory-lab", "safety-orange", "bakelite-brown", "anodized-blue", "frosted-ice",
	"monochrome-zine",
]


static func exists(key: String) -> bool:
	return key == CATEGORY or THEMES.has(key)


## The theme a module is actually wearing: its own if it has one, otherwise the patch's,
## otherwise the category colouring this editor has always used.
##
## Unknown names fall back rather than failing. A patch written by a newer editor, or by
## hand with a typo in it, should open and be legible - a module in the wrong colour is a
## far better outcome than a module that will not draw.
static func resolve(node_theme: String, patch_theme: String) -> String:
	if exists(node_theme) and node_theme != "":
		return node_theme
	if exists(patch_theme) and patch_theme != "":
		return patch_theme
	return CATEGORY


static func display_name(key: String) -> String:
	if key == CATEGORY:
		return "Category colours"
	var theme: Dictionary = THEMES.get(key, {})
	return str(theme.get("name", key))


## One token, as a colour. Missing keys come back transparent rather than throwing, so a
## half-written theme shows up as a hole instead of taking the editor down with it.
static func token(key: String, name: String) -> Color:
	var theme: Dictionary = THEMES.get(key, {})
	var value: String = str(theme.get(name, ""))
	if value == "" or not value.is_valid_html_color():
		return Color(0, 0, 0, 0)
	return Color(value)


## The cable colours for a theme, in signal order: audio, control, trigger, note. Empty
## for the category theme, which leaves the editor palette's own signal colours in place.
##
## Cables are drawn from the patch's theme rather than from either end's, because a cable
## between a teal module and a mustard one has no business being two colours, and the
## wiring of a rack is one system however the panels are painted.
static func cables(key: String) -> Array:
	var theme: Dictionary = THEMES.get(key, {})
	var out: Array = []
	for value in theme.get("cables", []):
		if str(value).is_valid_html_color():
			out.append(Color(str(value)))
	return out
