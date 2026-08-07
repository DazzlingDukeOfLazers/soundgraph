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
//   arp on|off          the built-in arpeggiator (on at boot, so power-up makes sound)
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

#include "board_config.h"
#include "codec_init.h"
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

extern "C" {
extern const char _binary_first_synth_json_start[];
extern const char _binary_sine_json_start[];
extern const char _binary_saw_json_start[];
extern const char _binary_square_json_start[];
extern const char _binary_noise_json_start[];
extern const char _binary_noise_pink_json_start[];
extern const char _binary_lfo_json_start[];
extern const char _binary_adsr_json_start[];
extern const char _binary_filter_sweep_json_start[];
extern const char _binary_delay_feedback_json_start[];
}

struct EmbeddedPatch {
    const char* name;
    const char* text;
};

const EmbeddedPatch kEmbeddedPatches[] = {
    {"first-synth", _binary_first_synth_json_start},
    {"sine", _binary_sine_json_start},
    {"saw", _binary_saw_json_start},
    {"square", _binary_square_json_start},
    {"noise", _binary_noise_json_start},
    {"noise-pink", _binary_noise_pink_json_start},
    {"lfo", _binary_lfo_json_start},
    {"adsr", _binary_adsr_json_start},
    {"filter-sweep", _binary_filter_sweep_json_start},
    {"delay-feedback", _binary_delay_feedback_json_start},
};

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
    std::atomic<bool> running_{true};
};

// ---------------------------------------------------------------------------------
// Shared state
// ---------------------------------------------------------------------------------

std::atomic<soundgraph::Graph*> g_live_graph{nullptr};
Sequencer g_sequencer;
i2s_chan_handle_t g_tx_channel = nullptr;

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

        for (int i = 0; i < kBlock; ++i) {
            float l = left[i];
            float r = right[i];
            l = l > 1.0f ? 1.0f : (l < -1.0f ? -1.0f : l);
            r = r > 1.0f ? 1.0f : (r < -1.0f ? -1.0f : r);
            interleaved[i * 2] = static_cast<int16_t>(l * 32767.0f);
            interleaved[i * 2 + 1] = static_cast<int16_t>(r * 32767.0f);
        }

        std::size_t written = 0;
        // Blocking write: the DMA queue's backpressure is the timing of this loop.
        i2s_channel_write(g_tx_channel, interleaved, sizeof(interleaved), &written, portMAX_DELAY);
    }
}

bool start_i2s() {
    i2s_chan_config_t channel_config = I2S_CHANNEL_DEFAULT_CONFIG(I2S_NUM_AUTO, I2S_ROLE_MASTER);
    if (i2s_new_channel(&channel_config, &g_tx_channel, nullptr) != ESP_OK) {
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
            .din = I2S_GPIO_UNUSED,
            .invert_flags = {.mclk_inv = false, .bclk_inv = false, .ws_inv = false},
        },
    };

    if (i2s_channel_init_std_mode(g_tx_channel, &std_config) != ESP_OK ||
        i2s_channel_enable(g_tx_channel) != ESP_OK) {
        ESP_LOGE(TAG, "could not start I2S on bclk=%d ws=%d dout=%d",
                 SG_I2S_BCLK, SG_I2S_WS, SG_I2S_DOUT);
        return false;
    }
    return true;
}

// ---------------------------------------------------------------------------------
// Patch loading
// ---------------------------------------------------------------------------------

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
    return graph.release();
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

        // Each line is standalone base64 of this block's bytes; the host decodes lines
        // independently and concatenates. Keeps the device free of any big buffer.
        base64_line(reinterpret_cast<const unsigned char*>(left),
                    static_cast<std::size_t>(count) * sizeof(float), encoded);
        std::printf("D %s\n", encoded);
        position += count;
    }
    std::printf("RENDER-END\n");
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
    for (int i = 0; i < byte_count; ++i) {
        int character = std::getchar();
        while (character == EOF) {
            vTaskDelay(pdMS_TO_TICKS(5));
            character = std::getchar();
        }
        text[static_cast<std::size_t>(i)] = static_cast<char>(character);
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
        } else if (command == "vol" && tokens.size() >= 2) {
            if (codec_set_volume(static_cast<float>(std::atof(tokens[1])))) {
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
    esp_err_t nvs_status = nvs_flash_init();
    if (nvs_status == ESP_ERR_NVS_NO_FREE_PAGES || nvs_status == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        nvs_flash_erase();
        nvs_flash_init();
    }

    if (!start_i2s()) {
        ESP_LOGE(TAG, "audio startup failed; the console still works");
    } else if (!codec_init(g_tx_channel, SG_AUDIO_SAMPLE_RATE)) {
        ESP_LOGE(TAG, "codec startup failed; I2S runs but the speaker may stay silent");
    }

    g_sequencer.configure(SG_AUDIO_SAMPLE_RATE);

    // A deployed patch survives power cycles; the embedded demo is the fallback, so a
    // fresh board makes sound the moment it has power.
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

    // Audio gets its own core; the console shares core 0 with the system.
    xTaskCreatePinnedToCore(audio_task, "sg_audio", 8192, nullptr, configMAX_PRIORITIES - 2,
                            nullptr, 1);
    xTaskCreatePinnedToCore(console_task, "sg_console", 8192, nullptr, 5, nullptr, 0);
}
