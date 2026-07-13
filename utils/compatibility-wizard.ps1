[CmdletBinding()]
param(
    [ValidateRange(3, 30)]
    [int]$TimeoutSeconds = 8,

    [switch]$ValidateContract
)

$coreParameters = @{ TimeoutSeconds = $TimeoutSeconds; ValidateContract = $ValidateContract }
. (Join-Path $PSScriptRoot 'compatibility-wizard-core.ps1') @coreParameters
. (Join-Path $PSScriptRoot 'compatibility-wizard-preflight.ps1')
. (Join-Path $PSScriptRoot 'compatibility-wizard-network.ps1')
. (Join-Path $PSScriptRoot 'compatibility-wizard-main.ps1')

if ($ValidateContract) {
    Invoke-WizardContractValidation
    return
}

Invoke-CompatibilityWizard
