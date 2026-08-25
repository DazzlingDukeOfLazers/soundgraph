# editor-godot

The primary editor, and deliberately not the authority on anything.

Every question this UI needs answered — what node types exist, what ports they have,
whether a connection is legal, what is wrong with a graph, what a wire is carrying — is
asked of the `SoundGraphEngine` extension, which wraps the same `dsp-core` as the browser
and the command line tools. There is no DSP in GDScript and no second copy of the node
vocabulary, because a second copy is a second set of answers that will eventually
disagree with the first.

Concretely, that means adding a node type to `dsp-core` makes it appear in this editor —
with its ports, units, ranges, enum labels, tooltips and search terms — without a line of
GDScript changing.

## Running it in a browser

The same editor, exported to WebAssembly, so the demo's "open a URL" and "the real editor"
can be the same thing. The extension is built again for `platform=web` — the fifth
compiler the core has been through — and loaded as an Emscripten side module.

```bash
emcmake cmake -S runtime-godot -B runtime-godot/build-web -DCMAKE_BUILD_TYPE=Release
cmake --build runtime-godot/build-web
node tools/export-web.mjs --out editor-web/editor
python tools/serve.py                    # then open /editor-web/editor/
```

`--out editor-web/editor` puts the export **below** the lite page rather than beside it, so
the local layout is the deployed one: `/soundgraph` and `/soundgraph/editor`. That is not
cosmetic. This export ships a service worker, a service worker's scope is the directory it
is served from, and this one is cache-first with no revalidation (see *It downloads once*).
Exported alongside or above the lite page it would take control of it, and the page a QR
code points at would become one that cannot be reliably updated.

If godot-cpp is not checked out yet — it is gitignored, being third-party source:

```bash
git clone --depth 1 https://github.com/godotengine/godot-cpp.git runtime-godot/third_party/godot-cpp
cmake -S runtime-godot -B runtime-godot/build-web -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DGODOTCPP_API_VERSION=4.7 \
  -DCMAKE_TOOLCHAIN_FILE=$EMSDK/upstream/emscripten/cmake/Modules/Platform/Emscripten.cmake
```

godot-cpp has **no 4.7 branch** — its newest is 4.5, and 4.7 support lives on `master`,
which ships `extension_api-4-7.json`. That file describes 4.7.0 while the engine here is
4.7.1; a patch-level difference is fine, because GDExtension compatibility is promised
within a minor version. `-DGODOTCPP_API_VERSION=4.7` selects it. If a future engine ever
has no matching file at all, dump one from the engine itself with
`godot --headless --dump-extension-api --dump-gdextension-interface` and point
`GODOTCPP_CUSTOM_API_FILE` at it.

## A patch arriving from the lite page

`/soundgraph` can hand a patch to this editor. Same origin, so the channel is
`localStorage['soundgraph.handoff.v1']`, and the patch itself is the whole protocol — both
surfaces read the same file and ask the same core about it, so there is nothing else to
agree on. `_load_handed_off_patch()` reads and clears it in one step and, when it finds
one, opens it **instead of** the default example: somebody who pressed "open in the full
editor" asked for their patch, and First Synth landing on top of it would throw away what
they had just made. Clearing matters as much — a handoff that survived its own load would
reopen on every later visit.

**The Emscripten version must match the one Godot's template was built with.** For Godot
4.7.1 that is **4.0.20**. A side module and the engine that loads it share an ABI, and a
mismatch shows up as `function signature mismatch` on a blank canvas, which says nothing
about versions at all. To find the right one for a future Godot release, look inside
`web_dlink_nothreads_release.zip` in the export templates and grep `godot.js` for a
version string.

```bash
C:\Users\danie\emsdk\emsdk.bat install 4.0.20
C:\Users\danie\emsdk\emsdk.bat activate 4.0.20
```

The extension is built against godot-cpp's **`template_release`**, so only the release
entries appear in `soundgraph.gdextension`. A debug export will fail to find a library,
which says what is wrong; pointing it at the release build would be a quiet mismatch.

godot-cpp ships a workaround that teaches CMake to emit Emscripten shared libraries, but
it is installed through `CMAKE_PROJECT_godot-cpp_INCLUDE` and only applies inside
godot-cpp's own project scope. Our library lives in the parent project, never saw it, and
linked as an executable — failing with `undefined symbol: main`, which points nowhere near
the cause. `runtime-godot/CMakeLists.txt` applies the same settings where our target can
see them.

Two settings in `export_presets.cfg` are load-bearing and easy to get wrong:

- **`variant/extensions_support=true`** selects a `dlink` template. Without it the engine
  has no dynamic loader and the extension simply never loads.
- **`variant/thread_support=false`** must match the extension, which is built with
  `GODOTCPP_THREADS=OFF`. A mismatch fails in confusing ways. Single-threaded also avoids
  `SharedArrayBuffer`, which would otherwise require cross-origin isolation headers — and
  a zero-install URL that only works behind special headers is not zero-install.

In a browser there is no filesystem to show a dialog for, so **Open** goes through a real
`<input type="file">` and **Save as** through a download.

### The web extension is a separate build, and nothing reminds you

`cmake --build runtime-godot/build` produces the **desktop** DLL.
`cmake --build runtime-godot/build-web` produces the **web** wasm. Changing anything in
`dsp-core` and rebuilding only the first leaves the browser running an extension from
before the change — and it does not fail at build time or export time. It fails much later,
as a patch that will not load because the engine "does not know about" a node type that
plainly exists.

That is exactly how the sandbox came to be silent in the browser while working on the
desktop: five node types were missing from a wasm nobody had rebuilt. Export after both:

```bash
cmake --build runtime-godot/build          # desktop
cmake --build runtime-godot/build-web      # web  <- the one that gets forgotten
godot --headless --path editor-godot --import
godot --headless --path editor-godot --export-release Web ../build-godot-web/index.html
```

### While developing, unregister the service worker

The caching below is cache-first with no revalidation, and Godot does not send the worker a
`skipWaiting`. A new export therefore does **not** appear on reload — and if a tab stays
open, the replacement worker waits behind it indefinitely. During a re-export cycle the
browser can serve a build from hours ago while every reload looks like it worked:

```js
navigator.serviceWorker.getRegistrations().then(r => r.forEach(w => w.unregister()));
caches.keys().then(k => k.forEach(c => caches.delete(c)));
```

Then reload. Worth knowing which build is actually running before debugging anything:
`performance.getEntriesByType('resource').filter(e => e.name.endsWith('index.pck'))` gives
its size, which can be compared against the file on disk.

### It downloads once

The export is ~46 MB, so it is a progressive web app: a service worker caches the whole
thing and later visits touch the network for nothing. Verified by loading it, killing the
web server, and reloading — the editor still came up, with `transferSize: 0` against
`decodedBodySize: 44077147` for `index.side.wasm`. It can also be installed to a home
screen, which is the point for a QR code at a stand.

Godot generates the worker and the manifest; the settings live under
`progressive_web_app/` in `export_presets.cfg`. The icons are rasterised from the one
`icon.svg` — regenerate them rather than editing the PNGs:

```bash
godot --headless --path editor-godot --script res://make_icons.gd
```

Three things about the caching are worth knowing before relying on it:

- **It is cached from the *second* visit, not the first.** The worker installs on the first
  load but does not control that page, so the four large files still come over the network.
  Godot can hand the worker control immediately, but only sends it that message when
  `ensure_cross_origin_isolation_headers` is on — and that adds COOP/COEP headers to every
  response, which is exactly the "any static host will do" property `nothreads` was chosen
  to keep. Not worth trading for one load.
- **Serve it gzipped anyway.** ~10 MB compressed versus ~46 MB raw, and that first load is
  the one an audience watches.
- **Updates land a visit late.** The worker is strictly cache-first with no revalidation. A
  new export changes the worker, which installs a fresh cache and drops the old one, but the
  new build appears on the visit after that. Deploy before the day, then load it twice.

Service workers need a secure context, so this works on `localhost` and over HTTPS, and not
over plain HTTP to a LAN address.

## Build and run

The extension binary and the example patches are build output, not repository content.
Build them first:

```bash
cmake -S runtime-godot -B runtime-godot/build -DCMAKE_BUILD_TYPE=Release
cmake --build runtime-godot/build
```

That writes `editor-godot/bin/` and `editor-godot/examples/`. Then open `editor-godot/`
in Godot 4.7.

The first configure clones and builds `godot-cpp`, which takes a while and produces around
two thousand binding files. Afterwards it is incremental.

## Using it

| | |
|---|---|
| Add a node | **Ctrl+Space**, or right-click the canvas, or the toolbar button — every result has its own **Add** button, and the dialog stays open so you can add several |
| Undo / redo | **Ctrl+Z** / **Ctrl+Shift+Z** (or Ctrl+Y), and the toolbar buttons, which name what they will undo |
| Tidy the graph | **Auto-place** lays the whole graph out; **Arrange selection** does only what you have selected |
| Move a cable | drag it; right-click puts it back |
| Play | **A W S E D F T G Y H U J K**, with **Z** / **X** to shift octave |
| Inspect a signal | select a node — the scope shows what its first output is carrying |
| Fix a problem | the panel names the nodes involved and highlights them in the graph |

## The grid

The canvas draws its own three-tier grid, and each tier **is** one of the layout's
pitches:

| line | spacing | means |
|---|---|---|
| faint | 40 | the snap step — where a dragged node lands |
| medium | 200 | a **row** — the vertical pitch auto-place uses |
| heavy | 400 | a **column** — the horizontal pitch auto-place uses |

GraphEdit's own grid draws minor lines at the snap distance and major lines at some
multiple of it, which leaves you counting minor lines to find the one you meant to align
to. Here there is nothing to count: the heavy line *is* the column and the medium line
*is* the row, so "line it up with a major line" and "put it where the layout would" are
the same instruction. GraphEdit's grid is switched off so only one grid is drawn.

Loading a patch snaps every node — and every cable waypoint — onto the 40 grid. A file
written by another editor, or by hand, otherwise lands on arbitrary pixels and every
alignment cue on the canvas is off by a few, which reads as the grid being broken rather
than the file.

## Layout

Everything snaps to a **40 pixel grid**, so hand-placed and auto-placed nodes share a
pitch instead of drifting a few pixels apart.

**Auto-place** (`layout.gd`) is the Sugiyama framework for layered graph drawing. Placing
nodes by depth alone — which is all the first version did — gets the columns right and
nothing else: it says nothing about which node sits above which, so cables cross for no
reason, and it stacks each column from the top, so a chain that should read as a straight
line zig-zags. The four phases:

1. **Cycle removal.** A feedback loop is temporarily reversed so the rest can assume a
   DAG. SoundGraph only permits cycles through a `Delay` anyway, so this draws a loop the
   way a person would: forward along the signal, back underneath.
2. **Layer assignment.** Longest path, then sources pulled right to sit beside whatever
   they drive — which is why an LFO lands next to its filter instead of stranded at the
   far left.
3. **Crossing reduction.** The median heuristic swept in both directions, then
   adjacent-swap transposition, keeping the ordering whose crossings were *actually
   measured* to be lowest rather than assumed.
4. **Coordinate assignment.** Each node is pulled toward the median of its neighbours,
   resolved against the no-overlap constraints by isotonic regression — which gives the
   closest legal placement rather than an approximation of it.

Edges spanning more than one column get **dummy nodes** in the layers they cross. Without
them a long cable is invisible to both the crossing count and the spacing, so it happily
cuts across whatever is in the way. Dummy chains are weighted heavily in phase 4, which is
what keeps a long cable straight instead of bowed.

**Cables are weighted by what they carry.** An audio cable pulls its ends into line far
harder than a control cable does, so the signal chain comes out as one straight spine with
the modulation sources arranged beneath it — the shape a person draws by hand. A weighted
median is still a compromise, though, and a spine node sitting above two modulators gets
tugged down by both; so after the sweeps, the strongest chains are put on a single row
outright and the rest of each column gives way around them.

**Rows land on the major grid lines** (multiples of 200), not on every grid line.
Vertical separation is a whole number of those steps, so a stack reads as a stack instead
of landing on whatever arithmetic the node heights happened to produce.

Column and row pitch come from real widget sizes, so a column of wide nodes pushes the
next one out instead of overlapping it.

**Auto-place is deterministic.** The result depends only on the graph — the same patch
lands the same way no matter where anything was beforehand, and no matter what happens to
be selected. That last part was a real trap: Auto-place used to switch to selection-only
mode whenever two or more nodes were selected, and a drag leaves what it dragged selected,
so pressing the button after moving things quietly did something different each time.

**Arrange selection** is now its own action. It arranges only the selected nodes, treats
everything else as a fixed anchor that still pulls on the result, and translates the
arrangement back to where the selection already sat — so tidying one corner does not move
it across the canvas or fight the part you arranged by hand. It refuses a selection of
fewer than two nodes rather than silently doing something else.

References: Sugiyama, Tagawa & Toda (1981); Gansner, Koutsofios, North & Vo, *A Technique
for Drawing Directed Graphs* (1993) for median + transpose; Brandes & Köpf, *Fast and
Simple Horizontal Coordinate Assignment* (2002).

`layout_test.gd` checks it against graphs with an obvious right answer — parallel chains,
a fully reversed bipartite graph, a chain that must come out perfectly straight — by
measuring crossings on the final coordinates rather than comparing to a recorded layout.

## Cables

A curved cable that passes straight through a node is unreadable — you cannot tell where
it goes. So a cable stays a smooth curve while its path is clear and switches to a routed
orthogonal trace with 45-degree corners when it would cross something, which is why PCB
traces look the way they do.

A graph dense enough will always have some crossings left. Where two cables do cross, the
lower one is **cut with a generous gap** and the upper one laid back over it, so it reads
as one cable passing beneath another. The gap is deliberately large: a timid one reads as
a rendering artefact rather than as a deliberate mark.
That is drawn on a Control inserted directly after GraphEdit's own connection layer —
above the cables, below the nodes — and recomputed only when the view actually changes,
since rerouting every cable on every frame is enough work to hold a core down by itself.

When the router's choice still is not what you want, **drag the cable**. That drops a
waypoint it must pass through, snapped to the same grid; right-clicking the cable removes
it. Waypoints are saved in the patch next to the node positions, so a layout you arranged
by hand comes back the way you left it.

## Undo

Undo works on whole-document snapshots rather than a hand-written inverse per operation.
A patch is a few kilobytes, and the code that turns a document into a view is the same
path used for loading — so "undo an edit" reduces to "load the previous document", which
cannot drift out of step with the edits the way per-operation inverses eventually do.

Two details matter in use:

**A drag is one step.** Node moves bracket on `begin_node_move`/`end_node_move`, knob
turns on the slider's `drag_started`/`drag_ended`, and cable drags on their own signal.
Without that, one sweep of a filter knob would bury the history under hundreds of entries.
A drag that ends where it started records nothing.

**Undoing a knob turn does not restart the sound.** If two snapshots differ only in
parameter values, the values are pushed straight to the running engine and the knobs move
to match — no rebuild, so oscillators keep their phase and delay lines keep their
contents. Rebuilding on every undo would make the feature unusable while playing, which is
the same reason knob movement never reloads the patch in the first place.

Opening a file starts a new history: undoing across a load would restore another patch's
nodes into this one.

## Type

The editor is set in **Atkinson Hyperlegible Next**, bold, at sizes well above the usual
editor default. It is the Braille Institute's typeface, drawn so that characters which
normally blur into one another — `I l 1`, `O 0`, `b d` — stay distinguishable at small
sizes and for low vision, and it is bundled here under the SIL Open Font License
(`fonts/OFL.txt`).

Colours are high contrast rather than the usual scale of greys: dimmed text is a lighter
grey, not white at reduced opacity, because fading the alpha costs contrast twice — once
against the background and again against everything around it.

This is the project's own rule from `docs/UX_PRINCIPLES.md` finally taken seriously:
*avoid tiny text, tiny hit targets, cryptic abbreviations, and maximum-density layouts as
the default.*

## Saving

Saved patches go through the core's own serialiser, not Godot's. Godot's `JSON.stringify`
sorts keys alphabetically and renders every number as a float, so a saved patch would come
back with `"schema_version": 1.0` and its fields shuffled. The patch format is the
product; it should not degrade depending on which editor wrote it.

Search accepts intent, not just names: *remove high frequencies*, *make quieter*, *echo*,
*midi keyboard*. The ranking comes from the core, so it matches the web editor and
`sg-validate --list-nodes`.

## Round trip

Milestone C's exit condition is that a patch edited here opens in the browser and vice
versa without changing meaning. That is checked by rendering, not by comparing text:

```bash
node tools/verify-roundtrip.mjs
```

It pushes each example through this editor's real load-and-save path — building the graph
view, generating the parameter widgets, reading it all back — then renders the original
and the result with `sg-render` and requires the audio to be **identical**, sample for
sample. Two patch files can differ in key order, number formatting and whitespace while
describing the same graph, and can look similar while describing different ones; only the
audio settles it.

## Notes for whoever edits this next

**Moving a knob must not reload the patch.** Parameter changes go straight to the running
engine and are recorded in the document. Rebuilding the graph would interrupt the sound,
which is exactly what "patching should feel immediate" rules out. Only structural edits —
adding, deleting, connecting, disconnecting — trigger a reload.

**Patch ids and Godot node names are not the same namespace.** Patch ids may contain
characters Godot rejects in a node name, so the mapping is kept explicitly in `ids` rather
than assuming the two agree.

**Rebuilding the view removes nodes before freeing them.** A queued node keeps its name
until the end of the frame, and a new node claiming that name gets silently renamed —
which corrupts the id mapping in a way that is very annoying to track down.
