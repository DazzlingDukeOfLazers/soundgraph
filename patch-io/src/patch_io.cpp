#include "soundgraph/patch_io.h"

#include <fstream>
#include <sstream>

#include "json.h"

namespace soundgraph {
namespace {

Diagnostic error(std::string code, std::string message, std::string suggestion = std::string()) {
    Diagnostic diagnostic;
    diagnostic.severity = Severity::Error;
    diagnostic.code = std::move(code);
    diagnostic.message = std::move(message);
    diagnostic.suggestion = std::move(suggestion);
    return diagnostic;
}

Diagnostic warning(std::string code, std::string message, std::string suggestion = std::string()) {
    Diagnostic diagnostic = error(std::move(code), std::move(message), std::move(suggestion));
    diagnostic.severity = Severity::Warning;
    return diagnostic;
}

bool read_endpoint(const json::Value& value,
                   const char* which,
                   std::size_t index,
                   std::string& node,
                   std::string& port,
                   std::vector<Diagnostic>& diagnostics) {
    const json::Value* endpoint = value.find(which);
    if (endpoint == nullptr || !endpoint->is_object()) {
        diagnostics.push_back(error(
            "connection_missing_endpoint",
            "Connection " + std::to_string(index) + " has no '" + which + "' endpoint.",
            "Each connection needs \"from\" and \"to\" objects, each with \"node\" and \"port\"."));
        return false;
    }
    const json::Value* node_value = endpoint->find("node");
    const json::Value* port_value = endpoint->find("port");
    if (node_value == nullptr || !node_value->is_string() ||
        port_value == nullptr || !port_value->is_string()) {
        diagnostics.push_back(error(
            "connection_malformed_endpoint",
            "Connection " + std::to_string(index) + " has a malformed '" + which + "' endpoint.",
            "Both \"node\" and \"port\" must be strings."));
        return false;
    }
    node = node_value->as_string();
    port = port_value->as_string();
    return true;
}

void read_control_target(const json::Value& parent,
                         ControlTarget& target) {
    const json::Value* value = parent.find("target");
    if (value == nullptr || !value->is_object()) {
        return;
    }
    if (const json::Value* node = value->find("node")) {
        if (node->is_string()) {
            target.node = node->as_string();
        }
    }
    if (const json::Value* parameter = value->find("parameter")) {
        if (parameter->is_string()) {
            target.parameter = parameter->as_string();
        }
    }
}

json::Value write_control_target(const ControlTarget& target) {
    json::Value value = json::Value::make_object();
    value.set("node", json::Value(target.node));
    value.set("parameter", json::Value(target.parameter));
    return value;
}

}  // namespace

bool parse_patch(const std::string& text,
                 GraphDescription& out,
                 std::vector<Diagnostic>& diagnostics) {
    out = GraphDescription();

    json::Value root;
    std::string parse_error;
    if (!json::parse(text, root, parse_error)) {
        diagnostics.push_back(error("invalid_json", "This file is not valid JSON: " + parse_error));
        return false;
    }
    if (!root.is_object()) {
        diagnostics.push_back(error("patch_not_an_object",
                                    "A patch must be a JSON object at the top level."));
        return false;
    }

    const json::Value* version = root.find("schema_version");
    if (version == nullptr || !version->is_number()) {
        diagnostics.push_back(error(
            "missing_schema_version",
            "This patch has no schema_version.",
            "Add \"schema_version\": 1. Every patch carries its version so that a runtime "
            "never has to guess how to read it."));
        return false;
    }
    out.schema_version = static_cast<int>(version->as_number());

    if (const json::Value* metadata = root.find("metadata")) {
        if (metadata->is_object()) {
            for (const auto& entry : metadata->object()) {
                if (entry.first == "tags" && entry.second.is_array()) {
                    for (const json::Value& tag : entry.second.array()) {
                        if (tag.is_string()) {
                            out.tags.push_back(tag.as_string());
                        }
                    }
                } else if (entry.second.is_string()) {
                    out.set_metadata(entry.first, entry.second.as_string());
                }
            }
        }
    }

    const json::Value* nodes = root.find("nodes");
    if (nodes == nullptr || !nodes->is_array()) {
        diagnostics.push_back(error("missing_nodes", "This patch has no \"nodes\" array."));
        return false;
    }

    bool ok = true;
    for (std::size_t i = 0; i < nodes->array().size(); ++i) {
        const json::Value& entry = nodes->array()[i];
        if (!entry.is_object()) {
            diagnostics.push_back(error("node_not_an_object",
                                        "Node " + std::to_string(i) + " is not an object."));
            ok = false;
            continue;
        }

        NodeDescription node;
        const json::Value* id = entry.find("id");
        const json::Value* type = entry.find("type");
        if (id == nullptr || !id->is_string() || id->as_string().empty()) {
            diagnostics.push_back(error(
                "node_missing_id",
                "Node " + std::to_string(i) + " has no id.",
                "Ids are how connections find nodes, so every node needs one."));
            ok = false;
            continue;
        }
        if (type == nullptr || !type->is_string()) {
            diagnostics.push_back(error("node_missing_type",
                                        "Node '" + id->as_string() + "' has no type."));
            ok = false;
            continue;
        }
        node.id = id->as_string();
        node.type = type->as_string();

        if (const json::Value* name = entry.find("name")) {
            if (name->is_string()) {
                node.name = name->as_string();
            }
        }
        if (const json::Value* parameters = entry.find("parameters")) {
            if (parameters->is_object()) {
                for (const auto& parameter : parameters->object()) {
                    if (!parameter.second.is_number()) {
                        diagnostics.push_back(warning(
                            "parameter_not_a_number",
                            "Parameter '" + parameter.first + "' on node '" + node.id +
                                "' is not a number and will be ignored."));
                        continue;
                    }
                    node.parameters.push_back(ParameterValue{parameter.first, parameter.second.as_number()});
                }
            }
        }
        if (const json::Value* position = entry.find("position")) {
            if (position->is_object()) {
                const json::Value* x = position->find("x");
                const json::Value* y = position->find("y");
                if (x != nullptr && x->is_number() && y != nullptr && y->is_number()) {
                    node.has_position = true;
                    node.x = static_cast<float>(x->as_number());
                    node.y = static_cast<float>(y->as_number());
                }
            }
        }
        if (const json::Value* collapsed = entry.find("collapsed")) {
            node.collapsed = collapsed->as_bool(false);
        }

        out.nodes.push_back(std::move(node));
    }

    if (const json::Value* connections = root.find("connections")) {
        if (!connections->is_array()) {
            diagnostics.push_back(error("connections_not_an_array",
                                        "\"connections\" must be an array."));
            ok = false;
        } else {
            for (std::size_t i = 0; i < connections->array().size(); ++i) {
                const json::Value& entry = connections->array()[i];
                if (!entry.is_object()) {
                    diagnostics.push_back(error("connection_not_an_object",
                                                "Connection " + std::to_string(i) + " is not an object."));
                    ok = false;
                    continue;
                }
                ConnectionDescription connection;
                if (!read_endpoint(entry, "from", i, connection.from_node, connection.from_port, diagnostics) ||
                    !read_endpoint(entry, "to", i, connection.to_node, connection.to_port, diagnostics)) {
                    ok = false;
                    continue;
                }
                out.connections.push_back(std::move(connection));
            }
        }
    }

    if (const json::Value* controls = root.find("controls")) {
        if (controls->is_array()) {
            for (const json::Value& entry : controls->array()) {
                if (!entry.is_object()) {
                    continue;
                }
                ControlDescription control;
                if (const json::Value* id = entry.find("id")) {
                    if (id->is_string()) control.id = id->as_string();
                }
                if (const json::Value* label = entry.find("label")) {
                    if (label->is_string()) control.label = label->as_string();
                }
                if (const json::Value* kind = entry.find("kind")) {
                    if (kind->is_string()) control.kind = kind->as_string();
                }
                read_control_target(entry, control.target);
                const json::Value* min_value = entry.find("min");
                const json::Value* max_value = entry.find("max");
                if (min_value != nullptr && min_value->is_number() &&
                    max_value != nullptr && max_value->is_number()) {
                    control.has_range = true;
                    control.min_value = min_value->as_number();
                    control.max_value = max_value->as_number();
                }
                if (const json::Value* default_value = entry.find("default")) {
                    if (default_value->is_number()) {
                        control.has_default = true;
                        control.default_value = default_value->as_number();
                    }
                }
                if (const json::Value* scaling = entry.find("scaling")) {
                    if (scaling->is_string()) control.scaling = scaling->as_string();
                }
                if (const json::Value* binding = entry.find("binding")) {
                    if (binding->is_object()) {
                        if (const json::Value* cc = binding->find("midi_cc")) {
                            control.midi_cc = static_cast<int>(cc->as_number(-1));
                        }
                        if (const json::Value* channel = binding->find("midi_channel")) {
                            control.midi_channel = static_cast<int>(channel->as_number(-1));
                        }
                        if (const json::Value* encoder = binding->find("encoder")) {
                            control.encoder = static_cast<int>(encoder->as_number(-1));
                        }
                    }
                }
                out.controls.push_back(std::move(control));
            }
        }
    }

    if (const json::Value* automation = root.find("automation")) {
        if (automation->is_array()) {
            for (const json::Value& entry : automation->array()) {
                if (!entry.is_object()) {
                    continue;
                }
                AutomationLane lane;
                if (const json::Value* id = entry.find("id")) {
                    if (id->is_string()) lane.id = id->as_string();
                }
                read_control_target(entry, lane.target);
                if (const json::Value* loop = entry.find("loop")) {
                    lane.loop = loop->as_bool(false);
                }
                if (const json::Value* length = entry.find("length_seconds")) {
                    lane.length_seconds = length->as_number(0.0);
                }
                if (const json::Value* interpolation = entry.find("interpolation")) {
                    if (interpolation->is_string()) lane.interpolation = interpolation->as_string();
                }
                if (const json::Value* points = entry.find("points")) {
                    if (points->is_array()) {
                        for (const json::Value& point : points->array()) {
                            const json::Value* time = point.find("time");
                            const json::Value* value = point.find("value");
                            if (time != nullptr && time->is_number() &&
                                value != nullptr && value->is_number()) {
                                lane.points.push_back(
                                    AutomationPoint{time->as_number(), value->as_number()});
                            }
                        }
                    }
                }
                out.automation.push_back(std::move(lane));
            }
        }
    }

    return ok;
}

bool load_patch(const std::string& path,
                GraphDescription& out,
                std::vector<Diagnostic>& diagnostics) {
    std::ifstream file(path, std::ios::binary);
    if (!file) {
        diagnostics.push_back(error("file_not_readable", "Could not open '" + path + "'."));
        return false;
    }
    std::ostringstream contents;
    contents << file.rdbuf();
    return parse_patch(contents.str(), out, diagnostics);
}

std::string write_patch(const GraphDescription& description, bool pretty) {
    json::Value root = json::Value::make_object();
    root.set("schema_version", json::Value(description.schema_version));

    if (!description.metadata.empty() || !description.tags.empty()) {
        json::Value metadata = json::Value::make_object();
        for (const MetadataEntry& entry : description.metadata) {
            metadata.set(entry.key, json::Value(entry.value));
        }
        if (!description.tags.empty()) {
            json::Value tags = json::Value::make_array();
            for (const std::string& tag : description.tags) {
                tags.push_back(json::Value(tag));
            }
            metadata.set("tags", std::move(tags));
        }
        root.set("metadata", std::move(metadata));
    }

    json::Value nodes = json::Value::make_array();
    for (const NodeDescription& node : description.nodes) {
        json::Value entry = json::Value::make_object();
        entry.set("id", json::Value(node.id));
        entry.set("type", json::Value(node.type));
        if (!node.name.empty()) {
            entry.set("name", json::Value(node.name));
        }
        if (!node.parameters.empty()) {
            json::Value parameters = json::Value::make_object();
            for (const ParameterValue& parameter : node.parameters) {
                parameters.set(parameter.name, json::Value(parameter.value));
            }
            entry.set("parameters", std::move(parameters));
        }
        if (node.has_position) {
            json::Value position = json::Value::make_object();
            position.set("x", json::Value(static_cast<double>(node.x)));
            position.set("y", json::Value(static_cast<double>(node.y)));
            entry.set("position", std::move(position));
        }
        if (node.collapsed) {
            entry.set("collapsed", json::Value(true));
        }
        nodes.push_back(std::move(entry));
    }
    root.set("nodes", std::move(nodes));

    json::Value connections = json::Value::make_array();
    for (const ConnectionDescription& connection : description.connections) {
        json::Value from = json::Value::make_object();
        from.set("node", json::Value(connection.from_node));
        from.set("port", json::Value(connection.from_port));
        json::Value to = json::Value::make_object();
        to.set("node", json::Value(connection.to_node));
        to.set("port", json::Value(connection.to_port));

        json::Value entry = json::Value::make_object();
        entry.set("from", std::move(from));
        entry.set("to", std::move(to));
        connections.push_back(std::move(entry));
    }
    root.set("connections", std::move(connections));

    if (!description.controls.empty()) {
        json::Value controls = json::Value::make_array();
        for (const ControlDescription& control : description.controls) {
            json::Value entry = json::Value::make_object();
            entry.set("id", json::Value(control.id));
            if (!control.label.empty()) {
                entry.set("label", json::Value(control.label));
            }
            if (!control.kind.empty()) {
                entry.set("kind", json::Value(control.kind));
            }
            entry.set("target", write_control_target(control.target));
            if (control.has_range) {
                entry.set("min", json::Value(control.min_value));
                entry.set("max", json::Value(control.max_value));
            }
            if (control.has_default) {
                entry.set("default", json::Value(control.default_value));
            }
            if (!control.scaling.empty()) {
                entry.set("scaling", json::Value(control.scaling));
            }
            if (control.midi_cc >= 0 || control.midi_channel >= 0 || control.encoder >= 0) {
                json::Value binding = json::Value::make_object();
                if (control.midi_cc >= 0) binding.set("midi_cc", json::Value(control.midi_cc));
                if (control.midi_channel >= 0) binding.set("midi_channel", json::Value(control.midi_channel));
                if (control.encoder >= 0) binding.set("encoder", json::Value(control.encoder));
                entry.set("binding", std::move(binding));
            }
            controls.push_back(std::move(entry));
        }
        root.set("controls", std::move(controls));
    }

    if (!description.automation.empty()) {
        json::Value lanes = json::Value::make_array();
        for (const AutomationLane& lane : description.automation) {
            json::Value entry = json::Value::make_object();
            if (!lane.id.empty()) {
                entry.set("id", json::Value(lane.id));
            }
            entry.set("target", write_control_target(lane.target));
            if (lane.loop) {
                entry.set("loop", json::Value(true));
            }
            if (lane.length_seconds > 0.0) {
                entry.set("length_seconds", json::Value(lane.length_seconds));
            }
            if (!lane.interpolation.empty()) {
                entry.set("interpolation", json::Value(lane.interpolation));
            }
            json::Value points = json::Value::make_array();
            for (const AutomationPoint& point : lane.points) {
                json::Value item = json::Value::make_object();
                item.set("time", json::Value(point.time));
                item.set("value", json::Value(point.value));
                points.push_back(std::move(item));
            }
            entry.set("points", std::move(points));
            lanes.push_back(std::move(entry));
        }
        root.set("automation", std::move(lanes));
    }

    return json::serialize(root, pretty);
}

bool save_patch(const std::string& path,
                const GraphDescription& description,
                std::string& error_message) {
    std::ofstream file(path, std::ios::binary);
    if (!file) {
        error_message = "Could not write to '" + path + "'.";
        return false;
    }
    file << write_patch(description, true);
    if (!file) {
        error_message = "Failed while writing '" + path + "'.";
        return false;
    }
    return true;
}

}  // namespace soundgraph
