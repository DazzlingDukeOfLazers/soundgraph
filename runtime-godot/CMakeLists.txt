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

# Stated on the target as well as through the shared-library flags above: this has to be a
# side module however CMake decides to phrase the link line, and a missing SIDE_MODULE
# fails as "undefined symbol: main", which points nowhere near the cause.
if(EMSCRIPTEN)
    target_link_options(soundgraph_godot PRIVATE -sSIDE_MODULE=1)
endif()

# Godot loads the library by the exact name in soundgraph.gdextension. The web build gets
# a distinct name because it sits alongside the desktop one in the same bin directory and
# a .wasm is not interchangeable with a .dll.
if(EMSCRIPTEN)
    set_target_properties(soundgraph_godot PROPERTIES
        PREFIX ""
        OUTPUT_NAME "soundgraph_godot.web.wasm32.nothreads"
        SUFFIX ".wasm"
    )
else()
    set_target_properties(soundgraph_godot PROPERTIES
        PREFIX ""
        OUTPUT_NAME "soundgraph_godot"
    )
endif()

# Drop the built library where the Godot project expects it, and mirror the example
# patches in. Godot cannot read outside res://, and committing a second copy of the
# examples would be two files that eventually disagree — so they are copied, and
# editor-godot/bin and editor-godot/examples are both build output.
set(SOUNDGRAPH_GODOT_BIN ${SOUNDGRAPH_ROOT}/editor-godot/bin)
set(SOUNDGRAPH_GODOT_EXAMPLES ${SOUNDGRAPH_ROOT}/editor-godot/examples)

add_custom_command(TARGET soundgraph_godot POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory ${SOUNDGRAPH_GODOT_BIN}
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
            $<TARGET_FILE:soundgraph_godot> ${SOUNDGRAPH_GODOT_BIN}
    COMMAND ${CMAKE_COMMAND} -E make_directory ${SOUNDGRAPH_GODOT_EXAMPLES}
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
            ${SOUNDGRAPH_ROOT}/examples/patches/first-synth.json ${SOUNDGRAPH_GODOT_EXAMPLES}
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
            ${SOUNDGRAPH_ROOT}/examples/patches/delay-echo.json ${SOUNDGRAPH_GODOT_EXAMPLES}
    COMMENT "Copying the extension and example patches into editor-godot/"
)
