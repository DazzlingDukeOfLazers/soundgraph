// sfxr's synthesis model, vendored as a test oracle. See sfxr_reference.h and README.md.
//
// Original: sfxr by DrPetter (Tomas Pettersson), 2007, MIT — see LICENSE.txt.
// Source: https://github.com/grimfang4/sfxr  (sfxr/source/main.cpp)
//
// The synthesis arithmetic below is copied from that file unchanged, down to the order of
// operations and the choice of float versus double, because an oracle that has been
// "cleaned up" is no longer an oracle. Four mechanical changes were needed to make it
// usable as one, and nothing else was touched. The first two are the same change twice:
// the C library is not the same library everywhere, and an oracle has to be.
//
//   1. rand() is replaced by an xorshift32 embedded here. sfxr calls rnd() inside the
//      audio loop to refill its noise buffer, so the waveform depends on the C library's
//      generator — and MSVC, glibc and musl do not agree. A corpus generated on one
//      machine would not reproduce on another, which would make the whole rig worthless.
//      This alters output, and only the noise waveform.
//   2. sin() is replaced by portable_sin() below, for exactly that reason. Apple's libm
//      and Microsoft's disagree by about one ULP; the low-pass filter's feedback grows
//      that into a byte-level difference by the end of a render, and the two vectors with
//      wave_type == 2 stopped reproducing on a Mac. This alters output too, by 2.2e-16 at
//      worst — see portable_sin for the measurement.
//   3. The globals became members of a state struct so a render cannot leak into the next
//      one. The arithmetic is untouched; only the names are qualified.
//   4. The SDL interface, the GUI, the undo buffer and the .sfs and .wav writers are gone.
//      The seven generator bodies were lifted out of DrawScreen() verbatim.
//
// Deliberately not fixed: the sustain stage computes
//   env_vol = 1 + pow(1 - t, 1.0) * 2 * p_env_punch
// where the pow with an exponent of exactly 1 is redundant, and env_length[n] can be zero,
// making the stage ratios a division by zero that lands on inf or nan before the next
// stage begins. Both are sfxr's real behaviour and audible in its real output, so both
// stay. The port has to match what sfxr does, not what it should have done.

#include "sfxr_reference.h"

#include <cmath>
#include <cstring>

namespace sfxr_reference {
namespace {

constexpr float kPi = 3.14159265f;

// The substitute sine, for the same reason as the substitute generator below: the C
// library's is not the same on every platform. Apple's differs from Microsoft's by about
// one unit in the last place, the low-pass filter's feedback grows that to roughly eight
// float ULPs over a render, and the two vectors with wave_type == 2 stopped being
// byte-reproducible on a Mac. A corpus that only reproduces where it was made is not a
// fixed target.
//
// Cody-Waite reduction onto [-pi/4, pi/4] with a three-part pi/2, then Taylor kernels
// carried to x^17 and x^16 — far past what double precision can hold over that interval,
// so the truncation is not what limits it. Measured against Apple's libm across the whole
// range sfxr uses, the worst disagreement is 2.2e-16: one ULP of a double, and orders of
// magnitude below the float the sample is stored as.
//
// Taylor rather than minimax coefficients on purpose. The series is derivable from first
// principles by anyone reading this, which matters more here than the handful of bits a
// fitted polynomial would buy — this is an oracle, and it has to be checkable.
constexpr double kTwoOverPi = 0.63661977236758134308;
constexpr double kPio2Hi = 1.57079632673412561417e+00;
constexpr double kPio2Mid = 6.07710050650619224932e-11;
constexpr double kPio2Lo = 2.02226624879595063154e-21;

double kernel_sin(double r) {
    const double r2 = r * r;
    double p = 1.0 / 355687428096000.0;   // 17!
    p = p * r2 - 1.0 / 1307674368000.0;   // 15!
    p = p * r2 + 1.0 / 6227020800.0;      // 13!
    p = p * r2 - 1.0 / 39916800.0;        // 11!
    p = p * r2 + 1.0 / 362880.0;          // 9!
    p = p * r2 - 1.0 / 5040.0;            // 7!
    p = p * r2 + 1.0 / 120.0;             // 5!
    p = p * r2 - 1.0 / 6.0;               // 3!
    return r + r * r2 * p;
}

double kernel_cos(double r) {
    const double r2 = r * r;
    double p = 1.0 / 20922789888000.0;    // 16!
    p = p * r2 - 1.0 / 87178291200.0;     // 14!
    p = p * r2 + 1.0 / 479001600.0;       // 12!
    p = p * r2 - 1.0 / 3628800.0;         // 10!
    p = p * r2 + 1.0 / 40320.0;           // 8!
    p = p * r2 - 1.0 / 720.0;             // 6!
    p = p * r2 + 1.0 / 24.0;              // 4!
    return 1.0 + r2 * (-0.5 + r2 * p);
}

// floor(x + 0.5) rather than rint or nearbyint: those consult the current rounding mode,
// and a reference that depends on ambient floating-point state is the problem this whole
// file is trying not to have.
double portable_sin(double x) {
    const double k = std::floor(x * kTwoOverPi + 0.5);
    const double r = ((x - k * kPio2Hi) - k * kPio2Mid) - k * kPio2Lo;
    switch (static_cast<long long>(k) & 3) {
        case 0: return kernel_sin(r);
        case 1: return kernel_cos(r);
        case 2: return -kernel_sin(r);
        default: return -kernel_cos(r);
    }
}

// The substitute generator. Deterministic across platforms, which the C library's is not.
struct Rng {
    unsigned int state = 1u;

    void seed(unsigned int value) { state = value ? value : 1u; }

    unsigned int next() {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        return state;
    }

    // sfxr's  #define rnd(n) (rand()%(n+1))
    int rnd(int n) { return static_cast<int>(next() % static_cast<unsigned int>(n + 1)); }

    // sfxr's  float frnd(float range) { return (float)rnd(10000)/10000*range; }
    float frnd(float range) { return static_cast<float>(rnd(10000)) / 10000 * range; }
};

// sfxr's synthesis state, one-for-one with its file-scope globals.
struct State {
    const Params* p = nullptr;
    Rng rng;

    bool playing_sample = false;
    int phase = 0;
    double fperiod = 0.0;
    double fmaxperiod = 0.0;
    double fslide = 0.0;
    double fdslide = 0.0;
    int period = 0;
    float square_duty = 0.0f;
    float square_slide = 0.0f;
    int env_stage = 0;
    int env_time = 0;
    int env_length[3] = {0, 0, 0};
    float env_vol = 0.0f;
    float fphase = 0.0f;
    float fdphase = 0.0f;
    int iphase = 0;
    float phaser_buffer[1024] = {0.0f};
    int ipp = 0;
    float noise_buffer[32] = {0.0f};
    float fltp = 0.0f;
    float fltdp = 0.0f;
    float fltw = 0.0f;
    float fltw_d = 0.0f;
    float fltdmp = 0.0f;
    float fltphp = 0.0f;
    float flthp = 0.0f;
    float flthp_d = 0.0f;
    float vib_phase = 0.0f;
    float vib_speed = 0.0f;
    float vib_amp = 0.0f;
    int rep_time = 0;
    int rep_limit = 0;
    int arp_time = 0;
    int arp_limit = 0;
    double arp_mod = 0.0;

    float master_vol = 0.05f;
    float sound_vol = 0.5f;
};

// sfxr's ResetSample(), verbatim.
void reset_sample(State& s, bool restart) {
    const Params& p = *s.p;

    if (!restart) s.phase = 0;
    s.fperiod = 100.0 / (p.p_base_freq * p.p_base_freq + 0.001);
    s.period = static_cast<int>(s.fperiod);
    s.fmaxperiod = 100.0 / (p.p_freq_limit * p.p_freq_limit + 0.001);
    s.fslide = 1.0 - pow(static_cast<double>(p.p_freq_ramp), 3.0) * 0.01;
    s.fdslide = -pow(static_cast<double>(p.p_freq_dramp), 3.0) * 0.000001;
    s.square_duty = 0.5f - p.p_duty * 0.5f;
    s.square_slide = -p.p_duty_ramp * 0.00005f;
    if (p.p_arp_mod >= 0.0f)
        s.arp_mod = 1.0 - pow(static_cast<double>(p.p_arp_mod), 2.0) * 0.9;
    else
        s.arp_mod = 1.0 + pow(static_cast<double>(p.p_arp_mod), 2.0) * 10.0;
    s.arp_time = 0;
    s.arp_limit = static_cast<int>(pow(1.0f - p.p_arp_speed, 2.0f) * 20000 + 32);
    if (p.p_arp_speed == 1.0f) s.arp_limit = 0;

    if (!restart) {
        // reset filter
        s.fltp = 0.0f;
        s.fltdp = 0.0f;
        s.fltw = pow(p.p_lpf_freq, 3.0f) * 0.1f;
        s.fltw_d = 1.0f + p.p_lpf_ramp * 0.0001f;
        s.fltdmp = 5.0f / (1.0f + pow(p.p_lpf_resonance, 2.0f) * 20.0f) * (0.01f + s.fltw);
        if (s.fltdmp > 0.8f) s.fltdmp = 0.8f;
        s.fltphp = 0.0f;
        s.flthp = pow(p.p_hpf_freq, 2.0f) * 0.1f;
        s.flthp_d = 1.0 + p.p_hpf_ramp * 0.0003f;
        // reset vibrato
        s.vib_phase = 0.0f;
        s.vib_speed = pow(p.p_vib_speed, 2.0f) * 0.01f;
        s.vib_amp = p.p_vib_strength * 0.5f;
        // reset envelope
        s.env_vol = 0.0f;
        s.env_stage = 0;
        s.env_time = 0;
        s.env_length[0] = static_cast<int>(p.p_env_attack * p.p_env_attack * 100000.0f);
        s.env_length[1] = static_cast<int>(p.p_env_sustain * p.p_env_sustain * 100000.0f);
        s.env_length[2] = static_cast<int>(p.p_env_decay * p.p_env_decay * 100000.0f);

        s.fphase = pow(p.p_pha_offset, 2.0f) * 1020.0f;
        if (p.p_pha_offset < 0.0f) s.fphase = -s.fphase;
        s.fdphase = pow(p.p_pha_ramp, 2.0f) * 1.0f;
        if (p.p_pha_ramp < 0.0f) s.fdphase = -s.fdphase;
        s.iphase = abs(static_cast<int>(s.fphase));
        s.ipp = 0;
        for (int i = 0; i < 1024; i++) s.phaser_buffer[i] = 0.0f;

        for (int i = 0; i < 32; i++) s.noise_buffer[i] = s.rng.frnd(2.0f) - 1.0f;

        s.rep_time = 0;
        s.rep_limit = static_cast<int>(pow(1.0f - p.p_repeat_speed, 2.0f) * 20000 + 32);
        if (p.p_repeat_speed == 0.0f) s.rep_limit = 0;
    }
}

// sfxr's SynthSample(), verbatim, minus the file-writing branch.
std::size_t synth_sample(State& s, float* buffer, std::size_t length) {
    const Params& p = *s.p;
    std::size_t written = 0;

    for (std::size_t i = 0; i < length; i++) {
        if (!s.playing_sample) break;

        s.rep_time++;
        if (s.rep_limit != 0 && s.rep_time >= s.rep_limit) {
            s.rep_time = 0;
            reset_sample(s, true);
        }

        // frequency envelopes/arpeggios
        s.arp_time++;
        if (s.arp_limit != 0 && s.arp_time >= s.arp_limit) {
            s.arp_limit = 0;
            s.fperiod *= s.arp_mod;
        }
        s.fslide += s.fdslide;
        s.fperiod *= s.fslide;
        if (s.fperiod > s.fmaxperiod) {
            s.fperiod = s.fmaxperiod;
            if (p.p_freq_limit > 0.0f) s.playing_sample = false;
        }
        float rfperiod = static_cast<float>(s.fperiod);
        if (s.vib_amp > 0.0f) {
            s.vib_phase += s.vib_speed;
            rfperiod = static_cast<float>(s.fperiod * (1.0 + portable_sin(s.vib_phase) * s.vib_amp));
        }
        s.period = static_cast<int>(rfperiod);
        if (s.period < 8) s.period = 8;
        s.square_duty += s.square_slide;
        if (s.square_duty < 0.0f) s.square_duty = 0.0f;
        if (s.square_duty > 0.5f) s.square_duty = 0.5f;
        // volume envelope
        s.env_time++;
        if (s.env_time > s.env_length[s.env_stage]) {
            s.env_time = 0;
            s.env_stage++;
            if (s.env_stage == 3) s.playing_sample = false;
        }
        if (s.env_stage == 0)
            s.env_vol = static_cast<float>(s.env_time) / s.env_length[0];
        if (s.env_stage == 1)
            s.env_vol = 1.0f + pow(1.0f - static_cast<float>(s.env_time) / s.env_length[1],
                                   1.0f) * 2.0f * p.p_env_punch;
        if (s.env_stage == 2)
            s.env_vol = 1.0f - static_cast<float>(s.env_time) / s.env_length[2];

        // phaser step
        s.fphase += s.fdphase;
        s.iphase = abs(static_cast<int>(s.fphase));
        if (s.iphase > 1023) s.iphase = 1023;

        if (s.flthp_d != 0.0f) {
            s.flthp *= s.flthp_d;
            if (s.flthp < 0.00001f) s.flthp = 0.00001f;
            if (s.flthp > 0.1f) s.flthp = 0.1f;
        }

        float ssample = 0.0f;
        for (int si = 0; si < 8; si++) {  // 8x supersampling
            float sample = 0.0f;
            s.phase++;
            if (s.phase >= s.period) {
                s.phase %= s.period;
                if (p.wave_type == 3)
                    for (int j = 0; j < 32; j++) s.noise_buffer[j] = s.rng.frnd(2.0f) - 1.0f;
            }
            // base waveform
            float fp = static_cast<float>(s.phase) / s.period;
            switch (p.wave_type) {
                case 0:  // square
                    sample = (fp < s.square_duty) ? 0.5f : -0.5f;
                    break;
                case 1:  // sawtooth
                    sample = 1.0f - fp * 2;
                    break;
                case 2:  // sine
                    sample = static_cast<float>(portable_sin(fp * 2 * kPi));
                    break;
                case 3:  // noise
                    sample = s.noise_buffer[s.phase * 32 / s.period];
                    break;
            }
            // lp filter
            float pp = s.fltp;
            s.fltw *= s.fltw_d;
            if (s.fltw < 0.0f) s.fltw = 0.0f;
            if (s.fltw > 0.1f) s.fltw = 0.1f;
            if (p.p_lpf_freq != 1.0f) {
                s.fltdp += (sample - s.fltp) * s.fltw;
                s.fltdp -= s.fltdp * s.fltdmp;
            } else {
                s.fltp = sample;
                s.fltdp = 0.0f;
            }
            s.fltp += s.fltdp;
            // hp filter
            s.fltphp += s.fltp - pp;
            s.fltphp -= s.fltphp * s.flthp;
            sample = s.fltphp;
            // phaser
            s.phaser_buffer[s.ipp & 1023] = sample;
            sample += s.phaser_buffer[(s.ipp - s.iphase + 1024) & 1023];
            s.ipp = (s.ipp + 1) & 1023;
            // final accumulation and envelope application
            ssample += sample * s.env_vol;
        }
        ssample = ssample / 8 * s.master_vol;
        ssample *= 2.0f * s.sound_vol;

        if (ssample > 1.0f) ssample = 1.0f;
        if (ssample < -1.0f) ssample = -1.0f;
        buffer[written++] = ssample;
    }

    return written;
}

}  // namespace

const char* preset_name(Preset preset) {
    switch (preset) {
        case Preset::PickupCoin: return "pickup-coin";
        case Preset::LaserShoot: return "laser-shoot";
        case Preset::Explosion: return "explosion";
        case Preset::Powerup: return "powerup";
        case Preset::HitHurt: return "hit-hurt";
        case Preset::Jump: return "jump";
        case Preset::BlipSelect: return "blip-select";
    }
    return "unknown";
}

bool preset_from_name(const char* name, Preset* out) {
    const Preset all[] = {Preset::PickupCoin, Preset::LaserShoot, Preset::Explosion,
                          Preset::Powerup,    Preset::HitHurt,    Preset::Jump,
                          Preset::BlipSelect};
    for (Preset preset : all) {
        if (std::strcmp(name, preset_name(preset)) == 0) {
            *out = preset;
            return true;
        }
    }
    return false;
}

// The seven generator bodies, lifted verbatim out of sfxr's DrawScreen().
Params generate(Preset preset, unsigned int seed) {
    Rng rng;
    rng.seed(seed);
    Params p;  // member initialisers are sfxr's ResetParams() values

    switch (preset) {
        case Preset::PickupCoin:
            p.p_base_freq = 0.4f + rng.frnd(0.5f);
            p.p_env_attack = 0.0f;
            p.p_env_sustain = rng.frnd(0.1f);
            p.p_env_decay = 0.1f + rng.frnd(0.4f);
            p.p_env_punch = 0.3f + rng.frnd(0.3f);
            if (rng.rnd(1)) {
                p.p_arp_speed = 0.5f + rng.frnd(0.2f);
                p.p_arp_mod = 0.2f + rng.frnd(0.4f);
            }
            break;

        case Preset::LaserShoot:
            p.wave_type = rng.rnd(2);
            if (p.wave_type == 2 && rng.rnd(1)) p.wave_type = rng.rnd(1);
            p.p_base_freq = 0.5f + rng.frnd(0.5f);
            p.p_freq_limit = p.p_base_freq - 0.2f - rng.frnd(0.6f);
            if (p.p_freq_limit < 0.2f) p.p_freq_limit = 0.2f;
            p.p_freq_ramp = -0.15f - rng.frnd(0.2f);
            if (rng.rnd(2) == 0) {
                p.p_base_freq = 0.3f + rng.frnd(0.6f);
                p.p_freq_limit = rng.frnd(0.1f);
                p.p_freq_ramp = -0.35f - rng.frnd(0.3f);
            }
            if (rng.rnd(1)) {
                p.p_duty = rng.frnd(0.5f);
                p.p_duty_ramp = rng.frnd(0.2f);
            } else {
                p.p_duty = 0.4f + rng.frnd(0.5f);
                p.p_duty_ramp = -rng.frnd(0.7f);
            }
            p.p_env_attack = 0.0f;
            p.p_env_sustain = 0.1f + rng.frnd(0.2f);
            p.p_env_decay = rng.frnd(0.4f);
            if (rng.rnd(1)) p.p_env_punch = rng.frnd(0.3f);
            if (rng.rnd(2) == 0) {
                p.p_pha_offset = rng.frnd(0.2f);
                p.p_pha_ramp = -rng.frnd(0.2f);
            }
            if (rng.rnd(1)) p.p_hpf_freq = rng.frnd(0.3f);
            break;

        case Preset::Explosion:
            p.wave_type = 3;
            if (rng.rnd(1)) {
                p.p_base_freq = 0.1f + rng.frnd(0.4f);
                p.p_freq_ramp = -0.1f + rng.frnd(0.4f);
            } else {
                p.p_base_freq = 0.2f + rng.frnd(0.7f);
                p.p_freq_ramp = -0.2f - rng.frnd(0.2f);
            }
            p.p_base_freq *= p.p_base_freq;
            if (rng.rnd(4) == 0) p.p_freq_ramp = 0.0f;
            if (rng.rnd(2) == 0) p.p_repeat_speed = 0.3f + rng.frnd(0.5f);
            p.p_env_attack = 0.0f;
            p.p_env_sustain = 0.1f + rng.frnd(0.3f);
            p.p_env_decay = rng.frnd(0.5f);
            if (rng.rnd(1) == 0) {
                p.p_pha_offset = -0.3f + rng.frnd(0.9f);
                p.p_pha_ramp = -rng.frnd(0.3f);
            }
            p.p_env_punch = 0.2f + rng.frnd(0.6f);
            if (rng.rnd(1)) {
                p.p_vib_strength = rng.frnd(0.7f);
                p.p_vib_speed = rng.frnd(0.6f);
            }
            if (rng.rnd(2) == 0) {
                p.p_arp_speed = 0.6f + rng.frnd(0.3f);
                p.p_arp_mod = 0.8f - rng.frnd(1.6f);
            }
            break;

        case Preset::Powerup:
            if (rng.rnd(1))
                p.wave_type = 1;
            else
                p.p_duty = rng.frnd(0.6f);
            if (rng.rnd(1)) {
                p.p_base_freq = 0.2f + rng.frnd(0.3f);
                p.p_freq_ramp = 0.1f + rng.frnd(0.4f);
                p.p_repeat_speed = 0.4f + rng.frnd(0.4f);
            } else {
                p.p_base_freq = 0.2f + rng.frnd(0.3f);
                p.p_freq_ramp = 0.05f + rng.frnd(0.2f);
                if (rng.rnd(1)) {
                    p.p_vib_strength = rng.frnd(0.7f);
                    p.p_vib_speed = rng.frnd(0.6f);
                }
            }
            p.p_env_attack = 0.0f;
            p.p_env_sustain = rng.frnd(0.4f);
            p.p_env_decay = 0.1f + rng.frnd(0.4f);
            break;

        case Preset::HitHurt:
            p.wave_type = rng.rnd(2);
            if (p.wave_type == 2) p.wave_type = 3;
            if (p.wave_type == 0) p.p_duty = rng.frnd(0.6f);
            p.p_base_freq = 0.2f + rng.frnd(0.6f);
            p.p_freq_ramp = -0.3f - rng.frnd(0.4f);
            p.p_env_attack = 0.0f;
            p.p_env_sustain = rng.frnd(0.1f);
            p.p_env_decay = 0.1f + rng.frnd(0.2f);
            if (rng.rnd(1)) p.p_hpf_freq = rng.frnd(0.3f);
            break;

        case Preset::Jump:
            p.wave_type = 0;
            p.p_duty = rng.frnd(0.6f);
            p.p_base_freq = 0.3f + rng.frnd(0.3f);
            p.p_freq_ramp = 0.1f + rng.frnd(0.2f);
            p.p_env_attack = 0.0f;
            p.p_env_sustain = 0.1f + rng.frnd(0.3f);
            p.p_env_decay = 0.1f + rng.frnd(0.2f);
            if (rng.rnd(1)) p.p_hpf_freq = rng.frnd(0.3f);
            if (rng.rnd(1)) p.p_lpf_freq = 1.0f - rng.frnd(0.6f);
            break;

        case Preset::BlipSelect:
            p.wave_type = rng.rnd(1);
            if (p.wave_type == 0) p.p_duty = rng.frnd(0.6f);
            p.p_base_freq = 0.2f + rng.frnd(0.4f);
            p.p_env_attack = 0.0f;
            p.p_env_sustain = 0.1f + rng.frnd(0.1f);
            p.p_env_decay = rng.frnd(0.2f);
            p.p_hpf_freq = 0.1f;
            break;
    }

    return p;
}

std::size_t render(const Params& params, unsigned int seed, float* out,
                   std::size_t capacity) {
    State s;
    s.p = &params;
    s.rng.seed(seed);
    reset_sample(s, false);
    s.playing_sample = true;
    return synth_sample(s, out, capacity);
}

}  // namespace sfxr_reference
