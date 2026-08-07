// SoundGraph — patch JSON in and out.
//
// The boundary between the canonical text format and the runtime. dsp-core never sees
// text; everything textual stops here.
#pragma once

#include <string>
#include <vector>

#include "soundgraph/graph_description.h"
#include "soundgraph/registry.h"
#include "soundgraph/types.h"

namespace soundgraph {

// Parses patch JSON. Structural problems (bad syntax, wrong types, missing required
// fields) are reported as diagnostics; graph-level problems are not checked here — run
// validate() from dsp-core for those.
bool parse_patch(const std::string& text,
                 GraphDescription& out,
                 std::vector<Diagnostic>& diagnostics);

// Writes the patch back out. Field and node order follow the description, so a load /
// save round trip produces a stable diff.
std::string write_patch(const GraphDescription& description, bool pretty = true);

// Diagnostics as JSON, so that a browser or editor frontend can highlight the same nodes
// and connections the command line tools name.
std::string write_diagnostics(const std::vector<Diagnostic>& diagnostics, bool pretty = false);

// The node vocabulary as JSON: ports, parameters, ranges, categories and search terms.
// This is what lets an editor build its palette, type-check a drag, and offer
// intent-based search without reimplementing any of it.
std::string write_registry(const NodeRegistry& registry, bool pretty = false);

#if !defined(SOUNDGRAPH_NO_FILE_IO)

// Reading and writing files is excluded from targets that have no filesystem — the
// browser and, later, embedded. Those receive patch text from their host instead.
bool load_patch(const std::string& path,
                GraphDescription& out,
                std::vector<Diagnostic>& diagnostics);

bool save_patch(const std::string& path,
                const GraphDescription& description,
                std::string& error);

#endif  // SOUNDGRAPH_NO_FILE_IO

}  // namespace soundgraph
