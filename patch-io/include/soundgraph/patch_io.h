// SoundGraph — patch JSON in and out.
//
// The boundary between the canonical text format and the runtime. dsp-core never sees
// text; everything textual stops here.
#pragma once

#include <string>
#include <vector>

#include "soundgraph/graph_description.h"
#include "soundgraph/types.h"

namespace soundgraph {

// Parses patch JSON. Structural problems (bad syntax, wrong types, missing required
// fields) are reported as diagnostics; graph-level problems are not checked here — run
// validate() from dsp-core for those.
bool parse_patch(const std::string& text,
                 GraphDescription& out,
                 std::vector<Diagnostic>& diagnostics);

bool load_patch(const std::string& path,
                GraphDescription& out,
                std::vector<Diagnostic>& diagnostics);

// Writes the patch back out. Field and node order follow the description, so a load /
// save round trip produces a stable diff.
std::string write_patch(const GraphDescription& description, bool pretty = true);

bool save_patch(const std::string& path,
                const GraphDescription& description,
                std::string& error);

}  // namespace soundgraph
