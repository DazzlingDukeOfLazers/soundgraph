#include "soundgraph/graph_description.h"

namespace soundgraph {

const ParameterValue* NodeDescription::find_parameter(const std::string& parameter_name) const {
    for (const ParameterValue& value : parameters) {
        if (value.name == parameter_name) {
            return &value;
        }
    }
    return nullptr;
}

const NodeDescription* GraphDescription::find_node(const std::string& node_id) const {
    for (const NodeDescription& node : nodes) {
        if (node.id == node_id) {
            return &node;
        }
    }
    return nullptr;
}

std::string GraphDescription::metadata_value(const std::string& key) const {
    for (const MetadataEntry& entry : metadata) {
        if (entry.key == key) {
            return entry.value;
        }
    }
    return std::string();
}

void GraphDescription::set_metadata(const std::string& key, const std::string& value) {
    for (MetadataEntry& entry : metadata) {
        if (entry.key == key) {
            entry.value = value;
            return;
        }
    }
    metadata.push_back(MetadataEntry{key, value});
}

}  // namespace soundgraph
