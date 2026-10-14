[CmdletBinding()]
param(
    [ValidateRange(3, 30)]
    [int]$TimeoutSeconds = 8,

    [switch]$ValidateContract,

    [ValidateSet('success', 'mixed-results', 'full-fail', 'timeout', 'proxy-vpn-blocker', 'legacy-zapret', 'cancel', 'exception-preflight', 'exception-stop', 'exception-scan', 'exception-manual', 'exception-final', 'exception-report')]
    [string]$SimulationScenario,

    [switch]$SelfTest
)

. (Join-Path $PSScriptRoot 'session-log.ps1')
Initialize-ZapretLog -Root ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))) -Component wizard -Action 'Scan'
try {

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

$bundleGate = $null
try {
    . (Join-Path $PSScriptRoot 'bundle-operation.ps1')
    $bundleGate = Enter-ZapretBundleOperation $root
    Invoke-CompatibilityWizard
} catch [OperationCanceledException] { Write-ZapretLogException $_ -Warning;
    Write-Host "Canceled by user: $($_.Exception.Message)" -ForegroundColor Yellow
    Complete-ZapretLogOperation -ExitCode 2; exit 2
} finally { Exit-ZapretBundleOperation $bundleGate }

} catch { Write-ZapretLogException $_; throw }
finally { Complete-ZapretLogOperation }
