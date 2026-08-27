# Does the transcriber hear what was actually played?
#
# sg-render is told to play a melody, so the answer is known before the model is asked
# and "it produced some notes" cannot be mistaken for "it worked". The melody leaps an
# octave on purpose: octave errors are the classic failure of every pitch tracker ever
# written, and a scale would hide them.
#
# Run through ctest, and only when sg-transcribe was built at all - see
# sg-transcribe.cmake for why that is conditional.
#
#   cmake -DRENDER=... -DTRANSCRIBE=... -DPATCH=... -DSCRATCH=... -P ground-truth.cmake

# One note a second, six seconds, held for three quarters of each.
set(melody 60 64 67 72 67 64)
set(seconds 6)

file(MAKE_DIRECTORY "${SCRATCH}")
set(wav "${SCRATCH}/ground-truth.wav")
set(midi "${SCRATCH}/ground-truth.mid")
set(patch_out "${SCRATCH}/ground-truth.json")

string(REPLACE ";" "," melody_argument "${melody}")

execute_process(
    COMMAND "${RENDER}" "${PATCH}" "${wav}"
        --seconds ${seconds} --notes ${melody_argument} --gate 0.75 --quiet
    RESULT_VARIABLE rendered
)
if(NOT rendered EQUAL 0)
    message(FATAL_ERROR "sg-render could not play the melody")
endif()

# Tempo 60 with four steps a beat puts one step every 250 ms, so each note of the melody
# is four steps long and starts on a multiple of four. That makes the expected roll
# something that can be written down rather than approximated.
execute_process(
    COMMAND "${TRANSCRIBE}" "${wav}" --midi "${midi}"
        --patch "${PATCH}" --out "${patch_out}"
        --tempo 60 --division 4 --quiet
    RESULT_VARIABLE transcribed
)
if(NOT transcribed EQUAL 0)
    message(FATAL_ERROR "sg-transcribe failed on the rendered melody")
endif()

if(NOT EXISTS "${midi}")
    message(FATAL_ERROR "no MIDI file was written")
endif()
file(SIZE "${midi}" midi_bytes)
if(midi_bytes LESS 40)
    message(FATAL_ERROR "the MIDI file is ${midi_bytes} bytes, which is empty")
endif()

# The roll, read back out of the patch. Only the note numbers in order are checked: the
# exact steps depend on where the model thinks each note began, and a frame either way
# is not a fault.
file(READ "${patch_out}" written)
# Only inside the sequence. A patch is full of the word "note" - a NoteInput node is
# usually called that - and matching the whole file would count things that are not
# notes in the roll.
string(FIND "${written}" "\"sequence\"" sequence_at)
if(sequence_at EQUAL -1)
    message(FATAL_ERROR "no sequence was written into the patch")
endif()
string(SUBSTRING "${written}" ${sequence_at} -1 roll)
string(REGEX MATCHALL "\"note\"[ \t]*:[ \t]*[0-9]+" note_fields "${roll}")
set(heard "")
foreach(field IN LISTS note_fields)
    string(REGEX REPLACE "[^0-9]" "" value "${field}")
    list(APPEND heard ${value})
endforeach()

if(NOT heard STREQUAL melody)
    message(FATAL_ERROR
        "the melody did not survive the round trip\n"
        "  played ${melody}\n"
        "  heard  ${heard}")
endif()

message(STATUS "played and heard ${heard}; MIDI is ${midi_bytes} bytes")
