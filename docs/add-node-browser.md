# The Add Node Browser

The long menu is being replaced by a browser: categories on the left, results in the
middle, preview and details on the right. It is being built in twelve steps, each one
rendered in the real editor and reviewed before the next is started, for the same reason
the cable renderer was built in ten — a review with six changes in it cannot say which
change it is agreeing with. See `docs/cable-design.md` for the same method applied to a
subsystem that is finished.

This file records what each step settled, and why, as the steps land.

## The shape

```
┌──────────────────────────────────────────────────────┐
│ Categories  │  Results                │  Preview     │
│   ~220      │   ~320                  │   ~360       │
└──────────────────────────────────────────────────────┘
```

`editor-godot/node_browser.gd`, its own file rather than more of `main.gd` — the editor's
other surfaces (the rack, the schematic, the face, the outline) each have one, and a panel
that will grow a data model, a keyboard model and three panes is a surface, not a popup.

## Step 1 — the shell

Three columns, the hairlines between them, and a close button. No categories, no search,
no preview: those are steps 2, 3 and 5, and each one arrives on its own.

**The old search palette stays.** `Add node` opens the browser; `Ctrl+Space` still opens
the palette that can actually add a node. Retiring a working path in favour of a scaffold
would make the editor worse in exchange for a screenshot, and the plan retires the old
menu at step 12, when the browser is faster at every task it took.

Three things the shell got wrong first, all of them invisible in the code and obvious in a
render:

**It asked the wrong window how big it was.** `DisplayServer.window_get_size()` is the OS
window — borders, DPI and all — while an embedded popup is positioned against its parent
viewport, and on this machine the two differ by 260 pixels. The browser opened with its
corner off the top-left of the screen while the toolbar button sat three hundred pixels
away. The frame to ask is `get_tree().root.get_visible_rect()`, the same one a Control's
`global_rect` is in, which is also what the anchor is now passed in.

**A PopupPanel is sized by its contents, not by its window.** Handing it 964 produced 1012:
it adds its own frame to whatever it is given. That is only a rounding error at full size,
but the size being handed over was a *cap* — a fraction of the window, so the browser
floats over the editor instead of covering it — and a cap that overshoots is not a cap. The
frame is now measured from the theme stylebox and subtracted, so different padding cannot
quietly bring the overflow back.

**A window clips its own shadow.** `shadow_size` on the panel stylebox drew a shadow
outside the popup's rectangle, which is to say nowhere. The panel is drawn inset instead —
negative expand margins pull the paint in on every side, the content margins put the gutter
back so the columns do not move, and the shadow falls into the gap.

The close glyph is drawn, not typed. `✕` is not in the editor's font, and
`editor_test.gd` refuses text the font cannot draw — the check that exists because of the
tofu incident, doing its job on the first panel written after it. `Icons.Kind.CROSS`.

### The polish pass

Reviewed in the editor, four corrections, no change to the width or the column
proportions:

- **It hung too low.** The drop is measured to the panel's *visible* edge now, not the
  window's — the shadow gutter is inside the popup's rectangle, so a drop measured from
  the window lands the panel that much further down again. Fourteen scaled pixels below
  the button, and asked for a second time after `popup()`, which nudges a window by a few
  pixels of its own accord. That is invisible on a dialog placed in the middle of a
  window and is the whole measurement on one hung off a toolbar button.
- **The header was too airy.** No separation under the title row: the row is already
  taller than its text, because the close button sets its height, and a gap on top of
  that pushed the column headings far enough down that the browser read as a large blank
  dialog waiting for content. Seventeen pixels between title and headings became nine.
- **The dividers were the loudest thing in the body.** Between three empty columns, at
  full border strength, they read as rails rather than as structure. Softened 45% toward
  the surface they sit on; when the columns carry lists they should recede under them.
- **The old palette stays on Ctrl+Space.** Confirmed rather than changed.

## Step 2 — the category rail

Fourteen rows in three families, `All` lit to begin with, up and down to walk it. No
search, no results, no preview: those are steps 3 and 5.

**Three families, two rules, no headings.** The primitive node classes, then Examples,
then the three banks. A rule and six pixels of air on each side say "different kind of
thing" quietly; a section heading under a section heading, over three rows, is a
hierarchy announcing itself rather than being read.

**No chevrons, no disclosure, no hover-to-open.** Pressing a row changes the middle
column. That is the whole interaction, and it is the reason the old menu is going.

**The marks are drawn, and they are a set.** Twelve new glyphs in `icons.gd`, on the
existing grid at the existing single stroke weight — a category mark earns its place by
being recognised as a shape before it is read as a word, which nine borrowed icon styles
cannot do. The oscillator and modulation marks are deliberately the same gesture with and
without corners. All three banks wear the *same* mark: they are one family of thing and
the word beside it says which. `editor_test` now renders every icon in the enum at rail
size and fails if any two of them are the same shape.

**The rail must not scroll**, and it very nearly did. Fourteen rows at 36px plus two
rules want 530px; the shell had 509. Three things gave way, in this order:

- Row separation went to zero. Rows carry their own padding, so they still do not touch.
- Row height and the rail's contents stopped scaling with the UI scale — the same choice
  the panel width made, for the same reason. A rail that scales its rows but not its
  budget shows fourteen categories at one setting and eleven and a scrollbar at another.
- The browser's height cap went from 0.84 of the window to 0.88, and its height became a
  real figure above that cap so the cap is what decides at every scale. The panel grew
  36px: the row height is the thing the eye is being asked about, so the panel is what
  gave way.

That leaves 530 in 545 at the tightest supported combination — a 1440x900 window at XL,
where the panel's furniture takes 193px. `NodeBrowser.RAIL_BUDGET` carries that figure
and the suite checks the rail's contents against it, because a popup that is never drawn
has no size and headless there is nothing for a scrollbar to be wrong about. The rail was
watched not scrolling at all three UI scales with the editor on screen.

**Selected is a tint, not the accent.** A rail of fourteen rows with one painted mint is a
button somebody put in a list. The fill (16% accent over the surface) says where you are,
a 45%-muted accent edge holds it together, and the ink and the mark carry the colour at
5.9:1 against their own fill.

## Step 3 — search and results

The middle column: a field, what matches, grouped under landmarks. No preview.

**A category is a scope, not a filter.** Searching inside Examples searches examples;
inside Oscillators, oscillators. `All` is the exception in both directions — with nothing
typed it browses the node vocabulary alone, because three hundred devices under an empty
search buries the fifty things you wire together; with something typed it searches
everything there is.

**The ranking is the core's**, for nodes: `search_nodes` is what the command line uses,
so "make quieter" finds the same node in both places. Devices match on every word of the
query appearing in the name. No ranking science beyond that yet.

**Rows carry a name and nothing else.** The old palette put an Add button on every row —
dozens of identical calls to action down a list you are trying to read. The row is the
target; what happens when you take it lives in one place, later.

**Landmarks earn their line.** Group headings appear only when there is more than one
group: a single heading over a single list is a label for a column that already has one.
Under All the groups are the rail's own rows, in the rail's own order, so the results
read down the rail rather than down whatever order the registry is in.

### What the taxonomy actually maps onto

This is the step that tests the rail against the data, and it mostly fits.

```
Oscillators   5     Filters      3     Envelopes    2
Modulation    8     Utilities    7     Mixing       5
Effects       7     MIDI & IO    4     Sequencers   4
                                       ----
                                       45 of 48 nodes
Examples     48     Node bank   48     FM bank    128     DX7 bank  68
```

Two findings:

**Three nodes had no row, so the row was renamed.** Sampler, Speech and Plugin
Instrument are sources that are not oscillators, and `Oscillators` had no word for them.
They spent one review as recorded exceptions before the obvious fix: the rail's first row
is `Sources`, and every node in the core now has a category. An exception list whose
invariant is "exactly three things stay uncategorised" is a taxonomy asking to be fixed,
and the next generator to arrive would have joined them. The suite checks that nothing is
homeless rather than that the expected few are.

**Examples absorbed the synth and drum shelves.** The old palette had chips for synth,
drums, dx7, clones and nodes; the rail has Examples and three banks. So Examples holds
the worked patches, the game sounds, the six Synth voices and the seventeen drum-machine
kits, and the group headings — PATCHES, GAME, 808, 909, 606, SDS, GATED, SYNTH — are what
separate them. That is exactly the landmark grammar the step was for, and it works, but
48 rows under one row of the rail is the most crowded thing in the browser.

Node families are mapped by the core's own category with a short override list, not by a
list of node names: a node added to dsp-core lands somewhere sensible on its own, where a
hand-written list would silently drop it.

### The column is called Browse

`NODES` over a result labelled `PATCHES` was the interface contradicting itself in one
screen: `All` searches everything the moment there is a query, which is the behaviour
worth keeping, so the language moved instead. The heading is `BROWSE` and the placeholder
is `Search…` — neither promises nodes, and both are honest before a query exists in a way
`RESULTS` would not be.

### The keyboard

Typing goes straight into the field, which takes focus on opening. Up and down move the
lit result, Enter takes it, Ctrl+K comes back to the field, and the selection is scrolled
into view — keyboard navigation that moves the selection somewhere you cannot see is
worse than none.

The arrow keys are taken from the field's own `gui_input`, before it can spend them on
its caret: a focused `LineEdit` eats them, so unhandled input never saw them and down did
nothing at all. The rail keeps its keys for when the focus is not in the field. Tab
between the two regions is step 8.

Enter adds what is lit, by the same route the search palette takes. Step 7 is where a
Load example and an Open in sandbox become different things from an Add node; until then
one route serves all three, and the browser stays open, because patches are built several
nodes at a time.

## Step 4 — one item vocabulary

Deliberately invisible. Four states rendered before and after: **zero differing pixels**
in all four, and the same searches return the same rows in the same order.

The browser used to be handed dictionaries that still smelled of where they were found —
a node carrying the core's category, a device carrying the prefix on its label — and it
worked out what to do with each as it drew them. That works for two sources and stops
working at four. The place where the old shapes leak back in is the preview pane, which
is the next thing being built, so the leak was closed first.

`BrowserItem` (`editor-godot/browser_item.gd`) holds the rule this step exists for:

```
kind      what the object is        NODE   PATCH   BANK_ITEM
category  where the browser puts it Sources, Examples, DX7 bank, …
```

They were one field. A bank voice and a worked patch are both patches to open, and belong
in different rows of the rail; a node and a bank voice both drop into the graph as a node,
and are not the same kind of object at all.

Actions are carried as descriptors, not buttons: a node's primary is `ADD_NODE`, a
patch's is `LOAD_PATCH` with `OPEN_IN_SANDBOX` behind it. Nothing reads them yet — Enter
still takes the palette's one route for everything — and step 7 is where the browser
starts honouring them instead of asking what kind of thing it is holding.

`BrowserCatalogue` is the provider layer: two providers today, and a third would be a
provider rather than a new shape for the browser to learn. What comes out is one list, and
after it there is one pipeline — scope by category, match, group, draw.

Node ranking is still the core's. Normalising did not mean throwing the specialised
ranking away; `BrowserItem.matches` asks the core's result set about a node and matches a
device's own name itself, and one vocabulary comes back from both.

The fields are the ones something reads: `id`, `display_name`, `kind`, `category`,
`group`, `description`, `tags`, `search_terms`, `source_ref`, `primary_action`,
`secondary_actions`. No author, no rating, no complexity score. They arrive when a pane
needs them.

Pinned: the catalogue is `BrowserItem`s and nothing else, no two items share an id, every
item has one of the three kinds and all three are in use, every item's category is a row
of the rail, every item says what taking it would do, and every row drawn is an item from
the catalogue — a row the catalogue cannot account for is the old shapes growing a second
path back into the column.

### The type grammar

Small uppercase grey labels for structural regions; normal mixed case for anything
interactive. `CATEGORIES / NODES / PREVIEW & DETAILS` set it, and every step after this
one follows it — it is what stops a browser full of categories, results, group headings
and detail fields from becoming a wall of equally weighted text.

Pinned by the suite: the toolbar's own signal opens it, the three columns exist, all three
ways out work, and the patch underneath is left where it was. That last check first failed
against a zoom that was still settling from an earlier check two frames after being asked
to fit — the suite's own leftover, reported as the browser disturbing the patch.
