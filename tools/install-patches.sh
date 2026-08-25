#!/bin/sh
# Copies the example patches into the folder the plugin scans on this machine, so the
# Patch selector has something to select. On macOS that is the Audio Presets folder —
# NOT ~/Documents, which is TCC-gated and breaks sandboxed plugin hosts. The selector
# lists at most 256 patches, so this installs the musical subsets rather than the whole
# corpus (nodes/ demo patches and the like stay home).
set -e

source_root="$(cd "$(dirname "$0")/.." && pwd)/examples/patches"
case "$(uname)" in
    Darwin) target="$HOME/Library/Audio/Presets/SoundGraph/Patches" ;;
    MINGW*|MSYS*|CYGWIN*)
        # The plugin reads %USERPROFILE%\Documents on Windows; git-bash's $HOME is
        # whatever some installer last vandalised it to (SPB_Data, on the machine
        # that found this), so USERPROFILE is the only name that agrees with the
        # plugin about where Documents is.
        target="$(cygpath "$USERPROFILE")/Documents/SoundGraph/Patches" ;;
    *)      target="$HOME/Documents/SoundGraph/Patches" ;;
esac

mkdir -p "$target"

for entry in synths drums drums606 drums909 dx7 fm game \
             first-synth.json plucked-string.json delay-echo.json warehouse.json \
             envelope-amp.json filter-envelope.json break-chopper.json kit-chopper.json; do
    if [ -e "$source_root/$entry" ]; then
        cp -R "$source_root/$entry" "$target/"
    fi
done

echo "installed $(find "$target" -name '*.json' | wc -l | tr -d ' ') patches into $target"
