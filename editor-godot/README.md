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
| Add a node | **Ctrl+Space**, or right-click the canvas, or the toolbar button |
| Play | **A W S E D F T G Y H U J K**, with **Z** / **X** to shift octave |
| Inspect a signal | select a node — the scope shows what its first output is carrying |
| Fix a problem | the panel names the nodes involved and highlights them in the graph |

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
