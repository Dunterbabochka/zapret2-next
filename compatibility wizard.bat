@echo off
setlocal EnableExtensions

fltmc >nul 2>&1
if errorlevel 1 (
  powershell -NoProfile -Command "Start-Process -FilePath 'cmd.exe' -ArgumentList '/c ""%~f0""' -Verb RunAs"
  exit /b
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
