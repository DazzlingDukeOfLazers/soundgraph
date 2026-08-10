// The DX7 oracle: renders one voice of a 32-voice SysEx bank through msfa — the
// music-synthesizer-for-android engine (Apache 2.0, vendored under
// tests/dx7/reference/), the same core Dexed builds on — so the imported patches
// have the real thing to be measured against.
//
//   dx7-ref <bank.syx> <voice 0-31> <out.wav> [--seconds N] [--note MIDI] [--gate F]
//
// One note, key-on for the gate fraction of the render, exactly the performance
// sg-render gives the imported patch. Output is mono 48 kHz.
//
// Same isolation rule as the sfxr and Nuked oracles: this links the vendored engine
// and the WAV writer, and nothing links it.

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

#include "synth.h"
#include "freqlut.h"
#include "sin.h"
#include "exp2.h"
#include "pitchenv.h"
#include "env.h"
#include "lfo.h"
#include "patch.h"
#include "controllers.h"
#include "dx7note.h"
#include "wav.h"

namespace {
constexpr double kSampleRate = 48000.0;
}

int main(int argc, char** argv) {
    if (argc < 4) {
        std::fprintf(stderr,
            "usage: dx7-ref <bank.syx> <voice 0-31> <out.wav> "
            "[--seconds N] [--note MIDI] [--gate F] [--velocity 0-127]\n");
        return 2;
    }
    const std::string bank_path = argv[1];
    const int voice_index = std::atoi(argv[2]);
    const std::string wav_path = argv[3];
    double seconds = 2.0;
    int note = 57;
    double gate = 0.7;
    int velocity = 100;
    for (int i = 4; i + 1 < argc; i += 2) {
        if (std::strcmp(argv[i], "--seconds") == 0) seconds = std::atof(argv[i + 1]);
        if (std::strcmp(argv[i], "--note") == 0) note = std::atoi(argv[i + 1]);
        if (std::strcmp(argv[i], "--gate") == 0) gate = std::atof(argv[i + 1]);
        if (std::strcmp(argv[i], "--velocity") == 0) velocity = std::atoi(argv[i + 1]);
    }
    if (voice_index < 0 || voice_index > 31) {
        std::fprintf(stderr, "voice index must be 0-31\n");
        return 2;
    }

    std::ifstream file(bank_path, std::ios::binary);
    if (!file) {
        std::fprintf(stderr, "could not open %s\n", bank_path.c_str());
        return 1;
    }
    std::vector<char> bytes((std::istreambuf_iterator<char>(file)),
                            std::istreambuf_iterator<char>());
    // Find the bulk data: F0 43 0n 09 20 00, then 4096 bytes.
    std::size_t start = 0;
    bool found = false;
    for (; start + 6 + 4096 <= bytes.size(); ++start) {
        if (static_cast<unsigned char>(bytes[start]) == 0xf0 &&
            static_cast<unsigned char>(bytes[start + 1]) == 0x43 &&
            static_cast<unsigned char>(bytes[start + 3]) == 0x09) {
            found = true;
            break;
        }
    }
    if (!found) {
        std::fprintf(stderr, "%s is not a DX7 32-voice bank\n", bank_path.c_str());
        return 1;
    }
    const char* packed = bytes.data() + start + 6 + voice_index * 128;

    char unpacked[156];
    UnpackPatch(packed, unpacked);

    Freqlut::init(kSampleRate);
    Exp2::init();
    Tanh::init();
    Sin::init();
    Lfo::init(kSampleRate);
    PitchEnv::init(kSampleRate);

    Lfo lfo;
    lfo.reset(unpacked + 137);
    Controllers controllers;
    std::memset(controllers.values_, 0, sizeof(controllers.values_));
    controllers.values_[kControllerPitch] = 0x2000;  // pitch wheel centred

    Dx7Note dx7_note;
    dx7_note.init(unpacked, note, velocity);
    lfo.keydown();

    const int total = static_cast<int>(seconds * kSampleRate);
    const int held = static_cast<int>(total * gate);
    std::vector<float> samples;
    samples.reserve(static_cast<std::size_t>(total));

    int rendered = 0;
    bool released = false;
    while (rendered < total) {
        if (!released && rendered >= held) {
            dx7_note.keyup();
            released = true;
        }
        int32_t buf[N];
        std::memset(buf, 0, sizeof(buf));
        const int32_t lfo_value = lfo.getsample();
        const int32_t lfo_delay = lfo.getdelay();
        dx7_note.compute(buf, lfo_value, lfo_delay, &controllers);
        for (int i = 0; i < N && rendered < total; ++i, ++rendered) {
            // The engine works in Q24, but a full-level operator swings +-2^25 (its
            // gain is 2^(10 + level/2^24), which tops out at 2^25 — see the index
            // derivation in tools/dx7-import.mjs), and a voice sums up to six
            // carriers. The original /2^24 clipped every full-level voice at the
            // 16-bit writer, which tools/dx7-index-check.mjs caught as phantom odd
            // harmonics. /2^27 keeps even a phase-aligned six-carrier peak inside
            // +-1 while the quietest voices stay far above the comparators' floors.
            // Fixed scale on purpose: an oracle's level should not depend on the
            // voice's own peak.
            samples.push_back(static_cast<float>(buf[i]) / static_cast<float>(1 << 27));
        }
    }

    soundgraph::AudioFile audio;
    audio.sample_rate = static_cast<int>(kSampleRate);
    audio.channels = 1;
    audio.samples = std::move(samples);
    std::string error;
    if (!soundgraph::write_wav(wav_path, audio, error)) {
        std::fprintf(stderr, "could not write %s: %s\n", wav_path.c_str(), error.c_str());
        return 1;
    }
    std::printf("%s voice %d -> %s (note %d, %.1fs)\n", bank_path.c_str(), voice_index,
        wav_path.c_str(), note, seconds);
    return 0;
}
