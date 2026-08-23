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
//   pm input connected        -> added to the phase being read, in cycles
//
// Modulation that is additive in octaves rather than in hertz is what makes a fixed
// vibrato depth sound the same at every pitch.
//
// `pm` is the other kind of modulation, and the distinction is the whole reason it
// exists as its own port: Yamaha-style FM — DX7, OPL, OPN, every "FM synth" anybody
// names — is *linear phase* modulation, and the sidebands that make it sound like FM
// come from that linearity. Routing a modulator into the exponential `fm` port gives
// vibrato at audio rate, which is a different (and much worse-behaved) spectrum. In
// cycles rather than radians because phase runs 0..1 throughout this codebase; a
// classic modulation index I in radians is I / 2pi cycles.
//
// The modulator does not advance the carrier's phase — it displaces where the wave is
// *read* this sample, and the free-running phase underneath is untouched. That is how
// the hardware behaves, and it is what keeps a silent modulator identical to no
// modulator at all.
// ---------------------------------------------------------------------------------

constexpr int kOscFrequency = 0;

constexpr PortDescriptor kOscInputs[] = {
    {"frequency", SignalType::Control, "Hz", false, false,
     "Pitch in hertz. Replaces the frequency parameter while connected."},
    {"fm", SignalType::Control, "octaves", false, false,
     "Frequency modulation in octaves. 1.0 is an octave up, -1.0 an octave down."},
    {"pm", SignalType::Audio, "cycles", false, false,
     "Phase modulation in cycles, added linearly. This is the FM of FM synthesis: "
     "feed another oscillator in here to make sidebands, not vibrato."},
};

constexpr PortDescriptor kAudioOut[] = {
    {"out", SignalType::Audio, "", false, false, "Oscillator output, -1 to 1."},
};

constexpr ParameterDescriptor kOscParameters[] = {
    {"frequency", "Hz", 0.01f, 20000.0f, 440.0f, Scaling::Exponential,
     "Pitch when nothing is connected to the frequency input.", nullptr, 0},
};

// The sine gets one thing the others do not: operator feedback, the oscillator phase-
// modulating itself. Every FM chip has it on exactly one operator per voice and it is
// where their bite comes from — a sine at feedback 0 is pure, and by 2 it has leaned
// most of the way to a saw. The two-sample average is the chip trick (OPL and OPN both
// do it): feeding back only the previous sample lets the loop lock into a period-two
// squeal, and averaging damps precisely that mode.
//
// Its own array rather than an entry in kOscParameters, because Saw and Square share
// that array and their parameter indices are load-bearing.
constexpr int kSineFeedback = 1;
constexpr int kSineShape = 2;

// The sine also gets one extra input the others lack, for the same reason it alone
// has feedback: on the chips, the feedback displacement is the operator's
// *gain-scaled* output, so anything that moves the operator's level — envelope,
// tremolo, velocity — moves the bite of its feedback with it. The port multiplies
// the feedback parameter; unconnected it multiplies by exactly 1 and the sample
// arithmetic is bit-identical to before the port existed, which the golden vectors
// hold. Indices 0-2 mirror kOscInputs exactly — OscillatorBase reads them by
// position.
constexpr PortDescriptor kSineInputs[] = {
    {"frequency", SignalType::Control, "Hz", false, false,
     "Pitch in hertz. Replaces the frequency parameter while connected."},
    {"fm", SignalType::Control, "octaves", false, false,
     "Frequency modulation in octaves. 1.0 is an octave up, -1.0 an octave down."},
    {"pm", SignalType::Audio, "cycles", false, false,
     "Phase modulation in cycles, added linearly. This is the FM of FM synthesis: "
     "feed another oscillator in here to make sidebands, not vibrato."},
    {"feedback", SignalType::Control, "", false, false,
     "Multiplied with the feedback parameter. Connect an envelope here so the bite "
     "follows the level, the way FM chips do."},
};

// The OPL2 waveform set: the same sine bent three cheap ways. Half keeps the positive
// lobes, absolute rectifies, quarter keeps the rising quarter of each lobe. On the
// chip these were nearly free — a mask on the table read — and that is exactly what
// they are here too, which is why they live on the sine as a shape rather than as
// three more node types: an FM operator on any of these chips is "a sine and a bend",
// and a patch that swaps the bend should not have to rewire its graph.
constexpr const char* kSineShapeLabels[] = {"sine", "half", "absolute", "quarter"};

constexpr ParameterDescriptor kSineParameters[] = {
    {"frequency", "Hz", 0.01f, 20000.0f, 440.0f, Scaling::Exponential,
     "Pitch when nothing is connected to the frequency input.", nullptr, 0},
    {"feedback", "cycles", 0.0f, 2.0f, 0.0f, Scaling::Linear,
     "Self phase-modulation. 0 is a pure sine; around 0.5 it turns brassy, and by 2 "
     "it is most of the way to a saw. OPL's strongest setting is 2.", nullptr, 0},
    {"shape", "", 0.0f, 3.0f, 0.0f, Scaling::Linear,
     "The OPL waveform family: pure, positive lobes only, rectified, or the rising "
     "quarters. Each adds its own harmonics before any modulation does.",
     kSineShapeLabels, 4},
};

class OscillatorBase : public DspNode {
public:
    void prepare(const PrepareContext& context) override {
        sample_rate_ = static_cast<float>(context.sample_rate);
        reset();
    }

    void reset() override {
        phase_ = 0.0f;
        history_a_ = 0.0f;
        history_b_ = 0.0f;
    }

    void process(const ProcessContext& context) override {
        const float* frequency_in = context.inputs[0];
        const float* fm_in = context.inputs[1];
        const float* pm_in = context.inputs[2];
        // Declared only by the sine; for Saw and Square the scheduler leaves every
        // undeclared slot nullptr, so reading it here is safe and always null.
        const float* feedback_in = context.inputs[3];
        float* out = context.outputs[0];
        const float base_frequency = parameter(kOscFrequency);
        const float nyquist = sample_rate_ * 0.5f;
        const float feedback = feedback_amount();

        for (int i = 0; i < context.frames; ++i) {
            float frequency = frequency_in != nullptr ? frequency_in[i] : base_frequency;
            if (fm_in != nullptr) {
                frequency *= std::pow(2.0f, fm_in[i]);
            }
            frequency = dsp::clampf(frequency, 0.0f, nyquist);

            const float increment = frequency / sample_rate_;

            // The phase being *read* this sample, as distinct from the free-running
            // phase underneath: modulation displaces one and never touches the other.
            // Assembled so that with nothing modulating, read_phase is phase_ to the
            // bit — the golden vectors depend on that literally.
            float displacement = 0.0f;
            bool displaced = false;
            if (pm_in != nullptr) {
                // Clamped to a few cycles either way before wrapping: wrap01 walks the
                // excess off one cycle at a time (fmod is slow on the ESP32), and a
                // patch that feeds an unscaled audio signal in here should get a rough
                // sound, not a slow engine. Real modulation indices live well inside
                // this range — a DX7 at full depth is about 2 cycles.
                displacement += dsp::clampf(pm_in[i], -8.0f, 8.0f);
                displaced = true;
            }
            if (feedback != 0.0f) {
                if (feedback_in != nullptr) {
                    // The scale is clamped to [0, 4]: with the parameter capped at 2
                    // the displacement stays within the same +-8 cycles the pm input
                    // is held to, and wrap01 walks excess off one cycle at a time.
                    const float scale = dsp::clampf(feedback_in[i], 0.0f, 4.0f);
                    displacement += feedback * scale * 0.5f * (history_a_ + history_b_);
                } else {
                    // Kept verbatim: this exact expression is what the golden
                    // vectors were rendered through.
                    displacement += feedback * 0.5f * (history_a_ + history_b_);
                }
                displaced = true;
            }
            const float read_phase =
                displaced ? dsp::wrap01(phase_ + displacement) : phase_;

            out[i] = render(read_phase, increment);
            history_b_ = history_a_;
            history_a_ = out[i];
            phase_ = dsp::wrap01(phase_ + increment);
        }
    }

protected:
    virtual float render(float phase, float increment) = 0;

    // Only the sine overrides this; see kSineParameters for why feedback is its alone.
    virtual float feedback_amount() const { return 0.0f; }

    float sample_rate_ = 48000.0f;
    float phase_ = 0.0f;
    float history_a_ = 0.0f;
    float history_b_ = 0.0f;
};

class SineOscillator final : public OscillatorBase {
protected:
    float render(float phase, float) override {
        // Everything is built from the owned table plus arithmetic every target rounds
        // identically — fabs and a comparison — so the shapes inherit the sine's
        // bit-exactness across native, WASM and the ESP32 for free.
        switch (static_cast<int>(parameter(kSineShape))) {
            default:
            case 0: return dsp::sine01(phase);
            case 1: return phase < 0.5f ? dsp::sine01(phase) : 0.0f;
            case 2: return std::fabs(dsp::sine01(phase));
            case 3: {
                // The rising quarter of each lobe: |sin| in the first and third
                // quarters of the cycle, silence in between.
                const bool rising = phase < 0.25f || (phase >= 0.5f && phase < 0.75f);
                return rising ? std::fabs(dsp::sine01(phase)) : 0.0f;
            }
        }
    }
    float feedback_amount() const override { return parameter(kSineFeedback); }
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
    // Negative is legal and means inverted: the DX7 import expresses tremolo as an
    // upside-down dip wave (amount -0.5, offset 0.5), and a floor of zero was
    // silently clamping that to a tremolo of nothing on every load.
    {"amount", "", -1000.0f, 1000.0f, 1.0f, Scaling::Linear,
     "Scales the output, in the unit of whatever you are modulating. Negative "
     "turns the swing upside down.", nullptr, 0},
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
            case 0: return dsp::sine01(phase_);
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

// ---------------------------------------------------------------------------------
// Sampler
//
// Plays a buffer the patch carries: the first node whose sound is data rather than
// mathematics. The buffer arrives resolved through PrepareContext - the node's JSON
// names it, the graph owns it, and this node just holds the pointer. Stage 1 of
// docs/sampler-design.md: gate-triggered playback at the recording's own pitch, with
// the frequency and slice inputs staged behind it.
//
// The read head moves at buffer_rate / engine_rate and interpolates linearly, so a
// 44.1 k recording plays at true speed in a 48 k graph and the golden vectors define
// the exactness per target, as they do for everything.
// ---------------------------------------------------------------------------------

constexpr const char* kSamplerLoopLabels[] = {"off", "loop"};

constexpr PortDescriptor kSamplerInputs[] = {
    {"gate", SignalType::Control, "", true, false,
     "Rises above 0.5 to play. Each edge restarts the current slice from its start."},
    {"frequency", SignalType::Control, "Hz", false, false,
     "Repitches playback: the recording plays at frequency / root speed. Wire the "
     "keyboard here and the recording follows it."},
    {"slice", SignalType::Control, "", false, false,
     "Where in the recording to play, 0 to 1, read on the gate edge. With eight "
     "slices, 0.5 is the fifth — a StepSequencer lane wired here chops the break, "
     "and every step can lock a different piece."},
};

constexpr PortDescriptor kSamplerOutputs[] = {
    {"out", SignalType::Audio, "", false, false, "The recording."},
};

constexpr ParameterDescriptor kSamplerParameters[] = {
    {"level", "", 0.0f, 1.0f, 0.8f, Scaling::Linear,
     "Playback level.", nullptr, 0},
    {"loop", "", 0.0f, 1.0f, 0.0f, Scaling::Linear,
     "Whether the slice's end wraps back to its start while the gate has not fired "
     "again.", kSamplerLoopLabels, 2},
    {"root", "Hz", 8.0f, 8000.0f, 261.63f, Scaling::Exponential,
     "The pitch the recording is considered to be. At this frequency it plays at "
     "true speed; an octave up plays double.", nullptr, 0},
    {"slices", "", 1.0f, 16.0f, 1.0f, Scaling::Linear,
     "How many equal pieces the recording divides into. 1 is the whole thing.",
     nullptr, 0},
    {"start", "", 0.0f, 1.0f, 0.0f, Scaling::Linear,
     "Where playback begins, as a fraction of the slice.", nullptr, 0},
    {"length", "", 0.0f, 1.0f, 1.0f, Scaling::Linear,
     "How much of the slice plays, from start.", nullptr, 0},
};

class SamplerNode final : public DspNode {
public:
    enum Param { kLevel = 0, kLoop = 1, kRoot = 2, kSlices = 3, kStart = 4, kLength = 5 };

    void prepare(const PrepareContext& context) override {
        sample_rate_ = static_cast<float>(context.sample_rate);
        data_ = context.buffer_data;
        frames_ = context.buffer_frames;
        rate_step_ = context.buffer_sample_rate > 0.0
                         ? static_cast<float>(context.buffer_sample_rate / context.sample_rate)
                         : 1.0f;
        reset();
    }

    void reset() override {
        position_ = 0.0;
        play_begin_ = 0.0;
        play_end_ = 0.0;
        playing_ = false;
        gate_was_open_ = false;
    }

    void process(const ProcessContext& context) override {
        const float* gate = context.inputs[0];
        const float* frequency_in = context.inputs[1];
        const float* slice_in = context.inputs[2];
        float* out = context.outputs[0];

        // A node without a buffer is silent, not an error: the harness jig and a
        // half-edited patch both meet this path, and neither deserves a crash.
        if (data_ == nullptr || frames_ < 2) {
            for (int i = 0; i < context.frames; ++i) {
                out[i] = 0.0f;
            }
            return;
        }

        const float level = parameter(kLevel);
        const bool loop = parameter(kLoop) >= 0.5f;
        const float root = parameter(kRoot);
        const int slices = static_cast<int>(dsp::clampf(parameter(kSlices) + 0.5f, 1.0f, 16.0f));
        const float start = dsp::clampf(parameter(kStart), 0.0f, 1.0f);
        const float length = dsp::clampf(parameter(kLength), 0.0f, 1.0f);
        const double last = static_cast<double>(frames_ - 1);
        const double slice_frames = static_cast<double>(frames_) / slices;

        for (int i = 0; i < context.frames; ++i) {
            const bool open = gate != nullptr && gate[i] >= 0.5f;
            if (open && !gate_was_open_) {
                // The slice is read on the edge and held for the whole hit, so a lane
                // that has already moved on cannot bend a note it started earlier.
                int slice = 0;
                if (slice_in != nullptr) {
                    slice = static_cast<int>(dsp::clampf(slice_in[i], 0.0f, 1.0f) *
                                             static_cast<float>(slices));
                    slice = slice >= slices ? slices - 1 : slice;
                }
                const double begin = slice * slice_frames;
                play_begin_ = begin + start * slice_frames;
                play_end_ = begin + dsp::clampf(start + length, 0.0f, 1.0f) * slice_frames;
                play_end_ = play_end_ > last ? last : play_end_;
                position_ = play_begin_;
                playing_ = play_end_ > play_begin_;
            }
            gate_was_open_ = open;

            if (!playing_) {
                out[i] = 0.0f;
                continue;
            }

            const int index = static_cast<int>(position_);
            const float fraction = static_cast<float>(position_ - index);
            const float sample = data_[index] * (1.0f - fraction) + data_[index + 1] * fraction;
            out[i] = sample * level;

            // frequency / root is the repitch; the recording's own rate is the base.
            const float pitch = frequency_in != nullptr
                                    ? dsp::clampf(frequency_in[i], 0.0f, 24000.0f) / root
                                    : 1.0f;
            position_ += static_cast<double>(rate_step_ * pitch);
            if (position_ >= play_end_) {
                if (loop) {
                    position_ = play_begin_ + (position_ - play_end_);
                } else {
                    playing_ = false;
                }
            }
        }
    }

private:
    float sample_rate_ = 48000.0f;
    const float* data_ = nullptr;
    int frames_ = 0;
    float rate_step_ = 1.0f;
    double position_ = 0.0;
    double play_begin_ = 0.0;
    double play_end_ = 0.0;
    bool playing_ = false;
    bool gate_was_open_ = false;
};

template <typename T>
std::unique_ptr<DspNode> make() {
    return std::unique_ptr<DspNode>(new T());
}

}  // namespace

const NodeTypeDescriptor kSineOscillator = {
    "SineOscillator", "Sine Oscillator", "Sources",
    "A pure tone with no harmonics. The sub-bass, the whistle, the FM building block.",
    "sine|sin|pure tone|test tone|simple wave|fundamental|fm operator|feedback|sub|"
    "sub bass|whistle|flute|beep|smooth tone",
    Slice<PortDescriptor>(kSineInputs),
    Slice<PortDescriptor>(kAudioOut),
    Slice<ParameterDescriptor>(kSineParameters),
    false, NodeRole::Processor, false,
    ResourceCost{3.0f, 8, 0},
    &make<SineOscillator>,
};

const NodeTypeDescriptor kSawOscillator = {
    "SawOscillator", "Saw Oscillator", "Sources",
    "A bright, buzzy wave containing every harmonic. The classic synth starting point.",
    "saw|sawtooth|ramp|bright|buzzy|brass|strings|classic synth sound|supersaw|lead|"
    "trance|rave|edm|violin|aggressive",
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
    "square|pulse|pwm|hollow|woody|reed|clarinet|chiptune|8 bit|8bit|game boy|"
    "gameboy|nes|video game|retro game|organ",
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
    "noise|white|pink|hiss|wind|percussion|snare|random|texture|hat|hihat|hi-hat|"
    "shaker|crash|ocean|waves|static|tv",
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

const NodeTypeDescriptor kSampler = {
    "Sampler", "Sampler", "Sources",
    "Plays a recording the patch carries. The buffer travels inside the file, like "
    "a module does.",
    "sampler|sample|play recording|wav|one-shot|hit|break|loop|playback|audio file|"
    "slice|slicer|chop|jungle|repitch|drum sample|sound file|wav player|import audio|"
    "recording",
    Slice<PortDescriptor>(kSamplerInputs),
    Slice<PortDescriptor>(kSamplerOutputs),
    Slice<ParameterDescriptor>(kSamplerParameters),
    false, NodeRole::Processor, false,
    ResourceCost{3.0f, 32, 0},
    &make<SamplerNode>,
};

const NodeTypeDescriptor kLfo = {
    "LFO", "LFO", "Modulation",
    "A slow wave for moving other controls: vibrato, tremolo, filter sweeps.",
    "lfo|low frequency oscillator|modulation|vibrato|tremolo|wobble|sweep|movement|"
    "slow|auto|drift|shimmer|dubstep|wobble bass|pulse",
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
    "constant|fixed|value|number|offset|dc|bias|always|set value|manual",
    Slice<PortDescriptor>(),
    Slice<PortDescriptor>(kConstantOutputs),
    Slice<ParameterDescriptor>(kConstantParameters),
    false, NodeRole::Processor, false,
    ResourceCost{0.2f, 0, 0},
    &make<ConstantNode>,
};

}  // namespace nodes
}  // namespace soundgraph
