[CmdletBinding()]
param([Parameter(Mandatory)][string]$Preset,[string]$SessionId='', [ValidateRange(0,30)][int]$CloseDelaySeconds=4)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'engine-control.ps1')
$exitCode=0; $handoff=$false
Initialize-ZapretLog -Root $root -Component menu -Action Start -SessionId $SessionId -OwnerProcessId $PID
try {
    Write-ZapretLogSettingsSnapshot $root
    if ($Preset -notmatch '^[A-Za-z0-9 _-]+$' -or -not [IO.File]::Exists((Join-Path $root ('presets\'+$Preset+'.txt.in')))) { $exitCode=3; throw "Preset not found: $Preset" }
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    try { $admin=([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
    finally { $identity.Dispose() }
    if (-not $admin) {
        $id=if ($script:ZapretLog) {$script:ZapretLog.Id} else {'disabled'}
        $arguments='/c ""'+(Join-Path $PSScriptRoot 'run-preset.bat')+'" "'+$Preset+'" log_session '+$id+'"'
        $null=Start-Process cmd.exe -ArgumentList $arguments -Verb RunAs -ErrorAction Stop
        $handoff=$true
    } else {
        $safe=$Preset.Replace(' ','_')
        $config=Join-Path $root ('runtime\manual-'+$safe+'.txt')
        $dry=Join-Path $root ('runtime\validate-'+$safe+'.txt')
        $logs=Join-Path $root ('runtime\manual-'+$safe)
        $phase=[Diagnostics.Stopwatch]::StartNew()
        # Hold the reentrant bundle gate through validation and launch. The engine
        # owns its non-reentrant launch lock; do not acquire that lock here.
        . (Join-Path $PSScriptRoot 'bundle-operation.ps1')
        $gate=Enter-ZapretBundleOperation $root
        try {
            $exitCode=4
            $null=Get-ZapretManualLaunchState -Root $root -ReplaceExisting
            $exitCode=5
            & (Join-Path $PSScriptRoot 'render-config.ps1') -Preset $Preset -Output $config -ValidationOutput $dry | Out-Null
            Write-ZapretLogEvent -Stage render -Details @{durationMs=[long]$phase.ElapsedMilliseconds}
            Write-Host "Validating `"$Preset`"..."
            $phase.Restart()
            $exitCode=Invoke-ZapretEngine -Config $dry -LogPrefix ($logs+'-validate') -Validate
            if ($exitCode) { $exitCode=6; throw 'Preset validation failed. The engine output is shown above.' }
            Write-ZapretLogEvent -Stage validate -Details @{durationMs=[long]$phase.ElapsedMilliseconds}
            $phase.Restart()
            $exitCode=Invoke-ZapretEngine -Config $config -LogPrefix $logs -ReplaceExisting
            if ($exitCode) { $exitCode=7; throw 'winws2 failed to start. The engine output is shown above.' }
            Write-ZapretLogEvent -Stage start -Details @{durationMs=[long]$phase.ElapsedMilliseconds}
        } finally { Exit-ZapretBundleOperation $gate }
        # The check competes with neither rendering nor validation.
        if ([IO.File]::Exists((Join-Path $PSScriptRoot 'check_updates.enabled'))) {
            $arguments='-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $PSScriptRoot 'update-release.ps1')+'" -Action Check -Quiet'
            $check=Start-Process powershell.exe -ArgumentList $arguments -WindowStyle Hidden -PassThru
            $check.Dispose()
        }
        Write-Host "[OK] Zapret 2 NEXT started with preset `"$Preset`"."
        Write-Host 'The winws2 process will keep running after this window closes.'
        if (-not [Console]::IsInputRedirected -and $CloseDelaySeconds) {
            Write-Host "Press any key to close now (automatic close in $CloseDelaySeconds seconds)."
            $timer=[Diagnostics.Stopwatch]::StartNew()
            while ($timer.Elapsed.TotalSeconds -lt $CloseDelaySeconds) {
                if ([Console]::KeyAvailable) { $null=[Console]::ReadKey($true); break }
                Start-Sleep -Milliseconds 50
            }
        }
    }
} catch {
    if (-not $exitCode) { $exitCode=1 }
    Write-ZapretLogException $_
    Write-Host ('[ERROR] '+$_.Exception.Message) -ForegroundColor Red
    if (-not [Console]::IsInputRedirected) { Write-Host 'Press any key to continue . . .'; $null=[Console]::ReadKey($true) }
} finally {
    Close-ZapretLogMenu -Handoff:$handoff -OwnerProcessId $PID -ExitCode $exitCode
    Complete-ZapretLogOperation -ExitCode $exitCode
    Save-ZapretSessionSummary $root
}
exit $exitCode
