#include "resample.h"

#include <cmath>

namespace transcribe {
namespace {

// Zeroth-order modified Bessel function, by its series. Converges quickly for the betas
// a resampler uses, and this runs once per file rather than once per sample.
double bessel_i0(double x) {
    double sum = 1.0;
    double term = 1.0;
    for (int k = 1; k < 40; ++k) {
        term *= (x / (2.0 * k)) * (x / (2.0 * k));
        sum += term;
        if (term < sum * 1e-16) break;
    }
    return sum;
}

constexpr double kPi = 3.14159265358979323846;

// Half-width of the kernel in output samples. Wider is sharper and slower; 32 puts the
// transition band comfortably inside what the model cares about at a cost nobody will
// notice on a file that takes milliseconds to read.
constexpr int kHalfWidth = 32;
constexpr double kBeta = 8.6;   // Kaiser beta: about 90 dB of stopband

}  // namespace

std::vector<float> resample(const std::vector<float>& input, int from_rate, int to_rate) {
    if (input.empty() || from_rate <= 0 || to_rate <= 0) return {};
    if (from_rate == to_rate) return input;

    const double ratio = static_cast<double>(to_rate) / from_rate;
    // Going down means the kernel has to cut at the *output* Nyquist, so it stretches in
    // input samples. Going up, the input's own Nyquist is already the limit.
    const double cutoff = ratio < 1.0 ? ratio : 1.0;
    const double width = kHalfWidth / cutoff;

    const size_t out_count = static_cast<size_t>(
        std::floor(static_cast<double>(input.size()) * ratio));
    std::vector<float> output(out_count, 0.0f);

    const double denominator = bessel_i0(kBeta);

    for (size_t n = 0; n < out_count; ++n) {
        // Where this output sample sits in the input, in input samples.
        const double centre = static_cast<double>(n) / ratio;
        const long first = static_cast<long>(std::ceil(centre - width));
        const long last = static_cast<long>(std::floor(centre + width));

        double sum = 0.0;
        double weight_total = 0.0;
        for (long i = first; i <= last; ++i) {
            if (i < 0 || static_cast<size_t>(i) >= input.size()) continue;
            const double offset = centre - static_cast<double>(i);

            // Kaiser window over the kernel's own half-width.
            const double t = offset / width;
            const double inside = 1.0 - t * t;
            if (inside <= 0.0) continue;
            const double window = bessel_i0(kBeta * std::sqrt(inside)) / denominator;

            // The band-limiting sinc, at the lower of the two Nyquists.
            const double x = kPi * offset * cutoff;
            const double sinc = std::fabs(x) < 1e-9 ? 1.0 : std::sin(x) / x;

            const double weight = window * sinc;
            sum += weight * input[static_cast<size_t>(i)];
            weight_total += weight;
        }
        // Normalised by the weight actually used, so that the partial kernels at the
        // very start and end of the file do not come out quiet.
        output[n] = static_cast<float>(weight_total > 1e-12 ? sum / weight_total : 0.0);
    }
    return output;
}

}  // namespace transcribe
