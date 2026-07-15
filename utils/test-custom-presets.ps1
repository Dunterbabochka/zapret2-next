[CmdletBinding()]
param(
    [string[]]$Preset = @('ALT12', 'CUSTOM SAFE', 'CUSTOM BALANCED', 'CUSTOM AGGRESSIVE'),
    [ValidateRange(2, 60)]
    [int]$TimeoutSeconds = 8,
    [string]$OutputDirectory,
    [string]$TesterId = 'anonymous',
    [string]$Provider = 'unknown',
    [string]$Region = 'unknown',
    [string]$ConnectionType = 'unknown',
    [switch]$NonInteractive,
    [switch]$ConfirmNetworkTest,
    [switch]$AllowEmptyIPSet,
    [switch]$AllowContaminatedNetwork,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$renderer = Join-Path $PSScriptRoot 'render-config.ps1'
$starter = Join-Path $PSScriptRoot 'invoke-winws.ps1'
$winws = Join-Path $root 'bin\winws2.exe'
$targetsPath = Join-Path $PSScriptRoot 'targets.txt'
$ipsetPath = Join-Path $root 'lists\ipset-all.txt'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $root ('runtime\custom-ab\' + $stamp)
}
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
$jsonPath = Join-Path $outputRoot 'results.json'
$csvPath = Join-Path $outputRoot 'web-results.csv'
$manualCsvPath = Join-Path $outputRoot 'manual-acceptance.csv'
$reportPath = Join-Path $outputRoot 'REPORT.txt'
New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null

$mandatoryNames = @(
    'DiscordMain', 'DiscordGateway', 'DiscordCDN', 'DiscordUpdates',
    'YouTubeWeb', 'YouTubeShort', 'YouTubeImage', 'YouTubeVideoRedirect'
)
$auxiliaryNames = @('GoogleMain', 'GoogleGstatic')
$quicNames = @('YouTubeWeb', 'GoogleMain')
$allRows = [Collections.Generic.List[object]]::new()
$candidateReports = [Collections.Generic.List[object]]::new()
$warnings = [Collections.Generic.List[string]]::new()
$serviceWasRunning = $false
$savedProcesses = @()
$stateChanged = $false
$executionError = $null
$baselineName = 'DIRECT NO ZAPRET'
$curlVersionText = try { (& curl.exe --version 2>&1 | Out-String) } catch { '' }
$curlSupportsHttp3 = $curlVersionText -match '(?im)^Features:.*\bHTTP3\b'
$tieBreakRank = @{
    'CUSTOM SAFE' = 0
    'ALT12' = 1
    'CUSTOM BALANCED' = 2
    'CUSTOM AGGRESSIVE' = 3
}

function Add-Warning([string]$Message) {
    [void]$script:warnings.Add($Message)
}

function Get-LoadedIPSetEntryCount {
    if (-not (Test-Path -LiteralPath $ipsetPath -PathType Leaf)) { return 0 }
    return @(
        Get-Content -LiteralPath $ipsetPath |
            Where-Object { $_ -notmatch '^\s*(?:#|$)' }
    ).Count
}

function Get-ProxySnapshot {
    $reasons = [Collections.Generic.List[string]]::new()
    $detectionWarnings = [Collections.Generic.List[string]]::new()
    $envNames = @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy')
    foreach ($name in $envNames) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            [void]$reasons.Add(('{0} is set' -f $name))
        }
    }
    try {
        $inet = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
        if ([int]$inet.ProxyEnable -eq 1 -and -not [string]::IsNullOrWhiteSpace($inet.ProxyServer)) {
            [void]$reasons.Add(('WinINET proxy is enabled: {0}' -f $inet.ProxyServer))
        }
        if (-not [string]::IsNullOrWhiteSpace($inet.AutoConfigURL)) {
            [void]$reasons.Add('WinINET proxy auto-configuration URL is set')
        }
    } catch {
        [void]$detectionWarnings.Add('Could not read WinINET proxy state')
    }
    try {
        $winHttp = (& netsh winhttp show proxy 2>&1 | Out-String).Trim()
        if ($winHttp -match '(?i)direct access|no proxy|\u043f\u0440\u044f\u043c\u043e\u0439\s+\u0434\u043e\u0441\u0442\u0443\u043f|\u0431\u0435\u0437\s+\u043f\u0440\u043e\u043a\u0441\u0438') {
            # Locale-independent direct access result (English or Russian).
        } elseif ($winHttp -match '(?i)proxy|\u043f\u0440\u043e\u043a\u0441\u0438|socks|https?://|\b(?:\d{1,3}\.){3}\d{1,3}:\d+\b') {
            [void]$reasons.Add('WinHTTP reports a configured proxy')
        } else {
            [void]$detectionWarnings.Add('Could not determine WinHTTP proxy state from localized netsh output')
        }
    } catch {
        [void]$detectionWarnings.Add('Could not read WinHTTP proxy state')
    }
    try {
        $adapters = @(Get-NetAdapter -ErrorAction Stop | Where-Object {
            $_.Status -eq 'Up' -and
            $_.Name -notmatch '(?i)tailscale|hyper-v|wsl|loopback' -and
            ($_.Name -match '(?i)vpn|tun|warp|clash|wireguard|openvpn|proton|outline|sing-box|v2ray' -or
             $_.InterfaceDescription -match '(?i)vpn|tun|warp|clash|wireguard|openvpn|proton|outline|sing-box|v2ray')
        })
        foreach ($adapter in $adapters) {
            [void]$reasons.Add(('Suspicious active adapter: {0}' -f $adapter.Name))
        }
    } catch {
        [void]$detectionWarnings.Add('Could not inspect active adapters; adapter-based VPN/TUN detection was skipped')
    }
    return [pscustomobject]@{
        Configured = ($reasons.Count -gt 0)
        Reasons = @($reasons)
        DetectionWarnings = @($detectionWarnings)
        CapturedAt = (Get-Date).ToString('o')
    }
}

function Get-TestTargets {
    $items = [Collections.Generic.List[object]]::new()
    foreach ($line in Get-Content -LiteralPath $targetsPath) {
        if ($line -match '^\s*([A-Za-z0-9_]+)\s*=') {
            $name = $matches[1]
            $parts = $line.Split('=', 2)
            $value = if ($parts.Count -gt 1) { $parts[1].Trim() } else { '' }
            if ($value.Length -lt 2 -or $value[0] -ne [char]34 -or $value[$value.Length - 1] -ne [char]34) {
                continue
            }
            $value = $value.Substring(1, $value.Length - 2)
            if ($value -like 'PING:*') {
                [void]$items.Add([pscustomobject]@{
                    Name = $name
                    Url = $null
                    PingTarget = $value.Substring(5)
                })
            } elseif ($name -in ($mandatoryNames + $auxiliaryNames + $quicNames)) {
                [void]$items.Add([pscustomobject]@{
                    Name = $name
                    Url = $value
                    PingTarget = $null
                })
            }
        }
    }
    if (@($items | Where-Object { $_.Name -in $mandatoryNames }).Count -ne $mandatoryNames.Count) {
        throw 'targets.txt does not contain the complete mandatory Discord/YouTube endpoint set.'
    }
    return @($items)
}

function Get-DebugOffset([string]$DebugPath) {
    if ([string]::IsNullOrWhiteSpace($DebugPath) -or
        -not (Test-Path -LiteralPath $DebugPath -PathType Leaf)) {
        return [int64]0
    }
    return [int64](Get-Item -LiteralPath $DebugPath).Length
}

function Get-DebugDeltaEvidence([string]$DebugPath, [int64]$Offset) {
    $empty = [pscustomobject]@{
        ProfileIds = ''
        ActualLuaActions = ''
        ActualLuaActionCount = 0
        ProfileNotFoundCount = 0
    }
    if ([string]::IsNullOrWhiteSpace($DebugPath) -or
        -not (Test-Path -LiteralPath $DebugPath -PathType Leaf)) {
        return $empty
    }
    $stream = $null
    $reader = $null
    try {
        $stream = [IO.File]::Open($DebugPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        if ($Offset -gt $stream.Length) { $Offset = 0 }
        [void]$stream.Seek($Offset, [IO.SeekOrigin]::Begin)
        $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::ASCII, $true, 4096, $true)
        $delta = $reader.ReadToEnd()
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
    $profileIds = @(
        [regex]::Matches($delta, '(?m)(?:desync profile|using cached desync profile)\s+(\d+).*?(?:matches)?\s*$') |
            ForEach-Object { $_.Groups[1].Value } |
            Sort-Object -Unique
    )
    $actualActionLines = @($delta -split '\r?\n' | Where-Object {
        $_ -match "^\s*\*\s+lua\s+'[^']+'.*:\s+desync\s*$"
    })
    $actualActions = @(
        $actualActionLines | ForEach-Object {
            if ($_ -match "'([^']+)'") { $matches[1] }
        } | Sort-Object -Unique
    )
    return [pscustomobject]@{
        ProfileIds = ($profileIds -join ';')
        ActualLuaActions = ($actualActions -join ';')
        ActualLuaActionCount = $actualActionLines.Count
        ProfileNotFoundCount = [regex]::Matches($delta, '(?i)profile\s+not\s+found').Count
    }
}

function Invoke-WebChecks {
    param(
        [string]$Candidate,
        [string]$Stage,
        [array]$Targets,
        [bool]$Contaminated,
        [string]$DebugPath = ''
    )
    $totalChecks = 0
    foreach ($plannedTarget in $Targets) {
        if ($null -ne $plannedTarget.Url) {
            $totalChecks += 3
            if ($plannedTarget.Name -in $quicNames) { $totalChecks++ }
        } elseif ($null -ne $plannedTarget.PingTarget) {
            $totalChecks++
        }
    }
    $completedChecks = 0
    foreach ($target in $Targets) {
        if ($null -ne $target.Url) {
            $tests = @(
                [pscustomobject]@{ Name = 'HTTP1.1'; Args = @('--http1.1') },
                [pscustomobject]@{ Name = 'TLS1.2'; Args = @('--tlsv1.2', '--tls-max', '1.2') },
                [pscustomobject]@{ Name = 'TLS1.3'; Args = @('--tlsv1.3', '--tls-max', '1.3') }
            )
            if ($target.Name -in $quicNames) {
                $tests += [pscustomobject]@{ Name = 'QUIC'; Args = @('--http3-only') }
            }
            foreach ($test in $tests) {
                Write-Progress -Activity ('CUSTOM A/B: {0}' -f $Candidate) `
                    -Status ('{0} {1} ({2}/{3})' -f $target.Name, $test.Name, ($completedChecks + 1), $totalChecks) `
                    -PercentComplete ([math]::Floor(($completedChecks / [math]::Max(1, $totalChecks)) * 100))
                if ($test.Name -eq 'QUIC' -and -not $curlSupportsHttp3) {
                    [void]$allRows.Add([pscustomobject]@{
                        Candidate = $Candidate
                        Stage = $Stage
                        Target = $target.Name
                        Protocol = $test.Name
                        ProbeAvailable = $false
                        TransportSuccess = $false
                        HttpCode = 0
                        ElapsedMs = $null
                        RemoteIP = ''
                        RemotePort = 0
                        Ranked = $false
                        ApplicationEvidenceRequired = $false
                        Contaminated = $Contaminated
                        ProfileIds = ''
                        ActualLuaActions = ''
                        ActualLuaActionCount = 0
                        ProfileNotFoundCount = 0
                        Detail = 'QUIC probe unavailable: the installed curl lacks HTTP/3 support. Verify h3 manually in a browser.'
                    })
                    $completedChecks++
                    continue
                }
                $debugOffset = Get-DebugOffset $DebugPath
                $curlArgs = @(
                    '--noproxy', '*', '-I', '-sS',
                    '--max-time', [string]$TimeoutSeconds,
                    '--connect-timeout', [string]$TimeoutSeconds,
                    '-o', 'NUL', '-w', '%{http_code}|%{time_total}|%{remote_ip}|%{remote_port}'
                ) + $test.Args
                $raw = ''
                $curlExit = -1
                try {
                    $raw = (& curl.exe @curlArgs $target.Url 2>$null | Out-String).Trim()
                    $curlExit = $LASTEXITCODE
                } catch {
                    $raw = $_.Exception.Message
                }
                if (-not [string]::IsNullOrWhiteSpace($DebugPath)) {
                    Start-Sleep -Milliseconds 100
                }
                $rowEvidence = Get-DebugDeltaEvidence -DebugPath $DebugPath -Offset $debugOffset
                $parts = @($raw -split '\|', 4)
                $formatOk = $parts.Count -eq 4 -and $parts[0] -match '^\d{3}$' -and $parts[1] -match '^[0-9.]+$'
                $code = if ($formatOk) { [int]$parts[0] } else { 0 }
                $elapsed = if ($formatOk) { [double]$parts[1] * 1000 } else { $null }
                $remoteIP = if ($formatOk) { [string]$parts[2] } else { '' }
                $remotePort = if ($formatOk -and $parts[3] -match '^\d+$') { [int]$parts[3] } else { 0 }
                $ok = $curlExit -eq 0 -and $code -ne 0
                [void]$allRows.Add([pscustomobject]@{
                    Candidate = $Candidate
                    Stage = $Stage
                    Target = $target.Name
                    Protocol = $test.Name
                    ProbeAvailable = $true
                    TransportSuccess = [bool]$ok
                    HttpCode = $code
                    ElapsedMs = $elapsed
                    RemoteIP = $remoteIP
                    RemotePort = $remotePort
                    Ranked = [bool]($test.Name -ne 'QUIC')
                    ApplicationEvidenceRequired = [bool]($target.Name -in $mandatoryNames)
                    Contaminated = $Contaminated
                    ProfileIds = $rowEvidence.ProfileIds
                    ActualLuaActions = $rowEvidence.ActualLuaActions
                    ActualLuaActionCount = $rowEvidence.ActualLuaActionCount
                    ProfileNotFoundCount = $rowEvidence.ProfileNotFoundCount
                    Detail = if ($ok) { 'HTTP response received; application/manual evidence still required where marked.' } else { ('No usable HTTP response: curl {0}; raw={1}' -f $curlExit, $raw) }
                })
                $completedChecks++
            }
        } elseif ($null -ne $target.PingTarget) {
            Write-Progress -Activity ('CUSTOM A/B: {0}' -f $Candidate) `
                -Status ('{0} ICMP ({1}/{2})' -f $target.Name, ($completedChecks + 1), $totalChecks) `
                -PercentComplete ([math]::Floor(($completedChecks / [math]::Max(1, $totalChecks)) * 100))
            $ping = [Net.NetworkInformation.Ping]::new()
            try {
                $reply = $ping.Send($target.PingTarget, $TimeoutSeconds * 1000)
                $ok = $reply.Status -eq [Net.NetworkInformation.IPStatus]::Success
                [void]$allRows.Add([pscustomobject]@{
                    Candidate = $Candidate
                    Stage = $Stage
                    Target = $target.Name
                    Protocol = 'ICMP'
                    ProbeAvailable = $true
                    TransportSuccess = [bool]$ok
                    HttpCode = $null
                    ElapsedMs = if ($ok) { [double]$reply.RoundtripTime } else { $null }
                    RemoteIP = $target.PingTarget
                    RemotePort = 0
                    Ranked = $false
                    ApplicationEvidenceRequired = $false
                    Contaminated = $Contaminated
                    ProfileIds = ''
                    ActualLuaActions = ''
                    ActualLuaActionCount = 0
                    ProfileNotFoundCount = 0
                    Detail = $reply.Status.ToString()
                })
            } catch {
                [void]$allRows.Add([pscustomobject]@{
                    Candidate = $Candidate
                    Stage = $Stage
                    Target = $target.Name
                    Protocol = 'ICMP'
                    ProbeAvailable = $true
                    TransportSuccess = $false
                    HttpCode = $null
                    ElapsedMs = $null
                    RemoteIP = $target.PingTarget
                    RemotePort = 0
                    Ranked = $false
                    ApplicationEvidenceRequired = $false
                    Contaminated = $Contaminated
                    ProfileIds = ''
                    ActualLuaActions = ''
                    ActualLuaActionCount = 0
                    ProfileNotFoundCount = 0
                    Detail = 'Ping exception: ' + $_.Exception.Message
                })
            } finally {
                $ping.Dispose()
                $completedChecks++
            }
        }
    }
    Write-Progress -Activity ('CUSTOM A/B: {0}' -f $Candidate) -Completed
}

function Stop-Winws2 {
    $processes = @(Get-Process -Name winws2 -ErrorAction SilentlyContinue)
    foreach ($process in $processes) {
        try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch {}
    }
    if ($processes.Count -gt 0) { Start-Sleep -Milliseconds 500 }
}

function Get-ActionEvidence([string]$DebugPath) {
    $debugText = if (Test-Path -LiteralPath $DebugPath -PathType Leaf) {
        Get-Content -LiteralPath $DebugPath -Raw
    } else {
        ''
    }
    $actionLines = @($debugText -split '\r?\n' | Where-Object {
        $_ -match "^\s*\*\s+lua\s+'[^']+'.*:\s+desync\s*$"
    })
    $actionNames = [Collections.Generic.List[string]]::new()
    foreach ($line in $actionLines) {
        if ($line -match '''([^'']+)''') {
            [void]$actionNames.Add($matches[1])
        }
    }
    $matchesCount = [regex]::Matches($debugText, '(?m)desync profile [0-9]+ .* matches').Count
    $notFoundCount = [regex]::Matches($debugText, '(?i)profile\s+not\s+found').Count
    $suspicious = @($debugText -split '\r?\n' | Where-Object {
        $_ -match '(?i)\b(?:proxy|socks5|tun2socks|clash|sing-box)\b'
    } | Select-Object -First 20)
    return [pscustomobject]@{
        DebugPath = $DebugPath
        DebugLogPresent = (Test-Path -LiteralPath $DebugPath -PathType Leaf)
        ActualLuaActionCount = $actionLines.Count
        ActualLuaActions = @($actionNames | Sort-Object -Unique)
        ProfileMatchCount = $matchesCount
        ProfileNotFoundCount = $notFoundCount
        SuspiciousProxyLines = @($suspicious)
        RawDebugLineCount = @($debugText -split '\r?\n').Count
    }
}

function Get-ProcessSnapshot {
    try {
        return @(
            Get-CimInstance Win32_Process -ErrorAction Stop |
                Where-Object { $_.Name -ieq 'winws2.exe' } |
                Select-Object ExecutablePath, CommandLine
        )
    } catch {
        Add-Warning 'Could not snapshot existing manual winws2 processes.'
        return @()
    }
}

function Restore-OriginalState {
    if ($serviceWasRunning) {
        try { Start-Service -Name winws2 -ErrorAction Stop } catch {
            Add-Warning ('Could not restart the previously running winws2 service: {0}' -f $_.Exception.Message)
        }
        return
    }
    foreach ($saved in $savedProcesses) {
        if ([string]::IsNullOrWhiteSpace($saved.ExecutablePath) -or
            [string]::IsNullOrWhiteSpace($saved.CommandLine)) { continue }
        $args = [string]$saved.CommandLine
        $quotedExe = [char]34 + [string]$saved.ExecutablePath + [char]34
        if ($args.StartsWith($quotedExe)) {
            $args = $args.Substring($quotedExe.Length).Trim()
        }
        try {
            $startParams = @{
                FilePath = $saved.ExecutablePath
                ArgumentList = $args
                WorkingDirectory = Split-Path -Parent $saved.ExecutablePath
                WindowStyle = 'Hidden'
            }
            Start-Process @startParams | Out-Null
        } catch {
            Add-Warning ('Could not restore manual winws2: {0}' -f $_.Exception.Message)
        }
    }
}

function Add-CandidateSummary([string]$Name, [string]$Stage, [bool]$StartupOk,
    [bool]$Contaminated, [string]$ConfigPath, [string]$DebugPath,
    [string]$Status, [object]$ActionEvidence) {
    $candidateRows = @($allRows | Where-Object { $_.Candidate -eq $Name })
    $rankedRows = @($candidateRows | Where-Object { $_.Ranked })
    $mandatoryRows = @($rankedRows | Where-Object { $_.Target -in $mandatoryNames })
    $transportPassed = @($rankedRows | Where-Object { $_.TransportSuccess }).Count
    $mandatoryPassed = @($mandatoryRows | Where-Object { $_.TransportSuccess }).Count
    $mandatoryEvidencePassed = @($mandatoryRows | Where-Object {
        $_.ActualLuaActionCount -gt 0 -and
        -not [string]::IsNullOrWhiteSpace($_.ProfileIds) -and
        $_.ProfileNotFoundCount -eq 0
    }).Count
    $aggregateEvidenceValid = $Name -eq $baselineName -or (
        $ActionEvidence.ActualLuaActionCount -gt 0 -and
        $ActionEvidence.ProfileMatchCount -gt 0 -and
        $ActionEvidence.ProfileNotFoundCount -eq 0
    )
    $valid = $StartupOk -and -not $Contaminated -and
        $mandatoryRows.Count -eq ($mandatoryNames.Count * 3) -and
        $mandatoryPassed -eq $mandatoryRows.Count -and
        $mandatoryEvidencePassed -eq $mandatoryRows.Count -and
        $aggregateEvidenceValid
    [void]$candidateReports.Add([pscustomobject]@{
        Candidate = $Name
        Stage = $Stage
        StartupOk = $StartupOk
        Status = $Status
        Contaminated = $Contaminated
        ValidForRanking = $valid
        TransportPassed = $transportPassed
        TransportTotal = $rankedRows.Count
        MandatoryPassed = $mandatoryPassed
        MandatoryTotal = $mandatoryRows.Count
        MandatoryEvidencePassed = $mandatoryEvidencePassed
        AggregateEvidenceValid = $aggregateEvidenceValid
        ConfigPath = $ConfigPath
        DebugPath = $DebugPath
        ActionEvidence = $ActionEvidence
    })
}

function Invoke-CustomABSelfTest {
    if ($tieBreakRank['CUSTOM SAFE'] -ge $tieBreakRank['ALT12'] -or
        $tieBreakRank['ALT12'] -ge $tieBreakRank['CUSTOM BALANCED'] -or
        $tieBreakRank['CUSTOM BALANCED'] -ge $tieBreakRank['CUSTOM AGGRESSIVE']) {
        throw 'The deterministic low-intervention tie-break order is invalid.'
    }
    $sampleLog = Join-Path $outputRoot 'selftest-debug.log'
    @(
        'desync profile 7 (noname) matches'
        "* lua 'fake_7_1' : out pos a0 d1 in range a0-d10"
        "* lua 'fake_7_1' : desync"
    ) | Set-Content -LiteralPath $sampleLog -Encoding ASCII
    try {
        $parsed = Get-DebugDeltaEvidence -DebugPath $sampleLog -Offset 0
        if ($parsed.ProfileIds -ne '7' -or $parsed.ActualLuaActions -ne 'fake_7_1' -or
            $parsed.ActualLuaActionCount -ne 1 -or $parsed.ProfileNotFoundCount -ne 0) {
            throw 'Debug evidence parser did not distinguish a real Lua desync action.'
        }
    } finally {
        Remove-Item -LiteralPath $sampleLog -Force -ErrorAction SilentlyContinue
    }

    $actionEvidence = [pscustomobject]@{
        ActualLuaActionCount = 1
        ActualLuaActions = @('fake_7_1')
        ProfileMatchCount = 1
        ProfileNotFoundCount = 0
        SuspiciousProxyLines = @()
    }
    $buildRows = {
        param([bool]$FailFirst)
        $first = $true
        foreach ($targetName in $mandatoryNames) {
            foreach ($protocol in @('HTTP1.1', 'TLS1.2', 'TLS1.3')) {
                [void]$allRows.Add([pscustomobject]@{
                    Candidate = 'SELFTEST'
                    Target = $targetName
                    Protocol = $protocol
                    Ranked = $true
                    TransportSuccess = -not ($FailFirst -and $first)
                    ActualLuaActionCount = 1
                    ProfileIds = '7'
                    ProfileNotFoundCount = 0
                })
                $first = $false
            }
        }
    }

    & $buildRows $false
    Add-CandidateSummary -Name 'SELFTEST' -Stage 'self-test' -StartupOk $true -Contaminated $false -ConfigPath '' -DebugPath '' -Status 'synthetic complete pass' -ActionEvidence $actionEvidence
    $complete = @($candidateReports)[0]
    if (-not $complete.ValidForRanking -or
        $complete.MandatoryEvidencePassed -ne ($mandatoryNames.Count * 3)) {
        throw 'A complete mandatory pass with evidence was not accepted by the ranking contract.'
    }

    $allRows.Clear()
    $candidateReports.Clear()
    & $buildRows $true
    Add-CandidateSummary -Name 'SELFTEST' -Stage 'self-test' -StartupOk $true -Contaminated $false -ConfigPath '' -DebugPath '' -Status 'synthetic incomplete pass' -ActionEvidence $actionEvidence
    if (@($candidateReports)[0].ValidForRanking) {
        throw 'A candidate with a failed mandatory transport row was accepted by the ranking contract.'
    }
    $allRows.Clear()
    $candidateReports.Clear()
    Write-Host 'CUSTOM A/B self-test passed: debug evidence and complete-pass ranking contract.' -ForegroundColor Green
}

if ($SelfTest) {
    Invoke-CustomABSelfTest
    return
}

$targets = @()
$proxySnapshot = $null
$ipsetEntryCount = Get-LoadedIPSetEntryCount
try {
    $targets = Get-TestTargets
    $proxySnapshot = Get-ProxySnapshot
    if (-not (Test-Path -LiteralPath $winws -PathType Leaf)) {
        throw ('winws2.exe not found: {0}' -f $winws)
    }
    if (-not (Test-Path -LiteralPath $renderer -PathType Leaf) -or
        -not (Test-Path -LiteralPath $starter -PathType Leaf)) {
        throw 'Renderer or winws2 launcher is missing.'
    }
    if ($ipsetEntryCount -eq 0 -and -not $AllowEmptyIPSet) {
        throw 'IPSet=loaded requires a populated lists\ipset-all.txt. Update the list or pass -AllowEmptyIPSet only for a diagnostic run.'
    }
    foreach ($detectionWarning in $proxySnapshot.DetectionWarnings) {
        Add-Warning $detectionWarning
        Write-Warning ('Network preflight: {0}' -f $detectionWarning)
    }
    if ($proxySnapshot.Configured) {
        Add-Warning 'Proxy/VPN/TUN indicators were found; the test will continue, but affected results are marked contaminated and excluded from ranking.'
        Write-Warning ('Proxy/VPN/TUN indicator: {0}. Continuing the test; affected candidates will not be ranked.' -f ($proxySnapshot.Reasons -join '; '))
    }
    Write-Warning 'Privacy: the report can contain provider/region metadata, endpoint IPs and ports, PIDs, timestamps, local paths and winws2 debug lines. Packet payloads and raw ETL are not collected.'
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this A/B test from an elevated PowerShell window.'
    }
    if (-not $NonInteractive) {
        if ($TesterId -eq 'anonymous') {
            $value = (Read-Host 'Tester pseudonym/ID (optional)').Trim()
            if ($value) { $TesterId = $value }
        }
        if ($Provider -eq 'unknown') {
            $value = (Read-Host 'Provider (optional)').Trim()
            if ($value) { $Provider = $value }
        }
        if ($Region -eq 'unknown') {
            $value = (Read-Host 'Region/city (optional; may be blank)').Trim()
            if ($value) { $Region = $value } else { $Region = 'unknown' }
        }
        if ($ConnectionType -eq 'unknown') {
            $value = (Read-Host 'Connection type, for example wired/wifi/mobile (optional)').Trim()
            if ($value) { $ConnectionType = $value }
        }
    }
    $service = Get-Service -Name winws2 -ErrorAction SilentlyContinue
    $serviceWasRunning = $null -ne $service -and $service.Status -ne 'Stopped'
    $savedProcesses = Get-ProcessSnapshot
    if (($serviceWasRunning -or $savedProcesses.Count -gt 0) -and -not $ConfirmNetworkTest) {
        throw 'winws2 is already active. Pass -ConfirmNetworkTest after reviewing the saved state before the test.'
    }
    if (-not $ConfirmNetworkTest) {
        if ($NonInteractive) {
            throw 'Non-interactive runs require the explicit -ConfirmNetworkTest switch.'
        }
        $answer = (Read-Host 'The test temporarily stops winws2/service and changes packet interception. Continue? [y/n]').Trim().ToLowerInvariant()
        if ($answer -notin @('y', 'yes')) { throw 'The tester cancelled before any state change.' }
    }
    $stateChanged = $true
    if ($serviceWasRunning) {
        Stop-Service -Name winws2 -Force -ErrorAction Stop
        Start-Sleep -Seconds 1
    }
    Stop-Winws2

    Write-Host ('[{0}] Starting transport checks...' -f $baselineName) -ForegroundColor Cyan
    Invoke-WebChecks -Candidate $baselineName -Stage 'baseline-no-zapret' -Targets $targets -Contaminated ([bool]$proxySnapshot.Configured)
    $baselineEvidence = [pscustomobject]@{
        ActualLuaActionCount = 0
        ActualLuaActions = @()
        ProfileMatchCount = 0
        ProfileNotFoundCount = 0
        SuspiciousProxyLines = @()
    }
    Add-CandidateSummary -Name $baselineName -Stage 'baseline-no-zapret' -StartupOk $true -Contaminated ([bool]$proxySnapshot.Configured) -ConfigPath '' -DebugPath '' -Status 'No Zapret baseline; manual app/voice evidence is not collected by this script.' -ActionEvidence $baselineEvidence

    foreach ($name in $Preset) {
        Write-Host ('[{0}] Preparing candidate...' -f $name) -ForegroundColor Cyan
        $presetPath = Join-Path $root ('presets\' + $name + '.txt.in')
        if (-not (Test-Path -LiteralPath $presetPath -PathType Leaf)) {
            $missingEvidence = [pscustomobject]@{
                ActualLuaActionCount = 0
                ActualLuaActions = @()
                ProfileMatchCount = 0
                ProfileNotFoundCount = 0
                SuspiciousProxyLines = @()
            }
            Add-CandidateSummary -Name $name -Stage 'candidate' -StartupOk $false -Contaminated $true -ConfigPath '' -DebugPath '' -Status 'Preset missing.' -ActionEvidence $missingEvidence
            continue
        }
        Stop-Winws2
        $safeName = $name -replace '[^A-Za-z0-9_-]', '_'
        $configPath = Join-Path $outputRoot ($safeName + '.txt')
        $dryPath = Join-Path $outputRoot ($safeName + '-dry.txt')
        $debugPath = Join-Path $outputRoot ($safeName + '-winws2-debug.log')
        $logPrefix = Join-Path $outputRoot ($safeName + '-winws2')
        try {
            & $renderer -Preset $name -Output $configPath -GameMode off -IPSetMode loaded -VoiceMode off -DebugLog $debugPath | Out-Null
            & $renderer -Preset $name -Output $dryPath -GameMode off -IPSetMode loaded -VoiceMode off -DryRun | Out-Null
        } catch {
            $renderEvidence = [pscustomobject]@{
                ActualLuaActionCount = 0
                ActualLuaActions = @()
                ProfileMatchCount = 0
                ProfileNotFoundCount = 0
                SuspiciousProxyLines = @()
            }
            Add-CandidateSummary -Name $name -Stage 'candidate' -StartupOk $false -Contaminated $true -ConfigPath $configPath -DebugPath $debugPath -Status ('Renderer failed: {0}' -f $_.Exception.Message) -ActionEvidence $renderEvidence
            continue
        }
        & $starter -Config $dryPath -LogPrefix ($logPrefix + '-validate') -Validate | Out-Null
        $validateOk = $LASTEXITCODE -eq 0
        if (-not $validateOk) {
            Add-CandidateSummary -Name $name -Stage 'candidate' -StartupOk $false -Contaminated $true -ConfigPath $configPath -DebugPath $debugPath -Status 'winws2 rejected the dry-run configuration.' -ActionEvidence (Get-ActionEvidence $debugPath)
            continue
        }
        & $starter -Config $configPath -LogPrefix $logPrefix -StartupWaitSeconds 3 | Out-Null
        $startupOk = $LASTEXITCODE -eq 0
        if ($startupOk) {
            Invoke-WebChecks -Candidate $name -Stage 'candidate' -Targets $targets -Contaminated ([bool]$proxySnapshot.Configured) -DebugPath $debugPath
        }
        Stop-Winws2
        $evidence = Get-ActionEvidence $debugPath
        $candidateContaminated = [bool]$proxySnapshot.Configured -or $evidence.SuspiciousProxyLines.Count -gt 0
        $statusText = if ($startupOk) {
            'Web transport checks completed; Discord App/Voice/YouTube playback require manual confirmation.'
        } else {
            'winws2 did not stay running.'
        }
        Add-CandidateSummary -Name $name -Stage 'candidate' -StartupOk $startupOk -Contaminated $candidateContaminated -ConfigPath $configPath -DebugPath $debugPath -Status $statusText -ActionEvidence $evidence
    }
} catch {
    $executionError = $_.Exception.Message
} finally {
    if ($stateChanged) {
        Stop-Winws2
        Restore-OriginalState
    }
}

$rankable = @($candidateReports | Where-Object {
    $_.Candidate -ne $baselineName -and $_.ValidForRanking
})
$winner = $rankable |
    Sort-Object @{Expression = 'MandatoryPassed'; Descending = $true},
        @{Expression = 'TransportPassed'; Descending = $true},
        @{Expression = {
            if ($tieBreakRank.ContainsKey($_.Candidate)) { $tieBreakRank[$_.Candidate] } else { 999 }
        }; Descending = $false},
        @{Expression = 'Candidate'; Descending = $false} |
    Select-Object -First 1
$osVersion = [Environment]::OSVersion.VersionString
$document = [ordered]@{
    Schema = 'zapret2-next/custom-ab/v1'
    CreatedAt = (Get-Date).ToString('o')
    TesterId = $TesterId
    Provider = $Provider
    Region = $Region
    ConnectionType = $ConnectionType
    OS = $osVersion
    Presets = @($Preset)
    Baseline = $baselineName
    Configuration = [ordered]@{
        Game = 'off'
        IPSet = 'loaded'
        Voice = 'off for web A/B; run fresh voice diagnostic separately'
        LoadedIPSetEntries = $ipsetEntryCount
        CurlSupportsHttp3 = $curlSupportsHttp3
    }
    ProxySnapshot = $proxySnapshot
    ProxyContaminationPolicy = 'Configured proxy/VPN/TUN or suspicious proxy log lines mark a run contaminated and exclude it from ranking.'
    RankingPolicy = 'A candidate must pass every mandatory Discord/YouTube HTTP/TLS row with row-level profile/Lua action evidence and no profile-not-found messages. ICMP is never ranked.'
    TieBreakPolicy = 'When mandatory and transport scores tie, prefer CUSTOM SAFE, then ALT12, CUSTOM BALANCED and CUSTOM AGGRESSIVE to minimize intervention.'
    ApplicationEvidencePolicy = 'A HTTP response is transport evidence only. Discord App, updater, Web UI, YouTube playback and Voice require manual fresh-session confirmation.'
    ExecutionError = $executionError
    Warnings = @($warnings)
    Candidates = @($candidateReports)
    Rows = @($allRows)
    Winner = if ($null -ne $winner) { $winner.Candidate } else { $null }
    Recommendation = if ($null -ne $winner) { 'Use only as an experimental candidate after manual Discord/YouTube/Voice confirmation.' } else { 'No automatic recommendation: collect a clean, non-contaminated run first.' }
    Files = [ordered]@{
        Report = $reportPath
        CSV = $csvPath
        JSON = $jsonPath
        ManualAcceptanceCSV = $manualCsvPath
    }
}
$document | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
if ($allRows.Count -gt 0) {
    @($allRows) | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
} else {
    'No web rows were collected.' | Set-Content -LiteralPath $csvPath -Encoding UTF8
}
$manualCandidates = @($baselineName) + @($Preset)
$manualRows = foreach ($candidateName in $manualCandidates) {
    [pscustomobject]@{
        Candidate = $candidateName
        TestedAt = ''
        TesterId = $TesterId
        Provider = $Provider
        Region = $Region
        ConnectionType = $ConnectionType
        FreshCandidateStart = 'not-tested'
        ProxyVpnTunDisabled = 'not-tested'
        DiscordWeb = 'not-tested'
        DiscordAppPastCheckingForUpdates = 'not-tested'
        DiscordUpdaterCompleted = 'not-tested'
        YouTubePlayback = 'not-tested'
        YouTubeQuicObserved = 'not-tested'
        AllowedSitesTested = ''
        AllowedSitesResult = 'not-tested'
        GameLauncherName = ''
        GameLauncherStartOrUpdate = 'not-tested'
        WindowsUpdateConnectivity = 'not-tested'
        VoiceReportZip = ''
        VoiceFreshHandshake = 'not-tested'
        VoiceProfileAction = 'not-tested'
        VoiceTwoWayAudio = 'not-tested'
        VoiceScreenShare = 'not-tested'
        VoicePingMs = ''
        Notes = ''
    }
}
@($manualRows) | Export-Csv -LiteralPath $manualCsvPath -NoTypeInformation -Encoding UTF8

$reportLines = New-Object 'System.Collections.Generic.List[string]'
[void]$reportLines.Add('Zapret 2 NEXT - CUSTOM preset deterministic A/B report')
[void]$reportLines.Add(('Created: {0}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')))
[void]$reportLines.Add(('TesterId: {0}' -f $TesterId))
[void]$reportLines.Add(('Provider: {0}' -f $Provider))
[void]$reportLines.Add(('Region: {0}' -f $Region))
[void]$reportLines.Add(('Connection type: {0}' -f $ConnectionType))
[void]$reportLines.Add(('OS: {0}' -f $osVersion))
[void]$reportLines.Add('')
[void]$reportLines.Add('Test contract')
[void]$reportLines.Add('Direct no-Zapret baseline, ALT12, CUSTOM SAFE, CUSTOM BALANCED and CUSTOM AGGRESSIVE use the same endpoint set.')
[void]$reportLines.Add('Game=off, IPSet=loaded and Voice=off are explicit renderer overrides for the web A/B.')
[void]$reportLines.Add('ICMP rows are retained for diagnostics and excluded from ranking.')
[void]$reportLines.Add(('QUIC probe availability: {0}. Unsupported local curl is reported as unavailable, not as a network failure.' -f $curlSupportsHttp3))
[void]$reportLines.Add('Proxy/VPN/TUN indicators contaminate results; contaminated candidates are not recommended.')
[void]$reportLines.Add('HTTP response transport is not proof of Discord updater/app success; fresh manual confirmation is required.')
[void]$reportLines.Add('A ranked candidate must have a complete mandatory transport pass plus row-level profile ID and real Lua desync evidence.')
[void]$reportLines.Add('Equal transport scores prefer CUSTOM SAFE, then ALT12, CUSTOM BALANCED and CUSTOM AGGRESSIVE to minimize intervention.')
[void]$reportLines.Add('Manual application/safety/voice acceptance is recorded separately in manual-acceptance.csv and is never inferred from curl.')
[void]$reportLines.Add('')
[void]$reportLines.Add('IPSet')
[void]$reportLines.Add(('Non-comment entries in lists\ipset-all.txt: {0}' -f $ipsetEntryCount))
if ($ipsetEntryCount -eq 0) {
    [void]$reportLines.Add('WARNING: this report is not a valid loaded-IPSet acceptance run.')
}
[void]$reportLines.Add('')
[void]$reportLines.Add('Proxy/VPN/TUN snapshot')
if ($null -eq $proxySnapshot) {
    [void]$reportLines.Add('Unavailable because preflight stopped before snapshot.')
} elseif ($proxySnapshot.Configured) {
    foreach ($reason in $proxySnapshot.Reasons) { [void]$reportLines.Add(('CONTAMINATION: {0}' -f $reason)) }
} else {
    [void]$reportLines.Add('No configured proxy/TUN indicator detected by local preflight.')
}
if ($null -ne $proxySnapshot) {
    foreach ($detectionWarning in $proxySnapshot.DetectionWarnings) {
        [void]$reportLines.Add(('DETECTION WARNING: {0}' -f $detectionWarning))
    }
}
[void]$reportLines.Add('')
[void]$reportLines.Add('Candidate comparison')
foreach ($candidate in $candidateReports) {
    $actions = @($candidate.ActionEvidence.ActualLuaActions) -join ','
    [void]$reportLines.Add(('{0}: mandatory {1}/{2}, transport {3}/{4}, startup={5}, contaminated={6}, valid={7}' -f
        $candidate.Candidate, $candidate.MandatoryPassed, $candidate.MandatoryTotal,
        $candidate.TransportPassed, $candidate.TransportTotal, $candidate.StartupOk,
        $candidate.Contaminated, $candidate.ValidForRanking))
    [void]$reportLines.Add(('  Lua actions observed: {0}; profiles matched: {1}; profile-not-found: {3}' -f
        $candidate.ActionEvidence.ActualLuaActionCount, $actions,
        $candidate.ActionEvidence.ProfileMatchCount, $candidate.ActionEvidence.ProfileNotFoundCount))
    [void]$reportLines.Add(('  Mandatory rows with profile/action evidence: {0}/{1}; aggregate evidence valid: {2}' -f
        $candidate.MandatoryEvidencePassed, $candidate.MandatoryTotal, $candidate.AggregateEvidenceValid))
    [void]$reportLines.Add(('  Status: {0}' -f $candidate.Status))
    if (@($candidate.ActionEvidence.SuspiciousProxyLines).Count -gt 0) {
        [void]$reportLines.Add('  Suspicious proxy log lines were retained in results.json.')
    }
}
[void]$reportLines.Add('')
if ($null -ne $winner) {
    [void]$reportLines.Add(('Automatic transport winner: {0}' -f $winner.Candidate))
    [void]$reportLines.Add('This is not a release/default recommendation until fresh manual Discord App/Web/YouTube/Voice checks pass.')
} else {
    [void]$reportLines.Add('Automatic transport winner: none')
    [void]$reportLines.Add('Reason: no candidate had a complete, non-contaminated mandatory transport pass.')
}
[void]$reportLines.Add('')
[void]$reportLines.Add('Required manual follow-up')
[void]$reportLines.Add('1. Fresh Discord restart, new UDP discovery/STUN handshake, profile/action evidence, two-way audio, screen share and voice ping.')
[void]$reportLines.Add('2. Discord Web/App startup, updater completion, YouTube playback and ordinary allowed sites.')
[void]$reportLines.Add('3. Confirm that the tester-selected game launcher and Windows Update check still work; record the exact products tested.')
[void]$reportLines.Add('4. Repeat the winner against ALT12 with the same Game/IPSet/Voice combination.')
[void]$reportLines.Add('5. Repeat on at least two independent networks before any provider or universal claim.')
[void]$reportLines.Add('')
[void]$reportLines.Add(('Results JSON: {0}' -f $jsonPath))
[void]$reportLines.Add(('Web CSV: {0}' -f $csvPath))
[void]$reportLines.Add(('Manual acceptance CSV: {0}' -f $manualCsvPath))
$reportLines | Set-Content -LiteralPath $reportPath -Encoding UTF8

Write-Output ('Results JSON: {0}' -f $jsonPath)
Write-Output ('Web CSV: {0}' -f $csvPath)
Write-Output ('Manual acceptance CSV: {0}' -f $manualCsvPath)
Write-Output ('Report: {0}' -f $reportPath)
if ($executionError) {
    Write-Error $executionError
    exit 1
}
if ($null -eq $winner) {
    exit 2
}
exit 0
