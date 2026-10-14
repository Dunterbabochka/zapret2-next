param([string]$Root, [string]$Source, [string]$Point)
$ErrorActionPreference='Stop'
. (Join-Path $Source 'utils\update-release-core.ps1')
. (Join-Path $Source 'utils\update-release-state.ps1')
# Every boundary is local to this disposable subprocess. There are no live
# SCM, scheduled-task, network or engine-start calls in a crash test.
function Get-ReleaseWindowsState($Root) { (Read-ReleaseTransaction $Root).Windows }
function Stop-ReleaseWindowsState($Snapshot) {}
function Start-ReleaseWindowsState($Root,$Snapshot) {}
function Stop-ReleaseInstalledProcesses($Root,$Snapshot) {}
function Test-ReleaseConfig($Root,$Config,$Output,[switch]$DryRun) {
    $options=@{}
    foreach ($property in $Config.Options.PSObject.Properties) { $options[$property.Name]=$property.Value }
    & (Join-Path $Root 'utils\render-config.ps1') @options -Output $Output -DryRun:$DryRun | Out-Null
}
function Invoke-ReleaseCheckpoint([string]$Name) {
    if ($Name -ceq $Point) { [Environment]::Exit(91) }
}
$transaction=Read-ReleaseTransaction $Root
Initialize-ZapretLog -Root $Root -Component update -Action Apply -SessionId $transaction.LogSessionId
$null=Invoke-ReleaseApply $Root
throw 'The crash checkpoint was not reached.'
