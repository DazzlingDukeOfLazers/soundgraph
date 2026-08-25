// The desktop answer to "where do I get a plugin from?".
//
// dsp-core declares PluginProvider and never implements one, because implementing one
// means loading shared libraries. This is the implementation, and it lives here beside
// sg-host's loaders because it is the same act: find a plugin, open it, drive it.
#pragma once

#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "soundgraph/plugin_host.h"

namespace soundgraph::host {

// One plugin as a scan found it. Enough for an editor to show a list and bind slots
// without opening anything itself — which matters, because opening a stranger's plugin
// is exactly the act that can hang or crash, and an editor should not be the process
// it happens in.
struct PluginSummary {
    std::string format;
    std::string identity;
    std::string name;
    std::string vendor;
    std::string path;
    bool is_instrument = false;
    // Parameter id and display name, in the plugin's own order: what a slot binds to.
    std::vector<std::pair<int, std::string>> parameters;
};

// Walks this platform's plugin folders (and SOUNDGRAPH_PLUGIN_PATH) and opens each
// candidate to ask what it is. Slow by nature — it is every plugin on the machine —
// and meant to be run once by a tool, not by an audio thread.
std::vector<PluginSummary> scan_installed_plugins();

// Scans the platform's plugin folders — and SOUNDGRAPH_PLUGIN_PATH, if set, which is
// how a test points at plugins nobody installed. Resolution is by identity; a path hint
// is tried first only because it is usually right and always cheap to check.
std::unique_ptr<soundgraph::PluginProvider> make_desktop_plugin_provider();

}  // namespace soundgraph::host
