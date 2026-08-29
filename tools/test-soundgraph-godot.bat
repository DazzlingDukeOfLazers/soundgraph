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

rem Git Bash is guaranteed by the git call above -- but not on cmd PATH, which is
rem exactly where this bat gets run from. The first version did `where bash`, fell
rem back to launching stale with a warning, and the warning was read only after a
rem confused session: a fallback that quietly under-delivers is how the launcher
rem trap gets rebuilt one layer up. So bash is derived from git own install
rem (cmd\git.exe sits beside bin\bash.exe), and PATH is merely the second guess.
set "BASH="
for /f "usebackq delims=" %%G in (`where git 2^>nul`) do (
    if not defined BASH if exist "%%~dpG..\bin\bash.exe" set "BASH=%%~dpG..\bin\bash.exe"
)
if not defined BASH (
    where bash >nul 2>&1
    if not errorlevel 1 set "BASH=bash"
)
if not defined BASH (
    echo Git Bash not found, so the extensions cannot be rebuilt from here.
    echo Refusing to launch a possibly stale build -- run tools/rebuild-extensions.sh
    echo from Git Bash, or relaunch with --no-build to run the old binary on purpose.
    exit /b 1
)

"%BASH%" "%REPO%\tools\rebuild-extensions.sh" --desktop
if errorlevel 1 (
    echo.
    echo The extension build failed, so the editor was not launched -- running the
    echo old DLL would show code that no longer exists. Fix the build, or relaunch
    echo with --no-build to look at the previous binary on purpose.
    exit /b 1
)

:launch
"%GODOT%" --path "%REPO%\editor-godot" %ARGS%
