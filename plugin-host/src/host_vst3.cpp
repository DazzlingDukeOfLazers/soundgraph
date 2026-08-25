// The VST3 side of sg-host.
//
// VST3 is COM without the registry: a module exports a factory, the factory hands out
// class instances by UID, and everything after that is queryInterface. Steinberg's own
// hosting helpers (module.h, hostclasses, eventlist, parameterchanges) do the loading
// and the boilerplate containers, so what remains here is the sequence a plugin
// actually requires — and the sequence is the part that bites:
//
//   component->initialize(host) → find the controller → connect the two → activate the
//   buses → setupProcessing → setActive → setProcessing
//
// Skip the bus activation and a plugin renders silence into buffers it was never told
// to write. Skip the component/controller connection and parameter changes reach the
// processor but never the UI's model, which is how a host ends up with a plugin whose
// automation "works" and whose displayed values never move.
//
// Two model differences from CLAP are worth stating because they leak into the CLI:
// VST3 parameter values are always normalised 0..1 (the plain value exists only as a
// string the plugin formats), and the controller — not the processor — is the thing
// that knows a parameter exists at all.
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <string>
#include <thread>
#include <vector>

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#endif

#include "hosted_plugin.h"

#include "base/source/fstring.h"
#include "pluginterfaces/base/funknown.h"
#include "pluginterfaces/base/ipluginbase.h"
#include "pluginterfaces/vst/ivstaudioprocessor.h"
#include "pluginterfaces/vst/ivstcomponent.h"
#include "pluginterfaces/vst/ivsteditcontroller.h"
#include "pluginterfaces/gui/iplugview.h"
#include "pluginterfaces/vst/ivstevents.h"
#include "pluginterfaces/vst/vsttypes.h"
#include "public.sdk/source/vst/hosting/eventlist.h"
#include "public.sdk/source/vst/hosting/hostclasses.h"
#include "public.sdk/source/common/memorystream.h"
#include "public.sdk/source/vst/hosting/module.h"
#include "public.sdk/source/vst/hosting/parameterchanges.h"
#include "public.sdk/source/vst/hosting/processdata.h"

using namespace Steinberg;
using namespace Steinberg::Vst;

namespace soundgraph::host {
namespace {

std::string from_utf16(const TChar* text) {
    if (!text) return {};
    String string(text);
    string.toMultiByte(kCP_Utf8);
    return string.text8() ? string.text8() : "";
}

class Vst3Plugin final : public HostedPlugin {
public:
    ~Vst3Plugin() override {
        deactivate();
        if (controller_ && component_) {
            // Symmetry matters here: a plugin that was connected and never
            // disconnected can hold references that outlive the module, and the
            // module unloads at the end of this destructor.
            FUnknownPtr<IConnectionPoint> component_point(component_);
            FUnknownPtr<IConnectionPoint> controller_point(controller_);
            if (component_point && controller_point) {
                component_point->disconnect(controller_point);
                controller_point->disconnect(component_point);
            }
        }
        if (controller_ && controller_ != FUnknownPtr<IEditController>(component_).getInterface()) {
            controller_->terminate();
        }
        if (component_) component_->terminate();
        processor_ = nullptr;
        controller_ = nullptr;
        component_ = nullptr;
        module_.reset();
    }

    bool open(const std::string& path, int index, std::string& error) {
        module_ = VST3::Hosting::Module::create(path, error);
        if (!module_) {
            if (error.empty()) error = "could not load " + path;
            return false;
        }

        const auto& factory = module_->getFactory();
        factory.setHostContext(host_context());

        std::vector<VST3::Hosting::ClassInfo> effects;
        for (const auto& info : factory.classInfos()) {
            if (info.category() != kVstAudioEffectClass) continue;
            effects.push_back(info);
            available_.push_back({info.ID().toString(), info.name(), info.vendor(), "VST3"});
        }
        if (effects.empty()) {
            error = path + " declares no audio effect classes";
            return false;
        }
        if (index < 0 || static_cast<std::size_t>(index) >= effects.size()) {
            error = "no plugin at index " + std::to_string(index);
            return false;
        }
        const auto& info = effects[static_cast<std::size_t>(index)];
        chosen_ = available_[static_cast<std::size_t>(index)];

        component_ = factory.createInstance<IComponent>(info.ID());
        if (!component_) {
            error = "could not instantiate " + info.name();
            return false;
        }
        if (component_->initialize(host_context()) != kResultOk) {
            error = info.name() + " refused component initialize";
            return false;
        }

        processor_ = FUnknownPtr<IAudioProcessor>(component_);
        if (!processor_) {
            error = info.name() + " has no IAudioProcessor";
            return false;
        }

        // The controller is either the component wearing a second hat (single-component
        // effects) or a separate class the component names.
        controller_ = FUnknownPtr<IEditController>(component_);
        if (!controller_) {
            TUID controller_uid;
            if (component_->getControllerClassId(controller_uid) == kResultOk) {
                controller_ = factory.createInstance<IEditController>(
                    VST3::UID(controller_uid));
                if (controller_ &&
                    controller_->initialize(host_context()) != kResultOk) {
                    error = info.name() + " refused controller initialize";
                    return false;
                }
                separate_controller_ = true;
            }
        }
        if (controller_) {
            FUnknownPtr<IConnectionPoint> component_point(component_);
            FUnknownPtr<IConnectionPoint> controller_point(controller_);
            if (component_point && controller_point) {
                component_point->connect(controller_point);
                controller_point->connect(component_point);
            }
        }

        // Output channel count comes from the first output bus; a plugin with no
        // output bus is one this host has nothing to say about.
        channels_ = 2;
        if (component_->getBusCount(kAudio, kOutput) > 0) {
            BusInfo bus{};
            if (component_->getBusInfo(kAudio, kOutput, 0, bus) == kResultOk) {
                channels_ = bus.channelCount;
            }
        }
        return true;
    }

    const std::vector<PluginDescription>& available() const override { return available_; }
    const PluginDescription& chosen() const override { return chosen_; }
    int channel_count() const override { return channels_; }

    std::vector<Parameter> parameters() const override {
        std::vector<Parameter> result;
        if (!controller_) return result;
        const int32 count = controller_->getParameterCount();
        for (int32 i = 0; i < count; ++i) {
            ParameterInfo info{};
            if (controller_->getParameterInfo(i, info) != kResultOk) continue;
            // Every VST3 parameter is normalised; the range printed is the range a
            // host may set, which is what --param needs to agree with.
            result.push_back({info.id, from_utf16(info.title), from_utf16(info.units), 0.0, 1.0,
                              info.defaultNormalizedValue,
                              (info.flags & ParameterInfo::kIsHidden) != 0});
        }
        return result;
    }

    bool activate(double sample_rate, int block_frames, std::string& error) override {
        // Buses a host does not activate are buses a plugin may decline to fill.
        for (int32 i = 0; i < component_->getBusCount(kAudio, kOutput); ++i) {
            component_->activateBus(kAudio, kOutput, i, true);
        }
        for (int32 i = 0; i < component_->getBusCount(kAudio, kInput); ++i) {
            component_->activateBus(kAudio, kInput, i, true);
        }
        for (int32 i = 0; i < component_->getBusCount(kEvent, kInput); ++i) {
            component_->activateBus(kEvent, kInput, i, true);
        }

        ProcessSetup setup{};
        setup.processMode = kRealtime;
        setup.symbolicSampleSize = kSample32;
        setup.maxSamplesPerBlock = block_frames;
        setup.sampleRate = sample_rate;
        if (processor_->setupProcessing(setup) != kResultOk) {
            error = "setupProcessing refused " + std::to_string(sample_rate) + " Hz / " +
                    std::to_string(block_frames) + " frames";
            return false;
        }
        if (component_->setActive(true) != kResultOk) {
            error = "the component refused to activate";
            return false;
        }
        if (processor_->setProcessing(true) != kResultOk) {
            // Not fatal: some plugins answer kNotImplemented and process anyway.
            std::printf("  [note] setProcessing was declined; processing anyway\n");
        }

        if (!data_.prepare(*component_, block_frames, kSample32)) {
            error = "could not prepare the process data buffers";
            return false;
        }
        events_.setMaxSize(kMaxEventsPerBlock);
        data_.inputEvents = &events_;
        data_.inputParameterChanges = &parameter_changes_;
        data_.processMode = kRealtime;
        data_.symbolicSampleSize = kSample32;
        active_ = true;
        return true;
    }

    void deactivate() override {
        if (!active_) return;
        processor_->setProcessing(false);
        component_->setActive(false);
        events_.setMaxSize(0);
        data_.inputEvents = nullptr;
        data_.inputParameterChanges = nullptr;
        data_.unprepare();
        active_ = false;
    }

    void queue_parameter(uint32_t id, double value) override {
        int32 index = 0;
        if (auto* queue = parameter_changes_.addParameterData(id, index)) {
            int32 point = 0;
            queue->addPoint(0, value, point);
        }
        // The controller keeps its own copy of every value, and a host that updates
        // only the processor leaves the two disagreeing — the plugin's own UI would
        // show the old number.
        if (controller_) controller_->setParamNormalized(id, value);
    }

    void queue_note(int key, bool on) override {
        Event event{};
        event.busIndex = 0;
        event.sampleOffset = 0;
        event.ppqPosition = 0.0;
        event.flags = Event::kIsLive;
        if (on) {
            event.type = Event::kNoteOnEvent;
            event.noteOn.channel = 0;
            event.noteOn.pitch = static_cast<int16>(key);
            event.noteOn.tuning = 0.0f;
            event.noteOn.velocity = 0.9f;
            event.noteOn.length = 0;
            event.noteOn.noteId = -1;
        } else {
            event.type = Event::kNoteOffEvent;
            event.noteOff.channel = 0;
            event.noteOff.pitch = static_cast<int16>(key);
            event.noteOff.velocity = 0.0f;
            event.noteOff.noteId = -1;
            event.noteOff.tuning = 0.0f;
        }
        events_.addEvent(event);
    }

    bool process(int frames, std::vector<std::vector<float>>& channels) override {
        // Silence every input bus, every block. HostProcessData allocates these
        // buffers but does not clear them, and a plugin handed uninitialised memory
        // processes it as audio: Surge XT's effects rack, given nothing, produced a
        // full-scale roar out of whatever the allocator happened to be holding. Every
        // block rather than once, because VST3 permits processing in place — a plugin
        // may legitimately write over its own input.
        for (int32 bus = 0; bus < data_.numInputs; ++bus) {
            AudioBusBuffers& buffers = data_.inputs[bus];
            for (int32 channel = 0; channel < buffers.numChannels; ++channel) {
                if (buffers.channelBuffers32[channel] != nullptr) {
                    std::fill_n(buffers.channelBuffers32[channel], frames, 0.0f);
                }
            }
            // And say so: silenceFlags is how a host tells a plugin the quiet is
            // deliberate, which lets it skip work rather than guess.
            buffers.silenceFlags = buffers.numChannels >= 64
                                       ? ~static_cast<uint64>(0)
                                       : (static_cast<uint64>(1) << buffers.numChannels) - 1;
        }
        data_.numSamples = frames;
        const tresult result = processor_->process(data_);

        // HostProcessData owns the buffers the plugin wrote into; copying out here
        // keeps the caller's channel vectors the single shape main.cpp deals with.
        if (data_.numOutputs > 0 && data_.outputs && data_.outputs[0].channelBuffers32) {
            const int32 available = data_.outputs[0].numChannels;
            for (std::size_t c = 0; c < channels.size(); ++c) {
                const bool have = static_cast<int32>(c) < available &&
                                  data_.outputs[0].channelBuffers32[c] != nullptr;
                if (have) {
                    std::copy_n(data_.outputs[0].channelBuffers32[c], frames, channels[c].data());
                } else {
                    std::fill_n(channels[c].data(), frames, 0.0f);
                }
            }
        }

        events_.clear();
        parameter_changes_.clearQueue();
        return result == kResultOk || result == kNotImplemented;
    }

    bool process_audio(const float* const* inputs, int input_channels, float* const* outputs,
                       int output_channels, int frames) override {
        // Fill the input buses from the caller rather than silencing them. Same
        // discipline as the silent path: every channel gets defined audio, because a
        // plugin handed an untouched buffer processes whatever was in that memory.
        for (int32 bus = 0; bus < data_.numInputs; ++bus) {
            AudioBusBuffers& buffers = data_.inputs[bus];
            uint64 silent = 0;
            for (int32 channel = 0; channel < buffers.numChannels; ++channel) {
                float* destination = buffers.channelBuffers32[channel];
                if (destination == nullptr) continue;
                const float* source =
                    (bus == 0 && inputs != nullptr && channel < input_channels)
                        ? inputs[channel]
                        : nullptr;
                if (source != nullptr) {
                    std::copy_n(source, frames, destination);
                } else {
                    std::fill_n(destination, frames, 0.0f);
                    silent |= static_cast<uint64>(1) << channel;
                }
            }
            buffers.silenceFlags = silent;
        }

        data_.numSamples = frames;
        const tresult result = processor_->process(data_);

        if (data_.numOutputs > 0 && data_.outputs && data_.outputs[0].channelBuffers32) {
            const int32 available = data_.outputs[0].numChannels;
            for (int channel = 0; channel < output_channels; ++channel) {
                if (channel < available && data_.outputs[0].channelBuffers32[channel] != nullptr) {
                    std::copy_n(data_.outputs[0].channelBuffers32[channel], frames,
                                outputs[channel]);
                } else {
                    std::fill_n(outputs[channel], frames, 0.0f);
                }
            }
        }

        events_.clear();
        parameter_changes_.clearQueue();
        return result == kResultOk || result == kNotImplemented;
    }

    int latency_frames() override {
        // getLatencySamples is a processor question and, per the SDK, is only answerable
        // once setupProcessing has run — which is what activate() does here.
        if (!processor_ || !active_) return 0;
        return static_cast<int>(processor_->getLatencySamples());
    }

    // ---- the plugin's own memory ------------------------------------------------
    //
    // The component owns the state; the controller keeps a shadow of it for the UI.
    // Restoring only the first gives a plugin that sounds right and looks wrong — the
    // knobs still show whatever they showed before — which is exactly the class of bug
    // the component/controller connection above exists to prevent. So both are told,
    // from the same bytes, with the stream rewound in between because setState leaves
    // the cursor at the end.
    //
    // Steinberg's MemoryStream is used rather than a stream of our own: it is already
    // compiled into this library, and IBStream has more corners than it looks.

    bool save_state(std::string& bytes) override {
        if (!component_) return false;
        MemoryStream stream;
        if (component_->getState(&stream) != kResultOk) return false;
        bytes.assign(stream.getData(), static_cast<std::size_t>(stream.getSize()));
        return true;
    }

    bool load_state(const std::string& bytes) override {
        if (!component_ || bytes.empty()) return false;
        // Copied because MemoryStream's reuse constructor takes a mutable pointer and
        // will not promise not to touch it. One allocation on a preset load is nothing;
        // a const_cast into somebody else's stream implementation is a bet.
        std::vector<char> buffer(bytes.begin(), bytes.end());
        MemoryStream stream(buffer.data(), static_cast<TSize>(buffer.size()));
        stream.seek(0, IBStream::kIBSeekSet, nullptr);
        if (component_->setState(&stream) != kResultOk) return false;
        if (controller_) {
            stream.seek(0, IBStream::kIBSeekSet, nullptr);
            controller_->setComponentState(&stream);
        }
        return true;
    }

    // ---- the plugin's own face -------------------------------------------------
    // VST3 puts the editor on the *controller*, not the processor, which is the same
    // split that decides where parameters live. A view is created, attached to a
    // platform window, and told nothing else — resizing is a conversation this host
    // does not yet hold.
    bool has_gui() override {
        if (!controller_) return false;
        IPtr<IPlugView> view = owned(controller_->createView(ViewType::kEditor));
        return view != nullptr;
    }

    bool open_gui(void* parent) override {
        if (!controller_ || parent == nullptr) return false;
        view_ = owned(controller_->createView(ViewType::kEditor));
        if (!view_) return false;
#if defined(_WIN32)
        const FIDString platform = kPlatformTypeHWND;
#elif defined(__APPLE__)
        const FIDString platform = kPlatformTypeNSView;
#else
        const FIDString platform = kPlatformTypeX11EmbedWindowID;
#endif
        if (view_->isPlatformTypeSupported(platform) != kResultTrue) {
            view_ = nullptr;
            return false;
        }
        if (view_->attached(parent, platform) != kResultOk) {
            view_ = nullptr;
            return false;
        }
        return true;
    }

    void close_gui() override {
        if (!view_) return;
        view_->removed();
        view_ = nullptr;
    }

    bool gui_size(unsigned& width, unsigned& height) override {
        if (!view_) return false;
        ViewRect rect{};
        if (view_->getSize(&rect) != kResultOk) return false;
        width = static_cast<unsigned>(rect.getWidth());
        height = static_cast<unsigned>(rect.getHeight());
        return true;
    }

    void main_thread_tick() override { pump_messages(); }

    void settle(int milliseconds) override {
        // Wall clock has to pass, not just messages: the wrapper's idle work rides a
        // 20 ms timer, and pumping an empty queue in a tight loop would return before
        // that timer ever posted. See the note on HostedPlugin::settle.
        const auto deadline =
            std::chrono::steady_clock::now() + std::chrono::milliseconds(milliseconds);
        while (std::chrono::steady_clock::now() < deadline) {
            pump_messages();
            std::this_thread::sleep_for(std::chrono::milliseconds(2));
        }
    }

private:
    static constexpr int32 kMaxEventsPerBlock = 2048;

    // A plugin's deferred main-thread work can arrive as a window message — on
    // Windows clap-wrapper posts itself WM_TIMER through a message-only window — and
    // a host that never pumps is a host that never delivers it.
    static void pump_messages() {
#if defined(_WIN32)
        MSG message;
        while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
#endif
    }

    // HostApplication derives from IHostApplication, which derives from FUnknown —
    // an unambiguous upcast, and the SDK offers no unknownCast() on this class.
    FUnknown* host_context() { return static_cast<IHostApplication*>(&host_application_); }

    IPtr<IPlugView> view_;
    VST3::Hosting::Module::Ptr module_;
    HostApplication host_application_;
    IPtr<IComponent> component_;
    IPtr<IEditController> controller_;
    FUnknownPtr<IAudioProcessor> processor_;
    HostProcessData data_;
    EventList events_;
    ParameterChanges parameter_changes_;
    std::vector<PluginDescription> available_;
    PluginDescription chosen_;
    int channels_ = 2;
    bool active_ = false;
    bool separate_controller_ = false;
};

}  // namespace

std::unique_ptr<HostedPlugin> open_vst3(const std::string& path, int index,
                                        std::string& error) {
    auto plugin = std::make_unique<Vst3Plugin>();
    if (!plugin->open(path, index, error)) return nullptr;
    return plugin;
}

}  // namespace soundgraph::host
