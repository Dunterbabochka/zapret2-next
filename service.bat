@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "ROOT=%~dp0"
if /I "%~1"=="check_updates" goto check_updates
echo Starting Zapret 2 NEXT...
if /I "%~1"=="log_session" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%utils\menu.ps1" -SessionId "%~2"
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%utils\menu.ps1"
)
exit /b %errorlevel%
:check_updates
if /I "%~2"=="soft" (
  if exist "%ROOT%utils\check_updates.enabled" start "" /b powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%utils\update-release.ps1" -Action Check -Quiet >nul 2>&1
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%utils\update-release.ps1" -Action Check -Force
)
exit /b %errorlevel%
