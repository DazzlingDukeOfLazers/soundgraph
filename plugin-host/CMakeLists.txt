# sg-host: the headless plugin host. Lives behind SOUNDGRAPH_CLAP with the plugins it
# tests, because both need the SDKs tools/get-plugin-sdks.sh fetches — the default
# build stays SDK-free. Unlike the plugin it links no wrapper: the whole point is to
# stand on the host side of the dynamic-loading boundary.
#
# The library itself is built by plugin-host.cmake, which runtime-godot also calls. This
# file is what is specific to *this* build: the command line tool, and the tests that
# point it at artifacts only this build produces.

include(${CMAKE_CURRENT_SOURCE_DIR}/plugin-host.cmake)

# In this build the answer is known exactly rather than searched for: clap-wrapper has
# just fetched the SDK and says where it put it, whatever this build directory is called.
set(SOUNDGRAPH_VST3_SDK ${CPM_PACKAGE_vst3sdk_SOURCE_DIR})
set(SOUNDGRAPH_CLAP_SDK ${CMAKE_SOURCE_DIR}/runtime-clap/sdks/clap)

soundgraph_find_plugin_sdks(SOUNDGRAPH_CLAP_SDK_PATH SOUNDGRAPH_VST3_SDK_PATH)
if(NOT SOUNDGRAPH_VST3_SDK_PATH)
    message(FATAL_ERROR "sg-host: the VST3 SDK is missing. clap-wrapper fetches it during "
            "configure; delete build-clap/runtime-clap/cpm and reconfigure if this persists.")
endif()

soundgraph_add_plugin_host(soundgraph-plugin-host)

add_executable(sg-host src/main.cpp)
target_include_directories(sg-host PRIVATE ${SOUNDGRAPH_CLAP_SDK_PATH}/include)
target_link_libraries(sg-host PRIVATE soundgraph-plugin-host soundgraph::wav)
target_compile_features(sg-host PRIVATE cxx_std_17)

# sg-render is declared before this directory, so the dependency is added from here
# rather than there: the offline renderer gains real plugins exactly when the SDKs are
# present, and needs no #ifdef of its own beyond one guard.
if(TARGET sg-render)
    target_link_libraries(sg-render PRIVATE soundgraph-plugin-host)
    target_compile_definitions(sg-render PRIVATE SOUNDGRAPH_WITH_PLUGIN_HOST)
endif()

if(SOUNDGRAPH_BUILD_TESTS)
    # The host meets the shipped artifacts, not a re-link of their objects: the test
    # that caught the NRVO dangling-pointer bug in-process would have missed a broken
    # export table, a CRT mismatch, or a loader failure. These cannot.
    set(SOUNDGRAPH_HOST_PATCHES
            "SOUNDGRAPH_PATCHES=${CMAKE_SOURCE_DIR}/examples/patches/synths")

    add_test(NAME sg_host_plays_the_built_clap
            COMMAND sg-host $<TARGET_FILE:soundgraph-plugin_clap>
                --seconds 1 --note 48,60 --rms-min 0.01
                --wav ${CMAKE_CURRENT_BINARY_DIR}/sg-host-clap.wav)
    set_tests_properties(sg_host_plays_the_built_clap PROPERTIES
            ENVIRONMENT "${SOUNDGRAPH_HOST_PATCHES}")

    add_test(NAME sg_host_lists_the_parameter_surface
            COMMAND sg-host $<TARGET_FILE:soundgraph-plugin_clap> --list)
    set_tests_properties(sg_host_lists_the_parameter_surface PROPERTIES
            ENVIRONMENT "${SOUNDGRAPH_HOST_PATCHES}"
            PASS_REGULAR_EXPRESSION "parameter")

    # The same plugin through the other doorway. The VST3 is what the wrapper built
    # from the same implementation, so a difference between these two runs is a
    # wrapper bug — which is exactly the bug class no in-process test can see.
    add_test(NAME sg_host_plays_the_built_vst3
            COMMAND sg-host ${CMAKE_BINARY_DIR}/plugins/VST3/SoundGraph.vst3
                --seconds 1 --note 48,60 --rms-min 0.01
                --wav ${CMAKE_CURRENT_BINARY_DIR}/sg-host-vst3.wav)
    set_tests_properties(sg_host_plays_the_built_vst3 PROPERTIES
            ENVIRONMENT "${SOUNDGRAPH_HOST_PATCHES}")

    # The watchdog, proven on a render far too long to finish: u-he's Podolski showed
    # that a plugin can stop this program for good by opening a dialog, and a rig that
    # can be stopped for good by a stranger is not a rig. A runaway render stands in
    # for the dialog — what is being tested is that something ends it. Exit code 3 is
    # deliberate, so a caller can tell "hung" from "silent".
    add_test(NAME sg_host_watchdog_ends_a_runaway_render
            COMMAND sg-host $<TARGET_FILE:soundgraph-plugin_clap>
                --seconds 200000 --note 60 --timeout 2)
    set_tests_properties(sg_host_watchdog_ends_a_runaway_render PROPERTIES
            ENVIRONMENT "${SOUNDGRAPH_HOST_PATCHES}"
            TIMEOUT 60
            PASS_REGULAR_EXPRESSION "did not finish within 2 seconds")

    # A patch swap is the one thing that needs main-thread work to actually arrive,
    # and through the VST3 wrapper it only arrives if the host pumps its message loop
    # and lets the wrapper's 20 ms timer fire. It silently did neither until sg-host
    # learned to settle, and the symptom was a render that quietly ignored the switch.
    # acid-bass at key 36 is much quieter than the built-in patch, so this threshold
    # fails if the swap is skipped rather than merely sounding different.
    add_test(NAME sg_host_swaps_patches_through_the_vst3
            COMMAND sg-host ${CMAKE_BINARY_DIR}/plugins/VST3/SoundGraph.vst3
                --seconds 1 --note 36 --param Patch=0.01282 --rms-min 0.001)
    set_tests_properties(sg_host_swaps_patches_through_the_vst3 PROPERTIES
            ENVIRONMENT "${SOUNDGRAPH_HOST_PATCHES}"
            FAIL_REGULAR_EXPRESSION "rms 0\\.16")
    # ---- the plugin's own state ------------------------------------------------------
    # Round-tripped rather than compared to a stored blob: a plugin's state is its own
    # business and a golden file of somebody's preset would break every time they
    # changed their minds about their own format. What is being tested is that the
    # bytes make the journey, which is a property of this host and not of that plugin.
    #
    # Our own plugin, because it is the one every machine building this has. Its state
    # is the patch it is playing, so --param Patch swaps it to something else first and
    # the saved state has to be of the patch it ended on rather than the one it opened
    # with — which is the failure this ordering exists to catch.
    add_test(NAME sg_host_saves_and_restores_plugin_state
            COMMAND ${CMAKE_COMMAND}
                -DHOST=$<TARGET_FILE:sg-host>
                -DPLUGIN=$<TARGET_FILE:soundgraph-plugin_clap>
                -DPATCHES=${CMAKE_SOURCE_DIR}/examples/patches/synths
                -DWORK=${CMAKE_CURRENT_BINARY_DIR}/state-roundtrip
                -P ${CMAKE_CURRENT_SOURCE_DIR}/state-roundtrip.cmake)

    # ---- the provider, against a plugin this build made itself ----------------------
    # The point is not the sound — our own plugin is an instrument, so as an effect it
    # has nothing to say — but that a patch naming a plugin by identity causes a real
    # shared library to be found, opened and matched. Using our own artifact keeps the
    # test honest on a machine with no third-party plugins installed anywhere.
    set(SOUNDGRAPH_HOSTED_PATCH ${CMAKE_CURRENT_BINARY_DIR}/hosted-patch.json)
    file(WRITE ${SOUNDGRAPH_HOSTED_PATCH}
"{
"
"  \"schema_version\": 4,
"
"  \"plugins\": { \"fx\": { \"format\": \"VST3\",
"
"      \"identity\": \"86A7F253842050FC89F71B2835D65C75\",
"
"      \"vendor\": \"MutantFactory.net\", \"name\": \"SoundGraph\" } },
"
"  \"nodes\": [
"
"    { \"id\": \"osc\", \"type\": \"SineOscillator\" },
"
"    { \"id\": \"fx\", \"type\": \"PluginEffect\", \"plugin\": \"fx\" },
"
"    { \"id\": \"out\", \"type\": \"StereoOutput\" }
"
"  ],
"
"  \"connections\": [
"
"    { \"from\": { \"node\": \"osc\", \"port\": \"out\" }, \"to\": { \"node\": \"fx\", \"port\": \"left\" } },
"
"    { \"from\": { \"node\": \"fx\", \"port\": \"left\" }, \"to\": { \"node\": \"out\", \"port\": \"left\" } }
"
"  ]
"
"}
")

    set(SOUNDGRAPH_BOGUS_PATCH ${CMAKE_CURRENT_BINARY_DIR}/hosted-patch-missing.json)
    file(WRITE ${SOUNDGRAPH_BOGUS_PATCH}
"{
"
"  \"schema_version\": 4,
"
"  \"plugins\": { \"fx\": { \"format\": \"VST3\",
"
"      \"identity\": \"00000000000000000000000000000000\",
"
"      \"vendor\": \"Nobody\", \"name\": \"A Plugin That Is Not Here\" } },
"
"  \"nodes\": [
"
"    { \"id\": \"osc\", \"type\": \"SineOscillator\" },
"
"    { \"id\": \"fx\", \"type\": \"PluginEffect\", \"plugin\": \"fx\" },
"
"    { \"id\": \"out\", \"type\": \"StereoOutput\" }
"
"  ],
"
"  \"connections\": [
"
"    { \"from\": { \"node\": \"osc\", \"port\": \"out\" }, \"to\": { \"node\": \"fx\", \"port\": \"left\" } },
"
"    { \"from\": { \"node\": \"fx\", \"port\": \"left\" }, \"to\": { \"node\": \"out\", \"port\": \"left\" } }
"
"  ]
"
"}
")

    if(TARGET sg-render)
        add_test(NAME sg_render_resolves_a_plugin_by_identity
                COMMAND sg-render ${SOUNDGRAPH_HOSTED_PATCH}
                        ${CMAKE_CURRENT_BINARY_DIR}/hosted-render.wav --seconds 1)
        set_tests_properties(sg_render_resolves_a_plugin_by_identity PROPERTIES
                ENVIRONMENT "SOUNDGRAPH_PLUGIN_PATH=${CMAKE_BINARY_DIR}/plugins/VST3"
                FAIL_REGULAR_EXPRESSION "not available here")

        # And the half that matters more, because every target that cannot host a
        # plugin lives here: the patch still renders, and says what is missing.
        add_test(NAME sg_render_says_what_it_could_not_find
                COMMAND sg-render ${SOUNDGRAPH_BOGUS_PATCH}
                        ${CMAKE_CURRENT_BINARY_DIR}/missing-render.wav --seconds 1)
        set_tests_properties(sg_render_says_what_it_could_not_find PROPERTIES
                ENVIRONMENT "SOUNDGRAPH_PLUGIN_PATH=${CMAKE_BINARY_DIR}/plugins/VST3"
                PASS_REGULAR_EXPRESSION "A Plugin That Is Not Here")
    endif()
endif()
