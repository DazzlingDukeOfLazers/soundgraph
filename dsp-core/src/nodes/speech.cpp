// The Speak & Spell's voice.
//
// A TMS5220-style LPC decoder and synthesizer: the patch carries a bitstream of
// LPC-10 frames in a schema-v3 buffer — energy, pitch and ten reflection
// coefficients per 25 ms frame — and this node speaks it through the same machinery
// the chip used: a chirp or noise excitation driven through a ten-stage lattice
// filter, parameters gliding between frames on the chip's own interpolation ladder.
//
// The coefficient tables are the chip's ROM constants, decap-verified (TMS5220NL,
// imaged by digshadow in April 2013, as recorded in MAME's tms5110r reference; the
// tables are published hardware facts). The synthesis is written fresh from the
// well-documented algorithm — the reusable asset here is the *format*: any tool
// that can quantize speech to these tables can put words in the patch, and
// tools/lpc-encode.mjs is that tool.
//
// The bitstream rides in the buffer one byte per pcm16 sample (the low eight bits),
// because pcm16's fixed-point round trip is exact and a second buffer format for a
// few hundred bytes of speech would be a schema change nobody needs. Bits are taken
// LSB-first within each byte, the chip's own speak-external order.
//
// One buffer can carry a whole phrase bank: phrases are stop-frame delimited —
// which the format already was — and the note input picks one, the root note
// saying the first line and each semitone up the next. Draw notes on the piano
// roll and the roll cues words.

#include <cmath>
#include <memory>

#include "dsp_math.h"
#include "nodes/speech_tables.h"
#include "nodes/node_types.h"

namespace soundgraph {
namespace nodes {
namespace {

constexpr PortDescriptor kSpeechInputs[] = {
    {"trigger", SignalType::Control, "", false, false,
     "Starts a phrase from the top on a rising edge. The keyboard's trigger "
     "makes every key a talk button."},
    {"note", SignalType::Control, "Hz", false, false,
     "Which phrase to say, read on the trigger edge: the root note says the "
     "first, each semitone up says the next. Wire the keyboard here and the "
     "piano roll cues words."},
};

constexpr PortDescriptor kSpeechOutputs[] = {
    {"out", SignalType::Audio, "", false, false, "The voice."},
};

constexpr ParameterDescriptor kSpeechParameters[] = {
    {"pitch", "", 0.25f, 4.0f, 1.0f, Scaling::Exponential,
     "Scales the voice without changing its speed: up is helium, down is a giant.",
     nullptr, 0},
    {"speed", "", 0.25f, 4.0f, 1.0f, Scaling::Exponential,
     "How fast the frames go by. The pitch stays put; only the words hurry.",
     nullptr, 0},
    {"level", "", 0.0f, 2.0f, 1.0f, Scaling::Linear, "Output level.", nullptr, 0},
    {"loop", "", 0.0f, 1.0f, 0.0f, Scaling::Linear,
     "Say it again forever. 0 speaks once per trigger.", nullptr, 0},
    {"root", "Hz", 27.5f, 2000.0f, 130.81f, Scaling::Exponential,
     "The note that says the first phrase — C3 by default, under the keyboard's "
     "opening octave. Each semitone above it says the next line.", nullptr, 0},
};

class SpeechNode final : public DspNode {
public:
    enum Param { kPitch = 0, kSpeed = 1, kLevel = 2, kLoop = 3, kRoot = 4 };

    void prepare(const PrepareContext& context) override {
        host_rate_ = static_cast<float>(context.sample_rate);
        data_ = context.buffer_data;
        data_frames_ = context.buffer_frames;
        scan_phrases();
        reset();
    }

    void reset() override {
        playing_ = false;
        trigger_was_open_ = false;
        bit_position_ = 0;
        period_index_ = 0;
        period_sample_ = 0;
        chirp_position_ = 0;
        resample_phase_ = 1.0f;
        held_ = 0.0f;
        previous_ = 0.0f;
        noise_ = 0x1234u;
        for (int i = 0; i < 10; ++i) {
            k_now_[i] = 0.0f;
            k_target_[i] = 0.0f;
            lattice_[i] = 0.0f;
        }
        energy_now_ = 0.0f;
        energy_target_ = 0.0f;
        pitch_now_ = 40.0f;
        pitch_target_ = 40.0f;
        voiced_ = false;
    }

    void process(const ProcessContext& context) override {
        const float* trigger = context.inputs[0];
        const float* note = context.inputs[1];
        float* out = context.outputs[0];

        if (trigger != nullptr) {
            const bool open = trigger[0] > 0.5f;
            if (open && !trigger_was_open_) {
                int phrase = 0;
                if (note != nullptr && note[0] > 0.0f) {
                    const float root = parameter(kRoot);
                    phrase = static_cast<int>(std::lround(
                        12.0 * std::log2(static_cast<double>(note[0]) / root)));
                }
                if (phrase < 0) {
                    phrase = 0;
                }
                if (phrase >= phrase_count_ && phrase_count_ > 0) {
                    phrase = phrase_count_ - 1;
                }
                start(phrase);
            }
            trigger_was_open_ = open;
        }

        const float level = parameter(kLevel);
        // The 8 kHz voice is lifted to the host rate by linear interpolation; a
        // Speak & Spell through a proper reconstruction filter would no longer
        // sound like a Speak & Spell.
        const float step = static_cast<float>(kSpeechRate) / host_rate_;
        for (int i = 0; i < context.frames; ++i) {
            resample_phase_ += step;
            while (resample_phase_ >= 1.0f) {
                resample_phase_ -= 1.0f;
                previous_ = held_;
                held_ = synthesize();
            }
            out[i] = (previous_ + (held_ - previous_) * resample_phase_) * level;
        }
    }

private:
    // Walks the bitstream once, recording where each stop-delimited phrase begins.
    // In prepare rather than process: the scan allocates nothing but still costs a
    // pass over the data, which is a load-time price, not a per-trigger one.
    void scan_phrases() {
        phrase_count_ = 0;
        if (data_ == nullptr || data_frames_ <= 0) {
            return;
        }
        int bit = 0;
        const int total_bits = data_frames_ * 8;
        phrase_starts_[phrase_count_++] = 0;
        auto peek = [&](int count) {
            int value = 0;
            for (int b = 0; b < count && bit < total_bits; ++b, ++bit) {
                const int byte = static_cast<int>(std::lround(
                    static_cast<double>(data_[bit >> 3]) * 32768.0)) & 0xff;
                value |= ((byte >> (bit & 7)) & 1) << b;
            }
            return value;
        };
        while (bit + 4 <= total_bits && phrase_count_ < kMaxPhrases) {
            const int energy = peek(4);
            if (energy == 15) {
                // A new phrase needs room for at least a frame behind it. The
                // stream is byte-padded, so up to seven zero bits trail the last
                // stop — counting those as a phrase made the bank one silent
                // entry longer than what was spoken, and the top-of-bank clamp
                // landed on the silence.
                if (bit + 12 <= total_bits) {
                    phrase_starts_[phrase_count_++] = bit;
                }
                continue;
            }
            if (energy == 0) {
                continue;
            }
            const int repeat = peek(1);
            const int pitch = kSpeechPitch[peek(6) & 63];
            if (repeat != 0) {
                continue;
            }
            const int stages = pitch != 0 ? 10 : 4;
            for (int i = 0; i < stages; ++i) {
                peek(kSpeechKBits[i]);
            }
        }
    }

    void start(int phrase) {
        current_phrase_ = phrase_count_ > 0
            ? (phrase < phrase_count_ ? phrase : phrase_count_ - 1) : 0;
        bit_position_ = phrase_count_ > 0 ? phrase_starts_[current_phrase_] : 0;
        period_index_ = 0;
        period_sample_ = 0;
        chirp_position_ = 0;
        playing_ = data_ != nullptr && data_frames_ > 0;
        energy_now_ = 0.0f;
        if (playing_) {
            read_frame();
            // The first frame starts where it means to rather than gliding up
            // from silence-shaped parameters.
            for (int i = 0; i < 10; ++i) {
                k_now_[i] = k_target_[i];
            }
            energy_now_ = energy_target_;
            pitch_now_ = pitch_target_;
        }
    }

    // One byte per pcm16 sample, low eight bits; bits LSB-first, the chip's order.
    int read_bits(int count) {
        int value = 0;
        for (int b = 0; b < count; ++b) {
            const int index = bit_position_ >> 3;
            if (index >= data_frames_) {
                playing_ = false;
                return value;
            }
            const int byte = static_cast<int>(
                std::lround(static_cast<double>(data_[index]) * 32768.0)) & 0xff;
            value |= ((byte >> (bit_position_ & 7)) & 1) << b;
            ++bit_position_;
        }
        return value;
    }

    void read_frame() {
        const int energy = read_bits(4);
        if (!playing_) {
            return;
        }
        if (energy == 15) {   // this phrase's stop, not necessarily the stream's
            if (parameter(kLoop) > 0.5f) {
                start(current_phrase_);
            } else {
                energy_target_ = 0.0f;
                playing_ = false;
            }
            return;
        }
        energy_target_ = kSpeechEnergy[energy] / 128.0f;
        if (energy == 0) {   // silent frame: parameters hold, the voice rests
            return;
        }
        const int repeat = read_bits(1);
        const int pitch = kSpeechPitch[read_bits(6) & 63];
        voiced_ = pitch != 0;
        pitch_target_ = voiced_ ? static_cast<float>(pitch) : pitch_target_;
        if (repeat != 0) {
            return;   // energy and pitch move, the mouth shape stays
        }
        const int stages = voiced_ ? 10 : 4;
        for (int i = 0; i < stages; ++i) {
            const int index = read_bits(kSpeechKBits[i]);
            k_target_[i] = static_cast<float>(kSpeechKTables[i][index]) / 512.0f;
        }
        for (int i = stages; i < 10; ++i) {
            k_target_[i] = 0.0f;
        }
    }

    // One sample of the 8 kHz voice.
    float synthesize() {
        if (!playing_ && energy_now_ < 0.0005f) {
            return 0.0f;
        }
        // Sub-frame boundaries: glide the parameters, and fetch the next frame
        // when the ladder has walked all eight periods.
        if (period_sample_ == 0) {
            const float glide = kSpeechGlide[period_index_];
            for (int i = 0; i < 10; ++i) {
                k_now_[i] += (k_target_[i] - k_now_[i]) * glide;
            }
            energy_now_ += (energy_target_ - energy_now_) * glide;
            pitch_now_ += (pitch_target_ - pitch_now_) * glide;
        }
        // The speed knob stretches the frame clock and nothing else.
        const int period_length = static_cast<int>(
            static_cast<float>(kSpeechPeriodLength) / parameter(kSpeed));
        if (++period_sample_ >= (period_length > 1 ? period_length : 1)) {
            period_sample_ = 0;
            if (++period_index_ >= 8) {
                period_index_ = 0;
                if (playing_) {
                    read_frame();
                }
            }
        }

        // Excitation: the chirp at the pitch period, or noise. The pitch knob
        // shortens the period, not the frame clock — helium, not fast-forward.
        float excitation;
        if (voiced_) {
            const int period = static_cast<int>(pitch_now_ / parameter(kPitch));
            if (++chirp_position_ >= (period > 2 ? period : 2)) {
                chirp_position_ = 0;
            }
            excitation = chirp_position_ < 52
                ? static_cast<float>(kSpeechChirp[chirp_position_]) / 128.0f
                : 0.0f;
        } else {
            noise_ ^= noise_ << 13;
            noise_ ^= noise_ >> 17;
            noise_ ^= noise_ << 5;
            excitation = (noise_ & 1) != 0 ? 0.5f : -0.5f;
        }

        // The ten-stage all-pole lattice, energy at the door.
        float forward = excitation * energy_now_;
        for (int i = 9; i >= 0; --i) {
            forward -= k_now_[i] * lattice_[i];
            if (i < 9) {
                lattice_[i + 1] = lattice_[i] + k_now_[i] * forward;
            }
        }
        lattice_[0] = forward;
        return dsp::clampf(forward, -1.2f, 1.2f);
    }

    const float* data_ = nullptr;
    int data_frames_ = 0;
    float host_rate_ = 48000.0f;

    static constexpr int kMaxPhrases = 64;
    int phrase_starts_[kMaxPhrases] = {};
    int phrase_count_ = 0;
    int current_phrase_ = 0;

    bool playing_ = false;
    bool trigger_was_open_ = false;
    int bit_position_ = 0;
    int period_index_ = 0;
    int period_sample_ = 0;
    int chirp_position_ = 0;
    bool voiced_ = false;
    unsigned int noise_ = 0x1234u;

    float k_now_[10] = {};
    float k_target_[10] = {};
    float lattice_[10] = {};
    float energy_now_ = 0.0f;
    float energy_target_ = 0.0f;
    float pitch_now_ = 40.0f;
    float pitch_target_ = 40.0f;

    float resample_phase_ = 1.0f;
    float held_ = 0.0f;
    float previous_ = 0.0f;
};

template <typename T>
std::unique_ptr<DspNode> make() {
    return std::unique_ptr<DspNode>(new T());
}

}  // namespace

const NodeTypeDescriptor kSpeech = {
    "Speech", "Speak", "Sources",
    "A Speak & Spell voice: TMS5220-style LPC frames carried in the patch, spoken "
    "through the chip's own tables. tools/lpc-encode.mjs turns any WAV into words.",
    "speech|speak|talk|talking|voice|words|say|lpc|speak and spell|speak & spell|"
    "tms5220|texas instruments|robot|robot voice|vocoder|phrase|spell|dalek",
    Slice<PortDescriptor>(kSpeechInputs),
    Slice<PortDescriptor>(kSpeechOutputs),
    Slice<ParameterDescriptor>(kSpeechParameters),
    false, NodeRole::Processor, false,
    ResourceCost{4.0f, 128, 0},
    &make<SpeechNode>,
};

}  // namespace nodes
}  // namespace soundgraph
