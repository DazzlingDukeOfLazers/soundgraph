# sg-host: the headless plugin host. Lives behind SOUNDGRAPH_CLAP with the plugins it
# tests, because both need the SDKs tools/get-plugin-sdks.sh fetches — the default
# build stays SDK-free. Unlike the plugin it links no wrapper: the whole point is to
# stand on the host side of the dynamic-loading boundary.

set(SOUNDGRAPH_VST3_SDK ${CPM_PACKAGE_vst3sdk_SOURCE_DIR})
if(NOT SOUNDGRAPH_VST3_SDK OR NOT EXISTS ${SOUNDGRAPH_VST3_SDK}/public.sdk/source/vst/hosting/module.h)
    message(FATAL_ERROR "sg-host: the VST3 SDK is missing. clap-wrapper fetches it during "
            "configure; delete build-clap/runtime-clap/cpm and reconfigure if this persists.")
endif()

# The hosting helpers Steinberg ships but base-sdk-vst3 does not compile: module loading
# (whose implementation is per-platform), the example IHostApplication, and the
# containers a process call needs. Everything else comes from base-sdk-vst3, which
# clap-wrapper already builds for the plugin side.
set(SOUNDGRAPH_VST3_HOSTING
        ${SOUNDGRAPH_VST3_SDK}/public.sdk/source/vst/hosting/module.cpp
        ${SOUNDGRAPH_VST3_SDK}/public.sdk/source/vst/hosting/hostclasses.cpp
        # HostApplication's constructor builds one of these, so the two travel together.
        ${SOUNDGRAPH_VST3_SDK}/public.sdk/source/vst/hosting/pluginterfacesupport.cpp
        ${SOUNDGRAPH_VST3_SDK}/public.sdk/source/vst/hosting/eventlist.cpp
        ${SOUNDGRAPH_VST3_SDK}/public.sdk/source/vst/hosting/parameterchanges.cpp
        ${SOUNDGRAPH_VST3_SDK}/public.sdk/source/vst/hosting/processdata.cpp
        ${SOUNDGRAPH_VST3_SDK}/public.sdk/source/vst/utility/stringconvert.cpp)
if(WIN32)
    list(APPEND SOUNDGRAPH_VST3_HOSTING
            ${SOUNDGRAPH_VST3_SDK}/public.sdk/source/vst/hosting/module_win32.cpp)
elseif(APPLE)
    list(APPEND SOUNDGRAPH_VST3_HOSTING
            ${SOUNDGRAPH_VST3_SDK}/public.sdk/source/vst/hosting/module_mac.mm)
else()
    list(APPEND SOUNDGRAPH_VST3_HOSTING
            ${SOUNDGRAPH_VST3_SDK}/public.sdk/source/vst/hosting/module_linux.cpp)
endif()

add_executable(sg-host
        src/main.cpp
        src/host_clap.cpp
        src/host_vst3.cpp
        ${SOUNDGRAPH_VST3_HOSTING})
target_include_directories(sg-host PRIVATE
        ${CMAKE_SOURCE_DIR}/runtime-clap/sdks/clap/include
        ${SOUNDGRAPH_VST3_SDK})
target_link_libraries(sg-host PRIVATE soundgraph::wav base-sdk-vst3 ${CMAKE_DL_LIBS})
target_compile_features(sg-host PRIVATE cxx_std_17)
if(WIN32)
    # module_win32 walks bundle directories with the Shell API and reports versions
    # through the Version API; neither is linked by default.
    target_link_libraries(sg-host PRIVATE shell32 ole32 version)
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
endif()
