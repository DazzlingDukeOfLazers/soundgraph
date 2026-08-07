# dsp-core + patch-io as an ESP-IDF component.
#
# The same source files the native, WebAssembly and Godot builds compile — no fork, no
# embedded-special copies. SOUNDGRAPH_NO_FILE_IO strips the file entry points (and with
# them <fstream>), exactly as the browser build does: on device, patch text arrives over
# serial or out of flash, never from a filesystem path.
set(SG_ROOT ${CMAKE_CURRENT_LIST_DIR}/../../..)

idf_component_register(
    SRCS
        ${SG_ROOT}/dsp-core/src/types.cpp
        ${SG_ROOT}/dsp-core/src/node.cpp
        ${SG_ROOT}/dsp-core/src/graph_description.cpp
        ${SG_ROOT}/dsp-core/src/graph.cpp
        ${SG_ROOT}/dsp-core/src/registry.cpp
        ${SG_ROOT}/dsp-core/src/nodes/sources.cpp
        ${SG_ROOT}/dsp-core/src/nodes/filters.cpp
        ${SG_ROOT}/dsp-core/src/nodes/amplitude.cpp
        ${SG_ROOT}/dsp-core/src/nodes/terminals.cpp
        ${SG_ROOT}/patch-io/src/json.cpp
        ${SG_ROOT}/patch-io/src/patch_io.cpp
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
