// SoundGraph — generic ESP32-S3 firmware.
//
// The same dsp-core that runs natively, in the browser and inside Godot, pointed at an
// I2S peripheral. There is no embedded-special DSP: this file is a host, exactly like
// sg-play and the AudioWorklet are hosts.
//
//   boot -> load patch (NVS if one was deployed, else the embedded demo) -> play
//
// A serial console (the USB/UART monitor) drives it:
//
//   note <n> [vel]      play MIDI note n
//   off <n>             release it
//   panic               all notes off
//   arp on|off          the built-in arpeggiator (off at boot; the board is quiet
//                       until asked, so it can sit on a stand all day)
//   arp 45,52,57,60     set the arpeggio pattern (MIDI notes) and start it
//   bpm <n>             arpeggio tempo
//   vol <0-100>         codec output volume, on boards that have one
//   set <node> <param> <value>
//   info                what is loaded, execution order, memory
//   load <bytes>        <bytes> of patch JSON follow; stored to NVS and made live
//   unload              forget the deployed patch, back to the embedded demo
//   render <name> <frames> [note_on:frame:note:vel|note_off:frame:note ...]
//                       offline-render an embedded patch, streaming base64 float32
//                       mono — the host-side golden verifier drives this
//
// The audio task owns the live graph pointer; deploys swap it atomically and the old
// graph is freed after the audio task has certainly moved on.
#include <atomic>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "driver/i2s_std.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "nvs.h"
#include "nvs_flash.h"
#include "sdkconfig.h"

#if CONFIG_ESP_CONSOLE_USB_SERIAL_JTAG
#include "driver/usb_serial_jtag.h"
#include "driver/usb_serial_jtag_vfs.h"
#endif

#include "board_config.h"
#include "codec_init.h"
#include "display.h"
#include "speech.h"
#include "touch.h"
#include "soundgraph/patch_io.h"
#include "soundgraph/soundgraph.h"

namespace {

const char* const TAG = "soundgraph";

constexpr int kBlock = soundgraph::kBlockSize;
constexpr char kNvsNamespace[] = "soundgraph";
constexpr char kNvsPatchKey[] = "patch";

// ---------------------------------------------------------------------------------
// Embedded patches
// ---------------------------------------------------------------------------------

// The embedded patch table is generated from tests/golden/cases.json at build time; see
// main/CMakeLists.txt. It was written by hand until eight golden cases were added and the
// device reported "no embedded patch named 'slide'" for every one of them — which sounds
// like a device fault and was a stale list.
#include "embedded_patches.h"

const char* find_embedded_patch(const std::string& name) {
    for (const EmbeddedPatch& patch : kEmbeddedPatches) {
        if (name == patch.name) {
            return patch.text;
        }
    }
    return nullptr;
}

// ---------------------------------------------------------------------------------
// The arpeggiator — same shape as sg-play's, running inside the audio task so the
// control queue keeps its single producer (the console task).
// ---------------------------------------------------------------------------------

class Sequencer {
public:
    static constexpr int kMaxPattern = 32;

    void configure(double sample_rate) {
        sample_rate_ = sample_rate;
        set_bpm(110.0);
        // The default pattern: a two-octave up-and-down A minor arpeggio — enough
        // movement to show off the filter sweep without turning into a melody.
        const int pattern[] = {45, 52, 57, 60, 64, 60, 57, 52};
        set_pattern(pattern, 8);
    }

    void set_bpm(double bpm) {
        if (bpm < 20.0) bpm = 20.0;
        if (bpm > 480.0) bpm = 480.0;
        samples_per_step_.store(static_cast<long long>(sample_rate_ * 60.0 / bpm),
                                std::memory_order_relaxed);
    }

    // Called from the console task while the audio task is reading. Writes the notes
    // first and the count last; the audio thread might play one stale note during the
    // change, which for a dev console beats a lock in the audio path.
    void set_pattern(const int* notes, int count) {
        if (count > kMaxPattern) count = kMaxPattern;
        for (int i = 0; i < count; ++i) {
            pattern_[i] = notes[i];
        }
        pattern_length_.store(count, std::memory_order_release);
    }

    void set_running(bool running) { running_.store(running, std::memory_order_relaxed); }
    bool running() const { return running_.load(std::memory_order_relaxed); }

    void advance(soundgraph::Graph& graph, int frames) {
        if (!running()) {
            if (sounding_ >= 0) {
                send(graph, soundgraph::NoteEvent::Kind::NoteOff, sounding_);
                sounding_ = -1;
            }
            return;
        }
        const long long samples_per_step = samples_per_step_.load(std::memory_order_relaxed);
        const long long gate_samples = samples_per_step * 3 / 4;
        const int length = pattern_length_.load(std::memory_order_acquire);
        if (length <= 0) {
            return;
        }

        for (int i = 0; i < frames; ++i) {
            if (position_ == 0) {
                if (sounding_ >= 0) {
                    send(graph, soundgraph::NoteEvent::Kind::NoteOff, sounding_);
                }
                sounding_ = pattern_[step_ % length];
                send(graph, soundgraph::NoteEvent::Kind::NoteOn, sounding_);
            } else if (position_ == gate_samples && sounding_ >= 0) {
                send(graph, soundgraph::NoteEvent::Kind::NoteOff, sounding_);
                sounding_ = -1;
            }
            if (++position_ >= samples_per_step) {
                position_ = 0;
                step_ = (step_ + 1) % length;
            }
        }
    }

private:
    static void send(soundgraph::Graph& graph, soundgraph::NoteEvent::Kind kind, int note) {
        soundgraph::NoteEvent event;
        event.kind = kind;
        event.note = note;
        event.velocity = 0.9f;
        graph.dispatch_note(event);
    }

    double sample_rate_ = 48000.0;
    int pattern_[kMaxPattern] = {};
    std::atomic<int> pattern_length_{0};
    std::atomic<long long> samples_per_step_{1};
    long long position_ = 0;
    int step_ = 0;
    int sounding_ = -1;
    // Silent at boot. The board previously started its arpeggiator the moment it had
    // power, on the reasoning that a fresh board should prove itself immediately — which
    // is right for a bench and wrong for a stand, where it means a device droning at
    // everyone for eight hours. `arp on` starts it, and a deploy from the editor is the
    // interesting way to make it speak anyway.
    std::atomic<bool> running_{false};
};

// ---------------------------------------------------------------------------------
// Shared state
// ---------------------------------------------------------------------------------

std::atomic<soundgraph::Graph*> g_live_graph{nullptr};
Sequencer g_sequencer;
i2s_chan_handle_t g_tx_channel = nullptr;
// Mother's own graph: the yes-dear patch, built once at boot and left standing. It is a
// SoundGraph patch like any other — a Speech node with 194 bytes of LPC in it — which is
// the point. The board answers in its own voice rather than in a text-to-speech engine's.
soundgraph::Graph* g_reply = nullptr;
// Frames of reply left to render. Nonzero means she is talking; the music ducks for
// exactly as long as that lasts. Written by the console and speech tasks, read by the
// audio task, which is why it is atomic and why nothing else about her is.
std::atomic<int> g_reply_frames{0};

// How far the music drops while she speaks, and how long her line takes. A duck rather
// than a mute: a parent talking over the radio does not switch the radio off.
constexpr float kDuck = 0.18f;
constexpr int kReplyFrames = SG_AUDIO_SAMPLE_RATE * 3 / 2;  // a second and a half

// Output volume as last set, so a relative change has something to be relative to.
// codec_init starts the codec at 55.
float g_volume = 55.0f;
i2s_chan_handle_t g_rx_channel = nullptr;

// ---------------------------------------------------------------------------------
// Audio
// ---------------------------------------------------------------------------------

void audio_task(void*) {
    float left[kBlock];
    float right[kBlock];
    int16_t interleaved[kBlock * 2];

    for (;;) {
        soundgraph::Graph* graph = g_live_graph.load(std::memory_order_acquire);
        if (graph == nullptr) {
            vTaskDelay(pdMS_TO_TICKS(10));
            continue;
        }

        g_sequencer.advance(*graph, kBlock);
        graph->render(left, right, kBlock);

        // Her reply, over the top, with the music pulled down under it. Both graphs are
        // rendered by this one task, so there is no second audio thread and nothing to
        // synchronise beyond the frame counter.
        int replying = g_reply_frames.load(std::memory_order_acquire);
        if (replying > 0 && g_reply != nullptr) {
            float reply_left[kBlock];
            float reply_right[kBlock];
            g_reply->render(reply_left, reply_right, kBlock);
            for (int i = 0; i < kBlock; ++i) {
                left[i] = left[i] * kDuck + reply_left[i];
                right[i] = right[i] * kDuck + reply_right[i];
            }
            replying -= kBlock;
            g_reply_frames.store(replying > 0 ? replying : 0, std::memory_order_release);
        }

        for (int i = 0; i < kBlock; ++i) {
            float l = left[i];
            float r = right[i];
            l = l > 1.0f ? 1.0f : (l < -1.0f ? -1.0f : l);
            r = r > 1.0f ? 1.0f : (r < -1.0f ? -1.0f : r);
            interleaved[i * 2] = static_cast<int16_t>(l * 32767.0f);
            interleaved[i * 2 + 1] = static_cast<int16_t>(r * 32767.0f);
        }

        // The reference for the echo canceller, taken here because here is where the
        // samples are known: this is exactly what the amplifier is about to play, and
        // therefore exactly what the microphone is about to hear.
        speech_push_playback(interleaved, kBlock);

        std::size_t written = 0;
        // Blocking write: the DMA queue's backpressure is the timing of this loop.
        i2s_channel_write(g_tx_channel, interleaved, sizeof(interleaved), &written, portMAX_DELAY);
    }
}

bool start_i2s() {
    i2s_chan_config_t channel_config = I2S_CHANNEL_DEFAULT_CONFIG(I2S_NUM_AUTO, I2S_ROLE_MASTER);

    // Both directions from one call, when the board has a microphone. That is what makes
    // them share a port and therefore a clock domain, which is what the board wires: one
    // bclk, one ws, one mclk, two data lines. Asking for the receive channel separately
    // would want a second port, and the second port would find the pins taken.
    i2s_chan_handle_t* receive = SG_AUDIO_IN_PRESENT ? &g_rx_channel : nullptr;
    if (i2s_new_channel(&channel_config, &g_tx_channel, receive) != ESP_OK) {
        ESP_LOGE(TAG, "could not create the I2S channel");
        return false;
    }

    i2s_std_config_t std_config = {
        .clk_cfg = I2S_STD_CLK_DEFAULT_CONFIG(SG_AUDIO_SAMPLE_RATE),
        .slot_cfg = I2S_STD_PHILIPS_SLOT_DEFAULT_CONFIG(I2S_DATA_BIT_WIDTH_16BIT,
                                                        I2S_SLOT_MODE_STEREO),
        .gpio_cfg = {
            .mclk = SG_I2S_MCLK >= 0 ? static_cast<gpio_num_t>(SG_I2S_MCLK) : I2S_GPIO_UNUSED,
            .bclk = static_cast<gpio_num_t>(SG_I2S_BCLK),
            .ws = static_cast<gpio_num_t>(SG_I2S_WS),
            .dout = static_cast<gpio_num_t>(SG_I2S_DOUT),
            .din = SG_AUDIO_IN_PRESENT ? static_cast<gpio_num_t>(SG_I2S_DIN)
                                       : I2S_GPIO_UNUSED,
            .invert_flags = {.mclk_inv = false, .bclk_inv = false, .ws_inv = false},
        },
    };

    if (i2s_channel_init_std_mode(g_tx_channel, &std_config) != ESP_OK ||
        i2s_channel_enable(g_tx_channel) != ESP_OK) {
        ESP_LOGE(TAG, "could not start I2S on bclk=%d ws=%d dout=%d",
                 SG_I2S_BCLK, SG_I2S_WS, SG_I2S_DOUT);
        return false;
    }

    // The receive side is not fatal. A board whose microphone refuses still plays, and a
    // silent capture path is a much smaller loss than a silent speaker — so this is
    // logged and stepped over rather than returned as a startup failure.
    if (g_rx_channel != nullptr) {
        if (i2s_channel_init_std_mode(g_rx_channel, &std_config) != ESP_OK ||
            i2s_channel_enable(g_rx_channel) != ESP_OK) {
            ESP_LOGE(TAG, "could not start I2S capture on din=%d", SG_I2S_DIN);
            g_rx_channel = nullptr;
        }
    }
    return true;
}

// ---------------------------------------------------------------------------------
// Patch loading
// ---------------------------------------------------------------------------------

// What the patch says its knobs are. The screen renders this rather than a copy kept
// in the firmware: the patch is the artifact, and a control surface invented here would
// be a second definition free to drift from it.
struct UiControl {
    std::string label;
    std::string node;
    std::string parameter;
    float min_value = 0.0f;
    float max_value = 1.0f;
    float value = 0.0f;
};
std::vector<UiControl> g_ui_controls;

soundgraph::Graph* build_graph(const char* patch_text, std::string& error_out) {
    soundgraph::GraphDescription description;
    std::vector<soundgraph::Diagnostic> diagnostics;

    if (!soundgraph::parse_patch(patch_text, description, diagnostics)) {
        error_out = soundgraph::write_diagnostics(diagnostics, false);
        return nullptr;
    }

    soundgraph::PrepareContext context;
    context.sample_rate = SG_AUDIO_SAMPLE_RATE;

    auto graph = std::make_unique<soundgraph::Graph>();
    if (!graph->build(description, soundgraph::NodeRegistry::builtin(), context, diagnostics)) {
        error_out = soundgraph::write_diagnostics(diagnostics, false);
        return nullptr;
    }

    g_ui_controls.clear();
    for (const soundgraph::ControlDescription& control : description.controls) {
        UiControl entry;
        entry.label = control.label.empty() ? control.id : control.label;
        entry.node = control.target.node;
        entry.parameter = control.target.parameter;
        entry.min_value = static_cast<float>(control.has_range ? control.min_value : 0.0);
        entry.max_value = static_cast<float>(control.has_range ? control.max_value : 1.0);
        entry.value = static_cast<float>(control.has_default ? control.default_value
                                                            : entry.min_value);
        g_ui_controls.push_back(entry);
    }
    return graph.release();
}

// ---------------------------------------------------------------------------------
// The face
// ---------------------------------------------------------------------------------
//
// Nine knobs in a three-by-three grid, drawn from whatever the patch declared. A knob
// is a ring with the used part of its travel filled and a pointer at the value: the
// same shape a panel knob has, for the same reason — the angle is readable at a glance
// from across a room, and a number is not.

// The house knob, as the rack and the plugin panel already draw it: 270 degrees of
// travel starting down-left, a dim track, the used part in the accent, a body with one
// pixel of highlight, and a pointer. Representational rather than skeuomorphic, and
// deliberately so on this hardware — an AMOLED spends power only on lit pixels, so a
// black ground is free and a broad grey bevel is not; at this size the angle carries
// the information that shading would only decorate; and a finger covers the body while
// it drags, which is exactly when a photoreal knob would have nothing left to say. The
// arc survives the fingertip because it lives outside it.
constexpr float kKnobStart = 135.0f;             // down-left, screen convention
constexpr float kKnobSweep = 270.0f;

// Palettes.
//
// The first cut used one accent for the arc, the pointer, the label and the readout,
// on nine knobs at once, and it read as garish for a reason worth writing down: neon
// is bright because it is *scarce*. Light every element and the eye has nowhere to
// rest, so nothing glows. What the cyberpunk look actually rests on is darkness with
// small areas of intense light, one dominant hue, and a hierarchy built from
// brightness rather than from more colours — a phosphor terminal is a single hue at
// several luminances.
//
// So in every theme below the accent is spent on one thing: the part of the arc that
// carries the value. The pointer is ink, because it is a piece of the knob rather than
// data. Labels are dim. The bloom under the arc is the one indulgence, and on an AMOLED
// against true black it is what a neon tube actually does to the air around it.
struct Theme {
    const char* name;
    uint32_t ground, body, body_lit, track, accent, ink, ink_dim;
};

const Theme kThemes[] = {
    // Phosphor: one hue, many luminances. The terminal that cyberpunk grew out of.
    {"phosphor", display_rgb(0, 0, 0),    display_rgb(16, 26, 20),
     display_rgb(24, 38, 30),  display_rgb(16, 62, 44),
     display_rgb(80, 255, 170), display_rgb(198, 255, 224), display_rgb(88, 128, 104)},
    // Amber on cool graphite: the Blade Runner pairing — warm light, cold room.
    {"amber",    display_rgb(0, 0, 0),    display_rgb(28, 27, 24),
     display_rgb(40, 38, 33),  display_rgb(64, 44, 14),
     display_rgb(255, 176, 60), display_rgb(255, 236, 206), display_rgb(138, 122, 98)},
    // Neon pair: cyan-lit bodies, magenta value. Complementary, so the value separates
    // without either colour having to shout.
    {"neon",     display_rgb(0, 0, 0),    display_rgb(16, 22, 34),
     display_rgb(24, 32, 48),  display_rgb(18, 58, 70),
     display_rgb(255, 64, 160), display_rgb(196, 240, 255), display_rgb(92, 124, 152)},
    // Ice: near-monochrome with a cold accent, for when the room is bright.
    {"ice",      display_rgb(0, 0, 0),    display_rgb(22, 25, 30),
     display_rgb(32, 36, 43),  display_rgb(28, 48, 60),
     display_rgb(96, 208, 255), display_rgb(228, 240, 250), display_rgb(112, 126, 144)},
};
constexpr int kThemeCount = sizeof(kThemes) / sizeof(kThemes[0]);
int g_theme = 0;

const Theme& theme() { return kThemes[g_theme]; }

uint32_t dimmed(uint32_t colour, int percent) { return display_dim(colour, percent); }

struct KnobHit { int cx = 0; int cy = 0; int radius = 0; };
std::vector<KnobHit> g_knob_hits;
int g_active_knob = -1;   // what a finger is holding, for the big readout

void format_value(char* out, std::size_t size, float value) {
    if (value >= 100.0f)     std::snprintf(out, size, "%d", static_cast<int>(value + 0.5f));
    else if (value >= 10.0f) std::snprintf(out, size, "%.1f", value);
    else                     std::snprintf(out, size, "%.2f", value);
}

void draw_knob(int cx, int cy, int radius, const UiControl& control, bool active) {
    const float span = control.max_value - control.min_value;
    float fraction = span > 0.0f ? (control.value - control.min_value) / span : 0.0f;
    if (fraction < 0.0f) fraction = 0.0f;
    if (fraction > 1.0f) fraction = 1.0f;
    const float angle = kKnobStart + kKnobSweep * fraction;

    const Theme& t = theme();
    const float track_radius = static_cast<float>(radius) + 6.0f;
    display_arc(cx, cy, track_radius, 3.0f, kKnobStart, kKnobStart + kKnobSweep, t.track);

    // The bloom: a wide, dim pass under the crisp one. Against unlit AMOLED pixels this
    // is what a tube does to the air around it, and it costs two arcs.
    display_arc(cx, cy, track_radius, 8.0f, kKnobStart, angle, dimmed(t.accent, 10));
    display_arc(cx, cy, track_radius, 5.0f, kKnobStart, angle, dimmed(t.accent, 26));
    display_arc(cx, cy, track_radius, 3.0f, kKnobStart, angle, t.accent);

    // Body, then the highlight a pixel above it. One pixel is the whole bevel: enough
    // to read as an object, not enough to cost a gradient.
    display_disc(cx, cy, static_cast<float>(radius), t.body);
    display_disc(cx, cy - 1, static_cast<float>(radius) - 4.0f, t.body_lit);

    // The pointer is ink, not accent: it is part of the knob, not part of the reading,
    // and giving it the accent too was half of what made the first cut shout.
    const float rad = angle * 3.14159265f / 180.0f;
    const float c = std::cos(rad), sn = std::sin(rad);
    display_line(cx + c * (radius * 0.34f), cy + sn * (radius * 0.34f),
                 cx + c * (radius - 3.0f), cy + sn * (radius - 3.0f),
                 2.5f, active ? t.ink : t.ink_dim);

    char label[14];
    std::snprintf(label, sizeof label, "%s", control.label.c_str());
    display_text(cx - display_text_width(label, 2) / 2, cy + radius + 10, label, 2,
                 active ? t.ink : t.ink_dim);
}

// ---------------------------------------------------------------------------------
// The swatch grid
// ---------------------------------------------------------------------------------
//
// Colour chosen by looking rather than by reasoning. Every cell draws the thing we are
// actually colouring — a stroke with its bloom, on black — because a colour judged as a
// filled square lies about how it will read as a thin bright line. Two axes per grid,
// labelled, so a verdict can be given as "column 3, row 2" and turned straight into a
// constant.

uint32_t from_hsv(float h, float s, float v) {
    h = std::fmod(h, 360.0f);
    if (h < 0.0f) h += 360.0f;
    const float c = v * s;
    const float x = c * (1.0f - std::fabs(std::fmod(h / 60.0f, 2.0f) - 1.0f));
    const float m = v - c;
    float r = 0, g = 0, b = 0;
    if (h < 60)       { r = c; g = x; }
    else if (h < 120) { r = x; g = c; }
    else if (h < 180) { g = c; b = x; }
    else if (h < 240) { g = x; b = c; }
    else if (h < 300) { r = x; b = c; }
    else              { r = c; b = x; }
    return display_rgb(static_cast<int>((r + m) * 255.0f),
                       static_cast<int>((g + m) * 255.0f),
                       static_cast<int>((b + m) * 255.0f));
}

void draw_swatch_grid(int mode) {
    if (!display_available()) return;
    const int w = display_width(), h = display_height();
    display_clear(display_rgb(0, 0, 0));

    constexpr int kCols = 7;
    constexpr int kRows = 6;
    const int left = 26, top = 46;
    const int cell_w = (w - left - 8) / kCols;
    const int cell_h = (h - top - 14) / kRows;

    const char* title = "";
    const char* x_axis = "";
    const char* y_axis = "";
    switch (mode) {
        case 0: title = "HUE X SAT";  x_axis = "HUE 90-180"; y_axis = "SAT 100-30"; break;
        case 1: title = "HUE X VAL";  x_axis = "HUE 90-180"; y_axis = "VAL 100-35"; break;
        default: title = "SAT X VAL"; x_axis = "SAT 100-25"; y_axis = "VAL 100-35"; break;
    }
    display_text(8, 8, title, 2, display_rgb(150, 160, 170));
    display_text(8, 26, x_axis, 1, display_rgb(90, 100, 110));
    display_text(8 + display_text_width(x_axis, 1) + 12, 26, y_axis, 1,
                 display_rgb(90, 100, 110));

    for (int col = 0; col < kCols; ++col) {
        char n[4];
        std::snprintf(n, sizeof n, "%d", col);
        display_text(left + cell_w * col + cell_w / 2 - 3, top - 14, n, 1,
                     display_rgb(110, 120, 130));
    }

    for (int row = 0; row < kRows; ++row) {
        char n[4];
        std::snprintf(n, sizeof n, "%d", row);
        display_text(6, top + cell_h * row + cell_h / 2 - 3, n, 1,
                     display_rgb(110, 120, 130));

        for (int col = 0; col < kCols; ++col) {
            const float fx = static_cast<float>(col) / (kCols - 1);
            const float fy = static_cast<float>(row) / (kRows - 1);
            uint32_t colour;
            if (mode == 0) {
                colour = from_hsv(90.0f + fx * 90.0f, 1.0f - fy * 0.70f, 1.0f);
            } else if (mode == 1) {
                colour = from_hsv(90.0f + fx * 90.0f, 0.85f, 1.0f - fy * 0.65f);
            } else {
                colour = from_hsv(150.0f, 1.0f - fx * 0.75f, 1.0f - fy * 0.65f);
            }

            // The stroke, drawn exactly as a value arc is: wide dim bloom, then narrower,
            // then the crisp line. A colour that survives this survives the knob.
            const int cx = left + cell_w * col + cell_w / 2;
            const int cy = top + cell_h * row + cell_h / 2;
            const float half = cell_w * 0.30f;
            display_line(cx - half, cy, cx + half, cy, 9.0f, dimmed(colour, 16));
            display_line(cx - half, cy, cx + half, cy, 5.0f, dimmed(colour, 38));
            display_line(cx - half, cy, cx + half, cy, 3.0f, colour);
        }
    }
    display_present();
}

// Six greens, drawn as the thing they would actually be.
//
// The swatch grids were a bad instrument: forty-two near-identical cells is a test of
// patience rather than of colour, and a colour judged as a bare stroke lies about how it
// reads once it is an arc wrapped around a lit knob body. Six candidates, far enough
// apart to tell apart, each drawn as a real knob at a real size — pick by pointing.
struct GreenCandidate { const char* name; uint32_t colour; };

const GreenCandidate kGreens[] = {
    {"P1",      display_rgb(51, 255, 51)},    // the CRT phosphor: pure, no blue at all
    {"MINT",    display_rgb(110, 232, 184)},  // cyan-leaning; what the rack uses today
    {"EMERALD", display_rgb(0, 210, 140)},    // deeper and bluer
    {"LIME",    display_rgb(160, 255, 70)},   // yellow-leaning: maximum apparent glow
    {"SAGE",    display_rgb(140, 200, 150)},  // desaturated: is "garish" about saturation?
    {"JADE",    display_rgb(60, 200, 120)},   // between mint and emerald
};
constexpr int kGreenCount = sizeof(kGreens) / sizeof(kGreens[0]);

void draw_green_choices() {
    if (!display_available()) return;
    const int w = display_width(), h = display_height();
    display_clear(display_rgb(0, 0, 0));
    display_text(10, 8, "WHICH GREEN", 2, display_rgb(150, 160, 170));

    const int columns = 2, rows = 3;
    const int top = 40;
    const int cell_w = w / columns, cell_h = (h - top - 6) / rows;
    const int radius = 46;

    for (int i = 0; i < kGreenCount; ++i) {
        const int cx = cell_w * (i % columns) + cell_w / 2;
        const int cy = top + cell_h * (i / columns) + cell_h / 2 - 10;
        const uint32_t colour = kGreens[i].colour;

        // Held at three-quarters, which shows both the lit arc and the dim remainder.
        const float angle = kKnobStart + kKnobSweep * 0.75f;
        const float track_radius = static_cast<float>(radius) + 6.0f;
        display_arc(cx, cy, track_radius, 3.0f, kKnobStart, kKnobStart + kKnobSweep,
                    dimmed(colour, 18));
        display_arc(cx, cy, track_radius, 9.0f, kKnobStart, angle, dimmed(colour, 16));
        display_arc(cx, cy, track_radius, 5.0f, kKnobStart, angle, dimmed(colour, 38));
        display_arc(cx, cy, track_radius, 3.0f, kKnobStart, angle, colour);

        display_disc(cx, cy, static_cast<float>(radius), display_rgb(16, 26, 20));
        display_disc(cx, cy - 1, static_cast<float>(radius) - 4.0f, display_rgb(24, 38, 30));

        const float rad = angle * 3.14159265f / 180.0f;
        display_line(cx + std::cos(rad) * (radius * 0.34f),
                     cy + std::sin(rad) * (radius * 0.34f),
                     cx + std::cos(rad) * (radius - 3.0f),
                     cy + std::sin(rad) * (radius - 3.0f),
                     2.5f, display_rgb(198, 255, 224));

        char caption[16];
        std::snprintf(caption, sizeof caption, "%d %s", i + 1, kGreens[i].name);
        display_text(cx - display_text_width(caption, 2) / 2, cy + radius + 12,
                     caption, 2, display_rgb(150, 160, 170));
    }
    display_present();
}

// A green ramp, at whatever depth the panel is being driven.
//
// This began as sixty-four bands because RGB565 gives green six bits, and the steps
// were visible — which is what sent the panel to 24 bits. At eight bits per channel
// there are 256 levels and the screen has 502 rows, so the ramp is now continuous:
// one level per two rows, with nothing left to band.
void draw_green_ramp(int tint) {
    if (!display_available()) return;
    const int w = display_width(), h = display_height();
    display_clear(display_rgb(0, 0, 0));

    // Levels are mapped onto the full height rather than given a row each: at 256
    // levels on a 502-row panel a row-per-level covered half the screen and left the
    // rest showing whatever was there before, which reads as noise rather than as a
    // short ramp.
    constexpr int kLevels = 256;  // eight bits of green, at 24-bit
    const int top = 0;

    for (int level = 0; level < kLevels; ++level) {
        const int g = level;
        // A little red leans the green yellow, a little blue leans it cyan; the tint is
        // scaled off the level so the hue stays put as it dims.
        const int r = tint > 0 ? g * tint / 100 : 0;
        const int b = tint < 0 ? g * (-tint) / 100 : 0;
        const int y = top + (h * (kLevels - 1 - level)) / kLevels;
        const int next = top + (h * (kLevels - level)) / kLevels;
        display_rect(0, y, w - 46, (next - y) > 0 ? (next - y) : 1, display_rgb(r, g, b));

        if (level % 32 == 0 || level == kLevels - 1) {
            char label[8];
            std::snprintf(label, sizeof label, "%d", level);
            display_text(w - 40, y - 3, label, 1, display_rgb(150, 160, 170));
        }
    }
}

void draw_face() {
    if (!display_available()) return;
    const int w = display_width(), h = display_height();
    const Theme& t = theme();
    display_clear(t.ground);

    if (g_ui_controls.empty()) {
        const char* none = "NO CONTROLS";
        display_text((w - display_text_width(none, 2)) / 2, h / 2, none, 2, t.ink_dim);
        display_present();
        return;
    }

    // The header carries the held knob's name and value at a size that reads from
    // across a desk — and it sits at the top, where the hand that is dragging is not.
    if (g_active_knob >= 0 && g_active_knob < static_cast<int>(g_ui_controls.size())) {
        const UiControl& control = g_ui_controls[static_cast<std::size_t>(g_active_knob)];
        char value[16];
        format_value(value, sizeof value, control.value);
        char name[14];
        std::snprintf(name, sizeof name, "%s", control.label.c_str());
        // The name dim, the number in ink. The accent stays on the arcs: a slab of
        // saturated type is the other half of what made the first cut shout.
        display_text((w - display_text_width(name, 2)) / 2, 12, name, 2, t.ink_dim);
        display_text((w - display_text_width(value, 5)) / 2, 32, value, 5, t.ink);
    } else {
        const char* title = "WRIST ARPEGGIO";
        display_text((w - display_text_width(title, 2)) / 2, 26, title, 2,
                     dimmed(t.ink_dim, 62));
    }

    // A safe inset, because the glass is a rounded rectangle and the corners are not
    // there. Drawn edge to edge, the bottom row's labels lost their first and last
    // letters to the curve — CUTOFF read as TOFF — which is invisible in a framebuffer
    // and obvious in a photograph.
    constexpr int kSideInset = 22;
    constexpr int kBottomInset = 30;
    const int columns = 3;
    const int rows = (static_cast<int>(g_ui_controls.size()) + columns - 1) / columns;
    const int top = 66;
    const int cell_w = (w - kSideInset * 2) / columns;
    const int cell_h = (h - top - kBottomInset) / (rows > 0 ? rows : 1);
    int radius = (cell_w < cell_h ? cell_w : cell_h) / 2 - 20;
    if (radius < 14) radius = 14;

    g_knob_hits.assign(g_ui_controls.size(), KnobHit{});
    for (std::size_t i = 0; i < g_ui_controls.size(); ++i) {
        const int col = static_cast<int>(i) % columns;
        const int row = static_cast<int>(i) / columns;
        const int cx = kSideInset + cell_w * col + cell_w / 2;
        const int cy = top + cell_h * row + cell_h / 2 - 10;
        draw_knob(cx, cy, radius, g_ui_controls[i], static_cast<int>(i) == g_active_knob);
        g_knob_hits[i] = KnobHit{cx, cy, radius};
    }
    display_present();
}

// ---------------------------------------------------------------------------------
// The glow lab.
//
// Every glow in this interface is currently a guess baked into a call site — three
// hard-coded arcs at widths 8, 5 and 3 with brightnesses 10, 26 and 100. Those numbers
// were chosen by writing them down, flashing, and squinting, which is a slow way to
// choose six numbers and a hopeless way to choose them *together*: a halo that is right
// at one core width is wrong at another, and photographs of a lit screen lie about
// intensity besides. So the parameters get knobs, and the specimen is a scope graticule
// — a rectangular grid of straight lines, which is the plainest possible thing to judge
// a line against and happens to be the shape the interface will actually want.
//
// The knobs here are deliberately NOT UiControls sourced from a patch. There is no patch
// behind them; they are the renderer's own dials, and pretending otherwise would put a
// second, fake control surface next to the real one.

struct LabState {
    float width = 2.0f;      // the bright core
    float glow = 9.0f;       // how far the spill reaches past it
    float level = 55.0f;     // how bright the spill starts, 0-100
    float cells = 4.0f;      // grid divisions
    float hue = 50.0f;       // along a green family, yellow-green to teal
    float bright = 100.0f;   // the core's own brightness
};
LabState g_lab;

std::vector<UiControl> g_lab_controls;

void lab_controls_init() {
    auto add = [](const char* label, float lo, float hi, float value) {
        UiControl c;
        c.label = label;
        c.min_value = lo;
        c.max_value = hi;
        c.value = value;
        g_lab_controls.push_back(c);
    };
    g_lab_controls.clear();
    add("WIDTH",  0.5f,  8.0f,   g_lab.width);
    add("GLOW",   0.0f,  28.0f,  g_lab.glow);
    add("LEVEL",  0.0f,  100.0f, g_lab.level);
    add("CELLS",  1.0f,  8.0f,   g_lab.cells);
    add("HUE",    0.0f,  100.0f, g_lab.hue);
    add("BRIGHT", 20.0f, 100.0f, g_lab.bright);
}

void lab_pull() {
    if (g_lab_controls.size() < 6) return;
    g_lab.width  = g_lab_controls[0].value;
    g_lab.glow   = g_lab_controls[1].value;
    g_lab.level  = g_lab_controls[2].value;
    g_lab.cells  = g_lab_controls[3].value;
    g_lab.hue    = g_lab_controls[4].value;
    g_lab.bright = g_lab_controls[5].value;
}

// One knob across the green family rather than three across all of colour space. The
// sweep runs yellow-green to teal with green pinned at full, because that is the arc
// the eye reads as "which green" — the rest of RGB space is not under discussion.
uint32_t lab_colour() {
    const float t = g_lab.hue / 100.0f;
    const int r = static_cast<int>(170.0f * (1.0f - t) + 0.5f);
    const int b = static_cast<int>(40.0f + 150.0f * t + 0.5f);
    return display_dim(display_rgb(r, 255, b), static_cast<int>(g_lab.bright + 0.5f));
}

void draw_lab() {
    if (!display_available()) return;
    const int w = display_width(), h = display_height();
    display_clear(display_rgb(0, 0, 0));

    const uint32_t colour = lab_colour();
    const int cells = static_cast<int>(g_lab.cells + 0.5f);
    const int intensity = static_cast<int>(g_lab.level + 0.5f);

    // The graticule. Inset from the glass edge, and given room below for the dials.
    const int left = 26, right = w - 26, top = 30;
    const int bottom = top + 190;

    for (int i = 0; i <= cells; ++i) {
        const float fx = left + (right - left) * static_cast<float>(i) / cells;
        display_glow_line(fx, static_cast<float>(top), fx, static_cast<float>(bottom),
                          g_lab.width, g_lab.glow, intensity, colour);
    }
    for (int i = 0; i <= cells; ++i) {
        const float fy = top + (bottom - top) * static_cast<float>(i) / cells;
        display_glow_line(static_cast<float>(left), fy, static_cast<float>(right), fy,
                          g_lab.width, g_lab.glow, intensity, colour);
    }

    // The readout names the six numbers, because the point of the exercise is to leave
    // with numbers that can be typed into the interface — not with a screen that looked
    // right once.
    char line[48];
    std::snprintf(line, sizeof line, "W%.1f G%.0f L%.0f C%d H%.0f B%.0f",
                  static_cast<double>(g_lab.width), static_cast<double>(g_lab.glow),
                  static_cast<double>(g_lab.level), cells,
                  static_cast<double>(g_lab.hue), static_cast<double>(g_lab.bright));
    display_text((w - display_text_width(line, 1)) / 2, bottom + 10, line, 1,
                 display_rgb(120, 132, 140));

    const int columns = 3;
    const int knob_top = bottom + 28;
    const int cell_w = (w - 44) / columns;
    const int cell_h = (h - knob_top - 22) / 2;
    int radius = (cell_w < cell_h ? cell_w : cell_h) / 2 - 16;
    if (radius < 14) radius = 14;

    g_knob_hits.assign(g_lab_controls.size(), KnobHit{});
    for (std::size_t i = 0; i < g_lab_controls.size(); ++i) {
        const int cx = 22 + cell_w * (static_cast<int>(i) % columns) + cell_w / 2;
        const int cy = knob_top + cell_h * (static_cast<int>(i) / columns) + cell_h / 2 - 8;
        draw_knob(cx, cy, radius, g_lab_controls[i], static_cast<int>(i) == g_active_knob);
        g_knob_hits[i] = KnobHit{cx, cy, radius};
    }
    display_present();
}

// ---------------------------------------------------------------------------------
// Which set of knobs the finger is on.
//
// The touch task used to reach straight into the patch's controls and call draw_face,
// which made a second screen impossible without duplicating it. A surface is the three
// things a screen of knobs needs: what the knobs are, how to draw them, and where a
// change goes. The face sends changes to the running graph; the lab keeps them.
struct Surface {
    std::vector<UiControl>* controls;
    void (*redraw)();
    void (*changed)();
};

void face_changed();
void lab_changed() { lab_pull(); }

const Surface kFaceSurface{&g_ui_controls, draw_face, face_changed};
const Surface kLabSurface{&g_lab_controls, draw_lab, lab_changed};
const Surface* g_surface = &kFaceSurface;

// A finger on a knob. Vertical drag rather than rotation: turning a real knob is a
// wrist movement, but on glass a straight drag is what the hand actually does, and it
// gives the whole screen height of travel instead of a thumb-sized arc. The value goes
// straight into the running graph, so the sound follows the finger.
void touch_task(void*) {
    int held = -1;
    int last_y = 0;
    float held_start_value = 0.0f;

    for (;;) {
        std::vector<UiControl>& controls = *g_surface->controls;
        int x = 0, y = 0;
        if (touch_read(&x, &y)) {
            if (held < 0) {
                // Generous hit radius: fingers are wider than knobs.
                for (std::size_t i = 0; i < g_knob_hits.size() && i < controls.size(); ++i) {
                    const KnobHit& hit = g_knob_hits[i];
                    const int dx = x - hit.cx, dy = y - hit.cy;
                    const int reach = hit.radius + 12;
                    if (dx * dx + dy * dy <= reach * reach) {
                        held = static_cast<int>(i);
                        last_y = y;
                        held_start_value = controls[i].value;
                        g_active_knob = held;
                        g_surface->redraw();
                        break;
                    }
                }
            } else if (held < static_cast<int>(controls.size())) {
                UiControl& control = controls[static_cast<std::size_t>(held)];
                const float span = control.max_value - control.min_value;
                // A full screen height covers the whole range; upward is more.
                const float travel = static_cast<float>(last_y - y) / display_height();
                float next = held_start_value + travel * span * 1.4f;
                if (next < control.min_value) next = control.min_value;
                if (next > control.max_value) next = control.max_value;

                if (next != control.value) {
                    control.value = next;
                    g_surface->changed();
                    g_surface->redraw();
                }
            }
        } else if (held >= 0) {
            held = -1;
            g_active_knob = -1;
            g_surface->redraw();   // back to the title once the finger lifts
        }
        vTaskDelay(pdMS_TO_TICKS(30));
    }
}

// The face's changes are the ones that make sound: straight into the running graph, so
// it follows the finger.
void face_changed() {
    if (g_active_knob < 0 || g_active_knob >= static_cast<int>(g_ui_controls.size())) return;
    const UiControl& control = g_ui_controls[static_cast<std::size_t>(g_active_knob)];
    soundgraph::Graph* graph = g_live_graph.load(std::memory_order_acquire);
    if (graph != nullptr) {
        graph->set_parameter(control.node, control.parameter, control.value);
    }
}

// Swaps the live graph and frees the old one once the audio task cannot still be inside
// it. One block at 48 kHz is ~1.3 ms; 50 ms is comfortably past any scheduling jitter.
void make_live(soundgraph::Graph* next) {
    soundgraph::Graph* previous = g_live_graph.exchange(next, std::memory_order_acq_rel);
    if (previous != nullptr) {
        vTaskDelay(pdMS_TO_TICKS(50));
        delete previous;
    }
}

bool load_deployed_patch(std::string& text_out) {
    nvs_handle_t handle;
    if (nvs_open(kNvsNamespace, NVS_READONLY, &handle) != ESP_OK) {
        return false;
    }
    std::size_t size = 0;
    if (nvs_get_blob(handle, kNvsPatchKey, nullptr, &size) != ESP_OK || size == 0) {
        nvs_close(handle);
        return false;
    }
    text_out.resize(size);
    const bool ok = nvs_get_blob(handle, kNvsPatchKey, text_out.data(), &size) == ESP_OK;
    nvs_close(handle);
    return ok;
}

bool store_deployed_patch(const std::string& text) {
    nvs_handle_t handle;
    if (nvs_open(kNvsNamespace, NVS_READWRITE, &handle) != ESP_OK) {
        return false;
    }
    const bool ok = nvs_set_blob(handle, kNvsPatchKey, text.data(), text.size()) == ESP_OK &&
                    nvs_commit(handle) == ESP_OK;
    nvs_close(handle);
    return ok;
}

void erase_deployed_patch() {
    nvs_handle_t handle;
    if (nvs_open(kNvsNamespace, NVS_READWRITE, &handle) == ESP_OK) {
        nvs_erase_key(handle, kNvsPatchKey);
        nvs_commit(handle);
        nvs_close(handle);
    }
}

// ---------------------------------------------------------------------------------
// Console byte-level input
//
// Command lines come through stdio, but a bulk payload needs a bounded wait — and with
// the interrupt-driven console driver, getchar() blocks with no timeout at all. These
// read through the driver itself where it can, and fall back to polled getchar on
// UART-console builds, where getchar really does return EOF when the buffer is empty.
// ---------------------------------------------------------------------------------

int console_read_bytes(char* destination, int wanted, int timeout_ms) {
#if CONFIG_ESP_CONSOLE_USB_SERIAL_JTAG
    return static_cast<int>(usb_serial_jtag_read_bytes(
        destination, static_cast<uint32_t>(wanted), pdMS_TO_TICKS(timeout_ms)));
#else
    int waited_ms = 0;
    int character = std::getchar();
    while (character == EOF) {
        if (waited_ms >= timeout_ms) {
            return 0;
        }
        vTaskDelay(pdMS_TO_TICKS(5));
        waited_ms += 5;
        character = std::getchar();
    }
    destination[0] = static_cast<char>(character);
    return 1;
#endif
}

void console_drain_input() {
    char discard[64];
    while (console_read_bytes(discard, sizeof(discard), 300) > 0) {
    }
}

// ---------------------------------------------------------------------------------
// Golden rendering over serial
// ---------------------------------------------------------------------------------

void base64_line(const unsigned char* data, std::size_t length, char* out) {
    static const char kAlphabet[] =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::size_t position = 0;
    for (std::size_t i = 0; i < length; i += 3) {
        const unsigned int b0 = data[i];
        const unsigned int b1 = i + 1 < length ? data[i + 1] : 0;
        const unsigned int b2 = i + 2 < length ? data[i + 2] : 0;
        out[position++] = kAlphabet[b0 >> 2];
        out[position++] = kAlphabet[((b0 & 0x03) << 4) | (b1 >> 4)];
        out[position++] = i + 1 < length ? kAlphabet[((b1 & 0x0F) << 2) | (b2 >> 6)] : '=';
        out[position++] = i + 2 < length ? kAlphabet[b2 & 0x3F] : '=';
    }
    out[position] = '\0';
}

struct RenderEvent {
    int frame = 0;
    bool on = true;
    int note = 60;
    float velocity = 1.0f;
};

// "note_on:frame:note:vel" or "note_off:frame:note"
bool parse_render_event(const char* token, RenderEvent& out) {
    char kind[16] = {};
    float velocity = 1.0f;
    int frame = 0;
    int note = 0;
    const int fields = std::sscanf(token, "%15[^:]:%d:%d:%f", kind, &frame, &note, &velocity);
    if (fields < 3) {
        return false;
    }
    out.frame = frame;
    out.note = note;
    out.velocity = velocity;
    if (std::strcmp(kind, "note_on") == 0) {
        out.on = true;
    } else if (std::strcmp(kind, "note_off") == 0) {
        out.on = false;
    } else {
        return false;
    }
    return true;
}

// Renders an embedded patch offline and streams the left channel as base64 float32.
// Runs in the console task against its own Graph; the live audio is untouched.
void command_render(const std::string& name, int frames, const std::vector<RenderEvent>& events) {
    const char* text = find_embedded_patch(name);
    if (text == nullptr) {
        std::printf("ERR no embedded patch named '%s'\n", name.c_str());
        return;
    }

    std::string error;
    std::unique_ptr<soundgraph::Graph> graph(build_graph(text, error));
    if (!graph) {
        std::printf("ERR %s\n", error.c_str());
        return;
    }

    std::printf("RENDER %s %d %d\n", name.c_str(), frames, SG_AUDIO_SAMPLE_RATE);

    float left[kBlock];
    char encoded[(kBlock * 4 / 3 + 4) * 4] = {};
    std::size_t next_event = 0;
    int position = 0;

    while (position < frames) {
        const int count = frames - position < kBlock ? frames - position : kBlock;
        while (next_event < events.size() && events[next_event].frame < position + count) {
            const RenderEvent& event = events[next_event];
            soundgraph::NoteEvent note;
            note.kind = event.on ? soundgraph::NoteEvent::Kind::NoteOn
                                 : soundgraph::NoteEvent::Kind::NoteOff;
            note.note = event.note;
            note.velocity = event.velocity;
            graph->dispatch_note(note);
            ++next_event;
        }
        graph->render(left, nullptr, count);

        // Each line is standalone base64 of this block's bytes, prefixed with the byte
        // count so the host can *detect* a corrupted or truncated line rather than
        // misinterpret it. The host decodes lines independently and concatenates.
        const std::size_t bytes = static_cast<std::size_t>(count) * sizeof(float);
        base64_line(reinterpret_cast<const unsigned char*>(left), bytes, encoded);
        std::printf("D %u %s\n", static_cast<unsigned>(bytes), encoded);
        std::fflush(stdout);
        position += count;

        // Yield periodically. A console task that prints flat-out can both starve the
        // idle task (whose watchdog complaint then deadlocks on the console lock this
        // task holds) and outrun the USB console's transmit buffer, which drops bytes
        // mid-line rather than blocking. A short pause every few blocks costs the
        // transfer little and keeps the stream intact.
        if ((position / kBlock) % 4 == 0) {
            vTaskDelay(2);
        }
    }
    std::printf("RENDER-END\n");
    std::fflush(stdout);
}

// ---------------------------------------------------------------------------------
// Console
// ---------------------------------------------------------------------------------

void print_info() {
    soundgraph::Graph* graph = g_live_graph.load(std::memory_order_acquire);
    std::printf("board       %s\n", SG_BOARD_NAME);
    std::printf("sample rate %d\n", SG_AUDIO_SAMPLE_RATE);
    if (graph == nullptr) {
        std::printf("no patch is loaded\n");
    } else {
        std::printf("nodes       %d\n", graph->node_count());
        std::printf("order       ");
        for (int index : graph->execution_order()) {
            std::printf("%s ", graph->node_id(index).c_str());
        }
        std::printf("\n");
        const soundgraph::ResourceCost cost = graph->estimated_cost();
        std::printf("cost        cpu %.1f, state %d B, buffers %d B\n",
                    static_cast<double>(cost.cpu_cost), cost.state_bytes, cost.heap_bytes);
    }
    std::printf("heap        %u internal, %u psram\n",
                static_cast<unsigned>(heap_caps_get_free_size(MALLOC_CAP_INTERNAL)),
                static_cast<unsigned>(heap_caps_get_free_size(MALLOC_CAP_SPIRAM)));
    std::printf("arpeggiator %s\n", g_sequencer.running() ? "on" : "off");
}

void command_load(int byte_count) {
    if (byte_count <= 0 || byte_count > 64 * 1024) {
        std::printf("ERR load size must be 1..65536 bytes\n");
        return;
    }
    std::string text(static_cast<std::size_t>(byte_count), '\0');
    std::printf("SEND %d\n", byte_count);
    std::fflush(stdout);

    // A host that promised N bytes and stops sending must not wedge the console — an
    // unplugged cable mid-deploy is a when, not an if. stdio cannot express "wait at
    // most this long", so the payload is read through the console driver directly
    // (stdin is unbuffered, so stdio holds nothing back). Any stall abandons the
    // transfer, and the input is drained afterwards so stragglers from the aborted
    // upload cannot be misread as commands.
    int received = 0;
    while (received < byte_count) {
        const int chunk = console_read_bytes(&text[static_cast<std::size_t>(received)],
                                             byte_count - received, 2000);
        if (chunk <= 0) {
            std::printf("ERR upload stalled at byte %d of %d; transfer abandoned\n",
                        received, byte_count);
            std::fflush(stdout);
            console_drain_input();
            return;
        }
        received += chunk;
    }

    std::string error;
    soundgraph::Graph* graph = build_graph(text.c_str(), error);
    if (graph == nullptr) {
        std::printf("ERR %s\n", error.c_str());
        return;
    }
    if (!store_deployed_patch(text)) {
        std::printf("ERR the patch plays but could not be stored to NVS\n");
    }
    make_live(graph);
    std::printf("OK deployed, %d nodes\n", g_live_graph.load()->node_count());
    draw_face();
}

// Listens for a moment and says what it heard.
//
// A microphone is the one part of a board that cannot be verified by reading a register:
// the chip will happily report itself present while the wire from it is dead. So this
// reports what actually arrived — level, and the strongest frequency in it — which is a
// claim somebody can check by making a noise at it.
//
// The frequency estimate is a Goertzel bank rather than an FFT: single-bin evaluations
// need no scratch buffer and no library, and the question being asked is only "is this
// the tone I am playing at it?".
//
// The bins have to tile the spectrum, though, and the first version of this did not.
// It swept 32 logarithmically-spaced frequencies across the *whole* capture, which made
// each one a filter 2.5 Hz wide (48000/19200) sitting in gaps 66 Hz apart at 440 Hz and
// 337 Hz apart at 2500 Hz. A tone registered only if it landed almost exactly on a bin:
// a 1 kHz test tone read perfectly, because bin 17 happened to be 999.7 Hz, while 440
// and 2500 read as room rumble with a clearly elevated level right there in the same
// output. A diagnostic that confidently reports the wrong answer is worse than one that
// reports nothing.
//
// So the bins are now the natural DFT bin centres of a short window — 1536 samples at
// 48 kHz, so 31.25 Hz apart and 31.25 Hz wide, which is a sieve with no holes in it.
// Magnitudes are averaged over as many windows as the capture holds, which trades the
// resolution nothing needs here for a steadier answer on a noisy one.
void command_mic(int milliseconds) {
    if (!mic_available()) {
        std::printf("ERR no microphone on this board\n");
        return;
    }
    if (milliseconds < 10) milliseconds = 10;
    if (milliseconds > 2000) milliseconds = 2000;

    // Four windows, and single precision throughout the bank below.
    //
    // The first version of this used doubles and eight windows, which is six million
    // emulated operations: the ESP32-S3's FPU is single-precision only, so every double
    // is a library call, and the console task held CPU 0 long enough for the idle task's
    // watchdog to fire. Nothing about a frequency readout needs more than a float, and
    // the bank yields between bins so that a long analysis is merely slow rather than
    // fatal — the same lesson command_render already carries.
    constexpr int kMaxWindows = 4;

    const int channels = SG_AUDIO_IN_CHANNELS;
    const int frames = SG_AUDIO_SAMPLE_RATE * milliseconds / 1000;
    const std::size_t samples = static_cast<std::size_t>(frames) * channels;

    // PSRAM: two seconds of stereo is 384 KB, which internal RAM would rather not lose.
    int16_t* buffer = static_cast<int16_t*>(
        heap_caps_malloc(samples * sizeof(int16_t), MALLOC_CAP_SPIRAM));
    if (buffer == nullptr) {
        std::printf("ERR could not allocate %u bytes for the capture\n",
                    static_cast<unsigned>(samples * sizeof(int16_t)));
        return;
    }

    // The recogniser is reading the same microphone. Two readers split the stream
    // between them and both get holes — which showed up as a noise floor of exactly
    // zero, a reading that looks like a broken microphone and is a broken measurement.
    // Listening pauses for the length of the capture and resumes after.
    const bool was_listening = speech_listening();
    if (was_listening) {
        speech_set_listening(false);
        vTaskDelay(pdMS_TO_TICKS(60));   // let the feed task notice and let go
    }
    const int got = mic_read(buffer, frames, 2000);
    if (was_listening) {
        speech_set_listening(true);
    }
    if (got <= 0) {
        std::printf("ERR the microphone returned nothing\n");
        heap_caps_free(buffer);
        return;
    }

    std::printf("MIC frames=%d rate=%d channels=%d\n", got, SG_AUDIO_SAMPLE_RATE, channels);

    double best_strength = 0.0;
    double best_frequency = 0.0;
    for (int channel = 0; channel < channels; ++channel) {
        // The mean comes out first: a DC offset is an ADC's resting state, and counting
        // it as signal makes a silent room look loud.
        double mean = 0.0;
        for (int i = 0; i < got; ++i) {
            mean += buffer[static_cast<std::size_t>(i) * channels + channel];
        }
        mean /= got;

        double sum_of_squares = 0.0;
        double peak = 0.0;
        for (int i = 0; i < got; ++i) {
            const double value =
                (buffer[static_cast<std::size_t>(i) * channels + channel] - mean) / 32768.0;
            sum_of_squares += value * value;
            const double magnitude = value < 0.0 ? -value : value;
            if (magnitude > peak) peak = magnitude;
        }
        std::printf("  ch%d rms=%.5f peak=%.5f dc=%.1f\n", channel,
                    std::sqrt(sum_of_squares / got), peak, mean);

        // The bank. Bin k sits at k * rate / kWindow and is that wide, so the range it
        // covers — 62 Hz to 5 kHz, which holds speech and any test tone worth playing —
        // has nothing falling between the bins.
        constexpr int kWindow = 1536;
        constexpr int kFirstBin = 2;    // 62.5 Hz
        constexpr int kLastBin = 160;   // 5000 Hz
        const int windows = got / kWindow < kMaxWindows ? got / kWindow : kMaxWindows;
        if (windows == 0) {
            continue;  // too short a capture to say anything about frequency
        }
        const float centre = static_cast<float>(mean);
        for (int bin = kFirstBin; bin <= kLastBin; ++bin) {
            const float omega = 2.0f * 3.14159265f * static_cast<float>(bin) / kWindow;
            const float coefficient = 2.0f * std::cos(omega);
            float total = 0.0f;
            for (int window = 0; window < windows; ++window) {
                float s1 = 0.0f;
                float s2 = 0.0f;
                const int start = window * kWindow;
                for (int i = 0; i < kWindow; ++i) {
                    const std::size_t at =
                        static_cast<std::size_t>(start + i) * channels + channel;
                    const float value = (buffer[at] - centre) * (1.0f / 32768.0f);
                    const float s0 = value + coefficient * s1 - s2;
                    s2 = s1;
                    s1 = s0;
                }
                total += std::sqrt(s1 * s1 + s2 * s2 - coefficient * s1 * s2) / kWindow;
            }
            const double strength = total / windows;
            if (strength > best_strength) {
                best_strength = strength;
                best_frequency = static_cast<double>(bin) * SG_AUDIO_SAMPLE_RATE / kWindow;
            }
            // The idle task needs a turn. Without this the console holds its core for
            // long enough that the watchdog calls it a hang, which it is not.
            if ((bin & 15) == 0) {
                vTaskDelay(1);
            }
        }
    }

    std::printf("  loudest ~%.0f Hz at %.5f\n", best_frequency, best_strength);
    heap_caps_free(buffer);
}

// What the board does when it hears one of its own phrases.
//
// Deliberately the same verbs the console already has, reaching the graph the same way a
// typed command does. A voice command is a control source and nothing more — it earns no
// private path into the engine, which is what keeps "what happens when I say this" the
// same question as "what happens when I type this".
void on_speech_command(int command, const char* phrase, float probability) {
    std::printf("HEARD %s (%.2f)\n", phrase, probability);

    soundgraph::Graph* graph = g_live_graph.load(std::memory_order_acquire);
    switch (command) {
        case kSpeechHeyMom:
            // Answering is the whole action. The note is what starts the Speech node —
            // the reply is a patch, and a patch is played, not printed.
            if (g_reply != nullptr) {
                g_reply->reset();
                g_reply->note_on(60, 1.0f);
                g_reply_frames.store(kReplyFrames, std::memory_order_release);
            }
            break;
        case kSpeechLouder:
            g_volume = g_volume + 10.0f > 100.0f ? 100.0f : g_volume + 10.0f;
            codec_set_volume(g_volume);
            std::printf("  volume %.0f\n", g_volume);
            break;
        case kSpeechQuieter:
            g_volume = g_volume - 10.0f < 0.0f ? 0.0f : g_volume - 10.0f;
            codec_set_volume(g_volume);
            std::printf("  volume %.0f\n", g_volume);
            break;
        case kSpeechStartPlaying:
            g_sequencer.set_running(true);
            break;
        case kSpeechStopPlaying:
            g_sequencer.set_running(false);
            if (graph != nullptr) {
                graph->all_notes_off();
            }
            break;
        case kSpeechNextPatch:
        case kSpeechPreviousPatch:
            // The embedded patches are there and switching between them is a few lines,
            // but doing it from this task would rebuild the graph underneath the audio
            // task. The console's own `load` path already solves that; this wants to go
            // through it rather than around it, and that is the next piece of work.
            std::printf("  not wired yet\n");
            break;
        default:
            break;
    }
}

void console_task(void*) {
    char line[512];
    std::printf("\nSoundGraph on %s — type 'info'\n", SG_BOARD_NAME);

    for (;;) {
        if (std::fgets(line, sizeof(line), stdin) == nullptr) {
            vTaskDelay(pdMS_TO_TICKS(20));
            continue;
        }
        // Tokenise in place.
        std::vector<char*> tokens;
        for (char* token = std::strtok(line, " \t\r\n"); token != nullptr;
             token = std::strtok(nullptr, " \t\r\n")) {
            tokens.push_back(token);
        }
        if (tokens.empty()) {
            continue;
        }
        soundgraph::Graph* graph = g_live_graph.load(std::memory_order_acquire);
        const std::string command = tokens[0];

        if (command == "info") {
            print_info();
        } else if (command == "screen") {
            // Panel bring-up without a reflash: the difference between iterating on a
            // screen in seconds and in minutes.
            if (!display_available()) {
                std::printf("ERR this board has no display\n");
            } else if (tokens.size() >= 2 && std::strcmp(tokens[1], "test") == 0) {
                display_test_card();
                std::printf("OK test card\n");
            } else if (tokens.size() >= 3 && std::strcmp(tokens[1], "fill") == 0) {
                const long rgb = std::strtol(tokens[2], nullptr, 16);
                display_clear(display_rgb((rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF));
                display_present();
                std::printf("OK filled %06lx\n", rgb);
            } else if (tokens.size() >= 3 && std::strcmp(tokens[1], "rotate") == 0) {
                display_set_rotation(std::atoi(tokens[2]));
                draw_face();
                std::printf("OK rotation %d\n", display_rotation());
            } else if (tokens.size() >= 3 && std::strcmp(tokens[1], "theme") == 0) {
                const int wanted = std::atoi(tokens[2]);
                if (wanted >= 0 && wanted < kThemeCount) {
                    g_theme = wanted;
                    draw_face();
                    std::printf("OK theme %d (%s)\n", g_theme, theme().name);
                } else {
                    std::printf("ERR themes 0..%d\n", kThemeCount - 1);
                    for (int i = 0; i < kThemeCount; ++i) {
                        std::printf("  %d %s\n", i, kThemes[i].name);
                    }
                }
            } else if (tokens.size() >= 2 && std::strcmp(tokens[1], "ramp") == 0) {
                const int tint = tokens.size() >= 3 ? std::atoi(tokens[2]) : 0;
                draw_green_ramp(tint);
                display_present();
                std::printf("OK ramp tint %d (64 levels)\n", tint);
            } else if (tokens.size() >= 2 && std::strcmp(tokens[1], "greens") == 0) {
                draw_green_choices();
                std::printf("OK greens\n");
            } else if (tokens.size() >= 3 && std::strcmp(tokens[1], "grid") == 0) {
                draw_swatch_grid(std::atoi(tokens[2]));
                std::printf("OK grid %s\n", tokens[2]);
            } else if (tokens.size() >= 2 && std::strcmp(tokens[1], "face") == 0) {
                g_surface = &kFaceSurface;
                g_active_knob = -1;
                draw_face();
                std::printf("OK face\n");
            } else if (tokens.size() >= 2 && std::strcmp(tokens[1], "lab") == 0) {
                if (g_lab_controls.empty()) lab_controls_init();
                g_surface = &kLabSurface;
                g_active_knob = -1;
                // Typed arguments set the dials directly, because "W2.5 G14 L60" from a
                // photograph needs to be reproducible without six drags.
                for (std::size_t i = 0; i + 2 < tokens.size() && i < g_lab_controls.size(); ++i) {
                    g_lab_controls[i].value = static_cast<float>(std::atof(tokens[i + 2]));
                }
                lab_pull();
                draw_lab();
                std::printf("OK lab W%.1f G%.0f L%.0f C%.0f H%.0f B%.0f\n",
                            static_cast<double>(g_lab.width), static_cast<double>(g_lab.glow),
                            static_cast<double>(g_lab.level), static_cast<double>(g_lab.cells),
                            static_cast<double>(g_lab.hue), static_cast<double>(g_lab.bright));
            } else if (tokens.size() >= 3 && std::strcmp(tokens[1], "bright") == 0) {
                display_set_brightness(std::atoi(tokens[2]));
                std::printf("OK brightness %s\n", tokens[2]);
            } else {
                std::printf("usage: screen test | face | lab [W G L C H B] | "
                            "theme 0-%d | rotate 0-270 | fill RRGGBB | bright 0-100\n",
                            kThemeCount - 1);
            }
        } else if (command == "note" && tokens.size() >= 2 && graph != nullptr) {
            const float velocity = tokens.size() >= 3 ? std::atof(tokens[2]) : 0.9f;
            g_sequencer.set_running(false);
            graph->note_on(std::atoi(tokens[1]), velocity);
            std::printf("OK\n");
        } else if (command == "off" && tokens.size() >= 2 && graph != nullptr) {
            graph->note_off(std::atoi(tokens[1]));
            std::printf("OK\n");
        } else if (command == "panic" && graph != nullptr) {
            g_sequencer.set_running(false);
            graph->all_notes_off();
            std::printf("OK\n");
        } else if (command == "arp" && tokens.size() >= 2) {
            if (std::strcmp(tokens[1], "on") == 0 || std::strcmp(tokens[1], "off") == 0) {
                g_sequencer.set_running(std::strcmp(tokens[1], "on") == 0);
                std::printf("OK arp %s\n", g_sequencer.running() ? "on" : "off");
            } else {
                // "arp 45,52,57,60" — set the pattern and start it.
                int notes[Sequencer::kMaxPattern];
                int count = 0;
                for (char* item = std::strtok(tokens[1], ","); item != nullptr &&
                     count < Sequencer::kMaxPattern; item = std::strtok(nullptr, ",")) {
                    notes[count++] = std::atoi(item);
                }
                if (count > 0) {
                    g_sequencer.set_pattern(notes, count);
                    g_sequencer.set_running(true);
                    std::printf("OK arp pattern of %d notes\n", count);
                } else {
                    std::printf("ERR arp takes on, off, or a note list like 45,52,57\n");
                }
            }
        } else if (command == "bpm" && tokens.size() >= 2) {
            g_sequencer.set_bpm(std::atof(tokens[1]));
            std::printf("OK\n");
        } else if (command == "listen") {
            if (!speech_available()) {
                std::printf("ERR this board is not listening\n");
            } else if (tokens.size() >= 2 && std::strcmp(tokens[1], "off") == 0) {
                speech_set_listening(false);
                std::printf("OK deaf\n");
            } else if (tokens.size() >= 2 && std::strcmp(tokens[1], "on") == 0) {
                speech_set_listening(true);
                std::printf("OK listening\n");
            } else {
                std::printf("LISTEN %s, wake word \"Hi ESP\"\n",
                            speech_listening() ? "on" : "off");
                for (int i = 0; i < kSpeechCommandCount; ++i) {
                    const char* phrasings[4];
                    const int count = speech_phrasings(i, phrasings, 4);
                    std::printf("  %d", i);
                    for (int p = 0; p < count; ++p) {
                        std::printf("%s %s", p == 0 ? "" : "  /", phrasings[p]);
                    }
                    std::printf("\n");
                }
            }
        } else if (command == "aec") {
            if (tokens.size() >= 2 && std::strcmp(tokens[1], "on") == 0) {
                speech_set_cancellation(true);
                std::printf("OK cancelling\n");
                continue;
            }
            if (tokens.size() >= 2 && std::strcmp(tokens[1], "off") == 0) {
                speech_set_cancellation(false);
                std::printf("OK not cancelling\n");
                continue;
            }
            if (tokens.size() >= 2) {
                speech_set_reference_lag(std::atoi(tokens[1]));
            }
            std::printf("AEC reference lag %d ms\n", speech_reference_lag());
        } else if (command == "mic") {
            if (tokens.size() >= 3 && std::strcmp(tokens[1], "gain") == 0) {
                std::printf("%s", mic_set_gain(static_cast<float>(std::atof(tokens[2])))
                                      ? "OK\n"
                                      : "ERR no microphone on this board\n");
            } else {
                command_mic(tokens.size() >= 2 ? std::atoi(tokens[1]) : 250);
            }
        } else if (command == "vol" && tokens.size() >= 2) {
            g_volume = static_cast<float>(std::atof(tokens[1]));
            if (codec_set_volume(g_volume)) {
                std::printf("OK\n");
            } else {
                std::printf("ERR this board has no volume hardware; use `set out level`\n");
            }
        } else if (command == "set" && tokens.size() >= 4 && graph != nullptr) {
            if (graph->set_parameter(tokens[1], tokens[2],
                                     static_cast<float>(std::atof(tokens[3])))) {
                std::printf("OK\n");
            } else {
                std::printf("ERR no parameter '%s' on node '%s'\n", tokens[2], tokens[1]);
            }
        } else if (command == "load" && tokens.size() >= 2) {
            command_load(std::atoi(tokens[1]));
        } else if (command == "unload") {
            erase_deployed_patch();
            std::string error;
            soundgraph::Graph* fallback = build_graph(find_embedded_patch("first-synth"), error);
            if (fallback != nullptr) {
                make_live(fallback);
            }
            std::printf("OK back to the embedded demo\n");
        } else if (command == "render" && tokens.size() >= 3) {
            std::vector<RenderEvent> events;
            bool events_ok = true;
            for (std::size_t i = 3; i < tokens.size(); ++i) {
                RenderEvent event;
                if (parse_render_event(tokens[i], event)) {
                    events.push_back(event);
                } else {
                    std::printf("ERR bad event '%s'\n", tokens[i]);
                    events_ok = false;
                    break;
                }
            }
            if (events_ok) {
                command_render(tokens[1], std::atoi(tokens[2]), events);
            }
        } else {
            std::printf("ERR unknown or incomplete command '%s'\n", command.c_str());
        }
        std::fflush(stdout);
    }
}

}  // namespace

extern "C" void app_main(void) {
#if CONFIG_ESP_CONSOLE_USB_SERIAL_JTAG
    // Put the console on the real interrupt-driven driver. The default polling path has
    // no buffering to speak of and can wedge under sustained output — which is exactly
    // what the golden-render streaming produces.
    usb_serial_jtag_driver_config_t console_config = {
        .tx_buffer_size = 4096,
        .rx_buffer_size = 1024,
    };
    if (usb_serial_jtag_driver_install(&console_config) == ESP_OK) {
        usb_serial_jtag_vfs_use_driver();
    }
    // No stdio read-ahead on stdin: bulk payloads are read through the driver directly,
    // and any byte stdio had buffered would be a byte the driver never sees.
    setvbuf(stdin, nullptr, _IONBF, 0);
#endif

    esp_err_t nvs_status = nvs_flash_init();
    if (nvs_status == ESP_ERR_NVS_NO_FREE_PAGES || nvs_status == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        nvs_flash_erase();
        nvs_flash_init();
    }

    if (!start_i2s()) {
        ESP_LOGE(TAG, "audio startup failed; the console still works");
    } else if (!codec_init(g_tx_channel, SG_AUDIO_SAMPLE_RATE)) {
        ESP_LOGE(TAG, "codec startup failed; I2S runs but the speaker may stay silent");
    } else if (g_rx_channel != nullptr && !mic_init(g_rx_channel, SG_AUDIO_SAMPLE_RATE)) {
        // After the codec, and only after it: the two chips share an I2C bus that
        // codec_init is the one to create. Not fatal — a board that cannot hear can
        // still play, and saying so is better than refusing to start.
        ESP_LOGW(TAG, "microphone startup failed; capture is unavailable");
    }

    // The panel, after the audio: a screen that fails to start is a cosmetic problem,
    // and an instrument that refuses to play because of one would be a worse instrument.
#if SG_DISPLAY_PRESENT
    if (display_init()) {
        // Rotation so the face is upright on a wrist: the panel is mounted with its
        // long axis across the strap, and this is the one place that fact lives.
        display_set_rotation(SG_DISPLAY_ROTATION);
        // After the codec, which owns the I2C bus the touch controller shares.
        if (!touch_init()) {
            ESP_LOGW(TAG, "touch unavailable; the face is readable but not playable");
        }
    }
#endif  // SG_DISPLAY_PRESENT

    // After the microphone, which speech_start checks for, and after the graph, so a
    // command heard early has something to act on. Not fatal: a board that cannot listen
    // is a board with a console, which is how every other board is driven anyway.
    if (!speech_start(on_speech_command)) {
        ESP_LOGI(TAG, "speech recognition unavailable on this board");
    }

    // Her graph, built once and kept. Not fatal if it will not build: a board that
    // cannot answer is a board that still plays, and it says which of the two happened.
    {
        std::string reply_error;
        g_reply = build_graph(find_embedded_patch("yes-dear"), reply_error);
        if (g_reply == nullptr) {
            ESP_LOGW(TAG, "no reply patch: %s", reply_error.c_str());
        }
    }

    g_sequencer.configure(SG_AUDIO_SAMPLE_RATE);

    // A deployed patch survives power cycles; the embedded demo is the fallback. The
    // graph is built and running either way — what is off is the arpeggiator driving it,
    // so the board is loaded and ready rather than asleep.
    std::string deployed;
    std::string error;
    soundgraph::Graph* graph = nullptr;
    if (load_deployed_patch(deployed)) {
        graph = build_graph(deployed.c_str(), error);
        if (graph == nullptr) {
            ESP_LOGW(TAG, "stored patch no longer builds (%s); using the demo", error.c_str());
        }
    }
    if (graph == nullptr) {
        graph = build_graph(find_embedded_patch("first-synth"), error);
    }
    if (graph == nullptr) {
        ESP_LOGE(TAG, "even the embedded demo failed to build: %s", error.c_str());
    } else {
        g_live_graph.store(graph, std::memory_order_release);
    }

    // The face, once there is a patch to have a face for.
    draw_face();

    // Audio gets its own core; the console shares core 0 with the system.
    xTaskCreatePinnedToCore(audio_task, "sg_audio", 8192, nullptr, configMAX_PRIORITIES - 2,
                            nullptr, 1);
    xTaskCreatePinnedToCore(console_task, "sg_console", 8192, nullptr, 5, nullptr, 0);
    if (touch_available()) {
        xTaskCreatePinnedToCore(touch_task, "sg_touch", 4096, nullptr, 4, nullptr, 0);
    }
}
