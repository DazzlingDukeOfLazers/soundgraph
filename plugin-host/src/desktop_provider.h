// The desktop answer to "where do I get a plugin from?".
//
// dsp-core declares PluginProvider and never implements one, because implementing one
// means loading shared libraries. This is the implementation, and it lives here beside
// sg-host's loaders because it is the same act: find a plugin, open it, drive it.
#pragma once

#include <memory>

#include "soundgraph/plugin_host.h"

namespace soundgraph::host {

// Scans the platform's plugin folders — and SOUNDGRAPH_PLUGIN_PATH, if set, which is
// how a test points at plugins nobody installed. Resolution is by identity; a path hint
// is tried first only because it is usually right and always cheap to check.
std::unique_ptr<soundgraph::PluginProvider> make_desktop_plugin_provider();

}  // namespace soundgraph::host
