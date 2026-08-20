// SoundGraph — the in-memory description of a patch.
//
// This is what patch-io produces and what the runtime consumes. It mirrors
// schema/patch.schema.json but contains no parsing: dsp-core never sees text.
#pragma once

#include <string>
#include <vector>

#include "soundgraph/types.h"

namespace soundgraph {

inline constexpr int kSchemaVersion = 1;

// Documents that use modules declare this version, so a runtime that predates them
// refuses loudly instead of misreading. Module-free documents stay version 1 forever.
inline constexpr int kSchemaVersionModules = 2;

// Documents that carry audio buffers declare this version, for the same reason.
inline constexpr int kSchemaVersionBuffers = 3;

struct ParameterValue {
    std::string name;
    double value = 0.0;
};

// Recorded audio carried by the patch, decoded: patch-io turns base64 PCM into these
// floats, and dsp-core only ever sees the floats. A patch that plays a break carries
// the break — the same self-containment rule modules established.
struct BufferDescription {
    std::string id;
    double sample_rate = 48000.0;
    std::vector<float> samples;  // mono
};

struct NodeDescription {
    std::string id;      // stable identity; connections refer to this
    std::string type;    // registry type name, or "module" for an instance
    std::string module;  // when type == "module": which definition this instantiates
    std::string buffer;  // when set: which of the patch's buffers this node plays
    // When type is "Input" or "Output": which side of the machine this seam is on.
    // Empty means a module's own edge — a port, spliced out by expansion. Set means the
    // patch's edge, and the seam becomes the terminal that already speaks to that host.
    // See docs/modules-design.md, "the seam made of nodes".
    std::string host;
    std::string name;    // cosmetic label
    std::vector<ParameterValue> parameters;

    // Editor layout, carried so a patch opens the same way in every editor.
    bool has_position = false;
    float x = 0.0f;
    float y = 0.0f;
    bool collapsed = false;

    const ParameterValue* find_parameter(const std::string& parameter_name) const;
};

struct ConnectionDescription {
    std::string from_node;
    std::string from_port;
    std::string to_node;
    std::string to_port;

    // Editor layout, carried like node positions so a patch looks the same in every
    // editor. The runtime never reads it.
    bool has_waypoint = false;
    float waypoint_x = 0.0f;
    float waypoint_y = 0.0f;
};

struct ControlTarget {
    std::string node;
    std::string parameter;
};

struct ControlDescription {
    std::string id;
    std::string label;
    std::string kind = "knob";
    ControlTarget target;
    bool has_range = false;
    double min_value = 0.0;
    double max_value = 1.0;
    bool has_default = false;
    double default_value = 0.0;
    std::string scaling;   // "linear" | "exponential" | "logarithmic"; empty = registry default
    int midi_cc = -1;
    int midi_channel = -1;
    int encoder = -1;
};

struct AutomationPoint {
    double time = 0.0;
    double value = 0.0;
};

struct AutomationLane {
    std::string id;
    ControlTarget target;
    bool loop = false;
    double length_seconds = 0.0;
    std::string interpolation = "linear";
    std::vector<AutomationPoint> points;
};

struct MetadataEntry {
    std::string key;
    std::string value;
};

// Presentation hints. Carried through the format and ignored by everything that makes
// sound — dropping the lot costs a nicer picture and nothing else.
//
// Positions and waypoints are not here: they belong on the node and the connection they
// describe. This is for hints about a whole view, which have nothing to hang off.
struct Arrangement {
    std::vector<std::string> rack_order;   // node ids, left to right in the rack view

    bool empty() const { return rack_order.empty(); }
};

// A module: a named subgraph with a declared surface. Pure data, like everything in
// this header — dsp-core never acts on it. patch-io expands instances into plain nodes
// before the engine looks, so a module is notation, the way a loop is notation for its
// unrolled body. See docs/modules-design.md.
struct ModulePortDescription {
    std::string name;   // the port the instance shows the world
    std::string node;   // which inner node it lands on
    std::string port;   // and which of that node's ports
};

struct ModuleParameterDescription {
    std::string name;       // the knob the instance shows the world
    std::string node;       // which inner node it reaches
    std::string parameter;  // and which parameter there
};

// The face an instance wears: which exported parameters get a knob, how they are grouped
// into rows, and what each is called on the panel.
//
// Presentation only, in the same sense as Arrangement — it never changes what a patch
// sounds like, and it never changes the declared surface. A parameter left off the panel
// is still exported, still settable per instance, still a legal target for controls and
// automation; it simply has no knob on the face. That separation is the whole point: the
// derived surface errs toward exporting everything, and a panel is where an author says
// which six of the thirty a player actually turns.
//
// An absent panel means "every export, in declared order" — what every module written
// before panels had, and what a fresh collapse still produces.
struct ModulePanelLabel {
    std::string parameter;  // the exported name
    std::string label;      // what the panel calls it instead
};

struct ModulePanel {
    std::vector<std::vector<std::string>> rows;  // exported parameter names, per panel row
    std::vector<ModulePanelLabel> labels;

    bool empty() const { return rows.empty() && labels.empty(); }
    const std::string* label_for(const std::string& parameter) const;
};

struct ModuleDescription {
    std::string name;
    std::string description;
    std::vector<NodeDescription> nodes;
    std::vector<ConnectionDescription> connections;
    std::vector<ModulePortDescription> inputs;
    std::vector<ModulePortDescription> outputs;
    std::vector<ModuleParameterDescription> parameters;
    ModulePanel panel;

    const ModulePortDescription* find_input(const std::string& port_name) const;
    const ModulePortDescription* find_output(const std::string& port_name) const;
    const ModuleParameterDescription* find_parameter(const std::string& parameter_name) const;
};

struct GraphDescription {
    int schema_version = kSchemaVersion;
    Arrangement arrangement;
    std::vector<MetadataEntry> metadata;
    std::vector<std::string> tags;
    std::vector<NodeDescription> nodes;
    std::vector<ConnectionDescription> connections;
    std::vector<ControlDescription> controls;
    std::vector<AutomationLane> automation;
    std::vector<BufferDescription> buffers;

    // Modules, and the document as authored. When `modules` is non-empty, the vectors
    // above hold the *flattened* view — instances expanded into plain nodes, which is
    // all the engine ever builds from — and the authored_* vectors hold what the file
    // actually said, which is all write_patch ever writes. Flattening is for the
    // engine, never for the file.
    std::vector<ModuleDescription> modules;
    bool authored_taken = false;
    std::vector<NodeDescription> authored_nodes;
    std::vector<ConnectionDescription> authored_connections;
    std::vector<ControlDescription> authored_controls;
    std::vector<AutomationLane> authored_automation;
    int authored_schema_version = kSchemaVersion;

    bool has_modules() const { return !modules.empty(); }
    const ModuleDescription* find_module(const std::string& module_name) const;
    const BufferDescription* find_buffer(const std::string& buffer_id) const;
    const NodeDescription* find_node(const std::string& node_id) const;
    std::string metadata_value(const std::string& key) const;
    void set_metadata(const std::string& key, const std::string& value);
};

}  // namespace soundgraph
