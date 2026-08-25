# Building the plugin host from more than one build tree.
#
# This started life inside plugin-host/CMakeLists.txt, where it could assume it was a
# guest in the plugin's build: clap-wrapper had already fetched the VST3 SDK and already
# compiled base-sdk-vst3, so the host library simply borrowed both. That assumption is
# exactly what stopped the Godot extension from hosting anything — runtime-godot is a
# separate configuration that has never heard of clap-wrapper and never will.
#
# So the host now stands on its own: it finds the SDKs, compiles the host-side subset of
# the VST3 SDK itself, and links nothing from the plugin side. That is the right shape
# anyway. A host depending on the build of the plugin it is meant to load is backwards.
#
# Two entry points:
#   soundgraph_find_plugin_sdks(<clap-var> <vst3-var>)  — sets each to a path or ""
#   soundgraph_add_plugin_host(<target>)                — the static library
#
# Neither is fatal when the SDKs are absent. A build without them is a build that cannot
# host plugins, which is a fact about the machine rather than an error — the same stance
# dsp-core takes when there is no provider at all.

# Where the SDKs might be. In order: whatever the caller said, the source tree (where
# tools/get-plugin-sdks.sh puts the CLAP SDK), and the plugin build's CPM directory,
# which is where clap-wrapper drops the VST3 SDK on first configure. That last one is a
# build directory and a poor place to depend on, so it is tried last and never required.
function(soundgraph_find_plugin_sdks clap_out vst3_out)
    set(root ${CMAKE_CURRENT_FUNCTION_LIST_DIR}/..)

    set(clap "")
    foreach(candidate ${SOUNDGRAPH_CLAP_SDK} ${root}/runtime-clap/sdks/clap)
        if(EXISTS ${candidate}/include/clap/clap.h)
            set(clap ${candidate})
            break()
        endif()
    endforeach()

    set(vst3 "")
    foreach(candidate ${SOUNDGRAPH_VST3_SDK}
                      ${root}/runtime-clap/sdks/vst3sdk
                      ${root}/build-clap/runtime-clap/cpm/vst3sdk
                      ${root}/build/runtime-clap/cpm/vst3sdk)
        if(EXISTS ${candidate}/public.sdk/source/vst/hosting/module.h)
            set(vst3 ${candidate})
            break()
        endif()
    endforeach()

    set(${clap_out} "${clap}" PARENT_SCOPE)
    set(${vst3_out} "${vst3}" PARENT_SCOPE)
endfunction()

# The loaders, the provider, and enough of the VST3 SDK to host with.
#
# The source list below is deliberately not clap-wrapper's: theirs is a plugin's list and
# carries pluginfactory, vstaudioeffect, vstsinglecomponenteffect and the rest of the
# machinery for *being* a VST3. A host needs none of that. What it needs is the base
# library, the interface ids, and the hosting helpers Steinberg ships as sources because
# their implementation is per-platform.
function(soundgraph_add_plugin_host target)
    soundgraph_find_plugin_sdks(clap vst3)
    if(NOT clap OR NOT vst3)
        message(FATAL_ERROR
            "soundgraph_add_plugin_host: SDKs missing (clap='${clap}' vst3='${vst3}'). "
            "Call soundgraph_find_plugin_sdks first and skip this target when either is empty.")
    endif()

    set(here ${CMAKE_CURRENT_FUNCTION_LIST_DIR})

    file(GLOB vst3_base
            ${vst3}/base/source/*.cpp
            ${vst3}/base/thread/source/*.cpp
            ${vst3}/pluginterfaces/base/*.cpp
            ${vst3}/public.sdk/source/common/*.cpp)

    set(vst3_hosting
            ${vst3}/public.sdk/source/vst/vstinitiids.cpp
            ${vst3}/public.sdk/source/vst/utility/stringconvert.cpp
            ${vst3}/public.sdk/source/vst/hosting/module.cpp
            ${vst3}/public.sdk/source/vst/hosting/hostclasses.cpp
            # HostApplication's constructor builds one of these, so the two travel together.
            ${vst3}/public.sdk/source/vst/hosting/pluginterfacesupport.cpp
            ${vst3}/public.sdk/source/vst/hosting/eventlist.cpp
            ${vst3}/public.sdk/source/vst/hosting/parameterchanges.cpp
            ${vst3}/public.sdk/source/vst/hosting/processdata.cpp)
    if(WIN32)
        list(APPEND vst3_hosting ${vst3}/public.sdk/source/vst/hosting/module_win32.cpp)
    elseif(APPLE)
        list(APPEND vst3_hosting ${vst3}/public.sdk/source/vst/hosting/module_mac.mm)
    else()
        list(APPEND vst3_hosting ${vst3}/public.sdk/source/vst/hosting/module_linux.cpp)
    endif()

    add_library(${target} STATIC
            ${here}/src/host_clap.cpp
            ${here}/src/host_vst3.cpp
            ${here}/src/desktop_provider.cpp
            ${vst3_base}
            ${vst3_hosting})

    # Steinberg's headers pick their assertions and their debug-only members from one of
    # these two, and disagreeing about which is an ODR violation that presents as a
    # crash inside the SDK rather than as a link error.
    target_compile_definitions(${target} PUBLIC
            $<IF:$<CONFIG:Debug>,DEVELOPMENT=1,RELEASE=1>)

    target_include_directories(${target}
            PUBLIC ${here}/src
            PRIVATE ${clap}/include ${vst3} ${vst3}/public.sdk ${vst3}/pluginterfaces)
    target_link_libraries(${target} PUBLIC soundgraph::dsp PRIVATE ${CMAKE_DL_LIBS})
    target_compile_features(${target} PUBLIC cxx_std_17)

    # The SDK does not survive a unity build, and its warnings are not ours to fix. The
    # silencing is per-source rather than per-target on purpose: our three files are
    # ours, and a build that hides warnings in them to quieten somebody else's headers
    # has traded away the wrong thing.
    #
    # Nothing is silenced under MSVC, because measuring it said there was nothing to
    # silence: this subset builds clean at /W4. Adding /W0 anyway cost twenty lines of
    # D9025 per build to suppress warnings that were never emitted. GCC and Clang are a
    # different story — the SDK there reaches Steinberg's own #warning directives and
    # some long-long format mismatches, which is why clap-wrapper turns those off too.
    set_target_properties(${target} PROPERTIES UNITY_BUILD FALSE)
    if(NOT MSVC)
        set_source_files_properties(${vst3_base} ${vst3_hosting}
                PROPERTIES COMPILE_OPTIONS "-w")
    endif()

    if(WIN32)
        # module_win32 walks bundle directories with the Shell API and reports versions
        # through the Version API; neither is linked by default.
        target_link_libraries(${target} PRIVATE shell32 ole32 version)
    endif()

    set(SOUNDGRAPH_CLAP_SDK_FOUND ${clap} PARENT_SCOPE)
    set(SOUNDGRAPH_VST3_SDK_FOUND ${vst3} PARENT_SCOPE)
endfunction()
