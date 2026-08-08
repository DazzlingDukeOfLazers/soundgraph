add_executable(sg-validate sg-validate/main.cpp)
target_link_libraries(sg-validate PRIVATE soundgraph::patch_io)

add_executable(sg-render sg-render/main.cpp)
target_link_libraries(sg-render PRIVATE soundgraph::patch_io soundgraph::wav)

# The sfxr oracle. Links the vendored reference under tests/ and the WAV writer, and
# nothing else: dsp-core must not acquire a dependency on the thing it is measured against.
add_executable(sfxr-ref
    sfxr-ref/main.cpp
    ${CMAKE_SOURCE_DIR}/tests/sfxr/reference/sfxr_reference.cpp
)
target_include_directories(sfxr-ref PRIVATE ${CMAKE_SOURCE_DIR}/tests/sfxr/reference)
target_link_libraries(sfxr-ref PRIVATE soundgraph::wav)
