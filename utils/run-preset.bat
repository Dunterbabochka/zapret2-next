@echo off
setlocal EnableExtensions
set "ROOT=%~dp0.."
for %%I in ("%ROOT%") do set "ROOT=%%~fI"
set "PRESET=%~1"
if /I "%~2"=="log_session" set "ZAPRET_LOG_SESSION=%~3"
set "ZAPRET_LOG_ROOT=%ROOT%"
set "LOG_SESSION_RESULT=disabled"
for /f "delims=" %%L in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\utils\manage-logs.ps1" -Action Start -SessionId "%ZAPRET_LOG_SESSION%"') do set "LOG_SESSION_RESULT=%%L"
set "ZAPRET_LOG_SESSION=%LOG_SESSION_RESULT%"
if "%ZAPRET_LOG_SESSION%"=="disabled" set "ZAPRET_LOG_DISABLED=1"
if not defined PRESET (
  echo [ERROR] Preset name is required.
  powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\utils\manage-logs.ps1" -Action Finish -ExitCode 2
  exit /b 2
)

if not exist "%ROOT%\presets\%PRESET%.txt.in" (
  echo [ERROR] Preset not found: %PRESET%
  pause
  powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\utils\manage-logs.ps1" -Action Finish -ExitCode 3
  exit /b 3
)

fltmc >nul 2>&1
if errorlevel 1 (
  powershell -NoProfile -Command "Start-Process -FilePath 'cmd.exe' -ArgumentList '/c ""%~f0" "%PRESET%" log_session %ZAPRET_LOG_SESSION%"' -Verb RunAs"
  if errorlevel 1 (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\utils\manage-logs.ps1" -Action Finish -Handoff -ExitCode 1
    exit /b 1
  )
  powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\utils\manage-logs.ps1" -Action Finish -Handoff
  exit /b 0
)

sc query winws2 2>nul | findstr /I "RUNNING START_PENDING" >nul
if not errorlevel 1 (
  echo [ERROR] The winws2 service is running. Remove or stop it in service.bat first.
  pause
  powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\utils\manage-logs.ps1" -Action Finish -ExitCode 4
  exit /b 4
)

tasklist /FI "IMAGENAME eq winws.exe" 2>nul | findstr /I "winws.exe" >nul
if not errorlevel 1 (
  echo [ERROR] Legacy winws.exe is running and may conflict with WinDivert.
  echo Stop the old Zapret bundle before starting Zapret 2 NEXT.
  pause
  powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\utils\manage-logs.ps1" -Action Finish -ExitCode 4
  exit /b 4
)
sc query zapret 2>nul | findstr /I "RUNNING START_PENDING" >nul
if not errorlevel 1 (
  echo [ERROR] A legacy Zapret service is running and may conflict with WinDivert.
  echo Stop or remove that service before starting Zapret 2 NEXT.
  pause
  powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\utils\manage-logs.ps1" -Action Finish -ExitCode 4
  exit /b 4
)

call "%ROOT%\service.bat" check_updates soft >nul 2>&1
set "SAFE_PRESET=%PRESET: =_%"
set "CONFIG=%ROOT%\runtime\manual-%SAFE_PRESET%.txt"
set "DRY_CONFIG=%ROOT%\runtime\validate-%SAFE_PRESET%.txt"
set "LOG_PREFIX=%ROOT%\runtime\manual-%SAFE_PRESET%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\utils\render-config.ps1" -Preset "%PRESET%" -Output "%CONFIG%"
if errorlevel 1 (
  echo [ERROR] Failed to render preset.
  pause
  powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\utils\manage-logs.ps1" -Action Finish -ExitCode 5
  exit /b 5
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\utils\render-config.ps1" -Preset "%PRESET%" -Output "%DRY_CONFIG%" -DryRun >nul
if errorlevel 1 (
  echo [ERROR] Failed to render validation config.
  pause
  powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\utils\manage-logs.ps1" -Action Finish -ExitCode 5
  exit /b 5
)

echo Validating "%PRESET%"...
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\utils\invoke-winws.ps1" -Config "%DRY_CONFIG%" -LogPrefix "%LOG_PREFIX%-validate" -Validate
if errorlevel 1 (
  echo [ERROR] Preset validation failed. The engine output is shown above.
  pause
  powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\utils\manage-logs.ps1" -Action Finish -ExitCode 6
  exit /b 6
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\utils\invoke-winws.ps1" -Config "%CONFIG%" -LogPrefix "%LOG_PREFIX%" -ReplaceExisting
if errorlevel 1 (
  echo [ERROR] winws2 failed to start. The engine output and log paths are shown above.
  pause
  powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\utils\manage-logs.ps1" -Action Finish -ExitCode 7
  exit /b 7
)
echo [OK] Zapret 2 NEXT started with preset "%PRESET%".
echo The winws2 process will keep running after this window closes.
timeout /t 4 /nobreak >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\utils\manage-logs.ps1" -Action Finish -ExitCode 0
exit /b 0
