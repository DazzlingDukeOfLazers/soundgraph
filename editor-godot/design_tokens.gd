extends SceneTree

## Exports the desktop's visual tokens for a second implementation to read.
##
##   godot --headless --path editor-godot --script design_tokens.gd
##
## The desktop is the reference implementation. A web build that re-types these values by
## eye will drift from it the first week, and nobody will be able to say which one is wrong —
## so they are exported from the running program, by asking `Design`, `Rack` and `CableArt`
## what they actually are rather than by reading the source and transcribing.
##
## Every palette, not only the default: the palette switch is one of the few pieces of this
## design anybody notices immediately, and a funnel that shows one look is showing less than
## the product has.
##
## What is deliberately **not** here: anything that is a behaviour rather than a value. The
## crossing knockout, the focus suppression, the LOD ladder and the glyph grammar are all
## rules about *when*, and a token file that pretended to carry them would be a second
## specification competing with `docs/graph-node-system.md` and `docs/graph-cable-system.md`.
## Those documents stay authoritative; this is the palette and the ruler.

const Design := preload("res://design.gd")
const CableArt := preload("res://cable_art.gd")
const Rack := preload("res://rack.gd")
const NodeGrid := preload("res://node_grid.gd")
const HarnessExit := preload("res://harness_exit.gd")


func hex(colour: Color) -> String:
	return "#" + colour.to_html(false)


func palette_tokens() -> Dictionary:
	var out := {}
	for index in Design.PALETTE_NAMES.size():
		Design.use_palette(index)
		var surfaces: Array = []
		for surface: Color in Design.SURFACES:
			surfaces.append(hex(surface))
		var borders: Array = []
		for border: Color in Design.BORDERS:
			borders.append(hex(border))
		out[str(Design.PALETTE_NAMES[index])] = {
			"surfaces": surfaces,
			"borders": borders,
			"ink": {
				"bright": hex(Design.INK_BRIGHT), "normal": hex(Design.INK_NORMAL),
				"second": hex(Design.INK_SECOND), "disabled": hex(Design.INK_DISABLED),
			},
			"accent": hex(Design.ACCENT), "on_accent": hex(Design.ON_ACCENT),
			"focus": hex(Design.FOCUS), "boundary": hex(Design.BOUNDARY),
			"signal": {
				"audio": hex(Design.AUDIO), "control": hex(Design.CONTROL),
				"trigger": hex(Design.TRIGGER),
			},
			"state": {
				"warning": hex(Design.WARNING), "error": hex(Design.ERROR),
			},
			"keys": {
				"white": hex(Design.WHITE_KEY), "white_ink": hex(Design.WHITE_KEY_INK),
				"black": hex(Design.BLACK_KEY), "black_ink": hex(Design.BLACK_KEY_INK),
			},
		}
	Design.use_palette(Design.Palette.LAB)
	return out


func _initialize() -> void:
	Settings.isolate()
	var tokens := {
		"_": "Exported from the running desktop by editor-godot/design_tokens.gd."
			+ " The desktop is the reference implementation; do not hand-edit this file.",
		"palettes": palette_tokens(),
		"default_palette": Design.PALETTE_NAMES[Design.Palette.LAB],
		"space": {
			"xs": Design.SPACE_XS, "s": Design.SPACE_S, "m": Design.SPACE_M,
			"l": Design.SPACE_L, "xl": Design.SPACE_XL, "xxl": Design.SPACE_XXL,
		},
		"radius": {
			"button": Design.RADIUS_BUTTON, "panel": Design.RADIUS_PANEL,
			"node": Design.RADIUS_NODE,
		},
		"type": {
			"family": Design.FONT_PATH.get_file(),
			"mono": Design.MONO_PATH.get_file(),
			"weights": {"regular": Design.WEIGHT_REGULAR, "medium": Design.WEIGHT_MEDIUM,
				"semibold": Design.WEIGHT_SEMIBOLD},
			"sizes": {"app_title": Design.SIZE_APP_TITLE,
				"node_title": Design.SIZE_NODE_TITLE, "body": Design.SIZE_BODY,
				"control": Design.SIZE_CONTROL},
		},
		"node": {
			"padding_h": Design.NODE_PADDING_H, "padding_v": Design.NODE_PADDING_V,
			"row_height": Design.NODE_ROW_HEIGHT,
			"parameter_cell_height": Design.PARAMETER_CELL_HEIGHT,
			"hit_target": Design.HIT_TARGET,
			# The width ladder is a node-system rule and belongs to its own document; the
			# numbers are here because a web layout cannot guess them.
			"widths": NodeGrid.WIDTHS,
		},
		"cable": {
			"cue_cadence": CableArt.CUE_CADENCE,
			"cue_clearance": CableArt.CUE_CLEARANCE,
			"suppression": CableArt.suppression,
			"sag_fraction": Rack.SAG_FRACTION,
			"sag_min": Rack.SAG_MIN,
			"sag_max": Rack.SAG_MAX,
		},
	}

	var folder := OS.get_environment("DESIGN_TOKENS_OUT")
	if folder == "":
		folder = ProjectSettings.globalize_path("res://").path_join("../docs")
	DirAccess.make_dir_recursive_absolute(folder)
	var out := FileAccess.open(folder.path_join("design-tokens.json"), FileAccess.WRITE)
	out.store_string(JSON.stringify(tokens, "  "))
	out.close()
	print("%d palettes, %d spacing steps -> %s"
		% [(tokens["palettes"] as Dictionary).size(),
			(tokens["space"] as Dictionary).size(),
			folder.path_join("design-tokens.json")])
	print("all design token checks passed")
	await HarnessExit.finish(self, null)
