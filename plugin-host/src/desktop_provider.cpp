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

// What a slot needs to know to speak to one particular parameter: which one, and in
// what units. A node always sends 0..1, because a knob in SoundGraph is 0..1. VST3
// agrees and reports every parameter as 0..1, but CLAP reports plain ranges — "FX Type"
// on Surge XT Effects runs 0..30 — so sending a normalised value straight through would
// have reached only the first two of thirty effects and looked, from the outside,
// exactly like a slot that did nothing.
struct SlotBinding {
    bool bound = false;
    int parameter = -1;
    double minimum = 0.0;
    double maximum = 1.0;
};

class HostedInstance final : public soundgraph::HostedPluginInstance {
public:
    HostedInstance(std::unique_ptr<HostedPlugin> plugin, std::vector<SlotBinding> slots)
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
        // A plugin that was asked to change something structural — Surge XT rebuilding
        // its effect chain when FX Type moves — asks for the main thread and waits.
        // Offline this is that thread, so answering here is right and the change lands
        // in the next block. A live host will want this moved off the audio callback.
        plugin_->main_thread_tick();
    }

    void note_on(int note, float velocity) override {
        (void)velocity;  // sg-host's queue_note carries its own fixed velocity for now
        plugin_->queue_note(note, true);
    }

    void note_off(int note) override { plugin_->queue_note(note, false); }

    void set_control(int slot, float value) override {
        if (slot < 0 || slot >= static_cast<int>(slots_.size())) return;
        const SlotBinding& binding = slots_[static_cast<std::size_t>(slot)];
        if (!binding.bound) return;  // an unbound slot drives nothing, quietly
        const double plain =
            binding.minimum + static_cast<double>(value) * (binding.maximum - binding.minimum);
        plugin_->queue_parameter(static_cast<uint32_t>(binding.parameter), plain);
    }

    bool save_state(std::string& bytes) override { return plugin_->save_state(bytes); }

    // Asked after prepare(), which is where the plugin was activated and therefore the
    // first moment it can answer. The graph does the aligning; this only reports.
    int latency_frames() const override { return plugin_->latency_frames(); }

    // ---- the plugin's own face ------------------------------------------------
    // Straight through. The core declares these so an editor has something to ask,
    // and the loaders already know how to do them; this is only the join. The one
    // translation is that the core counts pixels in ints.
    bool has_gui() override { return plugin_->has_gui(); }
    bool open_gui(void* parent) override { return plugin_->open_gui(parent); }
    void close_gui() override { plugin_->close_gui(); }

    bool gui_size(int& width, int& height) override {
        unsigned w = 0;
        unsigned h = 0;
        if (!plugin_->gui_size(w, h)) return false;
        width = static_cast<int>(w);
        height = static_cast<int>(h);
        return true;
    }

    bool gui_can_resize() override { return plugin_->gui_can_resize(); }

    bool set_gui_size(int& width, int& height) override {
        unsigned w = static_cast<unsigned>(width < 0 ? 0 : width);
        unsigned h = static_cast<unsigned>(height < 0 ? 0 : height);
        if (!plugin_->set_gui_size(w, h)) return false;
        width = static_cast<int>(w);
        height = static_cast<int>(h);
        return true;
    }

    bool take_gui_resize_request(int& width, int& height) override {
        unsigned w = 0;
        unsigned h = 0;
        if (!plugin_->take_gui_resize_request(w, h)) return false;
        width = static_cast<int>(w);
        height = static_cast<int>(h);
        return true;
    }

    void main_thread_tick() override { plugin_->main_thread_tick(); }

private:
    std::unique_ptr<HostedPlugin> plugin_;
    std::vector<SlotBinding> slots_;
    bool active_ = false;
};

// Resolves the patch's slot table against the ranges this plugin actually publishes.
std::vector<SlotBinding> bind_slots(const HostedPlugin& plugin, const std::vector<int>& wanted) {
    const std::vector<Parameter> parameters = plugin.parameters();
    std::vector<SlotBinding> bindings;
    bindings.reserve(wanted.size());
    for (const int id : wanted) {
        SlotBinding binding;
        // A CLAP parameter id is a uint32 and is very often negative once it has been
        // through an int — Surge XT's Global Volume is -810883302. So "negative means
        // unbound" was a sentinel that collided with most of the real ids on this
        // machine, and silently dropped them. Only the exact -1 the patch writes for an
        // empty slot means unbound.
        binding.bound = id != -1;
        binding.parameter = id;
        for (const Parameter& parameter : parameters) {
            if (static_cast<int>(parameter.id) == id) {
                binding.minimum = parameter.minimum;
                binding.maximum = parameter.maximum;
                break;
            }
        }
        bindings.push_back(binding);
    }
    return bindings;
}

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
            // Told what it is before it is told to play. The patch's state is the
            // plugin's own bytes, so this either works or the plugin refuses it — and a
            // refusal is not fatal: a preset that no longer loads, because the plugin
            // was updated under the patch, still leaves an instrument that makes a
            // sound. Losing the preset is bad; losing the patch would be worse.
            if (!request.state.empty()) {
                plugin->load_state(request.state);
            }
            auto bindings = bind_slots(*plugin, request.slots);
            return std::make_unique<HostedInstance>(std::move(plugin), std::move(bindings));
        }
        return nullptr;
    }
};

}  // namespace

std::vector<PluginSummary> scan_installed_plugins() {
    std::vector<PluginSummary> found;
    for (const char* format : {"CLAP", "VST3"}) {
        for (const fs::path& path : candidates(format)) {
            std::string error;
            std::unique_ptr<HostedPlugin> plugin = open_by_format(format, path.string(), 0, error);
            if (plugin == nullptr) continue;  // not a plugin, or one that refused to open
            const auto& available = plugin->available();
            for (std::size_t i = 0; i < available.size(); ++i) {
                PluginSummary summary;
                summary.format = format;
                summary.identity = available[i].id;
                summary.name = available[i].name;
                summary.vendor = available[i].vendor;
                summary.path = path.string();
                // Parameters come from the instance that is open; for a file holding
                // several, only the first is described rather than opening all of them
                // during a scan that is already the slowest thing here.
                if (i == 0) {
                    for (const Parameter& parameter : plugin->parameters()) {
                        if (parameter.hidden) continue;
                        summary.parameters.emplace_back(static_cast<int>(parameter.id),
                                                        parameter.name);
                    }
                    summary.is_instrument = plugin->channel_count() > 0;
                }
                found.push_back(std::move(summary));
            }
        }
    }
    return found;
}

std::unique_ptr<soundgraph::PluginProvider> make_desktop_plugin_provider() {
    return std::make_unique<DesktopProvider>();
}

}  // namespace soundgraph::host
