#include "speech.h"

#include "board_config.h"

#if !SG_AUDIO_IN_PRESENT

// No microphone, no listening. Every board without capture hardware compiles the models
// and the recogniser out entirely rather than carrying megabytes it can never use.
bool speech_start(SpeechCommandHandler) { return false; }
bool speech_available() { return false; }
void speech_set_listening(bool) {}
bool speech_listening() { return false; }
const char* speech_phrase(int) { return ""; }
int speech_phrasings(int, const char**, int) { return 0; }

#else

#include <cstring>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "esp_afe_config.h"
#include "esp_afe_sr_iface.h"
#include "esp_afe_sr_models.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "esp_mn_iface.h"
#include "esp_mn_models.h"
#include "esp_mn_speech_commands.h"
#include "esp_vad.h"
#include "model_path.h"

#include "codec_init.h"

namespace {

const char* const TAG = "sg-speech";

// The vocabulary.
//
// Phrases rather than words, on purpose. MultiNet matches phonetically, and a single
// short syllable — "next", "stop" — has too little in it to tell from the room. Two or
// three words give the matcher something to be sure about, and a person something
// natural to say. These are the things a hand would otherwise reach for a knob to do.
//
// Several phrasings per command, which is not padding. "previous patch" was measured at
// nought out of three against a wake word that fired every time — the model accepted the
// phrase and then never matched it, and there is no way to tell that from reading it.
// Some words simply come out of the recogniser worse than their synonyms do, and the
// only way to know which is to say them at it. So each command answers to more than one
// name, and a phrase that turns out to be weak costs a line rather than a feature.
//
// The first phrase for a command is its canonical one — what the console prints and what
// the board reports having heard.
struct Phrase {
    int command;
    const char* text;
};

const Phrase kPhrases[] = {
    {kSpeechNextPatch, "next patch"},
    {kSpeechNextPatch, "next sound"},
    {kSpeechPreviousPatch, "previous patch"},
    {kSpeechPreviousPatch, "last patch"},
    {kSpeechPreviousPatch, "go back"},
    {kSpeechLouder, "turn it up"},
    {kSpeechLouder, "louder please"},
    {kSpeechQuieter, "turn it down"},
    {kSpeechQuieter, "quieter please"},
    {kSpeechStartPlaying, "start playing"},
    {kSpeechStartPlaying, "play the sound"},
    {kSpeechStopPlaying, "stop playing"},
    {kSpeechStopPlaying, "be quiet"},
    {kSpeechHeyMom, "hey mom"},
    {kSpeechHeyMom, "hey mum"},
    {kSpeechHeyMom, "hello mother"},
};

constexpr int kPhraseCount = sizeof(kPhrases) / sizeof(kPhrases[0]);

// The canonical phrase for a command: the first one listed for it.
const char* canonical(int command) {
    for (int i = 0; i < kPhraseCount; ++i) {
        if (kPhrases[i].command == command) return kPhrases[i].text;
    }
    return "";
}

// The recogniser wants 16 kHz; the graph runs the I2S at 48 kHz and the two share a
// clock domain, so the capture cannot simply be reconfigured. Three-to-one it is.
constexpr int kDecimation = SG_AUDIO_SAMPLE_RATE / 16000;

SpeechCommandHandler g_handler = nullptr;
const esp_afe_sr_iface_t* g_afe = nullptr;
esp_afe_sr_data_t* g_afe_data = nullptr;
const esp_mn_iface_t* g_multinet = nullptr;
model_iface_data_t* g_model_data = nullptr;
volatile bool g_listening = false;
volatile bool g_running = false;

// Feeds the front end from the microphone, decimating on the way.
//
// The averaging is a three-tap box filter, which is a poor anti-aliasing filter and an
// entirely adequate one here: it nulls exactly at 16 kHz, speech has almost nothing above
// 8 kHz to fold down, and the alternative is an FIR whose cost would have to come out of
// the same core the graph is rendering on. If recognition ever turns out to be limited by
// this rather than by the room, it is the first thing to replace.
void feed_task(void*) {
    const int chunk = g_afe->get_feed_chunksize(g_afe_data);      // samples at 16 kHz
    const int channels = g_afe->get_feed_channel_num(g_afe_data);
    const int frames = chunk * kDecimation;                       // frames at 48 kHz

    auto* capture = static_cast<int16_t*>(
        heap_caps_malloc(static_cast<std::size_t>(frames) * SG_AUDIO_IN_CHANNELS *
                             sizeof(int16_t),
                         MALLOC_CAP_SPIRAM));
    auto* fed = static_cast<int16_t*>(
        heap_caps_malloc(static_cast<std::size_t>(chunk) * channels * sizeof(int16_t),
                         MALLOC_CAP_SPIRAM));
    if (capture == nullptr || fed == nullptr) {
        ESP_LOGE(TAG, "no room for the feed buffers");
        g_running = false;
        vTaskDelete(nullptr);
        return;
    }

    while (g_running) {
        if (!g_listening) {
            vTaskDelay(pdMS_TO_TICKS(50));
            continue;
        }
        if (mic_read(capture, frames, 1000) <= 0) {
            vTaskDelay(pdMS_TO_TICKS(10));
            continue;
        }
        for (int i = 0; i < chunk; ++i) {
            int sum = 0;
            for (int step = 0; step < kDecimation; ++step) {
                // Channel zero only. Both microphones work, but the front end is
                // configured for one; giving it two would buy beamforming and cost
                // another decimation pass, which is a trade to make with a measurement
                // rather than in advance.
                const std::size_t at =
                    static_cast<std::size_t>(i * kDecimation + step) * SG_AUDIO_IN_CHANNELS;
                sum += capture[at];
            }
            const int16_t value = static_cast<int16_t>(sum / kDecimation);
            for (int channel = 0; channel < channels; ++channel) {
                fed[static_cast<std::size_t>(i) * channels + channel] = value;
            }
        }
        g_afe->feed(g_afe_data, fed);
    }

    heap_caps_free(capture);
    heap_caps_free(fed);
    vTaskDelete(nullptr);
}

// Takes cleaned audio back out and runs the matcher on it.
//
// The matcher runs whenever somebody is talking, rather than only inside a window a wake
// word opened. That is what lets "hey mom" be said on its own — WakeNet words are
// pre-trained models from a fixed list and no "Hey Mom" exists, so a phrase of one's own
// has to be a command, and a command that needs no wake word has to be listened for.
//
// It took two measurements to get here. Matching every chunk starved the idle task and
// the watchdog called it a hang; gating on the AFE's voice detector fixed the quiet room
// and then overran the moment anybody spoke. The reason was not that the matcher is too
// slow — it measures 25.7 ms against a 32 ms slice, which is 0.80x realtime and fits —
// but that it was sharing a core with the front end, which is itself doing noise
// suppression and running WakeNet on every chunk. The two together do not fit; apart they
// do. The front end now runs beside the graph on core 0 and the matcher has core 1.
//
// The wake word still works and still opens a window. What changed is that the matcher no
// longer waits for one.
void fetch_task(void*) {
    bool matching = false;

    while (g_running) {
        afe_fetch_result_t* result = g_afe->fetch(g_afe_data);
        if (result == nullptr || result->ret_value == ESP_FAIL) {
            vTaskDelay(pdMS_TO_TICKS(10));
            continue;
        }

        if (result->wakeup_state == WAKENET_DETECTED) {
            // Still worth saying: it is the clearest sign the room is quiet enough and
            // the board is hearing properly.
            ESP_LOGI(TAG, "awake");
        }

        // No voice gate. It was tried, and it cost more than it saved: the detector
        // opens a fraction late, the matcher then starts halfway into the first word,
        // and a phrase heard from its second syllable is not the phrase. Running on
        // every chunk costs 0.80x of this core and leaves the fifth of it the idle task
        // needs, which is only true because the front end moved to the other core.

        // Once a phrase has started, keep matching through the gaps inside it: the voice
        // detector dips between words, and stopping at every dip would cut every phrase
        // in half. It ends when the matcher has an answer or has waited long enough.
        matching = true;

        const esp_mn_state_t state = g_multinet->detect(g_model_data, result->data);
        if (state == ESP_MN_STATE_DETECTING) {
            continue;
        }

        if (state == ESP_MN_STATE_DETECTED) {
            esp_mn_results_t* results = g_multinet->get_results(g_model_data);
            if (results != nullptr && results->num > 0 && g_handler != nullptr) {
                const int command = results->command_id[0];
                if (command >= 0 && command < kSpeechCommandCount) {
                    g_handler(command, canonical(command), results->prob[0]);
                }
            }
        }

        // Answered or timed out, the matcher starts afresh and waits for a voice again.
        // Timing out is the ordinary case here rather than a failure, so it says nothing.
        g_multinet->clean(g_model_data);
        matching = false;
    }

    vTaskDelete(nullptr);
}

}  // namespace

bool speech_start(SpeechCommandHandler handler) {
    if (!mic_available()) {
        ESP_LOGW(TAG, "no microphone; not listening");
        return false;
    }

    srmodel_list_t* models = esp_srmodel_init("model");
    if (models == nullptr || models->num <= 0) {
        ESP_LOGE(TAG, "the model partition is empty — was srmodels.bin flashed?");
        return false;
    }

    // One microphone, no reference channel. "MR" would give the front end the playback
    // signal to cancel, which is what a smart speaker needs to hear itself over — but
    // this board offers no loopback of what the amplifier is doing, so there is nothing
    // honest to put in that channel. Recognising over our own output is the next problem,
    // and it is a hardware conversation as much as a software one.
    afe_config_t* config = afe_config_init("M", models, AFE_TYPE_SR, AFE_MODE_LOW_COST);
    if (config == nullptr) {
        ESP_LOGE(TAG, "could not configure the audio front end");
        return false;
    }

    g_afe = esp_afe_handle_from_config(config);
    g_afe_data = g_afe != nullptr ? g_afe->create_from_config(config) : nullptr;
    if (g_afe_data == nullptr) {
        ESP_LOGE(TAG, "could not create the audio front end");
        return false;
    }

    char* name = esp_srmodel_filter(models, ESP_MN_PREFIX, ESP_MN_ENGLISH);
    if (name == nullptr) {
        ESP_LOGE(TAG, "no English command model in the partition");
        return false;
    }
    // How long the board stays open for a command after the wake word.
    //
    // Six seconds first, on the reasoning that somebody might need a moment to think.
    // That was wrong in a way the numbers showed plainly: saying the wake word every four
    // and a half seconds produced detected, missed, detected, missed, in perfect
    // alternation. WakeNet is switched off while the window is open, so every second wake
    // word was arriving at a recogniser that was still waiting for the first one's
    // command. A person who says the wake word again has given up on the last one, and
    // the board should have too.
    //
    // Three and a half seconds: long enough for any phrase here — the longest is three
    // short words — plus a moment to draw breath after the wake word, and still shorter
    // than the interval at which somebody who has been ignored says it again.
    g_multinet = esp_mn_handle_from_name(name);
    g_model_data = g_multinet != nullptr ? g_multinet->create(name, 3500) : nullptr;
    if (g_model_data == nullptr) {
        ESP_LOGE(TAG, "could not create the command model %s", name);
        return false;
    }

    // The vocabulary, at runtime. MultiNet7 converts English spelling to phonemes on the
    // chip, so the phrases live here beside the code that acts on them rather than in
    // sdkconfig — which is where MultiNet5 required them, one Kconfig entry per phrase.
    esp_mn_commands_clear();
    esp_mn_commands_alloc(g_multinet, g_model_data);
    for (int i = 0; i < kPhraseCount; ++i) {
        // Several phrases may share one id; the matcher is happy with that and it is how
        // one command comes to have more than one name.
        esp_mn_commands_add(kPhrases[i].command, kPhrases[i].text);
    }
    esp_mn_error_t* refused = esp_mn_commands_update();
    if (refused != nullptr && refused->num > 0) {
        // A phrase the model cannot pronounce is a phrase nobody can say to it. Naming
        // them is the difference between "voice control does not work" and "that one
        // word does not".
        for (int i = 0; i < refused->num; ++i) {
            ESP_LOGE(TAG, "refused phrase: %s", refused->phrases[i]->string);
        }
    }

    g_handler = handler;
    g_running = true;
    g_listening = true;

    // The two halves are split across the cores, and which half goes where is the
    // result of a measurement rather than a preference.
    //
    // Both started on core 1, leaving core 0 to the graph. That put the front end — the
    // AFE's noise suppression and WakeNet, both of which run on every chunk — on the same
    // core as the matcher, which measures at 0.80x realtime on its own. Together they
    // exceed a core, the idle task never runs, and the watchdog calls it a hang.
    //
    // So the front end joins the graph on core 0, which the watchdog dump showed sitting
    // idle while core 1 drowned, and the matcher gets core 1 to itself. The graph is a
    // fixed, small cost with a high priority; the front end is steady; the matcher is the
    // spiky one and now has a core of its own to be spiky in.
    xTaskCreatePinnedToCore(feed_task, "sg_sr_feed", 4096, nullptr, 5, nullptr, 0);
    xTaskCreatePinnedToCore(fetch_task, "sg_sr_fetch", 8192, nullptr, 5, nullptr, 1);

    ESP_LOGI(TAG, "listening for \"Hi ESP\", %d command(s) in %d phrasing(s)",
             kSpeechCommandCount, kPhraseCount);
    return true;
}

bool speech_available() { return g_afe_data != nullptr; }

void speech_set_listening(bool listening) { g_listening = listening; }

bool speech_listening() { return g_listening; }

const char* speech_phrase(int command) { return canonical(command); }

int speech_phrasings(int command, const char** out, int capacity) {
    int found = 0;
    for (int i = 0; i < kPhraseCount && found < capacity; ++i) {
        if (kPhrases[i].command == command) out[found++] = kPhrases[i].text;
    }
    return found;
}

#endif  // SG_AUDIO_IN_PRESENT
