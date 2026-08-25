# The Godot binding.
#
# Built separately from the main tree: godot-cpp brings its own large build and its own
# compiler settings, and the core must never depend on it. Configure this directory
# directly rather than from the root CMakeLists.
cmake_minimum_required(VERSION 3.22)
project(soundgraph-godot LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()

set(SOUNDGRAPH_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/..)

# godot-cpp links the static MSVC runtime, and everything in the same DLL has to agree —
# mixing /MT and /MD gives duplicate CRT symbols at link time. The setting is read when a
# target is created, so it is established before any target exists and godot-cpp is added
# first, ahead of our own libraries.
if(MSVC)
    set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
endif()

# A Godot web export loads the extension as an Emscripten SIDE_MODULE, and every object
# inside it has to be built that way — including the core, which does not link godot-cpp
# and so would not pick the flag up by propagation. Threads are off to match the
# web_dlink_nothreads template: the two must agree, and nothreads is what avoids
# SharedArrayBuffer and the cross-origin isolation headers that come with it.
if(EMSCRIPTEN)
    set(GODOTCPP_THREADS OFF CACHE BOOL "" FORCE)
    # A release export loads the template_release entry, so godot-cpp has to be the
    # matching build; the default is template_debug.
    set(GODOTCPP_TARGET "template_release" CACHE STRING "" FORCE)
    set(CMAKE_POSITION_INDEPENDENT_CODE ON)

    # -fvisibility=hidden is the one that matters, and godot-cpp puts it on the link line
    # (cmake/web.cmake), where it does nothing — visibility is decided when a translation
    # unit is compiled, not when it is linked. Without it every default-visibility symbol in
    # the module joins the dynamic symbol table, and Emscripten then emits our own
    # statically-linked code as *imports*: the built .wasm asked "env" for
    # _ZN10soundgraph16GraphDescriptionD2Ev and std::to_string. Godot cannot supply those, so
    # the loader substitutes a stub of another arity and the first call through it aborts the
    # engine with "function signature mismatch" — a message that names neither the symbol nor
    # this file. A stock GDExtension never trips it because it only uses Godot's own String;
    # this one links the C++ standard library.
    #
    # The entry point stays exported: GDE_EXPORT is visibility("default"), which overrides.
    add_compile_options(
        -sSIDE_MODULE=1 -sSUPPORT_LONGJMP=wasm -fPIC
        -fvisibility=hidden -fvisibility-inlines-hidden
    )

    # godot-cpp carries a workaround that teaches CMake to emit Emscripten shared
    # libraries, but it is installed through CMAKE_PROJECT_godot-cpp_INCLUDE and so only
    # applies inside godot-cpp's own project scope. Our library lives in this project, so
    # it never saw it and linked as an executable — which then failed looking for main().
    # The same settings are applied here, where our target can actually see them.
    set_property(GLOBAL PROPERTY TARGET_SUPPORTS_SHARED_LIBS TRUE)
    set(CMAKE_SHARED_LIBRARY_CREATE_CXX_FLAGS "-sSIDE_MODULE=1")
    set(CMAKE_SHARED_LIBRARY_CREATE_C_FLAGS "-sSIDE_MODULE=1")
endif()

add_subdirectory(third_party/godot-cpp)

# The core, built here as part of this configuration. Same sources, same semantics as the
# native and WebAssembly builds — that is the point.
add_subdirectory(${SOUNDGRAPH_ROOT}/dsp-core  ${CMAKE_BINARY_DIR}/dsp-core)
add_subdirectory(${SOUNDGRAPH_ROOT}/patch-io  ${CMAKE_BINARY_DIR}/patch-io)

add_library(soundgraph_godot SHARED
    src/register_types.cpp
    src/soundgraph_engine.cpp
)

target_link_libraries(soundgraph_godot PRIVATE godot-cpp soundgraph::patch_io)

# ---- hosting somebody else's plugin -------------------------------------------------
#
# Optional, and quietly so. Building this needs the CLAP and VST3 SDKs, which
# tools/get-plugin-sdks.sh fetches and an ordinary clone does not have; without them the
# extension is exactly what it was before, and a patch naming a plugin still opens and
# still says which plugin it wanted. dsp-core was built for that case from the start —
# no provider is a fact about the machine, not an error — so there is nothing to guard
# here beyond the one branch.
#
# Never for the web build: a browser has no shared libraries to load, and asking
# Emscripten to compile the VST3 SDK is a way to find that out slowly.
#
# The extension links the hosting code rather than shelling out to sg-host, which is a
# deliberate reversal. Scanning still happens out of process, because opening every
# plugin on a machine is exactly the act that hangs — but a plugin the user is *playing*
# has to be in the process that owns the audio graph and the window, and no amount of
# pipe between them changes that.
if(NOT EMSCRIPTEN)
    include(${SOUNDGRAPH_ROOT}/plugin-host/plugin-host.cmake)
    soundgraph_find_plugin_sdks(SOUNDGRAPH_GODOT_CLAP_SDK SOUNDGRAPH_GODOT_VST3_SDK)
    if(SOUNDGRAPH_GODOT_CLAP_SDK AND SOUNDGRAPH_GODOT_VST3_SDK)
        message(STATUS "soundgraph: hosting plugins (VST3 SDK ${SOUNDGRAPH_GODOT_VST3_SDK})")
        soundgraph_add_plugin_host(soundgraph_godot_plugin_host)
        target_link_libraries(soundgraph_godot PRIVATE soundgraph_godot_plugin_host)
        target_compile_definitions(soundgraph_godot PRIVATE SOUNDGRAPH_WITH_PLUGIN_HOST)
    else()
        message(STATUS "soundgraph: no plugin SDKs found; the extension will not host plugins. "
                "Run tools/get-plugin-sdks.sh and configure the plugin build once.")
    endif()
endif()

# Stated on the target as well as through the shared-library flags above: this has to be a
# side module however CMake decides to phrase the link line, and a missing SIDE_MODULE
# fails as "undefined symbol: main", which points nowhere near the cause.
if(EMSCRIPTEN)
    target_link_options(soundgraph_godot PRIVATE -sSIDE_MODULE=1)
endif()

# Godot loads the library by the exact name in soundgraph.gdextension. The web build gets
# a distinct name because it sits alongside the desktop one in the same bin directory and
# a .wasm is not interchangeable with a .dll.
#
# Everywhere else the platform's own convention is what the manifest already asks for:
# libsoundgraph_godot.dylib, libsoundgraph_godot.so, soundgraph_godot.dll. CMake produces
# exactly those on its own — MSVC has no prefix, macOS and Linux have "lib" — so the
# desktop branch sets only the stem and leaves the decoration alone.
#
# It used to force PREFIX "" here as well, which is right for the web module and wrong for
# everything else: the built file was soundgraph_godot.dylib while the manifest asked for
# libsoundgraph_godot.dylib, and the extension could not load at all. Linux had the same
# mismatch. Windows and web were unaffected, which is why it went unnoticed — those are
# the two the project is built on.
if(EMSCRIPTEN)
    set_target_properties(soundgraph_godot PROPERTIES
        PREFIX ""
        OUTPUT_NAME "soundgraph_godot.web.wasm32.nothreads"
        SUFFIX ".wasm"
    )
else()
    set_target_properties(soundgraph_godot PROPERTIES OUTPUT_NAME "soundgraph_godot")
endif()

# Drop the built library where the Godot project expects it, and mirror the example
# patches in. Godot cannot read outside res://, and committing a second copy of the
# examples would be two files that eventually disagree — so they are copied, and
# editor-godot/bin and editor-godot/examples-mirror are both build output.
set(SOUNDGRAPH_GODOT_BIN ${SOUNDGRAPH_ROOT}/editor-godot/bin)
set(SOUNDGRAPH_GODOT_EXAMPLES ${SOUNDGRAPH_ROOT}/editor-godot/examples-mirror)

add_custom_command(TARGET soundgraph_godot POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory ${SOUNDGRAPH_GODOT_BIN}
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
            $<TARGET_FILE:soundgraph_godot> ${SOUNDGRAPH_GODOT_BIN}
    COMMENT "Copying the extension into editor-godot/bin"
)

# The example patches, mirrored on every build rather than after a link.
#
# These were copied by the POST_BUILD above, which only runs when the extension itself
# relinks — so editing or regenerating a patch left editor-godot/examples-mirror holding the
# previous one. Making it an always-run target fixed that here, and here is a separate
# build directory that nobody runs when only a patch has changed: regenerating the sfxr
# corpus left the mirror stale a second time, by a different route.
#
# The sync itself now lives in tools/mirror-examples.mjs, outside any one build, and the
# main test suite checks it. This target is the convenience, not the guarantee — and it
# walks the tree rather than naming three paths, so a new example is not a fourth way to
# be out of date.
# Done with CMake's own file commands rather than by shelling out to the Node script.
#
# It used to call tools/mirror-examples.mjs and, when node was absent, print a warning and
# mirror nothing — which leaves the editor project with no examples at all. That is not a
# missing convenience: editor_test.gd loads res://examples-mirror/first-synth.json, and a Mac
# without node is a Mac where the Godot editor has nothing to open. Node is not a
# prerequisite for building this, so it must not be one for the build's own output.
#
# tools/mirror-examples.mjs remains the authority — its --check runs in the test suite,
# and it is the thing that also catches orphans. This is the copy; that is the guarantee.
# The directory is emptied first so a deleted example cannot survive here — and the
# copy is copy_directory, not a per-file list. The previous version globbed the file
# names at *configure* time and then rm -rf'd the target at *build* time, which is a
# delete that stays current paired with a copy that does not: any patch added after the
# last configure was erased from the editor by the next extension rebuild. That is how
# the freshly imported FM library vanished — the same configure-time-snapshot trap this
# file already documents twice, wearing its third costume.
add_custom_target(soundgraph_godot_examples ALL
    COMMAND ${CMAKE_COMMAND} -E rm -rf ${SOUNDGRAPH_GODOT_EXAMPLES}
    COMMAND ${CMAKE_COMMAND} -E copy_directory
            ${SOUNDGRAPH_ROOT}/examples/patches
            ${SOUNDGRAPH_GODOT_EXAMPLES}
    COMMENT "Mirroring the example patches into editor-godot/examples-mirror"
)

# The build stamp: what the editor shows when asked what it is running.
#
# Always-run, like the mirror above and for the same reason — a stamp that is only
# refreshed when somebody remembers is a stamp that eventually describes a different
# build, which is the failure it exists to prevent. Node is not a prerequisite for
# building this extension, so a machine without it simply gets no stamp and the editor
# says "development build"; that degrades to the truth rather than to a wrong answer.
# The web export does its own stamping in tools/export-web.mjs, because the bundle a
# browser caches is the one where this question is hardest to answer by other means.
find_program(SOUNDGRAPH_STAMP_NODE node)
if(SOUNDGRAPH_STAMP_NODE)
    add_custom_target(soundgraph_build_stamp ALL
        COMMAND ${SOUNDGRAPH_STAMP_NODE} ${SOUNDGRAPH_ROOT}/tools/stamp-build.mjs
                --target desktop
        COMMENT "Stamping the build"
    )
endif()
