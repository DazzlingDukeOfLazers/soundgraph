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

**Stage 2 — `PluginEffect`. Built, 2026-08-25.** Audio in, audio out, sixteen slots,
desktop runtimes only, resolved by identity. The node is in dsp-core; the provider that
actually loads anything is `plugin-host/src/desktop_provider.cpp`, which walks the
platform's plugin folders (and `SOUNDGRAPH_PLUGIN_PATH`, which is how a test points at
plugins nobody installed), opens each candidate, and keeps the one whose identity
matches. `sg-render` picks it up whenever the build has the SDKs, so an offline render
of a patch containing a plugin is a real render through a real plugin.

Proven end to end: a sine through Surge XT Effects renders at peak 0.717 where the
same patch with the plugin unreachable renders at 0.800 — different audio, and the
second says why. Two ctests hold it, both using only artifacts this build makes:
`sg_render_resolves_a_plugin_by_identity` and `sg_render_says_what_it_could_not_find`.

Slot control is demonstrated (2026-08-25). Surge XT hosted as a `PluginInstrument`
with its Global Volume on slot 1 renders at rms 0.068, 0.0043, 0.00082 and 0.00036 as
the slot moves 1.0 → 0.5 → 0.2 → 0.05. It did not work before, and the reason was ours
rather than the plugin's: **a CLAP parameter id is a uint32, so through an int it is
usually negative** — Surge XT's Global Volume is -810883302 — and the provider read
"negative" as "unbound", silently dropping most of the real ids on the machine. From
the outside that was indistinguishable from a slot that did nothing, which is exactly
how it was described here for two stages. Only the -1 a patch writes for an empty slot
means unbound now, and `an_unbound_slot_is_only_the_one_the_patch_marks_unbound` holds
it. A second fix rode along: CLAP publishes plain parameter ranges where VST3
normalises everything, so a slot's 0..1 is mapped onto whatever range the plugin
actually declares.

**Stage 3 — `PluginInstrument`. Built, 2026-08-25.** Decided in favour of the **voice
boundary**: a hosted instrument is the second place in the graph where the polyphonic
world collapses into one signal, exactly as the audio output has always been. The cone
that gets cloned per voice now stops at either, `NodeTypeDescriptor::is_voice_boundary`
says which nodes do that, and the rest fell out of machinery that already existed — the
engine has always given a note receiver the replicator never copied *every* note rather
than one voice's share.

The cost, stated where it is felt: nothing downstream of a hosted instrument is
per-note, so a SoundGraph filter after one filters the whole chord. That is inherent to
hosting a polyphonic instrument. The escape hatch discussed — a per-node switch for
somebody who deliberately wants N copies of a cheap mono plugin so they *can* filter
each note — is not built, and wants a real use before it is.

*Exit test: met. `a_plugin_instrument_is_one_instance_however_many_voices` asks for
eight voices, gets one plugin, and plays a three-note chord into it.*

**Stage 4 — editor. Picking and binding built, 2026-08-25; the plugin's own window
is not.** A plugin node grows a row: a button naming the chosen plugin, and a Slots…
button once there is one. Choosing runs `sg-host --scan` **out of process** — the
editor never loads a plugin, never links the hosting SDKs, and cannot be brought down
by one, which matters more here than anywhere else because the editor is the thing with
unsaved work in it. Both writes are ordinary undo steps, the patch's schema version
lifts to 4 on the first choice, and choosing the same plugin on a second node reuses the
one table entry.

`editor-godot/plugin_picker.gd` keeps the parsing separate from the running, so the
editor suite tests choosing and binding against a canned scan rather than needing Surge
XT installed on whatever machine runs it. `class_name` is deliberately not used: a
headless `--script` run never builds Godot's class cache, so the global would not exist
and the suite could not load.

**Hosting a plugin's editor works (2026-08-25), outside Godot so far.** `sg-host
<plugin> --gui` opens the plugin's own interface in a plain window of ours: Surge XT
draws its whole 1141x711 face, animates, and answers the mouse — clicking Filter 1
opens Surge's own filter-type menu. Dexed reports 866x674 and our own VST3 560x460, so
both formats and three vendors work. That was worth proving here rather than inside the
editor, where a failure would have looked like Godot's fault.

Two host-side lessons, both found by a segfault. A plugin with a face expects the host
to offer **`clap_host_timer_support`** — an editor is a timer and a redraw, and Surge XT
registers one the moment its window opens — and **`clap_host_gui`**; a host offering
neither is a host it was not written against. And `clap_host_thread_check` is
deliberately *not* offered: sg-host does everything on one thread, so every answer it
could give is a lie, and Surge rightly complained about being told it was off the audio
thread during start_processing. Offering nothing lets a plugin keep its own counsel.

Still to do: **giving that window to Godot instead of ours.** The remaining work is a
build change — the Godot extension has to link the hosting code — plus handing over
`DisplayServer.window_get_native_handle` in place of the HWND sg-host creates. The hard
half, making a stranger's editor draw and respond inside a window it did not create, is
done.

## Decided, 2026-08-25

**A patch names a plugin by identity, never by path.** Identity is the pair
(format, id): for CLAP the reverse-DNS string the plugin publishes
(`org.soundgraph.player`), for VST3 the 128-bit class UID as hex
(`ABCDEF019182FAEB566D624153675854`). Both are what `sg-host --list` already prints,
so the resolver has been proven against four vendors before a line of it exists.

Beside the identity, and never load-bearing, sits a hint block: vendor, display name,
version, and the path it was last seen at. A path is a fine thing to *remember* and a
terrible thing to *depend on* — it is what lets the diagnostic say "this patch wants
Surge XT by Surge Synth Team, last seen in Common Files" instead of a bare UID. The
runtime resolves by scanning the standard locations once and matching on identity; the
hint is consulted only to speed that up, and its being wrong is never an error.

**The plugin's window is embedded in Godot.** The editor opens a real OS sub-window
(a Godot `Window` with subwindow embedding off), takes its native handle through
`DisplayServer.window_get_native_handle`, and parents the plugin's HWND or NSView into
it — the same act `gui_set_parent` already performs for our own panel, pointed at a
window the editor owns rather than a DAW's. The plugin then sits in a window Godot
positions, titles and closes, which is what makes it feel like part of the editor
rather than a stray application.

This is the ambitious option and it is chosen knowingly. The Windows half is the same
`SetParent` plus `WS_CHILD` restyle already working in the plugin; macOS `addSubview:`
into a Godot-owned view is the part with genuine risk, and Linux is a third story
again. If a compositor fights us, the fallback — a plain top-level window that Godot
merely knows about — costs an afternoon and no design change, because nothing else
depends on where that HWND lives.

**Block size: pass 64 straight through, buffer nothing.** The design originally said
this was a measurement question nobody should answer from an armchair, so it was
measured, with `sg-host --block` across every third-party plugin on the machine:

| plugin | 32 | 64 | 128 | 256 | 512 |
|---|---|---|---|---|---|
| Surge XT (JUCE) | 0.089042 | 0.088780 | 0.088786 | 0.088606 | 0.088308 |
| Dexed (JUCE) | 0.044621 | 0.044618 | 0.044618 | 0.044564 | 0.044553 |
| ModulAir (no framework) | 0.070195 | 0.070195 | 0.070196 | 0.070185 | 0.070005 |

RMS of one second at 48 kHz. The spread across a sixteen-fold change in block size is
in the fourth decimal — block-boundary jitter in envelopes and modulation, not
misbehaviour. The received wisdom that plugins break below 128 frames is not true of
any plugin we can test.

Cost says the same. Sixty seconds of audio rendered in 502 ms at block 64 and 486 ms
at block 512 for Surge XT, 703 ms and 705 ms for ModulAir: no argument for buffering
there either.

So the node hands the plugin the graph's own 64 frames and adds no latency to anything.
An optional per-node block size stays in the schema, defaulting to zero meaning
"native", as the escape hatch for the plugin that eventually proves the folklore right
— but it is not the default, because three vendors and two frameworks say it needn't be.

**It ships before Knobcon.** Stage 2 goes into the pre-show plan. What that costs on
stage is a sentence: SoundGraph patches run unchanged on four targets, *and* a patch
may invite a desktop plugin in, which is the one thing that stays where it was
invited. Said that way it is a feature with a boundary, which is what it is. Said
carelessly it sounds like the portability claim developed an asterisk, which is what
it must not become.

## The plugin's own panel, inside the editor

Sixteen numbered slots are a mixing desk bolted over the front of an instrument. The
plugin knows how it wants to be operated and has spent years drawing it; the editor's
job is to get out of the way and lend it a window.

**Where the hosting lives.** The Godot extension links the loaders directly. That is a
reversal of the rule the rest of this feature follows — scanning happens out of process,
because opening every plugin on a machine is the act that hangs — and the reason is
simple: a plugin being *played* has to be in the process that owns the audio graph, and
a plugin being *drawn* has to be in the process that owns the window. There is no pipe
that makes either of those remote.

The cost is stated rather than hidden: a plugin that crashes now takes the editor with
it. The isolation that remains is the isolation that matters most — the scan, which is
where an unknown machine's worth of strangers' code gets opened for the first time.

`plugin-host/plugin-host.cmake` is what made this possible. The host library used to be
a guest in the plugin's own build, borrowing clap-wrapper's `base-sdk-vst3`; it now
finds the SDKs and compiles the host-side subset of the VST3 SDK itself, so any build
can call `soundgraph_add_plugin_host()`. A host that depends on the build of the plugin
it is meant to load was backwards anyway.

**How the handle travels.** Godot makes a real operating-system window, `DisplayServer`
reports its native handle, and that handle passes through `HostedPluginInstance::open_gui`
— which dsp-core declares and never looks at — to the loader, which knows it is an HWND
on Windows and an NSView on macOS. The core's promise is intact: it knows no more about
windows than it does about DLLs.

**Three things that had to be learned.**

- Godot draws its own subwindows *inside* the main viewport by default, and an embedded
  subwindow has no operating-system window behind it. `gui_embed_subwindows` is turned
  off while a panel is open and put back after — after, meaning on `tree_exited`, because
  freeing is deferred and Godot refuses the change while a child window is still shown.
- The plugin fills whatever it is handed, corner to corner, with no portable way to ask
  it to occupy a rectangle instead. So it gets a window of its own rather than a panel in
  the editor — which is also what every DAW does, so it is what the hands expect.
- Plugins ask in real pixels and are DPI-aware. Surge XT asks `sg-host` for 1141x711 and
  Godot for 2282x1422, on the same machine, because Godot's process is per-monitor DPI
  aware and sg-host's is not. Both are right. The request is clamped to the usable screen
  anyway: a window larger than the screen is one whose title bar cannot be reached.

**The gap this opens, said out loud.** A graph edit rebuilds the graph, which re-acquires
every plugin, which discards whatever the user did inside the plugin's panel — because
`PluginDescription::state` is in the schema and nothing writes it yet. Before the panel
existed this was theoretical; now it is the first thing a user will hit, and the editor
says so when it happens rather than letting a panel vanish unexplained. Saving and
restoring plugin state is the next piece of work, not a defect in this one.

## Still open

- **Latency compensation.** Plugins report latency and the graph has no notion of it.
  Irrelevant for a reverb, audible the moment two paths run in parallel and only one
  has a plugin in it. Stage 2 can report latency and ignore it; Stage 3 cannot.
- **Plugin state is not saved.** `PluginDescription::state` exists in the schema and
  nothing reads or writes it. Every graph edit therefore returns the plugin to its
  defaults. This was theoretical until the panel shipped; it is now the most visible
  thing missing.
- **How much state is too much.** The embedded-state ceiling wants a number taken from
  real plugin presets rather than invented here.
- **Resizing.** The host tells the plugin nothing about the window size, so dragging the
  panel's edge stretches the frame and not the plugin. Both formats have a call for it
  (`clap_plugin_gui::set_size`, `IPlugView::onSize`) and `HostedPlugin` has no verb for
  it yet.
