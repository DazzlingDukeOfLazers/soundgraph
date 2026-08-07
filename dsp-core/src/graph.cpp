#include "soundgraph/graph.h"

#include <algorithm>
#include <cstring>
#include <map>
#include <set>

namespace soundgraph {
namespace {

struct Edge {
    int connection_index = -1;
    int from_node = -1;
    int from_port = -1;
    int to_node = -1;
    int to_port = -1;
};

struct Resolved {
    std::vector<const NodeTypeDescriptor*> types;  // one per node, never null when ok
    std::vector<Edge> edges;                       // only fully-resolved connections
    bool ok = true;
};

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

std::string quote(const std::string& text) {
    return "'" + text + "'";
}

// Resolves node types and connection endpoints, reporting anything that cannot be
// resolved. A connection that fails to resolve is dropped rather than half-applied, so
// later passes only ever see well-formed edges.
Resolved resolve(const GraphDescription& description,
                 const NodeRegistry& registry,
                 std::vector<Diagnostic>& diagnostics) {
    Resolved resolved;
    resolved.types.resize(description.nodes.size(), nullptr);

    std::map<std::string, int> node_index_by_id;

    for (std::size_t i = 0; i < description.nodes.size(); ++i) {
        const NodeDescription& node = description.nodes[i];

        if (node.id.empty()) {
            diagnostics.push_back(error("empty_node_id",
                                        "A node has no id. Every node needs a stable id so that "
                                        "connections and automation can refer to it."));
            resolved.ok = false;
            continue;
        }

        const auto existing = node_index_by_id.find(node.id);
        if (existing != node_index_by_id.end()) {
            Diagnostic diagnostic = error(
                "duplicate_node_id",
                "Two nodes share the id " + quote(node.id) + ".",
                "Give one of them a different id. Ids are identity, not labels — use the name "
                "field for the visible label.");
            diagnostic.node_ids = {node.id};
            diagnostics.push_back(diagnostic);
            resolved.ok = false;
            continue;
        }
        node_index_by_id[node.id] = static_cast<int>(i);

        const NodeTypeDescriptor* type = registry.find(node.type);
        if (type == nullptr) {
            Diagnostic diagnostic = error(
                "unknown_node_type",
                "Node " + quote(node.id) + " has type " + quote(node.type) + ", which this build "
                "does not know about.",
                "Check the spelling, or open the patch in a build that has that node type.");
            diagnostic.node_ids = {node.id};
            diagnostics.push_back(diagnostic);
            resolved.ok = false;
            continue;
        }
        resolved.types[i] = type;

        for (const ParameterValue& parameter : node.parameters) {
            const int index = type->find_parameter(parameter.name.c_str());
            if (index < 0) {
                Diagnostic diagnostic = warning(
                    "unknown_parameter",
                    "Node " + quote(node.id) + " sets parameter " + quote(parameter.name) +
                        ", which " + quote(node.type) + " does not have. It will be ignored.",
                    "Remove it, or check whether the patch was written for a newer node version.");
                diagnostic.node_ids = {node.id};
                diagnostics.push_back(diagnostic);
                continue;
            }
            const ParameterDescriptor& descriptor = type->parameters[index];
            if (parameter.value < descriptor.min_value || parameter.value > descriptor.max_value) {
                Diagnostic diagnostic = warning(
                    "parameter_out_of_range",
                    "Node " + quote(node.id) + " sets " + quote(parameter.name) + " outside its "
                    "range; it will be clamped.",
                    std::string("Valid range is ") + std::to_string(descriptor.min_value) + " to " +
                        std::to_string(descriptor.max_value) + " " + descriptor.unit + ".");
                diagnostic.node_ids = {node.id};
                diagnostics.push_back(diagnostic);
            }
        }
    }

    // Connection endpoints.
    for (std::size_t i = 0; i < description.connections.size(); ++i) {
        const ConnectionDescription& connection = description.connections[i];
        const int index = static_cast<int>(i);

        const auto from_it = node_index_by_id.find(connection.from_node);
        const auto to_it = node_index_by_id.find(connection.to_node);

        if (from_it == node_index_by_id.end() || to_it == node_index_by_id.end()) {
            const std::string missing = from_it == node_index_by_id.end() ? connection.from_node
                                                                         : connection.to_node;
            Diagnostic diagnostic = error(
                "connection_to_missing_node",
                "A connection refers to node " + quote(missing) + ", which is not in this patch.",
                "Delete the connection, or add the node back.");
            diagnostic.connection_indices = {index};
            diagnostics.push_back(diagnostic);
            resolved.ok = false;
            continue;
        }

        const NodeTypeDescriptor* from_type = resolved.types[static_cast<std::size_t>(from_it->second)];
        const NodeTypeDescriptor* to_type = resolved.types[static_cast<std::size_t>(to_it->second)];
        if (from_type == nullptr || to_type == nullptr) {
            // The node type was already reported as unknown; do not pile on.
            resolved.ok = false;
            continue;
        }

        const int from_port = from_type->find_output(connection.from_port.c_str());
        if (from_port < 0) {
            Diagnostic diagnostic = error(
                "unknown_output_port",
                quote(connection.from_node) + " has no output called " + quote(connection.from_port) + ".",
                std::string(from_type->display_name) + " outputs: " + [&] {
                    std::string list;
                    for (int p = 0; p < from_type->outputs.size(); ++p) {
                        if (p > 0) list += ", ";
                        list += from_type->outputs[p].name;
                    }
                    return list.empty() ? std::string("(none)") : list;
                }());
            diagnostic.node_ids = {connection.from_node};
            diagnostic.connection_indices = {index};
            diagnostics.push_back(diagnostic);
            resolved.ok = false;
            continue;
        }

        const int to_port = to_type->find_input(connection.to_port.c_str());
        if (to_port < 0) {
            Diagnostic diagnostic = error(
                "unknown_input_port",
                quote(connection.to_node) + " has no input called " + quote(connection.to_port) + ".",
                std::string(to_type->display_name) + " inputs: " + [&] {
                    std::string list;
                    for (int p = 0; p < to_type->inputs.size(); ++p) {
                        if (p > 0) list += ", ";
                        list += to_type->inputs[p].name;
                    }
                    return list.empty() ? std::string("(none)") : list;
                }());
            diagnostic.node_ids = {connection.to_node};
            diagnostic.connection_indices = {index};
            diagnostics.push_back(diagnostic);
            resolved.ok = false;
            continue;
        }

        const SignalType from_signal = from_type->outputs[from_port].type;
        const SignalType to_signal = to_type->inputs[to_port].type;
        if (!signal_types_compatible(from_signal, to_signal)) {
            Diagnostic diagnostic = error(
                "incompatible_signal_types",
                std::string("Cannot connect a ") + to_string(from_signal) + " output to a " +
                    to_string(to_signal) + " input.",
                "These carry different kinds of information and there is no automatic conversion.");
            diagnostic.node_ids = {connection.from_node, connection.to_node};
            diagnostic.connection_indices = {index};
            diagnostics.push_back(diagnostic);
            resolved.ok = false;
            continue;
        }

        Edge edge;
        edge.connection_index = index;
        edge.from_node = from_it->second;
        edge.from_port = from_port;
        edge.to_node = to_it->second;
        edge.to_port = to_port;
        resolved.edges.push_back(edge);
    }

    return resolved;
}

// Fan-in rules and unconnected required inputs.
void check_input_wiring(const GraphDescription& description,
                        const Resolved& resolved,
                        std::vector<Diagnostic>& diagnostics,
                        bool& ok) {
    std::map<std::pair<int, int>, std::vector<int>> sources;  // (node, input port) -> edges
    for (const Edge& edge : resolved.edges) {
        sources[{edge.to_node, edge.to_port}].push_back(edge.connection_index);
    }

    for (const auto& entry : sources) {
        const int node = entry.first.first;
        const int port = entry.first.second;
        const NodeTypeDescriptor* type = resolved.types[static_cast<std::size_t>(node)];
        if (type == nullptr || entry.second.size() < 2) {
            continue;
        }
        if (!type->inputs[port].summing) {
            Diagnostic diagnostic = error(
                "input_over_connected",
                "Input " + quote(type->inputs[port].name) + " on " +
                    quote(description.nodes[static_cast<std::size_t>(node)].id) +
                    " has " + std::to_string(entry.second.size()) + " connections, but it accepts one.",
                "Insert a Mixer (for audio) or an Add node (for control) and feed both signals "
                "through it.");
            diagnostic.node_ids = {description.nodes[static_cast<std::size_t>(node)].id};
            diagnostic.connection_indices = entry.second;
            diagnostics.push_back(diagnostic);
            ok = false;
        }
    }

    for (std::size_t i = 0; i < description.nodes.size(); ++i) {
        const NodeTypeDescriptor* type = resolved.types[i];
        if (type == nullptr) {
            continue;
        }
        for (int port = 0; port < type->inputs.size(); ++port) {
            if (!type->inputs[port].required) {
                continue;
            }
            if (sources.count({static_cast<int>(i), port}) > 0) {
                continue;
            }
            Diagnostic diagnostic = error(
                "required_input_unconnected",
                quote(description.nodes[i].id) + " needs something connected to its " +
                    quote(type->inputs[port].name) + " input.",
                std::string(type->inputs[port].doc));
            diagnostic.node_ids = {description.nodes[i].id};
            diagnostics.push_back(diagnostic);
            ok = false;
        }
    }
}

void check_surfaces(const GraphDescription& description,
                    const Resolved& resolved,
                    std::vector<Diagnostic>& diagnostics,
                    bool& ok) {
    std::map<std::string, int> index_by_id;
    for (std::size_t i = 0; i < description.nodes.size(); ++i) {
        index_by_id[description.nodes[i].id] = static_cast<int>(i);
    }

    auto check_target = [&](const ControlTarget& target, const std::string& what,
                            const std::string& owner) {
        const auto it = index_by_id.find(target.node);
        if (it == index_by_id.end()) {
            Diagnostic diagnostic = error(
                "surface_target_missing_node",
                what + " " + quote(owner) + " points at node " + quote(target.node) +
                    ", which is not in this patch.");
            diagnostics.push_back(diagnostic);
            ok = false;
            return;
        }
        const NodeTypeDescriptor* type = resolved.types[static_cast<std::size_t>(it->second)];
        if (type == nullptr) {
            return;
        }
        if (type->find_parameter(target.parameter.c_str()) < 0) {
            Diagnostic diagnostic = error(
                "surface_target_missing_parameter",
                what + " " + quote(owner) + " points at parameter " + quote(target.parameter) +
                    " on " + quote(target.node) + ", which does not have it.");
            diagnostic.node_ids = {target.node};
            diagnostics.push_back(diagnostic);
            ok = false;
        }
    };

    for (const ControlDescription& control : description.controls) {
        check_target(control.target, "Control", control.id);
    }
    for (const AutomationLane& lane : description.automation) {
        check_target(lane.target, "Automation lane", lane.id);
        for (std::size_t i = 1; i < lane.points.size(); ++i) {
            if (lane.points[i].time < lane.points[i - 1].time) {
                diagnostics.push_back(warning(
                    "automation_points_unordered",
                    "Automation lane " + quote(lane.id) + " has points that go backwards in time.",
                    "Sort the points by time; playback assumes ascending order."));
                break;
            }
        }
    }
}

// Depth-first search for one cycle among the currently active edges.
// Returns the node indices around the loop, or an empty vector if the graph is acyclic.
std::vector<int> find_cycle(const std::vector<std::vector<int>>& successors) {
    const std::size_t count = successors.size();
    std::vector<int> colour(count, 0);  // 0 unvisited, 1 on stack, 2 done
    std::vector<int> stack;

    for (std::size_t start = 0; start < count; ++start) {
        if (colour[start] != 0) {
            continue;
        }
        stack.push_back(static_cast<int>(start));
        std::vector<std::size_t> cursor(count, 0);
        colour[start] = 1;

        while (!stack.empty()) {
            const int node = stack.back();
            const std::size_t node_index = static_cast<std::size_t>(node);
            if (cursor[node_index] < successors[node_index].size()) {
                const int next = successors[node_index][cursor[node_index]++];
                const std::size_t next_index = static_cast<std::size_t>(next);
                if (colour[next_index] == 1) {
                    // Found a back edge: unwind the stack to recover the loop.
                    std::vector<int> cycle;
                    auto it = std::find(stack.begin(), stack.end(), next);
                    for (; it != stack.end(); ++it) {
                        cycle.push_back(*it);
                    }
                    return cycle;
                }
                if (colour[next_index] == 0) {
                    colour[next_index] = 1;
                    stack.push_back(next);
                }
            } else {
                colour[node_index] = 2;
                stack.pop_back();
            }
        }
    }
    return {};
}

// Orders nodes for execution, cutting feedback edges where a node is allowed to break
// them. `feedback` is filled with one flag per edge in `edges`.
bool schedule(const GraphDescription& description,
              const Resolved& resolved,
              std::vector<int>& order,
              std::vector<bool>& feedback,
              std::vector<Diagnostic>& diagnostics) {
    const std::size_t node_count = description.nodes.size();
    feedback.assign(resolved.edges.size(), false);

    for (;;) {
        std::vector<std::vector<int>> successors(node_count);
        for (std::size_t e = 0; e < resolved.edges.size(); ++e) {
            if (feedback[e]) {
                continue;
            }
            const Edge& edge = resolved.edges[e];
            if (edge.from_node != edge.to_node) {
                successors[static_cast<std::size_t>(edge.from_node)].push_back(edge.to_node);
            } else {
                // A self-connection is a cycle of length one; treat it the same way.
                successors[static_cast<std::size_t>(edge.from_node)].push_back(edge.to_node);
            }
        }

        const std::vector<int> cycle = find_cycle(successors);
        if (cycle.empty()) {
            break;
        }

        // Prefer to cut where the graph says a cut is meaningful: an edge arriving at a
        // node that introduces latency. Anything else would silently invent timing.
        int cut_edge = -1;
        for (std::size_t position = 0; position < cycle.size(); ++position) {
            const int from = cycle[position];
            const int to = cycle[(position + 1) % cycle.size()];
            const NodeTypeDescriptor* to_type = resolved.types[static_cast<std::size_t>(to)];
            if (to_type == nullptr || !to_type->breaks_feedback) {
                continue;
            }
            for (std::size_t e = 0; e < resolved.edges.size(); ++e) {
                if (!feedback[e] && resolved.edges[e].from_node == from &&
                    resolved.edges[e].to_node == to) {
                    cut_edge = static_cast<int>(e);
                    break;
                }
            }
            if (cut_edge >= 0) {
                break;
            }
        }

        if (cut_edge < 0) {
            Diagnostic diagnostic = error(
                "zero_delay_cycle",
                "This loop has no delay in it, so there is no order in which its nodes can run.",
                "Insert a Delay node somewhere in the loop. Feedback only has a defined meaning "
                "when something in the loop holds the signal for a moment.");
            for (int node : cycle) {
                diagnostic.node_ids.push_back(description.nodes[static_cast<std::size_t>(node)].id);
            }
            for (std::size_t position = 0; position < cycle.size(); ++position) {
                const int from = cycle[position];
                const int to = cycle[(position + 1) % cycle.size()];
                for (std::size_t e = 0; e < resolved.edges.size(); ++e) {
                    if (!feedback[e] && resolved.edges[e].from_node == from &&
                        resolved.edges[e].to_node == to) {
                        diagnostic.connection_indices.push_back(resolved.edges[e].connection_index);
                        break;
                    }
                }
            }
            diagnostics.push_back(diagnostic);
            return false;
        }

        feedback[static_cast<std::size_t>(cut_edge)] = true;
    }

    // Kahn's algorithm over the remaining edges.
    std::vector<int> in_degree(node_count, 0);
    std::vector<std::vector<int>> successors(node_count);
    for (std::size_t e = 0; e < resolved.edges.size(); ++e) {
        if (feedback[e]) {
            continue;
        }
        const Edge& edge = resolved.edges[e];
        successors[static_cast<std::size_t>(edge.from_node)].push_back(edge.to_node);
        in_degree[static_cast<std::size_t>(edge.to_node)]++;
    }

    // Seed in declaration order so that the schedule is stable across runs, which keeps
    // golden vectors reproducible.
    std::vector<int> ready;
    for (std::size_t i = 0; i < node_count; ++i) {
        if (in_degree[i] == 0) {
            ready.push_back(static_cast<int>(i));
        }
    }

    order.clear();
    order.reserve(node_count);
    while (!ready.empty()) {
        const int node = ready.front();
        ready.erase(ready.begin());
        order.push_back(node);
        for (int next : successors[static_cast<std::size_t>(node)]) {
            if (--in_degree[static_cast<std::size_t>(next)] == 0) {
                ready.push_back(next);
            }
        }
    }

    if (order.size() != node_count) {
        diagnostics.push_back(error("scheduling_failed",
                                    "The graph could not be ordered for execution."));
        return false;
    }
    return true;
}

}  // namespace

bool has_errors(const std::vector<Diagnostic>& diagnostics) {
    for (const Diagnostic& diagnostic : diagnostics) {
        if (diagnostic.severity == Severity::Error) {
            return true;
        }
    }
    return false;
}

bool validate(const GraphDescription& description,
              const NodeRegistry& registry,
              std::vector<Diagnostic>& diagnostics) {
    bool ok = true;

    if (description.schema_version != kSchemaVersion) {
        diagnostics.push_back(error(
            "unsupported_schema_version",
            "This patch declares schema_version " + std::to_string(description.schema_version) +
                "; this build implements " + std::to_string(kSchemaVersion) + ".",
            "Open it in a matching build rather than guessing at the differences."));
        return false;
    }

    if (description.nodes.empty()) {
        diagnostics.push_back(warning("empty_patch", "This patch has no nodes."));
        return true;
    }

    const Resolved resolved = resolve(description, registry, diagnostics);
    ok = ok && resolved.ok;

    if (resolved.ok) {
        check_input_wiring(description, resolved, diagnostics, ok);
        check_surfaces(description, resolved, diagnostics, ok);

        bool has_sink = false;
        for (const NodeTypeDescriptor* type : resolved.types) {
            if (type != nullptr && type->role == NodeRole::HostAudioSink) {
                has_sink = true;
                break;
            }
        }
        if (!has_sink) {
            diagnostics.push_back(warning(
                "no_output",
                "This patch has no Stereo Output, so nothing will reach the speakers.",
                "Add a Stereo Output node and connect the end of your signal chain to it."));
        }
    }

    if (ok) {
        std::vector<int> order;
        std::vector<bool> feedback;
        ok = schedule(description, resolved, order, feedback, diagnostics);
    }

    return ok && !has_errors(diagnostics);
}

// -------------------------------------------------------------------------------------
// Graph
// -------------------------------------------------------------------------------------

Graph::Graph() = default;
Graph::~Graph() = default;

int Graph::allocate_buffer() {
    const int index = buffer_count_++;
    buffer_pool_.resize(static_cast<std::size_t>(buffer_count_) * kBlockSize, 0.0f);
    return index;
}

float* Graph::buffer(int index) {
    return buffer_pool_.data() + static_cast<std::size_t>(index) * kBlockSize;
}

const float* Graph::buffer(int index) const {
    return buffer_pool_.data() + static_cast<std::size_t>(index) * kBlockSize;
}

bool Graph::build(const GraphDescription& description,
                  const NodeRegistry& registry,
                  const PrepareContext& context,
                  std::vector<Diagnostic>& diagnostics) {
    built_ = false;
    nodes_.clear();
    order_.clear();
    feedback_connections_.clear();
    host_source_nodes_.clear();
    host_sink_nodes_.clear();
    note_receiver_nodes_.clear();
    buffer_pool_.clear();
    buffer_count_ = 0;
    control_queue_.clear();
    cost_ = ResourceCost{};

    if (!validate(description, registry, diagnostics)) {
        return false;
    }

    // Validation already reported everything worth reporting; re-resolving here would
    // duplicate its warnings, so the second pass keeps its diagnostics to itself.
    std::vector<Diagnostic> discarded;
    const Resolved resolved = resolve(description, registry, discarded);
    if (!resolved.ok) {
        return false;
    }

    std::vector<bool> feedback;
    if (!schedule(description, resolved, order_, feedback, discarded)) {
        return false;
    }

    sample_rate_ = context.sample_rate;

    // ---- instantiate ---------------------------------------------------------------
    nodes_.resize(description.nodes.size());
    for (std::size_t i = 0; i < description.nodes.size(); ++i) {
        const NodeDescription& node_description = description.nodes[i];
        const NodeTypeDescriptor* type = resolved.types[i];

        NodeSlot& slot = nodes_[i];
        slot.id = node_description.id;
        slot.type = type;
        slot.node = registry.create(node_description.type);
        if (!slot.node) {
            Diagnostic diagnostic = error("node_creation_failed",
                                          "Could not create node " + quote(node_description.id) + ".");
            diagnostic.node_ids = {node_description.id};
            diagnostics.push_back(diagnostic);
            return false;
        }

        for (const ParameterValue& parameter : node_description.parameters) {
            const int index = type->find_parameter(parameter.name.c_str());
            if (index >= 0) {
                slot.node->set_parameter(index, static_cast<float>(parameter.value));
            }
        }

        PrepareContext node_context = context;
        node_context.max_block_size = kBlockSize;
        slot.node->prepare(node_context);

        slot.inputs.resize(static_cast<std::size_t>(type->inputs.size()));

        cost_.cpu_cost += type->cost.cpu_cost;
        cost_.state_bytes += type->cost.state_bytes;
        cost_.heap_bytes += type->cost.heap_bytes;

        if (type->role == NodeRole::HostAudioSource) {
            host_source_nodes_.push_back(static_cast<int>(i));
        } else if (type->role == NodeRole::HostAudioSink) {
            host_sink_nodes_.push_back(static_cast<int>(i));
        }
        if (type->receives_notes) {
            note_receiver_nodes_.push_back(static_cast<int>(i));
        }
    }

    // ---- allocate output buffers ----------------------------------------------------
    for (std::size_t i = 0; i < nodes_.size(); ++i) {
        NodeSlot& slot = nodes_[i];
        for (int port = 0; port < slot.type->outputs.size(); ++port) {
            slot.output_buffers.push_back(allocate_buffer());
        }
    }

    // ---- resolve inputs -------------------------------------------------------------
    for (std::size_t e = 0; e < resolved.edges.size(); ++e) {
        const Edge& edge = resolved.edges[e];
        NodeSlot& destination = nodes_[static_cast<std::size_t>(edge.to_node)];
        InputBinding& binding = destination.inputs[static_cast<std::size_t>(edge.to_port)];
        binding.source_buffers.push_back(
            nodes_[static_cast<std::size_t>(edge.from_node)].output_buffers[static_cast<std::size_t>(edge.from_port)]);
        if (feedback[e]) {
            binding.is_feedback = true;
            feedback_connections_.push_back(edge.connection_index);
        }
    }

    for (NodeSlot& slot : nodes_) {
        for (InputBinding& binding : slot.inputs) {
            // One source and no delay needed: read the producer's buffer directly. More
            // than one source, or a feedback edge, needs somewhere to combine into.
            if (binding.source_buffers.size() > 1 || binding.is_feedback) {
                binding.mix_buffer = allocate_buffer();
            }
        }
    }

    master_left_.assign(kBlockSize, 0.0f);
    master_right_.assign(kBlockSize, 0.0f);
    pending_read_ = kBlockSize;

    built_ = true;
    return true;
}

void Graph::reset() {
    for (NodeSlot& slot : nodes_) {
        if (slot.node) {
            slot.node->reset();
        }
    }
    std::fill(buffer_pool_.begin(), buffer_pool_.end(), 0.0f);
    std::fill(master_left_.begin(), master_left_.end(), 0.0f);
    std::fill(master_right_.begin(), master_right_.end(), 0.0f);
    pending_read_ = kBlockSize;
    control_queue_.clear();
}

void Graph::set_audio_input(const float* left, const float* right, int frames) {
    host_input_left_ = left;
    host_input_right_ = right;
    host_input_frames_ = frames;
    host_input_offset_ = 0;
}

void Graph::drain_control_events() {
    ControlEvent event;
    while (control_queue_.pop(event)) {
        if (event.kind == ControlEvent::Kind::Note) {
            for (int index : note_receiver_nodes_) {
                nodes_[static_cast<std::size_t>(index)].node->handle_note_event(event.note);
            }
        } else {
            if (event.node_index >= 0 && event.node_index < static_cast<int>(nodes_.size())) {
                nodes_[static_cast<std::size_t>(event.node_index)]
                    .node->set_parameter(event.parameter_index, event.value);
            }
        }
    }
}

void Graph::process_block() {
    constexpr int frames = kBlockSize;
    drain_control_events();

    // Combine multi-source inputs. Single-source inputs read their producer's buffer
    // directly, and feedback inputs read the snapshot taken at the end of the last block,
    // so neither needs anything done here.
    const float* input_pointers[kMaxInputs];
    float* output_pointers[kMaxOutputs];

    for (int node_index : order_) {
        NodeSlot& slot = nodes_[static_cast<std::size_t>(node_index)];

        for (int port = 0; port < kMaxInputs; ++port) {
            input_pointers[port] = nullptr;
        }
        for (int port = 0; port < static_cast<int>(slot.inputs.size()); ++port) {
            InputBinding& binding = slot.inputs[static_cast<std::size_t>(port)];
            if (binding.is_feedback) {
                input_pointers[port] = buffer(binding.mix_buffer);
            } else if (binding.source_buffers.size() == 1) {
                input_pointers[port] = buffer(binding.source_buffers[0]);
            } else if (binding.source_buffers.size() > 1) {
                float* mix = buffer(binding.mix_buffer);
                const float* first = buffer(binding.source_buffers[0]);
                for (int i = 0; i < frames; ++i) {
                    mix[i] = first[i];
                }
                for (std::size_t s = 1; s < binding.source_buffers.size(); ++s) {
                    const float* source = buffer(binding.source_buffers[s]);
                    for (int i = 0; i < frames; ++i) {
                        mix[i] += source[i];
                    }
                }
                input_pointers[port] = mix;
            }
        }

        for (int port = 0; port < kMaxOutputs; ++port) {
            output_pointers[port] = nullptr;
        }
        for (int port = 0; port < static_cast<int>(slot.output_buffers.size()); ++port) {
            output_pointers[port] = buffer(slot.output_buffers[static_cast<std::size_t>(port)]);
        }

        // Terminals: the runtime, not the node, moves samples across the host boundary.
        if (slot.type->role == NodeRole::HostAudioSource) {
            const float* sources[2] = {host_input_left_, host_input_right_};
            if (sources[1] == nullptr) {
                sources[1] = sources[0];
            }
            for (int channel = 0; channel < 2 && channel < static_cast<int>(slot.output_buffers.size());
                 ++channel) {
                float* out = output_pointers[channel];
                const float* source = sources[channel];
                for (int i = 0; i < frames; ++i) {
                    const int position = host_input_offset_ + i;
                    out[i] = (source != nullptr && position < host_input_frames_) ? source[position]
                                                                                 : 0.0f;
                }
            }
        }

        ProcessContext process_context;
        process_context.frames = frames;
        process_context.sample_rate = sample_rate_;
        process_context.inputs = input_pointers;
        process_context.outputs = output_pointers;
        slot.node->process(process_context);
    }

    // ---- master bus ------------------------------------------------------------------
    for (int i = 0; i < frames; ++i) {
        master_left_[static_cast<std::size_t>(i)] = 0.0f;
        master_right_[static_cast<std::size_t>(i)] = 0.0f;
    }
    for (int node_index : host_sink_nodes_) {
        const NodeSlot& slot = nodes_[static_cast<std::size_t>(node_index)];
        if (slot.output_buffers.size() < 2) {
            continue;
        }
        const float* left = buffer(slot.output_buffers[0]);
        const float* right = buffer(slot.output_buffers[1]);
        for (int i = 0; i < frames; ++i) {
            master_left_[static_cast<std::size_t>(i)] += left[i];
            master_right_[static_cast<std::size_t>(i)] += right[i];
        }
    }

    snapshot_feedback();
    host_input_offset_ += frames;
    pending_read_ = 0;
}

void Graph::fill_pending() {
    if (pending_read_ >= kBlockSize) {
        process_block();
    }
}

// Copies this block's output of every feedback source into the destination's snapshot
// buffer, which that node will read at the start of the next block. Doing it here rather
// than reading the producer's buffer in place gives every feedback edge exactly one block
// of latency, regardless of where its sources sit in the schedule.
void Graph::snapshot_feedback() {
    constexpr int frames = kBlockSize;
    for (NodeSlot& slot : nodes_) {
        for (InputBinding& binding : slot.inputs) {
            if (!binding.is_feedback || binding.mix_buffer < 0) {
                continue;
            }
            float* destination = buffer(binding.mix_buffer);
            for (int i = 0; i < frames; ++i) {
                destination[i] = 0.0f;
            }
            for (int source_index : binding.source_buffers) {
                const float* source = buffer(source_index);
                for (int i = 0; i < frames; ++i) {
                    destination[i] += source[i];
                }
            }
        }
    }
}

void Graph::render(float* left, float* right, int frames) {
    if (!built_) {
        for (int i = 0; i < frames; ++i) {
            if (left != nullptr) left[i] = 0.0f;
            if (right != nullptr) right[i] = 0.0f;
        }
        return;
    }

    int written = 0;
    while (written < frames) {
        fill_pending();
        const int available = std::min(kBlockSize - pending_read_, frames - written);
        for (int i = 0; i < available; ++i) {
            const std::size_t source = static_cast<std::size_t>(pending_read_ + i);
            if (left != nullptr) {
                left[written + i] = master_left_[source];
            }
            if (right != nullptr) {
                right[written + i] = master_right_[source];
            }
        }
        pending_read_ += available;
        written += available;
    }
}

void Graph::render_interleaved(float* destination, int frames) {
    if (destination == nullptr) {
        return;
    }
    if (!built_) {
        for (int i = 0; i < frames * 2; ++i) {
            destination[i] = 0.0f;
        }
        return;
    }

    int written = 0;
    while (written < frames) {
        fill_pending();
        const int available = std::min(kBlockSize - pending_read_, frames - written);
        for (int i = 0; i < available; ++i) {
            const std::size_t source = static_cast<std::size_t>(pending_read_ + i);
            destination[(written + i) * 2] = master_left_[source];
            destination[(written + i) * 2 + 1] = master_right_[source];
        }
        pending_read_ += available;
        written += available;
    }
}

void Graph::note_on(int note, float velocity) {
    ControlEvent event;
    event.kind = ControlEvent::Kind::Note;
    event.note.kind = NoteEvent::Kind::NoteOn;
    event.note.note = note;
    event.note.velocity = velocity;
    control_queue_.push(event);
}

void Graph::note_off(int note) {
    ControlEvent event;
    event.kind = ControlEvent::Kind::Note;
    event.note.kind = NoteEvent::Kind::NoteOff;
    event.note.note = note;
    control_queue_.push(event);
}

void Graph::all_notes_off() {
    ControlEvent event;
    event.kind = ControlEvent::Kind::Note;
    event.note.kind = NoteEvent::Kind::AllNotesOff;
    control_queue_.push(event);
}

void Graph::dispatch_note(const NoteEvent& event) {
    for (int index : note_receiver_nodes_) {
        nodes_[static_cast<std::size_t>(index)].node->handle_note_event(event);
    }
}

int Graph::node_index(const std::string& id) const {
    for (std::size_t i = 0; i < nodes_.size(); ++i) {
        if (nodes_[i].id == id) {
            return static_cast<int>(i);
        }
    }
    return -1;
}

int Graph::parameter_index(int index, const std::string& parameter_name) const {
    if (index < 0 || index >= static_cast<int>(nodes_.size())) {
        return -1;
    }
    return nodes_[static_cast<std::size_t>(index)].type->find_parameter(parameter_name.c_str());
}

bool Graph::set_parameter(const std::string& id, const std::string& parameter_name, float value) {
    const int index = node_index(id);
    if (index < 0) {
        return false;
    }
    const int parameter = parameter_index(index, parameter_name);
    if (parameter < 0) {
        return false;
    }
    set_parameter(index, parameter, value);
    return true;
}

void Graph::set_parameter(int index, int parameter, float value) {
    ControlEvent event;
    event.kind = ControlEvent::Kind::ParameterSet;
    event.node_index = index;
    event.parameter_index = parameter;
    event.value = value;
    control_queue_.push(event);
}

const std::string& Graph::node_id(int index) const {
    static const std::string empty;
    if (index < 0 || index >= static_cast<int>(nodes_.size())) {
        return empty;
    }
    return nodes_[static_cast<std::size_t>(index)].id;
}

const NodeTypeDescriptor* Graph::node_type(int index) const {
    if (index < 0 || index >= static_cast<int>(nodes_.size())) {
        return nullptr;
    }
    return nodes_[static_cast<std::size_t>(index)].type;
}

const float* Graph::port_signal(int index, int port) const {
    if (index < 0 || index >= static_cast<int>(nodes_.size())) {
        return nullptr;
    }
    const NodeSlot& slot = nodes_[static_cast<std::size_t>(index)];
    if (port < 0 || port >= static_cast<int>(slot.output_buffers.size())) {
        return nullptr;
    }
    return buffer(slot.output_buffers[static_cast<std::size_t>(port)]);
}

ResourceCost Graph::estimated_cost() const {
    ResourceCost total = cost_;
    // Buffers are part of the honest answer to "does this fit on that board?".
    total.heap_bytes += buffer_count_ * kBlockSize * static_cast<int>(sizeof(float));
    return total;
}

}  // namespace soundgraph
