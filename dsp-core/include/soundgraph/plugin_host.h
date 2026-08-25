// Somebody else's plugin, as far as the core is concerned.
//
// dsp-core describes the node; the runtime supplies the plugin. That split is not new
// here — it is what terminals already do, where the core fully describes a
// HostAudioSource it cannot possibly implement and the runtime moves the samples. A
// hosted plugin has the same shape, so it arrives the same way: resolved by the graph
// before prepare(), handed down through PrepareContext, exactly as a sampler's buffer
// is.
//
// Nothing in this header knows what a DLL is. That is the point: LoadLibrary, bundles,
// COM and clap_entry live in the desktop runtime, and the core keeps its promise to
// depend on nothing but the standard library. A target with no plugins simply has no
// provider, which is a fact rather than an error.
//
// See docs/hosted-plugins-design.md.
#pragma once

#include <memory>
#include <string>
#include <vector>

namespace soundgraph {

// What a patch asks for. Identity is the question; everything else is a hint that
// makes a failure readable, and no hint is ever the thing looked up — a path is a fine
// thing to remember and a terrible thing to depend on.
struct PluginRequest {
    std::string format;     // "CLAP" or "VST3"
    std::string identity;   // format-native unique id: reverse-DNS, or a VST3 class UID
    std::string vendor;     // hint
    std::string name;       // hint
    std::string path_hint;  // hint
    std::string state;      // the plugin's own opaque state, empty for its defaults
    // Slot index to the plugin's own parameter id; -1 for an unbound slot. The provider
    // needs these because it, not the node, knows how to speak to that plugin — the
    // node only ever counts from zero.
    std::vector<int> slots;
};

// One loaded, activated plugin. The runtime hands these out; the node just uses one.
//
// Deliberately narrower than the plugin formats themselves: an effect needs audio in,
// audio out, and controls. Notes arrive when instruments do, in Stage 3.
class HostedPluginInstance {
public:
    virtual ~HostedPluginInstance() = default;

    // Called from prepare(), where allocation is allowed.
    virtual void prepare(double sample_rate, int max_block_frames) = 0;

    // Called from the audio thread. Buffers are the graph's; the plugin may write only
    // to `outputs`, and `frames` never exceeds the max_block_frames it was prepared
    // with. A hosted plugin makes no promise about allocation or locking — see the
    // design doc, which says so out loud rather than pretending otherwise.
    virtual void process(const float* const* inputs, int input_channels,
                         float* const* outputs, int output_channels, int frames) = 0;

    // Slot 0..n, always normalised 0..1, whatever the plugin's own range is. The node
    // sends these only when they change.
    virtual void set_control(int slot, float value) = 0;

    // Reported, and for Stage 2 not yet compensated for. See the design doc.
    virtual int latency_frames() const { return 0; }
};

// How a runtime offers plugins. A target that has none has no provider, and a graph
// with no provider still builds — the effect passes its audio through untouched, and
// the patch says so once rather than failing.
class PluginProvider {
public:
    virtual ~PluginProvider() = default;

    // Null is a legitimate answer: "not on this machine", or "not on this target".
    // The graph turns it into a diagnostic, never into a build failure.
    virtual std::unique_ptr<HostedPluginInstance> acquire(const PluginRequest& request) = 0;
};

}  // namespace soundgraph
