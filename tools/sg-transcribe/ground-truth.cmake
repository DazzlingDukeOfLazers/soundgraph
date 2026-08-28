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

# The same melody as an MP3, when one is supplied. Decoding is miniaudio's job rather
# than this project's, so what is guarded here is not the decoder but the build: a
# stray MA_NO_MP3, or a decode-only translation unit going missing, would take MP3
# support away silently and everything else would still pass.
#
# A committed fixture rather than something generated, because there is no MP3 encoder
# anywhere in this tree - which is the same reason the file is mono and short.
if(MP3_FIXTURE AND EXISTS "${MP3_FIXTURE}")
    set(mp3_patch "${SCRATCH}/from-mp3.json")
    execute_process(
        COMMAND "${TRANSCRIBE}" "${MP3_FIXTURE}" --midi "${SCRATCH}/from-mp3.mid"
            --patch "${PATCH}" --out "${mp3_patch}"
            --tempo 60 --division 4 --quiet
        RESULT_VARIABLE mp3_read
    )
    if(NOT mp3_read EQUAL 0)
        message(FATAL_ERROR "sg-transcribe could not read the MP3 fixture")
    endif()

    file(READ "${mp3_patch}" mp3_written)
    string(FIND "${mp3_written}" "\"sequence\"" mp3_at)
    string(SUBSTRING "${mp3_written}" ${mp3_at} -1 mp3_roll)
    string(REGEX MATCHALL "\"note\"[ 	]*:[ 	]*[0-9]+" mp3_fields "${mp3_roll}")
    set(mp3_heard "")
    foreach(field IN LISTS mp3_fields)
        string(REGEX REPLACE "[^0-9]" "" value "${field}")
        list(APPEND mp3_heard ${value})
    endforeach()
    if(NOT mp3_heard STREQUAL melody)
        message(FATAL_ERROR
            "the MP3 did not transcribe to the same melody
"
            "  played ${melody}
"
            "  heard  ${mp3_heard}")
    endif()
    message(STATUS "and the same again from MP3")
endif()

message(STATUS "played and heard ${heard}; MIDI is ${midi_bytes} bytes")
