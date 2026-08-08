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
    CHECK(registry.types().size() >= 22);

    for (const soundgraph::NodeTypeDescriptor* type : registry.types()) {
        NodeHarness harness(type->name, 128, kSampleRate);
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

TEST_MAIN("node tests")
