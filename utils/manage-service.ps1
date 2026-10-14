param(
    [Parameter(Mandatory)]
    [ValidateSet('Install', 'Refresh', 'Remove')]
    [string]$Action,
    [ValidatePattern('^[A-Za-z0-9 _-]+$')]
    [string]$Preset,
    [ValidateSet('loaded', 'none')]
    [string]$IPSetMode = 'loaded',
    [switch]$Restart
)

. (Join-Path $PSScriptRoot 'session-log.ps1')
Initialize-ZapretLog -Root ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))) -Component service -Action $Action
try {
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ipset-utils.ps1')
. (Join-Path $PSScriptRoot 'service-control.ps1')
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
try {
    if ($Action -eq 'Remove') {
        Remove-ZapretServiceConfiguration -Root $root
    } else {
        if ([string]::IsNullOrWhiteSpace($Preset)) { throw 'Preset is required for installation and refresh.' }
        Set-ZapretServiceConfiguration -Root $root -Preset $Preset -IPSetMode $IPSetMode -Install:($Action -eq 'Install') -Restart:$Restart
    }
} catch { Write-ZapretLogException $_ -Warning;
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    Complete-ZapretLogOperation -ExitCode 1; exit 1
}
Complete-ZapretLogOperation -ExitCode 0; exit 0

} catch { Write-ZapretLogException $_; throw }
finally { Complete-ZapretLogOperation }
