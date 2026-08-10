add_executable(sg-validate sg-validate/main.cpp)
target_link_libraries(sg-validate PRIVATE soundgraph::patch_io)

add_executable(sg-render sg-render/main.cpp)
target_link_libraries(sg-render PRIVATE soundgraph::patch_io soundgraph::wav)

# The sfxr oracle. Links the vendored reference under tests/ and the WAV writer, and
# nothing else: dsp-core must not acquire a dependency on the thing it is measured against.
add_executable(sfxr-ref
    sfxr-ref/main.cpp
    sfxr-ref/to_patch.cpp
    ${CMAKE_SOURCE_DIR}/tests/sfxr/reference/sfxr_reference.cpp
)
target_include_directories(sfxr-ref PRIVATE ${CMAKE_SOURCE_DIR}/tests/sfxr/reference)
target_link_libraries(sfxr-ref PRIVATE soundgraph::wav)

# No fused multiply-add in the oracle.
#
# The committed corpus is only a fixed target if regenerating it gives back the same
# bytes on every machine, which is why the reference already substitutes its own PRNG.
# Contraction breaks the same promise by a different route: clang fuses a*b+c into a
# single fma by default, which is more accurate and therefore *different*, and on Apple
# silicon every one of the 41 vectors came out changed — by about 1e-8, enough to fail a
# byte comparison and small enough to look like nothing.
#
# Only this target needs it. dsp-core is compared within declared tolerances and is free
# to be as accurate as the hardware allows; an oracle is not, because its whole job is to
# be the same thing twice.
if(MSVC)
    # /fp:precise is the default, but the default is what changed underfoot elsewhere.
    target_compile_options(sfxr-ref PRIVATE /fp:precise)
else()
    target_compile_options(sfxr-ref PRIVATE -ffp-contract=off)
endif()
