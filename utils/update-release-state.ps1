# Windows boundaries are deliberately separate from the file transaction.
function Get-ReleaseConfigOptions([string]$Path) {
    $text = [IO.File]::ReadAllText($Path)
    $options = @{}
    $fields = [ordered]@{Preset='Preset';GameMode='Game filter';IPSetMode='IPSet filter';VoiceMode='Discord Voice';DiscordFake='Discord UDP fake';GameFake='Game UDP fake'}
    foreach ($field in $fields.GetEnumerator()) {
        $matchesFound = [regex]::Matches($text, ('(?m)^# ' + [regex]::Escape($field.Value) + ': ([^\r\n]+)\r?$'))
        if ($matchesFound.Count -ne 1) { throw 'The active engine configuration is not a recognized generated configuration.' }
        $options[$field.Key] = $matchesFound[0].Groups[1].Value
    }
    if ($options.Preset -match '^CUSTOM (SAFE|BALANCED)$') { $options.Preset = 'NEXT ' + $matches[1] }
    if ($options.Preset -notmatch '^[A-Za-z0-9 _-]+$' -or $options.GameMode -notin @('off','tcp','udp','all') -or
        $options.IPSetMode -notin @('loaded','none') -or $options.VoiceMode -notin @('off','standard','compatible') -or
        $options.DiscordFake -notin @('current','steam','google') -or $options.GameFake -notin @('current','dbank-v2','steam')) {
        throw 'The active configuration uses settings that cannot be migrated.'
    }
    return $options
}
function Get-ReleaseEngineProcesses {
    @(Get-CimInstance Win32_Process -Filter "Name='winws2.exe' OR Name='winws.exe'" -ErrorAction Stop)
}
function Stop-ReleaseOwnedDriver([string]$Root) {
    $driver = Get-CimInstance Win32_SystemDriver -Filter "Name='WinDivert'" -ErrorAction Stop
    if (-not $driver -or $driver.State -eq 'Stopped') { return }
    $path = ([string]$driver.PathName).Trim('"')
    if ($path.StartsWith('\??\') -or $path.StartsWith('\\?\')) { $path = $path.Substring(4) }
    # WinDivert is shared system-wide. Never stop another bundle's driver.
    if ($path -ine (Join-Path $Root 'bin\WinDivert64.sys')) { return }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while (@(Get-ReleaseEngineProcesses).Count) {
        if ($timer.Elapsed.TotalSeconds -ge 5) { throw 'An engine is still running; the release driver cannot be stopped safely.' }
        Start-Sleep -Milliseconds 50
    }
    # Stopping winws2 alone does not unload WinDivert. Otherwise its old .sys
    # remains mapped after bin is moved to backup and cannot be deleted.
    $service = Get-Service -Name WinDivert -ErrorAction Stop
    if ($service.Status -ne 'Stopped') {
        if ($service.Status -ne 'StopPending') { $service.Stop() }
        # WinDivert can remove its registration on unload. ServiceController's
        # WaitForStatus then throws 1060 even though the driver stopped normally.
        $timer.Restart()
        while ($true) {
            $current = Get-CimInstance Win32_SystemDriver -Filter "Name='WinDivert'" -ErrorAction Stop
            if (-not $current -or $current.State -eq 'Stopped') { break }
            if ($timer.Elapsed.TotalSeconds -ge 30) { throw 'The release driver did not unload.' }
            Start-Sleep -Milliseconds 50
        }
    }
}
function Get-ReleaseWindowsState([string]$Root) {
    $service = Get-ZapretServiceSnapshot
    $configs = @(); $manual = @(); $telegram = @()
    $engine = Join-Path $Root 'bin\winws2.exe'
    $serviceConfig = Join-Path $Root 'runtime\service.txt'
    $servicePid = 0
    if ($service) {
        $expected = '"' + $engine + '" @"' + $serviceConfig + '"'
        if ($service.PathName -ine $expected) { throw 'The winws2 service belongs to another installation. Update that installation instead.' }
        $live = Get-CimInstance Win32_Service -Filter "Name='winws2'" -ErrorAction Stop
        if ($live.State -notin @('Running','Stopped')) { throw 'Wait until the winws2 service finishes changing state.' }
        $servicePid = $live.ProcessId
        $options = Get-ReleaseConfigOptions $serviceConfig
        $strategy = [string]$service.Strategy
        if ($strategy -match '^CUSTOM (SAFE|BALANCED)$') { $strategy = 'NEXT ' + $matches[1] }
        if ($strategy -ine $options.Preset) { throw 'Service metadata and the applied configuration disagree. Reinstall the selected strategy first.' }
        $configs += [pscustomobject]@{Relative='runtime\service.txt';Options=$options;Original=[Convert]::ToBase64String([IO.File]::ReadAllBytes($serviceConfig))}
    }
    foreach ($process in @(Get-ReleaseEngineProcesses)) {
        if ($process.ProcessId -eq $servicePid) { continue }
        if ($process.ExecutablePath -ine $engine) { throw 'Another Zapret/legacy engine is running. Close its bundle before updating.' }
        $pattern = '^"?' + [regex]::Escape($engine) + '"?\s+@"([^"\r\n]+)"\s*$'
        if ([string]$process.CommandLine -notmatch $pattern) { throw 'Unknown manual engine command. Close it before updating.' }
        $configPath = Assert-ReleaseChildPath (Join-Path $Root 'runtime') $matches[1]
        if ((Split-Path $configPath -Leaf) -notlike 'manual-*.txt') { throw 'Only generated manual launches can be restored automatically.' }
        $relative = $configPath.Substring($Root.TrimEnd('\').Length + 1)
        $configs += [pscustomobject]@{Relative=$relative;Options=(Get-ReleaseConfigOptions $configPath);Original=[Convert]::ToBase64String([IO.File]::ReadAllBytes($configPath))}
        $manual += [pscustomobject]@{Pid=$process.ProcessId;Config=$relative;CommandLine=[string]$process.CommandLine}
    }
    if ($manual.Count -gt 1 -or ($service -and $service.WasRunning -and $manual.Count)) { throw 'Multiple active engine configurations cannot be updated automatically.' }
    $telegramExe = Join-Path $Root 'bin\telegram\zapret-telegram.exe'
    foreach ($task in @(Get-ScheduledTask -TaskPath '\' -ErrorAction Stop)) {
        if (-not @($task.Actions | Where-Object { $_.Execute -ieq $telegramExe }).Count) { continue }
        if ($task.TaskName -notmatch '^Zapret2Next-Telegram-(S-1-\d+(?:-\d+)+)$') { throw 'An unrecognized scheduled task uses this Telegram executable.' }
        $sid = $matches[1]
        $context = [pscustomobject]@{Root=$Root;SID=$sid;TaskName=[string]$task.TaskName;Executable=$telegramExe
            Runtime=(Join-Path $Root ('runtime\telegram\' + $sid));Config=(Join-Path $Root ('runtime\telegram\' + $sid + '\config.json'))
            Log=(Join-Path $Root ('runtime\telegram\' + $sid + '\proxy.log'))}
        Assert-ZapretTelegramTaskOwner $context $task
        $config = Read-ZapretTelegramConfig $context
        if (-not $config) { throw 'An enabled Telegram task has no valid saved configuration.' }
        $telegram += [pscustomobject]@{Context=$context;Port=$config.port;WasRunning=([string]$task.State -in @('Running','Queued'))
            Enabled=([string]$task.State -ne 'Disabled');Xml=(Export-ScheduledTask -TaskName $task.TaskName -TaskPath '\' -ErrorAction Stop)}
    }
    foreach ($process in @(Get-ZapretTelegramProcesses | Where-Object { $_.ExecutablePath -ieq $telegramExe })) {
        if (-not @($telegram | Where-Object { Test-ZapretTelegramProcessOwner $_.Context $process }).Count) { throw 'An unmanaged Telegram proxy is using this installation. Close it first.' }
    }
    return [pscustomobject]@{Service=$service;Configs=@($configs);Manual=@($manual);Telegram=@($telegram)}
}
function Stop-ReleaseWindowsState($Snapshot) {
    foreach ($entry in $Snapshot.Telegram) {
        Disable-ScheduledTask -TaskName $entry.Context.TaskName -TaskPath '\' -ErrorAction Stop | Out-Null
        Stop-ZapretTelegramTask $entry.Context
    }
    if ($Snapshot.Service) { Stop-ZapretService }
    foreach ($saved in $Snapshot.Manual) {
        $process = Get-CimInstance Win32_Process -Filter ("ProcessId=" + [int]$saved.Pid) -ErrorAction Stop
        if ($process) {
            if ([string]$process.CommandLine -cne [string]$saved.CommandLine) { throw 'The manual engine changed while the update was being prepared.' }
            Stop-Process -Id $saved.Pid -ErrorAction Stop
            $handle = Get-Process -Id $saved.Pid -ErrorAction SilentlyContinue
            if ($handle -and -not $handle.WaitForExit(5000)) { throw 'The manual engine did not stop.' }
        }
    }
}
function Stop-ReleaseInstalledProcesses([string]$Root, $Snapshot) {
    if ($Snapshot.Service) { Stop-ZapretService }
    foreach ($entry in $Snapshot.Telegram) { Stop-ZapretTelegramTask $entry.Context }
    foreach ($process in @(Get-ReleaseEngineProcesses | Where-Object { $_.ExecutablePath -ieq (Join-Path $Root 'bin\winws2.exe') })) {
        Stop-Process -Id $process.ProcessId -ErrorAction Stop
        $handle = Get-Process -Id $process.ProcessId -ErrorAction SilentlyContinue
        if ($handle -and -not $handle.WaitForExit(5000)) { throw 'The updated engine did not stop for rollback.' }
    }
}
function Start-ReleaseWindowsState([string]$Root, $Snapshot) {
    if ($Snapshot.Service) {
        Restore-ZapretServiceRegistration $Snapshot.Service
        if ($Snapshot.Service.WasRunning) { Start-ZapretService }
    }
    foreach ($saved in $Snapshot.Manual) {
        $process = Start-Process -FilePath (Join-Path $Root 'bin\winws2.exe') -ArgumentList ('@"' + (Join-Path $Root $saved.Config) + '"') -WorkingDirectory (Join-Path $Root 'bin') -WindowStyle Hidden -PassThru
        Start-Sleep -Seconds 3
        if ($process.HasExited) { throw 'The manual engine failed to restart.' }
    }
    foreach ($entry in $Snapshot.Telegram) {
        Restore-ZapretTelegramTaskRegistration $entry.Context $entry
        if ($entry.Enabled) { Enable-ScheduledTask -TaskName $entry.Context.TaskName -TaskPath '\' -ErrorAction Stop | Out-Null }
        else { Disable-ScheduledTask -TaskName $entry.Context.TaskName -TaskPath '\' -ErrorAction Stop | Out-Null }
        if ($entry.WasRunning) {
            Start-ZapretTelegramTask $entry.Context
            Wait-ZapretTelegramReady $entry.Context $entry.Port
        }
    }
}
function Test-ReleaseConfig([string]$Root, $Config, [string]$Output, [switch]$DryRun) {
    $options = @{}
    if ($Config.Options -is [Collections.IDictionary]) { foreach ($key in $Config.Options.Keys) { $options[$key]=$Config.Options[$key] } }
    else { foreach ($property in $Config.Options.PSObject.Properties) { $options[$property.Name] = $property.Value } }
    & (Join-Path $Root 'utils\render-config.ps1') @options -Output $Output -DryRun:$DryRun | Out-Null
    if ($DryRun) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'utils\invoke-winws.ps1') -Config $Output -LogPrefix ($Output + '.validate') -Validate
        if ($LASTEXITCODE -ne 0) { throw 'The new engine rejected the saved configuration.' }
    }
}
function Assert-ReleaseAppliedConfig([string]$Root, $Config, [string]$Output) {
    foreach ($name in @('list-general-user.txt','list-exclude-user.txt','ipset-exclude-user.txt')) {
        if (-not [IO.File]::Exists((Join-Path $Root ('lists\'+$name)))) { throw 'An active configuration has missing user lists. Restore them before updating.' }
    }
    Test-ReleaseConfig $Root $Config $Output
    $actual = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Config.Original)).Replace("`r`n","`n").Trim()
    $expected = [IO.File]::ReadAllText($Output).Replace("`r`n","`n").Trim()
    $actual = [regex]::Replace($actual,'(?m)^# Preset: CUSTOM (SAFE|BALANCED)$','# Preset: NEXT $1')
    if ($actual -cne $expected) { throw 'The active configuration contains manual changes that cannot be migrated automatically. Reinstall its preset or keep this release.' }
}
function Get-ReleaseSettings([string]$Root) {
    $settings = @()
    $defaults=@{'game_filter.mode'='off';'ipset_filter.mode'='loaded';'voice_filter.mode'='compatible';'discord_fake.mode'='current';'game_fake.mode'='current'}
    foreach ($name in $script:releaseModeNames) {
        $path = Join-Path $Root ('utils\' + $name)
        $settings += [pscustomobject]@{Name=$name;Bytes=$(if ([IO.File]::Exists($path)) {[Convert]::ToBase64String([IO.File]::ReadAllBytes($path))} else {$null});Default=$defaults[$name]}
    }
    return $settings
}
function Copy-ReleaseSettings($Settings, [string]$Stage) {
    $allowed = @{'game_filter.mode'=@('off','tcp','udp','all');'ipset_filter.mode'=@('loaded','none','any')
        'voice_filter.mode'=@('off','standard','compatible');'discord_fake.mode'=@('current','steam','google');'game_fake.mode'=@('current','dbank-v2','steam')}
    foreach ($entry in $Settings) {
        $path = Join-Path $Stage ('utils\' + $entry.Name)
        if ($null -ne $entry.Bytes) {
            $bytes = [Convert]::FromBase64String($entry.Bytes)
            if ($entry.Name -ne 'check_updates.enabled' -and ([Text.Encoding]::UTF8.GetString($bytes)).Trim() -notin $allowed[$entry.Name]) { throw 'A saved mode file is invalid.' }
            [IO.File]::WriteAllBytes($path, $bytes)
        } elseif ($entry.Name -eq 'check_updates.enabled') {
            if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }
        } else { [IO.File]::WriteAllText($path,($entry.Default+"`r`n"),[Text.Encoding]::ASCII) }
    }
}
function Get-ReleaseFingerprint([string]$Root, $Windows, $Settings) {
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add(($Windows | ConvertTo-Json -Depth 16 -Compress))
    $lines.Add(($Settings | ConvertTo-Json -Depth 8 -Compress))
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $Root 'lists') -Recurse -File -Force | Sort-Object FullName)) {
        if ($file.Name -like '*.lock') { continue }
        $lines.Add($file.FullName + ':' + (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash)
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($lines -join "`n")))).Replace('-','') }
    finally { $sha.Dispose() }
}
function Assert-ReleaseInstallation([string]$Root) {
    $full = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    if ($full -eq [IO.Path]::GetPathRoot($full).TrimEnd('\') -or (Test-Path -LiteralPath (Join-Path $full '.git'))) { throw 'Automatic updates are only supported in an extracted release, not a Git checkout or drive root.' }
    foreach ($path in @($script:releaseDirectories + @('lists'))) {
        $item = Join-Path $full $path
        if (-not (Test-Path -LiteralPath $item -PathType Container)) { throw "Incomplete installation: $path" }
        Assert-ReleaseNoLinks $item
    }
}
function Assert-ReleaseDiskSpace([string]$Root, [long]$Required) {
    $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Root)))
    if ($drive.AvailableFreeSpace -lt $Required) { throw 'Not enough free disk space to prepare the update. The installed version was preserved.' }
}
function Save-ReleaseTransaction([string]$Root, $Transaction) {
    Write-ReleaseJson (Join-Path (Get-ReleaseUpdateDirectory $Root) 'transaction.json') $Transaction
}
function Read-ReleaseTransaction([string]$Root) {
    $state = Read-ReleaseJson (Join-Path (Get-ReleaseUpdateDirectory $Root) 'transaction.json')
    if (-not $state) { return $null }
    if ($state.Schema -ne 1 -or $state.Root -ine [IO.Path]::GetFullPath($Root).TrimEnd('\') -or $state.Session -notmatch '^session-[a-f0-9]{32}$') { throw 'Invalid update recovery journal.' }
    foreach ($item in $state.Items) {
        if ($item.Relative -notin @($script:releaseDirectories + $script:releaseFiles) -and $item.Relative -notmatch '^lists\\[^:]+$') { throw 'Invalid replacement path in update journal.' }
        $null = Assert-ReleaseChildPath $Root (Join-Path $Root $item.Relative)
        if ($item.Relative -like 'lists\*') { $null = Assert-ReleaseChildPath (Join-Path $Root 'lists') (Join-Path $Root $item.Relative) }
    }
    foreach ($config in $state.Windows.Configs) { $null = Assert-ReleaseChildPath (Join-Path $Root 'runtime') (Join-Path $Root $config.Relative) }
    return $state
}
function Get-ReleaseSession([string]$Root, $Transaction) {
    Assert-ReleaseChildPath (Get-ReleaseUpdateDirectory $Root) (Join-Path (Get-ReleaseUpdateDirectory $Root) $Transaction.Session)
}
function Invoke-ReleasePrepare([string]$Root) {
    $Root = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    Assert-ReleaseInstallation $Root
    $directory = Initialize-ReleaseUpdateDirectory $Root
    $prepareLock = [IO.File]::Open((Join-Path $directory 'prepare.lock'),'OpenOrCreate','ReadWrite','None')
    $gate = $null
    $session = $null; $preparedRecorded = $false
    try {
        $previous = Read-ReleaseTransaction $Root
        if ($previous -and $previous.Status -notin @('committed','rolled-back','prepared')) { throw 'Recover the previous update before preparing a new one.' }
        if ($previous -and $previous.CleanupPending) { throw 'Finish the pending cleanup before preparing another update.' }
        Write-Host 'Проверка доступности релиза GitHub...' -ForegroundColor Cyan
        $check = Invoke-ReleaseCheck $Root -Force
        if (-not $check -or $check.Status -ne 'available') { throw 'A newer stable release with downloadable assets is not available.' }
        Assert-ReleaseDiskSpace $Root ([Math]::Max(100MB, $check.Offer.Size * 5))
        $sessionName = 'session-' + [Guid]::NewGuid().ToString('N')
        $session = Join-Path $directory $sessionName
        New-Item -ItemType Directory -Path $session -Force | Out-Null
        Write-Host ('Скачивание версии ' + $check.Offer.Version + ' (Zapret продолжает работать)...') -ForegroundColor Cyan
        $archive = Join-Path $session $check.Offer.ArchiveName
        $checksum = Join-Path $session 'release-sha256.txt'
        Save-ReleaseDownload $check.Offer.ChecksumUrl $checksum
        Save-ReleaseDownload $check.Offer.ArchiveUrl $archive
        $sumLines = @([IO.File]::ReadAllLines($checksum) | Where-Object { $_ -match ('^[0-9a-fA-F]{64}[ \t]+\*?' + [regex]::Escape($check.Offer.ArchiveName) + '$') })
        if ($sumLines.Count -ne 1 -or (Get-Item -LiteralPath $archive).Length -ne $check.Offer.Size -or
            (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ine ($sumLines[0] -split '\s+',2)[0]) { throw 'Downloaded release ZIP failed its SHA256/size check.' }
        Write-Host 'Проверка и распаковка архива...' -ForegroundColor Cyan
        Write-ZapretLogEvent -Component update -Stage extract -Result started
        $stage = Expand-ReleasePackage $archive (Join-Path $session 'unpacked') $check.Offer.Version
        Assert-ReleasePackage $stage $check.Offer
        Write-ZapretLogEvent -Component update -Stage validate -Details @{toVersion=$check.Offer.Version}
        $gate = Enter-ZapretBundleOperation $Root
        $windows = Get-ReleaseWindowsState $Root
        $settings = @(Get-ReleaseSettings $Root)
        $fingerprint = Get-ReleaseFingerprint $Root $windows $settings
        foreach ($config in $windows.Configs) { Assert-ReleaseAppliedConfig $Root $config (Join-Path $session ((Split-Path $config.Relative -Leaf)+'.original-check.txt')) }
        Copy-ReleaseSettings $settings $stage
        # Overlay existing lists only in staging. The installed lists never move.
        Copy-Item -LiteralPath (Join-Path $Root 'lists') -Destination $stage -Recurse -Force
        foreach ($config in $windows.Configs) { Test-ReleaseConfig $stage $config (Join-Path $session ((Split-Path $config.Relative -Leaf) + '.dry.txt')) -DryRun }
        if (-not $windows.Configs.Count) {
            Test-ReleaseConfig $stage ([pscustomobject]@{Options=@{Preset='general'}}) (Join-Path $session 'default.dry.txt') -DryRun
        }
        $items = @()
        foreach ($relative in @($script:releaseDirectories + $script:releaseFiles)) {
            $items += [pscustomobject]@{Relative=$relative;HadOriginal=(Test-Path -LiteralPath (Join-Path $Root $relative));Started=$false;Installed=$false;Restored=$false}
        }
        foreach ($file in Get-ChildItem -LiteralPath (Join-Path $stage 'lists') -File -Recurse -Force) {
            $relative = $file.FullName.Substring($stage.Length + 1)
            if (-not (Test-Path -LiteralPath (Join-Path $Root $relative))) { $items += [pscustomobject]@{Relative=$relative;HadOriginal=$false;Started=$false;Installed=$false;Restored=$false} }
        }
        $worker = Join-Path $directory 'recovery'
        New-Item -ItemType Directory -Path $worker -Force | Out-Null
        foreach ($file in @('update-release.ps1','update-release-core.ps1','update-release-state.ps1','bundle-operation.ps1','session-log.ps1','manage-logs.ps1','service-control.ps1','ipset-utils.ps1','telegram-control.ps1','release-info.ps1','menu-input.ps1','menu-settings.ps1')) {
            Copy-Item -LiteralPath (Join-Path $Root ('utils\' + $file)) -Destination $worker -Force
        }
        $transaction = [pscustomobject]@{Schema=1;Root=$Root;Session=$sessionName;Status='prepared';Offer=$check.Offer
            Fingerprint=$fingerprint;Windows=$windows;Settings=$settings;Items=@($items);ProcessesTouched=$false;ConfigsTouched=$false;CleanupPending=$false;Error=''}
        if ($script:ZapretLog) {
            $transaction | Add-Member -NotePropertyName LogSessionId -NotePropertyValue $script:ZapretLog.Id
            $transaction | Add-Member -NotePropertyName LogOperationId -NotePropertyValue $script:ZapretLog.OperationId
        }
        Save-ReleaseTransaction $Root $transaction
        $preparedRecorded = $true
        return $transaction
    } finally {
        Exit-ZapretBundleOperation $gate; $prepareLock.Dispose()
        if ($session -and -not $preparedRecorded) {
            try { Remove-ReleaseTree $directory $session } catch { Write-Host 'Не удалось убрать временные файлы неудачной загрузки.' -ForegroundColor Yellow }
        }
    }
}
function Invoke-ReleaseCheckpoint([string]$Name) { } # Failure-injection boundary.
function Move-ReleaseItem([string]$Source, [string]$Destination) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force | Out-Null
    # These paths are on the same volume. Directory.Move is a rename or a
    # failure, whereas Move-Item can fall back to a partial recursive move.
    if ([IO.Directory]::Exists($Source)) { [IO.Directory]::Move($Source, $Destination) }
    else { [IO.File]::Move($Source, $Destination) }
}
function Restore-ReleaseFiles([string]$Root, $Transaction) {
    $session = Get-ReleaseSession $Root $Transaction
    $backup = Join-Path $session 'backup'
    $items = @($Transaction.Items)
    [array]::Reverse($items)
    foreach ($item in $items) {
        if (-not $item.Started -or $item.Restored) { continue }
        $destination = Join-Path $Root $item.Relative
        $saved = Join-Path $backup $item.Relative
        if (Test-Path -LiteralPath $saved) {
            Remove-ReleaseTree $Root $destination
            Move-ReleaseItem $saved $destination
        } elseif (-not $item.HadOriginal) { Remove-ReleaseTree $Root $destination }
        # If the old move did not happen, the original is still in place.
        $item.Restored = $true
        Save-ReleaseTransaction $Root $Transaction
    }
    if ($Transaction.ConfigsTouched) {
        foreach ($config in $Transaction.Windows.Configs) { Write-AtomicFileBytes (Join-Path $Root $config.Relative) ([Convert]::FromBase64String($config.Original)) }
    }
}
function Invoke-ReleaseRollback([string]$Root, $Transaction) {
    Write-ZapretLogEvent -Component update -Action Rollback -Stage rollback -Result started
    $Transaction.Status = 'rolling-back'
    Save-ReleaseTransaction $Root $Transaction
    if ($Transaction.ProcessesTouched) {
        Stop-ReleaseInstalledProcesses $Root $Transaction.Windows
        # A failure before any bin move needs only the original engine restart.
        if (@($Transaction.Items | Where-Object { $_.Relative -eq 'bin' -and $_.Started }).Count) { Stop-ReleaseOwnedDriver $Root }
    }
    Restore-ReleaseFiles $Root $Transaction
    if ($Transaction.ProcessesTouched) { Start-ReleaseWindowsState $Root $Transaction.Windows }
    Write-ZapretLogEvent -Component update -Action Rollback -Stage end -Details @{statePreserved=$true;serviceRestored=$true}
    $Transaction.Status = 'rolled-back'
    $Transaction.CleanupPending = $false
    Save-ReleaseTransaction $Root $Transaction
    [IO.File]::Delete((Join-Path (Get-ReleaseUpdateDirectory $Root) 'recovery-needed'))
    [IO.File]::Delete((Join-Path (Get-ReleaseUpdateDirectory $Root) 'cleanup-pending'))
}
function Clear-ReleaseBackup([string]$Root, $Transaction) {
    $session = Get-ReleaseSession $Root $Transaction
    try {
        Remove-ReleaseTree $session (Join-Path $session 'backup')
        Remove-ReleaseTree $session (Join-Path $session 'unpacked')
        foreach ($name in @($Transaction.Offer.ArchiveName,'release-sha256.txt')) {
            $path = Assert-ReleaseChildPath $session (Join-Path $session $name)
            if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }
        }
        Write-ZapretLogEvent -Component update -Action Cleanup -Stage cleanup
        $Transaction.CleanupPending = $false
    } catch {
        Write-ZapretLogException $_ -Code CleanupPending -Warning
        $Transaction.CleanupPending = $true
        Write-Host 'Обновление установлено. Старые файлы пока заняты; очистка повторится при следующем запуске меню.' -ForegroundColor Yellow
    }
    Save-ReleaseTransaction $Root $Transaction
    $marker = Join-Path (Get-ReleaseUpdateDirectory $Root) 'cleanup-pending'
    if ($Transaction.CleanupPending) { [IO.File]::WriteAllText($marker, 'pending') }
    else { [IO.File]::Delete($marker) }
}
function Invoke-ReleaseApply([string]$Root) {
    Assert-ReleaseInstallation $Root
    $gate = Enter-ZapretBundleOperation $Root
    $locks = @()
    $transaction = $null
    try {
        $transaction = Read-ReleaseTransaction $Root
        if (-not $transaction -or $transaction.Status -ne 'prepared') { throw 'No prepared update is available.' }
        $windows = Get-ReleaseWindowsState $Root
        if ((Get-ReleaseFingerprint $Root $windows @(Get-ReleaseSettings $Root)) -cne $transaction.Fingerprint) { throw 'Settings or running processes changed during preparation. Run the update again.' }
        $session = Get-ReleaseSession $Root $transaction
        $stage = Join-Path $session ('unpacked\zapret2-next-v' + $transaction.Offer.Version)
        Assert-ReleaseNoLinks $stage
        Assert-ReleasePackage $stage $transaction.Offer
        $locks += [IO.File]::Open((Join-Path $Root 'runtime\engine-operation.lock'),'OpenOrCreate','ReadWrite','None')
        $locks += [IO.File]::Open((Join-Path $Root 'lists\ipset-all.txt.lock'),'OpenOrCreate','ReadWrite','None')
        foreach ($entry in $transaction.Windows.Telegram) { $locks += [IO.File]::Open((Join-Path $entry.Context.Runtime 'operation.lock'),'OpenOrCreate','ReadWrite','None') }
        [IO.File]::WriteAllText((Join-Path (Get-ReleaseUpdateDirectory $Root) 'recovery-needed'), 'pending')
        $transaction.Status='applying'; $transaction.ProcessesTouched=$true
        Save-ReleaseTransaction $Root $transaction
        Write-Host 'Применение обновления: остановка процессов этой сборки...' -ForegroundColor Cyan
        Stop-ReleaseWindowsState $transaction.Windows
        Stop-ReleaseOwnedDriver $Root
        Write-ReleaseLogCheckpoint 'stopped'
        Invoke-ReleaseCheckpoint 'stopped'
        foreach ($item in $transaction.Items) {
            $item.Started = $true
            Save-ReleaseTransaction $Root $transaction
            $destination = Join-Path $Root $item.Relative
            if ($item.HadOriginal) { Move-ReleaseItem $destination (Join-Path $session ('backup\' + $item.Relative)) }
            Write-ReleaseLogCheckpoint ('old:' + $item.Relative)
            Invoke-ReleaseCheckpoint ('old:' + $item.Relative)
            Move-ReleaseItem (Join-Path $stage $item.Relative) $destination
            $item.Installed = $true
            Save-ReleaseTransaction $Root $transaction
            Write-ReleaseLogCheckpoint ('new:' + $item.Relative)
            Invoke-ReleaseCheckpoint ('new:' + $item.Relative)
        }
        Write-ZapretLogEvent -Component update -Stage settings -Result started
        Write-Host 'Восстановление применённых настроек...' -ForegroundColor Cyan
        $transaction.ConfigsTouched = $true
        Save-ReleaseTransaction $Root $transaction
        foreach ($config in $transaction.Windows.Configs) {
            $dry = Join-Path $session ((Split-Path $config.Relative -Leaf) + '.final.dry.txt')
            Test-ReleaseConfig $Root $config $dry -DryRun
            Test-ReleaseConfig $Root $config (Join-Path $Root $config.Relative)
        }
        # Existing launcher helpers take this lock themselves when restarting.
        foreach ($lock in $locks) { $lock.Dispose() }; $locks=@()
        Start-ReleaseWindowsState $Root $transaction.Windows
        Write-ReleaseLogCheckpoint 'started'
        Invoke-ReleaseCheckpoint 'started'
        [IO.File]::WriteAllText((Join-Path (Get-ReleaseUpdateDirectory $Root) 'cleanup-pending'), 'pending')
        $transaction.Status='committed'; $transaction.CleanupPending=$true
        Save-ReleaseTransaction $Root $transaction
        [IO.File]::Delete((Join-Path (Get-ReleaseUpdateDirectory $Root) 'recovery-needed'))
        Clear-ReleaseBackup $Root $transaction
        Write-Host ('Обновление до ' + $transaction.Offer.Version + ' завершено. Настройки сохранены.') -ForegroundColor Green
        Write-ZapretLogEvent -Component update -Action Apply -Stage end -Details @{toVersion=$transaction.Offer.Version;statePreserved=$true;serviceRestored=$true}
        return $transaction
    } catch {
        Write-ZapretLogException $_ -Code UpdateFailed
        $failure = $_.Exception.Message
        foreach ($lock in $locks) { $lock.Dispose() }; $locks=@()
        if ($transaction -and $transaction.Status -eq 'applying') {
            $transaction.Error = $failure
            try { Invoke-ReleaseRollback $Root $transaction }
            catch { Write-ZapretLogException $_ -Code RollbackFailed; $transaction.Status='rollback-failed';$transaction.Error=$_.Exception.Message;Save-ReleaseTransaction $Root $transaction;throw ("Update failed: $failure Recovery also failed: " + $_.Exception.Message) }
        }
        throw $failure
    } finally { foreach ($lock in $locks) { $lock.Dispose() }; Exit-ZapretBundleOperation $gate }
}
function Invoke-ReleaseRecover([string]$Root) {
    $gate = Enter-ZapretBundleOperation $Root
    try {
        $transaction = Read-ReleaseTransaction $Root
        if (-not $transaction) { return }
        if ($transaction.Status -eq 'committed') { if ($transaction.CleanupPending) { Clear-ReleaseBackup $Root $transaction }; return }
        if ($transaction.Status -in @('applying','rolling-back','rollback-failed')) {
            Write-Host 'Восстановление прерванного обновления...' -ForegroundColor Yellow
            Invoke-ReleaseRollback $Root $transaction
        }
        if ($transaction.Status -in @('prepared','rolled-back')) { [IO.File]::Delete((Join-Path (Get-ReleaseUpdateDirectory $Root) 'recovery-needed')) }
    } finally { Exit-ZapretBundleOperation $gate }
}

function Write-ReleaseLogCheckpoint([string]$Name) {
    $parts=$Name -split ':',2
    $stage=switch ($parts[0]) { 'stopped' {'stop'} 'started' {'start'} default {'files'} }
    Write-ZapretLogEvent -Component update -Action Checkpoint -Stage $stage -Details @{item=$(if ($parts.Count -gt 1) {$parts[1]} else {''});fileOperation=$(switch ($parts[0]) {'old' {'backup'} 'new' {'install'}})}
}
