set(SG_ROOT ${CMAKE_CURRENT_LIST_DIR}/../../..)

# Which board this firmware is wired for. A board is a manifest, not a fork: the JSON
# under embedded/boards/ is canonical and a C header is generated from it at build time.
if(NOT DEFINED SG_BOARD)
    set(SG_BOARD "esp32-s3-devkitc-pcm5102")
endif()

file(GLOB_RECURSE SG_BOARD_JSON ${SG_ROOT}/embedded/boards/*/${SG_BOARD}/board.json)
if(SG_BOARD_JSON STREQUAL "")
    message(FATAL_ERROR "No board profile named '${SG_BOARD}' under embedded/boards/")
endif()

# board.json -> board_config.h. Generated at configure time — idf_component_register
# refuses an include directory that does not exist yet — and regenerated at build time
# whenever the manifest changes.
idf_build_get_property(sg_python PYTHON)
set(SG_BOARD_HEADER ${CMAKE_CURRENT_BINARY_DIR}/generated/board_config.h)
file(MAKE_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}/generated)
execute_process(
    COMMAND ${sg_python} ${SG_ROOT}/tools/board-generator/generate.py ${SG_BOARD_JSON} ${SG_BOARD_HEADER}
    RESULT_VARIABLE SG_BOARD_RESULT
)
if(NOT SG_BOARD_RESULT EQUAL 0)
    message(FATAL_ERROR "board-generator failed for ${SG_BOARD_JSON}")
endif()

# Patches baked into the firmware: the demo patch that plays at boot, and every golden
# case, so the host can verify this target against the same vectors native and WASM use.
#
# Read out of the golden manifest rather than listed here. This was a hand-written list
# twice over — the files to embed, and a name-to-symbol table in main.cpp — and both went
# stale the moment eight cases were added. The device answered "no embedded patch named
# 'slide'" for every one of them, which reads like a device problem and is a build-script
# problem. tests/golden/cases.json is the single definition of what the golden set is; it
# should be the only place that knows.
file(READ ${SG_ROOT}/tests/golden/cases.json SG_GOLDEN_MANIFEST)
string(JSON SG_CASE_COUNT LENGTH "${SG_GOLDEN_MANIFEST}" cases)

set(SG_EMBED_PATCHES ${SG_ROOT}/examples/patches/first-synth.json)
set(SG_PATCH_EXTERNS "")
set(SG_PATCH_TABLE "")

# The boot patch is not a golden case, so it is named explicitly; the rest come from the
# manifest in its own order.
set(SG_PATCH_NAMES "first-synth")
math(EXPR SG_LAST_CASE "${SG_CASE_COUNT} - 1")
foreach(index RANGE ${SG_LAST_CASE})
    string(JSON SG_CASE_NAME GET "${SG_GOLDEN_MANIFEST}" cases ${index} name)
    list(APPEND SG_EMBED_PATCHES ${SG_ROOT}/tests/golden/cases/${SG_CASE_NAME}.json)
    list(APPEND SG_PATCH_NAMES ${SG_CASE_NAME})
endforeach()

# ESP-IDF turns each embedded file into _binary_<name>_start, with every character that is
# not a letter or a digit replaced by an underscore. Deriving the symbol the same way is
# what lets the table below be generated rather than typed.
foreach(patch_name IN LISTS SG_PATCH_NAMES)
    string(REGEX REPLACE "[^A-Za-z0-9]" "_" SG_SYMBOL "${patch_name}")
    string(APPEND SG_PATCH_EXTERNS
        "extern const char _binary_${SG_SYMBOL}_json_start[];
")
    string(APPEND SG_PATCH_TABLE
        "    {\"${patch_name}\", _binary_${SG_SYMBOL}_json_start},
")
endforeach()

configure_file(${CMAKE_CURRENT_LIST_DIR}/embedded_patches.h.in
               ${CMAKE_CURRENT_BINARY_DIR}/generated/embedded_patches.h @ONLY)

idf_component_register(
    SRCS main.cpp codec_init.cpp speech.cpp
    INCLUDE_DIRS ${CMAKE_CURRENT_BINARY_DIR}/generated
    PRIV_REQUIRES soundgraph-core driver nvs_flash
    EMBED_TXTFILES ${SG_EMBED_PATCHES}
)

add_custom_command(
    OUTPUT ${SG_BOARD_HEADER}
    COMMAND ${sg_python} ${SG_ROOT}/tools/board-generator/generate.py ${SG_BOARD_JSON} ${SG_BOARD_HEADER}
    DEPENDS ${SG_BOARD_JSON} ${SG_ROOT}/tools/board-generator/generate.py
    COMMENT "Generating board header for ${SG_BOARD}"
)
add_custom_target(sg_board_header DEPENDS ${SG_BOARD_HEADER})
add_dependencies(${COMPONENT_LIB} sg_board_header)
