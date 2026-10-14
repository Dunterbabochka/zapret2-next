param(
    [Parameter(Mandatory = $true)]
    [string]$Config,

    [Parameter(Mandatory = $true)]
    [string]$LogPrefix,

    [switch]$Validate,

    [switch]$ReplaceExisting,

    [ValidateRange(1, 120)]
    [int]$ValidationTimeoutSeconds = 30,

    [ValidateRange(1, 30)]
    [int]$StartupWaitSeconds = 3
)

. (Join-Path $PSScriptRoot 'engine-control.ps1')
exit (Invoke-ZapretEngine @PSBoundParameters)
