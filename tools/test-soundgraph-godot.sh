#!/usr/bin/env bash
# Builds the extensions, then launches the SoundGraph editor in Godot — the Git Bash
# twin of test-soundgraph-godot.bat, for people who live in this shell rather than cmd.
#
# Same contract as the bat: a rebuild first (under four seconds when nothing changed),
# a refusal to launch on a failed build rather than showing code that no longer
# exists, and --no-build to skip the rebuild on purpose.
#
#   git config soundgraph.godot "C:/path/to/Godot_console.exe"
set -e
cd "$(dirname "$0")/.."

skip_build=""
args=()
for arg in "$@"; do
    if [ "$arg" = "--no-build" ]; then
        skip_build=1
    else
        args+=("$arg")
    fi
done

godot=$(git config --get soundgraph.godot || true)
if [ -z "$godot" ]; then
    echo "soundgraph.godot is not configured. Set it with:" >&2
    echo '  git config soundgraph.godot "C:/path/to/Godot_console.exe"' >&2
    exit 1
fi
if [ ! -f "$godot" ]; then
    echo "Configured Godot binary not found: $godot" >&2
    exit 1
fi

if [ -z "$skip_build" ]; then
    if ! bash tools/rebuild-extensions.sh --desktop; then
        echo >&2
        echo "The extension build failed, so the editor was not launched -- running" >&2
        echo "the old DLL would show code that no longer exists. Fix the build, or" >&2
        echo "relaunch with --no-build to look at the previous binary on purpose." >&2
        exit 1
    fi
fi

exec "$godot" --path editor-godot "${args[@]}"
