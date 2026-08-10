// The OPL2 oracle: renders an SBI instrument through Nuked-OPL3, the accepted accuracy
// benchmark for the chip, so the imported patches have a real sound to be measured
// against instead of a fitted curve and a hopeful comment.
//
//   opl2-ref <instrument.sbi> <out.wav> [--seconds N] [--frequency HZ] [--gate F]
//
// One channel, 2-op mode, key on for the gate fraction of the render and off for the
// rest — the same envelope a sg-render note gets, which is what makes the two WAVs
// comparable. Output is mono 48 kHz, using the emulator's own resampler.
//
// Like the sfxr reference: this links the vendored emulator under tests/opl2/reference
// (LGPL 2.1, licence alongside) and the WAV writer, and nothing links it — dsp-core
// must not acquire a dependency on the thing it is measured against.

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

extern "C" {
#include "opl3.h"
}
#include "wav.h"

namespace {

constexpr double kSampleRate = 48000.0;

struct Sbi {
    char name[33] = {};
    uint8_t reg[11] = {};
};

bool read_sbi(const std::string& path, Sbi& out) {
    std::ifstream file(path, std::ios::binary);
    if (!file) return false;
    char magic[4];
    if (!file.read(magic, 4) || std::memcmp(magic, "SBI\x1a", 4) != 0) return false;
    if (!file.read(out.name, 32)) return false;
    out.name[32] = '\0';
    return static_cast<bool>(
        file.read(reinterpret_cast<char*>(out.reg), sizeof(out.reg)));
}

// The fnum/block pair whose chip frequency lands nearest the request.
// f = fnum * 49716 / 2^(20 - block); higher blocks trade resolution for range.
void pitch_registers(double frequency, uint8_t& low, uint8_t& high_key_on) {
    int best_block = 0;
    int best_fnum = 0;
    double best_error = 1e9;
    for (int block = 0; block < 8; ++block) {
        const double scale = 49716.0 / std::pow(2.0, 20 - block);
        const int fnum = static_cast<int>(std::lround(frequency / scale));
        if (fnum < 1 || fnum > 1023) continue;
        const double error = std::abs(fnum * scale - frequency);
        if (error < best_error) {
            best_error = error;
            best_block = block;
            best_fnum = fnum;
        }
    }
    low = static_cast<uint8_t>(best_fnum & 0xff);
    high_key_on = static_cast<uint8_t>(0x20 | (best_block << 2) | (best_fnum >> 8));
}

}  // namespace

int main(int argc, char** argv) {
    if (argc < 3) {
        std::fprintf(stderr,
            "usage: opl2-ref <instrument.sbi> <out.wav> "
            "[--seconds N] [--frequency HZ] [--gate F]\n");
        return 2;
    }
    const std::string sbi_path = argv[1];
    const std::string wav_path = argv[2];
    double seconds = 2.0;
    double frequency = 220.0;
    double gate = 0.7;
    for (int i = 3; i + 1 < argc; i += 2) {
        if (std::strcmp(argv[i], "--seconds") == 0) seconds = std::atof(argv[i + 1]);
        if (std::strcmp(argv[i], "--frequency") == 0) frequency = std::atof(argv[i + 1]);
        if (std::strcmp(argv[i], "--gate") == 0) gate = std::atof(argv[i + 1]);
    }

    Sbi sbi;
    if (!read_sbi(sbi_path, sbi)) {
        std::fprintf(stderr, "could not read %s as an SBI instrument\n",
            sbi_path.c_str());
        return 1;
    }

    opl3_chip chip;
    OPL3_Reset(&chip, static_cast<uint32_t>(kSampleRate));

    // Channel 0's two operator slots sit at offsets 0x00 (modulator) and 0x03
    // (carrier) in each per-operator register bank. NEW stays 0: this is an OPL2
    // instrument and it gets OPL2 behaviour.
    const uint16_t mod = 0x00;
    const uint16_t car = 0x03;
    OPL3_WriteReg(&chip, 0x20 + mod, sbi.reg[0]);
    OPL3_WriteReg(&chip, 0x20 + car, sbi.reg[1]);
    OPL3_WriteReg(&chip, 0x40 + mod, sbi.reg[2]);
    OPL3_WriteReg(&chip, 0x40 + car, sbi.reg[3]);
    OPL3_WriteReg(&chip, 0x60 + mod, sbi.reg[4]);
    OPL3_WriteReg(&chip, 0x60 + car, sbi.reg[5]);
    OPL3_WriteReg(&chip, 0x80 + mod, sbi.reg[6]);
    OPL3_WriteReg(&chip, 0x80 + car, sbi.reg[7]);
    OPL3_WriteReg(&chip, 0xE0 + mod, sbi.reg[8]);
    OPL3_WriteReg(&chip, 0xE0 + car, sbi.reg[9]);
    OPL3_WriteReg(&chip, 0xC0, static_cast<uint8_t>(sbi.reg[10] | 0x30));

    uint8_t low = 0;
    uint8_t high = 0;
    pitch_registers(frequency, low, high);
    OPL3_WriteReg(&chip, 0xA0, low);
    OPL3_WriteReg(&chip, 0xB0, high);  // key on

    const int total = static_cast<int>(seconds * kSampleRate);
    const int held = static_cast<int>(total * gate);
    std::vector<float> samples(static_cast<std::size_t>(total));
    for (int i = 0; i < total; ++i) {
        if (i == held) {
            OPL3_WriteReg(&chip, 0xB0, static_cast<uint8_t>(high & ~0x20));  // key off
        }
        int16_t frame[2];
        OPL3_GenerateResampled(&chip, frame);
        samples[static_cast<std::size_t>(i)] =
            static_cast<float>(frame[0]) / 32768.0f;
    }

    soundgraph::AudioFile audio;
    audio.sample_rate = static_cast<int>(kSampleRate);
    audio.channels = 1;
    audio.samples = std::move(samples);
    std::string error;
    if (!soundgraph::write_wav(wav_path, audio, error)) {
        std::fprintf(stderr, "could not write %s: %s\n", wav_path.c_str(),
            error.c_str());
        return 1;
    }
    std::printf("%s -> %s (%s, %.0f Hz, %.1fs)\n", sbi_path.c_str(),
        wav_path.c_str(), sbi.name, frequency, seconds);
    return 0;
}
