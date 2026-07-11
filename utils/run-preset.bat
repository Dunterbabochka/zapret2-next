@echo off
setlocal EnableExtensions
set "ROOT=%~dp0.."
for %%I in ("%ROOT%") do set "ROOT=%%~fI"
set "PRESET=%~1"
if not defined PRESET (
  echo [ERROR] Preset name is required.
  exit /b 2
)

if not exist "%ROOT%\presets\%PRESET%.txt.in" (
  echo [ERROR] Preset not found: %PRESET%
  pause
  exit /b 3
)

fltmc >nul 2>&1
if errorlevel 1 (
  powershell -NoProfile -Command "Start-Process -FilePath 'cmd.exe' -ArgumentList '/c ""%~f0" "%PRESET%""' -Verb RunAs"
  exit /b
)

sc query winws2 2>nul | findstr /I "RUNNING START_PENDING" >nul
if not errorlevel 1 (
  echo [ERROR] The winws2 service is running. Remove or stop it in service.bat first.
  pause
  exit /b 4
)

call "%ROOT%\service.bat" check_updates soft >nul 2>&1
set "SAFE_PRESET=%PRESET: =_%"
set "CONFIG=%ROOT%\runtime\manual-%SAFE_PRESET%.txt"
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\utils\render-config.ps1" -Preset "%PRESET%" -Output "%CONFIG%"
if errorlevel 1 (
  echo [ERROR] Failed to render preset.
  pause
  exit /b 5
)

taskkill /F /IM winws2.exe >nul 2>&1
start "Zapret 2 NEXT: %PRESET%" /min "%ROOT%\bin\winws2.exe" @"%CONFIG%"
timeout /t 2 /nobreak >nul
tasklist /FI "IMAGENAME eq winws2.exe" 2>nul | findstr /I "winws2.exe" >nul
if errorlevel 1 (
  echo [ERROR] winws2 did not stay running. Validate the preset from service.bat.
  pause
  exit /b 6
)
echo [OK] Zapret 2 NEXT started with preset "%PRESET%".
exit /b 0
