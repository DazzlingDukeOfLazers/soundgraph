@echo off
rem Launches the SoundGraph editor in Godot, for looking at the real thing.
rem
rem The Godot binary comes from git config, the same place the pre-push gate reads
rem it from -- one setting, every tool:
rem
rem   git config soundgraph.godot "C:/path/to/Godot_console.exe"

setlocal
set "REPO=%~dp0.."

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

"%GODOT%" --path "%REPO%\editor-godot" %*
