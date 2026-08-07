# WAV reading and writing. Used by the tools and by the golden tests, so it is built
# whether or not the command line tools are enabled.
add_library(soundgraph-wav STATIC wav.cpp)
target_include_directories(soundgraph-wav PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
target_compile_features(soundgraph-wav PUBLIC cxx_std_17)
add_library(soundgraph::wav ALIAS soundgraph-wav)
