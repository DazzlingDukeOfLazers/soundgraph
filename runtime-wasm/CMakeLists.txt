# The browser target.
#
# This produces a bare .wasm with no JavaScript glue. That is deliberate: the DSP has to
# run inside an AudioWorklet, and the AudioWorkletGlobalScope has no fetch, no TextDecoder
# and no module imports, so a generated glue file is a liability there. Instantiating the
# module by hand against a handful of WASI stubs is less code and fails in obvious ways.
add_executable(soundgraph-wasm src/bindings.cpp)

target_link_libraries(soundgraph-wasm PRIVATE soundgraph::patch_io)

set_target_properties(soundgraph-wasm PROPERTIES
    OUTPUT_NAME "soundgraph"
    SUFFIX ".wasm"
)

# Neither is used anywhere in the core, and dropping them roughly halves the binary.
target_compile_options(soundgraph-wasm PRIVATE -fno-exceptions -fno-rtti -Os)

target_link_options(soundgraph-wasm PRIVATE
    --no-entry
    -sSTANDALONE_WASM=1
    -sEXPORTED_FUNCTIONS=_malloc,_free
    # Fixed, not growable: a growing heap detaches every Float32Array the worklet holds,
    # and re-deriving those views on the audio thread is a bug waiting to happen. 32 MB
    # leaves room for roughly eighty maximum-length delay lines.
    -sINITIAL_MEMORY=33554432
    -sALLOW_MEMORY_GROWTH=0
    -sERROR_ON_UNDEFINED_SYMBOLS=1
    -sASSERTIONS=0
    -Os
)

# Drop the built module where the web host expects to load it from.
add_custom_command(TARGET soundgraph-wasm POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
            $<TARGET_FILE:soundgraph-wasm>
            ${CMAKE_SOURCE_DIR}/editor-web/soundgraph.wasm
    COMMENT "Copying soundgraph.wasm into editor-web/"
)
