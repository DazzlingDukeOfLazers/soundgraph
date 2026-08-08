# dsp-core + patch-io as an ESP-IDF component.
#
# The same source files the native, WebAssembly and Godot builds compile — no fork, no
# embedded-special copies. SOUNDGRAPH_NO_FILE_IO strips the file entry points (and with
# them <fstream>), exactly as the browser build does: on device, patch text arrives over
# serial or out of flash, never from a filesystem path.
set(SG_ROOT ${CMAKE_CURRENT_LIST_DIR}/../../..)

# The file list comes from dsp-core/sources.cmake, which the CMake builds also include.
# Two hand-copied lists that had to agree is exactly how shaping.cpp came to be missing
# here for a while — the firmware built cleanly and simply did not contain five nodes.
include(${SG_ROOT}/dsp-core/sources.cmake)

set(SG_SOURCES "")
foreach(source IN LISTS SOUNDGRAPH_DSP_SOURCES)
    list(APPEND SG_SOURCES ${SG_ROOT}/dsp-core/${source})
endforeach()
foreach(source IN LISTS SOUNDGRAPH_PATCH_IO_SOURCES)
    list(APPEND SG_SOURCES ${SG_ROOT}/patch-io/${source})
endforeach()

idf_component_register(
    SRCS ${SG_SOURCES}
    INCLUDE_DIRS
        ${SG_ROOT}/dsp-core/include
        ${SG_ROOT}/patch-io/include
    PRIV_INCLUDE_DIRS
        ${SG_ROOT}/dsp-core/src
        ${SG_ROOT}/patch-io/src
)

target_compile_definitions(${COMPONENT_LIB} PUBLIC SOUNDGRAPH_NO_FILE_IO)
target_compile_features(${COMPONENT_LIB} PUBLIC cxx_std_17)

# The audio render path should be optimised even in a default debug-ish build; the whole
# component is small enough that this costs nothing.
target_compile_options(${COMPONENT_LIB} PRIVATE -O2 -fno-exceptions -fno-rtti)
