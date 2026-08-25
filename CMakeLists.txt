cmake_minimum_required(VERSION 3.20)
project(soundgraph LANGUAGES CXX VERSION 0.1.0)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()

if(MSVC)
    add_compile_options(/W4 /permissive-)
    # dsp-core must never depend on locale/exception-heavy CRT extras.
    add_compile_definitions(_CRT_SECURE_NO_WARNINGS NOMINMAX)
else()
    add_compile_options(-Wall -Wextra -Wpedantic)
endif()

set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)

option(SOUNDGRAPH_BUILD_TESTS "Build the test suite" ON)
option(SOUNDGRAPH_BUILD_TOOLS "Build the command line tools" ON)
option(SOUNDGRAPH_BUILD_NATIVE_RUNTIME "Build the native live-audio host" ON)
# Off by default: needs SDKs the ordinary build must not depend on. See runtime-clap/.
option(SOUNDGRAPH_CLAP "Build the CLAP/VST3/AU plugin" OFF)

# One CRT for the whole plugin. clap-wrapper statically links the MSVC runtime for
# everything under its own roof, but the wrapper *entry* objects are compiled in this
# project's scope — without this they default to the DLL runtime and the VST3 dies in
# a hail of LNK2038 mismatches. Set before any target exists so every object agrees.
if(SOUNDGRAPH_CLAP AND MSVC AND NOT DEFINED CMAKE_MSVC_RUNTIME_LIBRARY)
    set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
endif()

# A WebAssembly configuration builds only the core and the browser binding. Everything
# else — device hosts, file tools, the test runners — is a native concern.
if(EMSCRIPTEN)
    set(SOUNDGRAPH_BUILD_TESTS OFF)
    set(SOUNDGRAPH_BUILD_TOOLS OFF)
    set(SOUNDGRAPH_BUILD_NATIVE_RUNTIME OFF)
endif()

add_subdirectory(dsp-core)
add_subdirectory(patch-io)

if(EMSCRIPTEN)
    add_subdirectory(runtime-wasm)
else()
    add_subdirectory(tools/common)
endif()

if(SOUNDGRAPH_BUILD_TOOLS)
    add_subdirectory(tools)
endif()

if(SOUNDGRAPH_BUILD_NATIVE_RUNTIME)
    add_subdirectory(runtime-native)
endif()

# Before any directory that registers tests: enable_testing() only covers directories
# added after it.
if(SOUNDGRAPH_BUILD_TESTS)
    enable_testing()
endif()

if(SOUNDGRAPH_CLAP AND NOT EMSCRIPTEN)
    if(APPLE)
        # clap-wrapper's AU and standalone shells are Objective-C++. Enabling the
        # languages from within a subdirectory leaves later sibling directories without
        # compile rules, so it happens here at the top.
        enable_language(OBJC OBJCXX)
    endif()
    add_subdirectory(runtime-clap)
    # The headless host rides the same switch: it tests the artifacts runtime-clap
    # builds, and it needs the same fetched CLAP and VST3 SDKs.
    add_subdirectory(plugin-host)
endif()

if(SOUNDGRAPH_BUILD_TESTS)
    add_subdirectory(tests)
endif()
