extends VBoxContainer
## The face of the whole file: the knobs somebody plays, rather than the graph that makes
## the sound.
##
## It needs no new idea in the document, because the document has had one since v1.
## `controls` is the performance surface — "deliberately separate from the DSP graph: the
## same parameter may be driven by a Godot knob, a browser slider, a DAW automation lane,
## a MIDI CC or a physical encoder without changing the graph", says the schema — and every
## example in this repository carries one. First Synth has seven. Collapse remaps them
## through a module's facade, expand brings them back down, and nothing in the editor has
## ever drawn a single one of them. This draws them.
##
## So a patch has a panel the way a module does, and it is the same kind of thing: a
## selection out of everything the graph could expose, in an order somebody chose, with
## names they chose. The wand puts knobs on it and takes them off.
##
## Values go through the rack's own signals rather than a second copy of the wiring —
## `parameter_changed` already lands in main._on_rack_parameter_changed, which writes the
## document and syncs whichever other view did not originate the change. Two panels
## showing one parameter cannot drift apart about what it is set to.

const Rack := preload("res://rack.gd")
const Seams := preload("res://seams.gd")

## How many *offers* to a line before wrapping. The knob blocks themselves are laid out
## as rack modules in rebuild(); this only shapes the ghost strip under them.
const PER_LINE := 2

## How many groups stack in one slot of the rail. A slot is the rack's module height,
## so at two a group gets half a module — which is what shrinking the faders bought.
const PER_SLOT := 2

## The title band on a block's plate, before UI scaling. Shorter than the rack's own
## TITLE_BAND of 40: that band has to clear a full-height module's mounting rail, and
## these blocks are half that tall, so the same 40px would be a third of the panel.
const BAND := 22

## Inputs that take a signal as *modulation* rather than as sound to be passed on.
##
## The one thing that separates a carrier from a modulator: both reach the output in the
## end, so plain reachability calls everything a carrier. What distinguishes them is
## whether the path gets there through one of these — an operator whose output only ever
## arrives at a `pm` input is felt, never heard.
const MODULATION_PORTS := ["pm", "fm", "fb_mod"]

## The gap between one module and the next, before UI scaling — enough to read as a
## break, and enough to hold the arrow that says what drives what.
const ARROW := 18

## The four parameters that make an envelope, and the letter each wears on the panel.
##
## When a node carries all four they are drawn as a row of vertical sliders instead of
## knobs, because an envelope reads as heights side by side — the sliders *are* the
## shape of the sound, which four dials never quite manage. All four or none: a node
## with only a `decay` has a decay knob, not a one-slider envelope.
const ENVELOPE := {"attack": "A", "decay": "D", "sustain": "S", "release": "R"}

## How far down an offer is turned: enough to read as something available rather than as
## something already on the panel. The same value the module's face uses.
const OFFERED := Color(1.0, 1.0, 1.0, 0.45)

var patch: Dictionary = {}
var registry: Dictionary = {}
var rack: Control = null

## What the case wears: the instrument's name, from main. On the case rather than above
## it because a name floating over a set of plates says less than a name *on* the thing
## the plates are mounted in.
var title := ""

## True while the panel is showing the default rather than the file's own.
##
## A file with no `controls` used to get one line of hint and nothing else — which is most
## of them, since only the hand-written examples carry a panel. A DX7 patch is fifteen nodes
## and sixty-odd knobs and the panel said "no knobs on the face yet", which is true about the
## document and useless about the instrument.
##
## So the default is every knob the patch has, grouped by the node it belongs to. It is a
## view, not an edit: nothing is written until somebody puts a knob on deliberately, and at
## that moment main seeds `controls` from this same list so the default becomes theirs
## rather than being replaced by the one thing they just added.
var derived := false

## The panel's own order, after somebody dragged a knob to a new place in it.
signal reordered(control_ids: Array)

## The node whose knobs are offered under the panel, or "" for none. Set from the selection:
## the offers are what *that* node could put on the face and has not, so choosing a node is
## how you choose what to add.
var offer_node := "":
	set(value):
		offer_node = value
		_carrying = -1
		_target = -1

## A knob was dragged onto the panel from the offers, or off the panel altogether. Both go
## through main._toggle_control, which is a toggle: the panel is the one place a control is
## listed, so putting one on and taking it off are the same edit run twice.
signal offered(node_id: String, parameter: String)

var _cells: Array = []          # Control per cell, panel first then the offers
var _ids: Array = []            # the control ids, panel cells only
## {cell index: {"node", "parameter"}} for the offers, and for the panel's own cells, so a
## drag either way knows what it is holding without asking the document again.
var _offers: Dictionary = {}
var _targets: Dictionary = {}
var _carrying := -1
var _target := -1
## The rail's scroller, kept so _fit_rail can size it once the tree has a size.
var _rail: ScrollContainer = null
## The case it is mounted in, so the fit can measure the name band and rails around it.
var _case: Control = null
## How many rows the rail ended up with, so the fit asks for the height it will use.
var _rail_rows := 1


## First refusal on the press, ahead of the GUI pass — the only reason a cell can be
## picked up at all, since a knob is a Control and would otherwise eat it. See
## PatchGraph._input, which does the same thing for the same reason.
##
## First refusal, not every refusal: see _handle_at. This used to claim every press on
## every cell, which had two consequences and both were wrong. A knob on the panel could
## not be turned — on the surface whose entire purpose is being played. And because a
## release outside the panel means "take this off the face", trying to drag a fader to
## shape an envelope *removed* it. That is what happened to OP4's attack.
func _input(event: InputEvent) -> void:
	if not is_visible_in_tree() or _cells.is_empty():
		return
	var button := event as InputEventMouseButton
	if button != null and button.button_index == MOUSE_BUTTON_LEFT:
		if button.pressed:
			_carrying = _handle_at(button.global_position)
			_target = _carrying
			if _carrying >= 0:
				get_viewport().set_input_as_handled()
		elif _carrying >= 0:
			var from := _carrying
			var to := _target
			_carrying = -1
			_target = -1
			queue_redraw()
			get_viewport().set_input_as_handled()
			_finish(from, to)
		return
	var motion := event as InputEventMouseMotion
	if motion != null and _carrying >= 0:
		_target = _gap_at(motion.global_position) \
			if get_global_rect().has_point(motion.global_position) else -1
		queue_redraw()
		get_viewport().set_input_as_handled()


## What a finished drag meant. Kept apart from _input so the suite can drive it with two
## indices rather than three synthetic events.
func _finish(from: int, to: int) -> void:
	if from < 0 or from >= _cells.size():
		return
	var offer: Dictionary = _offers.get(from, {})
	if not offer.is_empty():
		# From the offers onto the panel. Anywhere on it: an offer has no place on the face
		# yet, so "where" is not a question it can answer, and the panel's own order is what
		# a later drag is for.
		if to >= 0:
			offered.emit(str(offer["node"]), str(offer["parameter"]))
		return
	if to < 0:
		# Off the panel: the same toggle, run the other way.
		var target: Dictionary = _targets.get(from, {})
		if not target.is_empty():
			offered.emit(str(target["node"]), str(target["parameter"]))
		return
	if to == from:
		return
	var moved: Array = _ids.duplicate()
	var name: String = moved[from]
	moved.remove_at(from)
	moved.insert(clampi(to if to < from else to - 1, 0, moved.size()), name)
	reordered.emit(moved)


func _cell_at(point: Vector2) -> int:
	for index in _cells.size():
		if (_cells[index] as Control).get_global_rect().has_point(point):
			return index
	return -1


## The cell a press picks *up*, as against the cell a press plays.
##
## The name is the handle. Grab a control by its caption and it moves; grab it by the dial
## or the track and it turns. The panel is the thing somebody plays, so playing gets the
## larger target and the one you reach for without thinking, and rearranging gets the
## deliberate one — which is also the right way round for damage, since a drag off the
## panel takes the control off the face.
##
## An offer has no value to change, so the whole ghost is a handle: being dragged is the
## only thing it is for.
func _handle_at(point: Vector2) -> int:
	# Nothing outside the panel is a press on the panel. The rail is wider than the
	# window and scrolls, so a cell's rectangle can sit entirely off-screen while still
	# answering a hit test — which is how a drag in the margin picked up a fader nobody
	# could see and dragged it off the face.
	if not get_global_rect().has_point(point):
		return -1
	for index in _cells.size():
		var cell := _cells[index] as Control
		if not cell.get_global_rect().has_point(point):
			continue
		if _offers.has(index):
			return index
		# A fader is played and never picked up. It has no caption to grab — its letter
		# is drawn inside it, at the foot of the track, which is exactly where a hand
		# goes to pull the fader down — so any pickup zone at all sits under the gesture
		# it would interrupt. Twice now that has taken an envelope control off the panel
		# while somebody was setting it, and the four of an envelope only mean anything
		# together: lose one and the other three come back as knobs. The trade is that an
		# envelope cannot be dragged off the face at all, which is the better mistake to
		# be unable to make.
		if cell is Rack.Fader:
			return -1
		for part in cell.get_children():
			var caption := part as Label
			if caption != null and caption.get_global_rect().has_point(point):
				return index
		return -1
	return -1


## The gap a drop would land in, counted in cells: the number of cells whose middle the
## pointer is already past. A gap rather than a cell, because dropping *onto* something
## has to mean either before or after it and there is no way to say which.
func _gap_at(point: Vector2) -> int:
	var gap := 0
	for index in _ids.size():
		var rect: Rect2 = (_cells[index] as Control).get_global_rect()
		if point.y > rect.position.y + rect.size.y or (point.y > rect.position.y
				and point.x > rect.position.x + rect.size.x * 0.5):
			gap += 1
	return gap


func _draw() -> void:
	if _cells.is_empty():
		return
	var inverse := get_global_transform().affine_inverse()
	for index in _cells.size():
		var rect: Rect2 = (_cells[index] as Control).get_global_rect()
		var local := Rect2(inverse * rect.position, rect.size)
		if index == _carrying:
			draw_rect(local, Design.ACCENT, false, 2.0)
		elif _offers.has(index):
			# Only the ghosts keep the dashed outline. Dashed means "this could be acted
			# on", which is exactly what an offer is — but on every panel cell it was
			# forty rectangles of chrome saying the same thing, and the dotted group
			# frames now carry the panel's structure instead.
			Design.dashed_rect(self, local, Color(Design.INK_BRIGHT, 0.7))
	if _carrying < 0 or _target < 0:
		return
	# The caret, in the gap the drop would land in. Past the last cell it goes on the far
	# edge of it, which is the only place left to mean "after everything".
	var edge: Rect2
	var after := _target >= _cells.size()
	edge = (_cells[mini(_target, _cells.size() - 1)] as Control).get_global_rect()
	var at := inverse * (edge.position + (Vector2(edge.size.x, 0.0) if after else Vector2.ZERO))
	draw_rect(Rect2(at - Vector2(1.5, 0.0), Vector2(3.0, edge.size.y)), Design.ACCENT)


func _ready() -> void:
	add_theme_constant_override("separation", Design.SPACE_S)


## The parameter descriptor a control points at, or empty when it points at nothing —
## which happens to a file somebody hand-edited, and to one whose node was deleted.
func _descriptor_for(target: Dictionary) -> Dictionary:
	var node_id := str(target.get("node", ""))
	for node in patch.get("nodes", []):
		if str(node["id"]) != node_id:
			continue
		# Through Seams, not through a copy of its rule kept here. This asked the registry
		# for "Output" and got nothing, because a bound port is filed under
		# `seam:Output/stereo` — so the master level was invisible to the panel, and a
		# control naming it was skipped without a word. The same mistake, third place.
		for parameter in registry.get(Seams.registry_key(node), {}).get("parameters", []):
			if str(parameter["name"]) == str(target.get("parameter", "")):
				return parameter
		return {}
	return {}


## Every knob in the patch, in document order, as control entries. A module instance
## contributes its exported surface; a plain node its own parameters — which is the same
## rule the inspector and the node bodies follow, so the panel shows what the graph shows.
static func default_controls(patch: Dictionary, registry: Dictionary) -> Array:
	var out: Array = []
	for node in patch.get("nodes", []):
		# Ports are not knobs. They appear on the panel, but as the strip below rather than
		# as something to turn.
		if Seams.is_port_seam(node) or str(node.get("type", "")) in ["Input", "Output"]:
			continue
		var key: String = "module:%s" % str(node.get("module", "")) \
			if str(node.get("type", "")) == "module" else str(node.get("type", ""))
		for parameter in registry.get(key, {}).get("parameters", []):
			out.append({
				"id": "%s.%s" % [str(node["id"]), str(parameter["name"])],
				"label": str(parameter.get("display_name", parameter["name"])),
				"kind": "knob",
				"target": {"node": str(node["id"]), "parameter": str(parameter["name"])},
			})
	return out


func rebuild() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_cells.clear()
	_ids.clear()
	_offers.clear()
	_targets.clear()

	var controls: Array = patch.get("controls", [])
	derived = controls.is_empty()
	if derived:
		controls = default_controls(patch, registry)
		if not controls.is_empty():
			var note := Label.new()
			note.text = "Every knob in the patch. Drag one on to start a panel of your own."
			note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			note.add_theme_font_size_override("font_size", Design.type(Design.SIZE_SECONDARY))
			note.add_theme_color_override("font_color", Design.INK_SECOND)
			add_child(note)
	if controls.is_empty():
		# A blank column is indistinguishable from a broken one, and this is the state a
		# patch with nothing to turn is genuinely in.
		var hint := Label.new()
		hint.text = "Nothing to turn in this patch yet."
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		hint.add_theme_font_size_override("font_size", Design.type(Design.SIZE_SECONDARY))
		hint.add_theme_color_override("font_color", Design.INK_SECOND)
		add_child(hint)

	# A rack row, not a column.
	#
	# Forty-three knobs stacked downwards is a list nobody reads to the bottom of. So the
	# panel is shaped like the thing it names: a row of modules on one rail, every block the
	# same height the rack view would give this patch, read sideways the way a hardware case
	# is. One block per node, knobs two across inside it exactly as the rack draws them, and
	# a node with more knobs than one bank holds grows *rightwards* — another two-wide bank
	# on the same panel, a wide module rather than a tall one.
	#
	# The row overflows horizontally and scrolls, because that is what a rack does: a case
	# with more modules than the desk is walked along, not folded. Height is the one thing
	# that never moves — the rail is the promise.
	#
	# A block is never split. The knobs of one node belong together, and half an operator in
	# one place with the rest somewhere else is worse than a longer row.
	#
	# Blocks are runs of the same group *in the order the panel already had*, never a
	# regrouping. A file's own `controls` is an ordered statement of intent and reordering it
	# to tidy the layout would be the panel overruling the author.
	#
	# The group is the control's own `group` field when it has one, and its target node
	# otherwise. The field exists because the panel's blocks and the graph's nodes are not
	# the same idea: an operator and the gain node that sets its level are two nodes in the
	# graph and one instrument on the panel, and only the document's author knows which
	# gains belong to which operators. Panel organization, never graph semantics — the
	# schema says so in as many words.
	var runs: Array = []
	var on_panel := {}
	for index in controls.size():
		var control: Dictionary = controls[index]
		var target: Dictionary = control.get("target", {})
		var descriptor := _descriptor_for(target)
		if descriptor.is_empty():
			continue
		var node_id := str(target.get("node", ""))
		on_panel["%s.%s" % [node_id, str(target.get("parameter", ""))]] = true
		var key: String = str(control.get("group", ""))
		if key == "":
			key = node_id
		if runs.is_empty() or str(runs.back()["key"]) != key:
			runs.append({"key": key, "controls": []})
		(runs.back()["controls"] as Array).append({"control": control,
			"descriptor": descriptor})

	# Which nodes are heard rather than felt, worked out once for the whole panel.
	var audible := _heard_nodes()

	# And which groups are the end of the signal rather than a step along it. A group
	# that drives a port is not a stage of the instrument, it *is* where the instrument
	# stops — so it stands apart from the rows instead of taking a place in one.
	var mixes: Array = []
	var staged: Array = []
	for run: Dictionary in runs:
		var terminal := false
		for entry: Dictionary in (run["controls"] as Array):
			for node in patch.get("nodes", []):
				if str(node["id"]) == str((entry["control"] as Dictionary)
						.get("target", {}).get("node", "")) \
						and str(node.get("type", "")) in ["Input", "Output"]:
					terminal = true
		if terminal:
			mixes.append(run)
		else:
			staged.append(run)
	runs = staged

	if not runs.is_empty() or not mixes.is_empty():
		# The rail takes the room the panel has, up to a rack module and never below what
		# two stacked blocks need. It was a flat Rack.DEFAULT_HEIGHT, which is the right
		# *preference* and a bad rule: 404px of rail plus the ports strip is taller than
		# the inspector on an ordinary window, so the panel scrolled vertically and the
		# second operator of every pair was below the fold — stacking them bought nothing.
		#
		# A rack module is still what it settles at when the room is there. See _fit_rail,
		# which does the measuring once the tree has a size to measure.
		var panel_height: float = _least_block_height()

		var scroller := ScrollContainer.new()
		scroller.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
		scroller.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		scroller.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		scroller.name = "Rack"

		# The case around the whole thing: the instrument's name on it, and its modules
		# mounted inside. The rack row was a set of plates lying on the panel with the
		# file's name floating above them; a case says the obvious thing those plates
		# have in common, which is that they are one instrument and not six.
		#
		# The rails are the rack's own, drawn above and below the row the way they are
		# drawn between rows over there — a case is where modules are mounted, and the
		# rail is what they mount to.
		var case := VBoxContainer.new()
		case.name = "Case"
		case.add_theme_constant_override("separation", 0)
		add_child(case)

		var badge := Label.new()
		badge.name = "Name"
		badge.text = title.to_upper()
		badge.visible = title != ""
		badge.custom_minimum_size.y = Design.scale(BAND)
		badge.add_theme_font_override("font", Design.font(Design.WEIGHT_MEDIUM))
		badge.add_theme_font_size_override("font_size", Design.type(Design.SIZE_CONTROL))
		badge.add_theme_color_override("font_color", Design.INK_BRIGHT)
		badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		badge.clip_text = true
		badge.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		case.add_child(badge)

		var rail_height := float(Design.scale(Rack.RAIL))
		var top_rail := Control.new()
		top_rail.custom_minimum_size.y = rail_height
		top_rail.mouse_filter = Control.MOUSE_FILTER_IGNORE
		case.add_child(top_rail)
		case.add_child(scroller)
		var foot_rail := Control.new()
		foot_rail.custom_minimum_size.y = rail_height
		foot_rail.mouse_filter = Control.MOUSE_FILTER_IGNORE
		case.add_child(foot_rail)

		case.draw.connect(func() -> void:
			case.draw_rect(Rect2(Vector2.ZERO, case.size), Rack.PANEL_LOW.darkened(0.35))
			case.draw_rect(Rect2(Vector2.ZERO, case.size), Rack.PANEL_EDGE, false, 1.0)
			Rack.draw_rail(case, Rect2(top_rail.position, top_rail.size))
			Rack.draw_rail(case, Rect2(foot_rail.position, foot_rail.size)))
		_rail = scroller
		_case = case

		# The rail: rows of modules on the left, and whatever stands full height at the
		# end of the signal on the right.
		var rail := HBoxContainer.new()
		rail.name = "Rail"
		rail.add_theme_constant_override("separation", 0)
		rail.size_flags_vertical = Control.SIZE_EXPAND_FILL
		scroller.add_child(rail)

		# Rows of modules, read left to right and then down — the way a rack case with
		# two rails reads, and the way the chains of an algorithm want to be read. It
		# used to be columns filled top to bottom, which put OP6 above OP5 and started
		# the next column at OP4: the reading order was right but the shape of the voice
		# was cut across it.
		# The ports, at the ends of the rail their signals run towards: in at the left
		# edge, out at the right. Tinted the way the cables are — what arrives is notes
		# and gates, what leaves is sound — so the plates say which direction they are
		# without a word.
		var inputs: Array = []
		var outputs: Array = []
		for node in patch.get("nodes", []):
			if str(node.get("type", "")) == "Input":
				inputs.append(node)
			elif str(node.get("type", "")) == "Output":
				outputs.append(node)
		if not inputs.is_empty():
			var in_plate := _port_plate(inputs, "IN", Design.CONTROL, panel_height)
			in_plate.name = "PortsIn"
			rail.add_child(in_plate)
			rail.add_child(_arrow())

		var rows_column := VBoxContainer.new()
		# Named, like the plates and the mix line beside it. Everything that reads this
		# tree used to identify a part by its class, which meant every part added since
		# broke a reader that had been right the day before — the ports plate is a
		# VBoxContainer too, and the first one on the rail is no longer the rows.
		rows_column.name = "Rows"
		rows_column.add_theme_constant_override("separation", Design.SPACE_S)
		# So the rows inherit the scroller's height rather than collapsing to their own
		# minimums — the whole rail stretches or shrinks as one.
		rows_column.size_flags_vertical = Control.SIZE_EXPAND_FILL
		rail.add_child(rows_column)

		var rows := _rows_of(runs, audible)
		_rail_rows = rows.size()
		var placed: Array = []
		for row: Array in rows:
			var line := HBoxContainer.new()
			line.add_theme_constant_override("separation", Design.SPACE_S)
			line.size_flags_vertical = Control.SIZE_EXPAND_FILL
			# Right-justified, so the last column of every row lines up. A chain ends at
			# the operator you hear, so that column is the carriers — and the thing they
			# all feed sits immediately to its right. Signal runs to the edge and stops.
			line.alignment = BoxContainer.ALIGNMENT_END
			rows_column.add_child(line)
			for chain_index in row.size():
				var chain: Array = row[chain_index]
				for step in chain.size():
					placed.append({"run": runs[chain[step]], "line": line,
						# An arrow after every block but the last of its chain: it says
						# "this drives that", which is only true inside a chain. Between
						# two chains sharing a row there is a gap and no claim.
						"arrow": step < chain.size() - 1})
				if chain_index < row.size() - 1:
					placed.append({"gap": true, "line": line})

		# What stands at the end of the signal, full height beside the rows rather than
		# in one of them: where the chains meet, and the voice's master level. It belongs
		# to the instrument rather than to either chain, and both rows point into it.
		if not mixes.is_empty():
			rail.add_child(_arrow())
			var mix_line := HBoxContainer.new()
			mix_line.name = "Mix"
			mix_line.add_theme_constant_override("separation", Design.SPACE_S)
			mix_line.size_flags_vertical = Control.SIZE_EXPAND_FILL
			rail.add_child(mix_line)
			for run: Dictionary in mixes:
				# Stacked rather than side by side: this is a channel strip, and a strip
				# reads down. It is also signal order — the mix's own level, then the
				# port's — which is the same direction the rows to its left run in.
				placed.append({"run": run, "line": mix_line, "strip": true})

		if not outputs.is_empty():
			rail.add_child(_arrow())
			var out_plate := _port_plate(outputs, "OUT", Design.AUDIO, panel_height)
			out_plate.name = "PortsOut"
			rail.add_child(out_plate)

		for seat: Dictionary in placed:
			# A gap where one chain ends and the next begins on the same row: room
			# enough to read as a break, and nothing drawn in it, because there is
			# nothing to say.
			if seat.get("gap", false):
				var gap := Control.new()
				gap.custom_minimum_size.x = Design.scale(ARROW)
				gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
				(seat["line"] as HBoxContainer).add_child(gap)
				continue
			var run: Dictionary = seat["run"]

			var block := VBoxContainer.new()
			block.add_theme_constant_override("separation", 0)
			# A floor, and an equal share of whatever the row turns out to be: every
			# block on the rail measures the same, whether it got its rack module or
			# the rail had to make do.
			block.custom_minimum_size.y = panel_height
			(seat["line"] as HBoxContainer).add_child(block)

			# Heard or felt. A carrier's sound reaches the ear; a modulator's only ever
			# bends another operator, and the difference is the single most useful thing
			# to know about an FM voice — which of these six am I actually listening to.
			#
			# Said in colour rather than in a word, because the word was the problem: the
			# level knob used to be labelled "index" on modulators, which is Chowning's
			# term for the maths and not a name the DX7 ever uses. Both are "level" now,
			# as Yamaha has it, and the role moved to the plate where it belongs.
			var heard := false
			for entry: Dictionary in run["controls"]:
				if audible.has(str((entry["control"] as Dictionary)
						.get("target", {}).get("node", ""))):
					heard = true

			# The title band, as a rack module wears it: the name in caps on the plate,
			# over the stripe. Only worth saying when there is more than one block; a
			# panel of one group is a panel about one thing and the heading would be
			# repeating the file name back.
			var heading := Label.new()
			heading.text = str(run["key"]).to_upper()
			heading.visible = runs.size() > 1
			heading.custom_minimum_size.y = Design.scale(BAND)
			heading.add_theme_font_override("font", Design.font(Design.WEIGHT_MEDIUM))
			heading.add_theme_font_size_override("font_size",
				Design.type(Design.SIZE_SECONDARY))
			heading.add_theme_color_override("font_color",
				Design.INK_BRIGHT if heard else Design.INK_SECOND)
			heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			heading.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			heading.clip_text = true
			heading.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			# In words too, on demand. A colour is a code somebody has to be taught;
			# the tooltip teaches it, once, wherever the question is being asked.
			heading.tooltip_text = "heard — its sound reaches the output" if heard \
				else "felt — it modulates another part, and is not heard directly"
			heading.mouse_filter = Control.MOUSE_FILTER_STOP
			block.add_child(heading)

			# And the plate under it. A panel block and a rack module are the same object
			# seen twice — one arranged by signal flow, one arranged by the player — so
			# they are drawn by the same function rather than merely resembling each
			# other. This replaces the dotted frame: a grouping drawn as a module edge is
			# a stronger statement than a grouping drawn as a hint, and it is the true
			# one, since these really are the modules the rack view shows.
			# The stripe carries the role rather than the node's category, which on a
			# panel of six identical operators says the same word six times. Audio for
			# heard, control for felt — the same two colours the cables use for the same
			# two ideas, so the panel and the graph teach one vocabulary between them.
			var tint: Color = Design.AUDIO if heard else Design.CONTROL
			block.draw.connect(func() -> void:
				var plate := Rect2(Vector2.ZERO, block.size)
				Rack.draw_plate(block, plate,
					float(heading.size.y) if heading.visible else 0.0, tint)
				# Top rail only: the envelope runs to the bottom edge, and a screw
				# through a fader's letter is a collision, not a detail.
				Rack.draw_screws(block, plate, float(Design.scale(3)), false))

			# All four envelope parameters or none — see ENVELOPE.
			var enveloped := true
			for wanted in ENVELOPE:
				var found := false
				for entry: Dictionary in run["controls"]:
					if str((entry["control"] as Dictionary)
							.get("target", {}).get("parameter", "")) == str(wanted):
						found = true
				if not found:
					enveloped = false

			# Build the cells first, because how many fit in a bank depends on how tall
			# they actually are — the caption and the wiring line under each knob grow
			# with the reader's type size, and a capacity guessed from constants would be
			# wrong at exactly the sizes it matters. Built in document order whatever
			# they are, so _cells keeps the order the file states.
			var cells: Array = []
			var slider_cells: Array = []
			var cell_height := 1.0
			for entry: Dictionary in run["controls"]:
				# The entry's own target, not the run's: a grouped block spans nodes —
				# that being the point of groups — so every cell wires to the node its
				# control actually names.
				var cell_node := str((entry["control"] as Dictionary)
					.get("target", {}).get("node", ""))
				var parameter := str((entry["control"] as Dictionary)
					.get("target", {}).get("parameter", ""))
				var cell: Control
				if enveloped and ENVELOPE.has(parameter):
					var slide := Rack.Fader.new()
					slide.rack = rack
					slide.node_id = cell_node
					slide.descriptor = entry["descriptor"]
					slide.label = str(ENVELOPE[parameter])
					slide.size_flags_horizontal = Control.SIZE_EXPAND_FILL
					slide.size_flags_vertical = Control.SIZE_EXPAND_FILL
					slide.set_value_silently(float(_value_of(cell_node,
						parameter, float(entry["descriptor"].get("default", 0.0)))))
					slider_cells.append(slide)
					cell = slide
				else:
					cell = _cell(entry["control"], entry["descriptor"])
					cells.append(cell)
					cell_height = maxf(cell_height, cell.get_combined_minimum_size().y)
				_targets[_cells.size()] = {"node": cell_node,
					"parameter": parameter}
				_cells.append(cell)
				# Only a panel the file actually has can be rearranged or taken from. The
				# default is a picture of what is there; dragging within it would be
				# dragging within a derivation, and the honest first gesture is putting
				# a knob on.
				if not derived:
					_ids.append(str((entry["control"] as Dictionary).get("id", "")))

			var banks := HBoxContainer.new()
			banks.add_theme_constant_override("separation", Design.SPACE_M)
			block.add_child(banks)

			# The envelope reserves its floor before the banks divide what is left, or a
			# busy node's knobs would push the sliders out of the block's fixed height.
			var reserved := 0.0
			if not slider_cells.is_empty():
				reserved = (slider_cells[0] as Control).get_combined_minimum_size().y \
					+ float(Design.SPACE_S)
			# Three to a row where the rack fits two: the operator's own knobs and its
			# level make three, and a row is how they read as one instrument. One to a
			# row in a strip, where the knobs are stages of a signal rather than
			# settings of one thing, and reading down is reading in order.
			var across: int = 1 if seat.get("strip", false) else 3
			var room: float = panel_height - heading.get_combined_minimum_size().y \
				- reserved
			var pitch: float = cell_height + float(Design.SPACE_S)
			var deep: int = maxi(1, int(floorf((room + float(Design.SPACE_S)) / pitch)))
			# A strip keeps everything in one bank however tall that makes it: it is a
			# column of stages, and spilling stage three into a second column beside
			# stage one would break the only thing the ordering says. The block it sits
			# in is the full height of the rail rather than `panel_height`, so there is
			# more room here than the spill arithmetic above knows about.
			var per_bank: int = cells.size() if seat.get("strip", false) \
				else maxi(deep * across, 1)
			var bank: GridContainer = null
			for cell_index in cells.size():
				if cell_index % maxi(per_bank, 1) == 0:
					bank = GridContainer.new()
					bank.columns = across
					bank.size_flags_horizontal = Control.SIZE_EXPAND_FILL
					bank.add_theme_constant_override("h_separation", Design.SPACE_S)
					bank.add_theme_constant_override("v_separation", Design.SPACE_S)
					banks.add_child(bank)
				bank.add_child(cells[cell_index])

			# The faders sit under the knobs at the same width — one module edge, not two
			# ragged ones — whichever of the two rows is naturally wider, and they take
			# the height the block has left.
			#
			# All of it, now. There used to be an empty spacer here holding the envelope
			# to half the block, because a fader the full height of a rack module dwarfed
			# the knobs above it. Halving the block itself does that job better: the
			# faders are the same size they were, and the room the spacer was holding
			# open goes to the operator stacked underneath instead of to nothing.
			if not slider_cells.is_empty():
				var envelope := HBoxContainer.new()
				envelope.add_theme_constant_override("separation", Design.SPACE_S)
				envelope.size_flags_vertical = Control.SIZE_EXPAND_FILL
				for slide in slider_cells:
					envelope.add_child(slide)
				# Into the tree before it is measured. An orphan control reports a
				# minimum from default theme metrics, a few pixels shy of what it will
				# ask once it inherits the real theme — and a width matched to a lie
				# shows up as one ragged module edge.
				block.add_child(envelope)
				var span: float = maxf(banks.get_combined_minimum_size().x,
					envelope.get_combined_minimum_size().x)
				if span > 0.0:
					envelope.custom_minimum_size.x = span
					banks.custom_minimum_size.x = span

			# And the arrow to the next block in the chain, which is what the gap between
			# modules is for. The panel says which operators there are and what each one
			# is set to; the arrow says what drives what, which is the other half of an
			# algorithm and the half you otherwise have to go and read the graph for.
			if seat.get("arrow", false):
				(seat["line"] as HBoxContainer).add_child(_arrow())

		# The filler that used to pad a half-empty column is gone with the columns. A
		# short row is just a short row — it ends where its chain ends, which is a fact
		# about the algorithm rather than a hole to be plugged.

	# Now that everything else in the panel exists to be measured against.
	if not resized.is_connected(_fit_rail):
		resized.connect(_fit_rail)
	_fit_rail()

	# What the selected node could put on the panel and has not.
	#
	# The same offer the module's face makes, at the file's scale — and the reason there is
	# no tool to raise. The wand asked you to arm a mode and then point at a knob on the
	# canvas; this asks you to select the node you were going to point at anyway, and shows
	# what it has. Only the selection, because every parameter in a large patch is hundreds
	# of knobs and a panel of offers nobody can read is not an offer.
	if offer_node == "":
		return
	var spare: Array = []
	for parameter: Dictionary in registry.get(_type_of(offer_node), {}).get("parameters", []):
		if not on_panel.has("%s.%s" % [offer_node, str(parameter["name"])]):
			spare.append(parameter)
	if spare.is_empty():
		return

	var caption := Label.new()
	caption.text = "%s — not on the panel" % offer_node
	caption.add_theme_font_size_override("font_size", Design.type(Design.SIZE_SECONDARY))
	caption.add_theme_color_override("font_color", Design.INK_SECOND)
	add_child(caption)

	var offer_line: HBoxContainer = null
	for parameter: Dictionary in spare:
		if offer_line == null or offer_line.get_child_count() >= PER_LINE:
			offer_line = HBoxContainer.new()
			offer_line.add_theme_constant_override("separation", Design.SPACE_M)
			offer_line.alignment = BoxContainer.ALIGNMENT_CENTER
			add_child(offer_line)
		var ghost := _cell({"target": {"node": offer_node,
			"parameter": str(parameter["name"])}}, parameter)
		ghost.modulate = OFFERED
		offer_line.add_child(ghost)
		_offers[_cells.size()] = {"node": offer_node, "parameter": str(parameter["name"])}
		_cells.append(ghost)


## The groups laid out in rows, as indices into `runs`.
##
## Rows break at chain boundaries, not every N groups. A chain of an FM algorithm ends at
## the operator you hear — OP6 OP5 OP4 feed OP3, and OP3 is heard — and the panel is
## already written in signal order, so a chain ends exactly at each heard group. That is
## the whole rule: walk the order, close the row's current chain whenever a carrier goes
## past. No new field in the document and nothing FM-specific in the code; a patch whose
## groups are all heard has chains of one, and this degrades to plain row-major.
##
## Chains are never split across rows — the point is to see a chain whole — so a row can
## run longer than its share, and the rail scrolls sideways when they do.
## Returns rows of *chains*, not rows of groups: which groups sit together is one
## question and where one chain stops and the next begins is another, and the arrows
## between blocks depend on the second.
static func rows_of_chains(chains: Array, rows: int) -> Array:
	if chains.is_empty():
		return []
	var total := 0
	for chain: Array in chains:
		total += chain.size()
	var lines: Array = []
	var line: Array = []
	var held := 0
	var share: int = maxi(1, int(ceil(float(total) / float(maxi(rows, 1)))))
	for chain: Array in chains:
		line.append(chain)
		held += chain.size()
		# Full enough, and rows left to put the rest in.
		if held >= share and lines.size() < rows - 1:
			lines.append(line)
			line = []
			held = 0
	if not line.is_empty():
		lines.append(line)
	return lines


## The panel's rows: its groups cut into chains, then packed into at most PER_SLOT of them.
func _rows_of(runs: Array, audible: Dictionary) -> Array:
	var chains: Array = []
	var chain: Array = []
	for run_index in runs.size():
		chain.append(run_index)
		var heard := false
		for entry: Dictionary in (runs[run_index]["controls"] as Array):
			if audible.has(str((entry["control"] as Dictionary)
					.get("target", {}).get("node", ""))):
				heard = true
		if heard:
			chains.append(chain)
			chain = []
	if not chain.is_empty():
		chains.append(chain)
	return rows_of_chains(chains, mini(PER_SLOT, chains.size()))


## A solid triangle pointing the way the signal goes.
##
## Right, always, because the panel is laid out left to right and an arrow that agreed
## with the layout only sometimes would be worse than none. It sits in the gap between
## two modules and means "this one drives that one" — the half of an algorithm that knob
## values cannot tell you, and the half you would otherwise open the graph to read.
func _arrow() -> Control:
	var arrow := Control.new()
	arrow.custom_minimum_size.x = Design.scale(ARROW)
	arrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	arrow.draw.connect(func() -> void:
		var middle := arrow.size * 0.5
		var reach := float(Design.scale(5))
		arrow.draw_colored_polygon([
			middle + Vector2(reach, 0.0),
			middle + Vector2(-reach, -reach),
			middle + Vector2(-reach, reach)], Color(Design.INK_SECOND, 0.8)))
	return arrow


## The nodes whose sound is heard rather than felt — carriers, in FM terms.
##
## Walked backwards from the outputs, refusing to step back through a modulation input.
## Everything in an FM voice reaches the output eventually, so "reaches the output" calls
## all six operators carriers; what makes OP3 a carrier and OP6 a modulator is that OP6's
## only road out runs through OP5's `pm`.
##
## Derived from the wiring rather than declared in the document, so it stays true when
## somebody rewires the patch — a carrier is not a property the file asserts, it is a
## thing the cables make so.
func _heard_nodes() -> Dictionary:
	var reached := {}
	var frontier: Array = []
	for node in patch.get("nodes", []):
		if str(node.get("type", "")) == "Output":
			frontier.append(str(node["id"]))
	while not frontier.is_empty():
		var at: String = frontier.pop_back()
		if reached.has(at):
			continue
		reached[at] = true
		for wire in patch.get("connections", []):
			if str(wire.get("to", {}).get("node", "")) != at:
				continue
			if str(wire.get("to", {}).get("port", "")) in MODULATION_PORTS:
				continue
			frontier.append(str(wire.get("from", {}).get("node", "")))
	return reached


## The least a block can be and still hold what a block holds: a heading, one row of
## knobs, and an envelope under it.
##
## Derived rather than declared, because every term grows with the reader's type size —
## a constant that fits at COMFORTABLE is a clipped block at XL.
func _least_block_height() -> float:
	var probe := Rack.Fader.new()
	probe.rack = rack
	probe.descriptor = {"name": "probe", "min": 0.0, "max": 1.0}
	var fader: float = probe.get_combined_minimum_size().y
	probe.queue_free()
	return float(Design.type(Design.SIZE_SECONDARY)) + 6.0 \
		+ Design.scale(Design.HIT_TARGET) + float(Design.type(Design.SIZE_BODY)) + 6.0 \
		+ fader + float(Design.SPACE_S)


## The fitting rule itself, on numbers: what is left of `room` after `taken`, never above
## a rack module and never below what two stacked blocks need.
##
## Pulled out as a static function so it can be checked at the sizes that matter. A
## headless run keeps its root at 900px whatever the window is set to, so the short-window
## case — the only one that can fail — cannot be staged in the tree, and a check that
## cannot reach the failing case is not a check.
static func rail_height(room: float, taken: float, least: float, natural: float) -> float:
	if room <= 0.0:
		return natural
	return clampf(room - taken, least, natural)


## Sizes the rail to the room the panel actually has.
##
## Two operators only "fit" if they fit *on screen* — a rail taller than the inspector
## puts the second one below a scrollbar, which is the same as not stacking them. So the
## rail asks for what is left after everything else in the panel, capped at a rack module
## (taller than that is not a rack row any more) and floored at two blocks' minimum
## (below that the knobs start clipping, and a scrollbar is the honest answer).
##
## The room is measured from the inspector's own viewport rather than from this control,
## whose height is the thing being decided — asking it would be asking the question with
## the answer. Re-run on resize, because the window is where the room comes from.
func _fit_rail() -> void:
	if _rail == null or not is_instance_valid(_rail):
		return
	var bar: float = float(Design.scale(14))
	# The height the rail will actually use, not always two blocks': a panel that came
	# out as one row should not reserve room for a row it does not have.
	var stacked: int = maxi(_rail_rows, 1)
	var least: float = _least_block_height() * float(stacked) \
		+ float(Design.SPACE_S) * float(stacked - 1)
	var wanted: float = float(Design.scale(Rack.DEFAULT_HEIGHT))

	var viewport: ScrollContainer = null
	var above: Node = get_parent()
	while above != null:
		if above is ScrollContainer:
			viewport = above as ScrollContainer
			break
		above = above.get_parent()
	if viewport != null and viewport.size.y > 0.0:
		# What the rest of the inspector is using: the scrolled content's height less
		# our own. Everything above and below the faces, without naming any of it.
		var content := viewport.get_child(0) as Control
		var elsewhere: float = 0.0
		if content != null:
			elsewhere = maxf(content.size.y - size.y, 0.0)
		# And what this control holds besides the rail — the ports strip, the offers.
		# Everything in the panel that is not the rail itself — including the case's own
		# name band and rails, which sit between the two and would otherwise be counted
		# as part of neither. Measuring the case as a whole would count the rail twice,
		# since the rail is inside it.
		var mine: float = 0.0
		for child in get_children():
			var part := child as Control
			if part != null and part != _case and part.visible:
				mine += part.get_combined_minimum_size().y + float(Design.SPACE_S)
		if _case != null:
			for child in _case.get_children():
				var part := child as Control
				if part != null and part != _rail and part.visible:
					mine += part.get_combined_minimum_size().y
		wanted = rail_height(viewport.size.y, elsewhere + mine + bar, least, wanted)

	# Only when it moves. Writing the same minimum back invalidates the layout, which
	# is what called this, which would write it back again.
	if absf(_rail.custom_minimum_size.y - (wanted + bar)) > 1.0:
		_rail.custom_minimum_size.y = wanted + bar


## Where this file meets the machine: a plate of ports, standing at the end of the rail
## that its signals run towards.
##
## On the panel because the panel is the file's face, and a face has its sockets on it —
## "what do I plug in, and where does it come out" is the other half of "what do I turn".
## Beside the rack rather than under it, because a port is where the signal starts or
## stops, and the rail already reads left to right: in at the left edge, out at the right.
## As a list beneath everything it was a footnote about the instrument's edges rather than
## a picture of them.
##
## Read-only here: a port is moved by dragging its jack on the keyboard, which is the
## gesture that already exists for it.
func _port_plate(seams: Array, title: String, tint: Color, height: float) -> Control:
	var plate := VBoxContainer.new()
	plate.add_theme_constant_override("separation", 0)
	plate.custom_minimum_size.y = height

	var heading := Label.new()
	heading.text = title
	heading.custom_minimum_size.y = Design.scale(BAND)
	heading.add_theme_font_override("font", Design.font(Design.WEIGHT_MEDIUM))
	heading.add_theme_font_size_override("font_size", Design.type(Design.SIZE_SECONDARY))
	heading.add_theme_color_override("font_color", Design.INK_BRIGHT)
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	heading.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	plate.add_child(heading)
	plate.draw.connect(func() -> void:
		var face := Rect2(Vector2.ZERO, plate.size)
		Rack.draw_plate(plate, face, float(heading.size.y), tint)
		Rack.draw_screws(plate, face, float(Design.scale(3)), false))

	var inside := VBoxContainer.new()
	inside.add_theme_constant_override("separation", Design.SPACE_S)
	inside.size_flags_vertical = Control.SIZE_EXPAND_FILL
	plate.add_child(inside)

	for node: Dictionary in seams:
		var name_label := Label.new()
		var shown := str(node.get("name", ""))
		if shown == "":
			shown = str(node["id"])
		name_label.text = shown
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_label.clip_text = true
		name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		name_label.add_theme_font_size_override("font_size",
			Design.type(Design.SIZE_CONTROL))
		inside.add_child(name_label)

		var where := Label.new()
		var host := str(node.get("host", ""))
		# What is plugged into it, or that nothing is — which is a state that means
		# something now: a port nothing drives is one this patch offers to whatever uses it.
		where.text = host if host != "" else "not plugged in"
		where.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		where.add_theme_font_size_override("font_size", Design.type(Design.SIZE_SECONDARY))
		where.add_theme_color_override("font_color",
			Design.INK_SECOND if host != "" else Design.INK_DISABLED)
		inside.add_child(where)

		# And the signals themselves, which is what a socket actually is. A keyboard is
		# not one wire: it hands over frequency, gate, velocity and trigger, and this
		# patch takes the first two. All four are listed rather than only the two in use,
		# because the unused ones are the reason to come back to this plate — they are
		# what else is already there, and a list of only what is wired could never tell
		# you that. Lit in the signal's own colour when a cable is on them, dim when not:
		# the difference between "this patch uses it" and "this port has it".
		var wired := {}
		for wire in patch.get("connections", []):
			for end_of in [wire.get("from", {}), wire.get("to", {})]:
				if str(end_of.get("node", "")) == str(node["id"]):
					wired[str(end_of.get("port", ""))] = true
		var descriptor: Dictionary = registry.get(Seams.registry_key(node), {})
		# An Input hands signals to the patch and an Output takes them, so the side that
		# faces the patch is the opposite one each time. The host jack is left out: the
		# line above already says what is plugged into it.
		for port: Dictionary in descriptor.get(
				"outputs" if str(node.get("type", "")) == "Input" else "inputs", []):
			var port_name := str(port.get("name", ""))
			if port_name == Seams.HOST_PORT:
				continue
			# The socket itself, drawn by the rack's own function — a port on the panel
			# and a port on a module are the same socket seen twice. It faces the way it
			# does on the module: a seam's outputs are what the patch takes, so they wear
			# the filled pip an output has there, and an Output seam's inputs wear the
			# ring. Same symbol, same side, wherever you meet it.
			var lit: bool = wired.has(port_name)
			var signal_name := str(port.get("signal", "control"))
			var ink: Color = Design.signal_colour(signal_name) if lit \
				else Design.INK_DISABLED
			var facing := str(node.get("type", "")) == "Output"

			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", Design.SPACE_S)
			row.alignment = BoxContainer.ALIGNMENT_CENTER
			var socket := Control.new()
			var radius := float(Design.scale(7))
			socket.custom_minimum_size = Vector2(radius * 2.0, radius * 2.0)
			socket.mouse_filter = Control.MOUSE_FILTER_IGNORE
			socket.draw.connect(func() -> void:
				Rack.draw_socket(socket, socket.size * 0.5, radius, facing, ink))
			row.add_child(socket)

			var line := Label.new()
			line.text = port_name
			line.clip_text = true
			line.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			line.add_theme_font_size_override("font_size",
				Design.type(Design.SIZE_SECONDARY))
			line.add_theme_color_override("font_color", ink)
			line.tooltip_text = "%s — %s" % [signal_name, "in use" if lit else "free"]
			row.add_child(line)
			inside.add_child(row)
	return plate


## The registry key of a node in this patch — a module's synthesized entry or its plain
## type. Same rule as _descriptor_for, which is where it came from.
func _type_of(node_id: String) -> String:
	for node in patch.get("nodes", []):
		if str(node["id"]) != node_id:
			continue
		return Seams.registry_key(node)
	return ""


## One knob and its name. The name is the control's label when it has one, since that is
## the whole point of a label — "Cutoff" is what a player calls it and `cutoff` is what
## the graph calls it, and the file has room for both.
func _cell(control: Dictionary, descriptor: Dictionary) -> Control:
	var cell := VBoxContainer.new()
	cell.add_theme_constant_override("separation", 0)
	cell.alignment = BoxContainer.ALIGNMENT_CENTER
	cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Two-thirds of a rack pitch, so three knobs sit in the width the rack gives two —
	# ratio, feedback and level are a row, and a row is how an operator reads as one
	# instrument. It is a floor and not a size: a knob that needs more at a large UI
	# scale still gets it, and every cell shares the floor so a row of knobs sits at one
	# spacing rather than at whatever width each caption happened to want.
	cell.custom_minimum_size.x = Design.scale(Rack.KNOB_CELL.x * 2.0 / 3.0)

	var target: Dictionary = control.get("target", {})
	var knob := Rack.Knob.new()
	knob.rack = rack
	knob.compact = true
	# A smaller dial, not smaller text — a smaller circle is still a circle, but a
	# smaller label is a squint. Sized so the dial clears its cell's two-thirds pitch.
	knob.dial = 0.72
	knob.node_id = str(target.get("node", ""))
	knob.descriptor = descriptor
	knob.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var current: float = float(_value_of(str(target.get("node", "")),
		str(target.get("parameter", "")), float(descriptor.get("default", 0.0))))
	knob.set_value_silently(current)
	cell.add_child(knob)

	var caption := Label.new()
	caption.text = str(control.get("label", "")) if str(control.get("label", "")) != "" \
		else str(target.get("parameter", ""))
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	caption.clip_text = true
	caption.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	caption.add_theme_font_override("font", Design.font(Design.WEIGHT_MEDIUM))
	caption.add_theme_font_size_override("font_size", Design.type(Design.SIZE_BODY))
	caption.add_theme_color_override("font_color", Design.INK_NORMAL)
	# What it actually drives, in the tooltip rather than under the knob. It used to be a
	# printed line — "op3.feedback" beneath every caption — which is a third of a cell's
	# height spent restating what the block already says: the dotted frame names the
	# group, so a knob inside it labelled "fb" needs no "op3." in front. The tooltip
	# keeps the panel traceable back to the graph after a caption is renamed, which is
	# the one job that line genuinely had.
	caption.tooltip_text = "%s.%s" % [str(target.get("node", "")),
		str(target.get("parameter", ""))]
	cell.add_child(caption)
	return cell


func _value_of(node_id: String, parameter: String, fallback: float) -> float:
	for node in patch.get("nodes", []):
		if str(node["id"]) == node_id:
			return float(node.get("parameters", {}).get(parameter, fallback))
	return fallback
