extends SceneTree
## Photograph the real rack, with a real patch, at a real size.
##
## Every sheet so far has drawn cables against a mock panel 250 px wide with four jacks
## crammed into 208 of them. Whether the plug is correctly restrained or still too small
## is a question about actual module widths and actual jack spacing, and a mock cannot
## answer it — which is why the plan says stop making sheets and go and look.
##
##   godot --path editor-godot --script res://rack_shot.gd -- \
##       --patch res://examples/first-synth.json --style physical --out out/rack.png

const CableArt := preload("res://cable_art.gd")

const STYLES := {"catenary": 0, "pcb": 1, "physical": 2}

var _patch := "res://examples/first-synth.json"
var _style := "physical"
var _out := ""
var _zoom := 1.0


func _initialize() -> void:
	_run()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		match args[i]:
			"--patch": _patch = args[i + 1]
			"--style": _style = args[i + 1]
			"--out": _out = args[i + 1]
			"--zoom": _zoom = float(args[i + 1])

	Design.use_palette(Design.Palette.LAB)
	root.size = Vector2i(1600, 900)
	root.title = "rack — %s" % _style

	var file := FileAccess.open(_patch, FileAccess.READ)
	if file == null:
		printerr("no patch at %s" % _patch)
		quit(1)
		return
	var patch: Dictionary = JSON.parse_string(file.get_as_text())

	var rack := Rack.new()
	rack.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	rack.scale = Vector2(_zoom, _zoom)
	root.add_child(rack)
	# _ready builds the cable layer, and rebuild() moves it to the front. Called in the
	# same breath as add_child it finds nothing to move and dies on a null child.
	await process_frame
	# The registry is not a file — it comes from the native engine, which is what knows
	# what a node's ports are. Without it the rack builds panels with no jacks, and a
	# cable with no jack to leave from is not drawn at all: rails and titles and nothing
	# else, which looks exactly like a rendering failure and is not one.
	rack.registry = _registry()
	rack.type_colours = {
		"audio": CableArt.PALETTE["cyan"],
		"control": CableArt.PALETTE["amber"],
		"event": CableArt.PALETTE["magenta"],
		"note": CableArt.PALETTE["magenta"],
	}
	rack.cable_style = STYLES.get(_style, 2)
	rack.patch = patch
	# patch is a plain field; the build is a separate call, and assigning without it gets
	# you an empty rack that looks like a rendering failure.
	rack.rebuild()

	if _out != "":
		await _shoot()


func _registry() -> Dictionary:
	if not ClassDB.class_exists("SoundGraphEngine"):
		printerr("no SoundGraphEngine; build bin/ first — the rack will have no jacks")
		return {}
	var engine: Object = ClassDB.instantiate("SoundGraphEngine")
	var parsed: Variant = JSON.parse_string(engine.get_registry_json())
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	var out: Dictionary = {}
	for type: Dictionary in parsed.get("types", []):
		out[type["name"]] = type
	return out


func _shoot() -> void:
	# Three frames rather than two: the rack builds its modules on the first, lays them
	# out on the second, and only draws cables once the jacks know where they are.
	await process_frame
	await process_frame
	await process_frame
	var image := root.get_texture().get_image()
	if image.save_png(_out) == OK:
		print("wrote %s" % _out)
	else:
		printerr("could not write %s" % _out)
	quit()
