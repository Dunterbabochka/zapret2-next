@echo off
setlocal
cd /d "%~dp0zapret2-next"
if not exist "compatibility wizard.bat" (
  echo Beta kit is incomplete. Re-extract the original archive.
  pause
  exit /b 1
)
call "compatibility wizard.bat"
endlocal
