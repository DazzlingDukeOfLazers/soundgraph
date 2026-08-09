# Regenerates the sfxr corpus into a scratch directory and checks it byte-for-byte against
# the committed one.
#
# The corpus is committed because a test that compares against a moving target is not a
# test. That only holds if regenerating gives back exactly the same bytes — sfxr pulls from
# a PRNG inside its audio loop, so the waveform depends on the generator, and the reference
# substitutes a fixed one precisely so this is true on every platform. If this test ever
# fails, every comparison in the rig has silently changed meaning.
#
# Run through ctest; see tests/CMakeLists.txt.

file(REMOVE_RECURSE "${SCRATCH}")
file(MAKE_DIRECTORY "${SCRATCH}/cases" "${SCRATCH}/vectors" "${SCRATCH}/patches")

execute_process(
    COMMAND "${SFXR_REF}" corpus "${SCRATCH}" --per-preset 6
    RESULT_VARIABLE generate_result
    OUTPUT_VARIABLE generate_output
    ERROR_VARIABLE generate_output
)
if(NOT generate_result EQUAL 0)
    message(FATAL_ERROR "sfxr-ref corpus failed:\n${generate_output}")
endif()

# The manifest lists what the corpus is meant to contain, so it is compared first: a
# difference here means the generator itself changed, which explains any vector that also
# differs and is the more useful thing to report.
file(READ "${CORPUS}/manifest.json" committed_manifest)
file(READ "${SCRATCH}/manifest.json" fresh_manifest)
if(NOT committed_manifest STREQUAL fresh_manifest)
    message(FATAL_ERROR
        "The regenerated manifest differs from the committed one.\n"
        "sfxr-ref no longer produces the corpus that is checked in — either the "
        "reference synthesis changed, or its substitute PRNG did. Every comparison in "
        "the rig is measured against these vectors, so this has to be understood before "
        "any result from it means anything.")
endif()

file(GLOB committed_vectors RELATIVE "${CORPUS}/vectors" "${CORPUS}/vectors/*.wav")
list(LENGTH committed_vectors committed_count)
if(committed_count EQUAL 0)
    message(FATAL_ERROR "No committed vectors found in ${CORPUS}/vectors")
endif()

set(differing "")
foreach(vector IN LISTS committed_vectors)
    file(SHA256 "${CORPUS}/vectors/${vector}" committed_hash)
    if(NOT EXISTS "${SCRATCH}/vectors/${vector}")
        list(APPEND differing "${vector} (not regenerated)")
        continue()
    endif()
    file(SHA256 "${SCRATCH}/vectors/${vector}" fresh_hash)
    if(NOT committed_hash STREQUAL fresh_hash)
        list(APPEND differing "${vector}")
    endif()
endforeach()

if(differing)
    string(REPLACE ";" "\n  " differing_text "${differing}")
    message(FATAL_ERROR
        "These vectors are not reproducible:\n  ${differing_text}")
endif()

# The patches are generated from the same parameters by the same run, so they have to be
# reproducible for the same reason — and a change here means the *mapping* moved, which is
# a much more interesting event than a vector changing. Every comparison in the report is
# rendered from these.
file(GLOB committed_patches RELATIVE "${CORPUS}/patches" "${CORPUS}/patches/*.json")
set(patch_differences "")
foreach(patch IN LISTS committed_patches)
    file(SHA256 "${CORPUS}/patches/${patch}" committed_hash)
    if(NOT EXISTS "${SCRATCH}/patches/${patch}")
        list(APPEND patch_differences "${patch} (not regenerated)")
        continue()
    endif()
    file(SHA256 "${SCRATCH}/patches/${patch}" fresh_hash)
    if(NOT committed_hash STREQUAL fresh_hash)
        list(APPEND patch_differences "${patch}")
    endif()
endforeach()

if(patch_differences)
    string(REPLACE ";" "\n  " patch_text "${patch_differences}")
    message(FATAL_ERROR
        "The mapping from sfxr parameters to patches has changed:\n  ${patch_text}\n"
        "If that was intended, regenerate the corpus and re-read the report — the "
        "numbers in it are now measuring something else.")
endif()

list(LENGTH committed_patches patch_count)
message(STATUS "${committed_count} sfxr vectors and ${patch_count} patches regenerated "
               "byte-identically")
