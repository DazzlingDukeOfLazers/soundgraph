# dsp-core owns graph semantics. It links against nothing.
# The file list is shared with the ESP-IDF component; see sources.cmake for why.
include(${CMAKE_CURRENT_LIST_DIR}/sources.cmake)

add_library(soundgraph-dsp STATIC ${SOUNDGRAPH_DSP_SOURCES})

target_include_directories(soundgraph-dsp
    PUBLIC  ${CMAKE_CURRENT_SOURCE_DIR}/include
    PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/src
)

target_compile_features(soundgraph-dsp PUBLIC cxx_std_17)

add_library(soundgraph::dsp ALIAS soundgraph-dsp)
