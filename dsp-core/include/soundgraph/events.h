// SoundGraph — realtime-safe control messaging.
//
// Notes and parameter changes originate on a UI, MIDI or scheduler thread and are
// consumed by the audio thread. They travel through a fixed-capacity single-producer /
// single-consumer ring so that the audio callback never locks and never allocates.
#pragma once

#include <array>
#include <atomic>
#include <cstdint>

namespace soundgraph {

struct NoteEvent {
    enum class Kind : std::uint8_t { NoteOn, NoteOff, AllNotesOff };
    Kind kind = Kind::NoteOn;
    int note = 60;         // MIDI note number
    float velocity = 1.0f; // 0..1
};

struct ControlEvent {
    enum class Kind : std::uint8_t { Note, ParameterSet, ControlChange };
    Kind kind = Kind::Note;

    NoteEvent note{};

    int node_index = -1;
    int parameter_index = -1;
    float value = 0.0f;

    // ControlChange: which controller. 0..127 are MIDI CCs, 128 is the pitch bend
    // wheel wearing a controller number so one table serves the whole surface.
    int cc = -1;
};

// Capacity is generous relative to one audio block: a stuck or bursty producer drops
// messages rather than blocking the audio thread or growing memory.
template <int Capacity>
class SpscQueue {
public:
    static_assert((Capacity & (Capacity - 1)) == 0, "Capacity must be a power of two");

    // Producer side. Returns false if the queue is full; the caller decides whether a
    // dropped message matters (a dropped note-off would, so callers should not ignore it).
    bool push(const ControlEvent& event) {
        const std::uint32_t write = write_.load(std::memory_order_relaxed);
        const std::uint32_t next = write + 1;
        if (next - read_.load(std::memory_order_acquire) > static_cast<std::uint32_t>(Capacity)) {
            return false;
        }
        items_[write & (Capacity - 1)] = event;
        write_.store(next, std::memory_order_release);
        return true;
    }

    // Consumer side, audio thread only.
    bool pop(ControlEvent& out) {
        const std::uint32_t read = read_.load(std::memory_order_relaxed);
        if (read == write_.load(std::memory_order_acquire)) {
            return false;
        }
        out = items_[read & (Capacity - 1)];
        read_.store(read + 1, std::memory_order_release);
        return true;
    }

    void clear() {
        read_.store(write_.load(std::memory_order_acquire), std::memory_order_release);
    }

private:
    std::array<ControlEvent, Capacity> items_{};
    std::atomic<std::uint32_t> write_{0};
    std::atomic<std::uint32_t> read_{0};
};

using ControlQueue = SpscQueue<256>;

}  // namespace soundgraph
