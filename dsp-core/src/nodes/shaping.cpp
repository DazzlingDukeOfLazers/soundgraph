// Shaping: envelopes, pitch movement and retriggering.
//
// These exist because a graph could not previously say the things a game sound says —
// "drop the pitch fast", "jump up a fifth after 40 ms", "do that again every 100 ms". The
// vocabulary was built for held notes, where pitch is set by a keyboard and an envelope
// sustains until the key is released. A coin sound has no key and no sustain.
//
// They are deliberately general rather than shaped to sfxr. Each is expressed in seconds,
// hertz and semitones — the units the rest of the vocabulary already uses — so that a
// patch reads the same whether it came from a sfxr preset or from somebody dragging nodes
// around. sfxr's own quantities are converted when a preset is mapped to a patch, which
// is the right place for that arithmetic to live.
#include <cmath>
#include <vector>

#include "dsp_math.h"
#include "nodes/node_types.h"

namespace soundgraph {
namespace nodes {
namespace {

// A gate is open at or above 0.5, matching ADSR. Anything that triggers does so on the
// rising edge, so a held gate fires once and a pulse train fires once per pulse.
inline bool gate_open(const float* gate, int frame) {
    return gate != nullptr && gate[frame] >= 0.5f;
}

// ---------------------------------------------------------------------------------
// AHD envelope
//
// Attack, hold, decay — and then silence, with no sustain and nothing to release. This is
// the percussive envelope: a hit, a coin, a jump. ADSR cannot express it, because ADSR is
// built around a note being let go, and these sounds are over before anyone lets go.
//
// `punch` boosts the start of the hold stage and falls back to full level across it, which
// is what gives a coin its bright chirp and an explosion its thump.
//
// Zero-length stages are skipped rather than divided by. sfxr, which this shape is taken
// from, evaluates its stage ratio on the transition sample and so emits a NaN when a stage
// has zero length; that is a real defect of a real program and there is no reason to
// reproduce it. See tests/sfxr/README.md.
// ---------------------------------------------------------------------------------

constexpr PortDescriptor kAhdInputs[] = {
    {"gate", SignalType::Control, "", true, false,
     "Rises above 0.5 to fire the envelope. It runs to the end on its own; letting go "
     "early does nothing."},
};
constexpr PortDescriptor kAhdOutputs[] = {
    {"out", SignalType::Control, "", false, false,
     "Envelope level. Reaches 1, or higher during the punch."},
};
constexpr ParameterDescriptor kAhdParameters[] = {
    {"attack", "s", 0.0f, 10.0f, 0.0f, Scaling::Logarithmic,
     "Time to rise to full level. Zero starts instantly, which is what most percussive "
     "sounds want.", nullptr, 0},
    {"hold", "s", 0.0f, 10.0f, 0.1f, Scaling::Logarithmic,
     "Time held at full level before the decay begins.", nullptr, 0},
    {"decay", "s", 0.0f, 10.0f, 0.3f, Scaling::Logarithmic,
     "Time to fall from full level to silence.", nullptr, 0},
    {"punch", "", 0.0f, 1.0f, 0.0f, Scaling::Linear,
     "Extra level at the start of the hold, falling back to full across it. 1 starts at "
     "three times the level — this is what makes a hit sound like a hit.", nullptr, 0},
};

class AhdEnvelopeNode final : public DspNode {
public:
    enum Param { kAttack = 0, kHold = 1, kDecay = 2, kPunch = 3 };

    void prepare(const PrepareContext& context) override {
        sample_rate_ = static_cast<float>(context.sample_rate);
        reset();
    }

    void reset() override {
        stage_ = Stage::Idle;
        elapsed_ = 0.0f;
        gate_was_open_ = false;
        level_ = 0.0f;
    }

    void process(const ProcessContext& context) override {
        const float* gate = context.inputs[0];
        float* out = context.outputs[0];

        const float attack = parameter(kAttack);
        const float hold = parameter(kHold);
        const float decay = parameter(kDecay);
        const float punch = parameter(kPunch);
        const float dt = 1.0f / sample_rate_;

        for (int i = 0; i < context.frames; ++i) {
            const bool open = gate_open(gate, i);
            if (open && !gate_was_open_) {
                stage_ = Stage::Attack;
                elapsed_ = 0.0f;
            }
            gate_was_open_ = open;

            switch (stage_) {
                case Stage::Idle:
                    level_ = 0.0f;
                    break;

                case Stage::Attack:
                    if (elapsed_ >= attack) {
                        stage_ = Stage::Hold;
                        elapsed_ = 0.0f;
                        level_ = 1.0f + 2.0f * punch;
                    } else {
                        level_ = elapsed_ / attack;
                    }
                    break;

                case Stage::Hold:
                    if (elapsed_ >= hold) {
                        stage_ = Stage::Decay;
                        elapsed_ = 0.0f;
                        level_ = 1.0f;
                    } else {
                        level_ = 1.0f + 2.0f * punch * (1.0f - elapsed_ / hold);
                    }
                    break;

                case Stage::Decay:
                    if (elapsed_ >= decay) {
                        stage_ = Stage::Idle;
                        elapsed_ = 0.0f;
                        level_ = 0.0f;
                    } else {
                        level_ = 1.0f - elapsed_ / decay;
                    }
                    break;
            }

            out[i] = level_;
            elapsed_ += dt;
        }
    }

private:
    enum class Stage { Idle, Attack, Hold, Decay };

    float sample_rate_ = 48000.0f;
    Stage stage_ = Stage::Idle;
    float elapsed_ = 0.0f;
    float level_ = 0.0f;
    bool gate_was_open_ = false;
};

// ---------------------------------------------------------------------------------
// Slide
//
// Bends a frequency over time, at a rate that can itself change. Two parameters rather
// than one because a falling laser and a rising powerup are the same node with different
// signs, and both accelerate — a slide at a constant rate sounds mechanical.
//
// Semitones per second, not a multiplier per sample: a slide of -12 means "down an octave
// every second" at any sample rate, and reads the same in an editor as it does in a patch
// file.
// ---------------------------------------------------------------------------------

constexpr PortDescriptor kSlideInputs[] = {
    {"frequency", SignalType::Control, "Hz", true, false, "Frequency to bend."},
    {"gate", SignalType::Control, "", false, false,
     "Rises above 0.5 to restart the slide from the frequency present at that moment. "
     "Leave it unconnected and the slide runs from the first sample."},
};
constexpr PortDescriptor kSlideOutputs[] = {
    {"frequency", SignalType::Control, "Hz", false, false, "Bent frequency."},
};
constexpr ParameterDescriptor kSlideParameters[] = {
    // The range looks absurd for a musical control and is not. A percussive hit lasts a
    // few milliseconds, and its pitch has to collapse inside that: -2000 semitones per
    // second is 167 octaves per second, which over 5 ms is a little under one octave.
    // That is an ordinary drum sound, not an extreme one.
    //
    // The first range here was +/-240, chosen as "surely nobody needs more than twenty
    // octaves a second". Twelve of the forty-one sfxr cases exceeded it, every one of the
    // hit-hurt generator's did, and because parameters clamp on load the patches carried
    // the right number and the sound came out ten times too slow.
    {"slide", "semitones/s", -9600.0f, 9600.0f, 0.0f, Scaling::Linear,
     "How fast the pitch moves. Negative falls, positive rises. Large values are for "
     "percussive sounds, where the whole drop happens in a few milliseconds.", nullptr, 0},
    {"acceleration", "semitones/s^2", -19200.0f, 19200.0f, 0.0f, Scaling::Linear,
     "How fast the slide itself speeds up or slows down.", nullptr, 0},
    {"limit", "Hz", 0.0f, 20000.0f, 0.0f, Scaling::Linear,
     "Frequency the slide stops at. Zero means no limit.", nullptr, 0},
};

class SlideNode final : public DspNode {
public:
    enum Param { kSlide = 0, kAcceleration = 1, kLimit = 2 };

    void prepare(const PrepareContext& context) override {
        sample_rate_ = static_cast<float>(context.sample_rate);
        reset();
    }

    void reset() override {
        semitones_ = 0.0f;
        elapsed_ = 0.0f;
        gate_was_open_ = false;
        started_ = false;
        start_frequency_ = 0.0f;
    }

    void process(const ProcessContext& context) override {
        const float* frequency = context.inputs[0];
        const float* gate = context.inputs[1];
        float* out = context.outputs[0];

        if (frequency == nullptr) {
            for (int i = 0; i < context.frames; ++i) {
                out[i] = 0.0f;
            }
            return;
        }

        const float slide = parameter(kSlide);
        const float acceleration = parameter(kAcceleration);
        const float limit = parameter(kLimit);
        const float dt = 1.0f / sample_rate_;

        for (int i = 0; i < context.frames; ++i) {
            const bool open = gate_open(gate, i);
            if ((open && !gate_was_open_) || !started_) {
                semitones_ = 0.0f;
                elapsed_ = 0.0f;
                started_ = true;
                start_frequency_ = frequency[i];
            }
            gate_was_open_ = open;

            float bent = frequency[i] * std::pow(2.0f, semitones_ / 12.0f);

            // The limit is a stop, not a fold: whichever side of it the slide started on
            // is the side it stays on. Written this way so the same parameter works for a
            // laser falling to a floor and a powerup rising to a ceiling.
            if (limit > 0.0f) {
                if (start_frequency_ >= limit) {
                    bent = bent < limit ? limit : bent;
                } else {
                    bent = bent > limit ? limit : bent;
                }
            }

            out[i] = bent;

            semitones_ += (slide + acceleration * elapsed_) * dt;
            elapsed_ += dt;
        }
    }

private:
    float sample_rate_ = 48000.0f;
    float semitones_ = 0.0f;
    float elapsed_ = 0.0f;
    float start_frequency_ = 0.0f;
    bool gate_was_open_ = false;
    bool started_ = false;
};

// ---------------------------------------------------------------------------------
// Arpeggio
//
// One jump, once, at a set moment. Not an arpeggiator: there is no pattern and no clock,
// just a single step to a new interval part-way through the sound. That single step is
// what a pickup or a coin actually is, and it is the cheapest possible way to make a
// sound feel like it means something good happened.
// ---------------------------------------------------------------------------------

constexpr PortDescriptor kArpeggioInputs[] = {
    {"frequency", SignalType::Control, "Hz", true, false, "Frequency to step."},
    {"gate", SignalType::Control, "", false, false,
     "Rises above 0.5 to arm the step again. Leave it unconnected and it fires once, "
     "from the first sample."},
};
constexpr PortDescriptor kArpeggioOutputs[] = {
    {"frequency", SignalType::Control, "Hz", false, false, "Stepped frequency."},
};
constexpr ParameterDescriptor kArpeggioParameters[] = {
    {"time", "s", 0.0f, 5.0f, 0.05f, Scaling::Logarithmic,
     "How long to wait before stepping.", nullptr, 0},
    {"interval", "semitones", -48.0f, 48.0f, 7.0f, Scaling::Linear,
     "How far to step. 7 is a fifth up, 12 an octave, -12 an octave down.", nullptr, 0},
};

class ArpeggioNode final : public DspNode {
public:
    enum Param { kTime = 0, kInterval = 1 };

    void prepare(const PrepareContext& context) override {
        sample_rate_ = static_cast<float>(context.sample_rate);
        reset();
    }

    void reset() override {
        elapsed_ = 0.0f;
        stepped_ = false;
        gate_was_open_ = false;
    }

    void process(const ProcessContext& context) override {
        const float* frequency = context.inputs[0];
        const float* gate = context.inputs[1];
        float* out = context.outputs[0];

        if (frequency == nullptr) {
            for (int i = 0; i < context.frames; ++i) {
                out[i] = 0.0f;
            }
            return;
        }

        const float time = parameter(kTime);
        const float ratio = std::pow(2.0f, parameter(kInterval) / 12.0f);
        const float dt = 1.0f / sample_rate_;

        for (int i = 0; i < context.frames; ++i) {
            const bool open = gate_open(gate, i);
            if (open && !gate_was_open_) {
                elapsed_ = 0.0f;
                stepped_ = false;
            }
            gate_was_open_ = open;

            if (!stepped_ && elapsed_ >= time) {
                stepped_ = true;
            }

            out[i] = stepped_ ? frequency[i] * ratio : frequency[i];
            elapsed_ += dt;
        }
    }

private:
    float sample_rate_ = 48000.0f;
    float elapsed_ = 0.0f;
    bool stepped_ = false;
    bool gate_was_open_ = false;
};

// ---------------------------------------------------------------------------------
// Phaser
//
// A very short delay, swept, added back to the dry signal. The comb of cancellations that
// produces is the whoosh on an explosion and the sweep on a laser.
//
// It is a flanger by the usual naming, and sfxr calls it a phaser; the name here follows
// sfxr because that is what anyone arriving from a game-audio background will look for.
// Depth is an add rather than a crossfade, so at 1 it matches sfxr exactly.
// ---------------------------------------------------------------------------------

constexpr float kMaxPhaserMs = 24.0f;  // 1023 samples at 44100, sfxr's buffer

constexpr PortDescriptor kPhaserInputs[] = {
    {"in", SignalType::Audio, "", true, true, "Signal to sweep."},
    {"offset", SignalType::Control, "ms", false, false,
     "Delay in milliseconds. Replaces the offset parameter while connected."},
};
constexpr PortDescriptor kPhaserOutputs[] = {
    {"out", SignalType::Audio, "", false, false, "Swept signal."},
};
constexpr ParameterDescriptor kPhaserParameters[] = {
    {"offset", "ms", 0.0f, kMaxPhaserMs, 0.0f, Scaling::Linear,
     "Where the sweep starts. Small values comb the high end, larger ones the low.",
     nullptr, 0},
    {"sweep", "ms/s", -240.0f, 240.0f, 0.0f, Scaling::Linear,
     "How fast the delay moves. This is what makes it whoosh rather than sit still.",
     nullptr, 0},
    {"depth", "", 0.0f, 1.0f, 1.0f, Scaling::Linear,
     "How much of the delayed signal is added back.", nullptr, 0},
};

class PhaserNode final : public DspNode {
public:
    enum Param { kOffset = 0, kSweep = 1, kDepth = 2 };

    void prepare(const PrepareContext& context) override {
        sample_rate_ = static_cast<float>(context.sample_rate);
        const int capacity =
            static_cast<int>(sample_rate_ * kMaxPhaserMs * 0.001f) + 2;
        line_.assign(static_cast<std::size_t>(capacity), 0.0f);
        reset();
    }

    void reset() override {
        for (float& sample : line_) {
            sample = 0.0f;
        }
        write_index_ = 0;
        offset_ms_ = 0.0f;
        started_ = false;
    }

    void process(const ProcessContext& context) override {
        const float* in = context.inputs[0];
        const float* offset_in = context.inputs[1];
        float* out = context.outputs[0];

        if (in == nullptr || line_.empty()) {
            for (int i = 0; i < context.frames; ++i) {
                out[i] = 0.0f;
            }
            return;
        }

        if (!started_) {
            offset_ms_ = parameter(kOffset);
            started_ = true;
        }

        const int capacity = static_cast<int>(line_.size());
        const float sweep = parameter(kSweep);
        const float depth = parameter(kDepth);
        const float dt = 1.0f / sample_rate_;

        for (int i = 0; i < context.frames; ++i) {
            const float offset_ms =
                offset_in != nullptr ? offset_in[i] : offset_ms_;
            const float delay_samples = dsp::clampf(offset_ms, 0.0f, kMaxPhaserMs) *
                                        0.001f * sample_rate_;

            line_[static_cast<std::size_t>(write_index_)] = in[i];

            float read_position = static_cast<float>(write_index_) - delay_samples;
            while (read_position < 0.0f) {
                read_position += static_cast<float>(capacity);
            }
            const int index0 = static_cast<int>(read_position) % capacity;
            const int index1 = (index0 + 1) % capacity;
            const float fraction = read_position - std::floor(read_position);
            const float delayed = line_[static_cast<std::size_t>(index0)] * (1.0f - fraction) +
                                  line_[static_cast<std::size_t>(index1)] * fraction;

            out[i] = in[i] + delayed * depth;

            write_index_ = (write_index_ + 1) % capacity;
            offset_ms_ = dsp::clampf(offset_ms_ + sweep * dt, 0.0f, kMaxPhaserMs);
        }
    }

private:
    float sample_rate_ = 48000.0f;
    std::vector<float> line_;
    int write_index_ = 0;
    float offset_ms_ = 0.0f;
    bool started_ = false;
};

// ---------------------------------------------------------------------------------
// Retrigger
//
// A pulse on a timer, for driving the gate of anything that fires on a rising edge. This
// is how a sound stutters or machine-guns: the envelope and the slide are told to start
// again, while the sound itself keeps running.
//
// A separate node rather than a property of the envelope, because what should restart is
// a decision per patch. sfxr's repeat restarts the pitch but not the amplitude, and being
// able to say that in a graph — by wiring this to one gate and not the other — is exactly
// the sort of thing having a graph is for.
// ---------------------------------------------------------------------------------

constexpr PortDescriptor kRetriggerInputs[] = {
    {"rate", SignalType::Control, "Hz", false, false,
     "Retriggers per second. Replaces the rate parameter while connected."},
};
constexpr PortDescriptor kRetriggerOutputs[] = {
    {"gate", SignalType::Control, "", false, false,
     "Pulses to 1 briefly, then back to 0. Connect to any gate input."},
};
constexpr ParameterDescriptor kRetriggerParameters[] = {
    {"rate", "Hz", 0.1f, 200.0f, 8.0f, Scaling::Exponential,
     "How often to fire.", nullptr, 0},
    {"width", "ms", 0.1f, 100.0f, 1.0f, Scaling::Logarithmic,
     "How long each pulse stays up. Only its rising edge matters to most nodes.",
     nullptr, 0},
};

class RetriggerNode final : public DspNode {
public:
    enum Param { kRate = 0, kWidth = 1 };

    void prepare(const PrepareContext& context) override {
        sample_rate_ = static_cast<float>(context.sample_rate);
        reset();
    }

    // Starts at zero so that the first sample is a rising edge: a retrigger that did not
    // fire until one whole interval had passed would silently delay the start of anything
    // it drives.
    void reset() override { elapsed_ = 0.0f; }

    void process(const ProcessContext& context) override {
        const float* rate_in = context.inputs[0];
        float* out = context.outputs[0];

        const float width = parameter(kWidth) * 0.001f;
        const float dt = 1.0f / sample_rate_;

        for (int i = 0; i < context.frames; ++i) {
            const float rate =
                dsp::clampf(rate_in != nullptr ? rate_in[i] : parameter(kRate), 0.1f, 200.0f);
            const float interval = 1.0f / rate;

            out[i] = elapsed_ < width ? 1.0f : 0.0f;

            elapsed_ += dt;
            if (elapsed_ >= interval) {
                elapsed_ -= interval;
            }
        }
    }

private:
    float sample_rate_ = 48000.0f;
    float elapsed_ = 0.0f;
};

template <typename T>
std::unique_ptr<DspNode> make() {
    return std::unique_ptr<DspNode>(new T());
}

}  // namespace

const NodeTypeDescriptor kAhdEnvelope = {
    "AhdEnvelope", "AHD Envelope", "Modulation",
    "A one-shot envelope for sounds that are over before you let go: hits, coins, jumps.",
    "envelope|percussive|one shot|oneshot|attack hold decay|ahd|ad|punch|hit|coin|jump|"
    "drum|no sustain|game sound|blip",
    Slice<PortDescriptor>(kAhdInputs),
    Slice<PortDescriptor>(kAhdOutputs),
    Slice<ParameterDescriptor>(kAhdParameters),
    false, NodeRole::Processor, false,
    ResourceCost{2.0f, 20, 0},
    &make<AhdEnvelopeNode>,
};

const NodeTypeDescriptor kSlide = {
    "Slide", "Slide", "Modulation",
    "Bends a frequency over time. Falling makes a laser, rising makes a powerup.",
    "slide|glide|portamento|bend|sweep|pitch drop|pitch rise|laser|zap|powerup|siren|"
    "falling|rising|whoop",
    Slice<PortDescriptor>(kSlideInputs),
    Slice<PortDescriptor>(kSlideOutputs),
    Slice<ParameterDescriptor>(kSlideParameters),
    false, NodeRole::Processor, false,
    ResourceCost{4.0f, 20, 0},
    &make<SlideNode>,
};

const NodeTypeDescriptor kArpeggio = {
    "Arpeggio", "Arpeggio", "Modulation",
    "Steps the frequency once, part-way through. The chirp on a pickup.",
    "arpeggio|arp|jump|step|interval|chirp|coin|pickup|two tone|blip up",
    Slice<PortDescriptor>(kArpeggioInputs),
    Slice<PortDescriptor>(kArpeggioOutputs),
    Slice<ParameterDescriptor>(kArpeggioParameters),
    false, NodeRole::Processor, false,
    ResourceCost{3.0f, 16, 0},
    &make<ArpeggioNode>,
};

const NodeTypeDescriptor kPhaser = {
    "Phaser", "Phaser", "Time",
    "A short swept delay added to the signal. The whoosh on an explosion.",
    "phaser|flanger|whoosh|sweep|comb|jet|swirl|explosion|laser|space",
    Slice<PortDescriptor>(kPhaserInputs),
    Slice<PortDescriptor>(kPhaserOutputs),
    Slice<ParameterDescriptor>(kPhaserParameters),
    false, NodeRole::Processor, false,
    ResourceCost{5.0f, 20, static_cast<int>(48000 * kMaxPhaserMs * 0.001f * 4) + 8},
    &make<PhaserNode>,
};

const NodeTypeDescriptor kRetrigger = {
    "Retrigger", "Retrigger", "Modulation",
    "Fires a pulse on a timer, to restart anything with a gate.",
    "retrigger|repeat|stutter|machine gun|rearm|restart|pulse|clock|tremolo gate|ratchet",
    Slice<PortDescriptor>(kRetriggerInputs),
    Slice<PortDescriptor>(kRetriggerOutputs),
    Slice<ParameterDescriptor>(kRetriggerParameters),
    false, NodeRole::Processor, false,
    ResourceCost{2.0f, 12, 0},
    &make<RetriggerNode>,
};

}  // namespace nodes
}  // namespace soundgraph
