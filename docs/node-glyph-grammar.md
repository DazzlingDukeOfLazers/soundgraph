# The Node Glyph Grammar

Step 9 drew three marks and they worked. This is the difference between three marks that
worked and a system that can produce the fiftieth one.

The rules live in `editor-godot/glyph_grammar.gd`, in code, because a grammar in prose is
a grammar somebody has to remember. This file is the reasoning behind it, the proof that
it makes families, and the two places it strains.

Nothing was migrated. Gain, StateVariableFilter and ADSR are still the only node types
wearing a mark; the seven glyphs added here are attached to nothing and exist to be
looked at.

## The contract

Nine rules, all of them in the file. One cell, one coordinate system, one field, one
weight; an optical cut rather than a smaller drawing; identity ink and never a signal
colour; the mark yields to the name; behaviour and never hardware.

The ninth arrived during this step and is the only one the three specimens did not
already teach:

> **Siblings differ in silhouette, not in a detail.** Mirroring is a silhouette.
> Inverting is a silhouette. Removing one stroke is not.

At twenty-four pixels the outline is all there is. A family that can only be told apart
by looking closely is a family that costs the reader more than it saves them, and the
proof sheet below has one member that fails this and is kept anyway, marked.

### The three specimens are unchanged

Not "look unchanged" — the lowpass was rewritten to be constructed from the shared
grammar rather than from its own hand-placed coordinates, and the check is that the
rewrite is invisible:

```
gain_triangle   96, 24, 16, 10   identical
response_low    96, 24, 16, 10   identical
envelope        96, 24, 16, 10   identical
```

Twelve renders, pixel for pixel, against the same four sizes captured before the change.
The grammar's knee (0.55 along, 0.44 toward the stop level) is the lowpass's own knee
read off its hand-placed shoulder and rounded; the rounding moves the point by three
thousandths of a reach unit, which is under a tenth of a pixel at master and does not
survive into the rendered image at all.

## The six families

Semantic construction rules, not lists of pictures. Two are drawn; four are grammar,
deliberately, because the point of this step was to show that families can be built and
not to spend it drawing forty pictures nobody has asked for.

```
Generators   waveform geometry — one cycle in the field
             sine smooth, square cornered, saw ramped, noise unrepeating
Filters      one response axis, two levels, transitions between them          DRAWN
             lowpass falls, highpass rises, bandpass is a hill, notch a valley
Dynamics     amplitude transformed
             gain the amplifier triangle, compressor a range converging,
             limiter a signal meeting a ceiling
Time         repetition along the horizontal
             delay repeats, reverb repeats and decays, chorus displaces a copy
Routing      terminals and the cords between them                             DRAWN
             split one to many, merge many to one, switch a selectable branch
Control      the shape of a value over time
             envelope the ADSR contour, LFO a slow wave, clock a pulse train,
             sequencer discrete steps
```

## The proof sheet

`editor-godot/glyph_sheet.gd` renders it, straight out of `Icons.get_icon`, on the header
surface in the header ink — a glyph judged on white is judged somewhere it will never be
seen. Every mark is shown at the same size on the page whatever it was drawn at, because
four sizes can only be compared if the comparison is about how they are drawn and not
about how big they are.

```
godot --headless --path editor-godot --script glyph_sheet.gd   # GLYPH_SHEET_OUT names the folder
```

Rows, in order:

```
1  Gain            approved specimen
2  Lowpass         approved specimen, and the filter family's parent
3  Envelope        approved specimen
4  Highpass        the lowpass mirrored
5  Bandpass        a peak
6  Notch           a valley
7  Split           one terminal in, two out
8  Merge           two in, one out
9  Switch          one in, two available, one made
```

Columns: master 96, the header cell at XL (24), and that cell at 66% and 40% zoom (16 and
10). Nothing draws a 10-pixel glyph today — the title falls to the compensation overlay at
66% and the mark stands down with it — and it is on the sheet anyway, because "it would be
unreadable there" is the claim rule 7 rests on and a claim like that should be looked at.
It is unreadable there. All three routing marks collapse into one blob at 10.

### The filter family passes

The lowpass and the highpass are the same drawing read in two directions and they read
instantly as a pair. The bandpass and the notch are the same two levels with a plateau
between them, one up and one down, and they read as each other's inverse. Four marks, one
construction, no new idea to memorise after the first.

The bandpass took one correction. Its first plateau was ±0.35 reach units wide, which
drew a trapezoid, and a trapezoid is what the envelope also is at small sizes. Narrowing
it to ±0.18 makes it a resonant peak — which is both what a bandpass actually looks like
on paper and what separates it from the envelope's asymmetric contour. The notch narrowed
with it, to keep the pair mirror-symmetric.

**They are still the closest pair in the set.** The envelope and the bandpass are both an
arch, and what separates them is that the envelope's peak is left of centre and holds a
plateau on the way down. At 24 that is a real difference; at 16 it is a fine one. Two
families whose grammars produce similar outlines is a collision rule 9 does not currently
prevent, and the honest reading is that it is survivable here and would not be if a third
family also drew arches.

### The routing family passes as a family and fails rule 9 inside it

Split and merge are a clean mirror pair — one trunk and a fan, fanning the other way.
Nothing else in the icon set is discs joined by strokes, so a routing mark is recognised
as routing before it is read as which routing.

The switch is the failure. It is the split with one cord removed, which is a detail and
not a silhouette, and at 24 pixels it is legible only if you already suspect it. Two
other constructions were drawn and are worse:

```
A  full cord to the made contact, nothing to the other        kept
B  as A, plus a stub on the unmade branch                     worse — the stub closes
                                                              most of the gap it opens,
                                                              and at 24 the switch became
                                                              the split exactly
C  a blade leaning toward the contact without arriving         reads at 96, loses the aim
                                                              at 24
```

A is kept because it is the best of three, not because it is right. What the switch
actually needs is a different construction — the routing family's vocabulary of trunk,
junction and fan has no way to say "selectable" that changes an outline. It is possible
that a switch is not a routing mark at all and belongs with control, where a thing that
changes over time already lives. That is a question for whoever draws it for real.

## Recorded, not built

**Activity state.** The Noun Project search behind step 9 turned up an envelope family
(icons 385861–385867) that draws the whole ADSR contour every time and solids only the
segment being named, dashing the rest. Identity kept, state added on top of it, one
drawing doing both jobs — it is the right idea, and it is exactly what a running envelope
wants. It is not built. A header mark that changes while the patch plays is interaction
design, and building it here would quietly turn step 10 into step 11.

**A third arch.** If a future family wants an arch — a resonance, a swell, a crossfade —
it collides with both the bandpass and the envelope, and the fix is a grammar rule about
distinguishing outlines rather than a nudge to whichever mark is drawn last.

## What the build checks

`design_test.gd`, added this step: every `Icons.Kind` marks pixels at 20 and 24, and stays
off the edge of its 96-pixel cell. The first is the tofu incident in a new hat — an icon
that silently draws nothing is not an error, it is a rectangle of nothing, and nothing in
the build said so. The second is rule 3, which is what keeps a mark from touching the
title beside it on somebody else's interface scale.
