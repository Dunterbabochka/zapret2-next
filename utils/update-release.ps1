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
    [string]$Value,
    [int]$MenuProcessId=0
)
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')) }
. (Join-Path $PSScriptRoot 'menu-input.ps1')
if ($Action -in @('SetSetting','ToggleCheck')) {
    . (Join-Path $PSScriptRoot 'menu-settings.ps1')
} elseif ($Action -ne 'ReadMenuChoice') {
    . (Join-Path $PSScriptRoot 'update-release-core.ps1')
    if ($Action -in @('Prepare','Apply','Recover','ReleaseMenu')) { . (Join-Path $PSScriptRoot 'update-release-state.ps1') }
}
. (Join-Path $PSScriptRoot 'session-log.ps1')
$logSession=''; $logOperation=''
if ($Action -in @('Apply','Recover')) {
    try {
        $logTransaction=Read-ReleaseTransaction $Root
        $logSession=[string]$logTransaction.LogSessionId; $logOperation=[string]$logTransaction.LogOperationId
    } catch {}
}
Initialize-ZapretLog -Root $Root -Component update -Action $Action -SessionId $logSession -OperationId $logOperation
$failed = $false
$workerLease = $null

try {
    switch ($Action) {
        'ReadMenuChoice' {
            $selection=Read-ReleaseMenuChoice $Root
            Write-ZapretLogEvent -Component menu -Action Select -Stage selection -Details @{selection=[int]$selection}
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
                # Persistent menu hosts release the marker just before exiting.
                # Wait for that exact process lifetime before replacing scripts.
                Wait-ReleaseMenuHost (Join-Path $session 'menu-released')
                Start-Sleep -Milliseconds 150
            }
            $null = Invoke-ReleaseApply $Root
        }
        'Recover' { Invoke-ReleaseRecover $Root }
        'ReleaseMenu' {
            Close-ZapretLogMenu -Handoff
            $transaction = Read-ReleaseTransaction $Root
            $release='released'
            if ($MenuProcessId) {
                $menu=Get-Process -Id $MenuProcessId -ErrorAction Stop
                try { $release=@{ProcessId=$MenuProcessId;StartedTicks=$menu.StartTime.ToUniversalTime().Ticks} | ConvertTo-Json -Compress }
                finally { $menu.Dispose() }
            }
            Write-AtomicTextFile (Join-Path (Get-ReleaseSession $Root $transaction) 'menu-released') $release
        }
        'SetSetting' { Set-ReleaseMenuSetting $Root $Name $Value }
        'ToggleCheck' {
            Switch-ReleaseMenuCheck $Root
        }
    }
} catch {
    Write-ZapretLogException $_ -Code UpdateFailed
    if (-not $Quiet) { Write-Host ('[ERROR] ' + $_.Exception.Message) -ForegroundColor Red }
    if ($ReopenMenu) { Write-Host 'Результат восстановления записан в runtime\release-update\transaction.json.' -ForegroundColor Yellow }
    $failed = $true
    if ($Action -in @('Prepare','Apply','Recover')) {
        $recoveryState = try { (Read-ReleaseTransaction $Root).Status } catch { 'unavailable' }
        Write-Host ('Code: UpdateFailed; recovery: ' + $recoveryState) -ForegroundColor Yellow
        Write-Host '13. Run Diagnostics -> 5. Create logs archive' -ForegroundColor Yellow
        Write-Host 'If the menu cannot open, run from this folder: powershell -NoProfile -ExecutionPolicy Bypass -File runtime\release-update\recovery\manage-logs.ps1 -Action Export -Root .' -ForegroundColor Yellow
    }
} finally {
    Complete-ZapretLogOperation -ExitCode $(if ($failed) {1} else {0})
    if ($workerLease) { $workerLease.Dispose() }
    if ($ReopenMenu) {
        Start-Process -FilePath 'cmd.exe' -ArgumentList ('/c ""' + (Join-Path $Root 'service.bat') + '""') -WorkingDirectory $Root -WindowStyle Normal
    }
}
if ($failed) { exit 1 }
exit 0
