# SoundGraph as a plugin: one CLAP implementation, assembled by clap-wrapper into the
# CLAP, the VST3, the Audio Unit and a standalone. Opt-in (-DSOUNDGRAPH_CLAP=ON) because
# it needs SDKs the default build must not depend on: run tools/get-plugin-sdks.sh once
# to place clap and clap-wrapper under runtime-clap/sdks/ (gitignored); clap-wrapper
# fetches its pinned VST3 SDK and Apple AudioUnitSDK on first configure, into sdks/_fetch
# so a deleted build directory does not refetch them.

if(NOT EXISTS ${CMAKE_CURRENT_SOURCE_DIR}/sdks/clap-wrapper/CMakeLists.txt)
    message(FATAL_ERROR "runtime-clap: SDKs are missing. Run tools/get-plugin-sdks.sh first.")
endif()

# The plugin is a shared library; everything linked into it must be relocatable.
set_target_properties(soundgraph-dsp soundgraph-patch-io PROPERTIES
        POSITION_INDEPENDENT_CODE ON)

set(CLAP_SDK_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/sdks/clap)
set(FETCHCONTENT_BASE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/sdks/_fetch)
set(CLAP_WRAPPER_DOWNLOAD_DEPENDENCIES TRUE)
add_subdirectory(sdks/clap-wrapper)

# The built-in patch, embedded at build time from the example it mirrors — regenerated
# whenever the example changes, never copied by hand.
set(SOUNDGRAPH_DEFAULT_PATCH ${CMAKE_SOURCE_DIR}/examples/patches/first-synth.json)
set(SOUNDGRAPH_DEFAULT_PATCH_HEADER ${CMAKE_CURRENT_BINARY_DIR}/generated/default_patch.h)
add_custom_command(
        OUTPUT ${SOUNDGRAPH_DEFAULT_PATCH_HEADER}
        COMMAND ${CMAKE_COMMAND}
            -DINPUT=${SOUNDGRAPH_DEFAULT_PATCH}
            -DOUTPUT=${SOUNDGRAPH_DEFAULT_PATCH_HEADER}
            -P ${CMAKE_CURRENT_SOURCE_DIR}/cmake/embed_patch.cmake
        DEPENDS ${SOUNDGRAPH_DEFAULT_PATCH} ${CMAKE_CURRENT_SOURCE_DIR}/cmake/embed_patch.cmake
        COMMENT "Embedding first-synth.json as the built-in patch")

add_library(soundgraph-clap-impl STATIC
        src/soundgraph_clap.cpp
        ${SOUNDGRAPH_DEFAULT_PATCH_HEADER})
target_include_directories(soundgraph-clap-impl PRIVATE ${CMAKE_CURRENT_BINARY_DIR}/generated)
target_link_libraries(soundgraph-clap-impl
        PUBLIC clap clap-wrapper-extensions
        PRIVATE soundgraph::dsp soundgraph::patch_io)
set_target_properties(soundgraph-clap-impl PROPERTIES POSITION_INDEPENDENT_CODE ON)

set(SOUNDGRAPH_PLUGIN_FORMATS CLAP VST3)
if(APPLE)
    list(APPEND SOUNDGRAPH_PLUGIN_FORMATS AUV2)
endif()

# The standalone app's menu nib needs ibtool, which ships with Xcode proper, not the
# Command Line Tools. Without it the plugins still build — and sg-play is the standalone
# that matters day to day — so the app quietly steps aside rather than failing the build.
set(SOUNDGRAPH_STANDALONE TRUE)
if(APPLE)
    execute_process(COMMAND xcrun --find ibtool
            RESULT_VARIABLE SOUNDGRAPH_IBTOOL_MISSING OUTPUT_QUIET ERROR_QUIET)
    if(SOUNDGRAPH_IBTOOL_MISSING)
        set(SOUNDGRAPH_STANDALONE FALSE)
        message(STATUS "runtime-clap: ibtool not found (Command Line Tools only) — "
                "skipping the standalone app")
    endif()
endif()
set(SOUNDGRAPH_STANDALONE_ARGS "")
if(SOUNDGRAPH_STANDALONE)
    set(SOUNDGRAPH_STANDALONE_ARGS
            STANDALONE_CONFIGURATIONS standalone "SoundGraph" "org.soundgraph.player")
endif()

make_clapfirst_plugins(
        TARGET_NAME soundgraph-plugin
        IMPL_TARGET soundgraph-clap-impl

        OUTPUT_NAME "SoundGraph"

        ENTRY_SOURCE ${CMAKE_CURRENT_SOURCE_DIR}/src/soundgraph_clap_entry.cpp

        BUNDLE_IDENTIFIER "org.soundgraph.player"
        BUNDLE_VERSION ${PROJECT_VERSION}

        COPY_AFTER_BUILD FALSE

        PLUGIN_FORMATS ${SOUNDGRAPH_PLUGIN_FORMATS}

        ASSET_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/plugins

        AUV2_MANUFACTURER_NAME "SoundGraph"
        AUV2_MANUFACTURER_CODE "SnGr"
        AUV2_SUBTYPE_CODE "SgPl"
        AUV2_INSTRUMENT_TYPE "aumu"

        ${SOUNDGRAPH_STANDALONE_ARGS}
)

if(SOUNDGRAPH_BUILD_TESTS)
    add_executable(test_clap_plugin test/test_plugin.cpp)
    target_link_libraries(test_clap_plugin PRIVATE soundgraph-clap-impl clap)
    target_compile_definitions(test_clap_plugin PRIVATE
            SOUNDGRAPH_TEST_PATCHES="${CMAKE_SOURCE_DIR}/examples/patches/synths")
    add_test(NAME clap_plugin_plays_and_swaps_patches COMMAND test_clap_plugin)
endif()

if(APPLE)
    # clap-wrapper installs the generated AudioComponents Info.plist in a PRE_BUILD
    # step, which Ninja runs before CMake writes the bundle's own generic plist — so the
    # generic one wins and auval cannot find the component. Reinstate the generated
    # plist after the build, and re-sign since the bundle's contents changed.
    add_custom_command(TARGET soundgraph-plugin_auv2 POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy
                ${CMAKE_CURRENT_BINARY_DIR}/soundgraph-plugin_auv2-build-helper-output/auv2_Info.plist
                $<TARGET_FILE_DIR:soundgraph-plugin_auv2>/../Info.plist
            COMMAND codesign -s - -f $<TARGET_FILE_DIR:soundgraph-plugin_auv2>/../..
            COMMENT "Restoring the AudioComponents Info.plist and ad-hoc signature")
endif()
