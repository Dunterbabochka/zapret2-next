@echo off
setlocal
cd /d "%~dp0"
if not exist "compatibility wizard.bat" (
  echo Beta archive is incomplete. Re-extract the original archive.
  pause
  exit /b 1
)
call "compatibility wizard.bat"
endlocal
