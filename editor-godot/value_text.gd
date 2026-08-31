class_name ValueText
extends RefCounted

## A parameter value, written the way somebody would say it.
##
## `gain 0.700` is a debugger printing a float. `gain 0.7` is an instrument telling you
## its setting. The number is the same; what changed is a claim about resolution, and the
## first one is claiming a thousandth of a gain step matters when it does not.
##
## The old rule keyed the number of decimals to the *value's* magnitude — three under one,
## two under ten, one under a thousand — which is why every value on a normalised control
## wore three decimals whatever the control was. Two decimals of a cutoff in hertz and
## three of a resonance are not the same amount of information, and a value's own size is
## the wrong thing to ask.
##
## What is asked instead is the **parameter descriptor**: its range, its unit, and whether
## it is an enumeration. There is one implementation and both the graph and the rack call
## it, where there used to be two identical copies drifting quietly apart.
##
## ## Display only
##
## Nothing here is stored, parsed back, compared or sent anywhere. A patch keeps the float
## it always kept, in the units it always kept them in, and this decides how to write it
## on a face. The dsp-core is the authority on what a value *is*; this is the authority on
## how it is spelt.

## How many display steps a parameter's whole range should be able to show.
##
## A knob is dragged across a couple of hundred pixels, so a few hundred distinguishable
## readings across its travel is the resolution a hand actually has. Five hundred is that
## with room to spare, and it is what turns a 0-to-4 gain into thousandths (0.008 a step)
## and a 20-to-20000 hertz cutoff into whole hertz — two different answers from one rule,
## which is the point.
const STEPS := 500.0

## The fewest significant figures a value keeps, whatever its range says.
##
## The range rule alone is wrong at the bottom of a wide exponential parameter: an attack
## of half a millisecond on a range of ten seconds would round to nothing and the display
## would read `0 ms` for a value that is not zero. Three figures is the floor that stops
## a number becoming a different number.
const FIGURES := 3.0

## And a ceiling, so a parameter with a very small range cannot ask for a readout nobody
## can take in at a glance.
const MAX_DECIMALS := 4


## The value, its unit, and nothing else: "900 Hz", "0.55", "10 ms", "lowpass".
static func of(descriptor: Dictionary, value: float) -> String:
	if descriptor.has("enum"):
		var options: Array = descriptor["enum"]
		if options.is_empty():
			return ""
		return str(options[clampi(int(round(value)), 0, options.size() - 1)])
	var shown := _shown(descriptor, value)
	var unit: String = shown["unit"]
	var written := _write(float(shown["value"]), int(shown["decimals"]))
	return written if unit == "" else "%s %s" % [written, unit]


## The number without its unit, for a caller that draws the unit itself.
static func number(descriptor: Dictionary, value: float) -> String:
	if descriptor.has("enum"):
		return of(descriptor, value)
	var shown := _shown(descriptor, value)
	return _write(float(shown["value"]), int(shown["decimals"]))


## The widest string this parameter will ever show.
##
## Not the longer of its two ends. Stripping trailing zeros means the extremes are often
## the *shortest* readings a parameter has — a gain of 0 to 4 writes its ends as "0" and
## "4" while everything in between writes "0.75" — and a cell sized on the ends would be
## too narrow for almost every value it goes on to hold. So the worst case is built:
## a sign if the range has one, the integer digits of the larger end, and the decimals the
## range asks for.
##
## This is what keeps a knob from making its own cell breathe while it is being turned.
##
## The rack writes its numbers without units and the graph writes them with, so the shape
## has to be asked for the way the caller draws it.
static func widest(descriptor: Dictionary, with_unit: bool = true) -> String:
	if descriptor.has("enum"):
		var longest := ""
		for option: Variant in descriptor.get("enum", []):
			if str(option).length() > longest.length():
				longest = str(option)
		return longest

	var low := float(descriptor.get("min", 0.0))
	var high := float(descriptor.get("max", 1.0))
	# Both ends, because the unit can change between them: a range that runs from
	# milliseconds to seconds writes its two halves differently and the cell has to hold
	# whichever is longer.
	var worst := ""
	for edge: float in [low, high, (low + high) * 0.5]:
		var shown := _shown(descriptor, edge)
		var digits := maxi(1, str(int(absf(float(shown["value"])))).length())
		var text := "8".repeat(digits)
		if int(shown["decimals"]) > 0:
			text += "." + "8".repeat(int(shown["decimals"]))
		if low < 0.0:
			text = "-" + text
		if with_unit and str(shown["unit"]) != "":
			text += " " + str(shown["unit"])
		if text.length() > worst.length():
			worst = text
	return worst


## A typed string back into the value the patch stores.
##
## The other half of the pair, and it was broken before this step in a way the old
## formatting hid. A field showing an attack of "10.0 ms" seeded its editor with that
## string; pressing return without changing a character submitted the number 10, which was
## clamped into the parameter's own range and stored as **ten seconds**. The display
## converts and the parse did not, so the one gesture that should be a no-op was the one
## that moved the value furthest.
##
## The unit is read off the text. If the typist left it there — which they will, because
## the field put it there — it says which scale the number is in. If they deleted it, the
## unit that was on screen is what they were looking at and is what they meant.
##
## What this does not do, and never could, is restore precision the display rounded away.
## A cutoff of 12345 hertz is written "12.35 kHz" and typing that back stores 12350 — the
## reading is true to the resolution the parameter earns and no truer. The property that
## matters, and the one `design_test.gd` holds, is that a reading does not *drift*: shown,
## parsed and shown again is the same string.
static func parse(descriptor: Dictionary, typed: String, showing: String = "") -> float:
	var number := _numeric_prefix(typed)
	if not number.is_valid_float():
		return 0.0
	var value := number.to_float()
	var native := str(descriptor.get("unit", ""))
	var unit := _unit_in(typed)
	if unit != "":
		return _native(value, native, unit)

	# No unit typed, so it has to be inferred, and the two conversions want opposite
	# answers. A field showing "10 ms" that is handed "20" means twenty milliseconds. A
	# field showing "1 kHz" that is handed "440" means four hundred and forty hertz and
	# certainly not four hundred and forty kilohertz.
	#
	# What separates them is the parameter's own range, which is real information and not
	# a guess: read it in the unit that was on screen, and if that lands outside the range
	# while the native unit lands inside, the typist meant the native one. Only genuinely
	# ambiguous numbers — ones both readings accept — fall back to the unit on screen,
	# which is what they were looking at.
	var shown_unit := _unit_in(showing)
	var as_shown := _native(value, native, shown_unit)
	var as_native := _native(value, native, native)
	var low := float(descriptor.get("min", 0.0))
	var high := float(descriptor.get("max", 1.0))
	var shown_fits := as_shown >= low and as_shown <= high
	var native_fits := as_native >= low and as_native <= high
	return as_native if native_fits and not shown_fits else as_shown


## A number written in `unit` as the value the patch stores.
static func _native(value: float, native: String, unit: String) -> float:
	if native == "s" and unit == "ms":
		return value * 0.001
	if native == "Hz" and unit == "kHz":
		return value * 1000.0
	return value


## The leading number of a typed string, as a string. Everything up to the first character
## that cannot be part of one.
static func _numeric_prefix(text: String) -> String:
	var kept := ""
	for character in text.strip_edges():
		if character in "0123456789.-+eE":
			kept += character
		else:
			break
	return kept


## What is written after the number, if anything.
static func _unit_in(text: String) -> String:
	return text.strip_edges().substr(_numeric_prefix(text).length()).strip_edges()


## The unit a value is spoken in, its magnitude in that unit, and how many decimals that
## unit deserves.
##
## A patch stores seconds and hertz and a reader should not have to hold the native
## representation in their head: milliseconds under a second, kilohertz over a thousand,
## because that is how the number would be said and written down anywhere else. The
## decimals are worked out **after** the conversion, on the converted range, since a range
## multiplied by a thousand needs three fewer of them.
static func _shown(descriptor: Dictionary, value: float) -> Dictionary:
	var unit := str(descriptor.get("unit", ""))
	var low := float(descriptor.get("min", 0.0))
	var high := float(descriptor.get("max", 1.0))
	var factor := 1.0
	if unit == "s" and absf(value) < 1.0:
		unit = "ms"
		factor = 1000.0
	elif unit == "Hz" and absf(value) >= 1000.0:
		unit = "kHz"
		factor = 0.001
	var span: float = absf(high - low) * factor
	return {"unit": unit, "value": value * factor,
		"decimals": _decimals(span, value * factor)}


## How many decimals this parameter earns, from its range and from the value itself.
##
## Two lower bounds and the finer one wins. The range says how small a difference is worth
## showing at all; the significant-figure floor says a number may not be rounded into a
## different number. A gain of 0 to 4 wants thousandths and a cutoff of 20 to 20000 hertz
## wants none, which is one rule giving two answers because it was asked about two
## parameters instead of about two numbers.
static func _decimals(span: float, value: float) -> int:
	var by_range := 0
	if span > 0.0:
		by_range = int(ceil(-log(span / STEPS) / log(10.0)))
	var by_figures := 0
	if not is_zero_approx(value):
		by_figures = int(ceil(FIGURES - 1.0 - floor(log(absf(value)) / log(10.0))))
	return clampi(maxi(maxi(by_range, by_figures), 0), 0, MAX_DECIMALS)


## The number itself, with trailing zeros taken off.
##
## A trailing zero is a claim that the digit was measured, and on a knob at 0.7 it was
## not. What is kept is every digit that says something: 0.700 becomes 0.7 and 0.550
## becomes 0.55, two different lengths because they carry two different amounts.
##
## The one exception is a value that is not zero and would round to it. Stripping there
## turns a small number into a wrong one, so the zeros stay and the reader sees that the
## value is under the resolution rather than absent.
static func _write(value: float, decimals: int) -> String:
	var text := String.num(value, decimals)
	if decimals > 0 and text.contains("."):
		var trimmed := text.rstrip("0").rstrip(".")
		if trimmed in ["", "-", "0", "-0"] and not is_zero_approx(value):
			return text
		text = trimmed if trimmed != "" else "0"
	# String.num can hand back a negative zero, which is a true statement about a float
	# and a strange thing to write on a panel.
	return "0" if text == "-0" else text
