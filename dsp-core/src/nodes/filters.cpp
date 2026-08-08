// Filters and time-based effects.
#include <cmath>
#include <vector>

#include "dsp_math.h"
#include "nodes/node_types.h"

namespace soundgraph {
namespace nodes {
namespace {

// ---------------------------------------------------------------------------------
// State variable filter
//
// Topology-preserving transform SVF (Zavalishin / Cytomic form). Chosen over the classic
// Chamberlin design because it stays stable as cutoff approaches Nyquist, which matters
// when an LFO is sweeping the cutoff during a live demo.
//
// Coefficients are recomputed once per block rather than per sample. At 64 frames that is
// a 750 Hz update rate — smooth for any LFO — and it keeps a transcendental out of the
// inner loop, which is what would hurt on ESP32. See docs/known-issues.md.
// ---------------------------------------------------------------------------------

constexpr const char* kFilterModeLabels[] = {"lowpass", "highpass", "bandpass", "notch"};

constexpr PortDescriptor kFilterInputs[] = {
    {"in", SignalType::Audio, "", true, true, "Signal to filter."},
    {"cutoff", SignalType::Control, "Hz", false, false,
     "Cutoff in hertz. Replaces the cutoff parameter while connected."},
    {"cutoff_mod", SignalType::Control, "octaves", false, false,
     "Shifts the cutoff in octaves. Connect an LFO here for a sweep that stays musical."},
    {"resonance", SignalType::Control, "", false, false,
     "Resonance, 0 to 1. Replaces the resonance parameter while connected."},
};

constexpr PortDescriptor kFilterOutputs[] = {
    {"out", SignalType::Audio, "", false, false, "Filtered signal."},
};

constexpr ParameterDescriptor kFilterParameters[] = {
    {"cutoff", "Hz", 20.0f, 20000.0f, 1000.0f, Scaling::Exponential,
     "The frequency the filter turns around.", nullptr, 0},
    {"resonance", "", 0.0f, 1.0f, 0.2f, Scaling::Linear,
     "Emphasis at the cutoff. High values whistle.", nullptr, 0},
    {"mode", "", 0.0f, 3.0f, 0.0f, Scaling::Linear,
     "Which part of the spectrum to keep.", kFilterModeLabels, 4},
    {"cutoff_sweep", "octaves/s", -20.0f, 20.0f, 0.0f, Scaling::Linear,
     "How fast the cutoff moves on its own, without an LFO or an envelope. Negative "
     "closes the filter as the sound plays, positive opens it.", nullptr, 0},
};

class StateVariableFilterNode final : public DspNode {
public:
    enum Param { kCutoff = 0, kResonance = 1, kMode = 2, kCutoffSweep = 3 };

    void prepare(const PrepareContext& context) override {
        sample_rate_ = static_cast<float>(context.sample_rate);
        reset();
    }

    void reset() override {
        ic1_ = 0.0f;
        ic2_ = 0.0f;
        swept_octaves_ = 0.0f;
    }

    void process(const ProcessContext& context) override {
        const float* in = context.inputs[0];
        const float* cutoff_in = context.inputs[1];
        const float* cutoff_mod_in = context.inputs[2];
        const float* resonance_in = context.inputs[3];
        float* out = context.outputs[0];

        if (in == nullptr) {
            for (int i = 0; i < context.frames; ++i) {
                out[i] = 0.0f;
            }
            return;
        }

        // Modulation is sampled at the start of the block; see the note above.
        float cutoff = cutoff_in != nullptr ? cutoff_in[0] : parameter(kCutoff);
        if (cutoff_mod_in != nullptr) {
            cutoff *= std::pow(2.0f, cutoff_mod_in[0]);
        }
        // The sweep advances once per block, for the same reason the coefficients are
        // computed once per block: it keeps a transcendental out of the inner loop, which
        // is what would cost on ESP32. At 64 frames that is a 750 Hz update rate.
        const float sweep = parameter(kCutoffSweep);
        if (sweep != 0.0f) {
            cutoff *= std::pow(2.0f, swept_octaves_);
            swept_octaves_ += sweep * static_cast<float>(context.frames) / sample_rate_;
        }
        cutoff = dsp::clampf(cutoff, 10.0f, sample_rate_ * 0.45f);

        float resonance = resonance_in != nullptr ? resonance_in[0] : parameter(kResonance);
        resonance = dsp::clampf(resonance, 0.0f, 1.0f);

        // Map 0..1 onto damping. 2.0 is heavily damped, 0.05 is nearly self-oscillating.
        const float k = 2.0f - 1.95f * resonance;

        const float g = std::tan(dsp::kPi * cutoff / sample_rate_);
        const float a1 = 1.0f / (1.0f + g * (g + k));
        const float a2 = g * a1;
        const float a3 = g * a2;

        const int mode = static_cast<int>(parameter(kMode) + 0.5f);

        for (int i = 0; i < context.frames; ++i) {
            const float input = in[i];
            const float v3 = input - ic2_;
            const float v1 = a1 * ic1_ + a2 * v3;
            const float v2 = ic2_ + a2 * ic1_ + a3 * v3;
            ic1_ = 2.0f * v1 - ic1_;
            ic2_ = 2.0f * v2 - ic2_;

            switch (mode) {
                case 0: out[i] = v2; break;                       // lowpass
                case 1: out[i] = input - k * v1 - v2; break;      // highpass
                case 2: out[i] = v1; break;                       // bandpass
                default: out[i] = input - k * v1; break;          // notch
            }
        }
    }

private:
    float sample_rate_ = 48000.0f;
    float ic1_ = 0.0f;
    float ic2_ = 0.0f;
    float swept_octaves_ = 0.0f;
};

// ---------------------------------------------------------------------------------
// One-pole filter
//
// Six decibels per octave, where StateVariableFilter is twelve. A gentler slope is not a
// worse filter, it is a different tool: it thins or warms a sound without carving a hole
// in it, and it is what most hardware puts in front of an output to block DC.
//
// The two are worth having side by side because the difference is large where it matters
// most — far from the cutoff. Two octaves below a highpass, one pole takes 12 dB off and
// two poles take 24. That gap is the whole of the remaining error on sfxr's hit-hurt
// sounds, which spend most of their length at a frequency floor far below their highpass.
//
// The highpass is the DC-blocker form, y = r*(y + x - x_prev), which is the same structure
// sfxr uses and the standard way to write a one-pole highpass without a subtraction that
// loses precision at low cutoffs.
// ---------------------------------------------------------------------------------

constexpr const char* kOnePoleModeLabels[] = {"lowpass", "highpass"};

constexpr PortDescriptor kOnePoleInputs[] = {
    {"in", SignalType::Audio, "", true, true, "Signal to filter."},
    {"cutoff", SignalType::Control, "Hz", false, false,
     "Cutoff in hertz. Replaces the cutoff parameter while connected."},
};

constexpr PortDescriptor kOnePoleOutputs[] = {
    {"out", SignalType::Audio, "", false, false, "Filtered signal."},
};

constexpr ParameterDescriptor kOnePoleParameters[] = {
    {"cutoff", "Hz", 1.0f, 20000.0f, 1000.0f, Scaling::Exponential,
     "The frequency the filter turns around.", nullptr, 0},
    {"mode", "", 0.0f, 1.0f, 0.0f, Scaling::Linear,
     "Which side of the cutoff to keep.", kOnePoleModeLabels, 2},
    {"cutoff_sweep", "octaves/s", -20.0f, 20.0f, 0.0f, Scaling::Linear,
     "How fast the cutoff moves on its own.", nullptr, 0},
};

class OnePoleFilterNode final : public DspNode {
public:
    enum Param { kCutoff = 0, kMode = 1, kCutoffSweep = 2 };

    void prepare(const PrepareContext& context) override {
        sample_rate_ = static_cast<float>(context.sample_rate);
        reset();
    }

    void reset() override {
        state_ = 0.0f;
        previous_input_ = 0.0f;
        swept_octaves_ = 0.0f;
    }

    void process(const ProcessContext& context) override {
        const float* in = context.inputs[0];
        const float* cutoff_in = context.inputs[1];
        float* out = context.outputs[0];

        if (in == nullptr) {
            for (int i = 0; i < context.frames; ++i) {
                out[i] = 0.0f;
            }
            return;
        }

        float cutoff = cutoff_in != nullptr ? cutoff_in[0] : parameter(kCutoff);
        const float sweep = parameter(kCutoffSweep);
        if (sweep != 0.0f) {
            cutoff *= std::pow(2.0f, swept_octaves_);
            swept_octaves_ += sweep * static_cast<float>(context.frames) / sample_rate_;
        }
        cutoff = dsp::clampf(cutoff, 0.1f, sample_rate_ * 0.45f);

        // One coefficient per block, as the state variable filter does, and for the same
        // reason: it keeps the exponential out of the inner loop.
        const float w = dsp::kTwoPi * cutoff / sample_rate_;
        const float r = std::exp(-w);

        if (static_cast<int>(parameter(kMode) + 0.5f) == 0) {
            const float a = 1.0f - r;
            for (int i = 0; i < context.frames; ++i) {
                state_ += (in[i] - state_) * a;
                out[i] = state_;
            }
        } else {
            for (int i = 0; i < context.frames; ++i) {
                state_ = r * (state_ + in[i] - previous_input_);
                previous_input_ = in[i];
                out[i] = state_;
            }
        }
    }

private:
    float sample_rate_ = 48000.0f;
    float state_ = 0.0f;
    float previous_input_ = 0.0f;
    float swept_octaves_ = 0.0f;
};

// ---------------------------------------------------------------------------------
// Delay
//
// The only node that currently breaks a feedback loop. A cycle through anything else is
// a validation error rather than a silent reordering — see docs/decisions.md.
// ---------------------------------------------------------------------------------

constexpr float kMaxDelaySeconds = 2.0f;

constexpr PortDescriptor kDelayInputs[] = {
    {"in", SignalType::Audio, "", true, true, "Signal to delay."},
    {"time", SignalType::Control, "s", false, false,
     "Delay time in seconds. Replaces the time parameter while connected."},
    {"feedback", SignalType::Control, "", false, false,
     "Feedback amount, 0 to 0.99. Replaces the feedback parameter while connected."},
};

constexpr PortDescriptor kDelayOutputs[] = {
    {"out", SignalType::Audio, "", false, false, "Dry and delayed signal, per the mix parameter."},
};

constexpr ParameterDescriptor kDelayParameters[] = {
    {"time", "s", 0.001f, kMaxDelaySeconds, 0.25f, Scaling::Exponential,
     "How long until the echo returns.", nullptr, 0},
    {"feedback", "", 0.0f, 0.99f, 0.35f, Scaling::Linear,
     "How much of the echo is fed back in. Higher values repeat for longer.", nullptr, 0},
    {"mix", "", 0.0f, 1.0f, 0.35f, Scaling::Linear,
     "0 is dry only, 1 is delayed only.", nullptr, 0},
};

class DelayNode final : public DspNode {
public:
    enum Param { kTime = 0, kFeedback = 1, kMix = 2 };

    void prepare(const PrepareContext& context) override {
        sample_rate_ = static_cast<float>(context.sample_rate);
        // Allocation happens here and nowhere else. Sized for the maximum delay time so
        // that turning the time knob never reallocates.
        const int capacity = static_cast<int>(sample_rate_ * kMaxDelaySeconds) + 4;
        line_.assign(static_cast<std::size_t>(capacity), 0.0f);
        write_index_ = 0;
    }

    void reset() override {
        for (float& sample : line_) {
            sample = 0.0f;
        }
        write_index_ = 0;
    }

    void process(const ProcessContext& context) override {
        const float* in = context.inputs[0];
        const float* time_in = context.inputs[1];
        const float* feedback_in = context.inputs[2];
        float* out = context.outputs[0];

        if (line_.empty()) {
            for (int i = 0; i < context.frames; ++i) {
                out[i] = 0.0f;
            }
            return;
        }

        const int capacity = static_cast<int>(line_.size());
        const float mix = parameter(kMix);

        for (int i = 0; i < context.frames; ++i) {
            const float time = time_in != nullptr ? time_in[i] : parameter(kTime);
            const float feedback =
                dsp::clampf(feedback_in != nullptr ? feedback_in[i] : parameter(kFeedback), 0.0f, 0.99f);

            const float delay_samples =
                dsp::clampf(time, 0.001f, kMaxDelaySeconds) * sample_rate_;

            // Fractional read, linearly interpolated, so that moving the time knob glides
            // instead of clicking.
            float read_position = static_cast<float>(write_index_) - delay_samples;
            while (read_position < 0.0f) {
                read_position += static_cast<float>(capacity);
            }
            const int index0 = static_cast<int>(read_position);
            const int index1 = (index0 + 1) % capacity;
            const float fraction = read_position - static_cast<float>(index0);
            const float delayed = line_[static_cast<std::size_t>(index0 % capacity)] * (1.0f - fraction) +
                                  line_[static_cast<std::size_t>(index1)] * fraction;

            const float dry = in != nullptr ? in[i] : 0.0f;
            line_[static_cast<std::size_t>(write_index_)] = dry + delayed * feedback;
            write_index_ = (write_index_ + 1) % capacity;

            out[i] = dry * (1.0f - mix) + delayed * mix;
        }
    }

private:
    float sample_rate_ = 48000.0f;
    std::vector<float> line_;
    int write_index_ = 0;
};

template <typename T>
std::unique_ptr<DspNode> make() {
    return std::unique_ptr<DspNode>(new T());
}

}  // namespace

const NodeTypeDescriptor kStateVariableFilter = {
    "StateVariableFilter", "Filter", "Filters",
    "Removes part of the spectrum. Lowpass is the classic way to make a sound darker.",
    "filter|lowpass|low pass|highpass|high pass|bandpass|notch|svf|cutoff|resonance|"
    "remove high frequencies|remove low frequencies|make darker|make brighter|muffle|tone",
    Slice<PortDescriptor>(kFilterInputs),
    Slice<PortDescriptor>(kFilterOutputs),
    Slice<ParameterDescriptor>(kFilterParameters),
    false, NodeRole::Processor, false,
    ResourceCost{6.0f, 12, 0},
    &make<StateVariableFilterNode>,
};

const NodeTypeDescriptor kOnePoleFilter = {
    "OnePoleFilter", "One-pole Filter", "Filters",
    "A gentle filter, half the slope of the other one. Warms or thins without carving.",
    "one pole|onepole|6db|gentle filter|tilt|shelf|dc block|dc blocker|rumble|"
    "warm|thin|soften|take the edge off|remove rumble|high pass gentle|low pass gentle",
    Slice<PortDescriptor>(kOnePoleInputs),
    Slice<PortDescriptor>(kOnePoleOutputs),
    Slice<ParameterDescriptor>(kOnePoleParameters),
    false, NodeRole::Processor, false,
    ResourceCost{2.5f, 16, 0},
    &make<OnePoleFilterNode>,
};

const NodeTypeDescriptor kDelay = {
    "Delay", "Delay", "Time",
    "Repeats the signal after a set time. Feed it back for echoes.",
    "delay|echo|repeat|slapback|feedback|reverb-ish|space|doubling",
    Slice<PortDescriptor>(kDelayInputs),
    Slice<PortDescriptor>(kDelayOutputs),
    Slice<ParameterDescriptor>(kDelayParameters),
    true, NodeRole::Processor, false,
    ResourceCost{5.0f, 16, static_cast<int>(48000 * kMaxDelaySeconds * 4)},
    &make<DelayNode>,
};

}  // namespace nodes
}  // namespace soundgraph
