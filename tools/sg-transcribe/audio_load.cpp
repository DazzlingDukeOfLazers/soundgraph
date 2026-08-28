// miniaudio's translation unit for this tool: decoders on, sound card off.
#define MINIAUDIO_IMPLEMENTATION
#define MA_NO_DEVICE_IO
#define MA_NO_ENGINE
#define MA_NO_ENCODING
#define MA_NO_GENERATION
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#include "miniaudio.h"

#include "audio_load.h"

namespace transcribe {

bool load_audio(const std::string& path, Audio& out, std::string& error) {
    // Float samples, but the file's own rate and channel count: 0 means "whatever it
    // already is". Converting here would put a second resampler in front of the one
    // that was actually measured.
    ma_decoder_config config = ma_decoder_config_init(ma_format_f32, 0, 0);

    ma_decoder decoder;
    if (ma_decoder_init_file(path.c_str(), &config, &decoder) != MA_SUCCESS) {
        error = "could not read '" + path + "' - " + supported_formats() +
                ". For anything else, convert it to WAV first.";
        return false;
    }

    out.channels = static_cast<int>(decoder.outputChannels);
    out.sample_rate = static_cast<int>(decoder.outputSampleRate);
    if (out.channels <= 0 || out.sample_rate <= 0) {
        ma_decoder_uninit(&decoder);
        error = "'" + path + "' claims " + std::to_string(out.channels) +
                " channels at " + std::to_string(out.sample_rate) + " Hz";
        return false;
    }

    // A length is available for every format miniaudio decodes, but it is allowed to
    // fail - a stream with no seek table, for instance - so this reads in blocks and
    // keeps going until the decoder says there is no more, rather than trusting a
    // count it might not have.
    constexpr ma_uint64 kBlockFrames = 4096;
    std::vector<float> block(static_cast<size_t>(kBlockFrames) * out.channels);
    out.samples.clear();

    ma_uint64 total = 0;
    if (ma_decoder_get_length_in_pcm_frames(&decoder, &total) == MA_SUCCESS && total > 0) {
        out.samples.reserve(static_cast<size_t>(total) * out.channels);
    }

    while (true) {
        ma_uint64 read = 0;
        const ma_result result =
            ma_decoder_read_pcm_frames(&decoder, block.data(), kBlockFrames, &read);
        if (read > 0) {
            out.samples.insert(out.samples.end(), block.begin(),
                               block.begin() + static_cast<size_t>(read) * out.channels);
        }
        if (result != MA_SUCCESS || read < kBlockFrames) break;
    }

    ma_decoder_uninit(&decoder);

    if (out.samples.empty()) {
        error = "'" + path + "' decoded to no audio at all";
        return false;
    }
    return true;
}

const char* supported_formats() {
    return "WAV, FLAC and MP3 are understood";
}

}  // namespace transcribe
