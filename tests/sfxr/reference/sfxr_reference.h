// sfxr's synthesis model, vendored as a test oracle.
//
// Original: sfxr by DrPetter (Tomas Pettersson), 2007, MIT — see LICENSE.txt.
// Source: https://github.com/grimfang4/sfxr  (sfxr/source/main.cpp)
//
// This is the *reference*, not an implementation SoundGraph ships. It exists so the
// SoundGraph port can be measured against the thing it claims to reproduce, rather than
// against a second implementation written by whoever wrote the first one. It lives under
// tests/ and nothing in dsp-core, patch-io or any runtime links it.
//
// See README.md in this directory for what was changed and why.

#ifndef SOUNDGRAPH_SFXR_REFERENCE_H
#define SOUNDGRAPH_SFXR_REFERENCE_H

#include <cstddef>

namespace sfxr_reference {

// sfxr's parameter set, one-for-one with the sliders in its UI and with the fields of a
// .sfs file. Names are the original's, so the mapping to a SoundGraph patch can be read
// against sfxr's own source without translation.
struct Params {
    int wave_type = 0;  // 0 square, 1 saw, 2 sine, 3 noise

    float p_base_freq = 0.3f;
    float p_freq_limit = 0.0f;
    float p_freq_ramp = 0.0f;
    float p_freq_dramp = 0.0f;
    float p_duty = 0.0f;
    float p_duty_ramp = 0.0f;

    float p_vib_strength = 0.0f;
    float p_vib_speed = 0.0f;
    float p_vib_delay = 0.0f;

    float p_env_attack = 0.0f;
    float p_env_sustain = 0.3f;
    float p_env_decay = 0.4f;
    float p_env_punch = 0.0f;

    bool filter_on = false;
    float p_lpf_resonance = 0.0f;
    float p_lpf_freq = 1.0f;
    float p_lpf_ramp = 0.0f;
    float p_hpf_freq = 0.0f;
    float p_hpf_ramp = 0.0f;

    float p_pha_offset = 0.0f;
    float p_pha_ramp = 0.0f;

    float p_repeat_speed = 0.0f;

    float p_arp_speed = 0.0f;
    float p_arp_mod = 0.0f;
};

// sfxr's seven generators, by the names on its buttons.
enum class Preset {
    PickupCoin,
    LaserShoot,
    Explosion,
    Powerup,
    HitHurt,
    Jump,
    BlipSelect,
};

const char* preset_name(Preset preset);
bool preset_from_name(const char* name, Preset* out);

// Generates a parameter set the way sfxr's generator buttons do. `seed` drives the
// substitute PRNG (see README.md), so a given preset and seed always give the same
// parameters on every platform — which is what makes a corpus reproducible.
Params generate(Preset preset, unsigned int seed);

// Renders one parameter set at 44100 Hz mono, exactly as sfxr's own playback path does.
// Returns the number of samples written; stops early when the envelope finishes, which is
// sfxr's own definition of where a sound ends. `seed` drives the noise waveform.
//
// Output is sfxr's internal buffer range (its "playback" path, not its WAV export path,
// which applies a further arbitrary ×4 gain).
std::size_t render(const Params& params, unsigned int seed, float* out,
                   std::size_t capacity);

// A generous upper bound on the length of any sfxr sound, in samples at 44100 Hz. The
// envelope stages are each at most 100000 units and the repeat mechanism restarts rather
// than extends, so nothing runs past this.
constexpr std::size_t kMaxSamples = 44100 * 12;
constexpr int kSampleRate = 44100;

}  // namespace sfxr_reference

#endif
