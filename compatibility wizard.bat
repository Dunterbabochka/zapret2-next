@echo off
setlocal EnableExtensions

fltmc >nul 2>&1
if errorlevel 1 (
  echo Requesting administrator rights for Compatibility Wizard...
  powershell -NoProfile -Command "Start-Process -FilePath 'cmd.exe' -ArgumentList '/c ""%~f0""' -Verb RunAs -Wait -ErrorAction Stop"
  if errorlevel 1 (
    echo [ERROR] Could not open the elevated Compatibility Wizard window.
    pause
    exit /b 1
  )
  exit /b 0
)

title Zapret 2 NEXT - Compatibility Wizard
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0utils\compatibility-wizard.ps1"
set "RESULT=%ERRORLEVEL%"
echo.
if not "%RESULT%"=="0" (
  echo Compatibility Wizard finished with exit code %RESULT%.
)
pause
exit /b %RESULT%
