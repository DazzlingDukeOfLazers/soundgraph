#!/bin/sh
# The gate a push has to get through: build, ctest, and the three Godot suites.
#
# It exists because two of those ctest cases — node_demos_match_the_registry and
# game_sounds_match_the_corpus — went red and stayed red across several commits without
# anybody noticing. They are the checks that catch a *generated* file edited by hand
# instead of the generator that writes it, which is a mistake that looks fixed until
# something regenerates. A check nothing runs is a comment.
#
# Deliberately the whole suite rather than the two cheap cases. Picking the checks that
# would have caught last time's mistake is how a suite becomes a monument to old bugs;
# the run is about a minute and a half, which is cheaper than a bad push.
#
# Machine-specific paths are read from git config so this file stays the same everywhere:
#
#   git config soundgraph.godot "/path/to/godot_console"   # optional; suites skip without
#   git config soundgraph.build "build"                    # optional; defaults to build/
#
# Escape hatch: git push --no-verify. Use it for a push that cannot break anything —
# a docs branch, a WIP spike — and not to get past a red suite.

set -e

root=$(git rev-parse --show-toplevel)
cd "$root"

build=$(git config --get soundgraph.build || echo build)
godot=${SOUNDGRAPH_GODOT:-$(git config --get soundgraph.godot || true)}

say() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ---- the stale-extension trap, closed ------------------------------------------------
# The Godot tests load editor-godot/bin/soundgraph_godot.dll, and a green suite against
# an old binary proves nothing about the code being pushed. The repository's notes call
# this the trap that fails nowhere near the cause; here it fails exactly at the cause.
dll="editor-godot/bin/soundgraph_godot.dll"
if [ -f "$dll" ]; then
    stale=$(find dsp-core/src dsp-core/include patch-io/src runtime-godot/src         \( -name '*.cpp' -o -name '*.h' \) -newer "$dll" 2>/dev/null | head -1)
    if [ -n "$stale" ]; then
        echo "the Godot extension is stale: $stale is newer than $dll" >&2
        echo "run tools/rebuild-extensions.sh, then push again" >&2
        exit 1
    fi
fi

# ---- build ---------------------------------------------------------------------------
# Before ctest, because ctest against binaries older than the source is a suite that
# reports on a program nobody is pushing.
if [ -d "$build" ]; then
    say "building $build"
    if ! cmake --build "$build" >/dev/null 2>&1; then
        # MSVC needs its environment and a git hook does not inherit one. Try the usual
        # place before giving up, so this works from an ordinary shell on Windows.
        # Spelled 8.3 and unredirected on purpose — see tools/rebuild-extensions.sh
        # for the three MSYS traps this line walks around (quote mangling, spaces,
        # and `>nul` becoming /dev/null inside the argument).
        # Asked for rather than assumed. The Community edition was hard-coded here, and
        # this machine has Build Tools under Program Files (x86) instead — so the fallback
        # silently did not apply and the gate reported a build failure whose real cause was
        # a path that had stopped existing. vswhere ships with every installation since
        # 2017 and is itself at a fixed location, which is the one path worth hard-coding.
        vswhere="C:/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe"
        vsroot=""
        if [ -x "$vswhere" ]; then
            vsroot=$("$vswhere" -latest -products '*' \
                -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 \
                -property installationPath 2>/dev/null | tr -d '\r')
        fi
        vcvars="$vsroot/VC/Auxiliary/Build/vcvars64.bat"
        if [ -n "$vsroot" ] && [ -f "$vcvars" ]; then
            # Through a batch file rather than inline: the 8.3 spelling this used to need
            # only existed to dodge the spaces, and a discovered path can contain anything.
            # See tools/rebuild-extensions.sh for the MSYS quoting traps either way.
            runner=$(mktemp --suffix=.bat)
            printf '@echo off\r\ncall "%s" >nul\r\ncmake --build build\r\n' \
                "$(cygpath -w "$vcvars")" > "$runner"
            cmd //c "$(cygpath -w "$runner")" || {
                rm -f "$runner"
                echo "build failed — fix it before pushing" >&2
                exit 1
            }
            rm -f "$runner"
        else
            echo "build failed — run cmake --build $build to see why" >&2
            echo "  (no Visual Studio with the C++ tools found via vswhere)" >&2
            exit 1
        fi
    fi
else
    echo "no $build directory; skipping the native build and ctest" >&2
fi

# ---- ctest ---------------------------------------------------------------------------
if [ -d "$build" ]; then
    say "ctest"
    ( cd "$build" && ctest --output-on-failure ) || {
        echo "ctest failed — fix it before pushing" >&2
        exit 1
    }
fi

# ---- the editor suites ----------------------------------------------------------------
# A script error inside _initialize skips quit() and presents as a hang rather than a
# failure, so these are given a timeout they should never reach.
if [ -n "$godot" ] && [ -x "$godot" ]; then
    for suite in editor_test design_test layout_test; do
        say "godot: $suite"
        output=$( cd editor-godot && "$godot" --headless --path . --script "$suite.gd" 2>&1 ) || true
        echo "$output" | grep -E "FAIL|checks passed|checks failed" || true
        # Tested for the word "passed" rather than for "failed", and its exit status is
        # not consulted at all: Godot exits non-zero on a clean run here (leaked
        # ObjectDB instances at teardown), and a script error inside _initialize skips
        # quit() entirely, so a broken suite can print no verdict at all. Requiring the
        # conclusion is the only reading that treats silence as bad news.
        if ! echo "$output" | grep -q "checks passed"; then
            echo "$suite did not report success — fix it before pushing" >&2
            exit 1
        fi
    done
else
    echo "" >&2
    echo "godot not configured; the editor suites did not run." >&2
    echo "  git config soundgraph.godot /path/to/godot_console" >&2
fi

say "all checks passed"
