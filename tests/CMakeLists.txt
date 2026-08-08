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

# The port itself, measured against sfxr. A ratchet, not a target: the honest number today
# is not 41, and what this catches is that number going *down* while something else is
# being changed. Raise --min-pass whenever the port improves.
if(SOUNDGRAPH_NODE)
    add_test(NAME sfxr_port_does_not_regress
        COMMAND ${SOUNDGRAPH_NODE} ${CMAKE_SOURCE_DIR}/tools/sfxr-report.mjs
                --dir ${CMAKE_CURRENT_SOURCE_DIR}/sfxr
                --render $<TARGET_FILE:sg-render>
                --min-pass 24)
endif()
