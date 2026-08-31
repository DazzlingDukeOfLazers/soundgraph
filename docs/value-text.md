# Writing a Value

`gain 0.700` is a debugger printing a float. `gain 0.7` is an instrument telling you its
setting. The number is the same; what changed is a claim about resolution.

`editor-godot/value_text.gd` is the one implementation, and both the graph and the rack
call it. There used to be two identical copies — `main._format_value` and
`Rack.format_value` — quietly drifting apart.

## What was wrong

The old rule keyed the number of decimals to **the value's own magnitude**: three under
one, two under ten, one under a thousand. So every value on a normalised control wore
three decimals whatever the control was, and a filter's cutoff and an envelope's sustain
were written to the same precision because they happened to be similar-sized numbers.

A value's size is the wrong thing to ask. Two decimals of a cutoff in hertz and three of a
resonance are not the same amount of information.

## What is asked instead

The parameter descriptor: its range, its unit, whether it is an enumeration.

**How many decimals.** Two lower bounds, and the finer one wins.

- *From the range.* A parameter should be able to show about five hundred distinguishable
  readings across its travel, which is the resolution a hand dragging a knob across a
  couple of hundred pixels actually has. A gain of 0 to 4 gets thousandths; a cutoff of 20
  to 20000 hertz gets whole hertz. One rule, two answers, because it was asked about two
  parameters rather than about two numbers.
- *From the value.* Never fewer than three significant figures. The range rule alone is
  wrong at the bottom of a wide exponential parameter — an attack of half a millisecond on
  a range of ten seconds would round to nothing and the field would read `0 ms` for a value
  that is not zero.

**Then the trailing zeros come off.** A trailing zero is a claim that the digit was
measured, and on a knob sitting at 0.7 it was not. `0.700` becomes `0.7` and `0.550`
becomes `0.55` — two different lengths, because they carry two different amounts.

The one exception: a value that is not zero and would round to it keeps its zeros, so the
reader sees a number under the display's resolution rather than an absence.

**The unit still follows the magnitude.** Milliseconds under a second, kilohertz over a
thousand, unchanged from before. The decimals are worked out *after* the conversion, on
the converted range, since a range multiplied by a thousand needs three fewer of them.

## The readings

Everything the three proving-ground nodes show, before and after:

```
gain          0.700              0.7
cutoff        900.0 Hz           900 Hz
resonance     0.550              0.55
sweep         0.000 octaves/s    0 octaves/s
attack        10.0 ms            10 ms
decay         250.0 ms           250 ms
sustain       0.550              0.55
release       300.0 ms           300 ms
```

**No node changed size.** Measured, not assumed: the three nodes are 238×150, 508×248 and
400×101 before the change and the same three figures after. Steps 4 and 8 own geometry and
this step does not touch it.

## Width, and why the cell is not measured on the ends

A cell is sized for the longest reading its parameter can produce. It used to be sized on
the *ends* of the range — the longer of `min` and `max` formatted — which was fine while
every value wore a fixed number of decimals and is wrong now. Stripped of trailing zeros
the ends are often the shortest strings a parameter has: a gain of 0 to 4 writes them `0`
and `4` while everything between writes `0.75`, and a cell measured on them would be too
narrow for nearly every value it then holds.

`ValueText.widest` builds the worst case instead — sign, integer digits, decimals, and the
unit if the caller draws one. So a knob does not resize its own cell while it is being
turned. The rack draws its numbers without units and the graph with, so the shape is asked
for the way the caller draws it.

## The parse, which was broken

A field showing an attack of `10.0 ms` seeded its editor with that string. Pressing return
without changing a character submitted the number 10, which was clamped into the
parameter's range and stored as **ten seconds**. The display converted units and the parse
did not, so the one gesture that should be a no-op was the one that moved the value
furthest. It was there before this step; the old formatting only made it harder to notice.

`ValueText.parse` undoes the conversion. If the typist left the unit on the string — which
they will, because the field put it there — it says which scale the number is in.

### When no unit is typed

The two conversions want opposite answers, and both are obvious to a person:

```
field shows "10 ms", typist enters 20     twenty milliseconds
field shows "1 kHz", typist enters 440    four hundred and forty hertz
```

What separates them is the parameter's own **range**, which is real information rather
than a guess: read the number in the unit that was on screen, and if that lands outside
the range while the native unit lands inside, the typist meant the native one. 440 as
kilohertz is 440000 and the cutoff stops at 20000, so it is hertz. 20 as milliseconds is
0.02 seconds and well inside the attack's range, so it stays milliseconds. A number both
readings accept — 5 over a kilohertz display — keeps the unit that was on screen, because
that is what the typist was looking at.

### What the parse cannot do

Restore precision the display rounded away. A cutoff of 12345 hertz is written
`12.35 kHz`, and typing that back stores 12350. The reading is true to the resolution the
parameter earns and no truer, and that was as true of `12.3 kHz` before.

So the property the suite holds is not equality, it is a **fixed point**: what the field
shows, parsed and shown again, is the same string. That catches the unit bug — ten
milliseconds reading back as ten seconds fails it by a factor of a thousand — without
pretending a rounded display carries every bit.

## What the build checks

`design_test.gd`, headless and with no screenshots in it: a table of twenty readings
including the boundaries a formatter goes wrong at (a value that is not zero and nearly
is, an exact integer, a negative, a unit that changes under the value's feet, an
enumeration); the fixed-point round trip for each of them, with and without its unit; the
two ambiguous bare-number cases above; and that every reading fits the space reserved
for it.

Nothing here is stored, compared or sent anywhere. A patch keeps the float it always kept
in the units it always kept it in. The dsp-core is the authority on what a value *is*;
this is the authority on how it is spelt.
