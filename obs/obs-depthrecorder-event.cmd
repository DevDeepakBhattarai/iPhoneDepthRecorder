@echo off
setlocal EnableExtensions
set "SCRIPT_DIR=%~dp0"
if not defined DEPTHRECORDER_PROJECT (
  for %%I in ("%SCRIPT_DIR%..") do set "DEPTHRECORDER_PROJECT=%%~fI"
)
set "PY=%DEPTHRECORDER_PROJECT%\.venv\Scripts\python.exe"
if not exist "%PY%" set "PY=%LOCALAPPDATA%\pymobiledevice3-pure\venv\Scripts\python.exe"
if not exist "%PY%" set "PY=python"
set "HELPER=%DEPTHRECORDER_PROJECT%\tools\obs_phone_event.py"
if not defined DEPTHRECORDER_DATA_ROOT set "DEPTHRECORDER_DATA_ROOT=%USERPROFILE%\Videos\DepthRecorder"
set "LOGDIR=%DEPTHRECORDER_DATA_ROOT%\obs-sync"
if not exist "%LOGDIR%" mkdir "%LOGDIR%"
set "RENDER="
if "%~4"=="1" set "RENDER=--auto-render"
"%PY%" "%HELPER%" "%~1" --obs-monotonic-ns "%~2" --obs-path "%~3" %RENDER% >> "%LOGDIR%\events.log" 2>&1
endlocal
