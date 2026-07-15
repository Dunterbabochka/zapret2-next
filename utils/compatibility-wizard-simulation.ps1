function New-SimulationWebRows {
    param([string]$Scenario)

    $rows = @()
    $presets = @('general', 'ALT', 'ALT3', 'ALT5', 'ALT11', 'FAKE TLS AUTO ALT2')
    foreach ($preset in $presets) {
        foreach ($target in @('Discord gateway', 'Discord web', 'YouTube watch', 'YouTube image')) {
            $success = $preset -eq 'ALT3'
            if ($Scenario -eq 'mixed-results' -and $preset -eq 'general' -and $target -eq 'Discord gateway') { $success = $true }
            if ($Scenario -in @('full-fail', 'timeout')) { $success = $false }
            $rows += [pscustomobject]@{
                TimestampUtc = [DateTime]::UtcNow.ToString('o'); Phase = 'simulation-scan'; Preset = $preset; Pass = 1
                IPSetMode = 'any'; VoiceMode = 'off'; Target = $target; Product = if ($target -match '^Discord') { 'Discord' } else { 'YouTube' }
                Mandatory = $true; Url = 'https://simulation.invalid/'; Success = $success; CurlExitCode = if ($success) { 0 } elseif ($Scenario -eq 'timeout') { 28 } else { 6 }
                HttpCode = if ($success) { '204' } else { '000' }; DurationMs = if ($Scenario -eq 'timeout') { 8000 } else { 25 }; RemoteIP = ''; RemotePort = ''; EffectiveUrl = ''
                ProcessName = 'simulation'; ProcessId = 0; Error = if ($success) { '' } elseif ($Scenario -eq 'timeout') { 'simulated timeout' } else { 'simulated connection failure' }
            }
        }
    }
    return $rows
}

function Save-SimulationArtifacts {
    param([string]$Scenario, [object]$Document)

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $directory = Join-Path $root "runtime\wizard-simulation\$Scenario-$stamp"
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    Write-Utf8File (Join-Path $directory 'results.json') (($Document | ConvertTo-Json -Depth 12) + "`r`n")
    @($Document.webResults) | Export-Csv -LiteralPath (Join-Path $directory 'web-results.csv') -NoTypeInformation -Encoding UTF8
    $report = @(
        'Zapret 2 NEXT - Compatibility Wizard simulation report',
        "Scenario: $Scenario",
        "Status: $($Document.status)",
        'Simulation is local only: it did not stop a service, a process, WinDivert, or PktMon.',
        "Saved mode/IPSet state preserved: $($Document.userStatePreserved)",
        "Events: $($Document.simulation.events -join ' -> ')"
    ) -join "`r`n"
    Write-Utf8File (Join-Path $directory 'REPORT.txt') ($report + "`r`n")
    $zipPath = "$directory.zip"
    Compress-Archive -Path (Join-Path $directory '*') -DestinationPath $zipPath -CompressionLevel Optimal
    return [pscustomobject]@{ Directory = $directory; ZipPath = $zipPath; Document = $Document }
}

function Invoke-WizardSimulation {
    param(
        [ValidateSet('success', 'mixed-results', 'full-fail', 'timeout', 'proxy-vpn-blocker', 'legacy-zapret', 'cancel', 'exception-preflight', 'exception-stop', 'exception-scan', 'exception-manual', 'exception-final', 'exception-report')]
        [string]$Scenario
    )

    $before = @{}
    foreach ($entry in (Get-UserStateHashes).GetEnumerator()) { $before[$entry.Key] = $entry.Value }
    $tester = @{ TesterId = 'simulation'; Provider = 'simulation'; RegionCity = ''; ConnectionType = 'simulation' }
    $system = [pscustomobject]@{ Caption = 'Simulation'; Version = '0'; BuildNumber = '0'; OSArchitecture = 'n/a' }
    $document = New-ResultDocument -Tester $tester -SystemInfo $system -StateBefore $before
    $document.simulation = [ordered]@{ scenario = $Scenario; localOnly = $true; events = @('Started', 'PreflightStarted'); stoppedServices = 0; stoppedProcesses = 0 }
    $document.webResults = @()
    $document.userStateAfter = $before
    $document.userStatePreserved = $true
    $document.finishedAtUtc = [DateTime]::UtcNow.ToString('o')

    if ($Scenario -in @('proxy-vpn-blocker', 'legacy-zapret')) {
        $code = if ($Scenario -eq 'proxy-vpn-blocker') { 'ProxyOrVpn' } else { 'LegacyZapret' }
        $document.preflight = @([pscustomobject]@{ Attempt = 1; Code = $code; Severity = 'Blocker'; Category = 'Simulation'; Message = "Simulated $Scenario blocker."; Action = 'Resolve manually.'; NeedsDecision = $false; Decision = ''; Evidence = 'simulation' })
        $document.status = 'blocked-preflight'
        $document.simulation.events += 'PreflightBlocked'
    } elseif ($Scenario -eq 'cancel') {
        $document.status = 'canceled'
        $document.errors += 'Simulated cancellation before explicit confirmation.'
        $document.simulation.events += @('PreflightCompleted', 'CanceledBeforeConfirmation')
    } elseif ($Scenario -eq 'exception-preflight') {
        $document.status = 'failed'
        $document.errors += 'Simulated exception at preflight.'
        $document.simulation.events += 'ExceptionPreflight'
    } else {
        $document.simulation.events += @('PreflightCompleted', 'UserConfirmed')
        if ($Scenario -eq 'exception-stop') {
            $document.status = 'failed'; $document.errors += 'Simulated exception while stopping recorded state.'; $document.simulation.events += 'ExceptionStop'
        } else {
            $document.simulation.events += 'WouldStopRecordedZapretState'
            if ($Scenario -eq 'exception-scan') {
                $document.status = 'failed'; $document.errors += 'Simulated exception during automatic web scan.'; $document.simulation.events += 'ExceptionScan'
            } else {
                $document.webResults = @(New-SimulationWebRows $Scenario)
                $document.ranking = @(Get-PresetRanking $document.webResults)
                if ($Scenario -eq 'exception-manual') {
                    $document.status = 'failed'; $document.errors += 'Simulated exception during manual confirmation.'; $document.simulation.events += 'ExceptionManual'
                } elseif ($Scenario -eq 'exception-final') {
                    $document.status = 'failed'; $document.errors += 'Simulated exception during final recheck.'; $document.simulation.events += 'ExceptionFinal'
                } elseif ($Scenario -eq 'exception-report') {
                    $document.status = 'failed'; $document.errors += 'Simulated exception before report finalization.'; $document.simulation.events += 'ExceptionReport'
                } elseif ($Scenario -in @('full-fail', 'timeout')) {
                    $document.status = 'completed-unconfirmed'; $document.errors += "Simulation finished with $Scenario results."; $document.simulation.events += 'CompletedUnconfirmed'
                } else {
                    $document.status = if ($Scenario -eq 'success') { 'completed-confirmed' } else { 'completed-unconfirmed' }
                    $document.simulation.events += 'Completed'
                }
            }
        }
    }
    $artifact = Save-SimulationArtifacts -Scenario $Scenario -Document $document
    Write-Host "Simulation ${Scenario}: $($document.status)" -ForegroundColor Green
    Write-Host "Simulation report ZIP: $($artifact.ZipPath)" -ForegroundColor Cyan
    return $artifact
}

function Invoke-WizardSimulationSelfTest {
    $scenarios = @('success', 'mixed-results', 'full-fail', 'timeout', 'proxy-vpn-blocker', 'legacy-zapret', 'cancel', 'exception-preflight', 'exception-stop', 'exception-scan', 'exception-manual', 'exception-final', 'exception-report')
    $stateBefore = Get-UserStateHashes
    $failures = [Collections.Generic.List[string]]::new()
    foreach ($scenario in $scenarios) {
        $artifact = Invoke-WizardSimulation -Scenario $scenario
        $doc = $artifact.Document
        if (-not (Test-Path -LiteralPath $artifact.ZipPath -PathType Leaf)) { $failures.Add("$scenario did not create a result ZIP.") }
        if ($doc.simulation.stoppedServices -ne 0 -or $doc.simulation.stoppedProcesses -ne 0) { $failures.Add("$scenario simulated an unsafe state change.") }
        $events = @($doc.simulation.events)
        $stopIndex = [array]::IndexOf($events, 'WouldStopRecordedZapretState')
        if ($stopIndex -ge 0 -and ($events[0..($stopIndex - 1)] -notcontains 'UserConfirmed')) { $failures.Add("$scenario reached state stop before confirmation.") }
    }
    $stateAfter = Get-UserStateHashes
    foreach ($key in $stateBefore.Keys) { if ($stateBefore[$key] -ne $stateAfter[$key]) { $failures.Add("Self-test changed user state: $key") } }
    if ($failures.Count) { throw "Wizard simulation self-test failed: $($failures -join ' | ')" }
    Write-Host "Wizard simulation self-test passed: $($scenarios.Count) scenarios; no live state changes." -ForegroundColor Green
}
