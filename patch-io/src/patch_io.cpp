#include "soundgraph/patch_io.h"

#if !defined(SOUNDGRAPH_NO_FILE_IO)
#include <fstream>
#include <sstream>
#endif

#include <cstring>

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

// One node entry, shared between the top-level nodes array and module definitions —
// a definition's nodes are ordinary nodes, and two readers would drift.
bool read_node(const json::Value& entry,
               std::size_t index,
               NodeDescription& node,
               std::vector<Diagnostic>& diagnostics) {
    if (!entry.is_object()) {
        diagnostics.push_back(error("node_not_an_object",
                                    "Node " + std::to_string(index) + " is not an object."));
        return false;
    }
    const json::Value* id = entry.find("id");
    const json::Value* type = entry.find("type");
    if (id == nullptr || !id->is_string() || id->as_string().empty()) {
        diagnostics.push_back(error(
            "node_missing_id",
            "Node " + std::to_string(index) + " has no id.",
            "Ids are how connections find nodes, so every node needs one."));
        return false;
    }
    if (type == nullptr || !type->is_string()) {
        diagnostics.push_back(error("node_missing_type",
                                    "Node '" + id->as_string() + "' has no type."));
        return false;
    }
    node.id = id->as_string();
    node.type = type->as_string();

    if (node.type == "module") {
        const json::Value* module = entry.find("module");
        if (module == nullptr || !module->is_string() || module->as_string().empty()) {
            diagnostics.push_back(error(
                "instance_missing_module",
                "Node '" + node.id + "' has type \"module\" but names no module.",
                "An instance needs \"module\": \"<definition name>\"."));
            return false;
        }
        node.module = module->as_string();
    }

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
                node.parameters.push_back(
                    ParameterValue{parameter.first, parameter.second.as_number()});
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
    return true;
}

bool read_connection(const json::Value& entry,
                     std::size_t index,
                     ConnectionDescription& connection,
                     std::vector<Diagnostic>& diagnostics) {
    if (!entry.is_object()) {
        diagnostics.push_back(error("connection_not_an_object",
                                    "Connection " + std::to_string(index) + " is not an object."));
        return false;
    }
    if (!read_endpoint(entry, "from", index, connection.from_node, connection.from_port,
                       diagnostics) ||
        !read_endpoint(entry, "to", index, connection.to_node, connection.to_port,
                       diagnostics)) {
        return false;
    }
    if (const json::Value* waypoint = entry.find("waypoint")) {
        const json::Value* x = waypoint->find("x");
        const json::Value* y = waypoint->find("y");
        if (x != nullptr && x->is_number() && y != nullptr && y->is_number()) {
            connection.has_waypoint = true;
            connection.waypoint_x = static_cast<float>(x->as_number());
            connection.waypoint_y = static_cast<float>(y->as_number());
        }
    }
    return true;
}

// The declared surface of a module: {"name": ..., "node": ..., "port"/"parameter": ...}.
bool read_module_binding(const json::Value& entry,
                         const std::string& module_name,
                         const char* kind,
                         const char* inner_key,
                         std::string& name,
                         std::string& node,
                         std::string& inner,
                         std::vector<Diagnostic>& diagnostics) {
    const json::Value* name_value = entry.find("name");
    const json::Value* node_value = entry.find("node");
    const json::Value* inner_value = entry.find(inner_key);
    if (name_value == nullptr || !name_value->is_string() || name_value->as_string().empty() ||
        node_value == nullptr || !node_value->is_string() ||
        inner_value == nullptr || !inner_value->is_string()) {
        diagnostics.push_back(error(
            "module_malformed_binding",
            "Module '" + module_name + "' has a malformed " + kind + " declaration.",
            std::string("Each needs \"name\", \"node\" and \"") + inner_key + "\"."));
        return false;
    }
    name = name_value->as_string();
    node = node_value->as_string();
    inner = inner_value->as_string();
    return true;
}

// The expanded document may not outgrow what the smallest target can hold. This is a
// load-time refusal, not a steady-state concern: expansion allocates during load,
// which is where allocation already lives.
constexpr std::size_t kMaxExpandedNodes = 2048;

// instance id + "." + inner id, the separator the editor's module import established.
std::string expanded_id(const std::string& instance, const std::string& inner) {
    return instance + "." + inner;
}

// Turns instances into plain nodes, in place: description.nodes/connections/controls/
// automation become the flattened view the engine builds from, and the document as
// authored moves into the authored_* vectors for write_patch. Returns false (with
// diagnostics) on any structural violation; the rules are docs/modules-design.md's,
// one check each.
bool expand_modules(GraphDescription& description, std::vector<Diagnostic>& diagnostics) {
    bool any_instance = false;
    for (const NodeDescription& node : description.nodes) {
        if (node.type == "module") {
            any_instance = true;
        }
    }
    if (description.modules.empty() && !any_instance) {
        return true;  // a version-1 document, untouched
    }

    if (description.schema_version < kSchemaVersionModules) {
        diagnostics.push_back(error(
            "modules_require_v2",
            "This patch uses modules but declares schema_version " +
                std::to_string(description.schema_version) + ".",
            "Documents that use modules must declare \"schema_version\": 2 so that "
            "runtimes which predate modules refuse them loudly instead of misreading."));
        return false;
    }

    // Definitions are sound on their own terms before any instance is considered.
    for (const ModuleDescription& definition : description.modules) {
        for (const NodeDescription& inner : definition.nodes) {
            if (inner.type == "module") {
                diagnostics.push_back(error(
                    "module_nesting",
                    "Module '" + definition.name + "' instantiates module '" +
                        inner.module + "'; modules may not contain modules.",
                    "Nesting is deliberately out of scope — see docs/modules-design.md."));
                return false;
            }
        }
        for (std::size_t i = 0; i < definition.nodes.size(); ++i) {
            for (std::size_t j = i + 1; j < definition.nodes.size(); ++j) {
                if (definition.nodes[i].id == definition.nodes[j].id) {
                    diagnostics.push_back(error(
                        "module_duplicate_node",
                        "Module '" + definition.name + "' declares node '" +
                            definition.nodes[i].id + "' twice."));
                    return false;
                }
            }
        }
        auto inner_exists = [&definition](const std::string& id) {
            for (const NodeDescription& inner : definition.nodes) {
                if (inner.id == id) {
                    return true;
                }
            }
            return false;
        };
        for (const ModulePortDescription& port : definition.inputs) {
            if (!inner_exists(port.node)) {
                diagnostics.push_back(error(
                    "module_binding_unknown_node",
                    "Module '" + definition.name + "' input '" + port.name +
                        "' lands on node '" + port.node + "', which the module does not contain."));
                return false;
            }
        }
        for (const ModulePortDescription& port : definition.outputs) {
            if (!inner_exists(port.node)) {
                diagnostics.push_back(error(
                    "module_binding_unknown_node",
                    "Module '" + definition.name + "' output '" + port.name +
                        "' lands on node '" + port.node + "', which the module does not contain."));
                return false;
            }
        }
        for (const ModuleParameterDescription& parameter : definition.parameters) {
            if (!inner_exists(parameter.node)) {
                diagnostics.push_back(error(
                    "module_binding_unknown_node",
                    "Module '" + definition.name + "' parameter '" + parameter.name +
                        "' reaches node '" + parameter.node + "', which the module does not contain."));
                return false;
            }
        }
        auto unique_names = [&diagnostics, &definition](const auto& list, const char* kind) {
            for (std::size_t i = 0; i < list.size(); ++i) {
                for (std::size_t j = i + 1; j < list.size(); ++j) {
                    if (list[i].name == list[j].name) {
                        diagnostics.push_back(error(
                            "module_duplicate_name",
                            "Module '" + definition.name + "' declares " + kind + " '" +
                                list[i].name + "' twice."));
                        return false;
                    }
                }
            }
            return true;
        };
        if (!unique_names(definition.inputs, "input") ||
            !unique_names(definition.outputs, "output") ||
            !unique_names(definition.parameters, "parameter")) {
            return false;
        }
    }

    // The authored document is what write_patch will reproduce.
    description.authored_nodes = description.nodes;
    description.authored_connections = description.connections;
    description.authored_controls = description.controls;
    description.authored_automation = description.automation;
    description.authored_schema_version = description.schema_version;

    // ---- nodes -----------------------------------------------------------------------
    std::vector<NodeDescription> flat_nodes;
    for (const NodeDescription& node : description.nodes) {
        if (node.type != "module") {
            flat_nodes.push_back(node);
            continue;
        }
        const ModuleDescription* definition = description.find_module(node.module);
        if (definition == nullptr) {
            diagnostics.push_back(error(
                "unknown_module",
                "Node '" + node.id + "' instantiates module '" + node.module +
                    "', which this patch does not define.",
                "Definitions are inline: add it to the \"modules\" section."));
            return false;
        }
        for (const ParameterValue& value : node.parameters) {
            if (definition->find_parameter(value.name) == nullptr) {
                diagnostics.push_back(error(
                    "parameter_not_exported",
                    "Instance '" + node.id + "' sets parameter '" + value.name +
                        "', which module '" + definition->name + "' does not export.",
                    "The declared surface is the only surface."));
                return false;
            }
        }
        for (const NodeDescription& inner : definition->nodes) {
            NodeDescription expanded = inner;
            expanded.id = expanded_id(node.id, inner.id);
            expanded.has_position = false;
            for (const ParameterValue& value : node.parameters) {
                const ModuleParameterDescription* exported =
                    definition->find_parameter(value.name);
                if (exported->node == inner.id) {
                    bool replaced = false;
                    for (ParameterValue& existing : expanded.parameters) {
                        if (existing.name == exported->parameter) {
                            existing.value = value.value;
                            replaced = true;
                        }
                    }
                    if (!replaced) {
                        expanded.parameters.push_back(
                            ParameterValue{exported->parameter, value.value});
                    }
                }
            }
            flat_nodes.push_back(std::move(expanded));
        }
    }
    if (flat_nodes.size() > kMaxExpandedNodes) {
        diagnostics.push_back(error(
            "expansion_too_large",
            "Expanding this patch's modules produces " + std::to_string(flat_nodes.size()) +
                " nodes; the limit is " + std::to_string(kMaxExpandedNodes) + ".",
            "The limit exists so a small file cannot exhaust a small machine."));
        return false;
    }
    for (std::size_t i = 0; i < flat_nodes.size(); ++i) {
        for (std::size_t j = i + 1; j < flat_nodes.size(); ++j) {
            if (flat_nodes[i].id == flat_nodes[j].id) {
                diagnostics.push_back(error(
                    "module_id_collision",
                    "Expansion produces two nodes named '" + flat_nodes[i].id + "'.",
                    "An instance's inner nodes take the name <instance>.<node>; a "
                    "top-level node with that literal name collides with them."));
                return false;
            }
        }
    }

    // ---- connections ------------------------------------------------------------------
    auto resolve = [&description, &diagnostics](
                       const std::string& node_id, const std::string& port,
                       bool is_from, std::string& out_node, std::string& out_port) {
        const NodeDescription* node = description.find_node(node_id);
        if (node == nullptr || node->type != "module") {
            out_node = node_id;
            out_port = port;
            return true;
        }
        const ModuleDescription* definition = description.find_module(node->module);
        const ModulePortDescription* declared =
            is_from ? definition->find_output(port) : definition->find_input(port);
        if (declared == nullptr) {
            diagnostics.push_back(error(
                "undeclared_module_port",
                "Connection uses port '" + port + "' on instance '" + node_id +
                    "', which module '" + definition->name + "' does not declare as " +
                    (is_from ? "an output" : "an input") + ".",
                "The declared surface is the only surface."));
            return false;
        }
        out_node = expanded_id(node_id, declared->node);
        out_port = declared->port;
        return true;
    };

    std::vector<ConnectionDescription> flat_connections;
    for (const NodeDescription& node : description.nodes) {
        if (node.type != "module") {
            continue;
        }
        const ModuleDescription* definition = description.find_module(node.module);
        for (const ConnectionDescription& inner : definition->connections) {
            ConnectionDescription expanded = inner;
            expanded.from_node = expanded_id(node.id, inner.from_node);
            expanded.to_node = expanded_id(node.id, inner.to_node);
            expanded.has_waypoint = false;
            flat_connections.push_back(std::move(expanded));
        }
    }
    for (const ConnectionDescription& connection : description.connections) {
        ConnectionDescription expanded = connection;
        if (!resolve(connection.from_node, connection.from_port, true,
                     expanded.from_node, expanded.from_port) ||
            !resolve(connection.to_node, connection.to_port, false,
                     expanded.to_node, expanded.to_port)) {
            return false;
        }
        flat_connections.push_back(std::move(expanded));
    }

    // ---- controls and automation reach through the facade ------------------------------
    auto remap_target = [&description, &diagnostics](ControlTarget& target) {
        const NodeDescription* node = description.find_node(target.node);
        if (node == nullptr || node->type != "module") {
            return true;
        }
        const ModuleDescription* definition = description.find_module(node->module);
        const ModuleParameterDescription* exported =
            definition->find_parameter(target.parameter);
        if (exported == nullptr) {
            diagnostics.push_back(error(
                "parameter_not_exported",
                "A control or automation lane targets '" + target.parameter +
                    "' on instance '" + target.node + "', which module '" +
                    definition->name + "' does not export."));
            return false;
        }
        target.node = expanded_id(target.node, exported->node);
        target.parameter = exported->parameter;
        return true;
    };
    std::vector<ControlDescription> flat_controls = description.controls;
    for (ControlDescription& control : flat_controls) {
        if (!remap_target(control.target)) {
            return false;
        }
    }
    std::vector<AutomationLane> flat_automation = description.automation;
    for (AutomationLane& lane : flat_automation) {
        if (!remap_target(lane.target)) {
            return false;
        }
    }

    description.nodes = std::move(flat_nodes);
    description.connections = std::move(flat_connections);
    description.controls = std::move(flat_controls);
    description.automation = std::move(flat_automation);
    // The flattened view is a version-1 graph, which is the whole trick: the engine,
    // the golden manifest and every target build from exactly the document model they
    // always did.
    description.schema_version = kSchemaVersion;
    return true;
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

    // Presentation only. An unreadable hint is dropped rather than reported: a patch whose
    // rack order is malformed still makes exactly the right sound, and refusing to open it
    // over a picture would be the wrong trade.
    if (const json::Value* arrangement = root.find("arrangement")) {
        if (arrangement->is_object()) {
            if (const json::Value* order = arrangement->find("rack_order")) {
                if (order->is_array()) {
                    for (const json::Value& id : order->array()) {
                        if (id.is_string()) {
                            out.arrangement.rack_order.push_back(id.as_string());
                        }
                    }
                }
            }
        }
    }

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
        NodeDescription node;
        if (!read_node(nodes->array()[i], i, node, diagnostics)) {
            ok = false;
            continue;
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
                ConnectionDescription connection;
                if (!read_connection(connections->array()[i], i, connection, diagnostics)) {
                    ok = false;
                    continue;
                }
                out.connections.push_back(std::move(connection));
            }
        }
    }

    // Module definitions: the same node and connection readers as the document itself,
    // because a definition's contents are ordinary nodes and two readers would drift.
    if (const json::Value* modules = root.find("modules")) {
        if (!modules->is_object()) {
            diagnostics.push_back(error("modules_not_an_object",
                                        "\"modules\" must be an object of definitions."));
            ok = false;
        } else {
            for (const auto& entry : modules->object()) {
                ModuleDescription definition;
                definition.name = entry.first;
                const json::Value& body = entry.second;
                if (!body.is_object()) {
                    diagnostics.push_back(error(
                        "module_not_an_object",
                        "Module '" + definition.name + "' is not an object."));
                    ok = false;
                    continue;
                }
                if (const json::Value* text_value = body.find("description")) {
                    if (text_value->is_string()) {
                        definition.description = text_value->as_string();
                    }
                }
                if (const json::Value* inner_nodes = body.find("nodes")) {
                    if (inner_nodes->is_array()) {
                        for (std::size_t i = 0; i < inner_nodes->array().size(); ++i) {
                            NodeDescription node;
                            if (!read_node(inner_nodes->array()[i], i, node, diagnostics)) {
                                ok = false;
                                continue;
                            }
                            definition.nodes.push_back(std::move(node));
                        }
                    }
                }
                if (const json::Value* inner = body.find("connections")) {
                    if (inner->is_array()) {
                        for (std::size_t i = 0; i < inner->array().size(); ++i) {
                            ConnectionDescription connection;
                            if (!read_connection(inner->array()[i], i, connection, diagnostics)) {
                                ok = false;
                                continue;
                            }
                            definition.connections.push_back(std::move(connection));
                        }
                    }
                }
                auto read_ports = [&](const char* key, std::vector<ModulePortDescription>& list,
                                      const char* kind) {
                    const json::Value* declared = body.find(key);
                    if (declared == nullptr || !declared->is_array()) {
                        return;
                    }
                    for (const json::Value& port_entry : declared->array()) {
                        ModulePortDescription port;
                        if (!read_module_binding(port_entry, definition.name, kind, "port",
                                                 port.name, port.node, port.port, diagnostics)) {
                            ok = false;
                            continue;
                        }
                        list.push_back(std::move(port));
                    }
                };
                read_ports("inputs", definition.inputs, "input");
                read_ports("outputs", definition.outputs, "output");
                if (const json::Value* declared = body.find("parameters")) {
                    if (declared->is_array()) {
                        for (const json::Value& parameter_entry : declared->array()) {
                            ModuleParameterDescription parameter;
                            if (!read_module_binding(parameter_entry, definition.name,
                                                     "parameter", "parameter", parameter.name,
                                                     parameter.node, parameter.parameter,
                                                     diagnostics)) {
                                ok = false;
                                continue;
                            }
                            definition.parameters.push_back(std::move(parameter));
                        }
                    }
                }
                out.modules.push_back(std::move(definition));
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

    // Last, once controls and automation exist to remap: instances become plain
    // nodes, the authored document moves aside for write_patch, and the engine gets
    // the version-1 view it always got.
    if (ok && !expand_modules(out, diagnostics)) {
        ok = false;
    }

    return ok;
}

#if !defined(SOUNDGRAPH_NO_FILE_IO)

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

#endif  // SOUNDGRAPH_NO_FILE_IO

namespace {

json::Value write_node_entry(const NodeDescription& node) {
    json::Value entry = json::Value::make_object();
    entry.set("id", json::Value(node.id));
    entry.set("type", json::Value(node.type));
    if (!node.module.empty()) {
        entry.set("module", json::Value(node.module));
    }
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
    return entry;
}

json::Value write_connection_entry(const ConnectionDescription& connection) {
    json::Value from = json::Value::make_object();
    from.set("node", json::Value(connection.from_node));
    from.set("port", json::Value(connection.from_port));
    json::Value to = json::Value::make_object();
    to.set("node", json::Value(connection.to_node));
    to.set("port", json::Value(connection.to_port));
    json::Value entry = json::Value::make_object();
    entry.set("from", std::move(from));
    entry.set("to", std::move(to));
    if (connection.has_waypoint) {
        json::Value waypoint = json::Value::make_object();
        waypoint.set("x", json::Value(static_cast<double>(connection.waypoint_x)));
        waypoint.set("y", json::Value(static_cast<double>(connection.waypoint_y)));
        entry.set("waypoint", std::move(waypoint));
    }
    return entry;
}

json::Value write_module_binding(const std::string& name, const std::string& node,
                                 const char* inner_key, const std::string& inner) {
    json::Value entry = json::Value::make_object();
    entry.set("name", json::Value(name));
    entry.set("node", json::Value(node));
    entry.set(inner_key, json::Value(inner));
    return entry;
}

}  // namespace

std::string write_patch(const GraphDescription& description, bool pretty) {
    // Flattening is for the engine, never for the file: a modular document writes its
    // authored form back, definitions and instances intact.
    const bool modular = description.has_modules();
    const std::vector<NodeDescription>& nodes_out =
        modular ? description.authored_nodes : description.nodes;
    const std::vector<ConnectionDescription>& connections_out =
        modular ? description.authored_connections : description.connections;
    const std::vector<ControlDescription>& controls_out =
        modular ? description.authored_controls : description.controls;
    const std::vector<AutomationLane>& automation_out =
        modular ? description.authored_automation : description.automation;

    json::Value root = json::Value::make_object();
    root.set("schema_version", json::Value(modular
        ? (description.authored_schema_version > kSchemaVersionModules
               ? description.authored_schema_version
               : kSchemaVersionModules)
        : description.schema_version));

    if (!description.arrangement.empty()) {
        json::Value arrangement = json::Value::make_object();
        json::Value order = json::Value::make_array();
        for (const std::string& id : description.arrangement.rack_order) {
            order.push_back(json::Value(id));
        }
        arrangement.set("rack_order", std::move(order));
        root.set("arrangement", std::move(arrangement));
    }

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

    if (modular) {
        json::Value modules = json::Value::make_object();
        for (const ModuleDescription& definition : description.modules) {
            json::Value body = json::Value::make_object();
            if (!definition.description.empty()) {
                body.set("description", json::Value(definition.description));
            }
            json::Value inner_nodes = json::Value::make_array();
            for (const NodeDescription& node : definition.nodes) {
                inner_nodes.push_back(write_node_entry(node));
            }
            body.set("nodes", std::move(inner_nodes));
            json::Value inner_connections = json::Value::make_array();
            for (const ConnectionDescription& connection : definition.connections) {
                inner_connections.push_back(write_connection_entry(connection));
            }
            body.set("connections", std::move(inner_connections));
            if (!definition.inputs.empty()) {
                json::Value inputs = json::Value::make_array();
                for (const ModulePortDescription& port : definition.inputs) {
                    inputs.push_back(write_module_binding(port.name, port.node, "port", port.port));
                }
                body.set("inputs", std::move(inputs));
            }
            if (!definition.outputs.empty()) {
                json::Value outputs = json::Value::make_array();
                for (const ModulePortDescription& port : definition.outputs) {
                    outputs.push_back(write_module_binding(port.name, port.node, "port", port.port));
                }
                body.set("outputs", std::move(outputs));
            }
            if (!definition.parameters.empty()) {
                json::Value parameters = json::Value::make_array();
                for (const ModuleParameterDescription& parameter : definition.parameters) {
                    parameters.push_back(write_module_binding(
                        parameter.name, parameter.node, "parameter", parameter.parameter));
                }
                body.set("parameters", std::move(parameters));
            }
            modules.set(definition.name, std::move(body));
        }
        root.set("modules", std::move(modules));
    }

    json::Value nodes = json::Value::make_array();
    for (const NodeDescription& node : nodes_out) {
        nodes.push_back(write_node_entry(node));
    }
    root.set("nodes", std::move(nodes));

    json::Value connections = json::Value::make_array();
    for (const ConnectionDescription& connection : connections_out) {
        connections.push_back(write_connection_entry(connection));
    }
    root.set("connections", std::move(connections));

    if (!controls_out.empty()) {
        json::Value controls = json::Value::make_array();
        for (const ControlDescription& control : controls_out) {
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

    if (!automation_out.empty()) {
        json::Value lanes = json::Value::make_array();
        for (const AutomationLane& lane : automation_out) {
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

std::string write_diagnostics(const std::vector<Diagnostic>& diagnostics, bool pretty) {
    json::Value root = json::Value::make_array();
    for (const Diagnostic& diagnostic : diagnostics) {
        json::Value entry = json::Value::make_object();
        switch (diagnostic.severity) {
            case Severity::Error:   entry.set("severity", json::Value("error")); break;
            case Severity::Warning: entry.set("severity", json::Value("warning")); break;
            case Severity::Info:    entry.set("severity", json::Value("info")); break;
        }
        entry.set("code", json::Value(diagnostic.code));
        entry.set("message", json::Value(diagnostic.message));
        if (!diagnostic.suggestion.empty()) {
            entry.set("suggestion", json::Value(diagnostic.suggestion));
        }
        if (!diagnostic.node_ids.empty()) {
            json::Value nodes = json::Value::make_array();
            for (const std::string& id : diagnostic.node_ids) {
                nodes.push_back(json::Value(id));
            }
            entry.set("nodes", std::move(nodes));
        }
        if (!diagnostic.connection_indices.empty()) {
            json::Value connections = json::Value::make_array();
            for (int index : diagnostic.connection_indices) {
                connections.push_back(json::Value(index));
            }
            entry.set("connections", std::move(connections));
        }
        root.push_back(std::move(entry));
    }
    return json::serialize(root, pretty);
}

namespace {

const char* scaling_name(Scaling scaling) {
    switch (scaling) {
        case Scaling::Linear:      return "linear";
        case Scaling::Exponential: return "exponential";
        case Scaling::Logarithmic: return "logarithmic";
    }
    return "linear";
}

const char* role_name(NodeRole role) {
    switch (role) {
        case NodeRole::Processor:       return "processor";
        case NodeRole::HostAudioSource: return "host_audio_source";
        case NodeRole::HostAudioSink:   return "host_audio_sink";
    }
    return "processor";
}

json::Value write_ports(Slice<PortDescriptor> ports, bool is_input) {
    json::Value array = json::Value::make_array();
    for (int i = 0; i < ports.size(); ++i) {
        const PortDescriptor& port = ports[i];
        json::Value entry = json::Value::make_object();
        entry.set("name", json::Value(port.name));
        entry.set("type", json::Value(to_string(port.type)));
        if (std::strlen(port.unit) > 0) {
            entry.set("unit", json::Value(port.unit));
        }
        if (is_input) {
            entry.set("required", json::Value(port.required));
            entry.set("summing", json::Value(port.summing));
        }
        entry.set("doc", json::Value(port.doc));
        array.push_back(std::move(entry));
    }
    return array;
}

}  // namespace

std::string write_registry(const NodeRegistry& registry, bool pretty) {
    json::Value types = json::Value::make_array();

    for (const NodeTypeDescriptor* type : registry.types()) {
        json::Value entry = json::Value::make_object();
        entry.set("name", json::Value(type->name));
        entry.set("display_name", json::Value(type->display_name));
        entry.set("category", json::Value(type->category));
        entry.set("summary", json::Value(type->summary));

        json::Value terms = json::Value::make_array();
        std::string current;
        for (const char* cursor = type->search_terms; *cursor != '\0'; ++cursor) {
            if (*cursor == '|') {
                if (!current.empty()) {
                    terms.push_back(json::Value(current));
                }
                current.clear();
            } else {
                current.push_back(*cursor);
            }
        }
        if (!current.empty()) {
            terms.push_back(json::Value(current));
        }
        entry.set("search_terms", std::move(terms));

        entry.set("inputs", write_ports(type->inputs, true));
        entry.set("outputs", write_ports(type->outputs, false));

        json::Value parameters = json::Value::make_array();
        for (int i = 0; i < type->parameters.size(); ++i) {
            const ParameterDescriptor& parameter = type->parameters[i];
            json::Value item = json::Value::make_object();
            item.set("name", json::Value(parameter.name));
            if (std::strlen(parameter.unit) > 0) {
                item.set("unit", json::Value(parameter.unit));
            }
            item.set("min", json::Value(static_cast<double>(parameter.min_value)));
            item.set("max", json::Value(static_cast<double>(parameter.max_value)));
            item.set("default", json::Value(static_cast<double>(parameter.default_value)));
            item.set("scaling", json::Value(scaling_name(parameter.scaling)));
            item.set("doc", json::Value(parameter.doc));
            if (parameter.enum_labels != nullptr) {
                json::Value labels = json::Value::make_array();
                for (int e = 0; e < parameter.enum_count; ++e) {
                    labels.push_back(json::Value(parameter.enum_labels[e]));
                }
                item.set("enum", std::move(labels));
            }
            parameters.push_back(std::move(item));
        }
        entry.set("parameters", std::move(parameters));

        entry.set("breaks_feedback", json::Value(type->breaks_feedback));
        entry.set("role", json::Value(role_name(type->role)));
        entry.set("receives_notes", json::Value(type->receives_notes));

        json::Value cost = json::Value::make_object();
        cost.set("cpu", json::Value(static_cast<double>(type->cost.cpu_cost)));
        cost.set("state_bytes", json::Value(type->cost.state_bytes));
        cost.set("heap_bytes", json::Value(type->cost.heap_bytes));
        entry.set("cost", std::move(cost));

        types.push_back(std::move(entry));
    }

    json::Value root = json::Value::make_object();
    root.set("schema_version", json::Value(kSchemaVersion));
    root.set("block_size", json::Value(kBlockSize));
    root.set("types", std::move(types));
    return json::serialize(root, pretty);
}

#if !defined(SOUNDGRAPH_NO_FILE_IO)

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

#endif  // SOUNDGRAPH_NO_FILE_IO

}  // namespace soundgraph
