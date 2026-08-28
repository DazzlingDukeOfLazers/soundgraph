# sg-transcribe — built only when ONNX Runtime has been pointed at.
#
# Every other target here builds from what is in the repository. This one needs a
# prebuilt runtime that is 15 MB of DLL and platform-specific, which is not a thing to
# vendor into git, so it is optional in exactly the way the Godot suites are optional:
# tell the repository where it is, or do not, and the build works either way.
#
#   git config soundgraph.onnxruntime /path/to/onnxruntime-<platform>-<version>
#
# Downloads live at https://github.com/microsoft/onnxruntime/releases - the plain CPU
# archive, not the GPU one. The directory wanted is the one containing include/ and lib/.
#
# Nothing in dsp-core, patch-io, the editor or the firmware depends on this target. It is
# a tool that reads a file and writes two others.

# Captured while this file is being read. Inside a function body CMAKE_CURRENT_LIST_DIR
# follows the caller, not the definition, so reading it in there finds tools/ and the
# sources resolve to nothing.
set(SG_TRANSCRIBE_DIR ${CMAKE_CURRENT_LIST_DIR})

function(soundgraph_add_transcriber)
    execute_process(
        COMMAND git config soundgraph.onnxruntime
        WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
        OUTPUT_VARIABLE onnx_root
        OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_QUIET
    )

    if(onnx_root STREQUAL "")
        message(STATUS
            "sg-transcribe: skipped (git config soundgraph.onnxruntime is unset)")
        return()
    endif()

    if(NOT EXISTS "${onnx_root}/include/onnxruntime_cxx_api.h")
        message(WARNING
            "sg-transcribe: ${onnx_root} has no include/onnxruntime_cxx_api.h; skipping")
        return()
    endif()

    # The import library is named differently per platform, and there is no find module
    # worth the trouble for a single optional tool.
    if(WIN32)
        set(onnx_lib "${onnx_root}/lib/onnxruntime.lib")
        set(onnx_runtime_binary "${onnx_root}/lib/onnxruntime.dll")
    elseif(APPLE)
        set(onnx_lib "${onnx_root}/lib/libonnxruntime.dylib")
        set(onnx_runtime_binary "${onnx_lib}")
    else()
        set(onnx_lib "${onnx_root}/lib/libonnxruntime.so")
        set(onnx_runtime_binary "${onnx_lib}")
    endif()

    if(NOT EXISTS "${onnx_lib}")
        message(WARNING "sg-transcribe: no library at ${onnx_lib}; skipping")
        return()
    endif()

    add_executable(sg-transcribe
        ${SG_TRANSCRIBE_DIR}/main.cpp
        ${SG_TRANSCRIBE_DIR}/audio_load.cpp
        ${SG_TRANSCRIBE_DIR}/basic_pitch.cpp
        ${SG_TRANSCRIBE_DIR}/midi_write.cpp
        ${SG_TRANSCRIBE_DIR}/resample.cpp
    )
    target_include_directories(sg-transcribe PRIVATE
        ${onnx_root}/include
        ${SG_TRANSCRIBE_DIR}
        # The vendored miniaudio header, shared with the native runtime. Only the header:
        # runtime-native's translation unit is built with MA_NO_DECODING, because over
        # there miniaudio is a sound card. audio_load.cpp is the mirror image.
        ${CMAKE_SOURCE_DIR}/runtime-native/third_party/miniaudio
    )
    target_link_libraries(sg-transcribe PRIVATE
        soundgraph::patch_io
        ${onnx_lib}
    )

    # 95,000 lines of somebody else's C, which has no interest in this project's warning
    # settings. The same exemption runtime-native gives its own copy.
    if(MSVC)
        set_source_files_properties(${SG_TRANSCRIBE_DIR}/audio_load.cpp
            PROPERTIES COMPILE_OPTIONS /W0)
    else()
        set_source_files_properties(${SG_TRANSCRIBE_DIR}/audio_load.cpp
            PROPERTIES COMPILE_OPTIONS -w)
    endif()

    # The model sits beside the executable, which is where main.cpp looks by default.
    # Copied rather than found by a path baked in at configure time, so that a built
    # tree can be moved or copied to another machine and still work.
    add_custom_command(TARGET sg-transcribe POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            ${SG_TRANSCRIBE_DIR}/model/nmp.onnx
            $<TARGET_FILE_DIR:sg-transcribe>/nmp.onnx
        COMMENT "Placing the Basic Pitch model beside sg-transcribe"
    )

    if(WIN32)
        # Windows resolves the DLL from the executable's own directory, and there is no
        # rpath to lean on the way there is elsewhere.
        add_custom_command(TARGET sg-transcribe POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy_if_different
                ${onnx_runtime_binary}
                $<TARGET_FILE_DIR:sg-transcribe>/
            COMMENT "Placing onnxruntime.dll beside sg-transcribe"
        )
    endif()

    message(STATUS "sg-transcribe: building against ${onnx_root}")
endfunction()
