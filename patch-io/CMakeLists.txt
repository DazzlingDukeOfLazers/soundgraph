# patch-io is the only place that knows the canonical format is text.
add_library(soundgraph-patch-io STATIC
    src/json.cpp
    src/patch_io.cpp
)

target_include_directories(soundgraph-patch-io
    PUBLIC  ${CMAKE_CURRENT_SOURCE_DIR}/include
    PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/src
)

target_link_libraries(soundgraph-patch-io PUBLIC soundgraph::dsp)

# Targets without a filesystem receive patch text from their host instead of opening it.
# Excluding the file entry points also keeps <fstream> out of the WebAssembly build.
if(EMSCRIPTEN)
    target_compile_definitions(soundgraph-patch-io PUBLIC SOUNDGRAPH_NO_FILE_IO)
endif()

add_library(soundgraph::patch_io ALIAS soundgraph-patch-io)
