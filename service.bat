@echo off
setlocal EnableExtensions EnableDelayedExpansion
set "SERVICE_NAME=winws2"
set "TELEGRAM_STATUS="
set "ROOT=%~dp0"
if /I "%~1"=="log_session" set "ZAPRET_LOG_SESSION=%~2"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"
set "VERSION=unknown"
if exist "%ROOT%\.service\version.txt" set /p VERSION=<"%ROOT%\.service\version.txt"
set "STATE_KEY=HKLM\System\CurrentControlSet\Services\%SERVICE_NAME%"
set "REPO_SLUG="
if exist "%ROOT%\.service\repository.txt" set /p REPO_SLUG=<"%ROOT%\.service\repository.txt"
set "RAW_BASE=https://raw.githubusercontent.com/%REPO_SLUG%/main"
set "RELEASE_URL=https://github.com/%REPO_SLUG%/releases"

if /I "%~1"=="check_updates" (
  if /I "%~2"=="soft" (
    if exist "%ROOT%\utils\check_updates.enabled" start "" /b powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\utils\update-release.ps1" -Action Check -Quiet >nul 2>&1
  ) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\utils\update-release.ps1" -Action Check -Force
  )
  exit /b
)

set "ZAPRET_LOG_ROOT=%ROOT%"
set "LOG_SESSION_RESULT=disabled"
for /f "delims=" %%L in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\utils\manage-logs.ps1" -Action Start -SessionId "%ZAPRET_LOG_SESSION%"') do set "LOG_SESSION_RESULT=%%L"
set "ZAPRET_LOG_SESSION=%LOG_SESSION_RESULT%"
if "%ZAPRET_LOG_SESSION%"=="disabled" set "ZAPRET_LOG_DISABLED=1"

fltmc >nul 2>&1
if errorlevel 1 (
  echo Requesting administrator rights...
  powershell -NoProfile -Command "Start-Process -FilePath 'cmd.exe' -ArgumentList '/c ""%~f0"" log_session %ZAPRET_LOG_SESSION%' -Verb RunAs"
  set "ELEVATION_EXIT=!errorlevel!"
  powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\utils\manage-logs.ps1" -Action Finish -Handoff -ExitCode !ELEVATION_EXIT!
  exit /b !ELEVATION_EXIT!
)

mode con: cols=110 lines=40 >nul 2>&1
if exist "%ROOT%\runtime\release-update\recovery-needed" (
  call :recover_update
  if errorlevel 1 exit /b 1
)
if exist "%ROOT%\runtime\release-update\cleanup-pending" (
  call :recover_update
  if errorlevel 1 exit /b 1
)
if exist "%ROOT%\.service\version.txt" set /p VERSION=<"%ROOT%\.service\version.txt"

if exist "%ROOT%\.service\repository.txt" set /p REPO_SLUG=<"%ROOT%\.service\repository.txt"
set "RAW_BASE=https://raw.githubusercontent.com/%REPO_SLUG%/main"
set "RELEASE_URL=https://github.com/%REPO_SLUG%/releases"

:menu
call :read_status
cls
echo.
echo   ZAPRET 2 NEXT SERVICE MANAGER v%VERSION%
echo   Strategy: !CURRENT_PRESET!   Game: !GAME_MODE!   IPSet: !IPSET_MODE!   Voice: !VOICE_MODE!
echo   UDP fakes: Discord=!DISCORD_FAKE!   Game=!GAME_FAKE!
echo   Service: !SERVICE_STATUS!
echo   Telegram: !TELEGRAM_STATUS!
echo   -----------------------------------------------
echo.
echo   :: SERVICE
echo       1. Install Service
echo       2. Remove Service
echo       3. Check Status
echo.
echo   :: SETTINGS
echo       4. Game Filter         [!GAME_MODE!]
echo       5. IPSet Filter        [!IPSET_MODE!]
echo       6. Auto-Update Check   [!UPDATE_MODE!]
echo       7. Discord Voice       [!VOICE_MODE!]
echo       8. UDP Fake Profiles   [D:!DISCORD_FAKE! / G:!GAME_FAKE!]
echo       9. Telegram            [!TELEGRAM_STATUS!]
echo.
echo   :: UPDATES
echo      10. Update IPSet List
echo      11. Update Hosts File
echo      12. Check for Updates
echo.
echo   :: TOOLS
echo      13. Run Diagnostics
echo      14. Run Tests
echo      15. Clear Discord Cache
echo.
echo   -----------------------------------------------
echo       0. Exit
echo.
set "choice="
if not defined UPDATE_CHECK_STARTED (
  set "UPDATE_CHECK_STARTED=1"
  if exist "%ROOT%\utils\check_updates.enabled" start "" /b powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\utils\update-release.ps1" -Action Check -Quiet >nul 2>&1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\utils\update-release.ps1" -Action ReadMenuChoice
set "choice=!errorlevel!"
if "!choice!"=="211" goto update_release
if !choice! LSS 100 (
  call :red "Could not read the menu selection."
  pause
  goto menu
)
if !choice! GTR 115 goto menu
set /a choice-=100
if "!choice!"=="1" goto install_service
if "!choice!"=="2" goto remove_service
if "!choice!"=="3" goto show_status
if "!choice!"=="4" goto game_filter
if "!choice!"=="5" goto ipset_filter
if "!choice!"=="6" goto update_toggle
if "!choice!"=="7" goto voice_filter
if "!choice!"=="8" goto fake_profiles
if "!choice!"=="9" goto telegram
if "!choice!"=="10" goto update_ipset
if "!choice!"=="11" goto update_hosts
if "!choice!"=="12" goto manual_update_check
if "!choice!"=="13" goto diagnostics
if "!choice!"=="14" goto tests
if "!choice!"=="15" goto clear_discord_cache
if "!choice!"=="0" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\utils\manage-logs.ps1" -Action Finish
  exit /b 0
)
goto menu

:read_status
call :get_service_status
set "CURRENT_PRESET=none"
for /f "tokens=2,*" %%A in ('reg query "%STATE_KEY%" /v Zapret2NextStrategy 2^>nul ^| findstr /I "Zapret2NextStrategy"') do set "CURRENT_PRESET=%%B"
if /I "!CURRENT_PRESET!"=="CUSTOM SAFE" set "CURRENT_PRESET=NEXT SAFE"
if /I "!CURRENT_PRESET!"=="CUSTOM BALANCED" set "CURRENT_PRESET=NEXT BALANCED"
call :read_settings
:: Keep the last Telegram result during navigation; explicit status/actions refresh it.
if not defined TELEGRAM_STATUS call :read_telegram_status
exit /b

:read_settings
set "GAME_MODE=off"
if exist "%ROOT%\utils\game_filter.mode" set /p GAME_MODE=<"%ROOT%\utils\game_filter.mode"
if exist "%ROOT%\utils\check_updates.enabled" (set "UPDATE_MODE=enabled") else (set "UPDATE_MODE=disabled")
call :read_ipset_mode
call :read_voice_mode
call :read_fake_modes
exit /b

:read_telegram_status
set "TELEGRAM_STATUS=unavailable"
if not exist "%ROOT%\utils\manage-telegram.ps1" exit /b
for /f "usebackq delims=" %%S in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\utils\manage-telegram.ps1" -Action Status -Compact 2^>nul`) do set "TELEGRAM_STATUS=%%S"
exit /b

:get_service_status
set "SERVICE_STATUS=not installed"
:: Use numeric states regardless of Windows language; skip exit-code fields like (0x1).
for /f "tokens=3,4" %%S in ('sc.exe query "%SERVICE_NAME%" 2^>nul') do (
  set "SERVICE_FIELD=%%T"
  if defined SERVICE_FIELD if not "!SERVICE_FIELD:~0,1!"=="(" (
    if "%%S"=="1" set "SERVICE_STATUS=Stopped"
    if "%%S"=="2" set "SERVICE_STATUS=StartPending"
    if "%%S"=="3" set "SERVICE_STATUS=StopPending"
    if "%%S"=="4" set "SERVICE_STATUS=Running"
    if "%%S"=="5" set "SERVICE_STATUS=ContinuePending"
    if "%%S"=="6" set "SERVICE_STATUS=PausePending"
    if "%%S"=="7" set "SERVICE_STATUS=Paused"
  )
)
exit /b

:read_ipset_mode
set "IPSET_MODE=loaded"
if exist "%ROOT%\utils\ipset_filter.mode" set /p IPSET_MODE=<"%ROOT%\utils\ipset_filter.mode"
if /I not "!IPSET_MODE!"=="loaded" if /I not "!IPSET_MODE!"=="none" if /I not "!IPSET_MODE!"=="any" set "IPSET_MODE=loaded"
exit /b

:read_voice_mode
set "VOICE_MODE=compatible"
if exist "%ROOT%\utils\voice_filter.mode" set /p VOICE_MODE=<"%ROOT%\utils\voice_filter.mode"
if /I not "!VOICE_MODE!"=="compatible" if /I not "!VOICE_MODE!"=="standard" if /I not "!VOICE_MODE!"=="off" set "VOICE_MODE=compatible"
exit /b

:read_fake_modes
set "DISCORD_FAKE=current"
if exist "%ROOT%\utils\discord_fake.mode" set /p DISCORD_FAKE=<"%ROOT%\utils\discord_fake.mode"
if /I not "!DISCORD_FAKE!"=="current" if /I not "!DISCORD_FAKE!"=="steam" if /I not "!DISCORD_FAKE!"=="google" set "DISCORD_FAKE=current"
set "GAME_FAKE=current"
if exist "%ROOT%\utils\game_fake.mode" set /p GAME_FAKE=<"%ROOT%\utils\game_fake.mode"
if /I not "!GAME_FAKE!"=="current" if /I not "!GAME_FAKE!"=="dbank-v2" if /I not "!GAME_FAKE!"=="steam" set "GAME_FAKE=current"
exit /b

:install_service
cls
call :read_settings
set /a count=0
for /L %%N in (1,1,32) do set "preset%%N="
for %%P in ("general" "ALT" "ALT3" "ALT5" "ALT11" "ALT12" "ALT13" "EXP" "FAKE TLS AUTO ALT2") do (
  if not exist "%ROOT%\presets\%%~P.txt.in" (
    call :red "Missing Classic preset: %%~P"
    pause
    goto menu
  )
  set /a count+=1
  set "preset!count!=%%~P"
)
set "classic_count=!count!"
set /a next_count=0
for %%P in ("NEXT SAFE" "NEXT BALANCED") do (
  if not exist "%ROOT%\presets\%%~P.txt.in" (
    call :red "Missing NEXT preset: %%~P"
    pause
    goto menu
  )
  set /a count+=1
  set /a next_count+=1
  set "preset!count!=%%~P"
  set "nextRow!next_count!=!count!. %%~P"
)
echo   Classic presets                             NEXT presets
echo   ----------------------------------------    ----------------------------
for /L %%N in (1,1,!classic_count!) do (
  set "PRESET_ROW=  %%N. !preset%%N!                                            "
  echo !PRESET_ROW:~0,46!!nextRow%%N!
)
echo.
set "pick="
set /p "pick=Select preset (1-!count!, 0=cancel): "
if "!pick!"=="0" goto menu
for /f "delims=0123456789" %%A in ("!pick!") do goto invalid_choice
if not defined preset!pick! goto invalid_choice
for %%P in (!pick!) do set "SELECTED=!preset%%P!"
echo.
echo Selected configuration:
echo   Strategy: !SELECTED!   Game: !GAME_MODE!   IPSet: !IPSET_MODE!   Voice: !VOICE_MODE!
echo   UDP fakes: Discord=!DISCORD_FAKE!   Game=!GAME_FAKE!
set "confirm="
set /p "confirm=Install this service configuration? [Y/n]: "
if /I "!confirm!"=="N" goto menu
set "RENDER_IPSET_MODE=!IPSET_MODE!"
if /I "!RENDER_IPSET_MODE!"=="any" (
  set "RENDER_IPSET_MODE=loaded"
  call :yellow "IPSet any is diagnostic-only; service installation will use loaded."
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\utils\manage-service.ps1" -Action Install -Preset "!SELECTED!" -IPSetMode "!RENDER_IPSET_MODE!"
if errorlevel 1 (
  call :red "Service configuration failed; see the error above."
)
pause
goto menu

:invalid_choice
call :red "Invalid preset selection."
pause
goto menu

:remove_service
cls
echo Stopping Zapret 2 NEXT...
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\utils\manage-service.ps1" -Action Remove
if errorlevel 1 call :red "Service removal failed; see the error above."
pause
goto menu

:show_status
cls
call :read_telegram_status
call :read_status
echo Service name:       %SERVICE_NAME%
echo Service state:      !SERVICE_STATUS!
echo Selected strategy:  !CURRENT_PRESET!
echo Game filter:        !GAME_MODE!
echo IPSet filter:       !IPSET_MODE!
echo Discord Voice:      !VOICE_MODE!
echo Discord UDP fake:   !DISCORD_FAKE!
echo Game UDP fake:      !GAME_FAKE!
echo Configuration:      !CURRENT_PRESET! + !GAME_MODE! + !IPSET_MODE! + !VOICE_MODE! + D:!DISCORD_FAKE! + G:!GAME_FAKE!
echo Auto update check:  !UPDATE_MODE!
echo Telegram:           !TELEGRAM_STATUS!
tasklist /FI "IMAGENAME eq winws2.exe" 2>nul | findstr /I "winws2.exe" >nul
if errorlevel 1 (echo winws2 process:     not running) else (echo winws2 process:     running)
sc query WinDivert 2>nul | findstr /I "RUNNING" >nul
if errorlevel 1 (echo WinDivert driver:   not running) else (echo WinDivert driver:   running)
echo.
pause
goto menu

:game_filter
cls
set "newmode="
echo Select game filter mode:
echo   0. Off
echo   1. TCP and UDP
echo   2. TCP only
echo   3. UDP only
set "mode="
set /p "mode=Selection (0-3): "
if "!mode!"=="0" set "newmode=off"
if "!mode!"=="1" set "newmode=all"
if "!mode!"=="2" set "newmode=tcp"
if "!mode!"=="3" set "newmode=udp"
if not defined newmode goto invalid_choice
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\utils\update-release.ps1" -Action SetSetting -Name game_filter.mode -Value "!newmode!"
if errorlevel 1 goto menu
call :refresh_service_config
pause
goto menu

:ipset_filter
cls
call :read_ipset_mode
if /I "!IPSET_MODE!"=="loaded" (
  set "newmode=none"
) else (
  set "newmode=loaded"
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\utils\update-release.ps1" -Action SetSetting -Name ipset_filter.mode -Value "!newmode!"
if errorlevel 1 goto menu
call :green "IPSet mode changed: !IPSET_MODE! -^> !newmode!"
call :yellow "IPSet any is diagnostic-only and is not available as a persistent service mode."
call :refresh_service_config
pause
goto menu

:voice_filter
cls
echo Select Discord Voice mode:
echo   0. Off        - protect Discord/STUN from the Game UDP fallback
echo   1. Standard   - official discovery fake profile
echo   2. Compatible - preserved confirmed voice sequence
set "mode="
set "newmode="
set /p "mode=Selection (0-2): "
if "!mode!"=="0" set "newmode=off"
if "!mode!"=="1" set "newmode=standard"
if "!mode!"=="2" set "newmode=compatible"
if not defined newmode goto invalid_choice
call :read_voice_mode
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\utils\update-release.ps1" -Action SetSetting -Name voice_filter.mode -Value "!newmode!"
if errorlevel 1 goto menu
call :green "Discord Voice mode changed: !VOICE_MODE! -^> !newmode!"
call :refresh_service_config
pause
goto menu

:fake_profiles
cls
call :read_fake_modes
echo Select an immutable UDP fake profile:
echo.
echo   Discord Voice (current: !DISCORD_FAKE!)
echo      1. current   - existing confirmed dBank payload
echo      2. steam     - new experimental Steam payload
echo      3. google    - bundled Google QUIC payload
echo.
echo   Game Filter UDP (current: !GAME_FAKE!)
echo      4. current   - existing confirmed dBank payload
echo      5. dbank-v2  - new experimental dBank payload
echo      6. steam     - new experimental Steam payload
echo.
echo      7. Reset both to current
echo      0. Cancel
set "fake_choice="
set "fake_kind="
set "fake_value="
set /p "fake_choice=Selection (0-7): "
if "!fake_choice!"=="0" goto menu
if "!fake_choice!"=="1" (
  set "fake_kind=discord"
  set "fake_value=current"
)
if "!fake_choice!"=="2" (
  set "fake_kind=discord"
  set "fake_value=steam"
)
if "!fake_choice!"=="3" (
  set "fake_kind=discord"
  set "fake_value=google"
)
if "!fake_choice!"=="4" (
  set "fake_kind=game"
  set "fake_value=current"
)
if "!fake_choice!"=="5" (
  set "fake_kind=game"
  set "fake_value=dbank-v2"
)
if "!fake_choice!"=="6" (
  set "fake_kind=game"
  set "fake_value=steam"
)
if "!fake_choice!"=="7" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\utils\update-release.ps1" -Action SetSetting -Name fake-defaults -Value current
  if errorlevel 1 goto menu
  set "fake_kind=both"
)
if not defined fake_kind goto invalid_choice
if /I "!fake_kind!"=="discord" powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\utils\update-release.ps1" -Action SetSetting -Name discord_fake.mode -Value "!fake_value!"
if errorlevel 1 goto menu
if /I "!fake_kind!"=="game" powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\utils\update-release.ps1" -Action SetSetting -Name game_fake.mode -Value "!fake_value!"
if errorlevel 1 goto menu
call :read_fake_modes
call :green "UDP fake profiles: Discord=!DISCORD_FAKE!, Game=!GAME_FAKE!"
call :yellow "Experimental fakes can help or break connectivity; verify Discord Voice and the affected game after switching."
call :refresh_service_config
pause
goto menu

:clear_discord_cache
cls
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\utils\clear-discord-cache.ps1"
if errorlevel 1 call :yellow "Discord cache cleanup was incomplete; see the messages above."
pause
goto menu
:telegram
cls
if not exist "%ROOT%\utils\manage-telegram.ps1" (
  call :read_telegram_status
  call :red "Telegram manager is missing. Download the complete release archive."
  pause
  goto menu
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\utils\manage-telegram.ps1" -Action Menu
if errorlevel 1 (
  call :yellow "Telegram manager failed; see the messages above."
  pause
)
call :read_telegram_status
goto menu

:update_toggle
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\utils\update-release.ps1" -Action ToggleCheck
set "UPDATE_CHECK_STARTED="
pause
goto menu

:update_ipset
cls
set "IPSET_URL="
call :repository_ready
if not errorlevel 1 set "IPSET_URL=%RAW_BASE%/.service/ipset-service.txt"
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\utils\update-ipset.ps1" -RemoteUrl "!IPSET_URL!" -Destination "%ROOT%\lists\ipset-all.txt"
if errorlevel 1 (
  call :red "IPSet update failed; see the error above."
) else (
  call :refresh_service_config
)
:menu_pause
pause
goto menu

:update_hosts
cls
set "HOSTS_TEMP=%TEMP%\zapret2-next-hosts.txt"
set "HOSTS_URL="
call :repository_ready
if not errorlevel 1 set "HOSTS_URL=%RAW_BASE%/.service/hosts"
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\utils\prepare-hosts.ps1" -Output "!HOSTS_TEMP!" -RemoteUrl "!HOSTS_URL!"
if errorlevel 1 (
  call :red "Could not prepare hosts suggestions."
  pause
  goto menu
)
echo The system hosts file is never modified automatically.
echo Review the generated DNS snapshot and copy only the entries you need.
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
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\utils\update-release.ps1" -Action Check -Force
exit /b

:update_release
cls
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\utils\update-release.ps1" -Action Prepare -Launch
if errorlevel 1 (
  pause
  goto menu
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\runtime\release-update\recovery\update-release.ps1" -Action ReleaseMenu -Root "%ROOT%"
exit /b

:recover_update
if not exist "%ROOT%\runtime\release-update\recovery\update-release.ps1" (
  echo [ERROR] Recovery worker is missing. Restore the original release before continuing.
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\runtime\release-update\recovery\update-release.ps1" -Action Recover -Root "%ROOT%"
exit /b %errorlevel%

:diagnostics
cls
echo Zapret 2 NEXT diagnostics
echo -----------------------------------------------
echo   1. Quick check
echo   2. Create support report (automatic)
echo   3. Compatibility Wizard (advanced)
echo   4. Discord Voice diagnostic (advanced)
echo   5. Create logs archive
echo   0. Back
set "diagnostic_choice="
set /p "diagnostic_choice=Select option (0-5): "
if "!diagnostic_choice!"=="0" goto menu
if "!diagnostic_choice!"=="1" goto quick_diagnostics
if "!diagnostic_choice!"=="2" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\utils\support-diagnostics.ps1"
  pause
  goto diagnostics
)
if "!diagnostic_choice!"=="3" (
  call "%ROOT%\utils\compatibility wizard.bat"
  goto diagnostics
)
if "!diagnostic_choice!"=="4" (
  call "%ROOT%\utils\diagnose discord voice.bat"
  goto diagnostics
)
if "!diagnostic_choice!"=="5" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\utils\manage-logs.ps1" -Action Export
  pause
  goto diagnostics
)
goto diagnostics

:quick_diagnostics
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
call :read_telegram_status
call :read_status
echo Service: !SERVICE_STATUS!, strategy: !CURRENT_PRESET!, game: !GAME_MODE!, ipset: !IPSET_MODE!, voice: !VOICE_MODE!
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\utils\manage-telegram.ps1" -Action Status
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\utils\validate.ps1" -Quick
echo.
pause
goto diagnostics

:tests
start "Zapret 2 NEXT tests" powershell -NoExit -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\utils\test-presets.ps1"
goto menu

:refresh_service_config
sc query "%SERVICE_NAME%" >nul 2>&1
if errorlevel 1 (
  tasklist /FI "IMAGENAME eq winws2.exe" 2>nul | findstr /I "winws2.exe" >nul
  if not errorlevel 1 call :yellow "A manual winws2 process is running. Stop it and rerun its strategies\general*.bat launcher to apply this change."
  exit /b 0
)
set "ACTIVE="
for /f "tokens=2,*" %%A in ('reg query "%STATE_KEY%" /v Zapret2NextStrategy 2^>nul ^| findstr /I "Zapret2NextStrategy"') do set "ACTIVE=%%B"
if not defined ACTIVE (
  call :yellow "Service exists but its strategy metadata is missing. Reinstall it."
  exit /b 1
)
call :read_ipset_mode
set "RENDER_IPSET_MODE=!IPSET_MODE!"
if /I "!RENDER_IPSET_MODE!"=="any" (
  set "RENDER_IPSET_MODE=loaded"
  call :yellow "IPSet any is diagnostic-only; service refresh will use loaded."
)
set "restart="
set /p "restart=Restart the service now? [Y/n]: "
set "RESTART_FLAG=-Restart"
if /I "!restart!"=="N" set "RESTART_FLAG="
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\utils\manage-service.ps1" -Action Refresh -Preset "!ACTIVE!" -IPSetMode "!RENDER_IPSET_MODE!" !RESTART_FLAG!
if errorlevel 1 exit /b 1
if /I "!restart!"=="N" (
  call :yellow "Validated configuration saved; it will apply on the next service start."
) else (
  call :green "Service restarted."
)
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
