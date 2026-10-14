[CmdletBinding()]
param(
    [ValidateSet('Start','Finish','Event','Export')][string]$Action='Export',
    [string]$Root='',
    [string]$SessionId='',
    [int]$Selection=255,
    [int]$ExitCode=0,
    [switch]$Handoff,
    [switch]$NoReveal,
    [switch]$MenuBootstrap,
    [switch]$SkipTelegramStatus
)
$ErrorActionPreference='Stop'
if (-not $Root) { $Root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')) }
. (Join-Path $PSScriptRoot 'session-log.ps1')
$ownerId=0
try {
    $parent=Get-CimInstance Win32_Process -Filter "ProcessId=$PID"
    $ownerId=[int]$parent.ParentProcessId
    if ($Action -eq 'Start') {
        $shell=Get-CimInstance Win32_Process -Filter ("ProcessId="+$ownerId)
        $outer=Get-CimInstance Win32_Process -Filter ("ProcessId="+$shell.ParentProcessId)
        # FOR /F creates a short-lived cmd /c around PowerShell.
        if ($shell.Name -eq 'cmd.exe' -and $outer.Name -eq 'cmd.exe') { $ownerId=[int]$outer.ProcessId }
    }
} catch {}
Initialize-ZapretLog -Root $Root -Component menu -Action $(if ($Action -eq 'Event') {'Select'} else {$Action}) -SessionId $SessionId -OwnerProcessId $ownerId
if ($Action -eq 'Start') {
    Write-ZapretLogSettingsSnapshot $Root
    $id=if ($script:ZapretLog -and $env:ZAPRET_LOG_DISABLED -ne '1') {$script:ZapretLog.Id} else {'disabled'}
    if ($MenuBootstrap) {
        Write-Output ('SESSION='+$id)
        if (-not $SkipTelegramStatus) {
            $status='ERROR'
            try {
                . (Join-Path $PSScriptRoot 'telegram-control.ps1')
                $status=Get-ZapretTelegramStatus $Root -Compact -Fast
            } catch { Write-ZapretLogException $_ -Warning }
            Write-Output ('TELEGRAM='+$status)
        }
    } else { Write-Output $id }
    exit 0
}
try {
    switch ($Action) {
        'Finish' { Close-ZapretLogMenu -Handoff:$Handoff -OwnerProcessId $ownerId -ExitCode $ExitCode }
        'Event' { Write-ZapretLogEvent -Action Select -Stage selection -Details @{selection=$Selection} }
        'Export' {
            $zip=Export-ZapretSessionLogs -Root $Root -Archive
            Write-Host "Logs archive / Архив логов: $zip" -ForegroundColor Cyan
            Write-Host 'Attach this ZIP to your GitHub Issue or Discord message. It is not sent automatically.'
            if (-not $NoReveal) { Start-Process explorer.exe -ArgumentList ('/select,"'+$zip+'"') | Out-Null }
        }
    }
} catch { $ExitCode=1; Write-ZapretLogException $_; Write-Host 'Could not create the logs archive. Check runtime/logs access and free space.' -ForegroundColor Red; exit 1 }
finally { Complete-ZapretLogOperation -ExitCode $ExitCode; Save-ZapretSessionSummary $Root }
