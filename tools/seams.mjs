// Seams, for the generators — see docs/modules-design.md, "the seam made of nodes".
//
// A graph's edges are written as nodes. At the top level a seam carries a host binding and
// is the terminal that speaks to the machine; inside a module definition it carries none
// and is one of that module's ports.
//
// Its own file rather than a corner of migrate-seams.mjs, because that one is a command
// and importing it would run it.

// The one table, and it is patch-io's — see terminal_for() in patch-io/src/patch_io.cpp.
// Kept the other way round here because the generators go the other way.
export const SEAM_FOR = {
  NoteInput: ["Input", "note"],
  AudioInput: ["Input", "audio"],
  StereoOutput: ["Output", "stereo"],
};

/**
 * Turns a definition's `inputs`/`outputs` binding lists into the seam nodes that are
 * those ports, and returns it without them.
 *
 * The literals stay in the importers because a list of five named ports with a comment
 * each is the clearest way to *write* a surface; this is how it gets *said*. Ids are the
 * port names, since that is what a seam's port name is read from. A name already taken by
 * an inner node gets qualified and carried on the seam's `name` instead — two nodes with
 * one id is a document nothing can load.
 */
export function drawDefinitionPorts(definition) {
  const nodes = [...(definition.nodes ?? [])];
  const connections = [...(definition.connections ?? [])];
  const taken = new Set(nodes.map((n) => n.id));

  for (const [list, type] of [[definition.inputs, "Input"],
                              [definition.outputs, "Output"]]) {
    for (const binding of list ?? []) {
      let id = binding.name;
      if (taken.has(id)) {
        id = `${binding.name}_port`;
        for (let n = 2; taken.has(id); n += 1) id = `${binding.name}_port-${n}`;
      }
      taken.add(id);
      const seam = { id, type };
      if (id !== binding.name) seam.name = binding.name;
      nodes.push(seam);
      connections.push(type === "Input"
        ? { from: { node: id, port: "out" },
            to: { node: binding.node, port: binding.port } }
        : { from: { node: binding.node, port: binding.port },
            to: { node: id, port: "in" } });
    }
  }

  const drawn = { ...definition, nodes, connections };
  delete drawn.inputs;
  delete drawn.outputs;
  return drawn;
}
