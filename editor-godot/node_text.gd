class_name NodeText
extends RefCounted

## The typography inside a graph node, as roles rather than as overrides.
##
## Six kinds of text live on a node and they were being styled where they were built,
## which is how two of them ended up identical: a parameter's name and a port's name were
## both medium weight, body size, normal ink. On the Amplifier that produces the word
## "gain" twice in the same node at the same rank, once beside a socket and once under a
## knob, with nothing in the type to say they are different kinds of thing.
##
## The ranking this file exists to make true, reading down:
##
##   node name      identity        bright, semibold, larger
##   value          what it is at   bright, tabular figures, the loudest thing inside
##   unit           what it is in   the value's family, one size and one shade down
##   parameter name what it is      secondary ink, medium, subordinate to its value
##   port name      what connects   secondary ink a shade quieter, regular weight
##
## A reader scanning a patch wants the values; the names are how you check you are reading
## the right one. That is the order, and before this every one of them was fighting for
## the same rank.
##
## Applied to `NodeIdentity.PROVING_GROUND` only while the pass is being reviewed.

enum Role {
	NODE_TITLE,      ## the name in the header — step 3 set this and it is unchanged
	PARAM_LABEL,     ## the word under a control
	PARAM_VALUE,     ## the number
	PARAM_UNIT,      ## Hz, ms, octaves/s
	PORT_LABEL,      ## the word beside a socket
	CONTROL_OPTION,  ## what a dropdown is currently set to
}


## Dresses one label in its role. Everything a role decides — face, size, colour — is
## decided here, so a rank can be changed in one place rather than in six.
static func dress(label: Control, role: int) -> void:
	match role:
		Role.NODE_TITLE:
			_apply(label, Design.font(Design.WEIGHT_SEMIBOLD),
				Design.type(Design.SIZE_NODE_TITLE), Design.INK_BRIGHT)
		Role.PARAM_VALUE:
			# Tabular figures, from Design.numeric_font, so a value that changes under
			# the pointer does not shove its own unit sideways.
			_apply(label, Design.numeric_font(), Design.type(Design.SIZE_NUMERIC),
				Design.INK_BRIGHT)
		Role.PARAM_UNIT:
			_apply(label, Design.unit_font(), Design.type(Design.SIZE_UNIT),
				Design.INK_SECOND)
		Role.PARAM_LABEL:
			# A shade under its value, in ink and not in size. It was body size in normal
			# ink — the same rank as the number it names, so a node of four parameters was
			# eight pieces of text with no order to read them in.
			#
			# Body size on purpose. Dropping it to the secondary size put it under the
			# label legibility floor at 100% zoom, and the compensation system took it
			# over: at a zoom where nothing should be compensated, every parameter name
			# and every value went missing from the node. Rank here is carried by weight
			# and ink, which the floor has no opinion about.
			_apply(label, Design.font(Design.WEIGHT_MEDIUM),
				Design.type(Design.SIZE_BODY), Design.INK_SECOND)
		Role.PORT_LABEL:
			# The quietest text on the node, and the only one in regular weight: a port
			# name is a fact about the perimeter, not an operating control. Weight and a
			# shade of ink are what separate it from a parameter name — see the
			# Amplifier, where both words are "gain".
			_apply(label, Design.font(Design.WEIGHT_REGULAR),
				Design.type(Design.SIZE_BODY),
				Design.INK_SECOND.lerp(Design.SURFACES[Design.Surface.NODE], 0.2))
		Role.CONTROL_OPTION:
			# What a dropdown is set to is a value, and reads like one.
			_apply(label, Design.font(Design.WEIGHT_MEDIUM),
				Design.type(Design.SIZE_CONTROL), Design.INK_BRIGHT)


static func _apply(label: Control, face: Font, size: int, ink: Color) -> void:
	if label == null:
		return
	label.add_theme_font_override("font", face)
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", ink)
