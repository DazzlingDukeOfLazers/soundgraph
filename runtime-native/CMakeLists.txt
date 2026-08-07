# The native live-audio host. A thin shell around a device and the graph.
add_library(soundgraph-miniaudio STATIC src/miniaudio_impl.cpp)
target_include_directories(soundgraph-miniaudio
    PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/third_party/miniaudio)

# Third-party code is not held to the project's warning settings.
if(MSVC)
    target_compile_options(soundgraph-miniaudio PRIVATE /W0)
else()
    target_compile_options(soundgraph-miniaudio PRIVATE -w)
endif()

if(UNIX AND NOT APPLE)
    find_package(Threads REQUIRED)
    target_link_libraries(soundgraph-miniaudio PUBLIC Threads::Threads ${CMAKE_DL_LIBS} m)
elseif(APPLE)
    target_link_libraries(soundgraph-miniaudio PUBLIC
        "-framework CoreFoundation" "-framework CoreAudio" "-framework AudioToolbox")
endif()

add_executable(sg-play src/main.cpp)
target_link_libraries(sg-play PRIVATE soundgraph::patch_io soundgraph-miniaudio)
