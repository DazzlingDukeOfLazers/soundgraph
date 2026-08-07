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
