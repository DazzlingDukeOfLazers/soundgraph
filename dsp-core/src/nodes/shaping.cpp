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
    {"frequency", SignalType::Control, "Hz", false, false,
     "Frequency to bend. Replaces the frequency parameter while connected."},
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
    // Same idea as the oscillator's frequency parameter, and it exists for the same
    // reason the module seam does: a one-shot patch played from a keyboard takes its
    // pitch from the NoteInput, and NoteInput is a terminal that gets dropped when the
    // patch is imported into another. Without a fallback the slide then has nothing to
    // bend and the sound goes silent — the pitch it was designed around has to survive
    // somewhere that is not a connection.
    {"frequency", "Hz", 0.01f, 20000.0f, 440.0f, Scaling::Exponential,
     "Pitch to bend when nothing is connected to the frequency input.", nullptr, 0},
};

class SlideNode final : public DspNode {
public:
    enum Param { kSlide = 0, kAcceleration = 1, kLimit = 2, kFrequency = 3 };

    void prepare(const PrepareContext& context) override {
        sample_rate_ = static_cast<float>(context.sample_rate);
        reset();
    }

    void reset() override {
        sample_index_ = 0;
        gate_was_open_ = false;
        started_ = false;
        start_frequency_ = 0.0f;
    }

    void process(const ProcessContext& context) override {
        const float* frequency = context.inputs[0];
        const float* gate = context.inputs[1];
        float* out = context.outputs[0];

        const float slide = parameter(kSlide);
        const float acceleration = parameter(kAcceleration);
        const float limit = parameter(kLimit);
        const float base_frequency = parameter(kFrequency);

        for (int i = 0; i < context.frames; ++i) {
            const float pitch = frequency != nullptr ? frequency[i] : base_frequency;
            const bool open = gate_open(gate, i);
            if ((open && !gate_was_open_) || !started_) {
                sample_index_ = 0;
                started_ = true;
                start_frequency_ = pitch;
            }
            gate_was_open_ = open;

            // Computed from the sample count rather than accumulated. Adding a small
            // step to a running total every sample lets the rounding error grow with the
            // total, and over a long slide the two ends of a render disagree by more than
            // the tolerance: the ESP32 and MSVC parted company at sample 32455 of 36000
            // while matching perfectly at the start. The closed form of
            // integral(slide + acceleration*t) dt is exact in one multiply-add, and its
            // error is a fixed ulp rather than a growing one.
            //
            // Deliberately still float. The ESP32-S3 emulates doubles in software, and
            // buying agreement with a per-sample double add on the audio path is the wrong
            // trade when a better formula costs nothing.
            const float t = static_cast<float>(sample_index_) / sample_rate_;
            const float semitones = (slide + 0.5f * acceleration * t) * t;
            float bent = pitch * std::pow(2.0f, semitones / 12.0f);

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
            sample_index_++;
        }
    }

private:
    float sample_rate_ = 48000.0f;
    long sample_index_ = 0;
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
    {"frequency", SignalType::Control, "Hz", false, false,
     "Frequency to step. Replaces the frequency parameter while connected."},
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
    // As on Slide: whichever of the two heads the pitch chain has to hold the patch's own
    // pitch, so that dropping the keyboard does not drop the sound.
    {"frequency", "Hz", 0.01f, 20000.0f, 440.0f, Scaling::Exponential,
     "Pitch to step when nothing is connected to the frequency input.", nullptr, 0},
};

class ArpeggioNode final : public DspNode {
public:
    enum Param { kTime = 0, kInterval = 1, kFrequency = 2 };

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

        const float time = parameter(kTime);
        const float ratio = std::pow(2.0f, parameter(kInterval) / 12.0f);
        const float base_frequency = parameter(kFrequency);
        const float dt = 1.0f / sample_rate_;

        for (int i = 0; i < context.frames; ++i) {
            const float pitch = frequency != nullptr ? frequency[i] : base_frequency;
            const bool open = gate_open(gate, i);
            if (open && !gate_was_open_) {
                elapsed_ = 0.0f;
                stepped_ = false;
            }
            gate_was_open_ = open;

            if (!stepped_ && elapsed_ >= time) {
                stepped_ = true;
            }

            out[i] = stepped_ ? pitch * ratio : pitch;
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
        sample_index_ = 0;
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

        const int capacity = static_cast<int>(line_.size());
        const float start_offset = parameter(kOffset);
        const float sweep = parameter(kSweep);
        const float depth = parameter(kDepth);

        for (int i = 0; i < context.frames; ++i) {
            // From the sample count, not a running total. A swept delay reads the line
            // at a fractional position, so a rounding difference of a few ulps can land on
            // the other side of a sample boundary and pick a different pair to interpolate
            // between — which is a step, not a nudge, and is why this drifted past
            // tolerance on the ESP32 within the first 1200 samples.
            const float swept = start_offset +
                sweep * static_cast<float>(sample_index_) / sample_rate_;
            const float offset_ms =
                offset_in != nullptr ? offset_in[i] : dsp::clampf(swept, 0.0f, kMaxPhaserMs);
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
            sample_index_++;
        }
    }

private:
    float sample_rate_ = 48000.0f;
    std::vector<float> line_;
    int write_index_ = 0;
    long sample_index_ = 0;
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

// ---------------------------------------------------------------------------------
// Clock
//
// Musical time as a node: a pulse train described in bpm and note divisions rather than
// hertz, with swing, a bar output for the downbeat, and a run gate that rewinds. This is
// what Retrigger is not — Retrigger says "8 times a second", Clock says "sixteenths at
// 128". There is deliberately no global transport hiding in the engine: patches share a
// tempo by sharing a value, one Constant wired to several Clocks' bpm inputs, and
// identical Clocks stay sample-locked because nothing about them is random.
// ---------------------------------------------------------------------------------

constexpr const char* kClockDivisionLabels[] = {
    "1/1", "1/2", "1/4", "1/8", "1/16", "1/32", "1/8T", "1/16T", "1/8.", "1/16.",
};

// Pulses per quarter-note beat for each label above. Triplets pack three in the space
// of two; dots stretch a division by half, so its rate drops to two-thirds.
constexpr float kClockPulsesPerBeat[] = {
    0.25f, 0.5f, 1.0f, 2.0f, 4.0f, 8.0f, 3.0f, 6.0f, 4.0f / 3.0f, 8.0f / 3.0f,
};

constexpr PortDescriptor kClockInputs[] = {
    {"bpm", SignalType::Control, "BPM", false, false,
     "Tempo. Replaces the bpm parameter while connected — wire one Constant to several "
     "Clocks and they share it."},
    {"run", SignalType::Control, "", false, false,
     "Transport. At or above 0.5 the clock runs; below, it stops and rewinds to the "
     "downbeat, so the next start begins the bar cleanly. Unconnected means running."},
};

constexpr PortDescriptor kClockOutputs[] = {
    {"gate", SignalType::Control, "", false, false,
     "A pulse per division step. Connect to any gate input."},
    {"bar", SignalType::Control, "", false, false,
     "A pulse on the first beat of each bar."},
};

constexpr ParameterDescriptor kClockParameters[] = {
    {"bpm", "BPM", 20.0f, 300.0f, 120.0f, Scaling::Linear,
     "Beats per minute. A beat is a quarter note.", nullptr, 0},
    {"division", "", 0.0f, 9.0f, 4.0f, Scaling::Linear,
     "The step length, as a fraction of a bar of 4/4.", kClockDivisionLabels, 10},
    {"swing", "", 0.0f, 1.0f, 0.0f, Scaling::Linear,
     "Delays every second step. 0 is straight; 1 lands on the triplet, the full "
     "MPC-style shuffle.", nullptr, 0},
    {"width", "ms", 0.1f, 100.0f, 5.0f, Scaling::Logarithmic,
     "How long each pulse stays up. Only its rising edge matters to most nodes.",
     nullptr, 0},
    {"beats_per_bar", "", 1.0f, 16.0f, 4.0f, Scaling::Linear,
     "How many beats the bar output counts before firing again.", nullptr, 0},
};

class ClockNode final : public DspNode {
public:
    enum Param { kBpm = 0, kDivision = 1, kSwing = 2, kWidth = 3, kBeatsPerBar = 4 };

    void prepare(const PrepareContext& context) override {
        sample_rate_ = static_cast<float>(context.sample_rate);
        reset();
    }

    // Position 0 is a rising edge on both outputs, for the same reason Retrigger starts
    // at one: a clock that stayed silent for its first step would delay everything it
    // drives, and the run gate rewinds to here so every start is a downbeat.
    void reset() override {
        pulse_pos_ = 0.0;
        bar_pos_ = 0.0;
        off_step_ = false;
    }

    void process(const ProcessContext& context) override {
        const float* bpm_in = context.inputs[0];
        const float* run = context.inputs[1];
        float* gate = context.outputs[0];
        float* bar = context.outputs[1];

        const int division =
            static_cast<int>(dsp::clampf(parameter(kDivision) + 0.5f, 0.0f, 9.0f));
        const float pulses_per_beat = kClockPulsesPerBeat[division];
        const float swing_start = parameter(kSwing) / 3.0f;
        const float width_s = parameter(kWidth) * 0.001f;
        const float beats_per_bar = parameter(kBeatsPerBar);

        for (int i = 0; i < context.frames; ++i) {
            if (run != nullptr && run[i] < 0.5f) {
                reset();
                gate[i] = 0.0f;
                bar[i] = 0.0f;
                continue;
            }
            const float bpm =
                dsp::clampf(bpm_in != nullptr ? bpm_in[i] : parameter(kBpm), 20.0f, 300.0f);
            const float beats_per_second = bpm / 60.0f;

            // Both positions are phases — the step one in units of a step, the bar one
            // in beats — kept by subtraction rather than fmod, which is slow on the ESP32.
            const float start = off_step_ ? swing_start : 0.0f;
            const float width_steps = width_s * beats_per_second * pulses_per_beat;
            gate[i] = (pulse_pos_ >= start && pulse_pos_ < start + width_steps) ? 1.0f : 0.0f;
            bar[i] = bar_pos_ < width_s * beats_per_second ? 1.0f : 0.0f;

            const double beat_increment = static_cast<double>(beats_per_second) / sample_rate_;
            pulse_pos_ += beat_increment * pulses_per_beat;
            if (pulse_pos_ >= 1.0) {
                pulse_pos_ -= 1.0;
                off_step_ = !off_step_;
            }
            bar_pos_ += beat_increment;
            if (bar_pos_ >= beats_per_bar) {
                bar_pos_ -= beats_per_bar;
            }
        }
    }

private:
    float sample_rate_ = 48000.0f;
    double pulse_pos_ = 0.0;
    double bar_pos_ = 0.0;
    bool off_step_ = false;
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

const NodeTypeDescriptor kClock = {
    "Clock", "Clock", "Modulation",
    "Musical time: pulses at a bpm and note division, with swing and a bar downbeat.",
    "clock|tempo|bpm|metro|metronome|transport|division|sixteenth|eighth|swing|shuffle|"
    "groove|sync|downbeat|bar|beat",
    Slice<PortDescriptor>(kClockInputs),
    Slice<PortDescriptor>(kClockOutputs),
    Slice<ParameterDescriptor>(kClockParameters),
    false, NodeRole::Processor, false,
    ResourceCost{3.0f, 24, 0},
    &make<ClockNode>,
};

}  // namespace nodes
}  // namespace soundgraph
