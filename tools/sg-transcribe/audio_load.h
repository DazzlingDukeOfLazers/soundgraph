// Reading whatever somebody actually has.
//
// Recordings arrive as MP3 far more often than as WAV, and the WAV they do arrive as is
// usually 24-bit, which the minimal reader in tools/common refuses along with everything
// else that is not 16-bit PCM or 32-bit float. So decoding here goes through miniaudio,
// which is already vendored and has WAV, FLAC and MP3 decoders built in.
//
// Not Ogg Vorbis, despite miniaudio listing it: MA_HAS_VORBIS is defined only
// `#ifdef STB_VORBIS_INCLUDE_STB_VORBIS_H`, and stb_vorbis is not bundled with the
// header. Vorbis would mean vendoring one more file, which nobody has asked for.
//
// Not the copy runtime-native builds: that translation unit defines MA_NO_DECODING,
// because over there miniaudio is a sound card and not a file reader. This one is the
// mirror image - decoders on, device IO off - and shares only the header.
//
// Deliberately decode-only. miniaudio can downmix and resample on the way out, and this
// asks it to do neither: the mixing and the Kaiser resampler downstream are the ones
// that were measured against the Python reference, and swapping them for a different
// implementation would quietly invalidate that agreement.
//
// AAC, and so .m4a and .mp4, is not among the formats. miniaudio has no AAC decoder and
// adding one means a platform codec or another dependency; converting to WAV first is
// the cheaper answer and always available.
#pragma once

#include <string>
#include <vector>

namespace transcribe {

struct Audio {
    std::vector<float> samples;  // interleaved, native channel count
    int sample_rate = 0;
    int channels = 0;

    int frames() const {
        return channels > 0 ? static_cast<int>(samples.size()) / channels : 0;
    }
};

// Reads any format miniaudio can decode, at the file's own rate and channel count.
bool load_audio(const std::string& path, Audio& out, std::string& error);

// What the decoder will take, for the usage text - so the help cannot drift from the
// build's actual capability.
const char* supported_formats();

}  // namespace transcribe
