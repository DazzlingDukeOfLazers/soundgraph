// sg-validate — read a patch, say what is wrong with it, and explain what it will do.
//
// Deliberately usable before any audio device exists: this is the tool that answers
// "is this graph well formed?" independently of any host.
#include <cstring>
#include <iostream>
#include <string>
#include <vector>

#include "soundgraph/patch_io.h"
#include "soundgraph/soundgraph.h"

namespace {

int print_usage() {
    std::cout <<
        "usage: sg-validate <patch.json> [options]\n"
        "       sg-validate --list-nodes [search terms]\n"
        "\n"
        "options:\n"
        "  --explain          print the execution order, feedback edges and resource estimate\n"
        "  --quiet            print nothing; report the result through the exit code\n"
        "\n"
        "exit code is 0 when the patch has no errors, 1 otherwise.\n";
    return 2;
}

void print_diagnostics(const std::vector<soundgraph::Diagnostic>& diagnostics) {
    for (const soundgraph::Diagnostic& diagnostic : diagnostics) {
        std::cout << diagnostic.format() << "\n\n";
    }
}

int list_nodes(const std::string& query) {
    const soundgraph::NodeRegistry& registry = soundgraph::NodeRegistry::builtin();
    const std::vector<const soundgraph::NodeTypeDescriptor*> types =
        query.empty() ? std::vector<const soundgraph::NodeTypeDescriptor*>(
                            registry.types().begin(), registry.types().end())
                      : registry.search(query);

    if (types.empty()) {
        std::cout << "Nothing matches '" << query << "'.\n";
        return 1;
    }

    for (const soundgraph::NodeTypeDescriptor* type : types) {
        std::cout << type->name << "  (" << type->category << ")\n"
                  << "  " << type->summary << "\n";

        if (!type->inputs.empty()) {
            std::cout << "  in: ";
            for (int i = 0; i < type->inputs.size(); ++i) {
                if (i > 0) std::cout << ", ";
                std::cout << type->inputs[i].name << " [" << to_string(type->inputs[i].type);
                if (std::strlen(type->inputs[i].unit) > 0) {
                    std::cout << " " << type->inputs[i].unit;
                }
                std::cout << (type->inputs[i].required ? ", required]" : "]");
            }
            std::cout << "\n";
        }
        if (!type->outputs.empty()) {
            std::cout << "  out: ";
            for (int i = 0; i < type->outputs.size(); ++i) {
                if (i > 0) std::cout << ", ";
                std::cout << type->outputs[i].name << " [" << to_string(type->outputs[i].type) << "]";
            }
            std::cout << "\n";
        }
        for (int i = 0; i < type->parameters.size(); ++i) {
            const soundgraph::ParameterDescriptor& parameter = type->parameters[i];
            std::cout << "  " << parameter.name << " = " << parameter.default_value;
            if (std::strlen(parameter.unit) > 0) {
                std::cout << " " << parameter.unit;
            }
            std::cout << "  (" << parameter.min_value << " to " << parameter.max_value << ")";
            if (parameter.enum_labels != nullptr) {
                std::cout << "  [";
                for (int e = 0; e < parameter.enum_count; ++e) {
                    if (e > 0) std::cout << ", ";
                    std::cout << e << "=" << parameter.enum_labels[e];
                }
                std::cout << "]";
            }
            std::cout << "\n";
        }
        std::cout << "\n";
    }
    return 0;
}

void explain(const soundgraph::GraphDescription& description, const soundgraph::Graph& graph) {
    std::cout << "execution order:\n";
    for (int index : graph.execution_order()) {
        const soundgraph::NodeTypeDescriptor* type = graph.node_type(index);
        std::cout << "  " << graph.node_id(index) << "  (" << (type != nullptr ? type->name : "?")
                  << ")\n";
    }

    if (!graph.feedback_connections().empty()) {
        std::cout << "\nfeedback edges (these deliver the previous block's samples):\n";
        for (int index : graph.feedback_connections()) {
            const soundgraph::ConnectionDescription& connection =
                description.connections[static_cast<std::size_t>(index)];
            std::cout << "  " << connection.from_node << "." << connection.from_port << " -> "
                      << connection.to_node << "." << connection.to_port << "\n";
        }
    }

    const soundgraph::ResourceCost cost = graph.estimated_cost();
    std::cout << "\nestimated cost:\n"
              << "  cpu units   " << cost.cpu_cost << "\n"
              << "  state       " << cost.state_bytes << " bytes\n"
              << "  buffers     " << cost.heap_bytes << " bytes\n";
}

}  // namespace

int main(int argc, char** argv) {
    if (argc < 2) {
        return print_usage();
    }

    if (std::strcmp(argv[1], "--list-nodes") == 0) {
        std::string query;
        for (int i = 2; i < argc; ++i) {
            if (!query.empty()) query += " ";
            query += argv[i];
        }
        return list_nodes(query);
    }

    if (argv[1][0] == '-') {
        return print_usage();
    }

    const std::string path = argv[1];
    bool want_explanation = false;
    bool quiet = false;
    for (int i = 2; i < argc; ++i) {
        if (std::strcmp(argv[i], "--explain") == 0) {
            want_explanation = true;
        } else if (std::strcmp(argv[i], "--quiet") == 0) {
            quiet = true;
        } else {
            std::cerr << "unknown option: " << argv[i] << "\n";
            return print_usage();
        }
    }

    soundgraph::GraphDescription description;
    std::vector<soundgraph::Diagnostic> diagnostics;

    if (!soundgraph::load_patch(path, description, diagnostics)) {
        if (!quiet) {
            print_diagnostics(diagnostics);
            std::cout << path << ": could not be read.\n";
        }
        return 1;
    }

    const soundgraph::NodeRegistry& registry = soundgraph::NodeRegistry::builtin();
    const bool ok = soundgraph::validate(description, registry, diagnostics);

    if (!quiet) {
        print_diagnostics(diagnostics);
    }

    if (!ok) {
        if (!quiet) {
            std::cout << path << ": not valid.\n";
        }
        return 1;
    }

    if (want_explanation) {
        soundgraph::Graph graph;
        std::vector<soundgraph::Diagnostic> build_diagnostics;
        soundgraph::PrepareContext context;
        if (graph.build(description, registry, context, build_diagnostics)) {
            if (!quiet) {
                explain(description, graph);
                std::cout << "\n";
            }
        } else if (!quiet) {
            print_diagnostics(build_diagnostics);
            return 1;
        }
    }

    if (!quiet) {
        std::cout << path << ": valid. " << description.nodes.size() << " nodes, "
                  << description.connections.size() << " connections.\n";
    }
    return 0;
}
