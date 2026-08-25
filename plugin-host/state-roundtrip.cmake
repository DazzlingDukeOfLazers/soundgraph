# Does a plugin's own state survive being written down and handed back?
#
# Run as a ctest, because the question needs three separate processes to ask: one that
# changes something and saves, one that loads that state and saves again, and a
# comparison. In a single process the plugin never gets destroyed and reopened, which is
# the part that could quietly work by accident.
#
# The middle run is the one that matters. It is given no --param at all, so anything it
# reproduces can only have come out of the state file.

if(NOT DEFINED HOST OR NOT DEFINED PLUGIN)
    message(FATAL_ERROR "state-roundtrip: HOST and PLUGIN are required")
endif()

file(REMOVE_RECURSE ${WORK})
file(MAKE_DIRECTORY ${WORK})

set(ENV{SOUNDGRAPH_PATCHES} ${PATCHES})

function(run_host)
    execute_process(COMMAND ${HOST} ${ARGN}
                    RESULT_VARIABLE code OUTPUT_VARIABLE out ERROR_VARIABLE err)
    if(NOT code EQUAL 0)
        message(FATAL_ERROR "sg-host failed (${code}):\n${out}${err}")
    endif()
    message(STATUS "${out}")
endfunction()

# Opened, told to play a different patch, and asked what it now considers itself.
run_host(${PLUGIN} --seconds 0.3 --note 36 --param Patch=3 --save-state ${WORK}/swapped.state)

# A fresh process, given nothing but those bytes, asked the same question.
run_host(${PLUGIN} --seconds 0.3 --note 36
         --load-state ${WORK}/swapped.state --save-state ${WORK}/restored.state)

# And what it opens with by default, which the two above must not be.
run_host(${PLUGIN} --seconds 0.3 --note 36 --save-state ${WORK}/default.state)

file(SIZE ${WORK}/swapped.state swapped_size)
if(swapped_size EQUAL 0)
    message(FATAL_ERROR "the plugin saved no state at all")
endif()

file(MD5 ${WORK}/swapped.state swapped)
file(MD5 ${WORK}/restored.state restored)
file(MD5 ${WORK}/default.state fresh)

if(NOT swapped STREQUAL restored)
    message(FATAL_ERROR
        "state did not survive the round trip: saved ${swapped}, came back ${restored}")
endif()
if(swapped STREQUAL fresh)
    message(FATAL_ERROR
        "the saved state is the same as a fresh plugin's, so this test proves nothing")
endif()

message(STATUS "state round-tripped: ${swapped_size} bytes, md5 ${swapped}")
