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

### The type grammar

Small uppercase grey labels for structural regions; normal mixed case for anything
interactive. `CATEGORIES / NODES / PREVIEW & DETAILS` set it, and every step after this
one follows it — it is what stops a browser full of categories, results, group headings
and detail fields from becoming a wall of equally weighted text.

Pinned by the suite: the toolbar's own signal opens it, the three columns exist, all three
ways out work, and the patch underneath is left where it was. That last check first failed
against a zoom that was still settling from an earlier check two frames after being asked
to fit — the suite's own leftover, reported as the browser disturbing the patch.
