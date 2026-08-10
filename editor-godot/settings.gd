class_name Settings
extends RefCounted
## Preferences that belong to the person, not to the patch.
##
## Theme, UI scale, contrast mode, motion preference and cable style are all things somebody
## chose because of their eyes, their screen or their room. None of them belong in a .json
## that gets shared — opening a patch a colleague sent you should not switch your editor to
## their theme, and it certainly should not undo a high-contrast setting somebody needs.
##
## Stored in `user://` — the platform's own per-user location, and in a browser the origin's
## persistent storage, so a phone and a laptop keep their own answers.
##
## Deliberately dumb: a flat dictionary of primitives, written on every change. There is no
## migration story because there is nothing here worth migrating; a settings file that fails
## to parse is replaced by the defaults, which is the correct outcome for a file whose worst
## case is somebody re-picking a theme.

const PATH := "user://settings.json"

static var _values: Dictionary = {}
static var _loaded := false

## When true, nothing is written to disk.
##
## For the headless tests, which drive the theme and the UI scale to check they work
## and were persisting every one of those choices into the real settings file. Two
## costs: a test run silently changed the preferences of whoever ran it, and — worse —
## the next run started from whatever the last one happened to leave behind, so a
## test that aborted midway made the following run fail somewhere unrelated. Both
## showed up as "XL makes the text bigger (20 from 20)", which is a confusing way to
## be told your test suite has memory.
static var suspended := false


static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	var file := FileAccess.open(PATH, FileAccess.READ)
	if file == null:
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if typeof(parsed) == TYPE_DICTIONARY:
		_values = parsed


static func fetch(key: String, fallback: Variant) -> Variant:
	_ensure_loaded()
	return _values.get(key, fallback)


static func store(key: String, value: Variant) -> void:
	_ensure_loaded()
	if _values.get(key) == value:
		return
	_values[key] = value
	if suspended:
		return
	var file := FileAccess.open(PATH, FileAccess.WRITE)
	if file == null:
		# Not worth an error dialog. A preference that fails to persist is a preference
		# somebody re-picks next time, and there is nothing useful they could do about it.
		push_warning("could not write %s" % PATH)
		return
	file.store_string(JSON.stringify(_values, "  "))


## Applies everything stored to the design system, before any UI is built.
static func apply() -> void:
	Design.use_palette(int(fetch("palette", Design.Palette.LAB)))
	Design.ui_scale = int(fetch("ui_scale", Design.Scale.COMFORTABLE))
	Design.reduced_motion = bool(fetch("reduced_motion", false))
	Rack.density = int(fetch("rack_density", Rack.Density.INSTRUMENT))
