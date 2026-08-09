// Signal sources: oscillators, noise, LFO, constant.
#include <cmath>

#include "dsp_math.h"
#include "nodes/node_types.h"

namespace soundgraph {
namespace nodes {
namespace {

// ---------------------------------------------------------------------------------
// Oscillators
//
// Every oscillator shares the same pitch model, so that connecting a note source to any
// of them behaves identically:
//
//   frequency input connected -> it replaces the frequency parameter
//   fm input connected        -> multiplies by 2^fm, i.e. it is additive in octaves
//
// Modulation that is additive in octaves rather than in hertz is what makes a fixed
// vibrato depth sound the same at every pitch.
// ---------------------------------------------------------------------------------

constexpr int kOscFrequency = 0;

constexpr PortDescriptor kOscInputs[] = {
    {"frequency", SignalType::Control, "Hz", false, false,
     "Pitch in hertz. Replaces the frequency parameter while connected."},
    {"fm", SignalType::Control, "octaves", false, false,
     "Frequency modulation in octaves. 1.0 is an octave up, -1.0 an octave down."},
};

constexpr PortDescriptor kAudioOut[] = {
    {"out", SignalType::Audio, "", false, false, "Oscillator output, -1 to 1."},
};

constexpr ParameterDescriptor kOscParameters[] = {
    {"frequency", "Hz", 0.01f, 20000.0f, 440.0f, Scaling::Exponential,
     "Pitch when nothing is connected to the frequency input.", nullptr, 0},
};

class OscillatorBase : public DspNode {
public:
    void prepare(const PrepareContext& context) override {
        sample_rate_ = static_cast<float>(context.sample_rate);
        reset();
    }

    void reset() override { phase_ = 0.0f; }

    void process(const ProcessContext& context) override {
        const float* frequency_in = context.inputs[0];
        const float* fm_in = context.inputs[1];
        float* out = context.outputs[0];
        const float base_frequency = parameter(kOscFrequency);
        const float nyquist = sample_rate_ * 0.5f;

        for (int i = 0; i < context.frames; ++i) {
            float frequency = frequency_in != nullptr ? frequency_in[i] : base_frequency;
            if (fm_in != nullptr) {
                frequency *= std::pow(2.0f, fm_in[i]);
            }
            frequency = dsp::clampf(frequency, 0.0f, nyquist);

            const float increment = frequency / sample_rate_;
            out[i] = render(phase_, increment);
            phase_ = dsp::wrap01(phase_ + increment);
        }
    }

protected:
    virtual float render(float phase, float increment) = 0;

    float sample_rate_ = 48000.0f;
    float phase_ = 0.0f;
};

class SineOscillator final : public OscillatorBase {
protected:
    float render(float phase, float) override { return std::sin(dsp::kTwoPi * phase); }
};

class SawOscillator final : public OscillatorBase {
protected:
    float render(float phase, float increment) override {
        return (2.0f * phase - 1.0f) - dsp::poly_blep(phase, increment);
    }
};

class SquareOscillator final : public OscillatorBase {
public:
    static constexpr int kPulseWidth = 1;
    static constexpr int kPulseWidthSweep = 2;

    void reset() override {
        OscillatorBase::reset();
        swept_width_ = kUnstarted;
    }

protected:
    float render(float phase, float increment) override {
        const float sweep = parameter(kPulseWidthSweep);

        // With no sweep the width is read straight from the parameter, exactly as before
        // this sweep existed. That is not only simpler: it means every patch that does not
        // use the sweep renders the same samples it always did, which the golden vectors
        // check. A swept width has to carry state, and state that turning a knob cannot
        // reach is state that makes the knob feel broken.
        float width;
        if (sweep == 0.0f) {
            width = parameter(kPulseWidth);
            swept_width_ = kUnstarted;
        } else {
            if (swept_width_ == kUnstarted) {
                swept_width_ = parameter(kPulseWidth);
            }
            width = swept_width_;
            swept_width_ = dsp::clampf(swept_width_ + sweep / sample_rate_, 0.01f, 0.99f);
        }

        width = dsp::clampf(width, 0.01f, 0.99f);
        float value = phase < width ? 1.0f : -1.0f;
        value += dsp::poly_blep(phase, increment);
        value -= dsp::poly_blep(dsp::wrap01(phase + (1.0f - width)), increment);
        return value;
    }

private:
    static constexpr float kUnstarted = -1.0f;
    float swept_width_ = kUnstarted;
};

// ---------------------------------------------------------------------------------
// Noise oscillator
//
// Noise with a pitch. A short table of random values is read once per cycle and thrown
// away, so the sound has a definite period — a rasp rather than a hiss — and follows a
// frequency input like any other oscillator.
//
// This is what a retro sound chip's noise channel does, and what sfxr calls its noise
// waveform. Plain white noise cannot stand in for it: white noise has a flat spectrum and
// no pitch, and this has a harmonic comb at the oscillator's frequency. Reaching for
// `Noise` when a game sound wants this is the difference between an explosion and a hiss.
//
// The table is refilled every cycle rather than held, which is what stops it turning into
// a buzzing fixed waveform. Fewer steps make it coarser and more tonal.
// ---------------------------------------------------------------------------------

class NoiseOscillator final : public OscillatorBase {
public:
    static constexpr int kSteps = 1;
    static constexpr int kSeed = 2;
    static constexpr int kMaxSteps = 64;

    void reset() override {
        OscillatorBase::reset();
        random_.seed(static_cast<unsigned int>(parameter(kSeed)));
        last_phase_ = 1.0f;  // forces a refill on the first sample
        for (float& value : table_) {
            value = 0.0f;
        }
    }

protected:
    float render(float phase, float) override {
        const int steps = static_cast<int>(dsp::clampf(parameter(kSteps), 2.0f,
                                                       static_cast<float>(kMaxSteps)));
        // A wrap is the only signal that a cycle finished: render() is handed the phase
        // before it advances, so a phase that went backwards means it passed 1.
        if (phase < last_phase_) {
            for (int i = 0; i < steps; ++i) {
                table_[i] = random_.next_bipolar();
            }
        }
        last_phase_ = phase;

        int index = static_cast<int>(phase * static_cast<float>(steps));
        if (index < 0) index = 0;
        if (index >= steps) index = steps - 1;
        return table_[index];
    }

    void on_parameter_changed(int index) override {
        if (index == kSeed) {
            random_.seed(static_cast<unsigned int>(parameter(kSeed)));
        }
    }

private:
    dsp::Xorshift32 random_;
    float table_[kMaxSteps] = {0.0f};
    float last_phase_ = 1.0f;
};

constexpr ParameterDescriptor kNoiseOscillatorParameters[] = {
    {"frequency", "Hz", 0.01f, 20000.0f, 440.0f, Scaling::Exponential,
     "Pitch when nothing is connected to the frequency input.", nullptr, 0},
    {"steps", "", 2.0f, 64.0f, 32.0f, Scaling::Linear,
     "How many random values make up one cycle. Fewer is coarser and more tonal; 32 is "
     "what most retro sound chips used.", nullptr, 0},
    {"seed", "", 1.0f, 2147483000.0f, 12345.0f, Scaling::Linear,
     "Fixes the random sequence so a patch renders identically every time.", nullptr, 0},
};

constexpr ParameterDescriptor kSquareParameters[] = {
    {"frequency", "Hz", 0.01f, 20000.0f, 440.0f, Scaling::Exponential,
     "Pitch when nothing is connected to the frequency input.", nullptr, 0},
    {"pulse_width", "", 0.01f, 0.99f, 0.5f, Scaling::Linear,
     "Fraction of each cycle spent high. 0.5 is a square wave.", nullptr, 0},
    {"pulse_width_sweep", "1/s", -4.0f, 4.0f, 0.0f, Scaling::Linear,
     "How fast the width moves. Sweeping it thins or fattens the tone as the sound "
     "plays; zero holds it still.", nullptr, 0},
};

// ---------------------------------------------------------------------------------
// Noise
// ---------------------------------------------------------------------------------

constexpr const char* kNoiseColourLabels[] = {"white", "pink"};

constexpr ParameterDescriptor kNoiseParameters[] = {
    {"colour", "", 0.0f, 1.0f, 0.0f, Scaling::Linear,
     "White is flat; pink falls off 3 dB per octave and sounds more natural.",
     kNoiseColourLabels, 2},
    {"seed", "", 1.0f, 2147483000.0f, 12345.0f, Scaling::Linear,
     "Fixes the random sequence so a patch renders identically every time.", nullptr, 0},
};

class NoiseNode final : public DspNode {
public:
    enum Param { kColour = 0, kSeed = 1 };

    void prepare(const PrepareContext&) override { reset(); }

    void reset() override {
        random_.seed(static_cast<unsigned int>(parameter(kSeed)));
        for (float& state : pink_state_) {
            state = 0.0f;
        }
    }

    void process(const ProcessContext& context) override {
        float* out = context.outputs[0];
        const bool pink = parameter(kColour) >= 0.5f;

        for (int i = 0; i < context.frames; ++i) {
            const float white = random_.next_bipolar();
            if (!pink) {
                out[i] = white;
                continue;
            }
            // Paul Kellet's economy pink filter: three one-poles, roughly -3 dB/octave
            // across the audible band.
            pink_state_[0] = 0.99765f * pink_state_[0] + white * 0.0990460f;
            pink_state_[1] = 0.96300f * pink_state_[1] + white * 0.2965164f;
            pink_state_[2] = 0.57000f * pink_state_[2] + white * 1.0526913f;
            out[i] = (pink_state_[0] + pink_state_[1] + pink_state_[2] + white * 0.1848f) * 0.25f;
        }
    }

protected:
    void on_parameter_changed(int index) override {
        if (index == kSeed) {
            random_.seed(static_cast<unsigned int>(parameter(kSeed)));
        }
    }

private:
    dsp::Xorshift32 random_;
    float pink_state_[3] = {0.0f, 0.0f, 0.0f};
};

// ---------------------------------------------------------------------------------
// LFO
// ---------------------------------------------------------------------------------

constexpr const char* kLfoShapeLabels[] = {"sine", "triangle", "saw", "square", "random"};

constexpr PortDescriptor kLfoInputs[] = {
    {"rate", SignalType::Control, "Hz", false, false,
     "Speed in hertz. Replaces the rate parameter while connected."},
};

constexpr PortDescriptor kLfoOutputs[] = {
    {"out", SignalType::Control, "", false, false,
     "offset + amount x shape. With the defaults this swings between -1 and 1."},
};

constexpr ParameterDescriptor kLfoParameters[] = {
    {"rate", "Hz", 0.01f, 200.0f, 2.0f, Scaling::Exponential, "Cycles per second.", nullptr, 0},
    {"shape", "", 0.0f, 4.0f, 0.0f, Scaling::Linear, "Waveform.", kLfoShapeLabels, 5},
    {"amount", "", 0.0f, 1000.0f, 1.0f, Scaling::Linear,
     "Scales the output. Set this in the unit of whatever you are modulating.", nullptr, 0},
    {"offset", "", -1000.0f, 1000.0f, 0.0f, Scaling::Linear,
     "Added to the output. Use it to make a bipolar shape unipolar.", nullptr, 0},
};

class LfoNode final : public DspNode {
public:
    enum Param { kRate = 0, kShape = 1, kAmount = 2, kOffset = 3 };

    void prepare(const PrepareContext& context) override {
        sample_rate_ = static_cast<float>(context.sample_rate);
        reset();
    }

    void reset() override {
        phase_ = 0.0f;
        sample_and_hold_ = 0.0f;
        random_.seed(0x5EED1234u);
    }

    void process(const ProcessContext& context) override {
        const float* rate_in = context.inputs[0];
        float* out = context.outputs[0];
        const int shape = static_cast<int>(parameter(kShape) + 0.5f);
        const float amount = parameter(kAmount);
        const float offset = parameter(kOffset);

        for (int i = 0; i < context.frames; ++i) {
            const float rate = rate_in != nullptr ? rate_in[i] : parameter(kRate);
            const float increment = dsp::clampf(rate, 0.0f, sample_rate_ * 0.5f) / sample_rate_;

            out[i] = offset + amount * shape_value(shape, increment);

            const float next_phase = phase_ + increment;
            if (shape == 4 && next_phase >= 1.0f) {
                sample_and_hold_ = random_.next_bipolar();
            }
            phase_ = dsp::wrap01(next_phase);
        }
    }

private:
    float shape_value(int shape, float increment) {
        switch (shape) {
            case 0: return std::sin(dsp::kTwoPi * phase_);
            case 1: return 4.0f * std::fabs(phase_ - 0.5f) - 1.0f;
            case 2: return (2.0f * phase_ - 1.0f) - dsp::poly_blep(phase_, increment);
            case 3: return phase_ < 0.5f ? 1.0f : -1.0f;
            case 4: return sample_and_hold_;
            default: return 0.0f;
        }
    }

    float sample_rate_ = 48000.0f;
    float phase_ = 0.0f;
    float sample_and_hold_ = 0.0f;
    dsp::Xorshift32 random_{0x5EED1234u};
};

// ---------------------------------------------------------------------------------
// Constant
// ---------------------------------------------------------------------------------

constexpr PortDescriptor kConstantOutputs[] = {
    {"out", SignalType::Control, "", false, false, "The value, held forever."},
};

constexpr ParameterDescriptor kConstantParameters[] = {
    {"value", "", -100000.0f, 100000.0f, 1.0f, Scaling::Linear, "The value to output.", nullptr, 0},
};

class ConstantNode final : public DspNode {
public:
    void process(const ProcessContext& context) override {
        float* out = context.outputs[0];
        const float value = parameter(0);
        for (int i = 0; i < context.frames; ++i) {
            out[i] = value;
        }
    }
};

template <typename T>
std::unique_ptr<DspNode> make() {
    return std::unique_ptr<DspNode>(new T());
}

}  // namespace

const NodeTypeDescriptor kSineOscillator = {
    "SineOscillator", "Sine Oscillator", "Sources",
    "A pure tone with no harmonics.",
    "sine|sin|pure tone|test tone|simple wave|fundamental",
    Slice<PortDescriptor>(kOscInputs),
    Slice<PortDescriptor>(kAudioOut),
    Slice<ParameterDescriptor>(kOscParameters),
    false, NodeRole::Processor, false,
    ResourceCost{3.0f, 8, 0},
    &make<SineOscillator>,
};

const NodeTypeDescriptor kSawOscillator = {
    "SawOscillator", "Saw Oscillator", "Sources",
    "A bright, buzzy wave containing every harmonic. The classic synth starting point.",
    "saw|sawtooth|ramp|bright|buzzy|brass|strings|classic synth sound",
    Slice<PortDescriptor>(kOscInputs),
    Slice<PortDescriptor>(kAudioOut),
    Slice<ParameterDescriptor>(kOscParameters),
    false, NodeRole::Processor, false,
    ResourceCost{2.0f, 8, 0},
    &make<SawOscillator>,
};

const NodeTypeDescriptor kSquareOscillator = {
    "SquareOscillator", "Square Oscillator", "Sources",
    "A hollow, woody wave. Narrow the pulse width for a thinner, reedier tone.",
    "square|pulse|pwm|hollow|woody|reed|clarinet|chiptune|8 bit",
    Slice<PortDescriptor>(kOscInputs),
    Slice<PortDescriptor>(kAudioOut),
    Slice<ParameterDescriptor>(kSquareParameters),
    false, NodeRole::Processor, false,
    ResourceCost{2.5f, 8, 0},
    &make<SquareOscillator>,
};

const NodeTypeDescriptor kNoise = {
    "Noise", "Noise", "Sources",
    "Random signal. Use it for percussion, wind, breath and texture.",
    "noise|white|pink|hiss|wind|percussion|snare|random|texture",
    Slice<PortDescriptor>(),
    Slice<PortDescriptor>(kAudioOut),
    Slice<ParameterDescriptor>(kNoiseParameters),
    false, NodeRole::Processor, false,
    ResourceCost{1.5f, 20, 0},
    &make<NoiseNode>,
};

const NodeTypeDescriptor kNoiseOscillator = {
    "NoiseOscillator", "Noise Oscillator", "Sources",
    "Noise with a pitch. A rasp rather than a hiss — the retro sound-chip noise channel.",
    "noise oscillator|pitched noise|tuned noise|rasp|buzz|retro noise|chip noise|"
    "noise channel|nes noise|explosion|engine|growl|gritty|lo-fi noise",
    Slice<PortDescriptor>(kOscInputs),
    Slice<PortDescriptor>(kAudioOut),
    Slice<ParameterDescriptor>(kNoiseOscillatorParameters),
    false, NodeRole::Processor, false,
    ResourceCost{2.0f, 288, 0},
    &make<NoiseOscillator>,
};

const NodeTypeDescriptor kLfo = {
    "LFO", "LFO", "Modulation",
    "A slow wave for moving other controls: vibrato, tremolo, filter sweeps.",
    "lfo|low frequency oscillator|modulation|vibrato|tremolo|wobble|sweep|movement|slow",
    Slice<PortDescriptor>(kLfoInputs),
    Slice<PortDescriptor>(kLfoOutputs),
    Slice<ParameterDescriptor>(kLfoParameters),
    false, NodeRole::Processor, false,
    ResourceCost{3.0f, 16, 0},
    &make<LfoNode>,
};

const NodeTypeDescriptor kConstant = {
    "Constant", "Constant", "Modulation",
    "A fixed value. Useful for offsetting or scaling modulation.",
    "constant|fixed|value|number|offset|dc|bias",
    Slice<PortDescriptor>(),
    Slice<PortDescriptor>(kConstantOutputs),
    Slice<ParameterDescriptor>(kConstantParameters),
    false, NodeRole::Processor, false,
    ResourceCost{0.2f, 0, 0},
    &make<ConstantNode>,
};

}  // namespace nodes
}  // namespace soundgraph
