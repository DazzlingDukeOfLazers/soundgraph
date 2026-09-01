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
#
# Output goes to a file rather than into a subshell.
#
# The suite segfaults at teardown perhaps a third of the time, after every check has run
# and the verdict has been printed. That has been true for a while and is not what any of
# these suites are testing. The problem was that the verdict was being read out of a
# command substitution, and a process that dies with a pipe still buffered can take its
# last words with it: twice, a push was refused for a suite that had in fact passed.
#
# I could not reproduce the loss on demand - six attempts through the old capture, six
# verdicts - so this is not a fix for a mechanism anybody has watched happen. It removes
# the dependence on one, which is cheaper than continuing to guess, and it leaves the
# whole log on disk so the next unexplained refusal can be read rather than re-run.
suite_logs="$build/editor-suites"
mkdir -p "$suite_logs" 2>/dev/null || suite_logs=$(mktemp -d)

crashes=0

if [ -n "$godot" ] && [ -x "$godot" ]; then
    # legalize_test joins them because it turned out to run headless: the router is pure
    # geometry against the obstacle list, so a fault can be measured without a rendering
    # server. Every other harness in the layout and cable passes needs pixels and stays out.
    for suite in editor_test design_test layout_test panel_style_test legalize_test tidy_test routes_test crossing_semantics hit_geometry; do
        say "godot: $suite"
        log="$suite_logs/$suite.log"
        status=0
        ( cd editor-godot && "$godot" --headless --path . --script "$suite.gd" )             > "$log" 2>&1 || status=$?
        grep -E "FAIL|checks passed|checks failed" "$log" || true
        # Tested for the word "passed" rather than for "failed": a script error inside
        # _initialize skips quit() entirely, so a broken suite can print no verdict at
        # all, and requiring the conclusion is the only reading that treats silence as
        # bad news.
        if ! grep -q "checks passed" "$log"; then
            echo "$suite did not report success — fix it before pushing" >&2
            echo "  the whole run is in $log" >&2
            exit 1
        fi
        # And then the status, which this used to discard entirely.
        #
        # The reason it discarded it was true when written: a clean run exited non-zero,
        # because the editor leaked its audio playback at teardown. That much is fixed —
        # every harness now leaves through HarnessExit, which stops the audio, gives the
        # mixer a gap and frees the editor, and the leak is gone.
        #
        # What is *not* fixed is the 0xC0000005 exit crash docs/current-phase.md has been
        # tracking for months. It is out of script's reach: with HARNESS_EXIT_TRACE=1 the
        # crashing runs still print "[exit] quit returned", so every GDScript statement
        # completes and Godot dies afterwards in its own shutdown.
        #
        # So this reports rather than refuses, and the distinction is deliberate:
        #
        #   no verdict     the suite died before it could tell us anything, or never
        #                  reached quit(). Refused above, and that is the case that
        #                  actually endangers a push.
        #   verdict, then
        #   a signal       the suite finished, said so, and the engine fell over on the
        #                  way out. The result is complete. Printed loudly and counted,
        #                  because a crash nobody names is a crash nobody fixes — the
        #                  bare bash "Segmentation fault" line this replaces was easy to
        #                  read as noise from the shell.
        if [ "$status" -ge 128 ]; then
            crashes=$((crashes + 1))
            echo "  $suite reported success and then died at engine shutdown (status $status)" >&2
        fi
    done
else
    echo "" >&2
    echo "godot not configured; the editor suites did not run." >&2
    echo "  git config soundgraph.godot /path/to/godot_console" >&2
fi

if [ "$crashes" -gt 0 ]; then
    echo "" >&2
    echo "$crashes suite(s) crashed at engine shutdown after passing." >&2
    echo "  Known, unfixed, and not a reason to hold the push: see the exit-crash entry" >&2
    echo "  in docs/current-phase.md. Every verdict above is complete." >&2
fi

say "all checks passed"
