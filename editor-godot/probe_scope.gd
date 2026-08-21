extends VBoxContainer
## The probe scope: an external instrument for looking at any wire.
##
## The modules' own little scopes show their owner's output; this one is the bench
## instrument you clip onto a signal you do not trust. Point the probe at any output
## port and the engine captures a contiguous ring of that wire; the panel triggers
## on it like a bench scope — rising edge, or an external gate — and draws a chosen
## number of periods of a chosen fundamental, spelled in hertz or as a note.
##
## Three capture moods, cycled on one button:
##   live          redraw every frame; unlocked signal free-runs from the tail
##   freeze first  the first locked capture holds until Arm is pressed again
##   freeze each   holds the last locked capture, replaced on every new trigger
##
## The panel owns the pointing and the drawing; the engine owns the samples. Main
## hands over the engine and the list of wires, and refreshes the list on rebuild.

enum Mode { LIVE, FREEZE_FIRST, FREEZE_EACH }

const MODE_NAMES := ["live", "freeze first", "freeze each"]

var engine = null
var sample_rate := 48000.0

# What the probe and the gate point at: {"node": id, "port": name}, empty = nothing.
var probe: Dictionary = {}
var gate: Dictionary = {}
var _sources: Array = []
var _gates: Array = []

var note_mode := false
var base_hz := 220.0
var base_note := 57
var periods := 2
var mode: int = Mode.LIVE
var frozen := false

# What the display draws, and whether a trigger anchored it.
var window: PackedFloat32Array = PackedFloat32Array()
var locked := false

var source_pick: OptionButton
var gate_pick: OptionButton
var base_toggle: Button
var base_field: ValueField
var periods_field: ValueField
var mode_button: Button
var arm_button: Button
var trigger_label: Label
var level_field: ValueField
var level_auto: Button
## Where the trigger sits, in signal units. INF is auto — midway between the wire's
## own floor and ceiling, which is right until the moment it is not: a drum bus wants
## the trigger above the hats, and only a hand knows that.
var trigger_level := INF
var display: Control


func base_frequency() -> float:
	if note_mode:
		return 440.0 * pow(2.0, float(base_note - 69) / 12.0)
	return base_hz


func window_span() -> int:
	# Two seconds at most: sixteen periods of 10 Hz fit, and the engine's ring is
	# still several windows deep, so a slow sweep's edge stays catchable for
	# seconds rather than for a sliver.
	return clampi(int(sample_rate * float(periods) / maxf(10.0, base_frequency())),
		32, 96000)


func _ready() -> void:
	add_theme_constant_override("separation", Design.SPACE_S)

	# The wire under the probe, and the wire that pulls the trigger.
	source_pick = OptionButton.new()
	source_pick.fit_to_longest_item = false
	source_pick.item_selected.connect(_on_source_picked)
	add_child(_quiet(source_pick))
	gate_pick = OptionButton.new()
	gate_pick.fit_to_longest_item = false
	gate_pick.item_selected.connect(_on_gate_picked)
	add_child(_quiet(gate_pick))

	# Timebase: how many periods of what fundamental, said in Hz or as a note.
	var time_row := HBoxContainer.new()
	time_row.add_theme_constant_override("separation", Design.SPACE_S)
	base_toggle = Button.new()
	base_toggle.text = "Hz"
	base_toggle.tooltip_text = "How the timebase is spelled: a frequency, or the note " \
		+ "whose period it is."
	base_toggle.pressed.connect(_flip_base_mode)
	time_row.add_child(_quiet(base_toggle))
	base_field = ValueField.new()
	base_field.centred = true
	base_field.custom_minimum_size.x = Design.scale(96)
	base_field.default_value = 220.0
	base_field.to_value = func(position: float) -> float:
		if note_mode:
			return 24.0 + 72.0 * clampf(position, 0.0, 1.0)
		return 10.0 * pow(500.0, clampf(position, 0.0, 1.0))
	base_field.to_position = func(value: float) -> float:
		if note_mode:
			return clampf((value - 24.0) / 72.0, 0.0, 1.0)
		return clampf(log(value / 10.0) / log(500.0), 0.0, 1.0)
	base_field.value_submitted.connect(_on_base_submitted)
	time_row.add_child(base_field)
	periods_field = ValueField.new()
	periods_field.centred = true
	periods_field.custom_minimum_size.x = Design.scale(72)
	periods_field.default_value = 2.0
	periods_field.to_value = func(position: float) -> float:
		return 1.0 + 15.0 * clampf(position, 0.0, 1.0)
	periods_field.to_position = func(value: float) -> float:
		return clampf((value - 1.0) / 15.0, 0.0, 1.0)
	periods_field.value_submitted.connect(func(value: float) -> void:
		periods = clampi(int(round(value)), 1, 16)
		periods_field.text = "%d per." % periods)
	time_row.add_child(periods_field)
	add_child(time_row)

	# The capture mood, and the way back in from a freeze.
	var mode_row := HBoxContainer.new()
	mode_row.add_theme_constant_override("separation", Design.SPACE_S)
	mode_button = Button.new()
	mode_button.tooltip_text = "Live redraws always; freeze first holds the first " \
		+ "locked capture; freeze each holds the newest."
	mode_button.pressed.connect(func() -> void:
		mode = (mode + 1) % 3
		frozen = false
		_refresh_words())
	mode_row.add_child(_quiet(mode_button))
	arm_button = Button.new()
	arm_button.text = "Arm"
	arm_button.tooltip_text = "Let go of the frozen picture and wait for the next trigger."
	arm_button.pressed.connect(func() -> void:
		frozen = false
		_refresh_words())
	mode_row.add_child(_quiet(arm_button))
	trigger_label = Label.new()
	trigger_label.text = "trig 0"
	trigger_label.tooltip_text = "Rising edges the trigger wire has fired since the " 		+ "probe was pointed — counted in the engine, where no pulse can be missed."
	trigger_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	trigger_label.add_theme_font_size_override("font_size",
		Design.type(Design.SIZE_SECONDARY))
	trigger_label.add_theme_color_override("font_color", Design.INK_SECOND)
	mode_row.add_child(trigger_label)
	level_field = ValueField.new()
	level_field.centred = true
	level_field.custom_minimum_size.x = Design.scale(84)
	level_field.text = "level auto"
	level_field.default_value = 0.0
	level_field.position_now = 0.5
	level_field.to_value = func(position: float) -> float:
		return -1.2 + 2.4 * clampf(position, 0.0, 1.0)
	level_field.to_position = func(value: float) -> float:
		return clampf((value + 1.2) / 2.4, 0.0, 1.0)
	level_field.value_submitted.connect(func(value: float) -> void:
		trigger_level = clampf(value, -1.2, 1.2)
		level_field.text = "level %.2f" % trigger_level
		level_auto.visible = true
		if display != null:
			display.queue_redraw())
	level_field.tooltip_text = "Where the trigger sits, in signal units. Drag to set " \
		+ "it by hand; auto keeps it midway between the wire's own floor and ceiling."
	mode_row.add_child(level_field)
	level_auto = Button.new()
	level_auto.flat = true
	level_auto.text = "auto"
	level_auto.visible = false
	level_auto.tooltip_text = "Back to the automatic level."
	level_auto.pressed.connect(func() -> void:
		trigger_level = INF
		level_field.text = "level auto"
		level_field.position_now = 0.5
		level_auto.visible = false
		if display != null:
			display.queue_redraw())
	mode_row.add_child(_quiet(level_auto))
	add_child(mode_row)

	display = ScopeDisplay.new()
	display.panel = self
	display.size_flags_vertical = Control.SIZE_EXPAND_FILL
	display.custom_minimum_size.y = Design.scale(160)
	add_child(display)

	_refresh_words()
	_refresh_fields()


func _quiet(control: Control) -> Control:
	control.focus_mode = Control.FOCUS_NONE
	return control


func _flip_base_mode() -> void:
	# Carry the value across the flip, so the window does not jump: the note nearest
	# the frequency, or the frequency of the note.
	if note_mode:
		base_hz = base_frequency()
	else:
		base_note = clampi(int(round(69.0 + 12.0 * log(base_hz / 440.0) / log(2.0))),
			24, 96)
	note_mode = not note_mode
	frozen = false
	_refresh_words()
	_refresh_fields()


func _on_base_submitted(value: float) -> void:
	if note_mode:
		base_note = clampi(int(round(value)), 24, 96)
	else:
		base_hz = clampf(value, 10.0, 5000.0)
	frozen = false
	_refresh_fields()


func _refresh_words() -> void:
	if mode_button != null:
		mode_button.text = MODE_NAMES[mode]
	if arm_button != null:
		arm_button.visible = mode != Mode.LIVE
	if base_toggle != null:
		base_toggle.text = "Note" if note_mode else "Hz"


func _refresh_fields() -> void:
	if base_field == null:
		return
	if note_mode:
		base_field.text = Keyboard.note_name(base_note)
		base_field.position_now = base_field.to_position.call(float(base_note))
	else:
		base_field.text = "%d Hz" % int(round(base_hz))
		base_field.position_now = base_field.to_position.call(base_hz)
	periods_field.text = "%d per." % periods


## Main hands the panel the wires it may probe. `sources` are every output port;
## `gates` the control-typed ones. Selections survive when their wire still exists.
func refresh_sources(sources: Array, gates: Array) -> void:
	_sources = sources
	_gates = gates
	source_pick.clear()
	source_pick.add_item("probe: pick a wire")
	var keep_probe := 0
	for index in sources.size():
		var entry: Dictionary = sources[index]
		source_pick.add_item("probe: %s.%s" % [entry["node"], entry["port"]])
		if not probe.is_empty() and entry["node"] == probe.get("node") \
				and entry["port"] == probe.get("port"):
			keep_probe = index + 1
	source_pick.selected = keep_probe
	if keep_probe == 0:
		probe = {}
	gate_pick.clear()
	gate_pick.add_item("trigger: the signal itself")
	var keep_gate := 0
	for index in gates.size():
		var entry: Dictionary = gates[index]
		gate_pick.add_item("trigger: %s.%s" % [entry["node"], entry["port"]])
		if not gate.is_empty() and entry["node"] == gate.get("node") \
				and entry["port"] == gate.get("port"):
			keep_gate = index + 1
	gate_pick.selected = keep_gate
	if keep_gate == 0:
		gate = {}
	_point_probes()


func _on_source_picked(index: int) -> void:
	probe = {} if index <= 0 else (_sources[index - 1] as Dictionary).duplicate()
	frozen = false
	_point_probes()


func _on_gate_picked(index: int) -> void:
	gate = {} if index <= 0 else (_gates[index - 1] as Dictionary).duplicate()
	frozen = false
	_point_probes()


func _point_probes() -> void:
	if engine == null:
		return
	if probe.is_empty():
		engine.set_scope_tap("", "")
	else:
		engine.set_scope_tap(str(probe["node"]), str(probe["port"]))
	if gate.is_empty():
		engine.set_scope_gate("", "")
	else:
		engine.set_scope_gate(str(gate["node"]), str(gate["port"]))


func _process(_delta: float) -> void:
	if not is_visible_in_tree():
		return
	capture()


## One look at the wire: pull the rings, find the trigger, cut the window.
func capture() -> void:
	if engine == null or probe.is_empty():
		return
	var span := window_span()
	# The whole ring, always: a periodic signal crosses again soon, but a sparse
	# one — a gate, a trigger line — may have stepped long before the window's
	# worth of samples, and the probe exists precisely for wires like those.
	var reach := 262144
	var stream: PackedFloat32Array = engine.get_scope_tap(reach)
	if stream.size() < span:
		return
	var start := -1
	if not gate.is_empty():
		var edges: PackedFloat32Array = engine.get_scope_gate(reach)
		start = _last_edge(edges, span, 0.5)
	else:
		# The trigger sits midway between what the signal actually reaches. Zero is
		# right for audio and never right for a gate, which spends its whole life
		# at or above zero — hunting a zero crossing, the scope only ever caught a
		# gate when free-run happened to align. A flat wire offers no edge at all.
		var level := trigger_level if is_finite(trigger_level) \
			else _trigger_level(stream)
		if is_finite(level):
			start = _last_edge(stream, span, level)
	# The trigger sits a quarter of the way in, the way a bench scope parks it:
	# what led up to the edge is usually the half of the story being debugged.
	var begin: int = maxi(0, start - span / 4) if start >= 0 else stream.size() - span
	match mode:
		Mode.LIVE:
			locked = start >= 0
			window = stream.slice(begin, begin + span)
		Mode.FREEZE_FIRST:
			if frozen:
				return
			if start >= 0:
				window = stream.slice(begin, begin + span)
				locked = true
				frozen = true
		Mode.FREEZE_EACH:
			if start >= 0:
				window = stream.slice(begin, begin + span)
				locked = true
	if trigger_label != null:
		trigger_label.text = "trig %d" % (engine.get_scope_gate_edges()
			if not gate.is_empty() else engine.get_scope_tap_edges())
	if display != null:
		display.queue_redraw()


## Midway between the stream's floor and ceiling, or INF for a wire too flat to
## offer an edge worth locking to.
func _trigger_level(samples: PackedFloat32Array) -> float:
	var lowest := INF
	var highest := -INF
	for value in samples:
		lowest = minf(lowest, value)
		highest = maxf(highest, value)
	if highest - lowest < 0.02:
		return INF
	return (highest + lowest) * 0.5


## The latest rising crossing of `level` that still leaves a whole window after it.
func _last_edge(samples: PackedFloat32Array, span: int, level: float) -> int:
	var at := samples.size() - span - 1
	while at > 0:
		if samples[at] >= level and samples[at - 1] < level:
			return at
		at -= 1
	return -1


## The drawing: grid, period marks, trace, and whether the trigger has hold of it.
class ScopeDisplay extends Control:
	var panel = null

	func _draw() -> void:
		var box := Rect2(Vector2.ZERO, size)
		draw_rect(box, Color(0.0, 0.0, 0.0, 0.35))
		draw_rect(box, Color(1.0, 1.0, 1.0, 0.12), false, 1.0)
		# The centre line, and a mark at each period of the chosen fundamental.
		draw_line(Vector2(0.0, size.y * 0.5), Vector2(size.x, size.y * 0.5),
			Color(1.0, 1.0, 1.0, 0.10), 1.0)
		if panel == null:
			return
		for period in range(1, panel.periods):
			var x: float = size.x * float(period) / float(panel.periods)
			draw_line(Vector2(x, 0.0), Vector2(x, size.y),
				Color(1.0, 1.0, 1.0, 0.07), 1.0)
		var wave: PackedFloat32Array = panel.window
		if wave.is_empty():
			var font := Design.font(Design.WEIGHT_MEDIUM)
			draw_string(font, Vector2(Design.scale(12), size.y * 0.5),
				"point the probe at a wire", HORIZONTAL_ALIGNMENT_LEFT, -1.0,
				Design.type(Design.SIZE_SECONDARY), Design.INK_SECOND)
			return
		# A gate never goes below zero, and drawn on the audio axis it lived in the
		# top half with its floor on the centre line. A unipolar signal gets the
		# floor near the bottom of the box instead, so high and low read as high
		# and low.
		var lowest := 1.0e9
		for value in wave:
			lowest = minf(lowest, value)
		var unipolar: bool = lowest >= -0.02
		# The trace, one point per pixel column: enough for the eye, cheap for the CPU.
		var columns: int = maxi(2, int(size.x))
		var points := PackedVector2Array()
		points.resize(columns)
		for column in columns:
			var sample: float = wave[mini(wave.size() - 1,
				int(float(column) * float(wave.size()) / float(columns)))]
			var y: float
			if unipolar:
				y = size.y * 0.88 - clampf(sample, 0.0, 1.2) * size.y * 0.76
			else:
				y = size.y * 0.5 - clampf(sample, -1.2, 1.2) * size.y * 0.42
			points[column] = Vector2(float(column) * size.x / float(columns - 1), y)
		if unipolar:
			draw_line(Vector2(0.0, size.y * 0.88), Vector2(size.x, size.y * 0.88),
				Color(1.0, 1.0, 1.0, 0.10), 1.0)
		if is_finite(panel.trigger_level):
			# The hand-set trigger, drawn where it actually cuts the trace.
			var mark: float
			if unipolar:
				mark = size.y * 0.88 - clampf(panel.trigger_level, 0.0, 1.2) \
					* size.y * 0.76
			else:
				mark = size.y * 0.5 - clampf(panel.trigger_level, -1.2, 1.2) \
					* size.y * 0.42
			draw_line(Vector2(0.0, mark), Vector2(size.x, mark),
				Color(Design.WARNING.r, Design.WARNING.g, Design.WARNING.b, 0.55), 1.0)
			draw_string(Design.numeric_font(), Vector2(Design.scale(4), mark - 3.0),
				"T", HORIZONTAL_ALIGNMENT_LEFT, -1.0, Design.scale(10),
				Color(Design.WARNING.r, Design.WARNING.g, Design.WARNING.b, 0.8))
		draw_polyline(points, Design.ACCENT, 1.5, true)
		# The lock lamp: lit when a trigger anchored this picture.
		draw_circle(Vector2(size.x - Design.scale(12), Design.scale(12)),
			Design.scale(4), Design.ACCENT if panel.locked
				else Color(1.0, 1.0, 1.0, 0.25))
