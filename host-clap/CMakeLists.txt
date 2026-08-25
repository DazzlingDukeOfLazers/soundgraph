# sg-host: the headless CLAP host. Lives behind SOUNDGRAPH_CLAP with the plugin it
# tests, because both need the CLAP headers that tools/get-plugin-sdks.sh fetches —
# the default build stays SDK-free. Unlike the plugin it links no wrapper: the whole
# point is to stand on the host side of the dynamic-loading boundary.

add_executable(sg-host src/main.cpp)
target_include_directories(sg-host PRIVATE
        ${CMAKE_SOURCE_DIR}/runtime-clap/sdks/clap/include)
target_link_libraries(sg-host PRIVATE soundgraph::wav ${CMAKE_DL_LIBS})
target_compile_features(sg-host PRIVATE cxx_std_17)

if(SOUNDGRAPH_BUILD_TESTS)
    # The host meets the shipped artifact, not a re-link of its objects: the test that
    # caught the NRVO dangling-pointer bug in-process would have missed a broken export
    # table, a CRT mismatch, or a loader failure. This one cannot.
    add_test(NAME sg_host_plays_the_built_clap
            COMMAND sg-host $<TARGET_FILE:soundgraph-plugin_clap>
                --seconds 1 --note 48,60 --rms-min 0.01
                --wav ${CMAKE_CURRENT_BINARY_DIR}/sg-host-render.wav)
    set_tests_properties(sg_host_plays_the_built_clap PROPERTIES
            ENVIRONMENT "SOUNDGRAPH_PATCHES=${CMAKE_SOURCE_DIR}/examples/patches/synths")

    add_test(NAME sg_host_lists_the_parameter_surface
            COMMAND sg-host $<TARGET_FILE:soundgraph-plugin_clap> --list)
    set_tests_properties(sg_host_lists_the_parameter_surface PROPERTIES
            ENVIRONMENT "SOUNDGRAPH_PATCHES=${CMAKE_SOURCE_DIR}/examples/patches/synths"
            PASS_REGULAR_EXPRESSION "parameter")
endif()
