// sfxr-ref — renders the sfxr reference, so the SoundGraph port has something to be
// measured against.
//
//   sfxr-ref corpus <dir> [--per-preset N]
//   sfxr-ref render --preset <name> --seed <n> --out <file.wav>
//
// `corpus` writes a reproducible body of test material: sfxr's seven generators, each run
// with a spread of seeds, rendered to 32-bit float WAV and described in a manifest. The
// point of the spread is that a port which happens to match one coin sound has not been
// shown to work — the generators reach very different corners of the model depending on
// which branches their randomness takes, and it is those corners that find bugs.
//
// Nothing here is part of SoundGraph. It links the vendored reference under tests/ and the
// WAV writer, and neither dsp-core nor any runtime depends on it.

#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "sfxr_reference.h"
#include "wav.h"

namespace {

const sfxr_reference::Preset kPresets[] = {
    sfxr_reference::Preset::PickupCoin, sfxr_reference::Preset::LaserShoot,
    sfxr_reference::Preset::Explosion,  sfxr_reference::Preset::Powerup,
    sfxr_reference::Preset::HitHurt,    sfxr_reference::Preset::Jump,
    sfxr_reference::Preset::BlipSelect,
};

// Seeds are fixed rather than drawn from the clock: a corpus that changes every time it is
// generated cannot be committed, and a test that compares against a moving target is not a
// test. Spread out so that consecutive cases take different branches.
unsigned int seed_for(int preset_index, int repeat) {
    return 1000003u * static_cast<unsigned int>(preset_index + 1) +
           7919u * static_cast<unsigned int>(repeat) + 12345u;
}

std::string json_float(float value) {
    // Enough digits to reproduce a float exactly, so a case file is a faithful record of
    // what was rendered rather than a rounded description of it.
    char buffer[64];
    std::snprintf(buffer, sizeof(buffer), "%.9g", static_cast<double>(value));
    return buffer;
}

std::string params_to_json(const sfxr_reference::Params& p, const char* indent) {
    std::string out;
    auto field = [&](const char* name, const std::string& value, bool last = false) {
        out += indent;
        out += "\"";
        out += name;
        out += "\": ";
        out += value;
        out += last ? "\n" : ",\n";
    };
    field("wave_type", std::to_string(p.wave_type));
    field("p_base_freq", json_float(p.p_base_freq));
    field("p_freq_limit", json_float(p.p_freq_limit));
    field("p_freq_ramp", json_float(p.p_freq_ramp));
    field("p_freq_dramp", json_float(p.p_freq_dramp));
    field("p_duty", json_float(p.p_duty));
    field("p_duty_ramp", json_float(p.p_duty_ramp));
    field("p_vib_strength", json_float(p.p_vib_strength));
    field("p_vib_speed", json_float(p.p_vib_speed));
    field("p_vib_delay", json_float(p.p_vib_delay));
    field("p_env_attack", json_float(p.p_env_attack));
    field("p_env_sustain", json_float(p.p_env_sustain));
    field("p_env_decay", json_float(p.p_env_decay));
    field("p_env_punch", json_float(p.p_env_punch));
    field("p_lpf_resonance", json_float(p.p_lpf_resonance));
    field("p_lpf_freq", json_float(p.p_lpf_freq));
    field("p_lpf_ramp", json_float(p.p_lpf_ramp));
    field("p_hpf_freq", json_float(p.p_hpf_freq));
    field("p_hpf_ramp", json_float(p.p_hpf_ramp));
    field("p_pha_offset", json_float(p.p_pha_offset));
    field("p_pha_ramp", json_float(p.p_pha_ramp));
    field("p_repeat_speed", json_float(p.p_repeat_speed));
    field("p_arp_speed", json_float(p.p_arp_speed));
    field("p_arp_mod", json_float(p.p_arp_mod), true);
    return out;
}

bool write_text(const std::string& path, const std::string& text) {
    FILE* file = std::fopen(path.c_str(), "wb");
    if (file == nullptr) return false;
    std::fwrite(text.data(), 1, text.size(), file);
    std::fclose(file);
    return true;
}

struct Rendered {
    std::vector<float> samples;
    float peak = 0.0f;
    float rms = 0.0f;
    std::size_t non_finite = 0;
};

Rendered render_case(const sfxr_reference::Params& params, unsigned int seed) {
    Rendered result;
    result.samples.resize(sfxr_reference::kMaxSamples);
    std::size_t written =
        sfxr_reference::render(params, seed, result.samples.data(), result.samples.size());
    result.samples.resize(written);

    double sum_squares = 0.0;
    for (float sample : result.samples) {
        if (!std::isfinite(sample)) {
            result.non_finite++;
            continue;
        }
        result.peak = std::fmax(result.peak, std::fabs(sample));
        sum_squares += static_cast<double>(sample) * sample;
    }
    const std::size_t finite = written - result.non_finite;
    result.rms = finite > 0 ? static_cast<float>(std::sqrt(sum_squares / finite)) : 0.0f;
    return result;
}

int usage() {
    std::fprintf(stderr,
                 "usage: sfxr-ref corpus <dir> [--per-preset N]\n"
                 "       sfxr-ref render --preset <name> --seed <n> --out <file.wav>\n");
    return 2;
}

int command_corpus(const std::string& directory, int per_preset) {
    std::string manifest;
    manifest += "{\n";
    manifest += "  \"note\": \"Generated by sfxr-ref. Do not edit by hand; run "
                "'sfxr-ref corpus' instead.\",\n";
    manifest += "  \"sample_rate\": " + std::to_string(sfxr_reference::kSampleRate) + ",\n";
    manifest += "  \"cases\": [\n";

    int written_cases = 0;
    bool first = true;
    for (int preset_index = 0; preset_index < 7; preset_index++) {
        for (int repeat = 0; repeat < per_preset; repeat++) {
            const sfxr_reference::Preset preset = kPresets[preset_index];
            const unsigned int seed = seed_for(preset_index, repeat);
            const sfxr_reference::Params params = sfxr_reference::generate(preset, seed);
            const Rendered rendered = render_case(params, seed);

            const std::string name =
                std::string(sfxr_reference::preset_name(preset)) + "-" +
                std::to_string(repeat);

            // A generator can produce a sound with a zero-length envelope, which renders
            // as nothing. Those are real sfxr outputs but they cannot discriminate between
            // a good port and a broken one, so they are dropped rather than counted as
            // passing cases.
            if (rendered.samples.size() < 512 || rendered.peak < 1e-4f) {
                std::printf("  skip %-18s (silent: %zu samples, peak %.6f)\n", name.c_str(),
                            rendered.samples.size(), static_cast<double>(rendered.peak));
                continue;
            }

            // sfxr can emit NaN. When an envelope stage has zero length, the transition
            // sets env_time to 0 and then evaluates 1 - env_time/env_length in the same
            // iteration, which is 0/0; the result reaches the output because NaN fails
            // both of the clamp comparisons. That is sfxr's real behaviour and the
            // reference reproduces it faithfully — but a vector with a NaN in it cannot
            // discriminate between a good port and a bad one, so it is not a test case.
            if (rendered.non_finite > 0) {
                std::printf("  skip %-18s (%zu non-finite samples: sfxr's zero-length "
                            "envelope stage divides by zero)\n",
                            name.c_str(), rendered.non_finite);
                continue;
            }

            soundgraph::AudioFile audio;
            audio.sample_rate = sfxr_reference::kSampleRate;
            audio.channels = 1;
            audio.samples = rendered.samples;

            const std::string wav_path = directory + "/vectors/" + name + ".wav";
            std::string error;
            if (!soundgraph::write_wav_float(wav_path, audio, error)) {
                std::fprintf(stderr, "could not write %s: %s\n", wav_path.c_str(),
                             error.c_str());
                return 1;
            }

            std::string case_json;
            case_json += "{\n";
            case_json += "  \"name\": \"" + name + "\",\n";
            case_json += "  \"preset\": \"" +
                         std::string(sfxr_reference::preset_name(preset)) + "\",\n";
            case_json += "  \"seed\": " + std::to_string(seed) + ",\n";
            case_json += "  \"sample_rate\": " +
                         std::to_string(sfxr_reference::kSampleRate) + ",\n";
            case_json += "  \"samples\": " + std::to_string(rendered.samples.size()) + ",\n";
            case_json += "  \"params\": {\n";
            case_json += params_to_json(params, "    ");
            case_json += "  }\n";
            case_json += "}\n";
            if (!write_text(directory + "/cases/" + name + ".json", case_json)) {
                std::fprintf(stderr, "could not write case %s\n", name.c_str());
                return 1;
            }

            if (!first) manifest += ",\n";
            first = false;
            manifest += "    {\"name\": \"" + name + "\", \"preset\": \"" +
                        sfxr_reference::preset_name(preset) +
                        "\", \"seed\": " + std::to_string(seed) +
                        ", \"samples\": " + std::to_string(rendered.samples.size()) +
                        ", \"peak\": " + json_float(rendered.peak) +
                        ", \"rms\": " + json_float(rendered.rms) + "}";
            written_cases++;

            std::printf("  ok   %-18s %6zu samples  peak %.4f  rms %.4f\n", name.c_str(),
                        rendered.samples.size(), static_cast<double>(rendered.peak),
                        static_cast<double>(rendered.rms));
        }
    }

    manifest += "\n  ]\n}\n";
    if (!write_text(directory + "/manifest.json", manifest)) {
        std::fprintf(stderr, "could not write manifest\n");
        return 1;
    }

    std::printf("\n%d cases written to %s\n", written_cases, directory.c_str());
    return written_cases > 0 ? 0 : 1;
}

int command_render(const std::string& preset_name, unsigned int seed,
                   const std::string& out_path) {
    sfxr_reference::Preset preset;
    if (!sfxr_reference::preset_from_name(preset_name.c_str(), &preset)) {
        std::fprintf(stderr, "unknown preset: %s\n", preset_name.c_str());
        return 2;
    }
    const sfxr_reference::Params params = sfxr_reference::generate(preset, seed);
    const Rendered rendered = render_case(params, seed);

    soundgraph::AudioFile audio;
    audio.sample_rate = sfxr_reference::kSampleRate;
    audio.channels = 1;
    audio.samples = rendered.samples;

    std::string error;
    if (!soundgraph::write_wav_float(out_path, audio, error)) {
        std::fprintf(stderr, "could not write %s: %s\n", out_path.c_str(), error.c_str());
        return 1;
    }
    std::printf("%zu samples, peak %.4f, rms %.4f -> %s\n", rendered.samples.size(),
                static_cast<double>(rendered.peak), static_cast<double>(rendered.rms),
                out_path.c_str());
    return 0;
}

}  // namespace

int main(int argc, char** argv) {
    if (argc < 2) return usage();
    const std::string command = argv[1];

    if (command == "corpus") {
        if (argc < 3) return usage();
        const std::string directory = argv[2];
        int per_preset = 6;
        for (int i = 3; i < argc; i++) {
            if (std::strcmp(argv[i], "--per-preset") == 0 && i + 1 < argc)
                per_preset = std::atoi(argv[++i]);
            else
                return usage();
        }
        return command_corpus(directory, per_preset);
    }

    if (command == "render") {
        std::string preset;
        std::string out_path;
        unsigned int seed = 12345u;
        for (int i = 2; i < argc; i++) {
            if (std::strcmp(argv[i], "--preset") == 0 && i + 1 < argc)
                preset = argv[++i];
            else if (std::strcmp(argv[i], "--seed") == 0 && i + 1 < argc)
                seed = static_cast<unsigned int>(std::strtoul(argv[++i], nullptr, 10));
            else if (std::strcmp(argv[i], "--out") == 0 && i + 1 < argc)
                out_path = argv[++i];
            else
                return usage();
        }
        if (preset.empty() || out_path.empty()) return usage();
        return command_render(preset, seed, out_path);
    }

    return usage();
}
