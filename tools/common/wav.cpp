#include "wav.h"

#include <cstdint>
#include <cstring>
#include <fstream>

namespace soundgraph {
namespace {

void put_u32(std::string& out, std::uint32_t value) {
    out.push_back(static_cast<char>(value & 0xFF));
    out.push_back(static_cast<char>((value >> 8) & 0xFF));
    out.push_back(static_cast<char>((value >> 16) & 0xFF));
    out.push_back(static_cast<char>((value >> 24) & 0xFF));
}

void put_u16(std::string& out, std::uint16_t value) {
    out.push_back(static_cast<char>(value & 0xFF));
    out.push_back(static_cast<char>((value >> 8) & 0xFF));
}

std::uint32_t get_u32(const unsigned char* data) {
    return static_cast<std::uint32_t>(data[0]) | (static_cast<std::uint32_t>(data[1]) << 8) |
           (static_cast<std::uint32_t>(data[2]) << 16) | (static_cast<std::uint32_t>(data[3]) << 24);
}

std::uint16_t get_u16(const unsigned char* data) {
    return static_cast<std::uint16_t>(static_cast<std::uint16_t>(data[0]) |
                                      (static_cast<std::uint16_t>(data[1]) << 8));
}

bool write_bytes(const std::string& path, const std::string& bytes, std::string& error) {
    std::ofstream file(path, std::ios::binary);
    if (!file) {
        error = "Could not open '" + path + "' for writing.";
        return false;
    }
    file.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
    if (!file) {
        error = "Failed while writing '" + path + "'.";
        return false;
    }
    return true;
}

std::string build_header(const AudioFile& audio, std::uint16_t format, std::uint16_t bits,
                         std::uint32_t data_bytes) {
    const std::uint16_t channels = static_cast<std::uint16_t>(audio.channels);
    const std::uint32_t sample_rate = static_cast<std::uint32_t>(audio.sample_rate);
    const std::uint16_t block_align = static_cast<std::uint16_t>(channels * bits / 8);
    const std::uint32_t byte_rate = sample_rate * block_align;

    std::string header;
    header += "RIFF";
    put_u32(header, 36 + data_bytes);
    header += "WAVE";
    header += "fmt ";
    put_u32(header, 16);
    put_u16(header, format);
    put_u16(header, channels);
    put_u32(header, sample_rate);
    put_u32(header, byte_rate);
    put_u16(header, block_align);
    put_u16(header, bits);
    header += "data";
    put_u32(header, data_bytes);
    return header;
}

}  // namespace

bool write_wav(const std::string& path, const AudioFile& audio, std::string& error) {
    const std::uint32_t data_bytes = static_cast<std::uint32_t>(audio.samples.size() * 2);
    std::string bytes = build_header(audio, 1, 16, data_bytes);
    bytes.reserve(bytes.size() + data_bytes);

    for (float sample : audio.samples) {
        float clamped = sample;
        if (clamped > 1.0f) clamped = 1.0f;
        if (clamped < -1.0f) clamped = -1.0f;
        const std::int16_t quantised = static_cast<std::int16_t>(clamped * 32767.0f);
        put_u16(bytes, static_cast<std::uint16_t>(quantised));
    }
    return write_bytes(path, bytes, error);
}

bool write_wav_float(const std::string& path, const AudioFile& audio, std::string& error) {
    const std::uint32_t data_bytes = static_cast<std::uint32_t>(audio.samples.size() * 4);
    std::string bytes = build_header(audio, 3, 32, data_bytes);
    bytes.reserve(bytes.size() + data_bytes);

    for (float sample : audio.samples) {
        std::uint32_t raw = 0;
        std::memcpy(&raw, &sample, sizeof(raw));
        put_u32(bytes, raw);
    }
    return write_bytes(path, bytes, error);
}

bool read_wav(const std::string& path, AudioFile& audio, std::string& error) {
    std::ifstream file(path, std::ios::binary);
    if (!file) {
        error = "Could not open '" + path + "'.";
        return false;
    }
    std::string contents((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
    const unsigned char* data = reinterpret_cast<const unsigned char*>(contents.data());
    const std::size_t size = contents.size();

    if (size < 44 || std::memcmp(data, "RIFF", 4) != 0 || std::memcmp(data + 8, "WAVE", 4) != 0) {
        error = "'" + path + "' is not a WAV file.";
        return false;
    }

    std::uint16_t format = 0;
    std::uint16_t bits = 0;
    std::size_t position = 12;
    bool have_format = false;

    while (position + 8 <= size) {
        const char* chunk_id = contents.data() + position;
        const std::uint32_t chunk_size = get_u32(data + position + 4);
        const std::size_t body = position + 8;
        if (body + chunk_size > size) {
            break;
        }

        if (std::memcmp(chunk_id, "fmt ", 4) == 0 && chunk_size >= 16) {
            format = get_u16(data + body);
            audio.channels = get_u16(data + body + 2);
            audio.sample_rate = static_cast<int>(get_u32(data + body + 4));
            bits = get_u16(data + body + 14);
            have_format = true;
        } else if (std::memcmp(chunk_id, "data", 4) == 0) {
            if (!have_format) {
                error = "'" + path + "' has a data chunk before its format chunk.";
                return false;
            }
            audio.samples.clear();
            if (format == 1 && bits == 16) {
                const std::size_t count = chunk_size / 2;
                audio.samples.reserve(count);
                for (std::size_t i = 0; i < count; ++i) {
                    const std::int16_t raw = static_cast<std::int16_t>(get_u16(data + body + i * 2));
                    audio.samples.push_back(static_cast<float>(raw) / 32768.0f);
                }
            } else if (format == 3 && bits == 32) {
                const std::size_t count = chunk_size / 4;
                audio.samples.reserve(count);
                for (std::size_t i = 0; i < count; ++i) {
                    const std::uint32_t raw = get_u32(data + body + i * 4);
                    float sample = 0.0f;
                    std::memcpy(&sample, &raw, sizeof(sample));
                    audio.samples.push_back(sample);
                }
            } else {
                error = "'" + path + "' uses an unsupported sample format.";
                return false;
            }
            return true;
        }

        position = body + chunk_size + (chunk_size & 1);
    }

    error = "'" + path + "' has no data chunk.";
    return false;
}

}  // namespace soundgraph
