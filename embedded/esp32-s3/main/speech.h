// Command words, recognised on the chip.
//
// A wake word ("Hi ESP") opens a window; inside it, MultiNet matches one of a short list
// of phrases this firmware defines; the match arrives here as an id. Nothing leaves the
// board — no network, no API, no recording kept — which is the whole reason this is
// speech recognition on a microcontroller rather than a microphone pointed at somebody
// else's server.
//
// This is a *control source*, in the same sense as a button or a MIDI CC. It does not
// belong to dsp-core and never will: dsp-core depends on nothing but the C++ standard
// library, and this is several megabytes of Espressif neural network. The graph learns
// nothing about speech; the runtime gains another way to send it events. That is the same
// split hosted plugins use on the desktop.
//
// Every function here is a no-op on a board with no microphone, and says so.
#pragma once

#include <cstdint>

// What the board can be told to do. Ids rather than strings at the call site, so a
// renamed phrase is one edit in speech.cpp and not a search across the firmware.
enum SpeechCommand {
    kSpeechNextPatch = 0,
    kSpeechPreviousPatch,
    kSpeechLouder,
    kSpeechQuieter,
    kSpeechStartPlaying,
    kSpeechStopPlaying,
    // Not an instruction — an address. Calling the board by name makes it duck whatever
    // it is playing and answer, which is the whole of what it does.
    kSpeechHeyMom,
    kSpeechCommandCount,
};

// Called from the recognition task when a phrase matches. Keep it short: it runs on the
// task that is also feeding the recogniser, and anything slow here is a missed word.
using SpeechCommandHandler = void (*)(int command, const char* phrase, float probability);

// Loads the models and starts listening. Returns false when this board has no microphone,
// when the model partition is empty, or when the models will not fit in memory — all of
// which are reportable facts rather than reasons to refuse to boot.
bool speech_start(SpeechCommandHandler handler);

bool speech_available();

// Whether the wake word is currently being listened for. Recognition is not free, and a
// board rendering a heavy patch may want its cycles back.
void speech_set_listening(bool listening);
bool speech_listening();

// ---- hearing over its own voice -------------------------------------------------
// What the board just sent to its own speaker, handed over so the front end can subtract
// it from what the microphone heard.
//
// A smart speaker with no echo cancellation is deaf while it plays, and this board has no
// hardware loopback of its amplifier — but it does not need one, because the audio task
// has the exact samples it wrote. This is that tap. Called from the audio task, once per
// block, and it does nothing but copy into a ring.
void speech_push_playback(const int16_t* interleaved_stereo, int frames);

// How far behind the microphone the reference is assumed to be, in milliseconds.
//
// The sound the microphone hears now left the speaker a little while ago: through the
// output DMA, across the air, back through the input DMA. The canceller estimates the
// rest itself, but it has to be given roughly the right stretch of audio to work on.
// Tunable because the right number is a property of this board and this room, and the
// only way to find it is to try some.
void speech_set_reference_lag(int milliseconds);
int speech_reference_lag();

// Turn the canceller off, which is only worth doing to find out what it was worth.
void speech_set_cancellation(bool on);

// The canonical phrase behind an id, for a console that wants to list what it knows.
const char* speech_phrase(int command);

// Every phrasing a command answers to, written into `out`. Returns how many. A command
// has more than one name because some words come out of the recogniser worse than their
// synonyms do, and which is which is a measurement rather than a guess.
int speech_phrasings(int command, const char** out, int capacity);
