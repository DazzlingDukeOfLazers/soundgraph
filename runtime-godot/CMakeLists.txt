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

# Godot loads the library by the exact name in soundgraph.gdextension.
set_target_properties(soundgraph_godot PROPERTIES
    PREFIX ""
    OUTPUT_NAME "soundgraph_godot"
)

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
