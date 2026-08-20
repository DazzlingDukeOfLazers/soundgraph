#!/usr/bin/env bash
# Rebuilds both Godot extensions — the desktop DLL and the wasm — in one command.
#
# These are the two builds the repository's own notes call the stale-extension trap:
# rebuild only one and the other keeps running old code, failing nowhere near the
# cause. The ritual was typed by hand six times in one working day before this file
# existed, which is the whole argument for it.
#
# Two Windows realities are handled rather than hoped away. A running editor holds
# the DLL open, which blocks cmake's copy step — renaming a mapped file is allowed,
# overwriting it is not, so on a copy failure the loaded file is moved aside and the
# build retried. And cmake's copy is "if different", which no-ops when there is
# nothing to relink — so the target's existence is checked afterwards rather than
# assumed, because this script's first version renamed the DLL aside, watched cmake
# decide nothing had changed, and deleted the only copy.
set -e
cd "$(dirname "$0")/.."

dll="editor-godot/bin/soundgraph_godot.dll"
vcvars="C:/Program Files/Microsoft Visual Studio/2022/Community/VC/Auxiliary/Build/vcvars64.bat"

build_desktop() {
    cmake --build runtime-godot/build >/dev/null 2>&1 \
        || cmd //c "\"$vcvars\" >nul && cmake --build runtime-godot/build"
}

echo "desktop extension"
if ! build_desktop; then
    # Most likely a running editor holding the DLL against the copy step.
    if [ -f "$dll" ]; then
        mv "$dll" "$dll.old"
    fi
    build_desktop || { echo "desktop extension build failed" >&2; exit 1; }
fi
if [ ! -f "$dll" ] && [ -f "runtime-godot/build/soundgraph_godot.dll" ]; then
    cp "runtime-godot/build/soundgraph_godot.dll" "$dll"
fi
rm -f "$dll.old" 2>/dev/null || true

echo "wasm extension"
cmd //c 'C:\Users\danie\emsdk\emsdk_env.bat >nul 2>&1 && cmake --build runtime-godot/build-web' || {
    echo "wasm extension build failed" >&2
    exit 1
}
wasm="editor-godot/bin/soundgraph_godot.web.wasm32.nothreads.wasm"
if [ ! -f "$wasm" ] && [ -f "runtime-godot/build-web/soundgraph_godot.web.wasm32.nothreads.wasm" ]; then
    cp "runtime-godot/build-web/soundgraph_godot.web.wasm32.nothreads.wasm" "$wasm"
fi

echo "both extensions rebuilt"
