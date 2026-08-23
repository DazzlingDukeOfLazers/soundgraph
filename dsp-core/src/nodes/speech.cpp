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

#include <cmath>
#include <memory>

#include "dsp_math.h"
#include "nodes/node_types.h"

namespace soundgraph {
namespace nodes {
namespace {

// ---------------------------------------------------------------------------------
// The TMS5220 coefficient ROM.
// ---------------------------------------------------------------------------------

constexpr float kSpeechEnergy[16] = {0, 1, 2, 3, 4, 6, 8, 11, 16, 23, 33, 47, 63, 85, 114, 0};

constexpr int kSpeechPitch[64] = {
    0,   15,  16,  17,  18,  19,  20,  21,  22,  23,  24,  25,  26,  27,  28,  29,
    30,  31,  32,  33,  34,  35,  36,  37,  38,  39,  40,  41,  42,  44,  46,  48,
    50,  52,  53,  56,  58,  60,  62,  65,  68,  70,  72,  76,  78,  80,  84,  86,
    91,  94,  98,  101, 105, 109, 114, 118, 122, 127, 132, 137, 142, 148, 153, 159};

constexpr int kSpeechK1[32] = {
    -501, -498, -497, -495, -493, -491, -488, -482, -478, -474, -469, -464, -459, -452,
    -445, -437, -412, -380, -339, -288, -227, -158, -81,  -1,   80,   157,  226,  287,
    337,  379,  411,  436};
constexpr int kSpeechK2[32] = {
    -328, -303, -274, -244, -211, -175, -138, -99, -59, -18, 24,  64,  105, 143,
    180,  215,  248,  278,  306,  331,  354,  374, 392, 408, 422, 435, 445, 455,
    463,  470,  476,  506};
constexpr int kSpeechK3[16] = {-441, -387, -333, -279, -225, -171, -117, -63,
                               -9,   45,   98,   152,  206,  260,  314,  368};
constexpr int kSpeechK4[16] = {-328, -273, -217, -161, -106, -50,  5,    61,
                               116,  172,  228,  283,  339,  394,  450,  506};
constexpr int kSpeechK5[16] = {-328, -282, -235, -189, -142, -96,  -50,  -3,
                               43,   90,   136,  182,  229,  275,  322,  368};
constexpr int kSpeechK6[16] = {-256, -212, -168, -123, -79,  -35,  10,   54,
                               98,   143,  187,  232,  276,  320,  365,  409};
constexpr int kSpeechK7[16] = {-308, -260, -212, -164, -117, -69,  -21,  27,
                               75,   122,  170,  218,  266,  314,  361,  409};
constexpr int kSpeechK8[8] = {-256, -161, -66, 29, 124, 219, 314, 409};
constexpr int kSpeechK9[8] = {-256, -176, -96, -15, 65, 146, 226, 307};
constexpr int kSpeechK10[8] = {-205, -132, -59, 14, 87, 160, 234, 307};

constexpr const int* kSpeechKTables[10] = {
    kSpeechK1, kSpeechK2, kSpeechK3, kSpeechK4, kSpeechK5,
    kSpeechK6, kSpeechK7, kSpeechK8, kSpeechK9, kSpeechK10};
constexpr int kSpeechKBits[10] = {5, 5, 4, 4, 4, 4, 4, 3, 3, 3};

// The voiced excitation: one glottal chirp, replayed every pitch period.
constexpr int kSpeechChirp[52] = {
    0x00, 0x03, 0x0f, 0x28, 0x4c, 0x6c, 0x71, 0x50, 0x25, 0x26, 0x4c, 0x44, 0x1a,
    0x32, 0x3b, 0x13, 0x37, 0x1a, 0x25, 0x1f, 0x1d, 0,    0,    0,    0,    0,
    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,
    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0};

// The interpolation ladder: how much of the gap to the next frame's parameters is
// closed at each of the eight sub-frame boundaries, ending on the target exactly.
constexpr float kSpeechGlide[8] = {0.125f, 0.125f, 0.125f, 0.25f, 0.25f, 0.5f, 0.5f, 1.0f};

constexpr int kSpeechRate = 8000;
constexpr int kSpeechFrame = 200;   // 25 ms
constexpr int kSpeechPeriodLength = kSpeechFrame / 8;

constexpr PortDescriptor kSpeechInputs[] = {
    {"trigger", SignalType::Control, "", false, false,
     "Starts the phrase from the top on a rising edge. The keyboard's trigger "
     "makes every key a talk button."},
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
};

class SpeechNode final : public DspNode {
public:
    enum Param { kPitch = 0, kSpeed = 1, kLevel = 2, kLoop = 3 };

    void prepare(const PrepareContext& context) override {
        host_rate_ = static_cast<float>(context.sample_rate);
        data_ = context.buffer_data;
        data_frames_ = context.buffer_frames;
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
        float* out = context.outputs[0];

        if (trigger != nullptr) {
            const bool open = trigger[0] > 0.5f;
            if (open && !trigger_was_open_) {
                start();
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
    void start() {
        bit_position_ = 0;
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
        if (energy == 15) {   // stop
            if (parameter(kLoop) > 0.5f) {
                start();
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
