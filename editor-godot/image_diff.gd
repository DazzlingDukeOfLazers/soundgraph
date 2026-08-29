extends SceneTree
## Are two frames the same picture?
##
## The regression set is otherwise a set of things to look at, which catches what a person
## notices and nothing else. This is the one thing worth asserting outright: emphasis
## raises a cable over its neighbours while it lasts, and when it ends the rack has to go
## back to the order it had. Not to a plausible order — to the same one, so a crossing
## does not quietly swap sides every time the pointer passes.
##
##   godot --path editor-godot --script res://image_diff.gd -- out/a.png out/b.png
func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		printerr("usage: image_diff.gd -- <a.png> <b.png>")
		quit(2)
		return
	var a := Image.load_from_file(args[0])
	var b := Image.load_from_file(args[1])
	if a == null or b == null:
		printerr("could not read both images")
		quit(2)
		return
	if a.get_size() != b.get_size():
		printerr("FAIL %s vs %s: different sizes" % [args[0], args[1]])
		quit(1)
		return
	var differing := 0
	for y in a.get_height():
		for x in a.get_width():
			var p: Color = a.get_pixel(x, y)
			var q: Color = b.get_pixel(x, y)
			if absf(p.r - q.r) + absf(p.g - q.g) + absf(p.b - q.b) > 0.004:
				differing += 1
	if differing == 0:
		print("same  %s == %s" % [args[0], args[1]])
		quit(0)
	else:
		printerr("FAIL  %s != %s: %d pixels differ" % [args[0], args[1], differing])
		quit(1)
