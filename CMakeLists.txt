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

add_subdirectory(dsp-core)
add_subdirectory(patch-io)
add_subdirectory(tools/common)

if(SOUNDGRAPH_BUILD_TOOLS)
    add_subdirectory(tools)
endif()

if(SOUNDGRAPH_BUILD_NATIVE_RUNTIME)
    add_subdirectory(runtime-native)
endif()

if(SOUNDGRAPH_BUILD_TESTS)
    enable_testing()
    add_subdirectory(tests)
endif()
