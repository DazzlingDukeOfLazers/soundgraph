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
# case so the host can verify this target against the same vectors native and WASM use.
set(SG_EMBED_PATCHES
    ${SG_ROOT}/examples/patches/first-synth.json
    ${SG_ROOT}/tests/golden/cases/sine.json
    ${SG_ROOT}/tests/golden/cases/saw.json
    ${SG_ROOT}/tests/golden/cases/square.json
    ${SG_ROOT}/tests/golden/cases/noise.json
    ${SG_ROOT}/tests/golden/cases/noise-pink.json
    ${SG_ROOT}/tests/golden/cases/lfo.json
    ${SG_ROOT}/tests/golden/cases/adsr.json
    ${SG_ROOT}/tests/golden/cases/filter-sweep.json
    ${SG_ROOT}/tests/golden/cases/delay-feedback.json
)

idf_component_register(
    SRCS main.cpp
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
