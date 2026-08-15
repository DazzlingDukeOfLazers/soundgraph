# Schema-level modules — design

A module is a named subgraph with declared ports, defined once inside a patch and
instantiated as an ordinary node. This document is the design: what changes in the
schema, where expansion happens, what every target sees, and the staged plan with an
exit test per stage. Stage 1 is implemented; see the staged plan below.

## Why now, and why not before

`module_import.gd` records the standing decision: *"There is no sub-graph in the patch
format and there deliberately is not going to be one: a nested graph is a second thing
every target has to understand, and the promise is that one file runs everywhere."*
That decision was right when it was made, and its two concerns still bind:

1. one file must run on every target unchanged, and
2. opening a patch must never mean resolving links to files you may not have.

What changed is measured, not felt. The DX7 import produces 33-node documents whose
readability sits at the packing-density floor — the modular *layout* recovered what
layout can (three rows of emergent tiles at ~68% packing efficiency) and its ceiling is
now known. The repetition is not visual: a DX7 voice **is** six instances of one
subcircuit, the importer knows it at generation time, and the document format is the
only place that knowledge cannot currently be written down. Meanwhile the "second thing
every target has to understand" objection turns out to name one function in one place:
**every target — native, WASM, the Godot extension, the ESP32 firmware — links the same
patch-io** (`embedded/components/soundgraph-core` compiles it verbatim). Expansion
implemented in patch-io's loader is implemented everywhere, once.

So the design keeps both original concerns intact:

- **Definitions are inline.** A module lives in the same file that uses it. No
  external references, no resolution, no registry. Concern 2 holds by construction.
- **dsp-core never learns.** patch-io flattens instances into plain nodes before
  `Graph::build` runs. The engine, the scheduler, the golden manifest, the firmware's
  steady state: all unchanged. Concern 1 holds because the runtime document model is
  exactly what it is today.

A module is therefore a **notation**, not a runtime object — the same relationship a
`for` loop has to its unrolled body. That is deliberately modest, and it is enough:
notation is what the 33-node problem is made of.

## The schema

Two additions, both illustrated with the real DX7 operator:

```json
{
  "schema_version": 2,
  "modules": {
    "operator": {
      "description": "One DX7 operator: pitch ratio, sine, envelope, VCA.",
      "nodes": [
        { "id": "pitch", "type": "Multiply", "parameters": { "factor": 1.0 } },
        { "id": "osc",   "type": "SineOscillator", "parameters": {} },
        { "id": "env",   "type": "ADSR", "parameters": { "attack": 0.01 } },
        { "id": "vca",   "type": "Multiply", "parameters": {} }
      ],
      "connections": [
        { "from": { "node": "pitch", "port": "out" }, "to": { "node": "osc", "port": "frequency" } },
        { "from": { "node": "osc",   "port": "out" }, "to": { "node": "vca", "port": "a" } },
        { "from": { "node": "env",   "port": "out" }, "to": { "node": "vca", "port": "b" } }
      ],
      "inputs": [
        { "name": "note",  "node": "pitch", "port": "a" },
        { "name": "gate",  "node": "env",   "port": "gate" },
        { "name": "pm",    "node": "osc",   "port": "pm" }
      ],
      "outputs": [
        { "name": "out", "node": "vca", "port": "out" }
      ],
      "parameters": [
        { "name": "ratio",    "node": "pitch", "parameter": "factor" },
        { "name": "feedback", "node": "osc",   "parameter": "feedback" }
      ]
    }
  },
  "nodes": [
    { "id": "note", "type": "NoteInput", "parameters": {} },
    { "id": "op1", "type": "module", "module": "operator",
      "parameters": { "ratio": 1.0 } },
    { "id": "op2", "type": "module", "module": "operator",
      "parameters": { "ratio": 3.0, "feedback": 0.4 } }
  ],
  "connections": [
    { "from": { "node": "note", "port": "frequency" }, "to": { "node": "op1", "port": "note" } },
    { "from": { "node": "op2",  "port": "out" },       "to": { "node": "op1", "port": "pm" } }
  ]
}
```

Rules, each one a validator check:

- **`type: "module"` + `module: <name>`** — an instance is an ordinary entry in
  `nodes`, connected by its declared port names. Everything downstream of validation
  (controls, automation, arrangement) refers to instances like any node.
- **Declared surface only.** An instance exposes the module's `inputs`, `outputs` and
  `parameters` — nothing else. Reaching into `op1.osc` from outside the definition is
  invalid. The facade is the point: six knobs a voice actually wants, not thirty.
- **Exported parameters** behave exactly like node parameters: an instance's
  `parameters` values override the definition's inner defaults, per instance. Controls
  and automation may target them.
- **No modules inside modules** in this version. Definitions instantiate node types
  only. This removes recursion, makes the expansion bound `instances × definition
  size`, and postpones a real question (below) rather than answering it badly.
- **A panel is presentation, never surface.** A definition may carry an optional
  `panel` saying which exported parameters get a knob, how they group into rows, and
  what each is called there:

  ```json
  "panel": {
    "rows": [["attack", "decay", "sustain", "release"], ["gain"]],
    "labels": { "gain": "Level" }
  }
  ```

  It changes nothing else. A parameter left off the panel is still exported, still
  overridable per instance, still a legal control and automation target — it simply has
  no knob on the face. That separation is the point: a derived surface errs toward
  exporting everything, and the panel is where an author says which six of the thirty a
  player actually turns. An absent panel means every export in declared order, which is
  what modules had before panels and what a *derived* collapse still produces.

- **A surface may be nominated instead of derived.** Deriving is a fair guess standing
  in for being told, and one of its rules hurts: "every parameter that was set becomes a
  knob" is what makes a collapsed module arrive wearing thirty. So `collapse` takes an
  optional nomination — the ports and knobs an author pointed at, in the order they
  pointed at them — and given one, derives nothing. In the editor that pointing is the
  **wand** (Graph tab): raise it, click the jacks and knobs on the selected nodes, and
  the badges number them as they go. Only the selection is pickable, which is the same
  rule as "a nomination outside the selection is ignored", stated so that there is
  nothing there to click rather than a sentence explaining a click that did nothing.

  A nomination needs no panel: declared order is click order and a face is drawn in
  declared order, so a panel here would restate it. The panel earns its keep when a knob
  is dragged somewhere the order would not have put it.

  Two things override a nomination, for one reason — something is already attached. A
  boundary connection declares its port whether or not it was picked, and a control or
  automation lane targeting an inner knob exports that knob whether or not it was
  picked. Honouring the nomination in either case would silently drop wiring somebody
  had made, which is worse than a module having one more port than was asked for.

  A row naming something the module does not export costs that knob and nothing else —
  the rule `arrangement` follows, because both are presentation. Two asymmetries worth
  knowing: unlike `rack_order`, exports the panel omits are **not** appended, since
  omission is the whole authoring act; and unlike the renderer, the *loader* keeps an
  unresolvable name verbatim, because a tool that saves a patch it does not fully
  understand must hand the file back intact. Leniency at the edge, fidelity in the
  middle.

- **`schema_version: 2` iff the document contains modules.** A module-free document
  is byte-for-byte a v1 document, forever. Version is a capability floor, and the
  existing contract — "a runtime must refuse a patch whose schema_version it does not
  implement" — gives old runtimes a loud, clean refusal instead of a silent
  misreading. `patch.schema.json` grows the `modules` section and conditionally
  permits `"module"` type, so conforming validators agree with ours (the slash-in-ids
  lesson: our parser must never be the lenient one).

## Expansion

In patch-io, at parse time, before `GraphDescription` reaches `Graph::build`:

- Instance `op1` of `operator` becomes nodes `op1.pitch`, `op1.osc`, … — the dot
  separator is `ModuleImport.SEPARATOR`, already legal in the id charset and already
  the convention the import feature established.
- Inner connections are copied per instance. Boundary connections re-target through
  the port declarations (`op1`/`note` → `op1.pitch`/`a`).
- Exported parameter values overwrite the inner node's parameter in that instance.
- Diagnostics and `get_info` speak flattened ids. `op1.osc` is self-explanatory to a
  person, and the editor can fold anything left of the dot back onto the instance.

`GraphDescription` carries the hierarchy (definitions + instance nodes) and exposes a
flattened view for building; `write_patch` writes the hierarchy back. **Round-trip
preserves the module structure** — flattening is for the engine, never for the file.

Device note: expansion allocates during *load*, which is where allocation already
lives. The steady-state invariant (no allocation, locks, or I/O in `process()`) is
untouched. The abuse suite gains: unknown module name, undeclared port, duplicate
export names, module-typed node inside a definition, and an expansion-size bomb
(instances × nodes over the existing engine cap must refuse, not exhaust the heap).

## What the editor does with it

- **Stage A (with stage 1 below):** an instance renders as one GraphNode with the
  declared ports and exported parameters — the tiles the modular layout discovers
  today become real, collapsible objects. The layout treats instances as nodes; the
  18-node threshold suddenly means "big patches get modularized by their *author*."
- **Collapse selection into module:** the editor's inverse operation — selected nodes
  become a definition, their boundary edges become declared ports, the selection
  becomes an instance. `ModuleImport` stays as-is (import-by-copy is still right for
  *foreign* patches) and gains a sibling: import as definition.
- **Editing a definition** edits every instance; the undo model is already
  document-snapshot-based, so this costs nothing new. Entering a definition
  (double-click) to edit it in place is a later stage; the first editing surface is
  the inspector on the instance plus expand-in-place read-only.

## Staged plan, with exit tests

> **The wand landed.** A module's face can be pointed at rather than worked out:
> select the nodes, raise the wand in the Graph toolbar, click the jacks and knobs it
> should show. Picks are numbered as they accumulate, clicking one again takes it back
> off, and taking a node out of the selection takes its picks with it and renumbers the
> rest. Picking happens in `PatchGraph._input`, ahead of the GUI pass, which is the only
> reason a knob can be picked at all — a knob is a Control and would otherwise swallow
> its own press; anything the wand does not want falls straight through, so selecting,
> dragging and panning are untouched with it up.
>
> The same toggle has a second half in the Graphrack tab, where the module exists and is
> wearing that face: a knob becomes a tile, and dragging it writes `panel.rows`. This is
> the only gesture in the editor that writes a panel. Rows are read off the knobs rather
> than out of the panel, so a module that has never been arranged is rearranged from the
> arrangement on screen — the GridContainer's own two-column wrap — and the first drag
> writes down what was already true plus the one thing that changed. A row's middle half
> means "into this row" and its top and bottom quarters mean "on a new line", which is
> the only way to say that with a gesture that has no second button. Only a module can be
> rearranged; an ordinary node's face comes from the registry and a patch has nowhere to
> put an opinion about it.
>
> And after the fact, the same drag edits the surface a module already has. Everything a
> face could show and does not is drawn on it as a ghost — an export the panel leaves off,
> and every inner knob nobody exported — so putting one on is a drag from there to here
> rather than a trip to a list. An unexported one is exported on the way in, because "put
> this knob on the module" is one thought; the export name is chosen by the document,
> which is the only party that knows what is already taken. Dragging a knob *off* the
> module takes it off the face and leaves it exported, so nothing pointing at it breaks —
> the reversible edit cannot do the destructive one by accident. Undeclared inner ports
> are ghost jacks; a click declares one, since a port is on the face or it is not and
> there is no arrangement for it to land in.
>
> Only the additive directions are reachable. Declaring a port is safe — nothing can be
> plugged into a port that did not exist — while *un*declaring one strands whatever is
> plugged in, and un-exporting a knob strands the controls and automation aimed at it.
> Those are edits worth a considered surface rather than a click, and they do not have one
> since the Builder tab went. Renaming a module went with it too.

> **Stage 4 landed — the design is complete.** Both importers emit modules by
> default: the DX7 bank is one operator definition and six instances per voice, the
> OPL2 bank one definition and two instances per instrument, and each importer
> carries a --modular-check in ctest that renders every voice both ways and demands
> byte-identical audio (32 + 128, all green on the flip). Both oracle comparators run
> over the modular documents without noticing — which is the design's promise kept:
> notation for people, the same flat graph for everything that measures.

> **Stage 3 landed.** ModuleAuthor carries both authoring transforms, registry-blind:
> collapse-selection (Arrange menu) factors nodes into a definition plus one instance,
> boundary connections becoming ports, every authored knob an export, controls and
> automation remapped through the facade — the exit test renders the collapsed and
> original documents to byte-identical audio. Import-as-definition (File menu) brings
> a foreign patch in as one thing, its terminals becoming ports named for what fed
> them. Fixed en route: the native dialog import path had never honoured the
> add-module flag at all — it opened the file over the current document.

> **Stage 2 landed.** Instances render as single nodes wearing their declared
> surface — synthesized registry descriptors under "module:<name>", consumed by the
> graph, rack, outline and inspector without any of them learning what a module is.
> Exported knobs write the instance in the document and reach the inner node in the
> engine; glow and scopes read through the facade; saving writes the hierarchy. The
> committed fixture algo-01-modular opens as 15 authored nodes at 39% fit against the
> flat 33-node 23% floor — and getting there taught the layout to judge its own
> output: a flat result that is too wide *or* too empty (under 22% packing) re-lays
> itself through the modular flow.

> **Stage 1 landed.** parse/validate/expand/write in patch-io; schema updated; the
> documented abuses refuse with named diagnostics; all 32 demo voices render
> byte-identical flat vs modular (in ctest as modules_flatten_to_identical_audio);
> and a schema-v2 modular document deployed to the ESP32-S3 over serial expanded
> on-device — every target speaks modules because every target links the loader.

1. **patch-io + schema:** parse, validate, expand, write. *Exit:* the DX7 importer
   emits `algo-01` as one `operator` definition + six instances, and its flattened
   render is **byte-identical** to today's flat document's render — the golden
   comparison is the proof that notation changed and sound did not. Abuse cases
   above. All targets re-verified (same patch-io everywhere; ESP32 flashed).
2. **Editor rendering:** instances as single nodes; layout consumes them; round-trip
   through the editor preserves definitions. *Exit:* editor_test loads the modular
   algo-01, sees ~10 top-level nodes, saves, and the file still has its `modules`
   section; fit lands materially above the measured 23% floor.
3. **Authoring:** collapse-selection, import-as-definition, exported-parameter
   editing in the inspector. *Exit:* a round trip of collapse → save → load → expand
   reproduces the original wiring.
4. **DX7/OPL importers emit modules by default** once 1–2 are proven.

## `Input` and `Output` — the seam made of nodes

**Built.** Written down first because it moves where a module's edge *lives*, and that was
a decision worth arguing about before there was code to argue with. The argument below
stands as it was made; what follows it is what the four decisions were settled to, and all
four are now in the loader, the editor and every generator. Both spellings load — a patch
written the old way opens unchanged — but nothing in this repository writes the old way
any more.

Today a module's surface is a **list beside the graph**: `inputs` and `outputs` are
binding objects in the definition, saying "the port called `gate` means `env.gate`
inside." The list is derived at collapse and edited afterwards through a tool. That
works, and two things about it keep costing:

- **The seam is invisible.** Nothing on the canvas is the edge of the module. You find
  out what a module exposes by opening a panel, or by collapsing it and looking at the
  node that comes out. The one place the boundary is real — the wiring that crosses it
  — is exactly where it is not drawn.
- **The order is nobody's.** Port order is the order bindings landed in the list, which
  is the order boundary connections were walked. That is why the wand had to invent a
  click-order rule to say otherwise.

The proposal is that a module's edge is made of ordinary nodes: an `Input` node inside a
definition *is* an input, and an `Output` node *is* an output. Their order on the canvas
is the port order. Their names are the port names. The keyboard plugs into an `Input`,
which is the same thing a cable from outside plugs into, because now they are the same
thing.

This is what inlets and outlets do in Max and Pd, and terminals in Reaktor, and it is
the convention for the same reason in all three: the boundary is the one part of a
subpatch you need to see while you are inside it.

**What it buys.** The seam is on screen and in the file in one place. `collapse` stops
deriving a surface and starts *creating the nodes that are the surface* — no nomination
argument, no panel needed to state an order, no "which of these did you mean". A module
opened for editing shows its own edges, so the thing you are wiring to is drawn rather
than remembered. And a patch and a module stop being different kinds of object: a patch
with `Input` and `Output` nodes at the top level is already a module, which is what
`from_patch` has been faking with terminals.

**What it costs, and the decisions that go with it.**

1. **Do they replace the binding lists, or coexist?** Replacing is the honest version
   and it is a format change: every module in every example and both importer banks is
   written the other way. Coexisting means two ways to say one thing, which is the
   failure mode this document has avoided everywhere else. The migration is mechanical
   — a definition's `inputs` list becomes `Input` nodes wired to what the bindings named
   — and it should be done as a conversion in patch-io rather than by hand.
2. **What are they made of at runtime — settled: nothing.** They are notation, exactly
   like `type: "module"`, and dsp-core never learns either one.

   Checked against the code rather than assumed. `expand_modules` in
   `patch-io/src/patch_io.cpp` already performs the splice this needs: a connection
   arriving at `instance.gate` is rewritten to `expanded_id(instance, declared->node)`
   and `declared->port`, so the outside cable lands directly on the inner node's real
   port and the binding is consumed at load. A seam node replaces that binding, and
   expansion does the identical thing — find the `Input` named `gate`, find what it
   feeds, aim the outside cable there. The seam is gone before `Graph::build` runs.

   Fan-out needs no special case: one `Input` feeding three inner nodes is three
   rewritten connections, which is what a declared port already does. A seam feeding
   nothing is a declared port that goes nowhere, which an unused binding can be today.

   So the whole change lives in patch-io and the editor, and the invariant this document
   opens with — *"dsp-core never learns"* — holds without being defended. The only real
   nodes involved stay the ones that already exist: a **host-bound** seam converts on
   load into `NoteInput`, `AudioInput` or `StereoOutput`, which are and remain ordinary
   dsp-core nodes.

   That conversion is also what settles the shape problem. A dsp-core node's ports are
   fixed at compile time, so one `Input` type cannot have four ports bound to `note` and
   one bound to nothing. It does not have to: the four-port case *becomes* `NoteInput`
   during load, and the one-port case is spliced out. Neither ever needs a node whose
   shape depends on a parameter.

   The rule that falls out, and it is a good one: **a seam inside a module may not carry
   a host binding.** A module's ports are its own; one reaching past its edge for the
   keyboard would mean two instances sharing one.

   *Revised once the dock existed.* The first version of this rule had a second half —
   *a seam at the top level **must** carry a host binding* — and it was wrong, for a
   reason that only showed up when the keyboard became a thing you plug in rather than a
   node you draw. If every top-level port must be bound, then unplugging one is illegal,
   and the gesture of moving the keyboard from one input to another can only ever be a
   swap between two already-bound ports. That is not a gesture anybody wants.

   So: **an unbound top-level seam is a port nothing is currently driving**, and it is
   spliced exactly as a module's port is. What it fed has no source and goes silent,
   which is what an unplugged input sounds like on any instrument. Three things
   recommend this over the refusal. It is strictly backward-compatible — every patch that
   loaded before still loads. It keeps the editor unable to write a file the loader
   rejects, which is an invariant this project holds everywhere. And it makes "this patch
   is usable as a module" a visible state rather than a claim: a patch with unbound ports
   *is* one, and looks like one.
3. **The existing terminals — settled: same idea at two scales.** `NoteInput`,
   `AudioInput` and `StereoOutput` become `Input` and `Output` carrying a **host
   binding**: a seam whose other side is the machine rather than another patch. There is
   one concept, and a reader learns it once.

   This is worth more than the tidiness. It ends the rule that terminals may not live
   inside a module — the rule behind *"`note` is a terminal; a module is a subcircuit,
   not a finished patch"*. That refusal was never about terminals being a different kind
   of thing; it was about a module reaching past its own edge to grab the keyboard
   directly, so two instances would both be listening to the same one. With one concept
   the refusal is stated where it belongs: **a seam inside a module may not carry a host
   binding.** Same protection, and now it reads as a sentence about scope rather than a
   list of forbidden types.

   It also makes `from_patch` stop pretending. Importing a foreign patch as a definition
   works today by treating its terminals as though they were ports — which is exactly
   what they now are, minus the binding. Import becomes: drop the host bindings. That is
   the whole operation.

   **What a host binding provides is a shape, not a signal.** `Input{host: note}` carries
   the four the keyboard has — frequency, gate, velocity, trigger — because the host is a
   fixed thing with a known shape, and a keyboard is one device rather than four. A seam
   with no host binding is a single port, named by its node, because a module port is
   whatever somebody chose to call it and "in what order" only means anything per port.
   That asymmetry is real and worth stating out loud rather than discovering.

   The migration is then a rename plus a binding, not a restructure: every `NoteInput` in
   every example and both importer banks becomes an `Input` bound to `note`, with the
   same id, the same ports and the same cables. patch-io does it on load, so old files
   keep working and nothing has to be rewritten by hand.
4. **A module with no edges.** Today that is a definition with empty lists. Then it is a
   definition with no `Input` nodes, which is the same fact and reads better.

**What it does not change.** Exports stay a list: a knob is not a place on the boundary,
it is a name for something inside, and there is nothing for it to be a node *of*. The
panel stays presentation. Expansion stays the guarantee that every notation renders the
same audio.

## Deferred, deliberately

- **Cross-file module libraries** — reintroduces concern 2; if it ever comes, it
  comes as *vendoring on import* (copy the definition in), never as live links.
- **Nested modules** — wanted eventually (a DX7 voice inside a performance patch);
  needs a recursion budget and better diagnostics; not worth designing until stage 3
  usage exists.
- **Runtime modules** (dynamic voice allocation, per-instance bypass) — a different
  feature wearing the same name; nothing in this design blocks it, nothing requires
  it.
