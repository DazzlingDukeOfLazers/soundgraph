@echo off
rem Builds the extensions, then launches the SoundGraph editor in Godot.
rem
rem It used to only launch, which was a trap wearing a convenience's name: GDScript
rem changes always show up because Godot loads scripts fresh, so the tool felt like it
rem worked -- while anything C++ (dsp-core, patch-io, the runtime) kept running whatever
rem DLL was last copied into editor-godot/bin. A registry change would build green,
rem test green, and not exist in the app on screen. The rebuild is under four seconds
rem when nothing changed, which is cheaper than one minute of wondering why a change
rem is not there.
rem
rem   --no-build   skip the rebuild (quick relaunches when you know nothing C++ moved)
rem
rem The Godot binary comes from git config, the same place the pre-push gate reads
rem it from -- one setting, every tool:
rem
rem   git config soundgraph.godot "C:/path/to/Godot_console.exe"

setlocal enabledelayedexpansion
set "REPO=%~dp0.."

set "ARGS="
set "SKIP_BUILD="
:parse
if "%~1"=="" goto resolved
if /I "%~1"=="--no-build" (
    set "SKIP_BUILD=1"
) else (
    set ARGS=!ARGS! "%~1"
)
shift
goto parse
:resolved

for /f "usebackq delims=" %%G in (`git -C "%REPO%" config --get soundgraph.godot`) do set "GODOT=%%G"

if "%GODOT%"=="" (
    echo soundgraph.godot is not configured. Set it with:
    echo   git config soundgraph.godot "C:/path/to/Godot_console.exe"
    exit /b 1
)

if not exist "%GODOT%" (
    echo Configured Godot binary not found: %GODOT%
    exit /b 1
)

if defined SKIP_BUILD goto launch

rem Git Bash is guaranteed by the git call above; rebuild-extensions.sh handles the
rem two-build stale-extension trap and the DLL-held-open dance in one place, so this
rem does not grow a second copy of that knowledge.
where bash >nul 2>&1
if errorlevel 1 (
    echo bash not found; launching without a rebuild. C++ changes since the last
    echo rebuild are NOT in this run -- tools/rebuild-extensions.sh is the fix.
    goto launch
)

bash "%REPO%\tools\rebuild-extensions.sh"
if errorlevel 1 (
    echo.
    echo The extension build failed, so the editor was not launched -- running the
    echo old DLL would show code that no longer exists. Fix the build, or relaunch
    echo with --no-build to look at the previous binary on purpose.
    exit /b 1
)

:launch
"%GODOT%" --path "%REPO%\editor-godot" %ARGS%
