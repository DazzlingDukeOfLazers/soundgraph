// Finding a plugin by identity, and driving it as a graph node.
//
// Two halves. The search is unglamorous: walk the folders this platform keeps plugins
// in, open each candidate, ask what it is, keep the one that matches. Opening every
// plugin on a machine is not something to do twice, so a provider remembers.
//
// The adapter is the interesting half. sg-host's HostedPlugin is shaped for a command
// line — vectors, names, a parameter list — and dsp-core's HostedPluginInstance is
// shaped for an audio callback: raw pointers, slot indices, no allocation. This turns
// one into the other, and the slot table is the reason the two are allowed to differ.
// A node counts its controls from zero; only the provider knows that slot 3 means
// parameter 1049 of this particular plugin.
#include "desktop_provider.h"

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <filesystem>
#include <string>
#include <vector>

#include "hosted_plugin.h"

namespace soundgraph::host {
namespace {

namespace fs = std::filesystem;

std::string environment(const char* name) {
    const char* value = std::getenv(name);
    return value != nullptr ? std::string(value) : std::string();
}

// Where this platform keeps plugins, plus wherever the caller says. The override comes
// first because a test that has arranged for a particular plugin should not be at the
// mercy of whatever else is installed on the machine running it.
std::vector<fs::path> search_roots(const std::string& format) {
    std::vector<fs::path> roots;
    const std::string override_path = environment("SOUNDGRAPH_PLUGIN_PATH");
    if (!override_path.empty()) {
#if defined(_WIN32)
        const char separator = ';';
#else
        const char separator = ':';
#endif
        std::size_t start = 0;
        while (start <= override_path.size()) {
            const std::size_t end = override_path.find(separator, start);
            const std::string one = override_path.substr(
                start, end == std::string::npos ? std::string::npos : end - start);
            if (!one.empty()) {
                roots.emplace_back(one);
            }
            if (end == std::string::npos) break;
            start = end + 1;
        }
    }

#if defined(_WIN32)
    const std::string common = environment("CommonProgramFiles");
    const std::string local = environment("LOCALAPPDATA");
    if (!common.empty()) roots.emplace_back(fs::path(common) / format);
    if (!local.empty()) roots.emplace_back(fs::path(local) / "Programs" / "Common" / format);
#elif defined(__APPLE__)
    const std::string home = environment("HOME");
    if (!home.empty()) {
        roots.emplace_back(fs::path(home) / "Library" / "Audio" / "Plug-Ins" / format);
    }
    roots.emplace_back(fs::path("/Library/Audio/Plug-Ins") / format);
#else
    const std::string home = environment("HOME");
    const std::string lower = format == "VST3" ? "vst3" : "clap";
    if (!home.empty()) roots.emplace_back(fs::path(home) / ("." + lower));
    roots.emplace_back(fs::path("/usr/lib") / lower);
    roots.emplace_back(fs::path("/usr/local/lib") / lower);
#endif
    return roots;
}

// Every file with the right extension under the roots. Recursive, because plugins nest
// a couple of folders deep in places, and depth-limited because nothing good is found
// four levels down a plugin folder.
std::vector<fs::path> candidates(const std::string& format) {
    const std::string wanted = format == "CLAP" ? ".clap" : ".vst3";
    std::vector<fs::path> found;
    for (const fs::path& root : search_roots(format)) {
        std::error_code code;
        if (!fs::exists(root, code)) continue;
        const auto options = fs::directory_options::skip_permission_denied;
        for (fs::recursive_directory_iterator it(root, options, code), end; it != end;
             it.increment(code)) {
            if (code) break;
            if (it.depth() > 3) {
                it.disable_recursion_pending();
                continue;
            }
            const std::string name = it->path().filename().string();
            if (name.size() < wanted.size()) continue;
            std::string suffix = name.substr(name.size() - wanted.size());
            std::transform(suffix.begin(), suffix.end(), suffix.begin(),
                           [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
            if (suffix == wanted) {
                found.push_back(it->path());
                // A .vst3 is a directory on some platforms; do not walk into the one
                // that has just been matched.
                it.disable_recursion_pending();
            }
        }
    }
    return found;
}

std::unique_ptr<HostedPlugin> open_by_format(const std::string& format, const std::string& path,
                                             int index, std::string& error) {
    return format == "CLAP" ? open_clap(path, index, error) : open_vst3(path, index, error);
}

// ---- the adapter -------------------------------------------------------------------

class HostedInstance final : public soundgraph::HostedPluginInstance {
public:
    HostedInstance(std::unique_ptr<HostedPlugin> plugin, std::vector<int> slots)
        : plugin_(std::move(plugin)), slots_(std::move(slots)) {}

    void prepare(double sample_rate, int max_block_frames) override {
        // prepare() is called again whenever the rate changes, so this has to be the
        // second activation as often as the first.
        plugin_->deactivate();
        std::string error;
        active_ = plugin_->activate(sample_rate, max_block_frames, error);
    }

    void process(const float* const* inputs, int input_channels, float* const* outputs,
                 int output_channels, int frames) override {
        if (!active_) {
            for (int channel = 0; channel < output_channels; ++channel) {
                std::fill_n(outputs[channel], frames, 0.0f);
            }
            return;
        }
        plugin_->process_audio(inputs, input_channels, outputs, output_channels, frames);
    }

    void note_on(int note, float velocity) override {
        (void)velocity;  // sg-host's queue_note carries its own fixed velocity for now
        plugin_->queue_note(note, true);
    }

    void note_off(int note) override { plugin_->queue_note(note, false); }

    void set_control(int slot, float value) override {
        if (slot < 0 || slot >= static_cast<int>(slots_.size())) return;
        const int parameter = slots_[static_cast<std::size_t>(slot)];
        if (parameter < 0) return;  // an unbound slot drives nothing, quietly
        plugin_->queue_parameter(static_cast<uint32_t>(parameter), value);
    }

private:
    std::unique_ptr<HostedPlugin> plugin_;
    std::vector<int> slots_;
    bool active_ = false;
};

// ---- the provider ------------------------------------------------------------------

class DesktopProvider final : public soundgraph::PluginProvider {
public:
    std::unique_ptr<soundgraph::HostedPluginInstance> acquire(
        const soundgraph::PluginRequest& request) override {
        if (request.format != "CLAP" && request.format != "VST3") {
            return nullptr;
        }

        // The hint first: usually right, and one open to find out.
        if (!request.path_hint.empty()) {
            std::error_code code;
            if (fs::exists(request.path_hint, code)) {
                if (auto instance = try_open(request, request.path_hint)) {
                    return instance;
                }
            }
        }

        for (const fs::path& path : candidates(request.format)) {
            if (auto instance = try_open(request, path.string())) {
                return instance;
            }
        }
        return nullptr;  // "not on this machine" — which the graph turns into a warning
    }

private:
    std::unique_ptr<soundgraph::HostedPluginInstance> try_open(
        const soundgraph::PluginRequest& request, const std::string& path) {
        std::string error;
        std::unique_ptr<HostedPlugin> plugin = open_by_format(request.format, path, 0, error);
        if (plugin == nullptr) {
            return nullptr;
        }
        // One file may hold several plugins; the identity says which, and a file
        // holding none of them is simply the wrong file.
        const auto& available = plugin->available();
        for (std::size_t i = 0; i < available.size(); ++i) {
            if (available[i].id != request.identity) continue;
            if (i != 0) {
                plugin = open_by_format(request.format, path, static_cast<int>(i), error);
                if (plugin == nullptr) return nullptr;
            }
            return std::make_unique<HostedInstance>(std::move(plugin), request.slots);
        }
        return nullptr;
    }
};

}  // namespace

std::unique_ptr<soundgraph::PluginProvider> make_desktop_plugin_provider() {
    return std::make_unique<DesktopProvider>();
}

}  // namespace soundgraph::host
