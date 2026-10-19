[CmdletBinding()]
param([string]$SessionId='', [switch]$LibraryOnly)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$startupTimer=[Diagnostics.Stopwatch]::StartNew()
. (Join-Path $PSScriptRoot 'session-log.ps1')
. (Join-Path $PSScriptRoot 'preset-catalog.ps1')
. (Join-Path $PSScriptRoot 'menu-input.ps1')
. (Join-Path $PSScriptRoot 'menu-settings.ps1')
. (Join-Path $PSScriptRoot 'service-control.ps1')
. (Join-Path $PSScriptRoot 'telegram-control.ps1')

function Test-ZapretMenuAdministrator {
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    try { return ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
    finally { $identity.Dispose() }
}
function Clear-ZapretMenu {
    if (-not [Console]::IsOutputRedirected) { try { [Console]::Clear() } catch {} }
}
function Read-ZapretMenuLine([string]$Prompt) {
    [Console]::Write($Prompt)
    $answer=[Console]::ReadLine()
    if ($null -eq $answer) { return '0' }
    return $answer
}
function Wait-ZapretMenu {
    [Console]::WriteLine('Press any key to continue . . .')
    if ([Console]::IsInputRedirected) { $null=[Console]::ReadLine() }
    else { $null=[Console]::ReadKey($true) }
}
function Get-ZapretMenuService {
    $service=Get-Service -Name winws2 -ErrorAction Ignore
    $preset='none'
    $state='not installed'
    if ($service) {
        $key=$null
        try {
            $state=[string]$service.Status
            $key=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Services\winws2')
            if ($key) { $value=$key.GetValue('Zapret2NextStrategy'); if ($value) { $preset=[string]$value } }
        } catch { Write-ZapretLogException $_ -Warning }
        finally { if ($key) { $key.Dispose() }; $service.Dispose() }
    }
    if ($preset -match '^CUSTOM (SAFE|BALANCED)$') { $preset='NEXT '+$matches[1] }
    [pscustomobject]@{State=$state;Preset=$preset}
}
function Get-ZapretMenuTelegram {
    try { Get-ZapretTelegramStatus $root -Compact -Fast }
    catch { Write-ZapretLogException $_ -Warning; 'ERROR' }
}
function Get-ZapretMenuModes {
    $defaults=@{Game='off';IPSet='loaded';Voice='compatible';DiscordFake='current';GameFake='current'}
    $names=@{Game='game_filter.mode';IPSet='ipset_filter.mode';Voice='voice_filter.mode';DiscordFake='discord_fake.mode';GameFake='game_fake.mode'}
    $allowed=@{Game=@('off','tcp','udp','all');IPSet=@('loaded','none','any');Voice=@('compatible','standard','off');DiscordFake=@('current','steam','google');GameFake=@('current','dbank-v2','steam')}
    foreach ($name in @($defaults.Keys)) {
        $path=Join-Path $root ('utils\'+$names[$name])
        if ([IO.File]::Exists($path)) {
            $reader=$null
            try {
                $reader=[IO.StreamReader]::new($path,[Text.Encoding]::Default,$true)
                $value=$reader.ReadLine()
                if ($value -in $allowed[$name] -or ($name -in @('DiscordFake','GameFake') -and (Test-ZapretFakeSelection $value $(if ($name -eq 'DiscordFake') {'Discord'} else {'Game'})))) { $defaults[$name]=$value }
            } catch { Write-ZapretLogException $_ -Warning }
            finally { if ($reader) { $reader.Dispose() } }
        }
    }
    $defaults.GameTcpPorts=try { Get-ZapretGamePorts $root tcp } catch { 'invalid - set TCP ports' }
    $defaults.GameUdpPorts=try { Get-ZapretGamePorts $root udp } catch { 'invalid - set UDP ports' }
    $defaults.DiscordFakeLabel=Get-ZapretFakeLabel $defaults.DiscordFake
    $defaults.GameFakeLabel=Get-ZapretFakeLabel $defaults.GameFake
    $defaults.Update=if ([IO.File]::Exists((Join-Path $root 'utils\check_updates.enabled'))) {'enabled'} else {'disabled'}
    $defaults
}
function Invoke-ZapretMenuOperation([string]$Component,[string]$Action,[scriptblock]$Body) {
    Invoke-ZapretLoggedOperation -Root $root -Component $Component -Action $Action -Body $Body
}
function Invoke-ZapretMenuChild([string]$File,[object[]]$Arguments=@()) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot $File) @Arguments
    if ($LASTEXITCODE -ne 0) { throw "The operation failed (exit $LASTEXITCODE). See the messages above." }
}
function Start-ZapretMenuCheck {
    if ($script:updateCheckStarted -or -not [IO.File]::Exists((Join-Path $root 'utils\check_updates.enabled'))) { return }
    $script:updateCheckStarted=$true
    # Called after the input prompt is ready, never on the input thread's network path.
    $arguments='-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $PSScriptRoot 'update-release.ps1')+'" -Action Check -Quiet'
    try {
        if ($script:checkProcess) { $script:checkProcess.Dispose(); $script:checkProcess=$null }
        $script:checkProcess=Start-Process powershell.exe -ArgumentList $arguments -WindowStyle Hidden -PassThru
    }
    catch { Write-ZapretLogException $_ -Warning }
}
function Show-ZapretMenu([object]$Service,[hashtable]$Modes,[string]$Telegram) {
    Clear-ZapretMenu
    $version=try { Get-ReleaseVersion $root } catch {'unknown'}
    Write-Host "`n  ZAPRET 2 NEXT SERVICE MANAGER v$version"
    Write-Host "  Strategy: $($Service.Preset)   Game: $($Modes.Game)   IPSet: $($Modes.IPSet)   Voice: $($Modes.Voice)"
    Write-Host "  UDP fakes: Discord=$($Modes.DiscordFakeLabel)   Game=$($Modes.GameFakeLabel)"
    Write-Host "  Service: $($Service.State)"
    Write-Host "  Telegram: $Telegram"
    Write-Host '  -----------------------------------------------'
    Write-Host "`n  :: SERVICE`n      1. Install Service`n      2. Remove Service`n      3. Check Status"
    Write-Host "`n  :: SETTINGS"
    Write-Host "      4. Game Filter         [$($Modes.Game)]"
    Write-Host "      5. IPSet Filter        [$($Modes.IPSet)]"
    Write-Host "      6. Auto-Update Check   [$($Modes.Update)]"
    Write-Host "      7. Discord Voice       [$($Modes.Voice)]"
    Write-Host "      8. UDP Fake Profiles   [D:$($Modes.DiscordFakeLabel) / G:$($Modes.GameFakeLabel)]"
    Write-Host "      9. Telegram            [$Telegram]"
    Write-Host "`n  :: UPDATES`n     10. Update IPSet List`n     11. Update Hosts File`n     12. Check for Updates"
    Write-Host "`n  :: TOOLS`n     13. Run Diagnostics`n     14. Run Tests`n     15. Clear Discord Cache"
    Write-Host "`n  -----------------------------------------------`n      0. Exit`n"
}
function Update-ZapretMenuService {
    $service=Get-ZapretMenuService
    if ($service.State -eq 'not installed') {
        if (Test-ZapretMenuEngineProcess) { Write-Host 'A manual winws2 process is running. Stop it and rerun its strategies launcher to apply this change.' -ForegroundColor Yellow }
        return
    }
    if ($service.Preset -eq 'none') { throw 'Service exists but its strategy metadata is missing. Reinstall it.' }
    $modes=Get-ZapretMenuModes
    $ipset=if ($modes.IPSet -eq 'any') {'loaded'} else {$modes.IPSet}
    $restart=(Read-ZapretMenuLine 'Restart the service now? [Y/n]: ') -ine 'N'
    Invoke-ZapretMenuOperation service Refresh { Set-ZapretServiceConfiguration -Root $root -Preset $service.Preset -IPSetMode $ipset -Restart:$restart }
    if (-not $restart) { Write-Host 'Validated configuration saved; it will apply on the next service start.' -ForegroundColor Yellow }
}
function Install-ZapretMenuService {
    Clear-ZapretMenu
    $modes=Get-ZapretMenuModes
    $classic=@($classicPresets)
    $next=@($nextPresets)
    $presets=@(Get-ZapretMenuPresets)
    $custom=@($presets | Where-Object { $_ -notin $publicPresets })
    foreach ($preset in $presets) { if (-not [IO.File]::Exists((Join-Path $root ('presets\'+$preset+'.txt.in')))) { throw "Missing preset: $preset" } }
    Write-Host ('{0,-46}{1,-30}{2}' -f '  Classic presets','NEXT presets','Custom / other')
    Write-Host ('{0,-46}{1,-30}{2}' -f '  ----------------------------------------','----------------------------','----------------------')
    $rows=[Math]::Max([Math]::Max($classic.Count,$next.Count),$custom.Count)
    for ($i=0;$i -lt $rows;$i++) {
        $left=if ($i -lt $classic.Count) { "{0}. {1}" -f ($i+1),$classic[$i] } else {''}
        $middle=if ($i -lt $next.Count) { "{0}. {1}" -f ($classic.Count+$i+1),$next[$i] } else {''}
        $customLine=if ($i -lt $custom.Count) { "{0}. {1}" -f ($classic.Count+$next.Count+$i+1),$custom[$i] } else {''}
        Write-Host ('{0,-46}{1,-30}{2}' -f ('  '+$left),$middle,$customLine)
    }
    $pick=Read-ZapretMenuLine "Select preset (1-$($presets.Count), 0=cancel): "
    if ($pick -eq '0') { return }
    $selection=0
    if ($pick -notmatch '^\d+$' -or -not [int]::TryParse($pick,[ref]$selection) -or $selection -lt 1 -or $selection -gt $presets.Count) { throw 'Invalid preset selection.' }
    $selected=$presets[$selection-1]
    Write-Host "`nSelected configuration:`n  Strategy: $selected   Game: $($modes.Game)   IPSet: $($modes.IPSet)   Voice: $($modes.Voice)"
    Write-Host "  UDP fakes: Discord=$($modes.DiscordFakeLabel)   Game=$($modes.GameFakeLabel)"
    if ((Read-ZapretMenuLine 'Install this service configuration? [Y/n]: ') -ieq 'N') { return }
    $ipset=if ($modes.IPSet -eq 'any') {'loaded'} else {$modes.IPSet}
    if ($modes.IPSet -eq 'any') { Write-Host 'IPSet any is diagnostic-only; service installation will use loaded.' -ForegroundColor Yellow }
    Invoke-ZapretMenuOperation service Install { Set-ZapretServiceConfiguration -Root $root -Preset $selected -IPSetMode $ipset -Install }
    Wait-ZapretMenu
}
function Show-ZapretMenuStatus {
    Clear-ZapretMenu
    $service=Get-ZapretMenuService; $modes=Get-ZapretMenuModes
    $script:telegramStatus=Get-ZapretMenuTelegram
    Write-Host "Service name:       winws2`nService state:      $($service.State)`nSelected strategy:  $($service.Preset)"
    Write-Host "Game filter:        $($modes.Game)`nIPSet filter:       $($modes.IPSet)`nDiscord Voice:      $($modes.Voice)"
    Write-Host "Game TCP ports:     $($modes.GameTcpPorts)`nGame UDP ports:     $($modes.GameUdpPorts)"
    Write-Host "Discord UDP fake:   $($modes.DiscordFakeLabel)`nGame UDP fake:      $($modes.GameFakeLabel)"
    Write-Host "Configuration:      $($service.Preset) + $($modes.Game) + $($modes.IPSet) + $($modes.Voice) + D:$($modes.DiscordFakeLabel) + G:$($modes.GameFakeLabel)"
    Write-Host "Auto update check:  $($modes.Update)`nTelegram:           $script:telegramStatus"
    Write-Host ('winws2 process:     '+$(if (Test-ZapretMenuEngineProcess) {'running'} else {'not running'}))
    $driver=Get-Service WinDivert -ErrorAction Ignore
    try { Write-Host ('WinDivert driver:   '+$(if ($driver -and $driver.Status -eq 'Running') {'running'} else {'not running'})) }
    finally { if ($driver) { $driver.Dispose() } }
    Write-ZapretLogEvent -Component service -Action Status -Stage snapshot -Code StateObserved -Details @{preset=$service.Preset}
    Wait-ZapretMenu
}
function Test-ZapretMenuEngineProcess {
    $processes=[Diagnostics.Process]::GetProcessesByName('winws2')
    try { return $processes.Count -gt 0 }
    finally { foreach ($process in $processes) { $process.Dispose() } }
}
function Set-ZapretMenuMode([int]$Selection) {
    Clear-ZapretMenu
    $modes=Get-ZapretMenuModes
    $name=''; $value=''
    switch ($Selection) {
        4 {
            Write-Host "Select game filter mode:`n  0. Off`n  1. TCP and UDP`n  2. TCP only`n  3. UDP only`n  4. Change TCP ports [$($modes.GameTcpPorts)]`n  5. Change UDP ports [$($modes.GameUdpPorts)]`n  6. Back"
            $pick=Read-ZapretMenuLine 'Selection (0-6): '
            if ($pick -eq '6') { return }
            if ($pick -notmatch '^[0-5]$') { throw 'Invalid selection.' }
            if ([int]$pick -le 3) { $name='game_filter.mode';$value=@('off','all','tcp','udp')[[int]$pick] }
            else {
                $name=if ($pick -eq '4') {'game_tcp.ports'} else {'game_udp.ports'}
                $inputPorts=Read-ZapretMenuLine 'Ports/ranges (e.g. 1024-1934,1936-65535; ENTER=cancel): '
                if (-not $inputPorts.Trim()) { return }
                $value=ConvertTo-ZapretPortRange $inputPorts
            }
        }
        5 { $name='ipset_filter.mode';$value=if ($modes.IPSet -eq 'loaded') {'none'} else {'loaded'} }
        7 {
            Write-Host "Select Discord Voice mode:`n  0. Off        - protect Discord/STUN from the Game UDP fallback`n  1. Standard   - official discovery fake profile`n  2. Compatible - voice sequence of the selected preset"
            $pick=Read-ZapretMenuLine 'Selection (0-2): '
            if ($pick -notmatch '^[0-2]$') { throw 'Invalid selection.' }
            $name='voice_filter.mode';$value=@('off','standard','compatible')[[int]$pick]
        }
        8 {
            Write-Host "Select an immutable UDP fake profile:`n`n  Discord Voice (current: $($modes.DiscordFakeLabel))`n     1. current`n     2. steam`n     3. google`n`n  Game Filter UDP (current: $($modes.GameFakeLabel))`n     4. current`n     5. dbank-v2`n     6. steam`n`n     7. Reset both to current`n     0. Cancel"
            $choices=@(Get-ZapretFakeChoices $root)
            foreach ($kind in @('Discord','Game')) {
                $activeSelection=if ($kind -eq 'Discord') {$modes.DiscordFake} else {$modes.GameFake}
                try { $active=(Get-FileHash -LiteralPath (Get-ZapretFakePath $root $activeSelection $kind) -Algorithm SHA256).Hash; Write-Host ("  Current $kind SHA256: "+$active.Substring(0,12)) }
                catch { Write-Host ("  Current $kind fake is missing or changed; select it again.") -ForegroundColor Yellow }
            }
            Write-Host 'Additional files: Discord / Game number, name, SHA256 prefix'
            for ($i=0;$i -lt $choices.Count;$i++) {
                Write-Host ('  {0}/{1}. {2}  [{3}]' -f (8+2*$i),(9+2*$i),$choices[$i].Name,$choices[$i].Hash.Substring(0,12))
            }
            $pick=Read-ZapretMenuLine 'Selection (0=cancel): '
            if ($pick -eq '0') { return }
            $number=0
            if ($pick -notmatch '^\d+$' -or -not [int]::TryParse($pick,[ref]$number) -or $number -lt 1 -or $number -gt (7+2*$choices.Count)) { throw 'Invalid selection.' }
            if ($number -le 7) {
                $name=if ($number -le 3) {'discord_fake.mode'} elseif ($number -eq 7) {'fake-defaults'} else {'game_fake.mode'}
                $value=@('current','steam','google','current','dbank-v2','steam','current')[$number-1]
            } else {
                $name=if (($number-8)%2 -eq 0) {'discord_fake.mode'} else {'game_fake.mode'}
                $choice=$choices[[int][Math]::Floor(($number-8)/2)]
                $gate=Enter-ZapretBundleOperation $root
                try { $value=Import-ZapretFake $root $choice } finally { Exit-ZapretBundleOperation $gate }
            }
        }
    }
    Invoke-ZapretMenuOperation update SetSetting { Set-ReleaseMenuSetting $root $name $value }
    $notice=switch ($Selection) {
        4 {
            if ($name -like '*.ports') { "Game ports saved: $value." }
            else { $label=@{off='Off';all='TCP and UDP';tcp='TCP only';udp='UDP only'}[$value]; "Game Filter saved: $label." }
        }
        5 {
            if ($value -eq 'loaded') { 'IPSet Filter saved: Enabled (loaded IP list).' }
            else { 'IPSet Filter saved: Disabled (IP list is not used).' }
        }
        7 { "Discord Voice saved: $value." }
        8 {
            if ($name -eq 'fake-defaults') { 'UDP fake profiles reset: Discord=current, Game=current.' }
            elseif ($name -eq 'discord_fake.mode') { "Discord UDP fake profile saved: $value." }
            else { "Game UDP fake profile saved: $value." }
        }
    }
    Write-Host $notice -ForegroundColor Green
    if ($Selection -eq 8) { Write-Host 'Experimental fakes can help or break connectivity; verify Discord Voice and the affected game after switching.' -ForegroundColor Yellow }
    # Even a repeated selection may apply a deferred config or changed user lists.
    Update-ZapretMenuService
    Wait-ZapretMenu
}
function Show-ZapretTelegramMenu {
    do {
        Clear-ZapretMenu
        $script:telegramStatus=Get-ZapretMenuTelegram
        Write-Host 'Telegram Desktop proxy' -ForegroundColor Cyan
        Write-Host "Status: $script:telegramStatus`n`n  1. Enable and connect Telegram`n  2. Connect Telegram`n  3. Restart proxy`n  4. Disable proxy`n  5. Show status`n  6. Diagnose Telegram endpoints`n  0. Back`n"
        $pick=Read-ZapretMenuLine 'Select option (0-6): '
        if ($pick -eq '0') { return }
        $action=switch ($pick) {'1' {'Enable'} '2' {'Connect'} '3' {'Restart'} '4' {'Disable'} '5' {'Status'} '6' {'Diagnose'}}
        if (-not $action) { continue }
        try {
            Invoke-ZapretMenuOperation telegram $action {
                switch ($action) {
                    Enable { Enable-ZapretTelegram $root; Connect-ZapretTelegram $root }
                    Connect { Connect-ZapretTelegram $root }
                    Restart { Restart-ZapretTelegram $root }
                    Disable { Disable-ZapretTelegram $root }
                    Status { Get-ZapretTelegramStatus $root -Fast | Format-List | Out-Host }
                    Diagnose { Invoke-ZapretTelegramDiagnostics $root }
                }
            }
        } catch { Write-ZapretLogException $_ -Warning; Write-Host ('[ERROR] '+$_.Exception.Message) -ForegroundColor Red }
        Wait-ZapretMenu
    } while ($true)
}
function Show-ZapretQuickCheck {
    Clear-ZapretMenu
    Write-Host 'Zapret 2 NEXT diagnostics'
    Write-Host 'Administrator rights: OK' -ForegroundColor Green
    foreach ($file in @('bin\winws2.exe','bin\cygwin1.dll','bin\WinDivert.dll','bin\WinDivert64.sys','lua\zapret-lib.lua','lua\zapret-antidpi.lua')) {
        if ([IO.File]::Exists((Join-Path $root $file))) { Write-Host ('[OK] '+[IO.Path]::GetFileName($file)) }
        else { Write-Host ('Missing '+$file) -ForegroundColor Red }
    }
    $bfe=Get-Service BFE -ErrorAction Ignore
    try {
        if ($bfe -and $bfe.Status -eq 'Running') { Write-Host 'Base Filtering Engine: running' -ForegroundColor Green }
        else { Write-Host 'Base Filtering Engine: not running' -ForegroundColor Red }
    } finally { if ($bfe) { $bfe.Dispose() } }
    $tcp= & netsh.exe interface tcp show global
    if ($tcp -match 'timestamps\s+.*enabled') { Write-Host 'TCP timestamps: enabled' -ForegroundColor Green }
    else { Write-Host 'TCP timestamps: not reported as enabled' -ForegroundColor Yellow }
    $proxy=Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -Name ProxyEnable -ErrorAction SilentlyContinue
    if ($proxy -and $proxy.ProxyEnable) { Write-Host 'System proxy is enabled' -ForegroundColor Yellow }
    . (Join-Path $PSScriptRoot 'environment-diagnostics.ps1')
    foreach ($finding in @(Get-ZapretEnvironmentDiagnostics $root)) {
        Write-Host ("[{0}] {1} {2}" -f $finding.Severity,$finding.Message,$finding.Action) -ForegroundColor $(if ($finding.Severity -eq 'Warning') {'Yellow'} else {'Gray'})
    }
    $service=Get-ZapretMenuService; $modes=Get-ZapretMenuModes
    Write-Host "Service: $($service.State), strategy: $($service.Preset), game: $($modes.Game), ipset: $($modes.IPSet), voice: $($modes.Voice)"
    $status=Get-ZapretTelegramStatus $root -Fast
    $script:telegramStatus=$status.State; $status | Format-List | Out-Host
    Invoke-ZapretMenuChild validate.ps1 @('-Quick')
    Wait-ZapretMenu
}
function Show-ZapretDiagnosticsMenu {
    do {
        Clear-ZapretMenu
        Write-Host "Zapret 2 NEXT diagnostics`n-----------------------------------------------`n  1. Quick check`n  2. Create support report (automatic)`n  3. Compatibility Wizard (advanced)`n  4. Discord Voice diagnostic (advanced)`n  5. Create logs archive`n  0. Back"
        $pick=Read-ZapretMenuLine 'Select option (0-5): '
        try {
            switch ($pick) {
                0 { return }
                1 { Show-ZapretQuickCheck }
                2 { Invoke-ZapretMenuChild support-diagnostics.ps1; Wait-ZapretMenu }
                3 { & (Join-Path $PSScriptRoot 'compatibility wizard.bat') }
                4 { & (Join-Path $PSScriptRoot 'diagnose discord voice.bat') }
                5 {
                    Invoke-ZapretMenuOperation menu Export {
                        $zip=Export-ZapretSessionLogs -Root $root -Archive
                        Write-Host "Logs archive / Архив логов: $zip" -ForegroundColor Cyan
                        Write-Host 'Attach this ZIP to your GitHub Issue or Discord message. It is not sent automatically.'
                        Start-Process explorer.exe -ArgumentList ('/select,"'+$zip+'"') | Out-Null
                    }
                    Wait-ZapretMenu
                }
            }
        } catch { Write-ZapretLogException $_ -Warning; Write-Host ('[ERROR] '+$_.Exception.Message) -ForegroundColor Red; Wait-ZapretMenu }
    } while ($true)
}
function Invoke-ZapretMenuAction([int]$Selection) {
    switch ($Selection) {
        1 { Install-ZapretMenuService }
        2 { Clear-ZapretMenu; Invoke-ZapretMenuOperation service Remove { Remove-ZapretServiceConfiguration -Root $root }; Wait-ZapretMenu }
        3 { Show-ZapretMenuStatus }
        {$_ -in 4,5,7,8} { Set-ZapretMenuMode $Selection }
        6 {
            Invoke-ZapretMenuOperation update ToggleCheck { Switch-ReleaseMenuCheck $root }
            $script:updateCheckStarted=$false
            Wait-ZapretMenu
        }
        9 { Show-ZapretTelegramMenu }
        10 {
            Clear-ZapretMenu
            Invoke-ZapretMenuChild update-ipset.ps1 @('-Destination',(Join-Path $root 'lists\ipset-all.txt'))
            Update-ZapretMenuService; Wait-ZapretMenu
        }
        11 {
            Clear-ZapretMenu
            $output=Join-Path $env:TEMP 'zapret2-next-hosts.txt'
            $url=try { 'https://raw.githubusercontent.com/'+(Get-ReleaseRepository $root)+'/main/.service/hosts' } catch {''}
            Invoke-ZapretMenuChild prepare-hosts.ps1 @('-Output',$output,'-RemoteUrl',$url)
            Write-Host 'The system hosts file is never modified automatically. Review the generated DNS snapshot and copy only the entries you need.'
            Start-Process notepad.exe -ArgumentList ('"'+$output+'"') | Out-Null
            Start-Process explorer.exe -ArgumentList ('/select,"'+$env:SystemRoot+'\System32\drivers\etc\hosts"') | Out-Null
            Wait-ZapretMenu
        }
        12 { Clear-ZapretMenu; Invoke-ZapretMenuChild update-release.ps1 @('-Action','Check','-Force'); Wait-ZapretMenu }
        13 { Show-ZapretDiagnosticsMenu }
        14 { Start-Process powershell.exe -ArgumentList ('-NoExit -NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $PSScriptRoot 'test-presets.ps1')+'"') -WindowStyle Normal | Out-Null }
        15 { Clear-ZapretMenu; Invoke-ZapretMenuChild clear-discord-cache.ps1; Wait-ZapretMenu }
        111 {
            Clear-ZapretMenu
            Invoke-ZapretMenuChild update-release.ps1 @('-Action','Prepare','-Launch')
            $worker=Join-Path $root 'runtime\release-update\recovery\update-release.ps1'
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $worker -Action ReleaseMenu -Root $root -MenuProcessId $PID
            if ($LASTEXITCODE -ne 0) { throw 'Could not release the update menu.' }
            $script:handoff=$true; $script:menuExit=$true
        }
    }
}

# Menu entry point.
if ($LibraryOnly) { return }
$exitCode=0; $script:handoff=$false; $script:menuExit=$false
$script:updateCheckStarted=$false; $script:checkProcess=$null
Initialize-ZapretLog -Root $root -Component menu -Action Start -SessionId $SessionId -OwnerProcessId $PID
try {
    Write-ZapretLogSettingsSnapshot $root
    if (-not (Test-ZapretMenuAdministrator)) {
        Write-Host 'Requesting administrator rights...'
        $session=if ($script:ZapretLog) {$script:ZapretLog.Id} else {'disabled'}
        if ($session -eq 'disabled') { $env:ZAPRET_LOG_DISABLED='1' }
        $arguments='/c ""'+(Join-Path $root 'service.bat')+'" log_session '+$session+'"'
        $null=Start-Process cmd.exe -ArgumentList $arguments -Verb RunAs -ErrorAction Stop
        $script:handoff=$true
    } else {
        if (-not [Console]::IsOutputRedirected) {
            try {
                if ([Console]::BufferWidth -lt 110 -or [Console]::BufferHeight -lt 40) { [Console]::SetBufferSize([Math]::Max(110,[Console]::BufferWidth),[Math]::Max(40,[Console]::BufferHeight)) }
                [Console]::SetWindowSize([Math]::Min(110,[Console]::LargestWindowWidth),[Math]::Min(40,[Console]::LargestWindowHeight))
            } catch {}
        }
        foreach ($marker in @('recovery-needed','cleanup-pending')) {
            if ([IO.File]::Exists((Join-Path $root ('runtime\release-update\'+$marker)))) {
                $worker=Join-Path $root 'runtime\release-update\recovery\update-release.ps1'
                if (-not [IO.File]::Exists($worker)) { throw 'Recovery worker is missing. Restore the original release before continuing.' }
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $worker -Action Recover -Root $root
                if ($LASTEXITCODE -ne 0) { throw 'Release recovery failed. The menu cannot continue.' }
            }
        }
        $script:telegramStatus=Get-ZapretMenuTelegram
        while (-not $script:menuExit) {
            $service=Get-ZapretMenuService; $modes=Get-ZapretMenuModes
            Show-ZapretMenu $service $modes $script:telegramStatus
            try { $selection=Read-ReleaseMenuChoice $root -OnReady {
                if (-not $script:readyRecorded) {
                    Write-ZapretLogEvent -Stage ready -Details @{durationMs=[long]$startupTimer.ElapsedMilliseconds}
                    $script:readyRecorded=$true
                }
                Start-ZapretMenuCheck
            } }
            catch { Write-Host 'Could not read the menu selection.' -ForegroundColor Red; Write-ZapretLogException $_ -Warning; Wait-ZapretMenu; continue }
            Write-ZapretLogEvent -Component menu -Action Select -Stage selection -Details @{selection=[int]$selection}
            if ($selection -eq 0) { break }
            if ($selection -eq 255) { continue }
            try { Invoke-ZapretMenuAction $selection }
            catch { Write-ZapretLogException $_ -Warning; Write-Host ('[ERROR] '+$_.Exception.Message) -ForegroundColor Red; Wait-ZapretMenu }
        }
    }
} catch { $exitCode=1; Write-ZapretLogException $_; Write-Host ('[ERROR] '+$_.Exception.Message) -ForegroundColor Red }
finally {
    Close-ZapretLogMenu -Handoff:$script:handoff -OwnerProcessId $PID -ExitCode $exitCode
    Complete-ZapretLogOperation -ExitCode $exitCode
    Save-ZapretSessionSummary $root
    if ($script:checkProcess) { $script:checkProcess.Dispose() }
}
exit $exitCode
