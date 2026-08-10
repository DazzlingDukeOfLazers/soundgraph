// Small numeric helpers shared by node implementations.
#pragma once

#include <cmath>

#include "sine_table.h"

namespace soundgraph {
namespace dsp {

inline constexpr float kPi = 3.14159265358979323846f;
inline constexpr float kTwoPi = 6.28318530717958647692f;

inline float clampf(float value, float low, float high) {
    return value < low ? low : (value > high ? high : value);
}

// Sine of a phase in [0, 1), from the committed table with linear interpolation.
//
// Not std::sin, deliberately. MSVC, musl (WASM) and xtensa libm each round a handful
// of arguments differently, which is inaudible in an open-loop oscillator and fatal in
// a feedback one: the loop compounds a single ULP of disagreement to full scale in
// under a tenth of a second, and the golden vectors stop being one definition of
// correctness. Table lookup and lerp are plain IEEE arithmetic, which every target
// rounds identically — the same move as the sfxr reference owning its PRNG.
// Interpolation error at 4096 entries is under 3e-7, tighter than libm agreement was.
inline float sine01(float phase01) {
    const float scaled = phase01 * static_cast<float>(kSineTableSize);
    const int index = static_cast<int>(scaled);
    const float fraction = scaled - static_cast<float>(index);
    const float a = kSineTable[index];
    const float b = kSineTable[index + 1];
    return a + (b - a) * fraction;
}

// Wraps a phase in [0, 1). Uses subtraction rather than fmod: the argument is always
// within one period of the range here, and fmod is slow on ESP32.
inline float wrap01(float phase) {
    while (phase >= 1.0f) {
        phase -= 1.0f;
    }
    while (phase < 0.0f) {
        phase += 1.0f;
    }
    return phase;
}

// PolyBLEP: a two-sample correction applied at waveform discontinuities. Without it a
// 440 Hz saw aliases badly enough to be the first thing a listener notices, which would
// undermine the whole "the graph is the synth" claim.
//
// `t` is the phase in [0,1), `dt` the phase increment per sample.
inline float poly_blep(float t, float dt) {
    if (dt <= 0.0f) {
        return 0.0f;
    }
    if (t < dt) {
        const float x = t / dt;
        return x + x - x * x - 1.0f;
    }
    if (t > 1.0f - dt) {
        const float x = (t - 1.0f) / dt;
        return x * x + x + x + 1.0f;
    }
    return 0.0f;
}

// MIDI note number to frequency, A4 = note 69 = 440 Hz.
inline float note_to_frequency(float note) {
    return 440.0f * std::pow(2.0f, (note - 69.0f) / 12.0f);
}

// Deterministic noise source. Seeded explicitly so that golden vectors are reproducible
// across targets — std::rand would not be.
class Xorshift32 {
public:
    explicit Xorshift32(unsigned int seed = 0x9E3779B9u) : state_(seed == 0 ? 0x9E3779B9u : seed) {}

    void seed(unsigned int value) { state_ = (value == 0 ? 0x9E3779B9u : value); }

    unsigned int next_uint() {
        state_ ^= state_ << 13;
        state_ ^= state_ >> 17;
        state_ ^= state_ << 5;
        return state_;
    }

    // Uniform in [-1, 1). The shift leaves 24 bits, so the scale is 2 / 2^24.
    float next_bipolar() {
        return static_cast<float>(next_uint() >> 8) * (1.0f / 8388608.0f) - 1.0f;
    }

private:
    unsigned int state_;
};

}  // namespace dsp
}  // namespace soundgraph
