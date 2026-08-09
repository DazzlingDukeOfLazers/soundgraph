// sfxr parameters -> a SoundGraph patch.
//
// This is the port. Everything here is unit conversion and wiring: sfxr's twenty-four
// numbers are in its own units — squared, cubed, per-sample, and at a fixed 44100 Hz with
// 8x supersampling — and the node vocabulary is in seconds, hertz and semitones. All of
// that arithmetic lives here, in one file, rather than in the nodes, so that the nodes
// stay useful to somebody who has never heard of sfxr.
//
// Every conversion below is derived from sfxr's own source, and the derivation is written
// next to it. That is the only way any of this can be checked: a bare constant like 3528
// is unreviewable, and getting one of them wrong produces a sound that is merely
// plausible, which is the hardest kind of wrong to notice.
//
// Two of sfxr's behaviours have no equivalent in the vocabulary and are called out at the
// bottom rather than quietly approximated.

#include "to_patch.h"

#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

namespace sfxr_map {
namespace {

// sfxr runs at a fixed 44100 Hz, and its inner loop supersamples 8x. Which of the two
// rates a quantity is expressed in decides its conversion, and sfxr mixes them freely:
// the envelope and the slide step once per sample, the filters and the phaser step once
// per supersample.
constexpr double kRate = 44100.0;
constexpr double kSuperRate = kRate * 8.0;
constexpr double kPi = 3.14159265358979323846;
constexpr double kLn2 = 0.69314718055994530942;

std::string number(double value) {
    char buffer[64];
    std::snprintf(buffer, sizeof(buffer), "%.6g", value);
    return buffer;
}

// Column and lane rather than pixels. A patch is a graph and the editor has a proper
// layout engine, but a file with no coordinates at all opens as a heap in anything that
// does not — so the mapper says roughly where things go and lets a real editor improve on
// it. The grid matches the Godot editor's own column pitch and row step, so a generated
// patch lands on the same lines a hand-placed one does.
constexpr double kColumnPitch = 400.0;
constexpr double kRowStep = 200.0;

struct Node {
    std::string id;
    std::string type;
    std::vector<std::pair<std::string, double>> parameters;
    int column = 0;
    int lane = 0;
};

struct Connection {
    std::string from_node, from_port, to_node, to_port;
};

}  // namespace

// ---------------------------------------------------------------------------------
// The conversions
// ---------------------------------------------------------------------------------

// How far to shift the keyboard so that middle C plays the patch at the pitch sfxr chose.
//
// Without this the sound would be an instrument in name only: NoteInput hands out concert
// pitch, so C4 is 261.6 Hz and every generated effect would play a couple of octaves from
// where it was designed. With it the patch is a transposing instrument — press C4 and hear
// exactly the file as rendered offline, press an octave down and hear the same sound an
// octave down. That equality is also what keeps the offline comparison against sfxr
// meaningful, since sg-render plays note 60.
double transpose_semitones(const sfxr_reference::Params& p);

double base_frequency_hz(const sfxr_reference::Params& p) {
    // sfxr: fperiod = 100 / (p_base_freq^2 + 0.001), in supersamples per cycle. One cycle
    // every fperiod supersamples is kSuperRate/fperiod hertz, so the 100 cancels into
    // kSuperRate/100 = 3528.
    return kSuperRate / (100.0 / (p.p_base_freq * p.p_base_freq + 0.001));
}

double transpose_semitones(const sfxr_reference::Params& p) {
    // The note whose frequency is the patch's own pitch, minus middle C.
    return 12.0 * std::log2(base_frequency_hz(p) / 440.0) + 69.0 - 60.0;
}

double limit_frequency_hz(const sfxr_reference::Params& p) {
    // fmaxperiod is a maximum period, so it is a minimum frequency — and sfxr clamps to it
    // *always*, whatever p_freq_limit is. What p_freq_limit > 0 changes is only whether
    // reaching the floor also ends the sound.
    //
    // So there is no such thing as "no limit" here. At p_freq_limit = 0 the floor is
    // 3528 * 0.001 = 3.5 Hz, which sounds like nothing but is not nothing: without it a
    // steep downward slide runs the frequency to zero and the oscillator sits at DC.
    // That is what the steepest hit-hurt and jump cases were doing.
    return kSuperRate / (100.0 / (p.p_freq_limit * p.p_freq_limit + 0.001));
}

double slide_semitones_per_second(const sfxr_reference::Params& p) {
    // sfxr: fslide = 1 - p_freq_ramp^3 * 0.01, and fperiod *= fslide once per sample.
    // Multiplying the period by fslide divides the frequency by it, so each sample moves
    // the pitch by -log2(fslide) octaves, which is -12*log2(fslide) semitones.
    const double fslide = 1.0 - std::pow(static_cast<double>(p.p_freq_ramp), 3.0) * 0.01;
    if (fslide <= 0.0) return 0.0;
    return -12.0 * (std::log(fslide) / kLn2) * kRate;
}

double slide_acceleration(const sfxr_reference::Params& p) {
    // fdslide is added to fslide every sample, so the rate above is not constant. The
    // Slide node's acceleration is linear in time while sfxr's is not, so this is the
    // first-order term — the derivative of the rate at t = 0.
    //
    // In practice it is always zero: not one of sfxr's seven generators sets
    // p_freq_dramp. It is here because a hand-edited .sfs file can.
    const double fslide = 1.0 - std::pow(static_cast<double>(p.p_freq_ramp), 3.0) * 0.01;
    const double fdslide = -std::pow(static_cast<double>(p.p_freq_dramp), 3.0) * 0.000001;
    if (fslide <= 0.0) return 0.0;
    return -12.0 * kRate * kRate * fdslide / (kLn2 * fslide);
}

double pulse_width(const sfxr_reference::Params& p) {
    // sfxr: square_duty = 0.5 - p_duty*0.5, compared against phase/period exactly as
    // pulse_width is. Same convention, so this is the value itself, clamped to the range
    // the node accepts.
    const double width = 0.5 - p.p_duty * 0.5;
    return width < 0.01 ? 0.01 : (width > 0.99 ? 0.99 : width);
}

double pulse_width_sweep(const sfxr_reference::Params& p) {
    // square_slide = -p_duty_ramp * 0.00005, added per sample. Per second is x44100.
    return -static_cast<double>(p.p_duty_ramp) * 0.00005 * kRate;
}

double envelope_seconds(float stage) {
    // env_length[n] = p^2 * 100000, counted in samples at 44100.
    return static_cast<double>(stage) * stage * 100000.0 / kRate;
}

bool lowpass_active(const sfxr_reference::Params& p) {
    // sfxr bypasses its lowpass entirely at exactly 1.0.
    return p.p_lpf_freq != 1.0f;
}

double lowpass_cutoff_hz(const sfxr_reference::Params& p) {
    // sfxr's lowpass is a discretised damped oscillator, not a one-pole:
    //
    //     fltdp += (sample - fltp) * fltw;   // fltw is the spring constant
    //     fltdp -= fltdp * fltdmp;           // fltdmp is the damping
    //     fltp  += fltdp;
    //
    // A spring of constant fltw resonates at sqrt(fltw) radians per supersample, not
    // fltw. Reading it as a one-pole coefficient — which is what it looks like — puts the
    // cutoff out by a square root: 702 Hz instead of 6280 Hz at p_lpf_freq = 0.5, which is
    // three octaves of wrong and sounds like a completely different filter.
    const double fltw = std::pow(static_cast<double>(p.p_lpf_freq), 3.0) * 0.1;
    return std::sqrt(fltw) * kSuperRate / (2.0 * kPi);
}

double lowpass_resonance(const sfxr_reference::Params& p) {
    // sfxr's p_lpf_resonance is not a resonance, it is one term of a damping coefficient:
    //
    //     fltdmp = 5 / (1 + p_lpf_resonance^2 * 20) * (0.01 + fltw), capped at 0.8
    //
    // At p_lpf_resonance = 0 and a low cutoff that is around 0.05 — a Q of roughly 20, not
    // the flat response the name suggests. sfxr's lowpass is *always* resonant, and how
    // resonant depends on the cutoff. Passing p_lpf_resonance straight through gave a
    // filter with no ring at all, which is what showed up as an overshoot in sfxr's peak
    // and none in ours.
    //
    // For a damped oscillator the damping ratio is fltdmp / (2*sqrt(fltw)), so
    // Q = sqrt(fltw)/fltdmp and k = 1/Q = fltdmp/sqrt(fltw). The node maps
    // k = 2 - 1.95*resonance, so this inverts that. Dividing by sqrt(fltw) is the same
    // correction as the cutoff above: the damping only means something relative to the
    // frequency it is damping.
    const double fltw = std::pow(static_cast<double>(p.p_lpf_freq), 3.0) * 0.1;
    if (fltw <= 0.0) return 0.0;
    double fltdmp = 5.0 / (1.0 + std::pow(static_cast<double>(p.p_lpf_resonance), 2.0) * 20.0) *
                    (0.01 + fltw);
    if (fltdmp > 0.8) fltdmp = 0.8;
    const double resonance = (2.0 - fltdmp / std::sqrt(fltw)) / 1.95;
    return resonance < 0.0 ? 0.0 : (resonance > 1.0 ? 1.0 : resonance);
}

double lowpass_sweep_octaves_per_second(const sfxr_reference::Params& p) {
    // fltw *= (1 + p_lpf_ramp*0.0001) once per supersample. The cutoff is sqrt(fltw), so
    // it moves at half that rate in octaves — the same square root as above.
    const double factor = 1.0 + static_cast<double>(p.p_lpf_ramp) * 0.0001;
    if (factor <= 0.0) return 0.0;
    return 0.5 * kSuperRate * (std::log(factor) / kLn2);
}

bool highpass_active(const sfxr_reference::Params& p) { return p.p_hpf_freq != 0.0f; }

double highpass_cutoff_hz(const sfxr_reference::Params& p) {
    // flthp = p_hpf_freq^2 * 0.1, a one-pole highpass coefficient, also per supersample.
    const double flthp = std::pow(static_cast<double>(p.p_hpf_freq), 2.0) * 0.1;
    return flthp * kSuperRate / (2.0 * kPi);
}

double highpass_sweep_octaves_per_second(const sfxr_reference::Params& p) {
    // flthp *= (1 + p_hpf_ramp*0.0003) — and this one is in the *outer* loop, so it
    // compounds kRate times a second rather than kSuperRate. Easy to get wrong by a
    // factor of eight; sfxr genuinely does step the two filters' ramps at different rates.
    const double factor = 1.0 + static_cast<double>(p.p_hpf_ramp) * 0.0003;
    if (factor <= 0.0) return 0.0;
    return kRate * (std::log(factor) / kLn2);
}

// sfxr's phaser is never off. The buffer is written and read unconditionally:
//
//     phaser_buffer[ipp&1023] = sample;
//     sample += phaser_buffer[(ipp - iphase + 1024) & 1023];
//
// and when iphase is zero the tap reads the sample just written, so the signal is simply
// doubled. Every sfxr sound is 6 dB louder than its oscillator, phaser or no phaser, and
// the offset does not have to be zero for this to bite: iphase is |(int)fphase|, so any
// offset below about 0.03 truncates to zero and doubles too.
//
// The patch therefore always carries a Phaser, even at zero offset, so that both sides
// double identically and the gain below is one number rather than a special case. Leaving
// it out and folding the doubling into the gain would look tidier and would be wrong at
// exactly the offsets where the truncation matters.
bool phaser_always_present(const sfxr_reference::Params&) { return true; }

double phaser_offset_ms(const sfxr_reference::Params& p) {
    // fphase = p_pha_offset^2 * 1020, and the phaser buffer is written once per
    // *supersample* — so 1023 units is 1023/352800 s, under 3 ms, not the 23 ms it would
    // be at the sample rate.
    const double fphase = std::pow(static_cast<double>(p.p_pha_offset), 2.0) * 1020.0;
    return std::fabs(fphase) / kSuperRate * 1000.0;
}

double phaser_sweep_ms_per_second(const sfxr_reference::Params& p) {
    // fdphase = p_pha_ramp^2, added to fphase once per sample, in supersample units.
    const double fdphase = std::pow(static_cast<double>(p.p_pha_ramp), 2.0);
    const double signed_fdphase = p.p_pha_ramp < 0.0f ? -fdphase : fdphase;
    return signed_fdphase * kRate / kSuperRate * 1000.0;
}

bool vibrato_active(const sfxr_reference::Params& p) {
    return p.p_vib_strength > 0.0f && p.p_vib_speed > 0.0f;
}

double vibrato_rate_hz(const sfxr_reference::Params& p) {
    // vib_phase += p_vib_speed^2 * 0.01 per sample, and a cycle is 2pi of phase.
    return std::pow(static_cast<double>(p.p_vib_speed), 2.0) * 0.01 * kRate / (2.0 * kPi);
}

double vibrato_octaves(const sfxr_reference::Params& p) {
    // sfxr multiplies the *period* by (1 + sin*vib_amp) with vib_amp = strength/2.
    // Dividing the frequency by that is -log2(1 + a·sin) octaves, which for the depths
    // sfxr reaches is a·sin/ln2 to within a few percent. The sign is dropped: inverting a
    // sine is a half-cycle shift, and vibrato has no phase to be wrong about.
    return static_cast<double>(p.p_vib_strength) * 0.5 / kLn2;
}

bool arpeggio_active(const sfxr_reference::Params& p) {
    return p.p_arp_speed != 1.0f && p.p_arp_mod != 0.0f;
}

double arpeggio_time_seconds(const sfxr_reference::Params& p) {
    // arp_limit = (1 - p_arp_speed)^2 * 20000 + 32, counted in samples.
    return (std::pow(1.0 - static_cast<double>(p.p_arp_speed), 2.0) * 20000.0 + 32.0) / kRate;
}

double arpeggio_interval_semitones(const sfxr_reference::Params& p) {
    // arp_mod multiplies the period once, so the frequency is divided by it.
    const double mod = p.p_arp_mod >= 0.0f
                           ? 1.0 - std::pow(static_cast<double>(p.p_arp_mod), 2.0) * 0.9
                           : 1.0 + std::pow(static_cast<double>(p.p_arp_mod), 2.0) * 10.0;
    if (mod <= 0.0) return 0.0;
    return -12.0 * (std::log(mod) / kLn2);
}

bool repeat_active(const sfxr_reference::Params& p) { return p.p_repeat_speed != 0.0f; }

double repeat_rate_hz(const sfxr_reference::Params& p) {
    const double limit =
        std::pow(1.0 - static_cast<double>(p.p_repeat_speed), 2.0) * 20000.0 + 32.0;
    return kRate / limit;
}

double master_gain(const sfxr_reference::Params& p) {
    // sfxr: ssample = mean_of_8_supersamples * master_vol(0.05) * 2 * sound_vol(0.5),
    // which is a flat 0.05. Its square wave is +/-0.5 where ours is +/-1, so that halving
    // is folded in here rather than left as a level error for the comparator to find.
    return p.wave_type == 0 ? 0.05 * 0.5 : 0.05;
}

const char* oscillator_type(int wave_type) {
    switch (wave_type) {
        case 0: return "SquareOscillator";
        case 1: return "SawOscillator";
        case 2: return "SineOscillator";
        default: return "NoiseOscillator";
    }
}

// ---------------------------------------------------------------------------------
// Assembling the patch
// ---------------------------------------------------------------------------------

std::string to_patch(const sfxr_reference::Params& p, const std::string& name) {
    std::vector<Node> nodes;
    std::vector<Connection> connections;
    int column = 0;

    // sfxr's noise is a random wavetable read at the oscillator's period, so its pitch
    // matters as much as any other waveform's. NoiseOscillator takes a frequency, so the
    // pitch chain below is built for every waveform — earlier this was skipped for noise
    // and the whole slide, limit and arpeggio was thrown away with it.
    // --- pitch chain -----------------------------------------------------------------
    // The head of the chain holds the patch's own pitch as a parameter, and the keyboard
    // is connected to it as well. Both, on purpose, and each covers a case the other
    // cannot:
    //
    //   Played standalone, the note wins, so the whole sound transposes up and down the
    //   keys. A jump at the pitch it was designed at is one sound; a jump an octave down
    //   is a bigger creature jumping, which is a thing a game actually wants.
    //
    //   Imported as a module, NoteInput is a terminal and gets dropped — that is the seam.
    //   The connection goes with it and the parameter is what is left, so the sound still
    //   comes out at the pitch sfxr chose rather than going silent.
    //
    // This used to be a Constant feeding the chain, which did the second job and made the
    // first impossible: a constant is not a terminal, so it survived module import and
    // went on insisting on its pitch no matter what the host graph wanted.
    //
    // pitch_source is the tail of the chain, which feeds the oscillator. pitch_head is the
    // front of it, which is where the pitch comes in — the same node when the chain is one
    // long, and not when it is two.
    std::string pitch_source;
    std::string pitch_head;
    {
        const double slide = slide_semitones_per_second(p);
        const double acceleration = slide_acceleration(p);
        const double limit = limit_frequency_hz(p);
        if (slide != 0.0 || acceleration != 0.0 || limit != 0.0) {
            nodes.push_back({"slide",
                             "Slide",
                             {{"slide", slide},
                              {"acceleration", acceleration},
                              {"limit", limit},
                              {"frequency", base_frequency_hz(p)}},
                             column++, 0});
            pitch_source = "slide";
            pitch_head = "slide";
        }

        if (arpeggio_active(p)) {
            nodes.push_back({"arpeggio",
                             "Arpeggio",
                             {{"time", arpeggio_time_seconds(p)},
                              {"interval", arpeggio_interval_semitones(p)},
                              {"frequency", base_frequency_hz(p)}},
                             column++, 0});
            if (!pitch_source.empty()) {
                connections.push_back({pitch_source, "frequency", "arpeggio", "frequency"});
            } else {
                pitch_head = "arpeggio";
            }
            pitch_source = "arpeggio";
        }
    }

    // --- oscillator ------------------------------------------------------------------
    Node oscillator{"osc", oscillator_type(p.wave_type), {}, column++, 0};
    if (p.wave_type == 0) {
        oscillator.parameters.push_back({"pulse_width", pulse_width(p)});
        oscillator.parameters.push_back({"pulse_width_sweep", pulse_width_sweep(p)});
    }
    if (p.wave_type == 3) {
        // 32 steps per cycle is sfxr's buffer size, not a preference.
        oscillator.parameters.push_back({"steps", 32.0});
        oscillator.parameters.push_back({"seed", 12345.0});
    }
    // With no slide and no arpeggio the oscillator is itself the head of the chain, and it
    // has had this same parameter all along.
    if (pitch_source.empty()) {
        oscillator.parameters.push_back({"frequency", base_frequency_hz(p)});
        pitch_head = "osc";
    }
    nodes.push_back(oscillator);
    if (!pitch_source.empty()) {
        connections.push_back({pitch_source, "frequency", "osc", "frequency"});
    }

    if (vibrato_active(p)) {
        nodes.push_back({"vibrato",
                         "LFO",
                         {{"rate", vibrato_rate_hz(p)},
                          {"shape", 0.0},
                          {"amount", vibrato_octaves(p)},
                          {"offset", 0.0}},
                         oscillator.column - 1, -1});
        connections.push_back({"vibrato", "out", "osc", "fm"});
    }

    // --- filters, in sfxr's order: lowpass, then highpass ----------------------------
    std::string signal = "osc";
    std::string signal_port = "out";

    if (lowpass_active(p)) {
        nodes.push_back({"lowpass",
                         "StateVariableFilter",
                         {{"cutoff", lowpass_cutoff_hz(p)},
                          {"resonance", lowpass_resonance(p)},
                          {"mode", 0.0},
                          {"cutoff_sweep", lowpass_sweep_octaves_per_second(p)}},
                         column++, 0});
        connections.push_back({signal, signal_port, "lowpass", "in"});
        signal = "lowpass";
        signal_port = "out";
    }

    if (highpass_active(p)) {
        // One pole, not two. sfxr's highpass is
        //
        //     fltphp += fltp - pp;  fltphp -= fltphp * flthp;
        //
        // which is a DC blocker: 6 dB per octave. StateVariableFilter is 12, and the
        // difference is invisible near the cutoff and enormous away from it. These sounds
        // slide down to a 3.5 Hz floor, two hundred times below a 133 Hz corner, where one
        // pole takes about 32 dB off and two take about 63 — so the tail of the sound was
        // 30 dB quieter than sfxr's for most of its length.
        nodes.push_back({"highpass",
                         "OnePoleFilter",
                         {{"cutoff", highpass_cutoff_hz(p)},
                          {"mode", 1.0},
                          {"cutoff_sweep", highpass_sweep_octaves_per_second(p)}},
                         column++, 0});
        connections.push_back({signal, signal_port, "highpass", "in"});
        signal = "highpass";
        signal_port = "out";
    }

    if (phaser_always_present(p)) {
        nodes.push_back({"phaser",
                         "Phaser",
                         {{"offset", phaser_offset_ms(p)},
                          {"sweep", phaser_sweep_ms_per_second(p)},
                          {"depth", 1.0}},
                         column++, 0});
        connections.push_back({signal, signal_port, "phaser", "in"});
        signal = "phaser";
        signal_port = "out";
    }

    // --- envelope --------------------------------------------------------------------
    // The gate is a NoteInput, and that choice does three jobs at once.
    //
    // Standalone it makes the patch playable: press a key, hear the coin. A Constant of 1
    // fires on the first sample and never again, so an opened sound played once on load
    // and then sat there however hard anyone hit the keyboard.
    //
    // As a module it makes the patch *usable*. NoteInput is a terminal, so importing this
    // patch into another drops it and leaves the envelope's gate unconnected for the host
    // graph to drive — which is exactly the seam a module needs. A Constant is not a
    // terminal, so it came along and kept firing on its own, arguing with whatever the
    // parent wanted.
    //
    // And it is still one rising edge at the start when rendered offline, because
    // sg-render puts the first note_on at frame zero. sfxr's envelope fires once and runs
    // to the end; letting go early does nothing, which is what an AHD envelope does too.
    //
    // The trigger output rather than the gate, because these are one-shots. A gate stays
    // high while any key is held, so pressing a second key before releasing the first —
    // which is what jabbing at a jump button looks like — produced no new edge and no
    // second sound. The trigger pulses on every note whether or not one is already down.
    //
    // The frequency is taken as well as the trigger, transposed so that middle C is the
    // patch's own pitch. This was previously left alone on the grounds that a coin has a
    // pitch of its own — true, and the transpose is what keeps it: playing the patch at C4
    // is the file exactly as rendered, and every other key is that same sound moved. A
    // coin an octave down is a bigger coin, which is worth having and costs nothing.
    nodes.push_back({"trigger", "NoteInput",
                     {{"transpose", transpose_semitones(p)}}, column - 2, 1});
    connections.push_back({"trigger", "frequency", pitch_head, "frequency"});
    nodes.push_back({"envelope",
                     "AhdEnvelope",
                     {{"attack", envelope_seconds(p.p_env_attack)},
                      {"hold", envelope_seconds(p.p_env_sustain)},
                      {"decay", envelope_seconds(p.p_env_decay)},
                      {"punch", static_cast<double>(p.p_env_punch)}},
                     column - 1, 1});
    connections.push_back({"trigger", "trigger", "envelope", "gate"});

    nodes.push_back({"amp", "Gain", {{"gain", master_gain(p)}}, column++, 0});
    connections.push_back({signal, signal_port, "amp", "in"});
    connections.push_back({"envelope", "out", "amp", "gain"});

    // --- retrigger -------------------------------------------------------------------
    // Slide and arpeggio hold a position in time too, so a second note has to rewind them
    // or it gets the tail of the first one's sweep — a bloop that already finished bending.
    // Retrigger, when present, owns that job and rewinds them on its own schedule; two
    // sources fighting over one gate would be worse than either alone.
    const char* const restart_from = repeat_active(p) ? "repeat" : "trigger";
    const char* const restart_port = repeat_active(p) ? "gate" : "trigger";
    if (repeat_active(p)) {
        nodes.push_back({"repeat", "Retrigger", {{"rate", repeat_rate_hz(p)}, {"width", 1.0}},
                         0, -1});
    }
    for (Node& node : nodes) {
        if (node.id == "slide")
            connections.push_back({restart_from, restart_port, "slide", "gate"});
        if (node.id == "arpeggio")
            connections.push_back({restart_from, restart_port, "arpeggio", "gate"});
    }

    nodes.push_back({"out", "StereoOutput", {{"level", 1.0}, {"safety_limit", 0.0}},
                     column++, 0});
    connections.push_back({"amp", "out", "out", "left"});
    connections.push_back({"amp", "out", "out", "right"});

    // --- serialise -------------------------------------------------------------------
    std::string json;
    json += "{\n  \"schema_version\": 1,\n";
    json += "  \"metadata\": {\n";
    json += "    \"name\": \"" + name + "\",\n";
    json += "    \"description\": \"Generated from sfxr parameters by sfxr-ref patch. "
            "Do not edit by hand.\",\n";
    json += "    \"tags\": [\"sfxr\"]\n  },\n";

    json += "  \"nodes\": [\n";
    for (std::size_t i = 0; i < nodes.size(); ++i) {
        json += "    {\n      \"id\": \"" + nodes[i].id + "\",\n";
        json += "      \"type\": \"" + nodes[i].type + "\",\n";
        // A rough placement, not a considered one. The editor's layout engine will do
        // better and is welcome to; the point is that a file with no coordinates opens as
        // a heap in anything that has no layout engine at all.
        json += "      \"position\": {\"x\": " + number(nodes[i].column * kColumnPitch) +
                ", \"y\": " + number(nodes[i].lane * kRowStep) + "}";
        if (!nodes[i].parameters.empty()) {
            json += ",\n      \"parameters\": {\n";
            for (std::size_t k = 0; k < nodes[i].parameters.size(); ++k) {
                json += "        \"" + nodes[i].parameters[k].first + "\": " +
                        number(nodes[i].parameters[k].second);
                json += k + 1 < nodes[i].parameters.size() ? ",\n" : "\n";
            }
            json += "      }";
        }
        json += "\n    }";
        json += i + 1 < nodes.size() ? ",\n" : "\n";
    }
    json += "  ],\n";

    json += "  \"connections\": [\n";
    for (std::size_t i = 0; i < connections.size(); ++i) {
        json += "    {\n";
        json += "      \"from\": {\"node\": \"" + connections[i].from_node +
                "\", \"port\": \"" + connections[i].from_port + "\"},\n";
        json += "      \"to\": {\"node\": \"" + connections[i].to_node + "\", \"port\": \"" +
                connections[i].to_port + "\"}\n";
        json += "    }";
        json += i + 1 < connections.size() ? ",\n" : "\n";
    }
    json += "  ]\n}\n";
    return json;
}

}  // namespace sfxr_map
