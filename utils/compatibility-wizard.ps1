[CmdletBinding()]
param(
    [ValidateRange(3, 30)]
    [int]$TimeoutSeconds = 8,

    [switch]$ValidateContract,

    [ValidateSet('success', 'mixed-results', 'full-fail', 'timeout', 'proxy-vpn-blocker', 'legacy-zapret', 'cancel', 'exception-preflight', 'exception-stop', 'exception-scan', 'exception-manual', 'exception-final', 'exception-report')]
    [string]$SimulationScenario,

    [switch]$SelfTest
)

$coreParameters = @{ TimeoutSeconds = $TimeoutSeconds; ValidateContract = $ValidateContract }
. (Join-Path $PSScriptRoot 'compatibility-wizard-core.ps1') @coreParameters
. (Join-Path $PSScriptRoot 'compatibility-wizard-preflight.ps1')
. (Join-Path $PSScriptRoot 'compatibility-wizard-network.ps1')
. (Join-Path $PSScriptRoot 'compatibility-wizard-main.ps1')
. (Join-Path $PSScriptRoot 'compatibility-wizard-simulation.ps1')

if ($ValidateContract) {
    Invoke-WizardContractValidation
    return
}

if ($SelfTest) {
    Invoke-WizardSimulationSelfTest
    return
}

if ($SimulationScenario) {
    Invoke-WizardSimulation -Scenario $SimulationScenario
    return
}

Invoke-CompatibilityWizard
