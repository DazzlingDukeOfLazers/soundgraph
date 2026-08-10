# Each suite is a standalone executable; there is no test framework dependency.
function(soundgraph_add_test name)
    add_executable(${name} ${name}.cpp)
    target_link_libraries(${name} PRIVATE ${ARGN})
    target_include_directories(${name} PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
    target_compile_definitions(${name} PRIVATE
        SOUNDGRAPH_EXAMPLES_DIR="${CMAKE_SOURCE_DIR}/examples"
        SOUNDGRAPH_TESTS_DIR="${CMAKE_CURRENT_SOURCE_DIR}"
    )
    add_test(NAME ${name} COMMAND ${name})
endfunction()

soundgraph_add_test(test_nodes soundgraph::dsp)
soundgraph_add_test(test_graph soundgraph::dsp)
soundgraph_add_test(test_patch_io soundgraph::patch_io)
soundgraph_add_test(test_golden soundgraph::patch_io soundgraph::wav)

# The sfxr oracle. Two tests, both cheap, both guarding something the port will depend on.
#
# The comparator judges the port, so it is itself tested first: it must answer "identical"
# for identical input and "different" for input that is genuinely different. A metric
# nobody has checked is not evidence, and a port could otherwise pass by being wrong in a
# way the metric cannot see.
find_program(SOUNDGRAPH_NODE node)
if(SOUNDGRAPH_NODE)
    add_test(NAME sfxr_comparator
        COMMAND ${SOUNDGRAPH_NODE} ${CMAKE_SOURCE_DIR}/tools/compare-waveforms.mjs
                --self-test ${CMAKE_CURRENT_SOURCE_DIR}/sfxr)
endif()

# The corpus is committed, so it has to be reproducible: regenerating it must give back
# byte-identical vectors. sfxr draws from a PRNG inside its audio loop, which is why the
# reference substitutes a fixed generator for the C library's — if that ever drifts, every
# comparison silently changes meaning and this is the test that says so.
add_test(NAME sfxr_corpus_is_reproducible
    COMMAND ${CMAKE_COMMAND}
        -DSFXR_REF=$<TARGET_FILE:sfxr-ref>
        -DCORPUS=${CMAKE_CURRENT_SOURCE_DIR}/sfxr
        -DSCRATCH=${CMAKE_CURRENT_BINARY_DIR}/sfxr-regenerated
        -P ${CMAKE_CURRENT_SOURCE_DIR}/sfxr/reproducible.cmake)

# The eight game sounds are copies of eight corpus cases, and copies drift. They already
# did: the mapper changed, the corpus was regenerated, and the sandbox went on playing the
# previous wiring because nothing regenerated these. The recipe used to live in somebody's
# shell history; it now lives in tools/game-sounds.mjs, and this is what notices when the
# committed files stop matching it.
if(SOUNDGRAPH_NODE)
    add_test(NAME game_sounds_match_the_corpus
        COMMAND ${SOUNDGRAPH_NODE} ${CMAKE_SOURCE_DIR}/tools/game-sounds.mjs --check)
endif()

# The FM library is generated from the vendored Freedoom instruments by the same
# pattern: tools/opl2-import.mjs is the recipe, the committed patches are its output,
# and this notices when they stop agreeing.
if(SOUNDGRAPH_NODE)
    add_test(NAME opl2_imports_match_the_importer
        COMMAND ${SOUNDGRAPH_NODE} ${CMAKE_SOURCE_DIR}/tools/opl2-import.mjs --check)
endif()

# The modules stage-1 exit test: every DX7 voice built flat and factored modular must
# render byte-identical audio. Notation changes, sound does not — this is the design
# document's whole thesis as one assertion.
if(SOUNDGRAPH_NODE)
    add_test(NAME modules_flatten_to_identical_audio
        COMMAND ${SOUNDGRAPH_NODE} ${CMAKE_SOURCE_DIR}/tools/dx7-import.mjs --modular-check)
endif()

# Every DX7 voice, played through msfa and through its imported patch, agreeing on
# pitch and presence — the same bargain as the OPL comparator, against the engine
# Dexed builds on.
if(SOUNDGRAPH_NODE)
    add_test(NAME dx7_imports_agree_with_the_oracle
        COMMAND ${SOUNDGRAPH_NODE} ${CMAKE_SOURCE_DIR}/tools/dx7-compare.mjs)
endif()

# The DX7 library is generated the same way: the demo bank from its generator, the
# patches from the importer, and this notices when any of the three drift apart.
if(SOUNDGRAPH_NODE)
    add_test(NAME dx7_imports_match_the_importer
        COMMAND ${SOUNDGRAPH_NODE} ${CMAKE_SOURCE_DIR}/tools/dx7-import.mjs --check)
endif()

# Every imported instrument, played through Nuked-OPL3 and through its SoundGraph
# mapping, must agree on pitch and actually sound. Not a byte comparison — the mapping
# is a translation with documented approximations — but the coarse truths that catch
# real wiring bugs, measured against the accepted OPL emulator rather than against
# whoever wrote the importer's idea of what it meant.
if(SOUNDGRAPH_NODE)
    add_test(NAME opl2_imports_agree_with_the_oracle
        COMMAND ${SOUNDGRAPH_NODE} ${CMAKE_SOURCE_DIR}/tools/opl2-compare.mjs)
endif()

# And the same again one step further along: the Godot editor ships its own copy of the
# examples, because Godot cannot read outside res://. That copy has now gone stale twice by
# two different routes, the second time because the thing that syncs it lives in a build
# directory nobody runs when only a patch has changed. This test is in the build everybody
# runs, which is the point.
if(SOUNDGRAPH_NODE)
    add_test(NAME godot_examples_are_mirrored
        COMMAND ${SOUNDGRAPH_NODE} ${CMAKE_SOURCE_DIR}/tools/mirror-examples.mjs --check)
endif()

# One demo patch per node type, and two different questions about them.
#
# The first is the usual generated-file question — do the committed files still match the
# table that builds them, and is there an entry for every type the registry knows about.
#
# The second is the one worth the render time. Every demo makes a sound, and that proves
# almost nothing: a saw through a bypassed filter measures the same as a saw, so a demo
# whose node did nothing would pass a "is it audible" check. So each demo also names the
# change its own description tells the reader to make, and this renders the patch with and
# without it. A demo that says "drag this" and means it is a demo; one that doesn't is
# decoration that will be found out on stage.
if(SOUNDGRAPH_NODE)
    add_test(NAME node_demos_match_the_registry
        COMMAND ${SOUNDGRAPH_NODE} ${CMAKE_SOURCE_DIR}/tools/node-demos.mjs --check
                --nodes $<TARGET_FILE:sg-validate>)
    add_test(NAME node_demos_do_what_they_say
        COMMAND ${SOUNDGRAPH_NODE} ${CMAKE_SOURCE_DIR}/tools/node-demos.mjs
                --verify $<TARGET_FILE:sg-render>)
endif()

# The design system's own claims: that the surface levels are a measurable ladder rather
# than four names for one grey, that every text colour clears its contrast floor on every
# surface it can land on, and that the font really is delivering the weights the hierarchy
# is built out of. That last one is not hypothetical — the editor asked for bold through a
# key Godot silently ignores and got Regular for months, which is most of why nothing in it
# looked ranked.
#
# Needs Godot, so it is skipped rather than failed where there is none; the C++ suite is
# what has to run everywhere.
find_program(SOUNDGRAPH_GODOT
    NAMES godot Godot_v4.7.1-stable_win64_console.exe Godot_v4.7.1-stable_win64.exe
    PATHS "C:/Users/danie/Downloads/gofo/Godot_v4.7.1-stable_win64.exe")
if(SOUNDGRAPH_GODOT)
    add_test(NAME editor_design
        COMMAND ${SOUNDGRAPH_GODOT} --headless --path ${CMAKE_SOURCE_DIR}/editor-godot
                --script res://design_test.gd)
else()
    message(STATUS "Godot not found, so the design-system test will not run.")
endif()

# The port itself, measured against sfxr. A ratchet, not a target: the honest number today
# is not 41, and what this catches is that number going *down* while something else is
# being changed. Raise --min-pass whenever the port improves.
if(SOUNDGRAPH_NODE)
    add_test(NAME sfxr_port_does_not_regress
        COMMAND ${SOUNDGRAPH_NODE} ${CMAKE_SOURCE_DIR}/tools/sfxr-report.mjs
                --dir ${CMAKE_CURRENT_SOURCE_DIR}/sfxr
                --render $<TARGET_FILE:sg-render>
                --ref $<TARGET_FILE:sfxr-ref>
                --min-pass 32)
endif()
