#pragma once

#include <string>
#include <vector>

#include "basic_pitch.h"

namespace transcribe {

// Notes to a Standard MIDI File, format 0. `tempo` decides how seconds map onto ticks;
// it changes nothing about when notes sound, only how the file describes the grid they
// are described against.
bool write_midi(const std::string& path, const std::vector<Note>& notes, double tempo,
                std::string& error);

}  // namespace transcribe
