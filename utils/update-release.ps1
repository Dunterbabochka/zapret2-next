[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Check','Prepare','Apply','Recover','ReadMenuChoice','ReleaseMenu','SetSetting','ToggleCheck')][string]$Action,
    [string]$Root = '',
    [switch]$Force,
    [switch]$Quiet,
    [switch]$Launch,
    [switch]$ReopenMenu,
    [string]$Session = '',
    [string]$Name,
    [string]$Value
)
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')) }
. (Join-Path $PSScriptRoot 'update-release-core.ps1')
. (Join-Path $PSScriptRoot 'update-release-state.ps1')
$failed = $false
$workerLease = $null

function Get-ReleaseMenuBanner([string]$Root) {
    try {
        $cache = Read-ReleaseJson (Join-Path (Get-ReleaseUpdateDirectory $Root) 'check.json')
        if ($cache -and $cache.Status -eq 'available' -and $cache.Repository -ceq (Get-ReleaseRepository $Root) -and
            (Test-ReleaseNewer $cache.Offer.Version (Get-ReleaseVersion $Root))) {
            return 'Доступна новая версия ' + $cache.Offer.Version + '. Чтобы обновить Zapret, введите 111'
        }
    } catch {}
    return ''
}
function Read-ReleaseMenuChoice([string]$Root) {
    $prompt = '   Select option (0-15): '
    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
        $banner = Get-ReleaseMenuBanner $Root
        if ($banner) { [Console]::WriteLine($banner) }
        [Console]::Write($prompt)
        $answer = [Console]::ReadLine()
        if ($null -eq $answer) { return 0 }
        if ($answer -match '^(?:[0-9]|1[0-5]|111)$') { return [int]$answer }
        return 255
    }
    # Use a small local polling loop, not another process/network request for
    # every repaint. Reserve space above the prompt and preserve typed digits.
    [Console]::WriteLine('')
    [Console]::WriteLine('')
    $banner = ''; $answer = ''; $lastPoll = [DateTime]::MinValue
    [Console]::Write($prompt)
    while ($true) {
        if (([DateTime]::UtcNow - $lastPoll).TotalMilliseconds -ge 250) {
            $next = Get-ReleaseMenuBanner $Root
            if ($next -cne $banner) {
                $banner = $next
                [Console]::Write("`r`n")
                if ($banner) { [Console]::WriteLine($banner) }
                [Console]::Write($prompt + $answer)
            }
            $lastPoll = [DateTime]::UtcNow
        }
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq [ConsoleKey]::Enter) {
                [Console]::WriteLine('')
                if ($answer -match '^(?:[0-9]|1[0-5]|111)$') { return [int]$answer }
                return 255
            }
            if ($key.Key -eq [ConsoleKey]::Backspace) {
                if ($answer.Length) { $answer=$answer.Substring(0,$answer.Length-1);[Console]::Write("`b `b") }
            } elseif ($key.KeyChar -match '[0-9]' -and $answer.Length -lt 3) {
                $answer += $key.KeyChar; [Console]::Write($key.KeyChar)
            }
        } else { Start-Sleep -Milliseconds 25 }
    }
}
function Set-ReleaseMenuSetting([string]$Root, [string]$Name, [string]$Value) {
    $modes = @{
        'game_filter.mode'=@('off','tcp','udp','all');'ipset_filter.mode'=@('loaded','none','any')
        'voice_filter.mode'=@('off','standard','compatible');'discord_fake.mode'=@('current','steam','google')
        'game_fake.mode'=@('current','dbank-v2','steam')
    }
    if ($Name -ne 'fake-defaults' -and (-not $modes.ContainsKey($Name) -or $Value -notin $modes[$Name])) { throw 'Invalid setting.' }
    if ($Name -eq 'fake-defaults' -and $Value -cne 'current') { throw 'Invalid fake defaults.' }
    $gate = Enter-ZapretBundleOperation $Root
    try {
        if ($Name -eq 'fake-defaults') {
            foreach ($file in @('discord_fake.mode','game_fake.mode')) { Write-AtomicTextFile (Join-Path $Root ('utils\' + $file)) "current`r`n" }
        } else { Write-AtomicTextFile -Path (Join-Path $Root ('utils\' + $Name)) -Content ($Value + "`r`n") }
    }
    finally { Exit-ZapretBundleOperation $gate }
}

try {
    switch ($Action) {
        'ReadMenuChoice' {
            $selection=Read-ReleaseMenuChoice $Root
            if ($selection -eq 255) { exit 255 }
            # Reserve 0/1/... for errors from PowerShell itself. A failed input
            # helper must never be interpreted as "Install Service".
            exit (100+$selection)
        }
        'Check' {
            $result = Invoke-ReleaseCheck $Root -Force:$Force
            if (-not $Quiet) {
                if ($result -and $result.Status -eq 'available') { Write-Host (Get-ReleaseMenuBanner $Root) -ForegroundColor Yellow }
                elseif ($result -and $result.Status -eq 'current') { Write-Host 'Установлена актуальная версия.' -ForegroundColor Green }
                else { Write-Host 'Не удалось проверить обновления. Сборка продолжает работать.' -ForegroundColor Yellow }
            }
        }
        'Prepare' {
            $probePath = Join-Path (Initialize-ReleaseUpdateDirectory $Root) 'worker.lock'
            $probe = [IO.File]::Open($probePath,'OpenOrCreate','ReadWrite','None')
            $probe.Dispose()
            Invoke-ReleaseRecover $Root
            $transaction = Invoke-ReleasePrepare $Root
            if ($Launch) {
                $worker = Join-Path (Get-ReleaseUpdateDirectory $Root) 'recovery\update-release.ps1'
                $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $worker + '" -Action Apply -Root "' + $Root.TrimEnd('\') + '" -Session ' + $transaction.Session + ' -ReopenMenu'
                $process = Start-Process powershell.exe -ArgumentList $arguments -WorkingDirectory (Get-ReleaseUpdateDirectory $Root) -WindowStyle Normal -PassThru -ErrorAction Stop
                # A worker announces that it has loaded its recovery code before
                # the caller closes. No dependence on the lifetime of cmd /k.
                $ready = Join-Path (Get-ReleaseSession $Root $transaction) 'worker-ready'
                $timer = [Diagnostics.Stopwatch]::StartNew()
                while (-not [IO.File]::Exists($ready)) {
                    if ($process.HasExited -or $timer.Elapsed.TotalSeconds -gt 10) { throw 'The update worker could not start. The installed version is unchanged.' }
                    Start-Sleep -Milliseconds 50
                }
            }
        }
        'Apply' {
            if ($ReopenMenu) {
                $workerLease = [IO.File]::Open((Join-Path (Get-ReleaseUpdateDirectory $Root) 'worker.lock'),'OpenOrCreate','ReadWrite','None')
                $transaction = Read-ReleaseTransaction $Root
                if ($transaction.Session -cne $Session) { throw 'The prepared update was superseded by another preparation.' }
                $session = Get-ReleaseSession $Root $transaction
                [IO.File]::WriteAllText((Join-Path $session 'worker-ready'), 'ready')
                $timer = [Diagnostics.Stopwatch]::StartNew()
                while (-not [IO.File]::Exists((Join-Path $session 'menu-released'))) {
                    if ($timer.Elapsed.TotalSeconds -gt 15) { throw 'The old menu did not release control. Run 111 again.' }
                    Start-Sleep -Milliseconds 50
                }
                Start-Sleep -Milliseconds 150
            }
            $null = Invoke-ReleaseApply $Root
        }
        'Recover' { Invoke-ReleaseRecover $Root }
        'ReleaseMenu' {
            $transaction = Read-ReleaseTransaction $Root
            [IO.File]::WriteAllText((Join-Path (Get-ReleaseSession $Root $transaction) 'menu-released'), 'released')
        }
        'SetSetting' { Set-ReleaseMenuSetting $Root $Name $Value }
        'ToggleCheck' {
            $gate = Enter-ZapretBundleOperation $Root
            try {
                $path = Join-Path $Root 'utils\check_updates.enabled'
                if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }
                else { Write-AtomicTextFile $path "enabled`r`n" }
            } finally { Exit-ZapretBundleOperation $gate }
        }
    }
} catch {
    if (-not $Quiet) { Write-Host ('[ERROR] ' + $_.Exception.Message) -ForegroundColor Red }
    if ($ReopenMenu) { Write-Host 'Результат восстановления записан в runtime\release-update\transaction.json.' -ForegroundColor Yellow }
    $failed = $true
} finally {
    if ($workerLease) { $workerLease.Dispose() }
    if ($ReopenMenu) {
        Start-Process -FilePath 'cmd.exe' -ArgumentList ('/c ""' + (Join-Path $Root 'service.bat') + '""') -WorkingDirectory $Root -WindowStyle Normal
    }
}
if ($failed) { exit 1 }
exit 0
