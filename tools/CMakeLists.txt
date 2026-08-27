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

# The OPL2 oracle. Nuked-OPL3 is integer state machines throughout — bit-exact by
# construction, so it needs none of the float pinning the sfxr oracle does. Same
# isolation rule though: it links the vendored emulator (LGPL 2.1, licence in
# tests/opl2/reference/) and the WAV writer, and nothing links it.
# The top-level project enables only CXX, so the emulator's .c file would be silently
# skipped (one compile step, three unresolved externals — that is what it looks like).
# C is enabled here, where the one C file lives, rather than project-wide.
enable_language(C)
add_executable(opl2-ref
    opl2-ref/main.cpp
    ${CMAKE_SOURCE_DIR}/tests/opl2/reference/opl3.c
)
target_include_directories(opl2-ref PRIVATE ${CMAKE_SOURCE_DIR}/tests/opl2/reference)
target_link_libraries(opl2-ref PRIVATE soundgraph::wav)

# The DX7 oracle: the msfa engine (music-synthesizer-for-android, Apache 2.0, the
# core Dexed builds on), vendored under tests/dx7/reference/. Same isolation rule as
# the other two oracles: nothing links it.
add_executable(dx7-ref
    dx7-ref/main.cpp
    ${CMAKE_SOURCE_DIR}/tests/dx7/reference/dx7note.cc
    ${CMAKE_SOURCE_DIR}/tests/dx7/reference/env.cc
    ${CMAKE_SOURCE_DIR}/tests/dx7/reference/exp2.cc
    ${CMAKE_SOURCE_DIR}/tests/dx7/reference/fm_core.cc
    ${CMAKE_SOURCE_DIR}/tests/dx7/reference/fm_op_kernel.cc
    ${CMAKE_SOURCE_DIR}/tests/dx7/reference/freqlut.cc
    ${CMAKE_SOURCE_DIR}/tests/dx7/reference/lfo.cc
    ${CMAKE_SOURCE_DIR}/tests/dx7/reference/patch.cc
    ${CMAKE_SOURCE_DIR}/tests/dx7/reference/pitchenv.cc
    ${CMAKE_SOURCE_DIR}/tests/dx7/reference/sin.cc
)
target_include_directories(dx7-ref PRIVATE ${CMAKE_SOURCE_DIR}/tests/dx7/reference)
# msfa uses M_PI, which MSVC's <cmath> hides behind a feature macro.
target_compile_definitions(dx7-ref PRIVATE _USE_MATH_DEFINES)
target_link_libraries(dx7-ref PRIVATE soundgraph::wav)

# The transcriber. Optional: it needs a prebuilt ONNX Runtime, which is pointed at with
# `git config soundgraph.onnxruntime` rather than vendored, so a checkout that has never
# heard of it configures and builds exactly as before.
include(${CMAKE_CURRENT_LIST_DIR}/sg-transcribe/sg-transcribe.cmake)
soundgraph_add_transcriber()
