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

struct ParameterValue {
    std::string name;
    double value = 0.0;
};

struct NodeDescription {
    std::string id;      // stable identity; connections refer to this
    std::string type;    // registry type name
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

struct GraphDescription {
    int schema_version = kSchemaVersion;
    std::vector<MetadataEntry> metadata;
    std::vector<std::string> tags;
    std::vector<NodeDescription> nodes;
    std::vector<ConnectionDescription> connections;
    std::vector<ControlDescription> controls;
    std::vector<AutomationLane> automation;

    const NodeDescription* find_node(const std::string& node_id) const;
    std::string metadata_value(const std::string& key) const;
    void set_metadata(const std::string& key, const std::string& value);
};

}  // namespace soundgraph
