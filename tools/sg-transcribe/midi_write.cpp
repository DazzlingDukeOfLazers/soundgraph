// A Standard MIDI File, written by hand.
//
// Format 0, one track, one tempo. The whole specification that matters here is: a
// fourteen-byte header, then a track of delta-time-prefixed events, then an end-of-track
// meta event. Variable-length quantities are seven bits at a time, most significant
// first, with the high bit set on every byte but the last.
//
// Written rather than borrowed because the alternative was a MIDI library, and this is
// ninety lines. The editor's own reader takes what it produces, which is the check that
// matters - see the note in README.md about the round trip.
#include "midi_write.h"

#include <algorithm>
#include <cmath>
#include <cstdio>

namespace transcribe {
namespace {

// Ticks per quarter note. 480 is the usual choice and divides cleanly by everything a
// musician is likely to want.
constexpr int kTicksPerQuarter = 480;

void put_u32(std::vector<unsigned char>& out, unsigned int value) {
    out.push_back(static_cast<unsigned char>((value >> 24) & 0xff));
    out.push_back(static_cast<unsigned char>((value >> 16) & 0xff));
    out.push_back(static_cast<unsigned char>((value >> 8) & 0xff));
    out.push_back(static_cast<unsigned char>(value & 0xff));
}

void put_u16(std::vector<unsigned char>& out, unsigned int value) {
    out.push_back(static_cast<unsigned char>((value >> 8) & 0xff));
    out.push_back(static_cast<unsigned char>(value & 0xff));
}

// Seven bits at a time, high bit set on every byte but the last.
void put_varlen(std::vector<unsigned char>& out, unsigned int value) {
    unsigned char buffer[5];
    int count = 0;
    buffer[count++] = static_cast<unsigned char>(value & 0x7f);
    value >>= 7;
    while (value > 0) {
        buffer[count++] = static_cast<unsigned char>((value & 0x7f) | 0x80);
        value >>= 7;
    }
    for (int i = count - 1; i >= 0; --i) out.push_back(buffer[i]);
}

struct Event {
    unsigned int tick;
    bool on;
    int pitch;
    int velocity;
};

}  // namespace

bool write_midi(const std::string& path, const std::vector<Note>& notes, double tempo,
                std::string& error) {
    const double seconds_per_tick = 60.0 / tempo / kTicksPerQuarter;

    std::vector<Event> events;
    for (const Note& note : notes) {
        const unsigned int on = static_cast<unsigned int>(
            std::max(0.0, note.start_seconds / seconds_per_tick));
        unsigned int off = static_cast<unsigned int>(
            std::max(0.0, note.end_seconds / seconds_per_tick));
        if (off <= on) off = on + 1;   // a note nobody can hear is not a note
        const int velocity = std::max(1, std::min(127,
            static_cast<int>(std::lround(note.amplitude * 127.0))));
        events.push_back({on, true, note.pitch, velocity});
        events.push_back({off, false, note.pitch, 0});
    }
    // Note-offs before note-ons at the same tick, so a repeated pitch retriggers rather
    // than being switched off by its own predecessor a moment after it starts.
    std::sort(events.begin(), events.end(), [](const Event& a, const Event& b) {
        if (a.tick != b.tick) return a.tick < b.tick;
        return static_cast<int>(a.on) < static_cast<int>(b.on);
    });

    std::vector<unsigned char> track;

    // Tempo, as microseconds per quarter note.
    const unsigned int micros = static_cast<unsigned int>(std::lround(60000000.0 / tempo));
    put_varlen(track, 0);
    track.push_back(0xff);
    track.push_back(0x51);
    track.push_back(0x03);
    track.push_back(static_cast<unsigned char>((micros >> 16) & 0xff));
    track.push_back(static_cast<unsigned char>((micros >> 8) & 0xff));
    track.push_back(static_cast<unsigned char>(micros & 0xff));

    unsigned int last = 0;
    for (const Event& event : events) {
        put_varlen(track, event.tick - last);
        last = event.tick;
        track.push_back(static_cast<unsigned char>(event.on ? 0x90 : 0x80));
        track.push_back(static_cast<unsigned char>(event.pitch & 0x7f));
        track.push_back(static_cast<unsigned char>(event.velocity & 0x7f));
    }

    put_varlen(track, 0);
    track.push_back(0xff);
    track.push_back(0x2f);
    track.push_back(0x00);

    std::vector<unsigned char> file;
    file.push_back('M'); file.push_back('T'); file.push_back('h'); file.push_back('d');
    put_u32(file, 6);
    put_u16(file, 0);                  // format 0
    put_u16(file, 1);                  // one track
    put_u16(file, kTicksPerQuarter);
    file.push_back('M'); file.push_back('T'); file.push_back('r'); file.push_back('k');
    put_u32(file, static_cast<unsigned int>(track.size()));
    file.insert(file.end(), track.begin(), track.end());

    std::FILE* handle = std::fopen(path.c_str(), "wb");
    if (handle == nullptr) {
        error = "could not open " + path + " for writing";
        return false;
    }
    const size_t written = std::fwrite(file.data(), 1, file.size(), handle);
    std::fclose(handle);
    if (written != file.size()) {
        error = "could not write all of " + path;
        return false;
    }
    return true;
}

}  // namespace transcribe
