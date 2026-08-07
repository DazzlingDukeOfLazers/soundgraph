// SoundGraph — the node type registry.
//
// One place decides what node types exist and what they mean. Editors read this to
// populate their palette and to type-check connections while dragging; validation reads
// it to reject unknown types; the resource model reads it to answer target-fit questions.
#pragma once

#include <memory>
#include <string>
#include <vector>

#include "soundgraph/node.h"

namespace soundgraph {

class NodeRegistry {
public:
    // The built-in vocabulary. There is exactly one instance; node types are static data.
    static const NodeRegistry& builtin();

    const NodeTypeDescriptor* find(const std::string& type_name) const;

    // Creates a node with its parameters initialized to registry defaults.
    // Returns null if the type is unknown.
    std::unique_ptr<DspNode> create(const std::string& type_name) const;

    Slice<const NodeTypeDescriptor*> types() const {
        return Slice<const NodeTypeDescriptor*>(types_.data(), static_cast<int>(types_.size()));
    }

    // Intent-based lookup over name, display name, summary and search terms.
    // Results are ordered best-match first. Used by editor search fields.
    std::vector<const NodeTypeDescriptor*> search(const std::string& query) const;

private:
    NodeRegistry();
    std::vector<const NodeTypeDescriptor*> types_;
};

}  // namespace soundgraph
