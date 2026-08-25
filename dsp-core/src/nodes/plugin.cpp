// PluginEffect — somebody else's audio processor, wired into the graph like any node.
//
// The node holds no plugin loading code and never could: dsp-core depends on nothing
// but the standard library, so the instance arrives already made, resolved by the graph
// and handed down through PrepareContext exactly as a sampler's buffer is.
//
// The behaviour worth knowing is what happens when there is no plugin — on the ESP32,
// in a browser tab, or on a desktop that simply does not have it installed. The node
// passes its input through untouched. A missing reverb should cost you the reverb, not
// the patch: everything upstream still plays, the diagnostic explains itself once, and
// the same file opens everywhere even though it cannot sound the same everywhere.
//
// See docs/hosted-plugins-design.md.
#include <algorithm>
#include <array>
#include <vector>

#include "nodes/node_types.h"

namespace soundgraph {
namespace nodes {
namespace {

constexpr int kSlotCount = 16;

constexpr PortDescriptor kInputs[] = {
    {"left", SignalType::Audio, "", false, true, "Left channel into the plugin."},
    {"right", SignalType::Audio, "", false, true,
     "Right channel into the plugin. Unconnected, the left channel feeds both."},
};

constexpr PortDescriptor kOutputs[] = {
    {"left", SignalType::Audio, "", false, false, "Left channel out of the plugin."},
    {"right", SignalType::Audio, "", false, false, "Right channel out of the plugin."},
};

// Sixteen slots, because a plugin may publish thousands of parameters — Surge XT offers
// 2855 — and kMaxParameters is 24. Which plugin parameter a slot drives is chosen per
// patch and stored beside the plugin, not here; a slot is named generically because
// static descriptors cannot be renamed per instance, and the editor shows the plugin's
// own name for it because the editor can ask the plugin.
//
// The point of a slot being an ordinary control input is that an LFO, an envelope or a
// MidiCC node modulates a stranger's plugin with no special case anywhere.
constexpr ParameterDescriptor kParameters[] = {
    {"bypass", "", 0.0f, 1.0f, 0.0f, Scaling::Linear,
     "Pass the audio through untouched, leaving the plugin loaded.", nullptr, 0},
    {"mix", "", 0.0f, 1.0f, 1.0f, Scaling::Linear,
     "How much of the plugin's output to hear against the dry input.", nullptr, 0},
    {"slot1", "", 0.0f, 1.0f, 0.0f, Scaling::Linear, "Plugin control 1.", nullptr, 0},
    {"slot2", "", 0.0f, 1.0f, 0.0f, Scaling::Linear, "Plugin control 2.", nullptr, 0},
    {"slot3", "", 0.0f, 1.0f, 0.0f, Scaling::Linear, "Plugin control 3.", nullptr, 0},
    {"slot4", "", 0.0f, 1.0f, 0.0f, Scaling::Linear, "Plugin control 4.", nullptr, 0},
    {"slot5", "", 0.0f, 1.0f, 0.0f, Scaling::Linear, "Plugin control 5.", nullptr, 0},
    {"slot6", "", 0.0f, 1.0f, 0.0f, Scaling::Linear, "Plugin control 6.", nullptr, 0},
    {"slot7", "", 0.0f, 1.0f, 0.0f, Scaling::Linear, "Plugin control 7.", nullptr, 0},
    {"slot8", "", 0.0f, 1.0f, 0.0f, Scaling::Linear, "Plugin control 8.", nullptr, 0},
    {"slot9", "", 0.0f, 1.0f, 0.0f, Scaling::Linear, "Plugin control 9.", nullptr, 0},
    {"slot10", "", 0.0f, 1.0f, 0.0f, Scaling::Linear, "Plugin control 10.", nullptr, 0},
    {"slot11", "", 0.0f, 1.0f, 0.0f, Scaling::Linear, "Plugin control 11.", nullptr, 0},
    {"slot12", "", 0.0f, 1.0f, 0.0f, Scaling::Linear, "Plugin control 12.", nullptr, 0},
    {"slot13", "", 0.0f, 1.0f, 0.0f, Scaling::Linear, "Plugin control 13.", nullptr, 0},
    {"slot14", "", 0.0f, 1.0f, 0.0f, Scaling::Linear, "Plugin control 14.", nullptr, 0},
    {"slot15", "", 0.0f, 1.0f, 0.0f, Scaling::Linear, "Plugin control 15.", nullptr, 0},
    {"slot16", "", 0.0f, 1.0f, 0.0f, Scaling::Linear, "Plugin control 16.", nullptr, 0},
};

enum Param {
    kBypass = 0,
    kMix,
    kFirstSlot,
};

class PluginEffectNode : public DspNode {
public:
    void prepare(const PrepareContext& context) override {
        plugin_ = context.plugin;
        silence_.assign(static_cast<std::size_t>(context.max_block_size), 0.0f);
        dry_left_.assign(static_cast<std::size_t>(context.max_block_size), 0.0f);
        dry_right_.assign(static_cast<std::size_t>(context.max_block_size), 0.0f);
        // Nothing has been sent yet, and no plausible slot value equals this, so the
        // first block sends all sixteen and every block after it sends only movement.
        sent_.fill(-1.0f);
        if (plugin_ != nullptr) {
            plugin_->prepare(context.sample_rate, context.max_block_size);
        }
    }

    void reset() override { sent_.fill(-1.0f); }

    void process(const ProcessContext& context) override {
        const int frames = context.frames;
        float* out_left = context.outputs[0];
        float* out_right = context.outputs[1];
        if (out_left == nullptr || out_right == nullptr) {
            return;
        }

        // An unconnected input is null rather than zeros — the graph's convention — so
        // a mono source feeds both sides rather than being silently half-silent.
        const float* in_left = context.inputs[0] != nullptr ? context.inputs[0] : context.inputs[1];
        const float* in_right = context.inputs[1] != nullptr ? context.inputs[1] : in_left;
        if (in_left == nullptr) {
            in_left = silence_.data();
            in_right = silence_.data();
        }

        const bool bypassed = parameter(kBypass) >= 0.5f;
        if (plugin_ == nullptr || bypassed) {
            std::copy_n(in_left, frames, out_left);
            std::copy_n(in_right, frames, out_right);
            return;
        }

        const float mix = parameter(kMix);
        const bool needs_dry = mix < 1.0f;
        if (needs_dry) {
            std::copy_n(in_left, frames, dry_left_.data());
            std::copy_n(in_right, frames, dry_right_.data());
        }

        for (int slot = 0; slot < kSlotCount; ++slot) {
            const float value = parameter(kFirstSlot + slot);
            if (value != sent_[static_cast<std::size_t>(slot)]) {
                sent_[static_cast<std::size_t>(slot)] = value;
                plugin_->set_control(slot, value);
            }
        }

        const float* inputs[2] = {in_left, in_right};
        float* outputs[2] = {out_left, out_right};
        plugin_->process(inputs, 2, outputs, 2, frames);

        if (needs_dry) {
            const float dry = 1.0f - mix;
            for (int i = 0; i < frames; ++i) {
                out_left[i] = out_left[i] * mix + dry_left_[static_cast<std::size_t>(i)] * dry;
                out_right[i] = out_right[i] * mix + dry_right_[static_cast<std::size_t>(i)] * dry;
            }
        }
    }

private:
    HostedPluginInstance* plugin_ = nullptr;
    std::vector<float> silence_;
    std::vector<float> dry_left_;
    std::vector<float> dry_right_;
    std::array<float, kSlotCount> sent_{};
};

}  // namespace

const NodeTypeDescriptor kPluginEffect = {
    "PluginEffect",
    "Plugin Effect",
    "Effects",
    "Plays audio through a VST3 or CLAP plugin installed on this machine.",
    "plugin|vst|vst3|clap|effect|external|third party|reverb|somebody else's|host",
    {kInputs, 2},
    {kOutputs, 2},
    {kParameters, 18},
    // A plugin may hold a delay line of any length, which is exactly the property that
    // makes a feedback path through it well defined.
    true,
    NodeRole::Processor,
    false,
    // Cost is unknowable: it belongs to a plugin nobody here wrote. These are a placeholder
    // that keeps the board estimator from reading zero and concluding the node is free.
    {4.0f, 256, 0},
    []() -> std::unique_ptr<DspNode> { return std::make_unique<PluginEffectNode>(); },
    // The one node in the registry that cannot run everywhere.
    true,
};

}  // namespace nodes
}  // namespace soundgraph
