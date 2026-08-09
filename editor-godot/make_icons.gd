extends SceneTree

# Rasterises icon.svg at the sizes a PWA manifest asks for.
#
# The icons are build output, not hand-drawn assets: there is one icon, it lives in
# icon.svg, and these are it at other sizes. Regenerate with
#
#   godot --headless --path editor-godot --script res://make_icons.gd
#
# rather than editing the PNGs, or the four files will eventually disagree.

const SOURCE := "res://icon.svg"
const OUT_DIR := "res://pwa"
const SIZES := [144, 180, 512]


func _init() -> void:
	var svg := FileAccess.get_file_as_string(SOURCE)
	if svg.is_empty():
		push_error("Could not read %s" % SOURCE)
		quit(1)
		return

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	for size in SIZES:
		var image := Image.new()
		# icon.svg is 128 wide, so the scale is the ratio to the size we want.
		var err := image.load_svg_from_string(svg, float(size) / 128.0)
		if err != OK:
			push_error("Rasterising at %d failed: %d" % [size, err])
			quit(1)
			return
		var path := "%s/icon-%d.png" % [OUT_DIR, size]
		err = image.save_png(path)
		if err != OK:
			push_error("Writing %s failed: %d" % [path, err])
			quit(1)
			return
		print("%s  %dx%d" % [path, image.get_width(), image.get_height()])

	quit(0)
