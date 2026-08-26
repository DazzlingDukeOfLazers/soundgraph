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

    const int got = mic_read(buffer, frames, 2000);
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
        } else if (command == "mic") {
            if (tokens.size() >= 3 && std::strcmp(tokens[1], "gain") == 0) {
                std::printf("%s", mic_set_gain(static_cast<float>(std::atof(tokens[2])))
                                      ? "OK\n"
                                      : "ERR no microphone on this board\n");
            } else {
                command_mic(tokens.size() >= 2 ? std::atoi(tokens[1]) : 250);
            }
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

    // Audio gets its own core; the console shares core 0 with the system.
    xTaskCreatePinnedToCore(audio_task, "sg_audio", 8192, nullptr, configMAX_PRIORITIES - 2,
                            nullptr, 1);
    xTaskCreatePinnedToCore(console_task, "sg_console", 8192, nullptr, 5, nullptr, 0);
}
