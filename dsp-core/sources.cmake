# The source list, in one place.
#
# dsp-core is built by four separate build systems: CMake for native, WebAssembly and the
# Godot extension, and ESP-IDF's component system for the firmware. ESP-IDF cannot consume
# a CMake target from outside its own tree, so it has its own registration — and for a
# while that meant its own hand-copied list of the same files.
#
# That list drifted the first time a file was added. `shaping.cpp` landed with the AHD
# envelope, the slide, the arpeggio, the phaser and the retrigger, and the firmware quietly
# went on being built without any of them: it would have flashed, booted, and then rejected
# every patch that used a node it had never been told about. Nothing failed at build time,
# because nothing was wrong at build time.
#
# So the list lives here and both include it. A new node is now one edit, not two, and
# forgetting the second one is no longer possible.

set(SOUNDGRAPH_DSP_SOURCES
    src/types.cpp
    src/node.cpp
    src/graph_description.cpp
    src/graph.cpp
    src/registry.cpp
    src/lpc_encoder.cpp
    src/nodes/sources.cpp
    src/nodes/filters.cpp
    src/nodes/amplitude.cpp
    src/nodes/maths.cpp
    src/nodes/terminals.cpp
    src/nodes/shaping.cpp
    src/nodes/speech.cpp
)

set(SOUNDGRAPH_PATCH_IO_SOURCES
    src/json.cpp
    src/patch_io.cpp
)
