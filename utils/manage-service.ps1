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
} catch {
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
exit 0
