# Offline tests execute the real orchestrator/exporter with all live service,
# network and engine actions replaced before the first diagnostic invocation.
$ErrorActionPreference = 'Stop'
$bundleRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'compatibility-wizard-core.ps1')
. (Join-Path $PSScriptRoot 'compatibility-wizard-preflight.ps1')
. (Join-Path $PSScriptRoot 'compatibility-wizard-network.ps1')
. (Join-Path $PSScriptRoot 'compatibility-wizard-main.ps1')
. (Join-Path $PSScriptRoot 'support-diagnostics-core.ps1')
$exportImplementation = ${function:Save-SupportArtifacts}
$presetImplementation = ${function:Invoke-SupportPreset}
$environmentImplementation = ${function:Get-SupportEnvironment}
$settingsImplementation = ${function:Read-SupportSettings}
$fixture = Join-Path $bundleRoot ('runtime\support-tests-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $fixture 'runtime') -Force | Out-Null
$root = $fixture
$checks = 0
$canaries = @('198.51.100.77','2001:db8::cafe','AA:BB:CC:DD:EE:FF','991234','PRIVATE_TOKEN_123','C:\Users\private-user\private-path','--secret=private-cookie')
$canary = $canaries -join ' '
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Assert-Support([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function Read-YesNo { param($Prompt, $Default); $script:events.Add('confirm'); return $script:scenario -ne 'cancel' }
function Get-SupportStateHashes {
    $script:stateReads++
    return @{ config = if ($script:scenario -eq 'state-change' -and $script:stateReads -gt 1) { 'changed' } else { 'original' } }
}
function Get-SupportVersions { return @{bundle='0.4.0';engine='1.0.5.2';windows='10.0.26100';architecture='x64';private=$canary} }
function Get-WizardTargets {
    return @(
        [pscustomobject]@{Name='DiscordMain';Product='Discord';Mandatory=$true;Url='https://discord.com/'},
        [pscustomobject]@{Name='YouTubeWeb';Product='YouTube';Mandatory=$true;Url='https://www.youtube.com/'}
    )
}
function Get-SupportEnvironment {
    if ($script:scenario -eq 'preflight-error') { throw $canary }
    return [pscustomobject]@{
        Findings=@([pscustomobject]@{Code='SoftwareProcess-991234';Severity='Info';Message=$canary;Evidence=$canary})
        IPSetEntries=42; Blocked=$script:scenario -in @('foreign','proxy')
        Service=if ($script:scenario -eq 'no-service') { $null } else { [pscustomobject]@{WasRunning=$script:scenario -ne 'stopped-service'} }
        PrivateSnapshot=@{private=$canary}
    }
}
function Stop-SupportService {
    $script:events.Add('stop')
    if ($script:scenario -eq 'stop-error') { throw $canary }
}
function Restore-SupportService {
    $script:events.Add('restore')
    if ($script:scenario -eq 'restore-error') { throw $canary }
}
function Stop-WizardEngine { $script:events.Add('cleanup') }
function Add-TestRows([string]$Preset, [string]$Mode) {
    foreach ($target in $script:targets) {
        $reachable = $script:scenario -notin @('full-fail','timeout')
        if ($script:scenario -eq 'mixed') { $reachable = $Preset -eq 'general' -or $Mode -eq 'any' }
        $script:result.webResults += [pscustomobject]@{
            Phase=if ($Preset) { 'support-scan' } else { 'baseline' }; Preset=$Preset; IPSetMode=$Mode
            Target=$target.Name; Mandatory=$true; Success=$reachable; CurlExitCode=if ($reachable) { 0 } elseif ($script:scenario -eq 'timeout') { 28 } else { 6 }
            HttpCode=if ($reachable) { '200' } else { '000' }; DurationMs=8
            RemoteIP=$canary; LocalIP=$canary; RemotePort=$canary; ProcessId=$canary
            Error=$canary; ConfigPath=$canary; CommandLine=$canary; EffectiveUrl=$canary
        }
    }
}
function Invoke-SupportBaseline { $script:events.Add('baseline'); Add-TestRows '' 'none' }
function Invoke-SupportPreset {
    param($Preset, $IPSetMode)
    $script:events.Add("scan:$Preset/$IPSetMode")
    if ($script:scenario -eq 'scan-cancel') { throw [OperationCanceledException]::new($canary) }
    if ($script:scenario -eq 'scan-error') { throw $canary }
    Add-TestRows $Preset $IPSetMode
}
function Save-SupportArtifacts {
    param($RunDirectory)
    $script:events.Add('export')
    if ($script:scenario -eq 'export-error') { throw $canary }
    & $exportImplementation $RunDirectory
}
function Read-TestZip([string]$Path) {
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $names = @($zip.Entries | ForEach-Object FullName | Sort-Object)
        Assert-Support (($names -join ',') -eq 'REPORT.txt,results.json,web-results.csv') 'Unexpected support ZIP member'
        $text = ''
        foreach ($entry in $zip.Entries) {
            $reader = [IO.StreamReader]::new($entry.Open())
            try { $text += $reader.ReadToEnd() } finally { $reader.Dispose() }
        }
        foreach ($value in $canaries) { Assert-Support (-not $text.Contains($value)) "Private canary leaked: $value" }
    } finally { $zip.Dispose() }
    return Get-Content -LiteralPath (Join-Path ([IO.Path]::ChangeExtension($Path, $null)) 'share\results.json') -Raw | ConvertFrom-Json
}

foreach ($scenarioName in @('success','full-fail','timeout','mixed','foreign','proxy','cancel','scan-cancel','preflight-error','stop-error','scan-error','restore-error','state-change','no-service','stopped-service','busy','export-error')) {
    $script:scenario=$scenarioName; $script:events=[Collections.Generic.List[string]]::new(); $script:stateReads=0
    $busyLock=$null
    if ($scenarioName -eq 'busy') { $busyLock=[IO.File]::Open((Join-Path $root 'runtime\engine-operation.lock'), 'OpenOrCreate','ReadWrite','None') }
    try {
        if ($scenarioName -eq 'export-error') {
            $rejected=$false
            try { Invoke-SupportDiagnostics -Provider 'Test ISP' | Out-Null } catch { $rejected=$true }
            Assert-Support $rejected 'Exporter failure was swallowed'
            Assert-Support ($script:events.IndexOf('restore') -lt $script:events.IndexOf('export')) 'Export failure prevented restoration'
            continue
        }
        $artifact = Invoke-SupportDiagnostics -Provider 'Test ISP' -RegionCity ''
        Assert-Support (Test-Path -LiteralPath $artifact.ZipPath) "$scenarioName did not create an archive"
        $doc = Read-TestZip $artifact.ZipPath
        Assert-Support ($null -eq $doc.versions.PSObject.Properties['private']) 'Unexpected version metadata exported'
        Assert-Support (-not $doc.voiceTested -and -not $doc.videoPlaybackTested -and -not $doc.screenShareTested) 'Automatic scan claimed manual acceptance'
        $scans = @($script:events | Where-Object { $_ -like 'scan:*' })
        if ($scenarioName -in @('success','full-fail','timeout','mixed','no-service','stopped-service')) {
            Assert-Support ($doc.status -eq 'completed') "$scenarioName did not complete"
            $expected = if ($scenarioName -in @('full-fail','timeout')) {22} elseif ($scenarioName -eq 'mixed') {21} else {11}
            Assert-Support ($scans.Count -eq $expected) "$scenarioName skipped presets or fallback"
        }
        if ($scenarioName -in @('foreign','proxy','cancel','preflight-error','busy','no-service','stopped-service')) {
            Assert-Support (-not $script:events.Contains('stop')) "$scenarioName changed a service"
        } else {
            Assert-Support ($script:events.IndexOf('confirm') -lt $script:events.IndexOf('stop')) 'Stopped before confirmation'
            Assert-Support ($script:events.IndexOf('cleanup') -lt $script:events.IndexOf('restore')) 'Restored before engine cleanup'
            Assert-Support ($script:events.IndexOf('restore') -lt $script:events.IndexOf('export')) 'Restoration happened after export'
        }
        if ($scenarioName -eq 'restore-error') {
            Assert-Support (-not $doc.serviceRestored -and $doc.issues -contains 'ServiceRestoreFailed' -and $artifact.ExitCode -eq 1) 'Restore failure not reported'
        }
        if ($scenarioName -eq 'state-change') { Assert-Support (-not $doc.statePreserved -and $doc.issues -contains 'StateChanged') 'State change not detected' }
        if ($scenarioName -eq 'timeout') { Assert-Support (@($doc.webResults | Where-Object errorCode -eq 'Timeout').Count -gt 0) 'Timeout classification lost' }
        if ($scenarioName -in @('cancel','scan-cancel')) { Assert-Support ($doc.status -eq 'canceled' -and $artifact.ExitCode -eq 2) 'Cancellation not reported' }
        Write-Host "[OK] support $scenarioName"
    } finally { if ($busyLock) { $busyLock.Dispose() } }
    $probeLock=[IO.File]::Open((Join-Path $root 'runtime\engine-operation.lock'), 'OpenOrCreate','ReadWrite','None')
    $probeLock.Dispose()
}

# Exercise the real per-preset error path (not a parallel simulation of it).
$script:scenario='broken-preset'
function Invoke-WebPass { throw $canary }
$script:result.webResults=@()
& $presetImplementation 'general' 'loaded'
Assert-Support ($script:result.webResults.Count -eq 2 -and $script:result.webResults[0].CurlExitCode -eq -1) 'Broken preset lost result rows'
Assert-Support ($script:support.issues -contains 'EngineStartFailed') 'Broken preset not classified'

# Exercise real foreign-service and PktMon policy independently of Windows SCM.
$script:skipVoiceObserved=$false
function Get-PreflightSnapshot {
    param([switch]$SkipVoiceChecks)
    $script:skipVoiceObserved=[bool]$SkipVoiceChecks
    return [pscustomobject]@{Findings=@();ConflictState=[pscustomobject]@{Services=@();ManualProcesses=@()}}
}
function Test-SupportComponentHashes { return $true }
function Get-ZapretServiceSnapshot { return [pscustomobject]@{PathName='foreign-folder';WasRunning=$true} }
function Assert-ZapretNoManualEngine {}
$environment = & $environmentImplementation
Assert-Support ($environment.Blocked -and $script:skipVoiceObserved) 'Foreign service or PktMon policy regressed'

Write-Host "Support diagnostics validation passed: $checks checks." -ForegroundColor Green
