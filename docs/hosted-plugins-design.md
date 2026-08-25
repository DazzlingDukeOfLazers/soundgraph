# Hosted plugins as nodes — design

Somebody else's VST3 or CLAP, sitting inside a SoundGraph patch, wired to our nodes.
Vital as an oscillator bank feeding our filter; Surge XT's reverb on the end of a
drum patch; a MidiCC node turning a knob on a plugin nobody here wrote.

This is the first feature that cannot honour the sentence the whole project is built
on. Every other node runs on all four targets. A hosted plugin is a shared library on
a desktop operating system: it cannot exist on the ESP32, and it cannot exist in the
browser. So the design is mostly about being *honest* about that rather than clever.

Nothing here is built. `sg-host` (see `plugin-host/`) already hosts both formats
headlessly, which is the whole of the machinery; what follows is about where that
machinery is allowed to touch the graph.

## The one decision everything else follows from

**dsp-core describes the node. The runtime supplies the plugin.**

This is not a new idea in this codebase — it is exactly what terminals already do.
`NodeRole::HostAudioSource` and `HostAudioSink` are node types dsp-core fully
describes and cannot implement: the runtime fills their buffers before `process()` and
drains them after. `terminals.cpp` states the principle in its first paragraph: keep
"the one genuinely target-specific thing — how samples reach a device — out of the
nodes themselves."

A hosted plugin has the same shape. dsp-core can know everything about *what* the node
is — a black box with some audio inputs, some audio outputs, maybe a note input, and a
set of control values — without knowing anything about `LoadLibrary`, bundles, COM, or
`clap_entry`. Those live where they already live: in the desktop runtime.

Concretely, dsp-core gains two things and no dependencies:

```cpp
// An opaque plugin, as far as the core is concerned. Pure virtual, std-only.
class HostedPluginInstance {
public:
    virtual ~HostedPluginInstance() = default;
    virtual void prepare(double sample_rate, int max_block) = 0;
    virtual void process(const float* const* inputs, int input_channels,
                         float* const* outputs, int output_channels, int frames) = 0;
    virtual void set_control(int slot, float normalised) = 0;
    virtual void note_on(int note, float velocity) = 0;
    virtual void note_off(int note) = 0;
    virtual int latency_frames() const = 0;
};

// How a runtime offers them. Null on targets that have none.
class PluginProvider {
public:
    virtual ~PluginProvider() = default;
    // Null return is not an error: it is a target saying "not here". The node then
    // prepares as silence and the graph reports it.
    virtual std::unique_ptr<HostedPluginInstance> acquire(const PluginRequest&) = 0;
};
```

Resolution happens exactly where the sampler's buffers already resolve: the graph
looks the plugin up before `prepare()` and hands it down through `PrepareContext`,
the same way `buffer_data` arrives. One mechanism, two uses, no new concept for a
reader to learn.

## Portability stops being implicit

Today "this patch runs everywhere" is true by construction and therefore never stated.
The moment one node type can be absent, it has to become something a patch can be
*asked* about, or the guarantee quietly rots into a slogan.

`NodeTypeDescriptor` gains one field:

```cpp
bool requires_plugin_host;   // true only for the plugin nodes
```

and the validator gains an optional target capability set. A patch using a plugin node
validated against the ESP32 or the browser produces a `Diagnostic` — `Severity::Warning`,
code `plugin_host_unavailable`, message in the house voice: *"This patch plays a plugin,
which this target cannot load. It will be silent here."* Warning rather than Error on
purpose: the patch is not malformed, and refusing to open it would be worse than opening
it honestly. On a target that has no provider, the node prepares as silence and says so
once; it never fails a build.

The board schema already models capabilities (`audio_in`, `psram`, `controls`), so this
extends a pattern rather than inventing one.

## Parameters: fixed slots, again

A plugin can publish thousands of parameters — Surge XT offers 2855 through its VST3,
ModulAir 722 — and `kMaxParameters` is 24. The mapping cannot be one to one and should
not try.

The answer is the one the player plugin already reached from the other direction: a
fixed number of slots, bound to whatever the user chooses. **Sixteen slots**, plus
`bypass`, `mix` and `gain`, leaves headroom under 24. Each slot carries a plugin
parameter id in the patch JSON; the core names them `Slot 1`…`Slot 16` because static
descriptors cannot be renamed per instance, and the editor shows the plugin's own names
because the editor can ask the plugin.

The pleasing consequence: a slot is an ordinary SoundGraph control input, so an LFO, an
envelope or a MidiCC node modulates a third-party plugin with no special case anywhere.
That is the actual point of the feature.

## The patch stays the artifact

A patch that opens differently on another machine is not a patch. So the plugin's own
state — its preset, its wavetable, whatever it considers itself — is **embedded in the
patch JSON**, base64, exactly as the sampler embeds buffers and modules embed
definitions. Identity travels beside it: format, plugin id, vendor and display name, so
a patch can explain what it wanted even on a machine that does not have it.

The cost is real and must be capped: plugin states run to megabytes. A patch that
embeds more than a few megabytes gets a warning, and the ceiling is a number chosen by
measuring real plugins rather than guessed here.

## What we give up, stated plainly

- **Realtime discipline.** dsp-core forbids allocation, locks and I/O in `process()`.
  A third-party plugin obeys none of that: Surge XT allocates, and u-he's Podolski
  will open a modal dialog and wait forever. A patch containing a plugin inherits that
  plugin's behaviour, and no wording in our documentation changes it.
- **Determinism.** Two machines with different plugin versions render differently. The
  golden-vector suite therefore never covers a plugin node.
- **Crashes.** In-process hosting means a plugin fault is our fault, visibly. Out-of-
  process hosting is the industry answer and is out of scope here; it is a much larger
  feature and should be its own design if we ever want it.

## Polyphony is the sharp edge

The engine implements voices by **cloning everything downstream of a NoteInput**.
Cloned sixteen times, a plugin instrument becomes sixteen plugin instances — each
doing its own internal polyphony, sixteen times over. That is not a performance
concern, it is wrong: the plugin has already been told to play all the notes.

Two consequences, and they decide the staging below:

- A plugin **effect** is unaffected. It sits after the voice sum, one instance, no
  question to answer.
- A plugin **instrument** must live outside the per-voice clone, receiving all notes as
  one instance. That is a real change to how the graph builds voices, and it is the
  reason instruments are not first.

## Staged plan, an exit test per stage

**Stage 1 — the harness, already shipped.** `sg-host` hosts both formats, rides the
gate at four tests, and has already found three bugs. Nothing touches the graph. *Exit
test: done — `sg_host_plays_the_built_vst3` and friends are green.*

**Stage 2 — `PluginEffect`.** Audio in, audio out, sixteen slots, desktop runtimes
only, embedded state. No notes, so no polyphony question. *Exit test: a patch with our
own drum kit through Surge XT's reverb renders on Windows and macOS, and the same patch
opens on the ESP32 build with one warning and audible silence rather than a failure.*

**Stage 3 — `PluginInstrument`.** Note input, and the voice-clone exemption that
requires. *Exit test: a plugin instrument plays a chord as one instance, and
`voices` on the NoteInput above it changes nothing about the plugin's own voice count.*

**Stage 4 — editor.** Browse installed plugins, pick one, bind slots, show the
plugin's own window. This is where the feature becomes usable by a person, and it is
deliberately last: everything before it is testable from a command line.

## Open questions, deliberately

- **Where does the plugin's own GUI live?** The editor is Godot; the plugin wants an
  HWND or an NSView. Embedding is possible and unpleasant. A separate top-level window
  is honest and much cheaper, and may simply be right.
- **Does a patch name a plugin by path, or by identity?** Path is fragile across
  machines; identity (format + unique id) needs a scan to resolve. Probably both, with
  identity winning and path as a hint — but this wants a decision before Stage 2 ships,
  not during.
- **Sample-rate and block-size renegotiation.** The graph runs `kBlockSize = 64`.
  Plugins may prefer larger, and some behave badly below 128. Whether the node buffers
  up to a larger block — adding latency — or simply passes 64 through, is a measurement
  question nobody should answer from an armchair.
- **Does any of this ship before Knobcon?** Stage 2 is perhaps a week. It is also the
  first feature that makes the portability claim conditional, which is a thing to say
  on a stage carefully or not at all.
