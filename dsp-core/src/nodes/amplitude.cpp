// Amplitude shaping and arithmetic.
#include <cmath>

#include "dsp_math.h"
#include "nodes/node_types.h"

namespace soundgraph {
namespace nodes {
namespace {

// ---------------------------------------------------------------------------------
// Gain
// ---------------------------------------------------------------------------------

constexpr PortDescriptor kGainInputs[] = {
    {"in", SignalType::Audio, "", true, true, "Signal to scale."},
    {"gain", SignalType::Control, "", false, false,
     "Multiplied with the gain parameter. Connect an envelope here to shape the level."},
};

constexpr PortDescriptor kGainOutputs[] = {
    {"out", SignalType::Audio, "", false, false, "Scaled signal."},
};

constexpr ParameterDescriptor kGainParameters[] = {
    {"gain", "", 0.0f, 4.0f, 1.0f, Scaling::Logarithmic,
     "Linear level. 1 leaves the signal unchanged.", nullptr, 0},
};

class GainNode final : public DspNode {
public:
    void process(const ProcessContext& context) override {
        const float* in = context.inputs[0];
        const float* gain_in = context.inputs[1];
        float* out = context.outputs[0];
        const float gain = parameter(0);

        for (int i = 0; i < context.frames; ++i) {
            const float sample = in != nullptr ? in[i] : 0.0f;
            const float modulation = gain_in != nullptr ? gain_in[i] : 1.0f;
            out[i] = sample * gain * modulation;
        }
    }
};

// ---------------------------------------------------------------------------------
// Level
// ---------------------------------------------------------------------------------
// A port's own trim. This is what a module's Output seam becomes when it carries a
// level: expansion re-aims the cables through it, so the level a file sets on its
// out survives the file becoming a device. Gain with a control inlet is for shaping;
// this is the plain multiplier a jack's trim pot is.

constexpr PortDescriptor kLevelInputs[] = {
    {"in", SignalType::Audio, "", false, true, "Signal to trim; several sum."},
};

constexpr PortDescriptor kLevelOutputs[] = {
    {"out", SignalType::Audio, "", false, false, "Trimmed signal."},
};

constexpr ParameterDescriptor kLevelParameters[] = {
    {"level", "", 0.0f, 2.0f, 1.0f, Scaling::Logarithmic,
     "Linear level. 1 leaves the signal unchanged.", nullptr, 0},
};

class LevelNode final : public DspNode {
public:
    void process(const ProcessContext& context) override {
        const float* in = context.inputs[0];
        float* out = context.outputs[0];
        const float level = parameter(0);

        for (int i = 0; i < context.frames; ++i) {
            out[i] = (in != nullptr ? in[i] : 0.0f) * level;
        }
    }
};

// ---------------------------------------------------------------------------------
// StereoLevel
// ---------------------------------------------------------------------------------
// The two-channel trim: what a module's stereo Output seam becomes when it carries a
// level. One knob, two wires, and the channels never meet — the mono Level's summing
// inlet would fold left into right, which is exactly the collapse a stereo port
// exists to avoid.

constexpr PortDescriptor kStereoLevelInputs[] = {
    {"left", SignalType::Audio, "", false, true, "Left channel; several sum."},
    {"right", SignalType::Audio, "", false, true, "Right channel; several sum."},
};

constexpr PortDescriptor kStereoLevelOutputs[] = {
    {"left", SignalType::Audio, "", false, false, "Trimmed left channel."},
    {"right", SignalType::Audio, "", false, false, "Trimmed right channel."},
};

constexpr ParameterDescriptor kStereoLevelParameters[] = {
    {"level", "", 0.0f, 2.0f, 1.0f, Scaling::Logarithmic,
     "Linear level for both channels. 1 leaves the signal unchanged.", nullptr, 0},
};

class StereoLevelNode final : public DspNode {
public:
    void process(const ProcessContext& context) override {
        const float* left = context.inputs[0];
        const float* right = context.inputs[1];
        float* out_left = context.outputs[0];
        float* out_right = context.outputs[1];
        const float level = parameter(0);

        for (int i = 0; i < context.frames; ++i) {
            out_left[i] = (left != nullptr ? left[i] : 0.0f) * level;
            out_right[i] = (right != nullptr ? right[i] : 0.0f) * level;
        }
    }
};

// ---------------------------------------------------------------------------------
// Mixer
// ---------------------------------------------------------------------------------

constexpr PortDescriptor kMixerInputs[] = {
    {"in1", SignalType::Audio, "", false, true, "Channel 1."},
    {"in2", SignalType::Audio, "", false, true, "Channel 2."},
    {"in3", SignalType::Audio, "", false, true, "Channel 3."},
    {"in4", SignalType::Audio, "", false, true, "Channel 4."},
};

constexpr PortDescriptor kMixerOutputs[] = {
    {"out", SignalType::Audio, "", false, false, "Sum of the channels at their set levels."},
};

constexpr ParameterDescriptor kMixerParameters[] = {
    {"level1", "", 0.0f, 2.0f, 1.0f, Scaling::Logarithmic, "Channel 1 level.", nullptr, 0},
    {"level2", "", 0.0f, 2.0f, 1.0f, Scaling::Logarithmic, "Channel 2 level.", nullptr, 0},
    {"level3", "", 0.0f, 2.0f, 1.0f, Scaling::Logarithmic, "Channel 3 level.", nullptr, 0},
    {"level4", "", 0.0f, 2.0f, 1.0f, Scaling::Logarithmic, "Channel 4 level.", nullptr, 0},
};

class MixerNode final : public DspNode {
public:
    void process(const ProcessContext& context) override {
        float* out = context.outputs[0];
        for (int i = 0; i < context.frames; ++i) {
            out[i] = 0.0f;
        }
        for (int channel = 0; channel < 4; ++channel) {
            const float* in = context.inputs[channel];
            if (in == nullptr) {
                continue;
            }
            const float level = parameter(channel);
            for (int i = 0; i < context.frames; ++i) {
                out[i] += in[i] * level;
            }
        }
    }
};

// ---------------------------------------------------------------------------------
// ADSR
//
// Linear attack, exponential decay and release. The exponential segments are what make a
// synth envelope sound like a synth envelope; a linear decay reads as artificial.
// ---------------------------------------------------------------------------------

constexpr PortDescriptor kAdsrInputs[] = {
    {"gate", SignalType::Control, "", true, false,
     "Rises above 0.5 to start the note, falls below to release it."},
};

constexpr PortDescriptor kAdsrOutputs[] = {
    {"out", SignalType::Control, "", false, false, "Envelope level, 0 to 1."},
};

constexpr ParameterDescriptor kAdsrParameters[] = {
    {"attack", "s", 0.0f, 10.0f, 0.005f, Scaling::Exponential,
     "Time to reach full level after the note starts.", nullptr, 0},
    {"decay", "s", 0.0f, 10.0f, 0.120f, Scaling::Exponential,
     "Time to fall from full level to the sustain level.", nullptr, 0},
    {"sustain", "", 0.0f, 1.0f, 0.6f, Scaling::Linear,
     "Level held while the note is down.", nullptr, 0},
    {"release", "s", 0.0f, 10.0f, 0.250f, Scaling::Exponential,
     "Time to fall to silence after the note is let go.", nullptr, 0},
};

class AdsrNode final : public DspNode {
public:
    enum Param { kAttack = 0, kDecay = 1, kSustain = 2, kRelease = 3 };

    void prepare(const PrepareContext& context) override {
        sample_rate_ = static_cast<float>(context.sample_rate);
        reset();
    }

    void reset() override {
        stage_ = Stage::Idle;
        level_ = 0.0f;
        gate_open_ = false;
    }

    void process(const ProcessContext& context) override {
        const float* gate = context.inputs[0];
        float* out = context.outputs[0];

        const float attack_step = step_for(parameter(kAttack));
        const float decay_coefficient = coefficient_for(parameter(kDecay));
        const float release_coefficient = coefficient_for(parameter(kRelease));
        const float sustain = parameter(kSustain);

        for (int i = 0; i < context.frames; ++i) {
            const bool gate_now = gate != nullptr && gate[i] >= 0.5f;
            if (gate_now && !gate_open_) {
                stage_ = Stage::Attack;
            } else if (!gate_now && gate_open_) {
                stage_ = Stage::Release;
            }
            gate_open_ = gate_now;

            switch (stage_) {
                case Stage::Idle:
                    level_ = 0.0f;
                    break;
                case Stage::Attack:
                    level_ += attack_step;
                    if (level_ >= 1.0f) {
                        level_ = 1.0f;
                        stage_ = Stage::Decay;
                    }
                    break;
                case Stage::Decay:
                    level_ = sustain + (level_ - sustain) * decay_coefficient;
                    if (std::fabs(level_ - sustain) < 1.0e-4f) {
                        level_ = sustain;
                        stage_ = Stage::Sustain;
                    }
                    break;
                case Stage::Sustain:
                    level_ = sustain;
                    break;
                case Stage::Release:
                    level_ *= release_coefficient;
                    if (level_ < 1.0e-5f) {
                        level_ = 0.0f;
                        stage_ = Stage::Idle;
                    }
                    break;
            }
            out[i] = level_;
        }
    }

private:
    enum class Stage { Idle, Attack, Decay, Sustain, Release };

    float step_for(float seconds) const {
        const float samples = seconds * sample_rate_;
        return samples < 1.0f ? 1.0f : 1.0f / samples;
    }

    // Decays to roughly -60 dB of the remaining distance over `seconds`.
    float coefficient_for(float seconds) const {
        const float samples = seconds * sample_rate_;
        if (samples < 1.0f) {
            return 0.0f;
        }
        return std::exp(-6.907755f / samples);
    }

    float sample_rate_ = 48000.0f;
    Stage stage_ = Stage::Idle;
    float level_ = 0.0f;
    bool gate_open_ = false;
};

// ---------------------------------------------------------------------------------
// Arithmetic
// ---------------------------------------------------------------------------------

constexpr PortDescriptor kBinaryInputs[] = {
    {"a", SignalType::Control, "", false, true, "First input."},
    {"b", SignalType::Control, "", false, true,
     "Second input. Falls back to the parameter below while unconnected."},
};

constexpr PortDescriptor kControlOutput[] = {
    {"out", SignalType::Control, "", false, false, "Result."},
};

constexpr ParameterDescriptor kAddParameters[] = {
    {"offset", "", -100000.0f, 100000.0f, 0.0f, Scaling::Linear,
     "Used in place of the b input while it is unconnected.", nullptr, 0},
};

constexpr ParameterDescriptor kMultiplyParameters[] = {
    {"factor", "", -100000.0f, 100000.0f, 1.0f, Scaling::Linear,
     "Used in place of the b input while it is unconnected.", nullptr, 0},
};

class AddNode final : public DspNode {
public:
    void process(const ProcessContext& context) override {
        const float* a = context.inputs[0];
        const float* b = context.inputs[1];
        float* out = context.outputs[0];
        const float fallback = parameter(0);
        for (int i = 0; i < context.frames; ++i) {
            out[i] = (a != nullptr ? a[i] : 0.0f) + (b != nullptr ? b[i] : fallback);
        }
    }
};

class MultiplyNode final : public DspNode {
public:
    void process(const ProcessContext& context) override {
        const float* a = context.inputs[0];
        const float* b = context.inputs[1];
        float* out = context.outputs[0];
        const float fallback = parameter(0);
        for (int i = 0; i < context.frames; ++i) {
            out[i] = (a != nullptr ? a[i] : 0.0f) * (b != nullptr ? b[i] : fallback);
        }
    }
};

template <typename T>
std::unique_ptr<DspNode> make() {
    return std::unique_ptr<DspNode>(new T());
}

}  // namespace

const NodeTypeDescriptor kGain = {
    "Gain", "Gain", "Amplitude",
    "Makes a signal louder or quieter. Connect an envelope to shape it over time.",
    "gain|volume|level|amplitude|amp|vca|make quieter|make louder|turn down|turn up",
    Slice<PortDescriptor>(kGainInputs),
    Slice<PortDescriptor>(kGainOutputs),
    Slice<ParameterDescriptor>(kGainParameters),
    false, NodeRole::Processor, false,
    ResourceCost{1.0f, 0, 0},
    &make<GainNode>,
};

const NodeTypeDescriptor kLevel = {
    "Level", "Level", "Amplitude",
    "Trims a signal by a fixed amount. What a port's own level becomes in the flat graph.",
    "level|trim|attenuate|port level|output level|master",
    Slice<PortDescriptor>(kLevelInputs),
    Slice<PortDescriptor>(kLevelOutputs),
    Slice<ParameterDescriptor>(kLevelParameters),
    false, NodeRole::Processor, false,
    ResourceCost{1.0f, 0, 0},
    &make<LevelNode>,
};

const NodeTypeDescriptor kStereoLevel = {
    "StereoLevel", "Stereo Level", "Amplitude",
    "Trims a stereo pair by one fixed amount, keeping the channels apart.",
    "stereo level|stereo trim|pair|balance level|output level",
    Slice<PortDescriptor>(kStereoLevelInputs),
    Slice<PortDescriptor>(kStereoLevelOutputs),
    Slice<ParameterDescriptor>(kStereoLevelParameters),
    false, NodeRole::Processor, false,
    ResourceCost{1.0f, 0, 0},
    &make<StereoLevelNode>,
};

const NodeTypeDescriptor kMixer = {
    "Mixer", "Mixer", "Amplitude",
    "Combines up to four signals at independent levels.",
    "mixer|mix|sum|combine|blend|add signals|layer",
    Slice<PortDescriptor>(kMixerInputs),
    Slice<PortDescriptor>(kMixerOutputs),
    Slice<ParameterDescriptor>(kMixerParameters),
    false, NodeRole::Processor, false,
    ResourceCost{2.0f, 0, 0},
    &make<MixerNode>,
};

const NodeTypeDescriptor kAdsr = {
    "ADSR", "Envelope", "Modulation",
    "Shapes how a sound starts, holds and fades when a note is played.",
    "adsr|envelope|eg|attack|decay|sustain|release|fade in|fade out|pluck|swell|shape",
    Slice<PortDescriptor>(kAdsrInputs),
    Slice<PortDescriptor>(kAdsrOutputs),
    Slice<ParameterDescriptor>(kAdsrParameters),
    false, NodeRole::Processor, false,
    ResourceCost{2.0f, 12, 0},
    &make<AdsrNode>,
};

const NodeTypeDescriptor kAdd = {
    "Add", "Add", "Maths",
    "Adds two control signals together.",
    "add|plus|sum|offset|combine controls",
    Slice<PortDescriptor>(kBinaryInputs),
    Slice<PortDescriptor>(kControlOutput),
    Slice<ParameterDescriptor>(kAddParameters),
    false, NodeRole::Processor, false,
    ResourceCost{1.0f, 0, 0},
    &make<AddNode>,
};

const NodeTypeDescriptor kMultiply = {
    "Multiply", "Multiply", "Maths",
    "Multiplies two control signals. Use it to scale modulation depth.",
    "multiply|times|scale|depth|attenuate|ring|product",
    Slice<PortDescriptor>(kBinaryInputs),
    Slice<PortDescriptor>(kControlOutput),
    Slice<ParameterDescriptor>(kMultiplyParameters),
    false, NodeRole::Processor, false,
    ResourceCost{1.0f, 0, 0},
    &make<MultiplyNode>,
};

}  // namespace nodes
}  // namespace soundgraph
