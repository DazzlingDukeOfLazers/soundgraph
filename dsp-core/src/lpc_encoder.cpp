// Words in, bitstream out: the native half of the speak pipeline.
//
// The same hobby-grade TMS5220-style analysis as tools/lpc-encode.mjs — 25 ms
// frames at 8 kHz, Levinson-Durbin to ten reflection coefficients, energy and
// pitch by autocorrelation, everything quantized to the chip's ROM via the shared
// tables header — living in dsp-core so the editor can encode without leaving the
// engine, on every platform the extension builds for. No I/O, no allocation
// surprises beyond the returned vector: samples in, bytes out.

#include "soundgraph/lpc_encoder.h"

#include <algorithm>
#include <cmath>
#include <vector>

#include "nodes/speech_tables.h"

namespace soundgraph {
namespace {

using nodes::kSpeechEnergy;
using nodes::kSpeechKBits;
using nodes::kSpeechKTables;
using nodes::kSpeechPitch;
using nodes::kSpeechRate;
using nodes::kSpeechFrame;

// Maps a frame's RMS onto the chip's energy scale; the same constant the mjs
// encoder settled on by ear against the node's excitation scaling.
constexpr double kEnergyCalibration = 700.0;

int nearest(const float* table, int size, double value) {
    int best = 0;
    for (int i = 1; i < size; ++i) {
        if (std::fabs(table[i] - value) < std::fabs(table[best] - value)) {
            best = i;
        }
    }
    return best;
}

int nearest(const int* table, int size, double value) {
    int best = 0;
    for (int i = 1; i < size; ++i) {
        if (std::abs(table[i] - value) < std::abs(table[best] - value)) {
            best = i;
        }
    }
    return best;
}

class BitWriter {
public:
    void put(int value, int count) {
        for (int b = 0; b < count; ++b) {
            if (bit_ % 8 == 0) {
                bytes_.push_back(0);
            }
            bytes_.back() = static_cast<unsigned char>(
                bytes_.back() | (((value >> b) & 1) << (bit_ % 8)));
            ++bit_;
        }
    }
    std::vector<unsigned char> take() { return bytes_; }

private:
    std::vector<unsigned char> bytes_;
    int bit_ = 0;
};

}  // namespace

std::vector<unsigned char> encode_lpc(const float* samples, int count,
                                      double sample_rate) {
    BitWriter writer;
    if (samples == nullptr || count <= 0 || sample_rate <= 0.0) {
        writer.put(15, 4);
        return writer.take();
    }

    // To 8 kHz by linear interpolation, like everything else about this voice.
    std::vector<double> at8k;
    const double step = sample_rate / static_cast<double>(kSpeechRate);
    for (double at = 0.0; at < static_cast<double>(count - 1); at += step) {
        const int low = static_cast<int>(at);
        const double frac = at - low;
        at8k.push_back(samples[low] * (1.0 - frac) + samples[low + 1] * frac);
    }

    std::vector<double> emphasized(at8k);
    for (int i = static_cast<int>(emphasized.size()) - 1; i > 0; --i) {
        emphasized[i] -= 0.9375 * emphasized[i - 1];
    }

    for (int start = 0; start + kSpeechFrame <= static_cast<int>(at8k.size());
         start += kSpeechFrame) {
        // Energy from the plain frame.
        double rms = 0.0;
        for (int i = 0; i < kSpeechFrame; ++i) {
            rms += at8k[start + i] * at8k[start + i];
        }
        rms = std::sqrt(rms / kSpeechFrame);
        const int energy = nearest(kSpeechEnergy, 15, rms * kEnergyCalibration);
        writer.put(energy, 4);
        if (energy == 0) {
            continue;
        }

        // Autocorrelation of the Hamming-windowed, pre-emphasized frame.
        double windowed[kSpeechFrame];
        for (int i = 0; i < kSpeechFrame; ++i) {
            windowed[i] = emphasized[start + i] *
                (0.54 - 0.46 * std::cos(2.0 * 3.14159265358979 * i / (kSpeechFrame - 1)));
        }
        double r[11] = {};
        for (int lag = 0; lag <= 10; ++lag) {
            for (int i = lag; i < kSpeechFrame; ++i) {
                r[lag] += windowed[i] * windowed[i - lag];
            }
        }

        // Levinson-Durbin, keeping the reflection coefficients it produces.
        double ks[10] = {};
        double a[11] = {};
        double error = r[0] > 1e-12 ? r[0] : 1e-12;
        for (int m = 1; m <= 10; ++m) {
            double acc = r[m];
            for (int j = 1; j < m; ++j) {
                acc -= a[j] * r[m - j];
            }
            double k = error > 1e-12 ? acc / error : 0.0;
            k = std::max(-0.98, std::min(0.98, k));
            ks[m - 1] = k;
            double next[11];
            std::copy(a, a + 11, next);
            next[m] = k;
            for (int j = 1; j < m; ++j) {
                next[j] = a[j] - k * a[m - j];
            }
            std::copy(next, next + 11, a);
            error *= 1.0 - k * k;
        }

        // Pitch and voicing from the plain frame's own periodicity.
        double r0 = 0.0;
        for (int i = 0; i < kSpeechFrame; ++i) {
            r0 += at8k[start + i] * at8k[start + i];
        }
        int best_lag = 0;
        double best_score = 0.0;
        for (int lag = 15; lag <= 159 && lag < kSpeechFrame; ++lag) {
            double sum = 0.0;
            for (int i = lag; i < kSpeechFrame; ++i) {
                sum += at8k[start + i] * at8k[start + i - lag];
            }
            if (sum > best_score) {
                best_score = sum;
                best_lag = lag;
            }
        }
        const bool voiced = r0 > 0.0 && best_score / r0 > 0.3;

        writer.put(0, 1);   // never a repeat frame: bits are cheap here
        writer.put(voiced ? nearest(kSpeechPitch + 1, 63,
                                    static_cast<double>(best_lag)) + 1
                          : 0, 6);
        const int stages = voiced ? 10 : 4;
        for (int i = 0; i < stages; ++i) {
            // The sign flip is the lattice convention; see the mjs encoder's note.
            const int sizes[10] = {32, 32, 16, 16, 16, 16, 16, 8, 8, 8};
            writer.put(nearest(kSpeechKTables[i], sizes[i], -ks[i] * 512.0),
                       kSpeechKBits[i]);
        }
    }

    writer.put(15, 4);   // stop
    return writer.take();
}

}  // namespace soundgraph
