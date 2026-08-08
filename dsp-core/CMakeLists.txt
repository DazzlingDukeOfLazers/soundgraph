# dsp-core owns graph semantics. It links against nothing.
add_library(soundgraph-dsp STATIC
    src/types.cpp
    src/node.cpp
    src/graph_description.cpp
    src/graph.cpp
    src/registry.cpp
    src/nodes/sources.cpp
    src/nodes/filters.cpp
    src/nodes/amplitude.cpp
    src/nodes/terminals.cpp
    src/nodes/shaping.cpp
)

target_include_directories(soundgraph-dsp
    PUBLIC  ${CMAKE_CURRENT_SOURCE_DIR}/include
    PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/src
)

target_compile_features(soundgraph-dsp PUBLIC cxx_std_17)

add_library(soundgraph::dsp ALIAS soundgraph-dsp)
