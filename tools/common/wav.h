// Minimal WAV reading and writing for offline rendering and golden tests.
//
// Deliberately outside dsp-core: file formats are a host concern.
#pragma once

#include <string>
#include <vector>

namespace soundgraph {

struct AudioFile {
    int sample_rate = 48000;
    int channels = 2;
    std::vector<float> samples;  // interleaved

    int frames() const {
        return channels > 0 ? static_cast<int>(samples.size()) / channels : 0;
    }
};

// Writes 16-bit PCM. Golden comparisons happen on float data before quantisation, so
// 16 bits here is about listening, not about test fidelity.
bool write_wav(const std::string& path, const AudioFile& audio, std::string& error);

// Writes 32-bit float PCM. Used for golden vectors, where quantisation would hide
// exactly the differences the test is looking for.
bool write_wav_float(const std::string& path, const AudioFile& audio, std::string& error);

bool read_wav(const std::string& path, AudioFile& audio, std::string& error);

}  // namespace soundgraph
