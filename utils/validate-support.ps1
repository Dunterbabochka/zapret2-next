# Offline tests execute the real orchestrator/exporter with all live service,
# network and engine actions replaced before the first diagnostic invocation.
$ErrorActionPreference = 'Stop'
$bundleRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'compatibility-wizard-core.ps1')
. (Join-Path $PSScriptRoot 'compatibility-wizard-preflight.ps1')
. (Join-Path $PSScriptRoot 'compatibility-wizard-network.ps1')
. (Join-Path $PSScriptRoot 'compatibility-wizard-main.ps1')
. (Join-Path $PSScriptRoot 'support-diagnostics-core.ps1')
$logExportImplementation=${function:Export-ZapretSessionLogs}
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
    $findings = switch ($script:scenario) {
        'proxy' { @(New-PreflightFinding 'WinINETProxy' 'Blocker' 'Proxy' $canary $canary) }
        'foreign' { @(New-PreflightFinding 'ForeignZapret' 'Blocker' 'ZapretState' $canary $canary) }
        'stale-service' { @(New-PreflightFinding 'ServiceConfiguration' 'Blocker' 'ZapretState' $canary $canary) }
        'warnings' { @(New-PreflightFinding 'SoftwareProcess-991234' 'Warning' 'ConflictingSoftware' ('Potentially conflicting process: tailscaled.exe ' + $canary) $canary) }
        default { @([pscustomobject]@{Code='SoftwareProcess-991234';Severity='Info';Message=$canary;Evidence=$canary}) }
    }
    return [pscustomobject]@{
        Findings=@($findings)
        IPSetEntries=42; Blocked=$script:scenario -in @('foreign','proxy','stale-service')
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
function Export-ZapretSessionLogs {
    param($Root,$Directory)
    if ($script:scenario -eq 'log-export-error') { throw 'Injected logs export failure' }
    & $logExportImplementation -Root $Root -Directory $Directory
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
        Assert-Support (($names -join ',') -eq $(if ($script:scenario -eq 'log-export-error') {'REPORT.txt,results.json,web-results.csv'} else {'logs/events.jsonl,logs/LOGS.txt,logs/manifest.json,REPORT.txt,results.json,web-results.csv'})) 'Unexpected support ZIP member'
        $text = ''
        foreach ($entry in $zip.Entries) {
            $reader = [IO.StreamReader]::new($entry.Open())
            try { $text += $reader.ReadToEnd() } finally { $reader.Dispose() }
        }
        foreach ($value in $canaries) { Assert-Support (-not $text.Contains($value)) "Private canary leaked: $value" }
    } finally { $zip.Dispose() }
    return Get-Content -LiteralPath (Join-Path ([IO.Path]::ChangeExtension($Path, $null)) 'share\results.json') -Raw -Encoding UTF8 | ConvertFrom-Json
}

foreach ($scenarioName in @('success','full-fail','timeout','mixed','warnings','foreign','proxy','stale-service','cancel','scan-cancel','preflight-error','stop-error','scan-error','restore-error','state-change','no-service','stopped-service','busy','export-error','log-export-error')) {
    Initialize-ZapretLog -Root $root -Component support -Action Scan
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
        if ($scenarioName -in @('success','full-fail','timeout','mixed','warnings','no-service','stopped-service')) {
            Assert-Support ($doc.status -eq 'completed') "$scenarioName did not complete"
            $expected = if ($scenarioName -in @('full-fail','timeout')) {22} elseif ($scenarioName -eq 'mixed') {21} else {11}
            Assert-Support ($scans.Count -eq $expected) "$scenarioName skipped presets or fallback"
        }
        if ($scenarioName -in @('foreign','proxy','stale-service','cancel','preflight-error','busy','no-service','stopped-service')) {
            Assert-Support (-not $script:events.Contains('stop')) "$scenarioName changed a service"
        } else {
            Assert-Support ($script:events.IndexOf('confirm') -lt $script:events.IndexOf('stop')) 'Stopped before confirmation'
            Assert-Support ($script:events.IndexOf('cleanup') -lt $script:events.IndexOf('restore')) 'Restored before engine cleanup'
            Assert-Support ($script:events.IndexOf('restore') -lt $script:events.IndexOf('export')) 'Restoration happened after export'
        }
        if ($scenarioName -eq 'restore-error') {
            Assert-Support (-not $doc.serviceRestored -and $doc.issues -contains 'ServiceRestoreFailed' -and $artifact.ExitCode -eq 1) 'Restore failure not reported'
            Assert-Support (Test-Path -LiteralPath (Join-Path $artifact.Directory 'local\service-restore-local.txt')) 'Restore error lost its local explanation'
        }
        if ($scenarioName -eq 'state-change') { Assert-Support (-not $doc.statePreserved -and $doc.issues -contains 'StateChanged') 'State change not detected' }
        $reportText = Get-Content -LiteralPath (Join-Path $artifact.Directory 'share\REPORT.txt') -Raw -Encoding UTF8
        if ($scenarioName -in @('foreign','proxy','stale-service')) {
            Assert-Support ($doc.status -eq 'blocked' -and $artifact.ExitCode -eq 3 -and $doc.issues -contains 'EnvironmentBlocked') 'Environment blocker not classified'
            Assert-Support ($scans.Count -eq 0 -and $doc.webResults.Count -eq 0) 'Blocked run performed network probes'
            Assert-Support ($reportText.Contains('Сетевые проверки не выполнялись') -and -not $reportText.Contains('Проверена DNS/TLS/HTTP')) 'Blocked report claimed a network test'
        }
        if ($scenarioName -eq 'proxy') {
            Assert-Support ($doc.checks[0].message.Contains('системный прокси') -and $doc.checks[0].action.Contains('Параметры')) 'Proxy reason or corrective action missing from shared results'
            Assert-Support ($reportText.Contains('Сеть и Интернет')) 'Proxy corrective action missing from text report'
        }
        if ($scenarioName -eq 'warnings') {
            Assert-Support ($reportText.Contains('Tailscale') -and $reportText.Contains('Проверена DNS/TLS/HTTP')) 'Warning-only run lost its explanation or results'
        }
        if ($scenarioName -eq 'stale-service') { Assert-Support ($reportText.Contains('Install Service')) 'Stale service config has no recovery instruction' }
        if ($scenarioName -eq 'full-fail') {
            Assert-Support ($doc.issues -contains 'DNSResolutionFailed' -and $artifact.Issues -contains 'DNSResolutionFailed') 'DNS failures not surfaced to the report and console'
            Assert-Support ($reportText.Contains('ошибка DNS') -and $reportText.Contains('браузере')) 'DNS report confused failed resolution with browser availability'
        }
        if ($doc.webResults.Count) {
            $localText = Get-Content -LiteralPath (Join-Path $artifact.Directory 'local\results-local.json') -Raw -Encoding UTF8
            Assert-Support ($localText.Contains('PRIVATE_TOKEN_123')) 'Detailed curl evidence was not preserved outside the ZIP'
        }
        if ($scenarioName -eq 'timeout') { Assert-Support (@($doc.webResults | Where-Object errorCode -eq 'Timeout').Count -gt 0) 'Timeout classification lost' }
        if ($scenarioName -in @('cancel','scan-cancel')) { Assert-Support ($doc.status -eq 'canceled' -and $artifact.ExitCode -eq 2) 'Cancellation not reported' }
        Write-Host "[OK] support $scenarioName"
    } finally { if ($busyLock) { $busyLock.Dispose() }
        Complete-ZapretLogOperation }
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

# Regression: potential software presence is different from active filtering.
# These fixtures reproduce the reported Tailscale/Proxifier environment without
# storing the user's proxy address, process IDs, command lines or local paths.
function Get-ZapretServiceSnapshot { return $null }
function Get-PreflightSnapshot {
    param([switch]$SkipVoiceChecks)
    return [pscustomobject]@{Findings=@($script:policyFindings);ConflictState=[pscustomobject]@{Services=@();ManualProcesses=@()}}
}
foreach ($case in @(
    @{name='tailscale-idle';blocked=$false;findings=@(
        (New-PreflightFinding 'SoftwareProcess-991234' 'Warning' 'ConflictingSoftware' ('Potentially conflicting process: tailscaled.exe ' + $canary) $canary $true),
        (New-PreflightFinding 'SoftwareService-Tailscale' 'Warning' 'ConflictingSoftware' ('Potentially conflicting service: Tailscale ' + $canary) $canary $true),
        (New-PreflightFinding 'Adapter-991234' 'Warning' 'Network' ('Tailscale [Overlay] default-route=False ' + $canary) $canary $true))},
    @{name='proxifier-present';blocked=$false;findings=@(New-PreflightFinding 'SoftwareProcess-991234' 'Warning' 'ConflictingSoftware' ('Potentially conflicting process: Proxifier.exe ' + $canary) $canary $true)},
    @{name='enumeration-warning';blocked=$false;findings=@(New-PreflightFinding 'SoftwareProcesses' 'Warning' 'ConflictingSoftware' $canary $canary $true)},
    @{name='system-proxy';blocked=$true;findings=@(New-PreflightFinding 'WinINETProxy' 'Blocker' 'Proxy' $canary $canary)},
    @{name='active-overlay';blocked=$true;findings=@(New-PreflightFinding 'Adapter-991234' 'Warning' 'Network' ('Tailscale [Overlay] default-route=True ' + $canary) $canary $true)},
    @{name='active-vpn';blocked=$true;findings=@(New-PreflightFinding 'Adapter-991234' 'Warning' 'Network' ('VPN [VpnCandidate] default-route=True ' + $canary) $canary $true)},
    @{name='dpi-process';blocked=$true;findings=@(New-PreflightFinding 'SoftwareProcess-991234' 'Blocker' 'ConflictingSoftware' ('Potentially conflicting process: goodbyedpi.exe ' + $canary) $canary)},
    @{name='dpi-service';blocked=$true;findings=@(New-PreflightFinding 'SoftwareService-GoodbyeDPI' 'Warning' 'ConflictingSoftware' $canary $canary $true)}
)) {
    $script:policyFindings=$case.findings
    $severitiesBefore=@($script:policyFindings | ForEach-Object Severity) -join ','
    $environment = & $environmentImplementation
    Assert-Support ($environment.Blocked -eq $case.blocked) ("Incorrect conflict policy: " + $case.name)
    Assert-Support ((@($script:policyFindings | ForEach-Object Severity) -join ',') -eq $severitiesBefore) 'Support policy mutated the shared Wizard snapshot'
    $console = Show-SupportFindings $environment.Findings 6>&1 | Out-String
    foreach ($value in $canaries) { Assert-Support (-not $console.Contains($value)) 'Local evidence leaked through console explanations' }
    if ($case.name -eq 'system-proxy') {
        Assert-Support ($console.Contains('системный прокси') -and $console.Contains('Параметры')) 'Console did not show proxy reason and correction'
    }
    Write-Host ('[OK] environment ' + $case.name)
}
# The same proxy check must describe a disabled proxy correctly.
$passingProxy = ConvertTo-SupportFinding (New-PreflightFinding 'WinINETProxy' 'Pass' 'Proxy' $canary)
Assert-Support ($passingProxy.message.Contains('выключен') -and -not $passingProxy.action) 'Passing proxy check claims an active proxy'

# A service installed before the folder reorganization can still be running
# with cached filters. Do not stop it if its on-disk config cannot be reloaded.
$savedConfig = Join-Path $root 'runtime\service.txt'
Assert-Support (-not (Test-SupportServiceConfiguration)) 'Missing service config accepted'
[IO.File]::WriteAllText($savedConfig, '', [Text.Encoding]::ASCII)
Assert-Support (-not (Test-SupportServiceConfiguration)) 'Empty service config accepted'
[IO.File]::WriteAllText($savedConfig, '# no file references', [Text.Encoding]::ASCII)
Assert-Support (-not (Test-SupportServiceConfiguration)) 'Config without references accepted'
$fixtureBin = Join-Path $root 'bin'
New-Item -ItemType Directory -Path $fixtureBin -Force | Out-Null
$referencedFile = Join-Path $root 'runtime\filter with spaces.txt'
[IO.File]::WriteAllText($referencedFile, 'filter', [Text.Encoding]::ASCII)
$baseLine = '--chdir="' + $fixtureBin + '"' + "`r`n"
[IO.File]::WriteAllText($savedConfig, $baseLine + '--wf-raw-part=@"' + $referencedFile + '"' + "`r`n" + '--hostlist="' + $referencedFile + '"', [Text.Encoding]::ASCII)
Assert-Support (Test-SupportServiceConfiguration) 'Existing quoted references rejected'
[IO.File]::WriteAllText($savedConfig, $baseLine + '--wf-raw-part=@"../runtime/filter with spaces.txt"', [Text.Encoding]::ASCII)
Assert-Support (Test-SupportServiceConfiguration) 'Relative reference from chdir rejected'
[IO.File]::WriteAllText($savedConfig, '--chdir="missing-dir"' + "`r`n" + '--wf-raw-part=@"' + $referencedFile + '"', [Text.Encoding]::ASCII)
Assert-Support (-not (Test-SupportServiceConfiguration)) 'Missing working directory accepted'
[IO.File]::WriteAllText($savedConfig, $baseLine + '--wf-raw-part=@"../windivert.filter/moved-filter.txt"', [Text.Encoding]::ASCII)
Assert-Support (-not (Test-SupportServiceConfiguration)) 'Moved filter reference accepted'
$script:policyFindings=@()
function Get-ZapretServiceSnapshot { return [pscustomobject]@{PathName=('"' + (Join-Path $root 'bin\winws2.exe') + '" @"' + $savedConfig + '"');WasRunning=$true} }
$environment = & $environmentImplementation
Assert-Support ($environment.Blocked -and @($environment.Findings | Where-Object { $_.Code -eq 'ServiceConfiguration' -and $_.Severity -eq 'Blocker' }).Count -eq 1) 'Running service with stale references was allowed to stop'
[IO.File]::WriteAllText($savedConfig, $baseLine + '--wf-raw-part=@"' + $referencedFile + '"', [Text.Encoding]::ASCII)
$environment = & $environmentImplementation
Assert-Support (-not $environment.Blocked) 'Valid own service config incorrectly blocked the scan'

Write-Host "Support diagnostics validation passed: $checks checks." -ForegroundColor Green
