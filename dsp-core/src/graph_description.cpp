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

const ModulePortDescription* ModuleDescription::find_input(const std::string& port_name) const {
    for (const ModulePortDescription& port : inputs) {
        if (port.name == port_name) {
            return &port;
        }
    }
    return nullptr;
}

const ModulePortDescription* ModuleDescription::find_output(const std::string& port_name) const {
    for (const ModulePortDescription& port : outputs) {
        if (port.name == port_name) {
            return &port;
        }
    }
    return nullptr;
}

const ModuleParameterDescription* ModuleDescription::find_parameter(
        const std::string& parameter_name) const {
    for (const ModuleParameterDescription& parameter : parameters) {
        if (parameter.name == parameter_name) {
            return &parameter;
        }
    }
    return nullptr;
}

const std::string* ModulePanel::label_for(const std::string& parameter) const {
    for (const ModulePanelLabel& entry : labels) {
        if (entry.parameter == parameter) {
            return &entry.label;
        }
    }
    return nullptr;
}

const ModuleDescription* GraphDescription::find_module(const std::string& module_name) const {
    for (const ModuleDescription& definition : modules) {
        if (definition.name == module_name) {
            return &definition;
        }
    }
    return nullptr;
}

const BufferDescription* GraphDescription::find_buffer(const std::string& buffer_id) const {
    for (const BufferDescription& entry : buffers) {
        if (entry.id == buffer_id) {
            return &entry;
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
