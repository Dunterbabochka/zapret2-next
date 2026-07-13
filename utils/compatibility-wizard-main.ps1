function Save-ResultArtifacts {
    if (-not $script:resultDir -or -not (Test-Path -LiteralPath $script:resultDir -PathType Container)) { return }

    Get-ChildItem -LiteralPath $script:resultDir -Recurse -Filter '*.etl' -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue

    $webCsv = Join-Path $script:resultDir 'web-results.csv'
    if (@($script:result.webResults).Count) {
        @($script:result.webResults) | Export-Csv -LiteralPath $webCsv -NoTypeInformation -Encoding UTF8
    } else {
        $header = '"TimestampUtc","Phase","Preset","Pass","IPSetMode","VoiceMode","Target","Product","Mandatory","Success","CurlExitCode","HttpCode","DurationMs","RemoteIP","RemotePort","ProcessId","Error"' + "`r`n"
        Write-Utf8File $webCsv $header
    }
    if (@($script:result.preflight).Count) {
        @($script:result.preflight) | Export-Csv -LiteralPath (Join-Path $script:resultDir 'preflight.csv') -NoTypeInformation -Encoding UTF8
    }
    if (@($script:result.networkObservations).Count) {
        @($script:result.networkObservations) | Export-Csv -LiteralPath (Join-Path $script:resultDir 'network-observations.csv') -NoTypeInformation -Encoding UTF8
    }

    Write-Utf8File (Join-Path $script:resultDir 'results.json') (($script:result | ConvertTo-Json -Depth 12) + "`r`n")
    Write-Utf8File (Join-Path $script:resultDir 'REPORT.txt') (New-TextReport)
    if (Test-Path -LiteralPath $script:zipPath -PathType Leaf) { Remove-Item -LiteralPath $script:zipPath -Force }
    Compress-Archive -Path (Join-Path $script:resultDir '*') -DestinationPath $script:zipPath -CompressionLevel Optimal
}

function Invoke-WizardContractValidation {
    $errors = [Collections.Generic.List[string]]::new()
    try { $targets = @(Get-WizardTargets) } catch { $errors.Add($_.Exception.Message); $targets = @() }

    if ($publicPresets.Count -ne 6 -or @($publicPresets | Sort-Object -Unique).Count -ne 6) {
        $errors.Add('The wizard must expose exactly six unique public presets.')
    }
    foreach ($preset in $publicPresets) {
        if (-not (Test-Path -LiteralPath (Join-Path $root "presets\$preset.txt.in") -PathType Leaf)) {
            $errors.Add("Missing public preset template: $preset")
        }
    }
    if ($targets.Count -lt 6) { $errors.Add('At least six local HTTPS endpoint definitions are required.') }
    if (@($targets | Select-Object -ExpandProperty Name -Unique).Count -ne $targets.Count) { $errors.Add('Endpoint names must be unique.') }
    foreach ($target in $targets) {
        if (-not $target.Name -or -not $target.Product -or $target.Url -notmatch '^https://[^\s\"]+$') {
            $errors.Add("Invalid endpoint definition: $($target.Name)")
        }
        if ($target.Url -match '^(?i:PING:)' -or $target.Name -match '(?i)ping') {
            $errors.Add('ICMP ping targets must not be part of wizard ranking.')
        }
    }
    foreach ($product in @('Discord', 'YouTube')) {
        if (@($targets | Where-Object { $_.Mandatory -and $_.Product -eq $product }).Count -lt 2) {
            $errors.Add("At least two mandatory $product endpoints are required.")
        }
    }

    $synthetic = @(
        [pscustomobject]@{ Preset='required-first'; Pass=1; Mandatory=$true; Success=$true; DurationMs=50 },
        [pscustomobject]@{ Preset='required-first'; Pass=1; Mandatory=$true; Success=$true; DurationMs=50 },
        [pscustomobject]@{ Preset='required-first'; Pass=1; Mandatory=$false; Success=$false; DurationMs=50 },
        [pscustomobject]@{ Preset='overall-first'; Pass=1; Mandatory=$true; Success=$true; DurationMs=5 },
        [pscustomobject]@{ Preset='overall-first'; Pass=1; Mandatory=$true; Success=$false; DurationMs=5 },
        [pscustomobject]@{ Preset='overall-first'; Pass=1; Mandatory=$false; Success=$true; DurationMs=5 }
    )
    $ranked = @(Get-PresetRanking $synthetic)
    if (-not $ranked.Count -or $ranked[0].Preset -ne 'required-first') {
        $errors.Add('Ranking must prioritize complete mandatory Discord/YouTube endpoints before overall score and time.')
    }
    $adapterCases = @{
        'Tailscale Tunnel' = 'Overlay'
        'vEthernet (WSL)' = 'Virtual'
        'WireGuard Tunnel' = 'VpnCandidate'
        'Intel Ethernet Controller' = 'Physical'
    }
    foreach ($case in $adapterCases.GetEnumerator()) {
        if ((Get-AdapterKind -Name $case.Key -Description $case.Key) -ne $case.Value) {
            $errors.Add("Adapter classification failed for $($case.Key).")
        }
    }

    $networkScript = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'compatibility-wizard-network.ps1') -Raw
    $mainScript = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'compatibility-wizard-main.ps1') -Raw
    foreach ($requiredToken in @(
        "-GameMode 'off'", '-IPSetMode $IPSetMode', '-VoiceMode $VoiceMode',
        'Restore-ConflictState', 'finally', 'RawEtlIncluded = $false', 'Compress-Archive'
    )) {
        if (($networkScript + $mainScript) -notmatch [regex]::Escape($requiredToken)) {
            $errors.Add("Wizard contract token is missing: $requiredToken")
        }
    }
    foreach ($forbiddenPattern in @(
        ('Invoke-' + 'RestMethod'),
        ('api' + '\.openai'),
        ('--dpi-' + 'desync')
    )) {
        if (($networkScript + $mainScript) -match $forbiddenPattern) {
            $errors.Add('The wizard must not use remote APIs, AI calls, or Zapret 1 options.')
        }
    }

    if ($errors.Count) { throw "Compatibility Wizard contract validation failed: $($errors -join ' | ')" }
    Write-Host "Compatibility Wizard contract passed: $($publicPresets.Count) presets, $($targets.Count) local endpoint definitions, deterministic ranking." -ForegroundColor Green
}

function Get-WindowsInfo {
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        return [pscustomobject]@{
            Caption = [string]$os.Caption
            Version = [string]$os.Version
            BuildNumber = [string]$os.BuildNumber
            OSArchitecture = [string]$os.OSArchitecture
        }
    } catch {
        return [pscustomobject]@{
            Caption = [Environment]::OSVersion.VersionString
            Version = [Environment]::OSVersion.Version.ToString()
            BuildNumber = [Environment]::OSVersion.Version.Build.ToString()
            OSArchitecture = if ([Environment]::Is64BitOperatingSystem) { '64-bit' } else { '32-bit' }
        }
    }
}

function Invoke-PreflightLoop {
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $snapshot = Get-PreflightSnapshot
        foreach ($finding in @($snapshot.Findings)) { $finding.Attempt = $attempt }
        Show-PreflightFindings $snapshot.Findings
        Resolve-PreflightDecisions $snapshot.Findings
        $script:result.preflight += @($snapshot.Findings)
        $blockers = @($snapshot.Findings | Where-Object Severity -eq 'Blocker')
        if (-not $blockers.Count) { return $snapshot.ConflictState }

        Write-Host ''
        Write-Host 'Preflight has blockers. Nothing has been stopped or changed.' -ForegroundColor Red
        foreach ($blocker in $blockers) { Write-Host "  - $($blocker.Message)" -ForegroundColor Red }
        if ($attempt -ge 3 -or -not (Read-YesNo 'After resolving them manually, rerun every preflight check now?' 'Yes')) {
            throw "Preflight did not pass: $(@($blockers | ForEach-Object Message) -join '; ')"
        }
    }
    throw 'Preflight did not pass.'
}

function Invoke-ManualWebConfirmation {
    param([string]$Preset, [string]$IPSetMode)

    try {
        Start-WizardEngine -Preset $Preset -IPSetMode $IPSetMode -VoiceMode 'off' -Tag "manual-web-$Preset-$IPSetMode" | Out-Null
        Write-Host ''
        Write-Host 'Manual web confirmation' -ForegroundColor Cyan
        Write-Host 'Open Discord Web, start the Discord desktop app, and play a YouTube video.' -ForegroundColor Yellow
        $ready = (Read-Host 'Press Enter when ready, or q to cancel').Trim().ToLowerInvariant()
        if ($ready -in @('q', 'quit', 'cancel')) { Stop-Wizard 'Canceled before manual web confirmation.' }
        $result = [pscustomobject]@{
            Type = 'WebConfirmation'
            TimestampUtc = [DateTime]::UtcNow.ToString('o')
            Preset = $Preset
            GameMode = 'off'
            IPSetMode = $IPSetMode
            VoiceMode = 'off'
            DiscordWeb = Read-YesNo 'Did Discord Web load and work?' 'No'
            DiscordApp = Read-YesNo 'Did the Discord desktop app connect and work?' 'No'
            YouTubePlayback = Read-YesNo 'Did a YouTube video play?' 'No'
        }
        $script:result.networkObservations += @(Get-DiscordNetworkObservations 'manual-web' 'off')
        return $result
    } finally {
        Stop-WizardEngine
    }
}

function Invoke-VoiceManualTest {
    param([string]$Preset, [string]$IPSetMode, [string]$VoiceMode, [string]$Phase = 'voice-test')

    $observations = @()
    $pktmonArtifact = $null
    try {
        Start-WizardEngine -Preset $Preset -IPSetMode $IPSetMode -VoiceMode $VoiceMode -Tag "$Phase-$Preset-$IPSetMode-$VoiceMode" | Out-Null
        Start-PktMonCapture "$Phase-$VoiceMode" | Out-Null
        Write-Host ''
        Write-Host "Voice check: $VoiceMode" -ForegroundColor Cyan
        Write-Host 'Join a Discord voice channel with another participant and keep the call active.' -ForegroundColor Yellow
        $ready = (Read-Host 'Press Enter after the call is connected, or q to cancel').Trim().ToLowerInvariant()
        if ($ready -in @('q', 'quit', 'cancel')) { Stop-Wizard "Canceled during $VoiceMode voice test." }
        $observations += @(Get-DiscordNetworkObservations $Phase $VoiceMode)
        $ping = Read-PingValue
        $heardOther = Read-YesNo 'Could you hear the other participant?' 'No'
        $otherHeard = Read-YesNo 'Could the other participant hear you?' 'No'
        $screenShare = Read-ThreeWay 'Did screen share work?'
        $observations += @(Get-DiscordNetworkObservations $Phase $VoiceMode)
        $ports = @($observations | Where-Object Protocol -eq 'UDP' | ForEach-Object { [int]$_.LocalPort } | Sort-Object -Unique)
        $pktmonArtifact = Stop-PktMonCapture -DiscordLocalPorts $ports
        $script:result.networkObservations += $observations
        return [pscustomobject]@{
            Type = 'VoiceConfirmation'
            TimestampUtc = [DateTime]::UtcNow.ToString('o')
            Phase = $Phase
            Preset = $Preset
            GameMode = 'off'
            IPSetMode = $IPSetMode
            VoiceMode = $VoiceMode
            PingMs = $ping
            HeardOtherParticipant = $heardOther
            OtherParticipantHeardTester = $otherHeard
            TwoWayAudio = ($heardOther -and $otherHeard)
            ScreenShare = $screenShare
            PktMon = $pktmonArtifact
        }
    } finally {
        if ($script:pktMonOwned -or $null -ne $script:pktMonState) {
            $ports = @($observations | Where-Object Protocol -eq 'UDP' | ForEach-Object { [int]$_.LocalPort } | Sort-Object -Unique)
            try { Stop-PktMonCapture -DiscordLocalPorts $ports | Out-Null } catch {}
        }
        Stop-WizardEngine
    }
}

function Invoke-FinalManualRecheck {
    param([string]$Preset, [string]$IPSetMode, [string]$VoiceMode, [bool]$VoiceWasConfirmed)

    $observations = @()
    $pktmonArtifact = $null
    try {
        Start-WizardEngine -Preset $Preset -IPSetMode $IPSetMode -VoiceMode $VoiceMode -Tag "final-manual-$Preset-$IPSetMode-$VoiceMode" | Out-Null
        Start-PktMonCapture 'final-combination' | Out-Null
        Write-Host ''
        Write-Host 'Final exact-combination recheck' -ForegroundColor Cyan
        Write-Host "Web=$Preset | Voice=$VoiceMode | Game=off | IPSet=$IPSetMode" -ForegroundColor Green
        $ready = (Read-Host 'Repeat the Discord/YouTube/call checks, then press Enter (q = cancel)').Trim().ToLowerInvariant()
        if ($ready -in @('q', 'quit', 'cancel')) { Stop-Wizard 'Canceled during final exact-combination recheck.' }
        $observations += @(Get-DiscordNetworkObservations 'final-manual' $VoiceMode)
        $discordWeb = Read-YesNo 'Final check: did Discord Web work?' 'No'
        $discordApp = Read-YesNo 'Final check: did the Discord app work?' 'No'
        $youtube = Read-YesNo 'Final check: did YouTube playback work?' 'No'
        $ping = if ($VoiceWasConfirmed) { Read-PingValue } else { $null }
        $heardOther = if ($VoiceWasConfirmed) { Read-YesNo 'Final check: could you hear the other participant?' 'No' } else { $false }
        $otherHeard = if ($VoiceWasConfirmed) { Read-YesNo 'Final check: could the other participant hear you?' 'No' } else { $false }
        $screenShare = if ($VoiceWasConfirmed) { Read-ThreeWay 'Final check: did screen share work?' } else { 'not-tested' }
        $observations += @(Get-DiscordNetworkObservations 'final-manual' $VoiceMode)
        $ports = @($observations | Where-Object Protocol -eq 'UDP' | ForEach-Object { [int]$_.LocalPort } | Sort-Object -Unique)
        $pktmonArtifact = Stop-PktMonCapture -DiscordLocalPorts $ports
        $script:result.networkObservations += $observations
        return [pscustomobject]@{
            Type = 'FinalCombinationConfirmation'
            TimestampUtc = [DateTime]::UtcNow.ToString('o')
            Preset = $Preset
            GameMode = 'off'
            IPSetMode = $IPSetMode
            VoiceMode = $VoiceMode
            DiscordWeb = $discordWeb
            DiscordApp = $discordApp
            YouTubePlayback = $youtube
            PingMs = $ping
            HeardOtherParticipant = $heardOther
            OtherParticipantHeardTester = $otherHeard
            TwoWayAudio = ($heardOther -and $otherHeard)
            ScreenShare = $screenShare
            PktMon = $pktmonArtifact
        }
    } finally {
        if ($script:pktMonOwned -or $null -ne $script:pktMonState) {
            $ports = @($observations | Where-Object Protocol -eq 'UDP' | ForEach-Object { [int]$_.LocalPort } | Sort-Object -Unique)
            try { Stop-PktMonCapture -DiscordLocalPorts $ports | Out-Null } catch {}
        }
        Stop-WizardEngine
    }
}

function Invoke-CompatibilityWizard {
    try { $Host.UI.RawUI.WindowTitle = 'Zapret 2 NEXT - Compatibility Wizard' } catch {}
    Clear-Host
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host '          ZAPRET 2 NEXT - COMPATIBILITY WIZARD' -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'PRIVACY WARNING' -ForegroundColor Yellow
    Write-Host 'The result ZIP contains tester/provider/region metadata, exact IP addresses and ports,' -ForegroundColor Yellow
    Write-Host 'process IDs, timestamps, local paths, full winws2 debug logs, and filtered PktMon metadata.' -ForegroundColor Yellow
    Write-Host 'It does not contain packet payloads or raw ETL. The wizard is fully local and uses no AI/API.' -ForegroundColor Yellow
    if (-not (Read-YesNo 'Do you consent to collecting these local diagnostics?' 'No')) {
        Write-Host 'No report was created and no system state was changed.' -ForegroundColor Yellow
        exit 2
    }

    $tester = @{
        TesterId = Read-RequiredValue 'Tester alias or ID'
        Provider = Read-RequiredValue 'Internet provider'
        RegionCity = (Read-Host 'Region or city (optional; q = cancel)').Trim()
        ConnectionType = Get-ConnectionType
    }
    if ($tester.RegionCity -match '^(?i:q|quit|cancel)$') { Stop-Wizard 'Canceled while entering region/city.' }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:resultDir = Join-Path $root "runtime\compatibility-results\compatibility-$stamp"
    $script:zipPath = "$script:resultDir.zip"
    New-Item -ItemType Directory -Force -Path $script:resultDir | Out-Null
    $stateBeforeOrdered = Get-UserStateHashes
    $stateBefore = @{}
    foreach ($entry in $stateBeforeOrdered.GetEnumerator()) { $stateBefore[$entry.Key] = $entry.Value }
    $script:result = New-ResultDocument -Tester $tester -SystemInfo (Get-WindowsInfo) -StateBefore $stateBefore
    $script:targets = @(Get-WizardTargets)
    $exitCode = 0

    try {
        $script:conflictState = Invoke-PreflightLoop
        $script:result.conflictState = $script:conflictState
        Write-Host ''
        Write-Host 'All preflight checks are complete. No Zapret process or service has been stopped yet.' -ForegroundColor Green
        if (-not (Read-YesNo 'Temporarily stop the recorded Zapret state and start compatibility testing?' 'No')) {
            Stop-Wizard 'Canceled before any Zapret state was stopped.'
        }
        Stop-ConflictState $script:conflictState | Out-Null

        Write-Host ''
        Write-Host 'Stage 1/4: one pass across all six public web presets' -ForegroundColor Cyan
        foreach ($preset in $publicPresets) {
            Invoke-WebPass -Preset $preset -Pass 1 -IPSetMode 'any' -VoiceMode 'off' -Phase 'scan' | Out-Null
        }
        $firstRanking = @(Get-PresetRanking @($script:result.webResults | Where-Object Phase -eq 'scan'))
        $topThree = @($firstRanking | Select-Object -First 3 | Select-Object -ExpandProperty Preset)
        if ($topThree.Count -ne 3) { throw 'The first web pass did not produce three candidates.' }

        Write-Host ''
        Write-Host "Stage 2/4: two additional passes for: $($topThree -join ', ')" -ForegroundColor Cyan
        foreach ($pass in 2..3) {
            foreach ($preset in $topThree) {
                Invoke-WebPass -Preset $preset -Pass $pass -IPSetMode 'any' -VoiceMode 'off' -Phase 'scan' | Out-Null
            }
        }
        $scanRows = @($script:result.webResults | Where-Object Phase -eq 'scan')
        $script:result.ranking = @(Get-PresetRanking $scanRows)
        $candidate = @($script:result.ranking | Where-Object { $_.Preset -in $topThree })[0]
        $selectedPreset = [string]$candidate.Preset

        Write-Host ''
        Write-Host "Selected web candidate: $selectedPreset" -ForegroundColor Green
        Write-Host 'Stage 3/4: verify the selected candidate with IPSet loaded' -ForegroundColor Cyan
        $loadedRows = @(Invoke-WebPass -Preset $selectedPreset -Pass 1 -IPSetMode 'loaded' -VoiceMode 'off' -Phase 'ipset-loaded')
        $loadedMandatoryOk = @($loadedRows | Where-Object { $_.Mandatory -and -not $_.Success }).Count -eq 0
        $anyMandatoryOk = $candidate.MandatoryRunRate -gt 0
        $recommendedIPSet = if ($loadedMandatoryOk) { 'loaded' } else { 'any' }
        $ipsetNote = if ($loadedMandatoryOk) {
            'The selected preset passed its mandatory endpoint check with IPSet loaded.'
        } elseif ($anyMandatoryOk) {
            'IPSet loaded failed while IPSet any had a complete mandatory pass; IPSet any is explicitly recommended.'
        } else {
            'Neither loaded nor any produced a fully reliable mandatory endpoint result; the suggestion is unconfirmed.'
        }
        Write-Host $ipsetNote -ForegroundColor $(if ($loadedMandatoryOk) { 'Green' } else { 'Yellow' })

        $webManual = Invoke-ManualWebConfirmation -Preset $selectedPreset -IPSetMode $recommendedIPSet
        $script:result.manualResults += $webManual

        $selectedVoice = $null
        foreach ($voiceMode in @('off', 'standard', 'compatible')) {
            $voiceResult = Invoke-VoiceManualTest -Preset $selectedPreset -IPSetMode $recommendedIPSet -VoiceMode $voiceMode
            $script:result.manualResults += $voiceResult
            if ($voiceResult.TwoWayAudio) { $selectedVoice = $voiceMode; break }
        }
        $finalVoiceMode = if ($null -ne $selectedVoice) { $selectedVoice } else { 'off' }

        Write-Host ''
        Write-Host 'Stage 4/4: repeat the exact final combination before report creation' -ForegroundColor Cyan
        $finalAutomatic = @(Invoke-WebPass -Preset $selectedPreset -Pass 1 -IPSetMode $recommendedIPSet -VoiceMode $finalVoiceMode -Phase 'final-recheck')
        $finalAutomaticOk = @($finalAutomatic | Where-Object { $_.Mandatory -and -not $_.Success }).Count -eq 0
        $finalManual = Invoke-FinalManualRecheck -Preset $selectedPreset -IPSetMode $recommendedIPSet -VoiceMode $finalVoiceMode -VoiceWasConfirmed ($null -ne $selectedVoice)
        $script:result.manualResults += $finalManual

        $manualWebOk = $webManual.DiscordWeb -and $webManual.DiscordApp -and $webManual.YouTubePlayback
        $finalWebOk = $finalManual.DiscordWeb -and $finalManual.DiscordApp -and $finalManual.YouTubePlayback
        $voiceOk = $null -ne $selectedVoice -and $finalManual.TwoWayAudio
        $confirmed = $finalAutomaticOk -and $manualWebOk -and $finalWebOk -and $voiceOk
        $notes = @($ipsetNote)
        if ($null -eq $selectedVoice) { $notes += 'No voice mode was confirmed with two-way audio; Voice=off below is a web-only fallback, not a working-voice claim.' }
        if (-not $confirmed) { $notes += 'The exact final combination did not pass every automatic and manual confirmation; do not treat it as provider compatibility evidence.' }
        $script:result.recommendation = [pscustomobject]@{
            WebPreset = $selectedPreset
            VoiceMode = $finalVoiceMode
            GameMode = 'off'
            IPSetMode = $recommendedIPSet
            Confirmed = [bool]$confirmed
            Notes = $notes
            Installed = $false
        }
        $script:result.status = if ($confirmed) { 'completed-confirmed' } else { 'completed-unconfirmed' }
    } catch [OperationCanceledException] {
        $script:result.status = 'canceled'
        $script:result.errors += $_.Exception.Message
        $exitCode = 2
    } catch {
        $script:result.status = 'failed'
        $script:result.errors += $_.Exception.ToString()
        Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
        $exitCode = 1
    } finally {
        Stop-WizardOwnedResources
        if ($script:conflictsStopped) {
            $script:result.restoration = @(Restore-ConflictState $script:conflictState)
        }
        $stateAfterOrdered = Get-UserStateHashes
        $stateAfter = @{}
        foreach ($entry in $stateAfterOrdered.GetEnumerator()) { $stateAfter[$entry.Key] = $entry.Value }
        $script:result.userStateAfter = $stateAfter
        $preserved = $true
        foreach ($key in $stateBefore.Keys) {
            if ($stateBefore[$key] -ne $stateAfter[$key]) { $preserved = $false }
        }
        $script:result.userStatePreserved = $preserved
        if (-not $preserved) {
            $script:result.errors += 'Saved mode/IPSet state changed during the wizard run.'
            if ($exitCode -eq 0) { $exitCode = 1; $script:result.status = 'failed-state-changed' }
        }
        $script:result.finishedAtUtc = [DateTime]::UtcNow.ToString('o')
    }

    try {
        Save-ResultArtifacts
        Write-Host ''
        Write-Host "Report directory: $script:resultDir" -ForegroundColor Green
        Write-Host "Result ZIP: $script:zipPath" -ForegroundColor Cyan
        Write-Host 'No settings were installed or saved.' -ForegroundColor Yellow
    } catch {
        Write-Host "[REPORT ERROR] $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Partial files remain in: $script:resultDir" -ForegroundColor Yellow
        $exitCode = 1
    }
    exit $exitCode
}
