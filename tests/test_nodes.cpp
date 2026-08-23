// Per-node behaviour, checked against properties rather than against recorded output.
// A golden vector catches changes; these catch being wrong in the first place.
#include <algorithm>

#include "node_harness.h"
#include "test_support.h"

using testing::NodeHarness;

namespace {

constexpr double kSampleRate = 48000.0;
constexpr int kOneSecond = 48000;

}  // namespace

// ---- oscillators --------------------------------------------------------------------

TEST(sine_oscillator_runs_at_the_requested_frequency) {
    NodeHarness harness("SineOscillator", kOneSecond, kSampleRate);
    CHECK(harness.valid());
    harness.set("frequency", 1000.0f);
    harness.process();

    // One second of a 1 kHz tone crosses zero upwards 1000 times.
    CHECK_NEAR(testing::rising_zero_crossings(harness.output()), 1000, 1);
    CHECK_NEAR(testing::peak(harness.output()), 1.0, 0.001);
    CHECK_NEAR(testing::mean(harness.output()), 0.0, 0.001);
}

TEST(oscillator_frequency_input_replaces_the_parameter) {
    NodeHarness harness("SineOscillator", kOneSecond, kSampleRate);
    harness.set("frequency", 100.0f);
    harness.connect("frequency", 500.0f);
    harness.process();

    CHECK_NEAR(testing::rising_zero_crossings(harness.output()), 500, 1);
}

TEST(oscillator_fm_input_is_additive_in_octaves) {
    NodeHarness harness("SineOscillator", kOneSecond, kSampleRate);
    harness.set("frequency", 220.0f);
    harness.connect("fm", 1.0f);  // one octave up
    harness.process();

    CHECK_NEAR(testing::rising_zero_crossings(harness.output()), 440, 1);
}

TEST(oscillator_pm_input_displaces_the_read_phase_linearly) {
    // A near-stopped carrier turns pm into a direct probe of the phase arithmetic: the
    // free-running phase stays at ~0, so the output is sin(2*pi*pm) and nothing else.
    NodeHarness harness("SineOscillator", 64, kSampleRate);
    harness.set("frequency", 0.01f);
    harness.connect("pm", 0.25f);
    harness.process();

    CHECK_NEAR(harness.output().front(), 1.0, 1e-3);
    CHECK_NEAR(harness.output().back(), 1.0, 1e-3);
}

TEST(oscillator_pm_shifts_phase_and_leaves_pitch_alone) {
    // The linearity signature, and the reason pm is its own port: a constant into pm
    // is a phase offset and nothing else, so the pitch does not move. The same
    // constant into the exponential fm port would play 220 * 2^0.3 = 271 Hz. This is
    // exactly the distinction that makes a DX7 patch importable through one port and
    // wrong through the other.
    //
    // (The first version of this test drove pm with a full-depth 1:1 sine and counted
    // zero crossings, expecting the carrier frequency back. Average rate is indeed
    // preserved — but at that index the instantaneous frequency swings negative, the
    // phase runs backwards part of each cycle, and the extra crossings arrive in
    // pairs. The test was wrong about waves, not the port about FM.)
    NodeHarness harness("SineOscillator", kOneSecond, kSampleRate);
    harness.set("frequency", 220.0f);
    harness.connect("pm", 0.3f);
    harness.process();

    CHECK_NEAR(testing::rising_zero_crossings(harness.output()), 220, 1);
}

TEST(oscillator_pm_at_zero_is_no_modulator_at_all) {
    NodeHarness modulated("SineOscillator", kOneSecond, kSampleRate);
    modulated.set("frequency", 440.0f);
    modulated.connect("pm", 0.0f);
    modulated.process();

    NodeHarness bare("SineOscillator", kOneSecond, kSampleRate,
        testing::Coverage::SmokeTest);
    bare.set("frequency", 440.0f);
    bare.process();

    bool identical = true;
    for (std::size_t i = 0; i < bare.output().size(); ++i) {
        if (modulated.output()[i] != bare.output()[i]) {
            identical = false;
            break;
        }
    }
    CHECK(identical);
}

TEST(sine_feedback_at_zero_is_a_pure_sine_to_the_bit) {
    NodeHarness with("SineOscillator", kOneSecond, kSampleRate);
    with.set("frequency", 440.0f);
    with.set("feedback", 0.0f);
    with.process();

    NodeHarness without("SineOscillator", kOneSecond, kSampleRate,
        testing::Coverage::SmokeTest);
    without.set("frequency", 440.0f);
    without.process();

    bool identical = true;
    for (std::size_t i = 0; i < with.output().size(); ++i) {
        if (with.output()[i] != without.output()[i]) {
            identical = false;
            break;
        }
    }
    CHECK(identical);
}

TEST(sine_feedback_adds_harmonics_without_moving_the_pitch) {
    // 0.12, not more, and the bound is physics rather than taste: self-modulation keeps
    // the phase monotonic only below 1/2pi ≈ 0.159 cycles. Above that the wave folds
    // back on itself and rising crossings arrive in pairs — the authentic OPL buzz at
    // high feedback, and the third time this suite has had to learn that zero-crossing
    // counting and deep phase modulation do not mix.
    NodeHarness harness("SineOscillator", kOneSecond, kSampleRate);
    harness.set("frequency", 220.0f);
    harness.set("feedback", 0.12f);
    harness.process();

    // Still 220 crossings — feedback distorts the shape, not the period.
    CHECK_NEAR(testing::rising_zero_crossings(harness.output()), 220, 1);

    // But no longer the shape a bare sine would have: compare against one sample by
    // sample and require a real divergence, not a rounding one.
    NodeHarness pure("SineOscillator", kOneSecond, kSampleRate,
        testing::Coverage::SmokeTest);
    pure.set("frequency", 220.0f);
    pure.process();
    float widest = 0.0f;
    for (std::size_t i = 0; i < pure.output().size(); ++i) {
        widest = std::max(widest,
            std::abs(harness.output()[i] - pure.output()[i]));
    }
    CHECK(widest > 0.2f);

    // And the loop is tame: bounded output, no NaN. The two-sample average exists to
    // damp the period-two squeal, and this is where that promise gets checked.
    CHECK(testing::peak(harness.output()) <= 1.2f);
    for (float sample : harness.output()) {
        CHECK(std::isfinite(sample));
        if (!std::isfinite(sample)) break;
    }
}

TEST(sine_shapes_bend_the_wave_the_opl_ways) {
    // Shape 1, half: the positive lobes survive untouched, the negative ones are gone.
    NodeHarness half("SineOscillator", kOneSecond, kSampleRate);
    half.set("frequency", 100.0f);
    half.set("shape", 1.0f);
    half.process();
    float lowest = 1.0f;
    for (float sample : half.output()) lowest = std::min(lowest, sample);
    CHECK(lowest >= 0.0f);
    CHECK(testing::peak(half.output()) > 0.99f);

    // Shape 2, absolute: rectification doubles the period, so a 100 Hz oscillator
    // reads as 200 to anything counting repetitions — that is the octave-up trick
    // every OPL organ patch leans on.
    NodeHarness rectified("SineOscillator", kOneSecond, kSampleRate);
    rectified.set("frequency", 100.0f);
    rectified.set("shape", 2.0f);
    rectified.process();
    float rect_low = 1.0f;
    for (float sample : rectified.output()) rect_low = std::min(rect_low, sample);
    CHECK(rect_low >= 0.0f);

    // Shape 3, quarter: strictly quieter than absolute — same lobes, half of each
    // kept — and never negative either.
    NodeHarness quarter("SineOscillator", kOneSecond, kSampleRate);
    quarter.set("frequency", 100.0f);
    quarter.set("shape", 3.0f);
    quarter.process();
    float quarter_energy = 0.0f;
    float rect_energy = 0.0f;
    for (std::size_t i = 0; i < quarter.output().size(); ++i) {
        quarter_energy += quarter.output()[i] * quarter.output()[i];
        rect_energy += rectified.output()[i] * rectified.output()[i];
    }
    CHECK(quarter_energy > 0.0f);
    CHECK(quarter_energy < rect_energy * 0.75f);

    // And shape 0 is exactly the sine it always was.
    NodeHarness plain("SineOscillator", kOneSecond, kSampleRate,
        testing::Coverage::SmokeTest);
    plain.set("frequency", 100.0f);
    plain.set("shape", 0.0f);
    plain.process();
    NodeHarness reference("SineOscillator", kOneSecond, kSampleRate,
        testing::Coverage::SmokeTest);
    reference.set("frequency", 100.0f);
    reference.process();
    bool identical = true;
    for (std::size_t i = 0; i < plain.output().size(); ++i) {
        if (plain.output()[i] != reference.output()[i]) {
            identical = false;
            break;
        }
    }
    CHECK(identical);
}

TEST(saw_oscillator_sweeps_the_full_range_and_is_band_limited) {
    NodeHarness harness("SawOscillator", kOneSecond, kSampleRate);
    harness.set("frequency", 440.0f);
    harness.process();

    CHECK_NEAR(testing::mean(harness.output()), 0.0, 0.01);
    CHECK(testing::peak(harness.output()) > 0.9f);
    // PolyBLEP softens the discontinuity; without it the peak would sit at exactly 1.0
    // and the wave would alias.
    CHECK(testing::peak(harness.output()) <= 1.05f);
}

TEST(square_pulse_width_shifts_the_duty_cycle) {
    NodeHarness even("SquareOscillator", kOneSecond, kSampleRate);
    even.set("frequency", 200.0f);
    even.set("pulse_width", 0.5f);
    even.process();
    CHECK_NEAR(testing::mean(even.output()), 0.0, 0.01);

    NodeHarness narrow("SquareOscillator", kOneSecond, kSampleRate);
    narrow.set("frequency", 200.0f);
    narrow.set("pulse_width", 0.25f);
    narrow.process();
    // A quarter of the cycle at +1 and three quarters at -1 averages to -0.5.
    CHECK_NEAR(testing::mean(narrow.output()), -0.5, 0.02);
}

// ---- noise --------------------------------------------------------------------------

TEST(noise_is_reproducible_for_a_given_seed) {
    NodeHarness first("Noise", 4096, kSampleRate);
    NodeHarness second("Noise", 4096, kSampleRate);
    first.set("seed", 4242.0f);
    second.set("seed", 4242.0f);
    first.process();
    second.process();

    bool identical = true;
    for (std::size_t i = 0; i < first.output().size(); ++i) {
        if (first.output()[i] != second.output()[i]) {
            identical = false;
            break;
        }
    }
    CHECK_MESSAGE(identical, "the same seed must produce the same sequence, or goldens are meaningless");

    NodeHarness different("Noise", 4096, kSampleRate);
    different.set("seed", 99.0f);
    different.process();
    CHECK(different.output()[0] != first.output()[0]);
}

TEST(white_noise_fills_the_range_without_leaving_it) {
    NodeHarness harness("Noise", 48000, kSampleRate);
    harness.set("colour", 0.0f);
    harness.process();

    CHECK_MESSAGE(testing::peak(harness.output()) <= 1.0f, "noise must stay inside full scale");
    CHECK(testing::peak(harness.output()) > 0.99f);
    CHECK_NEAR(testing::mean(harness.output()), 0.0, 0.01);
    // Uniform over [-1, 1) has an RMS of 1/sqrt(3).
    CHECK_NEAR(testing::rms(harness.output()), 0.5774, 0.01);
}

TEST(pink_noise_stays_centred_and_bounded) {
    NodeHarness harness("Noise", 48000, kSampleRate);
    harness.set("colour", 1.0f);
    harness.process();

    CHECK_NEAR(testing::mean(harness.output()), 0.0, 0.05);
    CHECK_MESSAGE(testing::peak(harness.output()) < 2.0f,
                  "pink noise should stay in the same neighbourhood as white, not run away");
}

TEST(pink_noise_has_more_energy_than_white_at_the_same_scale) {
    NodeHarness white("Noise", 48000, kSampleRate);
    white.set("colour", 0.0f);
    white.process();

    NodeHarness pink("Noise", 48000, kSampleRate);
    pink.set("colour", 1.0f);
    pink.process();

    CHECK(testing::rms(white.output()) > 0.4);
    CHECK(testing::rms(pink.output()) > 0.0);
    // Pink noise is low-frequency weighted, so it crosses zero far less often.
    CHECK(testing::rising_zero_crossings(pink.output()) <
          testing::rising_zero_crossings(white.output()));
}

// ---- amplitude ----------------------------------------------------------------------

TEST(gain_multiplies_by_parameter_and_input_together) {
    NodeHarness harness("Gain", 64, kSampleRate);
    harness.connect("in", 1.0f);
    harness.set("gain", 0.5f);
    harness.process();
    CHECK_NEAR(harness.output()[0], 0.5, 1e-6);

    harness.connect("gain", 0.25f);
    harness.process();
    CHECK_NEAR(harness.output()[0], 0.125, 1e-6);
}

TEST(level_trims_by_its_parameter_and_nothing_else) {
    NodeHarness harness("Level", 64, kSampleRate);
    harness.connect("in", 1.0f);
    harness.set("level", 0.5f);
    harness.process();
    CHECK_NEAR(harness.output()[0], 0.5, 1e-6);

    // At 1 it is a wire: this is the identity that lets expansion stand one in for
    // every trimmed port without changing a patch that left the trim alone.
    harness.set("level", 1.0f);
    harness.process();
    CHECK_NEAR(harness.output()[0], 1.0, 1e-6);
}

TEST(stereo_level_trims_both_channels_and_keeps_them_apart) {
    NodeHarness harness("StereoLevel", 64, kSampleRate);
    harness.connect("left", 1.0f);
    harness.connect("right", 0.5f);
    harness.set("level", 0.5f);
    harness.process();
    CHECK_NEAR(harness.output(0)[0], 0.5, 1e-6);
    CHECK_NEAR(harness.output(1)[0], 0.25, 1e-6);
}

TEST(mixer_sums_channels_at_their_levels) {
    NodeHarness harness("Mixer", 64, kSampleRate);
    harness.connect("in1", 1.0f);
    harness.connect("in2", 1.0f);
    harness.set("level1", 0.5f);
    harness.set("level2", 0.25f);
    harness.process();
    CHECK_NEAR(harness.output()[0], 0.75, 1e-6);
}

TEST(unconnected_mixer_channels_contribute_nothing) {
    NodeHarness harness("Mixer", 64, kSampleRate);
    harness.connect("in3", 2.0f);
    harness.set("level3", 0.5f);
    harness.process();
    CHECK_NEAR(harness.output()[0], 1.0, 1e-6);
}

TEST(add_and_multiply_fall_back_to_their_parameters) {
    NodeHarness add("Add", 16, kSampleRate);
    add.connect("a", 3.0f);
    add.set("offset", 4.0f);
    add.process();
    CHECK_NEAR(add.output()[0], 7.0, 1e-6);

    NodeHarness multiply("Multiply", 16, kSampleRate);
    multiply.connect("a", 3.0f);
    multiply.set("factor", 4.0f);
    multiply.process();
    CHECK_NEAR(multiply.output()[0], 12.0, 1e-6);

    multiply.connect("b", 0.5f);
    multiply.process();
    CHECK_NEAR(multiply.output()[0], 1.5, 1e-6);
}

TEST(constant_holds_its_value) {
    NodeHarness harness("Constant", 16, kSampleRate);
    harness.set("value", -2.5f);
    harness.process();
    CHECK_NEAR(harness.output()[0], -2.5, 1e-6);
    CHECK_NEAR(harness.output()[15], -2.5, 1e-6);
}

TEST(clip_keeps_the_signal_between_its_limits) {
    NodeHarness harness("Clip", 5, kSampleRate);
    std::vector<float>& in = harness.input("in");
    in = {-2.0f, -0.3f, 0.0f, 0.3f, 2.0f};
    harness.set("floor", -0.5f);
    harness.set("ceiling", 0.5f);
    harness.process();
    CHECK_NEAR(harness.output()[0], -0.5, 1e-6);
    CHECK_NEAR(harness.output()[1], -0.3, 1e-6);
    CHECK_NEAR(harness.output()[3], 0.3, 1e-6);
    CHECK_NEAR(harness.output()[4], 0.5, 1e-6);
}

TEST(clip_survives_a_floor_dragged_past_the_ceiling) {
    NodeHarness harness("Clip", 3, kSampleRate);
    harness.connect("in", 0.0f);
    harness.set("floor", 2.0f);
    harness.set("ceiling", -2.0f);
    harness.process();
    CHECK_NEAR(harness.output()[0], 2.0, 1e-6);
}

TEST(abs_folds_negative_upward) {
    NodeHarness harness("Abs", 4, kSampleRate);
    std::vector<float>& in = harness.input("in");
    in = {-1.5f, -0.25f, 0.0f, 0.75f};
    harness.process();
    CHECK_NEAR(harness.output()[0], 1.5, 1e-6);
    CHECK_NEAR(harness.output()[1], 0.25, 1e-6);
    CHECK_NEAR(harness.output()[2], 0.0, 1e-6);
    CHECK_NEAR(harness.output()[3], 0.75, 1e-6);
}

TEST(minmax_picks_a_side_and_falls_back) {
    NodeHarness max_side("MinMax", 4, kSampleRate);
    max_side.connect("a", 0.2f);
    max_side.connect("b", 0.8f);
    max_side.set("mode", 1.0f);
    max_side.process();
    CHECK_NEAR(max_side.output()[0], 0.8, 1e-6);

    NodeHarness min_side("MinMax", 4, kSampleRate);
    min_side.connect("a", 0.2f);
    min_side.connect("b", 0.8f);
    min_side.set("mode", 0.0f);
    min_side.process();
    CHECK_NEAR(min_side.output()[0], 0.2, 1e-6);

    NodeHarness fallback("MinMax", 4, kSampleRate);
    fallback.connect("a", -0.4f);
    fallback.set("mode", 1.0f);
    fallback.set("other", 0.0f);
    fallback.process();
    CHECK_NEAR(fallback.output()[0], 0.0, 1e-6);
}

TEST(compare_turns_a_crossing_into_a_gate) {
    NodeHarness harness("Compare", 4, kSampleRate);
    std::vector<float>& in = harness.input("a");
    in = {-1.0f, 0.29f, 0.3f, 1.0f};
    harness.set("threshold", 0.3f);
    harness.process();
    CHECK_NEAR(harness.output()[0], 0.0, 1e-6);
    CHECK_NEAR(harness.output()[1], 0.0, 1e-6);
    CHECK_NEAR(harness.output()[2], 1.0, 1e-6);
    CHECK_NEAR(harness.output()[3], 1.0, 1e-6);
}

TEST(samplehold_freezes_on_the_rising_edge_only) {
    NodeHarness harness("SampleHold", 8, kSampleRate);
    std::vector<float>& in = harness.input("in");
    in = {0.1f, 0.2f, 0.3f, 0.4f, 0.5f, 0.6f, 0.7f, 0.8f};
    std::vector<float>& trigger = harness.input("trigger");
    // One edge at frame 1, held through frame 3 — a held gate must not re-sample —
    // then a second edge at frame 5.
    trigger = {0.0f, 1.0f, 1.0f, 1.0f, 0.0f, 1.0f, 0.0f, 0.0f};
    harness.process();
    CHECK_NEAR(harness.output()[0], 0.0, 1e-6);
    CHECK_NEAR(harness.output()[1], 0.2, 1e-6);
    CHECK_NEAR(harness.output()[3], 0.2, 1e-6);
    CHECK_NEAR(harness.output()[4], 0.2, 1e-6);
    CHECK_NEAR(harness.output()[5], 0.6, 1e-6);
    CHECK_NEAR(harness.output()[7], 0.6, 1e-6);
}




// ---- envelope -----------------------------------------------------------------------

TEST(adsr_moves_through_its_stages) {
    const int frames = 48000;
    NodeHarness harness("ADSR", frames, kSampleRate);
    harness.set("attack", 0.01f);
    harness.set("decay", 0.05f);
    harness.set("sustain", 0.5f);
    harness.set("release", 0.05f);

    // Gate held for the first half second, released for the second.
    std::vector<float>& gate = harness.input("gate");
    for (int i = 0; i < frames; ++i) {
        gate[static_cast<std::size_t>(i)] = i < frames / 2 ? 1.0f : 0.0f;
    }
    harness.process();

    const std::vector<float>& out = harness.output();
    CHECK_NEAR(out[0], 0.0, 0.01);
    // Attack lasts 480 samples and must reach full level before decay takes over.
    const float attack_peak = *std::max_element(out.begin(), out.begin() + 600);
    CHECK_NEAR(attack_peak, 1.0, 0.01);
    CHECK_NEAR(out[480], 1.0, 0.01);
    // Well past attack + decay, the envelope holds at the sustain level.
    CHECK_NEAR(out[20000], 0.5, 0.01);
    // Half a second after release, it is back to silence.
    CHECK_NEAR(out[frames - 1], 0.0, 0.001);
}

TEST(adsr_with_zero_sustain_falls_silent_while_the_key_is_still_down) {
    const int frames = 24000;
    NodeHarness harness("ADSR", frames, kSampleRate);
    harness.set("attack", 0.001f);
    harness.set("decay", 0.05f);
    harness.set("sustain", 0.0f);
    harness.set("release", 0.05f);
    harness.connect("gate", 1.0f);
    harness.process();

    CHECK(harness.output()[100] > 0.5f);
    CHECK_NEAR(harness.output()[frames - 1], 0.0, 0.01);
}

TEST(adsr_without_a_gate_stays_silent) {
    NodeHarness harness("ADSR", 1024, kSampleRate);
    harness.process();
    CHECK_NEAR(testing::peak(harness.output()), 0.0, 1e-9);
}

// ---- LFO ----------------------------------------------------------------------------

TEST(lfo_applies_amount_and_offset) {
    NodeHarness harness("LFO", kOneSecond, kSampleRate);
    harness.set("rate", 4.0f);
    harness.set("shape", 0.0f);
    harness.set("amount", 2.0f);
    harness.set("offset", 3.0f);
    harness.process();

    CHECK_NEAR(testing::mean(harness.output()), 3.0, 0.02);
    CHECK_NEAR(testing::peak(harness.output()), 5.0, 0.01);
    CHECK_NEAR(testing::rising_zero_crossings(harness.output()), 0, 0);  // never crosses zero
}

TEST(lfo_runs_at_the_requested_rate) {
    NodeHarness harness("LFO", kOneSecond, kSampleRate);
    harness.set("rate", 7.0f);
    harness.set("shape", 0.0f);
    harness.process();
    CHECK_NEAR(testing::rising_zero_crossings(harness.output()), 7, 1);
}

TEST(lfo_square_shape_only_takes_two_values) {
    NodeHarness harness("LFO", 4800, kSampleRate);
    harness.set("rate", 5.0f);
    harness.set("shape", 3.0f);
    harness.process();
    for (float sample : harness.output()) {
        CHECK(sample == 1.0f || sample == -1.0f);
    }
}

// ---- filter -------------------------------------------------------------------------

namespace {

// Drives the filter with a sine at `frequency` and reports the output level.
double filter_response(float cutoff, float frequency, float mode) {
    const int frames = 24000;
    NodeHarness oscillator("SineOscillator", frames, kSampleRate);
    oscillator.set("frequency", frequency);
    oscillator.process();

    NodeHarness filter("StateVariableFilter", frames, kSampleRate);
    filter.set("cutoff", cutoff);
    filter.set("resonance", 0.0f);
    filter.set("mode", mode);
    filter.input("in") = oscillator.output();
    filter.process();

    // Measure the tail only, so that the filter's settling is not counted.
    std::vector<float> tail(filter.output().begin() + frames / 2, filter.output().end());
    return testing::rms(tail);
}

}  // namespace

TEST(lowpass_passes_below_cutoff_and_stops_above) {
    const double reference = testing::rms(std::vector<float>(1000, 0.7071f));

    const double passed = filter_response(4000.0f, 200.0f, 0.0f);
    const double stopped = filter_response(200.0f, 8000.0f, 0.0f);

    CHECK_NEAR(passed, reference, 0.05);
    CHECK_MESSAGE(stopped < reference * 0.05,
                  "a tone five octaves above cutoff should be well down");
}

TEST(highpass_is_the_mirror_of_lowpass) {
    const double passed = filter_response(200.0f, 8000.0f, 1.0f);
    const double stopped = filter_response(4000.0f, 100.0f, 1.0f);

    CHECK(passed > 0.6);
    CHECK(stopped < 0.05);
}

TEST(resonance_lifts_the_level_at_cutoff) {
    const int frames = 24000;
    auto measure = [&](float resonance) {
        NodeHarness oscillator("SineOscillator", frames, kSampleRate);
        oscillator.set("frequency", 1000.0f);
        oscillator.process();

        NodeHarness filter("StateVariableFilter", frames, kSampleRate);
        filter.set("cutoff", 1000.0f);
        filter.set("resonance", resonance);
        filter.input("in") = oscillator.output();
        filter.process();
        std::vector<float> tail(filter.output().begin() + frames / 2, filter.output().end());
        return testing::rms(tail);
    };

    CHECK(measure(0.9f) > measure(0.0f) * 2.0);
}

TEST(filter_stays_stable_with_cutoff_pushed_at_nyquist) {
    const int frames = 4800;
    NodeHarness oscillator("SawOscillator", frames, kSampleRate);
    oscillator.set("frequency", 220.0f);
    oscillator.process();

    NodeHarness filter("StateVariableFilter", frames, kSampleRate);
    filter.set("cutoff", 20000.0f);
    filter.set("resonance", 1.0f);
    filter.input("in") = oscillator.output();
    filter.process();

    CHECK_MESSAGE(testing::peak(filter.output()) < 10.0f,
                  "the filter must not blow up when swept to the top");
}

TEST(filter_without_an_input_outputs_silence) {
    NodeHarness filter("StateVariableFilter", 256, kSampleRate);
    filter.process();
    CHECK_NEAR(testing::peak(filter.output()), 0.0, 1e-9);
}

// ---- delay --------------------------------------------------------------------------

TEST(delay_moves_an_impulse_by_the_requested_time) {
    const int frames = 24000;
    NodeHarness harness("Delay", frames, kSampleRate);
    harness.set("time", 0.1f);        // 4800 samples
    harness.set("feedback", 0.0f);
    harness.set("mix", 1.0f);         // delayed signal only
    harness.input("in")[0] = 1.0f;
    harness.process();

    CHECK_NEAR(harness.output()[0], 0.0, 1e-6);
    CHECK_NEAR(harness.output()[4800], 1.0, 0.001);
    CHECK_NEAR(harness.output()[4700], 0.0, 1e-6);
}

TEST(delay_feedback_produces_decaying_repeats) {
    const int frames = 48000;
    NodeHarness harness("Delay", frames, kSampleRate);
    harness.set("time", 0.1f);
    harness.set("feedback", 0.5f);
    harness.set("mix", 1.0f);
    harness.input("in")[0] = 1.0f;
    harness.process();

    CHECK_NEAR(harness.output()[4800], 1.0, 0.001);
    CHECK_NEAR(harness.output()[9600], 0.5, 0.01);
    CHECK_NEAR(harness.output()[14400], 0.25, 0.01);
}

TEST(delay_mix_blends_dry_and_wet) {
    NodeHarness harness("Delay", 1024, kSampleRate);
    harness.set("time", 0.01f);
    harness.set("feedback", 0.0f);
    harness.set("mix", 0.0f);
    harness.connect("in", 1.0f);
    harness.process();
    CHECK_NEAR(harness.output()[0], 1.0, 1e-6);
}

// ---- terminals ----------------------------------------------------------------------

// AudioInput was the one registered type with no jig at all, which is easy to explain and
// was still worth fixing: it is the only node whose input arrives through its *outputs*,
// so there was no obvious way to drive it and it quietly stayed untested. Everything it
// does — scale what the host already wrote — happens on a path nothing else takes.
TEST(audio_input_scales_what_the_host_wrote_into_its_outputs) {
    NodeHarness harness("AudioInput", 64, kSampleRate);
    CHECK(harness.valid());
    harness.fill_output("left", 0.5f);
    harness.fill_output("right", -0.25f);
    harness.set("gain", 2.0f);
    harness.process();

    CHECK_NEAR(harness.output("left")[0], 1.0, 1e-6);
    CHECK_NEAR(harness.output("right")[0], -0.5, 1e-6);
    CHECK_NEAR(harness.output("left")[63], 1.0, 1e-6);
}

TEST(audio_input_at_unity_leaves_the_host_samples_alone) {
    NodeHarness harness("AudioInput", 64, kSampleRate);
    harness.fill_output("left", 0.5f);
    harness.fill_output("right", 0.5f);
    harness.process();  // gain defaults to 1

    // Unity takes an early return rather than multiplying by 1.0, so this covers a branch
    // the test above does not: a mistake there would silence the input entirely.
    CHECK_NEAR(harness.output("left")[0], 0.5, 1e-6);
    CHECK_NEAR(harness.output("right")[0], 0.5, 1e-6);
}

TEST(audio_input_silences_at_zero_gain) {
    NodeHarness harness("AudioInput", 64, kSampleRate);
    harness.fill_output("left", 1.0f);
    harness.fill_output("right", 1.0f);
    harness.set("gain", 0.0f);
    harness.process();
    CHECK_NEAR(testing::peak(harness.output("left")), 0.0, 1e-6);
    CHECK_NEAR(testing::peak(harness.output("right")), 0.0, 1e-6);
}

TEST(note_input_converts_midi_notes_to_frequencies) {
    NodeHarness harness("NoteInput", 256, kSampleRate);
    soundgraph::NoteEvent event;
    event.kind = soundgraph::NoteEvent::Kind::NoteOn;
    event.note = 69;
    event.velocity = 0.8f;
    harness.node().handle_note_event(event);
    harness.process();

    CHECK_NEAR(harness.output("frequency")[10], 440.0, 0.01);
    CHECK_NEAR(harness.output("gate")[10], 1.0, 1e-6);
    CHECK_NEAR(harness.output("velocity")[10], 0.8, 1e-6);

    event.kind = soundgraph::NoteEvent::Kind::NoteOff;
    harness.node().handle_note_event(event);
    harness.process();
    CHECK_NEAR(harness.output("gate")[10], 0.0, 1e-6);
}

TEST(note_input_falls_back_to_the_note_still_held) {
    NodeHarness harness("NoteInput", 64, kSampleRate);
    auto send = [&](soundgraph::NoteEvent::Kind kind, int note) {
        soundgraph::NoteEvent event;
        event.kind = kind;
        event.note = note;
        event.velocity = 1.0f;
        harness.node().handle_note_event(event);
    };

    send(soundgraph::NoteEvent::Kind::NoteOn, 60);
    send(soundgraph::NoteEvent::Kind::NoteOn, 72);
    harness.process();
    CHECK_NEAR(harness.output("frequency")[0], 523.25, 0.5);  // C5

    send(soundgraph::NoteEvent::Kind::NoteOff, 72);
    harness.process();
    CHECK_NEAR(harness.output("frequency")[0], 261.63, 0.5);  // back to C4
    CHECK_NEAR(harness.output("gate")[0], 1.0, 1e-6);
}

TEST(note_triggers_fire_their_lanes) {
    NodeHarness harness("NoteTriggers", 256, kSampleRate);
    auto strike = [&](int note) {
        soundgraph::NoteEvent event;
        event.kind = soundgraph::NoteEvent::Kind::NoteOn;
        event.note = note;
        event.velocity = 1.0f;
        harness.node().handle_note_event(event);
    };

    strike(48);  // the default base: C3 fires the first lane and nothing else
    harness.process();
    CHECK_NEAR(harness.output("t1")[0], 1.0, 1e-6);
    CHECK_NEAR(harness.output("t2")[0], 0.0, 1e-6);
    CHECK_NEAR(harness.output("t8")[0], 0.0, 1e-6);
    // A trigger is an edge, not a level: the pulse is over well inside the block.
    CHECK_NEAR(harness.output("t1")[200], 0.0, 1e-6);

    strike(55);  // seven semitones up: the last lane
    strike(47);  // below the base: not for this node
    strike(56);  // past the last lane: not for this node either
    harness.process();
    CHECK_NEAR(harness.output("t8")[0], 1.0, 1e-6);
    CHECK_NEAR(harness.output("t1")[0], 0.0, 1e-6);
    CHECK_NEAR(harness.output("t7")[0], 0.0, 1e-6);

    harness.set("base", 60.0f);  // the knob moves the whole row of pads
    strike(60);
    harness.process();
    CHECK_NEAR(harness.output("t1")[0], 1.0, 1e-6);
}

TEST(note_triggers_carry_a_bus) {
    // Lane n rides the bus as bit n, so simultaneous hits sum cleanly and a scope
    // reads which pad fired by pulse height.
    NodeHarness harness("NoteTriggers", 128, kSampleRate);
    auto strike = [&](int note) {
        soundgraph::NoteEvent event;
        event.kind = soundgraph::NoteEvent::Kind::NoteOn;
        event.note = note;
        event.velocity = 1.0f;
        harness.node().handle_note_event(event);
    };
    strike(48);  // lane one: bit zero
    strike(50);  // lane three: bit two
    harness.process();
    CHECK_NEAR(harness.output("bus")[0], 5.0, 1e-6);  // 1 + 4
    // An upstream bus rides through, so routers chain on one wire.
    harness.connect("bus", 2.0f);
    harness.process();
    CHECK_NEAR(harness.output("bus")[0], 2.0, 1e-6);
}

TEST(note_triggers_ride_a_shifted_bank) {
    // The second card's lanes park eight bits up, so two routers chained
    // bus-to-bus put sixteen distinct lanes on one wire.
    NodeHarness harness("NoteTriggers", 128, kSampleRate);
    harness.set("shift", 8.0f);
    soundgraph::NoteEvent event;
    event.kind = soundgraph::NoteEvent::Kind::NoteOn;
    event.note = 48;
    event.velocity = 1.0f;
    harness.node().handle_note_event(event);
    harness.process();
    CHECK_NEAR(harness.output("t1")[0], 1.0, 1e-6);  // the pad itself is unshifted
    CHECK_NEAR(harness.output("bus")[0], 256.0, 1e-6);  // bit eight, the high bank
    // A low-bank bus from the first router rides through untouched.
    harness.connect("bus", 5.0f);
    harness.process();
    CHECK_NEAR(harness.output("bus")[0], 5.0, 1e-6);
}

TEST(drive_saturates_and_keeps_full_scale) {
    // The normalisation contract: whatever the drive, a full-scale input comes
    // out full scale — the knob shapes the wave, the Level knob after it sets
    // the loudness. At low drive a half-scale input passes nearly linear; at
    // high drive it is slammed to the rail.
    NodeHarness gentle("Drive", 64, kSampleRate);
    gentle.set("drive", 1.0f);
    gentle.connect("in", 0.5f);
    gentle.process();
    CHECK_NEAR(gentle.output("out")[0], std::tanh(0.5) / std::tanh(1.0), 1e-5);

    NodeHarness slammed("Drive", 64, kSampleRate);
    slammed.set("drive", 30.0f);
    slammed.connect("in", 0.5f);
    slammed.process();
    CHECK_NEAR(slammed.output("out")[0], 1.0, 1e-4);

    // The control input replaces the parameter while connected.
    NodeHarness pedalled("Drive", 64, kSampleRate);
    pedalled.set("drive", 1.0f);
    pedalled.connect("in", 0.5f);
    pedalled.connect("drive", 30.0f);
    pedalled.process();
    CHECK_NEAR(pedalled.output("out")[0], 1.0, 1e-4);
}

TEST(trigger_bus_splits_its_lanes) {
    NodeHarness harness("TriggerBus", 64, kSampleRate);
    harness.connect("bus", 5.0f);  // lanes one and three
    harness.process();
    CHECK_NEAR(harness.output("t1")[0], 1.0, 1e-6);
    CHECK_NEAR(harness.output("t2")[0], 0.0, 1e-6);
    CHECK_NEAR(harness.output("t3")[0], 1.0, 1e-6);
    CHECK_NEAR(harness.output("t8")[0], 0.0, 1e-6);
}

TEST(a_shifted_trigger_bus_reads_the_high_bank) {
    // One wire, two banks: bits 8 and 10 are the second card's lanes one and
    // three, and the low bank's bits must not bleed through.
    NodeHarness harness("TriggerBus", 64, kSampleRate);
    harness.set("shift", 8.0f);
    // 2 + 4 + 256 + 1024: the banks deliberately disagree — low holds lanes two
    // and three, high holds lanes one and three — so a splitter that ignores its
    // shift reads the wrong pattern and fails, not the same one by luck.
    harness.connect("bus", 1286.0f);
    harness.process();
    CHECK_NEAR(harness.output("t1")[0], 1.0, 1e-6);
    CHECK_NEAR(harness.output("t2")[0], 0.0, 1e-6);
    CHECK_NEAR(harness.output("t3")[0], 1.0, 1e-6);
    CHECK_NEAR(harness.output("t8")[0], 0.0, 1e-6);
}

// The bug this guards: a one-shot patch played by jabbing at a key sounded once and then
// went quiet. Two notes overlapping keep the gate high the whole way through, so an AHD
// envelope watching the gate never sees a second rising edge. The trigger output exists to
// carry "a note started" through a signal that otherwise only says "a note is held".
// A generated sound effect is a transposing instrument — the mapper offsets the keyboard so
// that middle C plays the patch at the pitch it was designed around — and 19 of the 41 sfxr
// cases need more than the two octaves a musical transpose control would offer. Parameters
// clamp on load, so getting this wrong is silent: the file keeps the right number and the
// sound comes out at the wrong pitch.
TEST(note_input_transposes_further_than_two_octaves) {
    NodeHarness harness("NoteInput", 64, kSampleRate);
    harness.set("transpose", -69.534f);  // the largest the corpus asks for
    soundgraph::NoteEvent event;
    event.kind = soundgraph::NoteEvent::Kind::NoteOn;
    event.note = 60;
    harness.node().handle_note_event(event);
    harness.process();
    // 261.63 Hz shifted down 69.534 semitones. Clamped to -24 it would be 65.5 Hz, so the
    // check is nowhere near the failure it is guarding against.
    CHECK_NEAR(harness.output("frequency")[0], 4.7137, 0.001);
}

TEST(note_input_triggers_on_a_note_played_over_a_held_one) {
    // Long enough that a whole pulse fits inside one block with room to spare, so "the
    // pulse ended" and "the pulse never came" are distinguishable.
    constexpr int kBlock = 256;
    NodeHarness harness("NoteInput", kBlock, kSampleRate);
    auto send = [&](int note) {
        soundgraph::NoteEvent event;
        event.kind = soundgraph::NoteEvent::Kind::NoteOn;
        event.note = note;
        event.velocity = 1.0f;
        harness.node().handle_note_event(event);
    };
    auto pulsed = [&]() {
        for (int i = 0; i < kBlock; ++i) {
            if (harness.output("trigger")[i] > 0.5f) return true;
        }
        return false;
    };
    auto gate_ever_low = [&]() {
        for (int i = 0; i < kBlock; ++i) {
            if (harness.output("gate")[i] < 0.5f) return true;
        }
        return false;
    };

    send(60);
    harness.process();
    CHECK(pulsed());

    // Nothing happened here, so nothing should fire. This is what separates a trigger from
    // a gate: without it the whole test would pass against the old behaviour, where the
    // trigger and the gate were the same signal.
    harness.process();
    CHECK(!pulsed());

    // The second note arrives with the first still down, which is the case that failed.
    send(64);
    harness.process();
    CHECK(pulsed());
    // And it is genuinely the overlapping case: nothing released the gate in between, so
    // an edge detector watching the gate would have had nothing to find.
    CHECK(!gate_ever_low());
}

TEST(note_input_trigger_is_a_pulse_not_a_level) {
    NodeHarness harness("NoteInput", 4096, kSampleRate);
    soundgraph::NoteEvent event;
    event.kind = soundgraph::NoteEvent::Kind::NoteOn;
    event.note = 60;
    event.velocity = 1.0f;
    harness.node().handle_note_event(event);
    harness.process();

    int high = 0;
    for (int i = 0; i < 4096; ++i) {
        if (harness.output("trigger")[i] > 0.5f) high++;
    }
    // About a millisecond, and over well before the block ends — a trigger that stayed
    // high would be a gate by another name and would retrigger nothing.
    CHECK(high > 0 && high < 4096);
    CHECK_NEAR(static_cast<double>(high) / kSampleRate, 0.001, 0.0005);
    CHECK_NEAR(harness.output("trigger")[4095], 0.0, 1e-6);
}

TEST(note_input_transpose_shifts_by_semitones) {
    NodeHarness harness("NoteInput", 64, kSampleRate);
    harness.set("transpose", 12.0f);
    soundgraph::NoteEvent event;
    event.kind = soundgraph::NoteEvent::Kind::NoteOn;
    event.note = 69;
    harness.node().handle_note_event(event);
    harness.process();
    CHECK_NEAR(harness.output("frequency")[0], 880.0, 0.05);
}

TEST(stereo_output_copies_a_mono_chain_to_both_channels) {
    NodeHarness harness("StereoOutput", 64, kSampleRate);
    harness.set("level", 1.0f);
    harness.connect("left", 0.5f);
    harness.process();

    CHECK_NEAR(harness.output(0)[0], 0.5, 1e-6);
    CHECK_NEAR(harness.output(1)[0], 0.5, 1e-6);
}

TEST(stereo_output_safety_limit_tames_an_overload) {
    NodeHarness limited("StereoOutput", 64, kSampleRate);
    limited.set("level", 1.0f);
    limited.set("safety_limit", 1.0f);
    limited.connect("left", 8.0f);
    limited.process();
    CHECK(limited.output(0)[0] < 1.01f);

    NodeHarness unlimited("StereoOutput", 64, kSampleRate);
    unlimited.set("level", 1.0f);
    unlimited.set("safety_limit", 0.0f);
    unlimited.connect("left", 8.0f);
    unlimited.process();
    CHECK_NEAR(unlimited.output(0)[0], 8.0, 1e-6);
}

// ---- parameter handling -------------------------------------------------------------

TEST(parameters_are_clamped_to_their_declared_range) {
    NodeHarness harness("Gain", 16, kSampleRate);
    harness.set("gain", 1000.0f);
    harness.connect("in", 1.0f);
    harness.process();
    CHECK_NEAR(harness.output()[0], 4.0, 1e-6);  // gain maxes at 4

    harness.set("gain", -5.0f);
    harness.process();
    CHECK_NEAR(harness.output()[0], 0.0, 1e-6);
}

// ---- one-pole filter ------------------------------------------------------------------

namespace {

// Drives a filter with a steady sine and returns the settled amplitude, measured over the
// second half so the filter's own start-up transient is not in the answer.
float settled_amplitude(const std::string& type, float cutoff, float mode, float tone) {
    const int frames = 24000;
    NodeHarness harness(type, frames, kSampleRate);
    harness.set("cutoff", cutoff);
    harness.set("mode", mode);
    std::vector<float>& in = harness.input("in");
    for (std::size_t i = 0; i < in.size(); ++i) {
        in[i] = std::sin(6.2831853f * tone * static_cast<float>(i) / 48000.0f);
    }
    harness.process();

    float peak = 0.0f;
    for (std::size_t i = in.size() / 2; i < in.size(); ++i) {
        peak = std::max(peak, std::fabs(harness.output()[i]));
    }
    return peak;
}

}  // namespace

namespace {
// A sine at tone_hz through the Formant node; the settled tail's RMS.
float formant_response(float morph, float tone_hz) {
    NodeHarness harness("Formant", 8000, kSampleRate);
    harness.set("morph", morph);
    harness.set("emphasis", 0.5f);
    std::vector<float>& in = harness.input("in");
    for (size_t i = 0; i < in.size(); ++i) {
        in[i] = std::sin(2.0f * 3.14159265f * tone_hz * static_cast<float>(i)
            / static_cast<float>(kSampleRate));
    }
    harness.process();
    float sum = 0.0f;
    for (size_t i = 4000; i < 8000; ++i) {
        sum += harness.output()[i] * harness.output()[i];
    }
    return std::sqrt(sum / 4000.0f);
}
}  // namespace

TEST(formant_vowels_move_the_energy) {
    // "Ah" has its first formant at 650 Hz, "ee" at 290: a tone under each vowel's
    // own formant should ring far louder than under the other's.
    CHECK(formant_response(0.0f, 650.0f) > 2.0f * formant_response(2.0f, 650.0f));
    CHECK(formant_response(2.0f, 290.0f) > 2.0f * formant_response(0.0f, 290.0f));
}

TEST(formant_morph_blends_rather_than_switches) {
    // Halfway between A and E, a 650 Hz tone sits between the two ends' responses.
    const float at_a = formant_response(0.0f, 650.0f);
    const float at_e = formant_response(1.0f, 650.0f);
    const float between = formant_response(0.5f, 650.0f);
    CHECK(between < at_a);
    CHECK(between > at_e);
}

TEST(formant_stays_finite_driven_hard) {
    NodeHarness harness("Formant", 8000, kSampleRate);
    harness.set("morph", 4.0f);
    harness.set("emphasis", 1.0f);
    std::vector<float>& in = harness.input("in");
    for (size_t i = 0; i < in.size(); ++i) {
        // A loud naive saw, the harshest thing a keyboard patch will feed it.
        in[i] = 2.0f * (static_cast<float>(i % 200) / 200.0f) - 1.0f;
    }
    harness.process();
    for (size_t i = 0; i < 8000; ++i) {
        CHECK(std::isfinite(harness.output()[i]));
        CHECK(std::fabs(harness.output()[i]) < 10.0f);
    }
}

TEST(one_pole_lowpass_passes_below_and_cuts_above) {
    CHECK_NEAR(settled_amplitude("OnePoleFilter", 1000.0f, 0.0f, 50.0f), 1.0, 0.02);
    // A one-pole is 3 dB down at its own cutoff.
    CHECK_NEAR(settled_amplitude("OnePoleFilter", 1000.0f, 0.0f, 1000.0f), 0.707, 0.03);
    CHECK(settled_amplitude("OnePoleFilter", 1000.0f, 0.0f, 8000.0f) < 0.2f);
}

TEST(one_pole_highpass_blocks_dc_and_passes_above) {
    NodeHarness harness("OnePoleFilter", 8000, kSampleRate);
    harness.set("cutoff", 100.0f);
    harness.set("mode", 1.0f);
    harness.connect("in", 1.0f);  // pure DC
    harness.process();
    CHECK(std::fabs(harness.output()[7999]) < 0.01f);

    CHECK_NEAR(settled_amplitude("OnePoleFilter", 100.0f, 1.0f, 4000.0f), 1.0, 0.02);
}

TEST(one_pole_has_half_the_slope_of_the_state_variable_filter) {
    // The reason both exist, and the whole of the remaining error on sfxr's hit-hurt
    // sounds: they sit far below a highpass cutoff, where the slope is everything.
    // Two octaves down, one pole should take about 12 dB off and two poles about 24.
    const float one_pole = settled_amplitude("OnePoleFilter", 500.0f, 1.0f, 125.0f);
    const float two_pole = settled_amplitude("StateVariableFilter", 500.0f, 1.0f, 125.0f);

    CHECK(one_pole > two_pole * 3.0f);
    // 12 dB down is a quarter of full scale; allow the usual slack near the corner.
    CHECK(one_pole > 0.15f);
    CHECK(one_pole < 0.40f);
    CHECK(two_pole < 0.12f);
}

// ---- pitched noise --------------------------------------------------------------------

TEST(noise_oscillator_repeats_at_its_frequency) {
    // The whole point: this has a period where Noise does not. One second at 200 Hz is
    // 200 cycles of the same table, so the waveform must repeat 200 times.
    NodeHarness harness("NoiseOscillator", kOneSecond, kSampleRate);
    CHECK(harness.valid());
    harness.set("frequency", 200.0f);
    harness.set("steps", 32.0f);
    harness.process();

    // A table refilled every cycle still crosses zero on a schedule set by the period, so
    // the crossing count is bounded by steps per cycle rather than being arbitrary.
    const std::vector<float>& out = harness.output();
    const int crossings = testing::rising_zero_crossings(out);
    CHECK(crossings > 200);
    CHECK(crossings < 200 * 32);
    CHECK(testing::peak(out) <= 1.0f);
    CHECK_NEAR(testing::mean(out), 0.0, 0.02);
}

TEST(noise_oscillator_follows_its_frequency_input) {
    // Doubling the pitch has to double the rate at which the texture repeats. This is the
    // property plain Noise cannot have, and the reason this node exists.
    NodeHarness low("NoiseOscillator", kOneSecond, kSampleRate);
    low.connect("frequency", 100.0f);
    low.process();

    NodeHarness high("NoiseOscillator", kOneSecond, kSampleRate);
    high.connect("frequency", 400.0f);
    high.process();

    CHECK(testing::rising_zero_crossings(high.output()) >
          testing::rising_zero_crossings(low.output()) * 2);
}

TEST(noise_oscillator_is_reproducible_and_coarser_with_fewer_steps) {
    NodeHarness first("NoiseOscillator", 4096, kSampleRate);
    NodeHarness second("NoiseOscillator", 4096, kSampleRate);
    first.set("seed", 777.0f);
    second.set("seed", 777.0f);
    first.process();
    second.process();

    bool identical = true;
    for (std::size_t i = 0; i < first.output().size(); ++i) {
        if (first.output()[i] != second.output()[i]) identical = false;
    }
    CHECK_MESSAGE(identical, "the same seed must give the same sequence, or goldens mean nothing");

    // Two steps per cycle is very nearly a square wave: it should cross zero far less
    // often than thirty-two steps of the same length.
    NodeHarness coarse("NoiseOscillator", kOneSecond, kSampleRate);
    coarse.set("frequency", 200.0f);
    coarse.set("steps", 2.0f);
    coarse.process();

    NodeHarness fine("NoiseOscillator", kOneSecond, kSampleRate);
    fine.set("frequency", 200.0f);
    fine.set("steps", 32.0f);
    fine.process();

    CHECK(testing::rising_zero_crossings(coarse.output()) <
          testing::rising_zero_crossings(fine.output()));
}

// ---- shaping: envelopes, pitch movement, retriggering ---------------------------------

TEST(ahd_envelope_runs_attack_hold_decay_and_then_stops) {
    NodeHarness harness("AhdEnvelope", kOneSecond, kSampleRate);
    CHECK(harness.valid());
    harness.set("attack", 0.1f);
    harness.set("hold", 0.2f);
    harness.set("decay", 0.2f);
    harness.set("punch", 0.0f);
    harness.connect("gate", 1.0f);
    harness.process();

    const std::vector<float>& out = harness.output();
    CHECK_NEAR(out[0], 0.0, 0.01);
    CHECK_NEAR(out[static_cast<std::size_t>(0.05 * kSampleRate)], 0.5, 0.01);
    CHECK_NEAR(out[static_cast<std::size_t>(0.15 * kSampleRate)], 1.0, 0.01);
    CHECK_NEAR(out[static_cast<std::size_t>(0.40 * kSampleRate)], 0.5, 0.01);
    CHECK_NEAR(out[static_cast<std::size_t>(0.60 * kSampleRate)], 0.0, 0.01);
}

TEST(ahd_envelope_punch_boosts_the_start_of_the_hold_and_falls_back) {
    NodeHarness harness("AhdEnvelope", kOneSecond, kSampleRate);
    harness.set("attack", 0.0f);
    harness.set("hold", 0.4f);
    harness.set("decay", 0.1f);
    harness.set("punch", 1.0f);
    harness.connect("gate", 1.0f);
    harness.process();

    const std::vector<float>& out = harness.output();
    // Punch of 1 starts the hold at three times full level and returns to 1 across it.
    CHECK_NEAR(testing::peak(out), 3.0, 0.02);
    CHECK_NEAR(out[static_cast<std::size_t>(0.20 * kSampleRate)], 2.0, 0.02);
    // A fortieth of the hold still to run, so a fortieth of the punch is still on: the
    // boost falls back linearly and reaches exactly 1 as the decay begins.
    CHECK_NEAR(out[static_cast<std::size_t>(0.39 * kSampleRate)], 1.05, 0.01);
}

TEST(ahd_envelope_survives_zero_length_stages) {
    // sfxr, which this shape comes from, emits a NaN here: it evaluates the stage ratio on
    // the transition sample, so a zero-length stage is a division by zero. See
    // tests/sfxr/README.md. Nothing in a graph should ever produce one.
    NodeHarness harness("AhdEnvelope", 4800, kSampleRate);
    harness.set("attack", 0.0f);
    harness.set("hold", 0.0f);
    harness.set("decay", 0.0f);
    harness.set("punch", 0.5f);
    harness.connect("gate", 1.0f);
    harness.process();

    for (float sample : harness.output()) {
        CHECK(std::isfinite(sample));
    }
}

TEST(slide_bends_the_pitch_by_the_stated_semitones_per_second) {
    NodeHarness harness("Slide", kOneSecond, kSampleRate);
    CHECK(harness.valid());
    harness.connect("frequency", 440.0f);
    harness.set("slide", 12.0f);  // one octave per second
    harness.process();

    const std::vector<float>& out = harness.output();
    CHECK_NEAR(out[0], 440.0, 0.5);
    CHECK_NEAR(out[static_cast<std::size_t>(0.5 * kSampleRate)], 440.0 * 1.41421, 1.0);
    CHECK_NEAR(out[kOneSecond - 1], 880.0, 1.0);
}

// Both of these used to emit silence with nothing connected, which is how a generated
// patch lost its sound the moment it was imported as a module: the keyboard driving it is
// a NoteInput, NoteInput is a terminal, and terminals are dropped at the module seam. The
// pitch a patch was designed around has to survive somewhere that is not a connection.
TEST(slide_falls_back_to_its_frequency_parameter) {
    NodeHarness harness("Slide", kOneSecond, kSampleRate);
    CHECK(harness.valid());
    harness.set("frequency", 440.0f);
    harness.set("slide", 12.0f);
    harness.process();

    const std::vector<float>& out = harness.output();
    CHECK_NEAR(out[0], 440.0, 0.5);
    // And it is the whole node that runs on the fallback, not just the first sample: the
    // bend still happens.
    CHECK_NEAR(out[kOneSecond - 1], 880.0, 1.0);
}

TEST(slide_frequency_input_wins_over_the_parameter) {
    NodeHarness harness("Slide", 64, kSampleRate);
    harness.set("frequency", 440.0f);
    harness.connect("frequency", 100.0f);
    harness.process();
    CHECK_NEAR(harness.output()[0], 100.0, 0.01);
}

TEST(arpeggio_falls_back_to_its_frequency_parameter) {
    NodeHarness harness("Arpeggio", kOneSecond, kSampleRate);
    CHECK(harness.valid());
    harness.set("frequency", 440.0f);
    harness.set("time", 0.25f);
    harness.set("interval", 12.0f);
    harness.process();

    const std::vector<float>& out = harness.output();
    CHECK_NEAR(out[static_cast<std::size_t>(0.10 * kSampleRate)], 440.0, 0.01);
    CHECK_NEAR(out[static_cast<std::size_t>(0.30 * kSampleRate)], 880.0, 0.01);
}

TEST(arpeggio_frequency_input_wins_over_the_parameter) {
    NodeHarness harness("Arpeggio", 64, kSampleRate);
    harness.set("frequency", 440.0f);
    harness.connect("frequency", 100.0f);
    harness.process();
    CHECK_NEAR(harness.output()[0], 100.0, 0.01);
}

TEST(slide_acceleration_makes_the_bend_speed_up) {
    NodeHarness harness("Slide", kOneSecond, kSampleRate);
    harness.connect("frequency", 100.0f);
    harness.set("slide", 0.0f);
    harness.set("acceleration", 24.0f);  // semitones per second squared
    harness.process();

    // From a standing start the pitch has moved 0.5 * a * t^2 = 12 semitones after 1 s,
    // and a quarter of that at half the time, which a constant rate would not give.
    CHECK_NEAR(harness.output()[kOneSecond - 1], 200.0, 1.0);
    CHECK_NEAR(harness.output()[static_cast<std::size_t>(0.5 * kSampleRate)],
               100.0 * 1.18921, 0.5);
}

TEST(slide_stops_at_its_limit_from_either_direction) {
    NodeHarness falling("Slide", kOneSecond, kSampleRate);
    falling.connect("frequency", 800.0f);
    falling.set("slide", -48.0f);
    falling.set("limit", 200.0f);
    falling.process();
    CHECK_NEAR(falling.output()[kOneSecond - 1], 200.0, 0.001);

    NodeHarness rising("Slide", kOneSecond, kSampleRate);
    rising.connect("frequency", 200.0f);
    rising.set("slide", 48.0f);
    rising.set("limit", 800.0f);
    rising.process();
    CHECK_NEAR(rising.output()[kOneSecond - 1], 800.0, 0.001);
}

TEST(arpeggio_steps_once_at_the_stated_time) {
    NodeHarness harness("Arpeggio", kOneSecond, kSampleRate);
    CHECK(harness.valid());
    harness.connect("frequency", 440.0f);
    harness.set("time", 0.25f);
    harness.set("interval", 12.0f);  // an octave
    harness.process();

    const std::vector<float>& out = harness.output();
    CHECK_NEAR(out[static_cast<std::size_t>(0.10 * kSampleRate)], 440.0, 0.01);
    CHECK_NEAR(out[static_cast<std::size_t>(0.30 * kSampleRate)], 880.0, 0.01);
    // Once, not repeatedly: still an octave up at the end, not two.
    CHECK_NEAR(out[kOneSecond - 1], 880.0, 0.01);
}

TEST(retrigger_fires_at_the_stated_rate_starting_immediately) {
    NodeHarness harness("Retrigger", kOneSecond, kSampleRate);
    CHECK(harness.valid());
    harness.set("rate", 10.0f);
    harness.set("width", 1.0f);
    harness.process();

    int rising_edges = 0;
    bool was_high = false;
    for (float sample : harness.output()) {
        const bool high = sample >= 0.5f;
        if (high && !was_high) ++rising_edges;
        was_high = high;
    }
    CHECK(rising_edges == 10);
    // The first sample is already high, so anything it drives starts without a gap.
    CHECK(harness.output()[0] >= 0.5f);
}

namespace {
std::vector<int> rising_edge_positions(const std::vector<float>& samples) {
    std::vector<int> edges;
    bool was_high = false;
    for (int i = 0; i < static_cast<int>(samples.size()); ++i) {
        const bool high = samples[static_cast<std::size_t>(i)] >= 0.5f;
        if (high && !was_high) edges.push_back(i);
        was_high = high;
    }
    return edges;
}
}  // namespace

TEST(clock_pulses_at_its_division_from_the_first_sample) {
    NodeHarness harness("Clock", kOneSecond, kSampleRate);
    CHECK(harness.valid());
    harness.set("bpm", 120.0f);
    harness.set("division", 4.0f);  // 1/16: four per beat, eight per second at 120
    harness.process();

    const std::vector<int> edges = rising_edge_positions(harness.output("gate"));
    CHECK(static_cast<int>(edges.size()) == 8);
    CHECK(edges.front() == 0);
}

TEST(clock_swing_delays_every_second_step_toward_the_triplet) {
    NodeHarness harness("Clock", kOneSecond, kSampleRate);
    harness.set("bpm", 120.0f);
    harness.set("division", 3.0f);  // 1/8: interval 12000 samples at 48k
    harness.set("swing", 1.0f);
    harness.process();

    const std::vector<int> edges = rising_edge_positions(harness.output("gate"));
    CHECK(static_cast<int>(edges.size()) == 4);
    // Even steps stay on the grid; odd steps land a third of a step late.
    CHECK_NEAR(edges[0], 0, 2);
    CHECK_NEAR(edges[1], 16000, 2);
    CHECK_NEAR(edges[2], 24000, 2);
    CHECK_NEAR(edges[3], 40000, 2);
}

TEST(clock_marks_the_bar_downbeat) {
    const int frames = 2 * kOneSecond;
    NodeHarness harness("Clock", frames, kSampleRate);
    harness.set("bpm", 120.0f);
    harness.set("beats_per_bar", 2.0f);  // a bar each second at 120
    harness.process();

    const std::vector<int> edges = rising_edge_positions(harness.output("bar"));
    CHECK(static_cast<int>(edges.size()) == 2);
    CHECK(edges.front() == 0);
    CHECK_NEAR(edges[1], kOneSecond, 2);
}

TEST(clock_run_gate_stops_and_rewinds_to_the_downbeat) {
    NodeHarness harness("Clock", kOneSecond, kSampleRate);
    harness.set("bpm", 120.0f);
    harness.set("division", 4.0f);
    std::vector<float>& run = harness.input("run");
    // Held low for the first half second, opened for the rest.
    for (int i = kOneSecond / 2; i < kOneSecond; ++i) {
        run[static_cast<std::size_t>(i)] = 1.0f;
    }
    harness.process();

    const std::vector<float>& gate = harness.output("gate");
    bool silent_while_stopped = true;
    for (int i = 0; i < kOneSecond / 2; ++i) {
        silent_while_stopped = silent_while_stopped && gate[static_cast<std::size_t>(i)] < 0.5f;
    }
    CHECK(silent_while_stopped);
    // The first running sample is an edge — the start is a downbeat, not mid-bar.
    CHECK(gate[kOneSecond / 2] >= 0.5f);
    CHECK(harness.output("bar")[kOneSecond / 2] >= 0.5f);
}

TEST(scale_quantizer_passes_scale_notes_untouched) {
    NodeHarness harness("ScaleQuantizer", 4, kSampleRate);
    CHECK(harness.valid());
    harness.set("scale", 1.0f);  // major
    harness.set("root", 0.0f);   // C
    std::vector<float>& in = harness.input("in");
    in = {0.0f, 2.0f / 12.0f, 7.0f / 12.0f, 1.0f};
    harness.process();
    CHECK_NEAR(harness.output()[0], 0.0, 1e-6);
    CHECK_NEAR(harness.output()[1], 2.0 / 12.0, 1e-6);
    CHECK_NEAR(harness.output()[2], 7.0 / 12.0, 1e-6);
    CHECK_NEAR(harness.output()[3], 1.0, 1e-6);
}

TEST(scale_quantizer_snaps_between_notes_and_resolves_ties_downward) {
    NodeHarness harness("ScaleQuantizer", 3, kSampleRate);
    harness.set("scale", 1.0f);  // major, root C
    std::vector<float>& in = harness.input("in");
    // C# sits exactly between C and D; F# exactly between F and G. Both resolve down.
    // 4.4 semitones is simply nearest to E.
    in = {1.0f / 12.0f, 6.0f / 12.0f, 4.4f / 12.0f};
    harness.process();
    CHECK_NEAR(harness.output()[0], 0.0, 1e-6);
    CHECK_NEAR(harness.output()[1], 5.0 / 12.0, 1e-6);
    CHECK_NEAR(harness.output()[2], 4.0 / 12.0, 1e-6);
}

TEST(scale_quantizer_respects_the_root) {
    NodeHarness harness("ScaleQuantizer", 2, kSampleRate);
    harness.set("scale", 2.0f);  // natural minor
    harness.set("root", 9.0f);   // A: A minor is the white keys
    std::vector<float>& in = harness.input("in");
    // A# is a semitone off either way from A and B; the tie resolves down to A.
    in = {10.0f / 12.0f, 9.0f / 12.0f};
    harness.process();
    CHECK_NEAR(harness.output()[0], 9.0 / 12.0, 1e-6);
    CHECK_NEAR(harness.output()[1], 9.0 / 12.0, 1e-6);
}

TEST(scale_quantizer_wraps_across_the_octave) {
    NodeHarness harness("ScaleQuantizer", 2, kSampleRate);
    harness.set("scale", 1.0f);  // major, root C
    std::vector<float>& in = harness.input("in");
    // Just below C snaps to the B beneath it; just below the octave snaps up to it.
    in = {-0.6f / 12.0f, 11.6f / 12.0f};
    harness.process();
    CHECK_NEAR(harness.output()[0], -1.0 / 12.0, 1e-6);
    CHECK_NEAR(harness.output()[1], 1.0, 1e-6);
}

namespace {
// The Speech node's buffer format, written the way tools/lpc-encode.mjs writes it:
// one byte per pcm16 sample, bits LSB-first. Mid-table reflection coefficients make
// a stable, unremarkable mouth — the tests are about the machinery, not the accent.
struct SpeechStream {
    std::vector<float> samples;
    int bit = 0;
    void put(int value, int count) {
        for (int b = 0; b < count; ++b) {
            if (bit % 8 == 0) {
                samples.push_back(0.0f);
            }
            int byte = static_cast<int>(std::lround(samples.back() * 32768.0));
            byte |= ((value >> b) & 1) << (bit % 8);
            samples.back() = static_cast<float>(byte) / 32768.0f;
            ++bit;
        }
    }
    void voiced_frame(int energy, int pitch_index) {
        put(energy, 4);
        put(0, 1);
        put(pitch_index, 6);
        const int k_index[10] = {16, 16, 8, 8, 8, 8, 8, 4, 4, 4};
        const int k_bits[10] = {5, 5, 4, 4, 4, 4, 4, 3, 3, 3};
        for (int i = 0; i < 10; ++i) {
            put(k_index[i], k_bits[i]);
        }
    }
    void silent_frame() { put(0, 4); }
    void stop() { put(15, 4); }
};
}  // namespace

TEST(speech_speaks_its_bitstream_and_stops) {
    SpeechStream phrase;
    for (int i = 0; i < 8; ++i) {
        phrase.voiced_frame(12, 20);
    }
    phrase.stop();
    NodeHarness harness("Speech", 48000, kSampleRate);
    CHECK(harness.valid());
    harness.bind_buffer(phrase.samples);
    harness.connect("trigger", 1.0f);
    harness.process();
    double early = 0.0;
    for (int i = 0; i < 9600; ++i) {
        early += harness.output()[i] * harness.output()[i];
    }
    CHECK(std::sqrt(early / 9600.0) > 0.001);   // eight frames of voice, audible
    double late = 0.0;
    for (int i = 38000; i < 48000; ++i) {
        late += harness.output()[i] * harness.output()[i];
    }
    CHECK(std::sqrt(late / 10000.0) < 0.0005);  // the stop frame stops
    for (int i = 0; i < 48000; ++i) {
        CHECK(std::isfinite(harness.output()[i]));
        CHECK(std::fabs(harness.output()[i]) < 2.0f);
    }
}

TEST(speech_silent_frames_say_nothing) {
    SpeechStream phrase;
    for (int i = 0; i < 4; ++i) {
        phrase.silent_frame();
    }
    phrase.stop();
    NodeHarness harness("Speech", 24000, kSampleRate);
    harness.bind_buffer(phrase.samples);
    harness.connect("trigger", 1.0f);
    harness.process();
    for (int i = 0; i < 24000; ++i) {
        CHECK(std::fabs(harness.output()[i]) < 0.001f);
    }
}

TEST(speech_without_a_buffer_is_silent_not_broken) {
    NodeHarness harness("Speech", 4800, kSampleRate);
    CHECK(harness.valid());
    harness.connect("trigger", 1.0f);
    harness.process();
    for (float sample : harness.output()) {
        CHECK(sample == 0.0f);
    }
}

TEST(sampler_without_a_buffer_is_silent_not_broken) {
    // The harness prepares nodes with no buffer bound, which is exactly the state of
    // a Sampler dropped into a patch before anyone gives it audio: silent, gate and
    // all, and never a crash. Playback with real audio is proven at the graph level
    // in test_patch_io, where a buffer can actually arrive.
    NodeHarness harness("Sampler", 64, kSampleRate);
    CHECK(harness.valid());
    harness.connect("gate", 1.0f);
    harness.process();
    bool silent = true;
    for (float sample : harness.output()) {
        silent = silent && sample == 0.0f;
    }
    CHECK(silent);
}

TEST(compressor_holds_loud_signals_down_by_its_ratio) {
    const int frames = 48000;
    NodeHarness harness("Compressor", frames, kSampleRate);
    CHECK(harness.valid());
    harness.set("threshold", 0.2f);
    harness.set("ratio", 4.0f);
    harness.set("attack", 0.001f);
    harness.set("release", 0.05f);
    harness.connect("in", 0.8f);
    harness.process();
    // 0.8 is 4x over the 0.2 threshold; at ratio 4 the output rises to only
    // 4^(1/4) over it: 0.2 * 4^0.25 = 0.283.
    CHECK_NEAR(harness.output()[frames - 1], 0.2 * std::pow(4.0, 0.25), 0.005);
}

TEST(compressor_leaves_quiet_signals_alone) {
    const int frames = 4800;
    NodeHarness harness("Compressor", frames, kSampleRate);
    harness.set("threshold", 0.2f);
    harness.set("ratio", 4.0f);
    harness.connect("in", 0.1f);
    harness.process();
    CHECK_NEAR(harness.output()[frames - 1], 0.1, 1e-4);
}

TEST(compressor_ducks_to_the_sidechain) {
    const int frames = 48000;
    NodeHarness harness("Compressor", frames, kSampleRate);
    harness.set("threshold", 0.2f);
    harness.set("ratio", 4.0f);
    harness.set("attack", 0.001f);
    // 0.3 through the body is under the threshold and would pass untouched — but the
    // sidechain is loud, and the detector listens there instead.
    harness.connect("in", 0.3f);
    harness.connect("sidechain", 0.9f);
    harness.process();
    const double expected = 0.3 * std::pow(0.9 / 0.2, 1.0 / 4.0 - 1.0);
    CHECK_NEAR(harness.output()[frames - 1], expected, 0.005);
    CHECK(harness.output()[frames - 1] < 0.15);
}

TEST(comb_echoes_at_its_period_and_decays_by_its_feedback) {
    const int frames = 2000;
    NodeHarness harness("Comb", frames, kSampleRate);
    CHECK(harness.valid());
    harness.set("time", 480.0f / kSampleRate);
    harness.set("feedback", 0.5f);
    harness.set("damp", 0.0f);
    std::vector<float>& in = harness.input("in");
    in[0] = 1.0f;
    harness.process();
    CHECK_NEAR(harness.output()[480], 1.0, 1e-6);
    CHECK_NEAR(harness.output()[960], 0.5, 1e-6);
    CHECK_NEAR(harness.output()[1440], 0.25, 1e-6);
    CHECK_NEAR(harness.output()[479], 0.0, 1e-6);
}

TEST(comb_frequency_input_tunes_the_loop_to_a_period) {
    const int frames = 2000;
    NodeHarness harness("Comb", frames, kSampleRate);
    harness.set("time", 0.09f);  // would be 4320 samples; the input overrides it
    harness.set("feedback", 0.5f);
    harness.set("damp", 0.0f);
    harness.connect("frequency", 1000.0f);  // one period = 48 samples at 48k
    std::vector<float>& in = harness.input("in");
    in[0] = 1.0f;
    harness.process();
    CHECK_NEAR(harness.output()[48], 1.0, 1e-6);
    CHECK_NEAR(harness.output()[96], 0.5, 1e-6);
    CHECK_NEAR(harness.output()[47], 0.0, 1e-6);
}

TEST(comb_damp_darkens_each_pass) {
    const int frames = 1000;
    NodeHarness harness("Comb", frames, kSampleRate);
    harness.set("time", 480.0f / kSampleRate);
    harness.set("feedback", 0.5f);
    harness.set("damp", 0.5f);
    std::vector<float>& in = harness.input("in");
    in[0] = 1.0f;
    harness.process();
    // The first return is untouched; the recirculated copy has been through the
    // loop's lowpass once, so it comes back at half the undamped level.
    CHECK_NEAR(harness.output()[480], 1.0, 1e-6);
    CHECK_NEAR(harness.output()[960], 0.25, 1e-6);
}

TEST(allpass_smears_time_but_keeps_all_the_energy) {
    const int frames = 48000;
    NodeHarness harness("Allpass", frames, kSampleRate);
    CHECK(harness.valid());
    harness.set("time", 0.005f);
    harness.set("gain", 0.5f);
    std::vector<float>& in = harness.input("in");
    in[0] = 1.0f;
    harness.process();
    // An impulse comes out scattered across many echoes — but a true allpass has a
    // flat magnitude response, so the impulse response carries exactly unit energy.
    double energy = 0.0;
    for (float sample : harness.output()) {
        energy += static_cast<double>(sample) * sample;
    }
    CHECK_NEAR(energy, 1.0, 1e-3);
    CHECK_NEAR(harness.output()[0], -0.5, 1e-6);  // the direct -g path
}

TEST(crush_quantises_and_holds) {
    const int frames = 40;
    NodeHarness harness("Crush", frames, kSampleRate);
    CHECK(harness.valid());
    harness.set("bits", 2.0f);   // levels at halves: -1, -0.5, 0, 0.5, 1
    harness.set("rate", kSampleRate / 10.0f);
    std::vector<float>& in = harness.input("in");
    for (int i = 0; i < frames; ++i) {
        in[static_cast<std::size_t>(i)] = 0.6f;
    }
    harness.process();
    // 0.6 lands on the 0.5 step, and each captured value holds for ten samples.
    CHECK_NEAR(harness.output()[0], 0.5, 1e-6);
    CHECK_NEAR(harness.output()[9], 0.5, 1e-6);
    int changes = 0;
    for (int i = 1; i < frames; ++i) {
        changes += harness.output()[i] != harness.output()[i - 1] ? 1 : 0;
    }
    CHECK(changes == 0);  // a constant input crushes to a constant output
}

TEST(step_sequencer_advances_on_clock_edges_and_wraps) {
    NodeHarness harness("StepSequencer", 8, kSampleRate);
    CHECK(harness.valid());
    harness.set("length", 3.0f);
    harness.set("step1", 0.1f);
    harness.set("step2", 0.2f);
    harness.set("step3", 0.3f);
    std::vector<float>& clock = harness.input("clock");
    // A pulse every second sample: edges at 0, 2, 4, 6.
    clock = {1.0f, 0.0f, 1.0f, 0.0f, 1.0f, 0.0f, 1.0f, 0.0f};
    harness.process();
    // The edge and the new value share a sample, and the fourth edge wraps.
    CHECK_NEAR(harness.output()[0], 0.1, 1e-6);
    CHECK_NEAR(harness.output()[2], 0.2, 1e-6);
    CHECK_NEAR(harness.output()[4], 0.3, 1e-6);
    CHECK_NEAR(harness.output()[6], 0.1, 1e-6);
    // Between edges the value holds.
    CHECK_NEAR(harness.output()[3], 0.2, 1e-6);
}

TEST(step_sequencer_first_edge_lands_on_step_one) {
    NodeHarness harness("StepSequencer", 4, kSampleRate);
    harness.set("step1", 0.7f);
    harness.set("step2", -0.7f);
    std::vector<float>& clock = harness.input("clock");
    clock = {0.0f, 0.0f, 1.0f, 1.0f};
    harness.process();
    // Before any edge the lane already shows step 1; the edge enters it, and a held
    // gate does not advance further.
    CHECK_NEAR(harness.output()[0], 0.7, 1e-6);
    CHECK_NEAR(harness.output()[2], 0.7, 1e-6);
    CHECK_NEAR(harness.output()[3], 0.7, 1e-6);
}

TEST(step_sequencer_reset_returns_to_step_one) {
    NodeHarness harness("StepSequencer", 8, kSampleRate);
    harness.set("length", 4.0f);
    harness.set("step1", 0.1f);
    harness.set("step2", 0.2f);
    harness.set("step3", 0.3f);
    std::vector<float>& clock = harness.input("clock");
    clock = {1.0f, 0.0f, 1.0f, 0.0f, 1.0f, 0.0f, 1.0f, 0.0f};
    std::vector<float>& reset = harness.input("reset");
    // Reset fires with the third clock edge: that edge is step 1 again, not step 3.
    reset = {0.0f, 0.0f, 0.0f, 0.0f, 1.0f, 0.0f, 0.0f, 0.0f};
    harness.process();
    CHECK_NEAR(harness.output()[2], 0.2, 1e-6);
    CHECK_NEAR(harness.output()[4], 0.1, 1e-6);
    CHECK_NEAR(harness.output()[6], 0.2, 1e-6);
}

TEST(euclid_three_in_eight_is_the_tresillo) {
    const int frames = 16;
    NodeHarness harness("Euclid", frames, kSampleRate);
    CHECK(harness.valid());
    harness.set("steps", 8.0f);
    harness.set("fill", 3.0f);
    std::vector<float>& clock = harness.input("clock");
    for (int i = 0; i < frames; i += 2) {
        clock[static_cast<std::size_t>(i)] = 1.0f;  // eight pulses, one per two samples
    }
    harness.process();
    // ((step * 3) mod 8) < 3 puts the hits on 1, 4 and 7 of the eight: x..x..x.
    const std::vector<float>& gate = harness.output("gate");
    const std::vector<float>& rest = harness.output("rest");
    bool pattern_ok = true;
    for (int step = 0; step < 8; ++step) {
        const bool expected = step == 0 || step == 3 || step == 6;
        pattern_ok = pattern_ok && (gate[static_cast<std::size_t>(step * 2)] >= 0.5f) == expected;
        // The rest output is the exact complement, on the pulses.
        pattern_ok = pattern_ok && (rest[static_cast<std::size_t>(step * 2)] >= 0.5f) == !expected;
    }
    CHECK(pattern_ok);
    // Between pulses both outputs are low: the clock's width is the pulse width.
    CHECK(gate[1] < 0.5f);
    CHECK(rest[1] < 0.5f);
}

TEST(euclid_fill_bounds_are_silence_and_every_step) {
    NodeHarness none("Euclid", 8, kSampleRate);
    none.set("steps", 4.0f);
    none.set("fill", 0.0f);
    std::vector<float>& clock_none = none.input("clock");
    for (int i = 0; i < 8; i += 2) clock_none[static_cast<std::size_t>(i)] = 1.0f;
    none.process();
    bool silent = true;
    for (float sample : none.output("gate")) silent = silent && sample < 0.5f;
    CHECK(silent);

    NodeHarness all("Euclid", 8, kSampleRate);
    all.set("steps", 4.0f);
    all.set("fill", 16.0f);  // clamps to steps
    std::vector<float>& clock_all = all.input("clock");
    for (int i = 0; i < 8; i += 2) clock_all[static_cast<std::size_t>(i)] = 1.0f;
    all.process();
    bool every = true;
    for (int i = 0; i < 8; i += 2) every = every && all.output("gate")[static_cast<std::size_t>(i)] >= 0.5f;
    CHECK(every);
}

TEST(euclid_rotate_moves_the_downbeat) {
    const int frames = 16;
    NodeHarness harness("Euclid", frames, kSampleRate);
    harness.set("steps", 8.0f);
    harness.set("fill", 3.0f);
    harness.set("rotate", 1.0f);
    std::vector<float>& clock = harness.input("clock");
    for (int i = 0; i < frames; i += 2) clock[static_cast<std::size_t>(i)] = 1.0f;
    harness.process();
    // Rotated by one, the hits sit where steps 1, 4 and 7 of the unrotated necklace
    // were: steps 2, 5 and 7 of the pattern as played.
    const std::vector<float>& gate = harness.output("gate");
    bool pattern_ok = true;
    for (int step = 0; step < 8; ++step) {
        const bool expected = ((step + 1) * 3) % 8 < 3;
        pattern_ok = pattern_ok && (gate[static_cast<std::size_t>(step * 2)] >= 0.5f) == expected;
    }
    CHECK(pattern_ok);
}

TEST(retrigger_restarts_an_envelope_it_is_wired_to) {
    // The two nodes together are what "stutter" means; neither says it alone.
    NodeHarness retrigger("Retrigger", kOneSecond, kSampleRate);
    retrigger.set("rate", 5.0f);
    retrigger.process();

    NodeHarness envelope("AhdEnvelope", kOneSecond, kSampleRate);
    envelope.set("attack", 0.0f);
    envelope.set("hold", 0.0f);
    envelope.set("decay", 0.1f);
    envelope.input("gate") = retrigger.output();
    envelope.process();

    int restarts = 0;
    bool low = true;
    for (float sample : envelope.output()) {
        if (sample > 0.95f && low) {
            ++restarts;
            low = false;
        } else if (sample < 0.5f) {
            low = true;
        }
    }
    CHECK(restarts == 5);
}

TEST(phaser_doubles_a_signal_at_zero_delay_and_cancels_it_at_half_a_cycle) {
    // At zero offset the delayed copy is the signal itself, so the output is exactly
    // double. That is the check that the line is read where it is written.
    NodeHarness flat("Phaser", 4800, kSampleRate);
    CHECK(flat.valid());
    flat.set("offset", 0.0f);
    flat.set("sweep", 0.0f);
    std::vector<float>& in = flat.input("in");
    for (std::size_t i = 0; i < in.size(); ++i) {
        in[i] = std::sin(6.2831853f * 1000.0f * static_cast<float>(i) / 48000.0f);
    }
    flat.process();
    CHECK_NEAR(testing::peak(flat.output()), 2.0, 0.01);

    // Half a cycle of delay at 1 kHz is 0.5 ms, where the delayed copy cancels the dry.
    NodeHarness notched("Phaser", 4800, kSampleRate);
    notched.set("offset", 0.5f);
    notched.set("sweep", 0.0f);
    std::vector<float>& in2 = notched.input("in");
    for (std::size_t i = 0; i < in2.size(); ++i) {
        in2[i] = std::sin(6.2831853f * 1000.0f * static_cast<float>(i) / 48000.0f);
    }
    notched.process();

    const std::vector<float>& settled = notched.output();
    float late_peak = 0.0f;
    for (std::size_t i = 1000; i < settled.size(); ++i) {
        late_peak = std::max(late_peak, std::fabs(settled[i]));
    }
    CHECK(late_peak < 0.02f);
}

TEST(square_pulse_width_sweep_moves_the_duty_and_zero_leaves_it_alone) {
    // The default of zero has to render exactly as it did before the sweep existed, or
    // every patch already written changes sound. The golden vectors check that; this says
    // why it matters.
    NodeHarness still("SquareOscillator", 4800, kSampleRate);
    still.set("frequency", 100.0f);
    still.set("pulse_width", 0.5f);
    still.set("pulse_width_sweep", 0.0f);
    still.process();
    CHECK_NEAR(testing::mean(still.output()), 0.0, 0.02);

    // Sweeping towards a narrow pulse pushes the mean negative: the wave spends most of
    // each cycle low.
    NodeHarness swept("SquareOscillator", kOneSecond, kSampleRate);
    swept.set("frequency", 100.0f);
    swept.set("pulse_width", 0.5f);
    swept.set("pulse_width_sweep", -0.45f);
    swept.process();
    CHECK(testing::mean(swept.output()) < -0.2);
}

TEST(filter_cutoff_sweep_closes_the_filter_over_time) {
    // Driven in kBlockSize chunks, which is how a graph drives it: graph.cpp calls every
    // node with exactly kBlockSize frames, behind the output FIFO. The cutoff advances
    // once per block, so a single enormous block would never sweep at all — the rate is
    // right for any block size, but the granularity is the block.
    const int block = soundgraph::kBlockSize;
    NodeHarness harness("StateVariableFilter", block, kSampleRate);
    CHECK(harness.valid());
    harness.set("cutoff", 8000.0f);
    harness.set("mode", 0.0f);           // lowpass
    harness.set("cutoff_sweep", -6.0f);  // six octaves down per second

    std::vector<float> rendered;
    rendered.reserve(static_cast<std::size_t>(kOneSecond));
    std::vector<float>& in = harness.input("in");
    for (int start = 0; start + block <= kOneSecond; start += block) {
        for (int i = 0; i < block; ++i) {
            in[static_cast<std::size_t>(i)] =
                std::sin(6.2831853f * 4000.0f * static_cast<float>(start + i) / 48000.0f);
        }
        harness.process(block);
        for (int i = 0; i < block; ++i) {
            rendered.push_back(harness.output()[static_cast<std::size_t>(i)]);
        }
    }

    // A 4 kHz tone passes while the cutoff is above it, and is gone once the sweep has
    // taken the cutoff five octaves below it.
    float early = 0.0f;
    for (std::size_t i = 0; i < 2000; ++i) early = std::max(early, std::fabs(rendered[i]));
    float late = 0.0f;
    for (std::size_t i = rendered.size() - 2000; i < rendered.size(); ++i) {
        late = std::max(late, std::fabs(rendered[i]));
    }
    CHECK(early > 0.3f);
    CHECK(late < early * 0.1f);
}

TEST(every_registered_type_can_be_created_with_working_defaults) {
    const soundgraph::NodeRegistry& registry = soundgraph::NodeRegistry::builtin();
    CHECK(registry.types().size() >= 23);

    for (const soundgraph::NodeTypeDescriptor* type : registry.types()) {
        NodeHarness harness(type->name, 128, kSampleRate, testing::Coverage::SmokeTest);
        CHECK_MESSAGE(harness.valid(), std::string("could not create ") + type->name);
        harness.process();

        for (int i = 0; i < type->outputs.size(); ++i) {
            for (float sample : harness.output(i)) {
                CHECK_MESSAGE(std::isfinite(sample),
                              std::string(type->name) + " produced a non-finite sample at defaults");
                break;
            }
        }
    }
}

// Not a TEST, because it can only be asked once every test has run and TEST order is
// declaration order — a check that depends on being last is a check that breaks when
// somebody appends a case below it.
static int report_jig_coverage() {
    std::vector<std::string> exercised = testing::exercised_types();
    std::sort(exercised.begin(), exercised.end());
    exercised.erase(std::unique(exercised.begin(), exercised.end()), exercised.end());

    std::vector<std::string> missing;
    for (const soundgraph::NodeTypeDescriptor* type : soundgraph::NodeRegistry::builtin().types()) {
        if (!std::binary_search(exercised.begin(), exercised.end(), type->name)) {
            missing.push_back(type->name);
        }
    }

    if (missing.empty()) {
        std::printf("node jigs: all %zu registered types are exercised\n", exercised.size());
        return 0;
    }
    std::printf("node jigs: %zu registered type(s) have no jig:\n", missing.size());
    for (const std::string& name : missing) {
        std::printf("  %s\n", name.c_str());
    }
    std::printf("  Add one to test_nodes.cpp. A node nobody drives is a node nobody knows\n"
                "  the behaviour of, and the smoke test only proves it starts.\n");
    return 1;
}

int main() {
    const int failures = testing::run_all("node tests");
    return report_jig_coverage() != 0 ? 1 : failures;
}
