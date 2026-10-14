@echo off
setlocal EnableExtensions DisableDelayedExpansion
if "%~1"=="" (
  echo [ERROR] Preset name is required.
  exit /b 2
)
if /I "%~2"=="log_session" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run-preset.ps1" -Preset "%~1" -SessionId "%~3"
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run-preset.ps1" -Preset "%~1"
)
exit /b %errorlevel%
