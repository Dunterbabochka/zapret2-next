@echo off
setlocal EnableExtensions EnableDelayedExpansion
set "VERSION=0.1.0"
set "SERVICE_NAME=winws2"
set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"
set "STATE_KEY=HKLM\System\CurrentControlSet\Services\%SERVICE_NAME%"
set "REPO_SLUG="
if exist "%ROOT%\.service\repository.txt" set /p REPO_SLUG=<"%ROOT%\.service\repository.txt"
set "RAW_BASE=https://raw.githubusercontent.com/%REPO_SLUG%/main"
set "RELEASE_URL=https://github.com/%REPO_SLUG%/releases"

if /I "%~1"=="check_updates" (
  call :check_updates %~2
  exit /b
)

fltmc >nul 2>&1
if errorlevel 1 (
  echo Requesting administrator rights...
  powershell -NoProfile -Command "Start-Process -FilePath 'cmd.exe' -ArgumentList '/c ""%~f0""' -Verb RunAs"
  exit /b
)

:menu
cls
call :read_status
echo.
echo   ZAPRET 2 NEXT SERVICE MANAGER v%VERSION%
echo   Strategy: !CURRENT_PRESET!   Service: !SERVICE_STATUS!
echo   -----------------------------------------------
echo.
echo   :: SERVICE
echo      1. Install Service
echo      2. Remove Services
echo      3. Check Status
echo.
echo   :: SETTINGS
echo      4. Game Filter         [!GAME_MODE!]
echo      5. IPSet Filter        [!IPSET_MODE!]
echo      6. Auto-Update Check   [!UPDATE_MODE!]
echo.
echo   :: UPDATES
echo      7. Update IPSet List
echo      8. Update Hosts File
echo      9. Check for Updates
echo.
echo   :: TOOLS
echo     10. Run Diagnostics
echo     11. Run Tests
echo.
echo   -----------------------------------------------
echo      0. Exit
echo.
set "choice="
set /p "choice=   Select option (0-11): "
if "%choice%"=="1" goto install_service
if "%choice%"=="2" goto remove_service
if "%choice%"=="3" goto show_status
if "%choice%"=="4" goto game_filter
if "%choice%"=="5" goto ipset_filter
if "%choice%"=="6" goto update_toggle
if "%choice%"=="7" goto update_ipset
if "%choice%"=="8" goto update_hosts
if "%choice%"=="9" goto manual_update_check
if "%choice%"=="10" goto diagnostics
if "%choice%"=="11" goto tests
if "%choice%"=="0" exit /b 0
goto menu

:read_status
set "SERVICE_STATUS=not installed"
for /f "tokens=3" %%S in ('sc query "%SERVICE_NAME%" 2^>nul ^| findstr /I "STATE"') do set "SERVICE_STATUS=%%S"
set "CURRENT_PRESET=none"
for /f "tokens=2,*" %%A in ('reg query "%STATE_KEY%" /v Zapret2NextStrategy 2^>nul ^| findstr /I "Zapret2NextStrategy"') do set "CURRENT_PRESET=%%B"
set "GAME_MODE=off"
if exist "%ROOT%\utils\game_filter.mode" set /p GAME_MODE=<"%ROOT%\utils\game_filter.mode"
if exist "%ROOT%\utils\check_updates.enabled" (set "UPDATE_MODE=enabled") else (set "UPDATE_MODE=disabled")
call :read_ipset_mode
exit /b

:read_ipset_mode
set "IPSET_FILE=%ROOT%\lists\ipset-all.txt"
set "IPSET_MODE=loaded"
for %%F in ("!IPSET_FILE!") do if %%~zF==0 set "IPSET_MODE=any"
findstr /X /C:"203.0.113.113/32" "!IPSET_FILE!" >nul 2>&1
if not errorlevel 1 set "IPSET_MODE=none"
exit /b

:install_service
cls
echo Available presets:
set /a count=0
for %%F in ("%ROOT%\presets\*.txt.in") do (
  set "name=%%~nF"
  set "name=!name:.txt=!"
  if not "!name:~0,1!"=="_" (
    set /a count+=1
    set "preset!count!=!name!"
    echo   !count!. !name!
  )
)
echo.
set "pick="
set /p "pick=Select preset (1-!count!, 0=cancel): "
if "%pick%"=="0" goto menu
for /f "delims=0123456789" %%A in ("%pick%") do goto invalid_choice
if not defined preset%pick% goto invalid_choice
set "SELECTED=!preset%pick%!"
set "SERVICE_CONFIG=%ROOT%\runtime\service.txt"
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\utils\render-config.ps1" -Preset "!SELECTED!" -Output "!SERVICE_CONFIG!"
if errorlevel 1 (
  call :red "Failed to render service config."
  pause
  goto menu
)
sc stop "%SERVICE_NAME%" >nul 2>&1
timeout /t 1 /nobreak >nul
sc delete "%SERVICE_NAME%" >nul 2>&1
timeout /t 1 /nobreak >nul
set "IMAGE_PATH=\"%ROOT%\bin\winws2.exe\" @\"!SERVICE_CONFIG!\""
sc create "%SERVICE_NAME%" binPath= "!IMAGE_PATH!" DisplayName= "Zapret 2 NEXT" start= auto
if errorlevel 1 (
  call :red "Failed to create the winws2 service."
  pause
  goto menu
)
sc description "%SERVICE_NAME%" "Zapret 2 NEXT DPI bypass service powered by Zapret 2"
reg add "%STATE_KEY%" /v Zapret2NextStrategy /t REG_SZ /d "!SELECTED!" /f >nul
sc start "%SERVICE_NAME%"
if errorlevel 1 call :yellow "Service was installed but did not start. Run Diagnostics."
pause
goto menu

:invalid_choice
call :red "Invalid preset selection."
pause
goto menu

:remove_service
cls
echo Stopping Zapret 2 NEXT...
sc stop "%SERVICE_NAME%" >nul 2>&1
taskkill /F /IM winws2.exe >nul 2>&1
timeout /t 1 /nobreak >nul
sc delete "%SERVICE_NAME%" >nul 2>&1
for %%S in (WinDivert WinDivert14) do (
  sc stop "%%S" >nul 2>&1
  sc delete "%%S" >nul 2>&1
)
del /q "%ROOT%\runtime\service.txt" >nul 2>&1
call :green "Service and WinDivert registrations removed."
pause
goto menu

:show_status
cls
call :read_status
echo Service name:       %SERVICE_NAME%
echo Service state:      !SERVICE_STATUS!
echo Selected strategy:  !CURRENT_PRESET!
echo Game filter:        !GAME_MODE!
echo IPSet filter:       !IPSET_MODE!
echo Auto update check:  !UPDATE_MODE!
tasklist /FI "IMAGENAME eq winws2.exe" 2>nul | findstr /I "winws2.exe" >nul
if errorlevel 1 (echo winws2 process:     not running) else (echo winws2 process:     running)
sc query WinDivert 2>nul | findstr /I "RUNNING" >nul
if errorlevel 1 (echo WinDivert driver:   not running) else (echo WinDivert driver:   running)
echo.
pause
goto menu

:game_filter
cls
echo Select game filter mode:
echo   0. Off
echo   1. TCP and UDP
echo   2. TCP only
echo   3. UDP only
set "mode="
set /p "mode=Selection (0-3): "
if "%mode%"=="0" set "newmode=off"
if "%mode%"=="1" set "newmode=all"
if "%mode%"=="2" set "newmode=tcp"
if "%mode%"=="3" set "newmode=udp"
if not defined newmode goto invalid_choice
>"%ROOT%\utils\game_filter.mode" echo !newmode!
call :refresh_service_config
pause
goto menu

:ipset_filter
cls
call :read_ipset_mode
set "IPSET_FILE=%ROOT%\lists\ipset-all.txt"
set "IPSET_BACKUP=%ROOT%\lists\ipset-all.txt.backup"
if "!IPSET_MODE!"=="loaded" (
  copy /y "!IPSET_FILE!" "!IPSET_BACKUP!" >nul
  >"!IPSET_FILE!" echo 203.0.113.113/32
  call :green "IPSet mode changed: loaded -^> none"
) else if "!IPSET_MODE!"=="none" (
  type nul >"!IPSET_FILE!"
  call :green "IPSet mode changed: none -^> any"
) else (
  if not exist "!IPSET_BACKUP!" (
    call :red "No IPSet backup found. Use Update IPSet List first."
    pause
    goto menu
  )
  copy /y "!IPSET_BACKUP!" "!IPSET_FILE!" >nul
  call :green "IPSet mode changed: any -^> loaded"
)
call :refresh_service_config
pause
goto menu

:update_toggle
if exist "%ROOT%\utils\check_updates.enabled" (
  del /q "%ROOT%\utils\check_updates.enabled"
  call :yellow "Automatic update checks disabled."
) else (
  >"%ROOT%\utils\check_updates.enabled" echo enabled
  call :green "Automatic update checks enabled."
)
pause
goto menu

:update_ipset
cls
call :require_repository
if errorlevel 1 goto menu_pause
set "IPSET_URL=%RAW_BASE%/.service/ipset-service.txt"
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Stop'; $dst='%ROOT%\lists\ipset-all.txt'; $tmp=$dst+'.download'; $bak=$dst+'.backup';" ^
  "Invoke-WebRequest -UseBasicParsing -TimeoutSec 20 -Uri '%IPSET_URL%' -OutFile $tmp;" ^
  "$valid=Get-Content $tmp ^| Where-Object { $_ -and $_ -notmatch '^\s*#' };" ^
  "if($valid.Count -lt 10 -or ($valid ^| Where-Object { $_ -notmatch '^\s*([0-9a-fA-F:.]+)(/\d+)?\s*$' })){throw 'Downloaded IPSet has an invalid format'};" ^
  "if(Test-Path $dst){Copy-Item $dst $bak -Force}; Move-Item $tmp $dst -Force"
if errorlevel 1 (call :red "IPSet update failed; current list was preserved.") else (call :green "IPSet updated atomically.")
:menu_pause
pause
goto menu

:update_hosts
cls
set "HOSTS_TEMP=%TEMP%\zapret2-next-hosts.txt"
set "HOSTS_SOURCE=%ROOT%\.service\hosts"
call :repository_ready
if not errorlevel 1 (
  powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 15 -Uri '%RAW_BASE%/.service/hosts' -OutFile '%HOSTS_TEMP%' } catch { exit 1 }"
)
if not exist "!HOSTS_TEMP!" copy /y "!HOSTS_SOURCE!" "!HOSTS_TEMP!" >nul
if not exist "!HOSTS_TEMP!" (
  call :red "No hosts suggestion file is available."
  pause
  goto menu
)
echo The system hosts file is never modified automatically.
echo Review the suggestions and copy only the entries you need.
start "" notepad "!HOSTS_TEMP!"
explorer /select,"%SystemRoot%\System32\drivers\etc\hosts"
pause
goto menu

:manual_update_check
cls
call :check_updates
pause
goto menu

:check_updates
if /I "%~1"=="soft" if not exist "%ROOT%\utils\check_updates.enabled" exit /b 0
call :require_repository
if errorlevel 1 exit /b 1
set "REMOTE_VERSION="
for /f "usebackq delims=" %%V in (`curl.exe -fsSL --connect-timeout 4 --max-time 8 "%RAW_BASE%/.service/version.txt" 2^>nul`) do set "REMOTE_VERSION=%%V"
if not defined REMOTE_VERSION (
  if /I not "%~1"=="soft" call :yellow "Could not check for updates."
  exit /b 1
)
if /I "!REMOTE_VERSION!"=="%VERSION%" (
  if /I not "%~1"=="soft" call :green "You are using the latest version (%VERSION%)."
) else (
  call :yellow "A new version is available: !REMOTE_VERSION! (installed: %VERSION%)"
  echo Releases: %RELEASE_URL%
)
exit /b 0

:diagnostics
cls
echo Zapret 2 NEXT diagnostics
echo -----------------------------------------------
fltmc >nul 2>&1 && (call :green "Administrator rights: OK") || call :red "Administrator rights: missing"
for %%F in ("%ROOT%\bin\winws2.exe" "%ROOT%\bin\cygwin1.dll" "%ROOT%\bin\WinDivert.dll" "%ROOT%\bin\WinDivert64.sys" "%ROOT%\lua\zapret-lib.lua" "%ROOT%\lua\zapret-antidpi.lua") do (
  if exist %%F (echo [OK] %%~nxF) else call :red "Missing %%~nxF"
)
sc query BFE 2>nul | findstr /I "RUNNING" >nul && (call :green "Base Filtering Engine: running") || call :red "Base Filtering Engine: not running"
netsh interface tcp show global | findstr /I "timestamps enabled" >nul && (call :green "TCP timestamps: enabled") || call :yellow "TCP timestamps: not reported as enabled"
for /f "tokens=3" %%P in ('reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyEnable 2^>nul ^| findstr /I "ProxyEnable"') do if not "%%P"=="0x0" call :yellow "System proxy is enabled"
for %%S in (KillerNetworkService SmartByteNetworkService TracSrvWrapper) do sc query "%%S" >nul 2>&1 && call :yellow "Potential conflicting service: %%S"
call :read_status
echo Service: !SERVICE_STATUS!, preset: !CURRENT_PRESET!, game: !GAME_MODE!, ipset: !IPSET_MODE!
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\utils\validate.ps1" -Quick
echo.
pause
goto menu

:tests
start "Zapret 2 NEXT tests" powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\utils\test-presets.ps1"
goto menu

:refresh_service_config
sc query "%SERVICE_NAME%" >nul 2>&1
if errorlevel 1 exit /b 0
set "ACTIVE="
for /f "tokens=2,*" %%A in ('reg query "%STATE_KEY%" /v Zapret2NextStrategy 2^>nul ^| findstr /I "Zapret2NextStrategy"') do set "ACTIVE=%%B"
if not defined ACTIVE (
  call :yellow "Service exists but its strategy metadata is missing. Reinstall it."
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\utils\render-config.ps1" -Preset "!ACTIVE!" -Output "%ROOT%\runtime\service.txt"
if errorlevel 1 (
  call :red "Failed to regenerate service config."
  exit /b 1
)
set "restart="
set /p "restart=Restart the service now? [Y/n]: "
if /I "!restart!"=="N" exit /b 0
sc stop "%SERVICE_NAME%" >nul 2>&1
timeout /t 1 /nobreak >nul
sc start "%SERVICE_NAME%" >nul
if errorlevel 1 (call :red "Service restart failed.") else call :green "Service restarted."
exit /b

:repository_ready
if not defined REPO_SLUG exit /b 1
echo %REPO_SLUG% | findstr /I /C:"OWNER/" >nul && exit /b 1
exit /b 0

:require_repository
call :repository_ready
if errorlevel 1 (
  call :yellow "Repository is not configured yet. Set .service\repository.txt to owner/zapret2-next."
  exit /b 1
)
exit /b 0

:green
powershell -NoProfile -Command "Write-Host '%~1' -ForegroundColor Green"
exit /b
:yellow
powershell -NoProfile -Command "Write-Host '%~1' -ForegroundColor Yellow"
exit /b
:red
powershell -NoProfile -Command "Write-Host '%~1' -ForegroundColor Red"
exit /b
