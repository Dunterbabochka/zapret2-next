[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9 _-]+$')]
    [string]$Preset = 'VOICE',

    [ValidateRange(15, 180)]
    [int]$DurationSeconds = 45,

    [switch]$AllowEmptyIPSet,

    [switch]$AllowContaminatedNetwork
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$renderer = Join-Path $PSScriptRoot 'render-config.ps1'
$winws = Join-Path $root 'bin\winws2.exe'
$ipsetPath = Join-Path $root 'lists\ipset-all.txt'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$resultDir = Join-Path $root "runtime\voice-diagnostic-$stamp"
$configPath = Join-Path $resultDir 'VOICE-debug.txt'
$debugLog = Join-Path $resultDir 'winws2-debug.log'
$debugRelevant = Join-Path $resultDir 'winws2-debug-relevant.log'
$stdoutLog = Join-Path $resultDir 'winws2.stdout.log'
$stderrLog = Join-Path $resultDir 'winws2.stderr.log'
$etlPath = Join-Path $resultDir 'packets.etl'
$packetText = Join-Path $resultDir 'packets-brief.txt'
$voicePacketText = Join-Path $resultDir 'packets-discord-ports.txt'
$counterText = Join-Path $resultDir 'pktmon-counters.txt'
$statsText = Join-Path $resultDir 'pktmon-stats.txt'
$reportPath = Join-Path $resultDir 'REPORT.txt'
$zipPath = "$resultDir.zip"

$report = [Collections.Generic.List[string]]::new()
$endpointKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$endpointRows = [Collections.Generic.List[object]]::new()
$discordPids = [Collections.Generic.HashSet[int]]::new()
$localPorts = [Collections.Generic.HashSet[int]]::new()
$pktmonStarted = $false
$pktmonFilterOwned = $false
$winwsProcess = $null
$pingMs = $null
$heardOtherParticipant = $false
$otherParticipantHeardTester = $false
$screenShare = 'not-tested'
$freshHandshakeObserved = $false
$strategyActionObserved = $false
$twoWayAudioConfirmed = $false
$rawTwoWayAudioObserved = $false
$networkContaminated = $false
$networkContaminationReasons = @()
$ipsetEntryCount = if (Test-Path -LiteralPath $ipsetPath -PathType Leaf) {
    @((Get-Content -LiteralPath $ipsetPath) | Where-Object { $_ -notmatch '^\s*(?:#|$)' }).Count
} else {
    0
}

function Get-NetworkContaminationReasons {
    $reasons = [Collections.Generic.List[string]]::new()
    foreach ($name in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy')) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            [void]$reasons.Add(('Environment proxy is set: {0}' -f $name))
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
        Write-Warning 'Could not read WinINET proxy state; this source was not used to mark contamination.'
    }
    try {
        $winHttp = (& netsh winhttp show proxy 2>&1 | Out-String).Trim()
        if ($winHttp -match '(?i)direct access|no proxy|\u043f\u0440\u044f\u043c\u043e\u0439\s+\u0434\u043e\u0441\u0442\u0443\u043f|\u0431\u0435\u0437\s+\u043f\u0440\u043e\u043a\u0441\u0438') {
            # Locale-independent direct-access result (English or Russian).
        } elseif ($winHttp -match '(?i)proxy|\u043f\u0440\u043e\u043a\u0441\u0438|socks|https?://|\b(?:\d{1,3}\.){3}\d{1,3}:\d+\b') {
            [void]$reasons.Add('WinHTTP reports a configured proxy')
        } else {
            Write-Warning 'Could not determine WinHTTP proxy state from localized netsh output; this source was not used to mark contamination.'
        }
    } catch {
        Write-Warning 'Could not read WinHTTP proxy state; this source was not used to mark contamination.'
    }
    try {
        foreach ($adapter in @(Get-NetAdapter -ErrorAction Stop | Where-Object {
            $_.Status -eq 'Up' -and
            $_.Name -notmatch '(?i)tailscale|hyper-v|wsl|loopback' -and
            ($_.Name -match '(?i)vpn|tun|warp|clash|wireguard|openvpn|proton|outline|sing-box|v2ray' -or
             $_.InterfaceDescription -match '(?i)vpn|tun|warp|clash|wireguard|openvpn|proton|outline|sing-box|v2ray')
        })) {
            [void]$reasons.Add(('Suspicious active adapter: {0}' -f $adapter.Name))
        }
    } catch {
        Write-Warning 'Could not inspect active adapters; adapter-based VPN/TUN detection was skipped.'
    }
    return @($reasons)
}

function Add-Report([string]$Line = '') {
    $script:report.Add($Line)
}

function Read-DiagnosticYesNo([string]$Prompt) {
    while ($true) {
        $value = (Read-Host "$Prompt [y/n]").Trim().ToLowerInvariant()
        if ($value -in @('y', 'yes')) { return $true }
        if ($value -in @('n', 'no', '')) { return $false }
        Write-Host 'Enter y or n.' -ForegroundColor Yellow
    }
}

function Read-DiagnosticPing {
    while ($true) {
        $value = (Read-Host 'Discord voice ping in ms (number or unknown)').Trim().ToLowerInvariant()
        if ($value -in @('', 'unknown', 'n/a')) { return $null }
        if ($value -match '^\d{1,5}$') { return [int]$value }
        Write-Host 'Enter a number or unknown.' -ForegroundColor Yellow
    }
}

function Stop-OwnedResources {
    if ($script:pktmonStarted) {
        & pktmon counters 2>&1 | Out-File -LiteralPath $counterText -Encoding utf8
        & pktmon stop 2>&1 | Out-Null
        $script:pktmonStarted = $false
    }
    if ($script:pktmonFilterOwned) {
        & pktmon filter remove 2>&1 | Out-Null
        $script:pktmonFilterOwned = $false
    }
    if ($null -ne $script:winwsProcess) {
        try {
            $script:winwsProcess.Refresh()
            if (-not $script:winwsProcess.HasExited) {
                Stop-Process -Id $script:winwsProcess.Id -Force
                $script:winwsProcess.WaitForExit()
            }
        } catch {}
    }
}

try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run diagnose discord voice.bat and approve the Administrator prompt.'
    }

    foreach ($path in @($renderer, $winws, (Join-Path $root "presets\$Preset.txt.in"))) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Required file is missing: $path"
        }
    }
    if ($ipsetEntryCount -eq 0 -and -not $AllowEmptyIPSet) {
        throw 'IPSet=loaded voice acceptance requires a populated lists\ipset-all.txt. Update the list first; -AllowEmptyIPSet is diagnostic-only.'
    }
    $networkContaminationReasons = @(Get-NetworkContaminationReasons)
    $networkContaminated = $networkContaminationReasons.Count -gt 0
    if ($networkContaminated) {
        Write-Warning ('Proxy/VPN/TUN contamination detected: {0}. Continuing diagnostic; this run cannot be acceptance evidence.' -f ($networkContaminationReasons -join '; '))
    }

    $service = Get-Service -Name winws2 -ErrorAction SilentlyContinue
    if ($null -ne $service -and $service.Status -ne 'Stopped') {
        throw 'The winws2 service is running. Stop it in service.bat before this diagnostic.'
    }
    if (Get-Process -Name winws -ErrorAction SilentlyContinue) {
        throw 'Legacy winws.exe is running. Stop the old Zapret bundle first.'
    }

    $discordBefore = @(Get-Process -Name Discord -ErrorAction SilentlyContinue)
    if ($discordBefore.Count -gt 0) {
        Write-Host ''
        Write-Host 'Fully close Discord, including its tray icon.' -ForegroundColor Yellow
        Read-Host 'Press Enter after Discord has closed'
        if (Get-Process -Name Discord -ErrorAction SilentlyContinue) {
            throw 'Discord is still running. Close every Discord process and retry.'
        }
    }

    $oldWinws = @(Get-Process -Name winws2 -ErrorAction SilentlyContinue)
    if ($oldWinws.Count -gt 0) {
        throw 'A manual winws2 instance is already running. Stop it explicitly before this diagnostic; its state will not be changed automatically.'
    }

    New-Item -ItemType Directory -Force -Path $resultDir | Out-Null
    & $renderer -Preset $Preset -Output $configPath -GameMode off -IPSetMode loaded -VoiceMode compatible -DebugLog $debugLog | Out-Null

    Write-Host ''
    Write-Host "Starting winws2 with preset $Preset and debug logging..." -ForegroundColor Cyan
    $argument = '@"' + $configPath + '"'
    $startArgs = @{
        FilePath = $winws
        ArgumentList = $argument
        WorkingDirectory = (Split-Path -Parent $winws)
        WindowStyle = 'Hidden'
        RedirectStandardOutput = $stdoutLog
        RedirectStandardError = $stderrLog
        PassThru = $true
    }
    $winwsProcess = Start-Process @startArgs
    Start-Sleep -Seconds 3
    $winwsProcess.Refresh()
    if ($winwsProcess.HasExited) {
        $engineOutput = @()
        if (Test-Path -LiteralPath $stderrLog) { $engineOutput += Get-Content -LiteralPath $stderrLog }
        if (Test-Path -LiteralPath $stdoutLog) { $engineOutput += Get-Content -LiteralPath $stdoutLog }
        throw "winws2 exited during startup: $($engineOutput -join ' | ')"
    }

    # PktMon records only the first 64 bytes and the generated text never includes a hex dump.
    # The raw ETL is deleted after producing address/port metadata.
    & pktmon filter remove 2>&1 | Out-Null
    & pktmon filter add Zapret2NextVoiceUDP -t UDP 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the PktMon UDP filter.' }
    $pktmonFilterOwned = $true
    & pktmon start --capture --comp nics --pkt-size 64 --flags 0x012 --file-name $etlPath --file-size 32 --log-mode circular 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not start PktMon capture.' }
    $pktmonStarted = $true

    Write-Host ''
    Write-Host 'NOW start Discord and join the voice channel.' -ForegroundColor Green
    Write-Host "Keep the voice connection open for $DurationSeconds seconds." -ForegroundColor Green
    Write-Host 'It is useful to open Discord Voice Debug while the timer runs.' -ForegroundColor DarkGray
    Write-Host ''

    $startedAt = Get-Date
    for ($second = 1; $second -le $DurationSeconds; $second++) {
        $discordNow = @(Get-Process -Name Discord -ErrorAction SilentlyContinue)
        foreach ($process in $discordNow) {
            [void]$discordPids.Add($process.Id)
            $endpoints = @(Get-NetUDPEndpoint -OwningProcess $process.Id -ErrorAction SilentlyContinue)
            foreach ($endpoint in $endpoints) {
                [void]$localPorts.Add([int]$endpoint.LocalPort)
                $key = "$($endpoint.LocalAddress)|$($endpoint.LocalPort)|$($endpoint.OwningProcess)"
                if ($endpointKeys.Add($key)) {
                    $endpointRows.Add([pscustomobject]@{
                        FirstSeen = (Get-Date).ToString('HH:mm:ss.fff')
                        PID = $endpoint.OwningProcess
                        LocalAddress = $endpoint.LocalAddress
                        LocalPort = $endpoint.LocalPort
                    })
                }
            }
        }
        Write-Progress -Activity 'Discord voice diagnostic' -Status "$second / $DurationSeconds seconds" -PercentComplete (($second / $DurationSeconds) * 100)
        Start-Sleep -Seconds 1
    }
    Write-Progress -Activity 'Discord voice diagnostic' -Completed

    Write-Host ''
    Write-Host 'Manual voice confirmation' -ForegroundColor Cyan
    Write-Host 'Keep the fresh Discord call active while answering these questions.' -ForegroundColor Yellow
    $pingMs = Read-DiagnosticPing
    $heardOtherParticipant = Read-DiagnosticYesNo 'Could you hear the other participant?'
    $otherParticipantHeardTester = Read-DiagnosticYesNo 'Could the other participant hear you?'
    $screenShare = if (Read-DiagnosticYesNo 'Did screen share work?') { 'yes' } else { 'no' }

    & pktmon counters 2>&1 | Out-File -LiteralPath $counterText -Encoding utf8
    & pktmon stop 2>&1 | Out-Null
    $pktmonStarted = $false
    & pktmon filter remove 2>&1 | Out-Null
    $pktmonFilterOwned = $false

    $winwsProcess.Refresh()
    if (-not $winwsProcess.HasExited) {
        Stop-Process -Id $winwsProcess.Id -Force
        $winwsProcess.WaitForExit()
    }

    & pktmon etl2txt $etlPath --out $packetText --brief --timestamp 2>&1 | Out-Null
    & pktmon etl2txt $etlPath --stats 2>&1 | Out-File -LiteralPath $statsText -Encoding utf8

    $voiceLines = @()
    if ((Test-Path -LiteralPath $packetText) -and $localPorts.Count -gt 0) {
        $escapedPorts = @($localPorts | Sort-Object | ForEach-Object { [regex]::Escape([string]$_) })
        $portPattern = '(?<!\d)(?:' + ($escapedPorts -join '|') + ')(?!\d)'
        $voiceLines = @(Get-Content -LiteralPath $packetText | Where-Object { $_ -match $portPattern })
    }
    if ($voiceLines.Count -gt 5000) {
        $voiceLines = @($voiceLines | Select-Object -First 5000)
    }
    if ($voiceLines.Count -eq 0) {
        @('No PktMon lines matched the UDP ports owned by Discord.') | Set-Content -LiteralPath $voicePacketText -Encoding utf8
    } else {
        $voiceLines | Set-Content -LiteralPath $voicePacketText -Encoding utf8
    }

    $debugText = if (Test-Path -LiteralPath $debugLog) {
        Get-Content -LiteralPath $debugLog -Raw
    } else {
        ''
    }
    $voiceProfileIds = @(
        [regex]::Matches($debugText, 'profile\s+(\d+).*payload_type=.*(?:discord_ip_discovery|stun)') |
            ForEach-Object { $_.Groups[1].Value } |
            Sort-Object -Unique
    )
    foreach ($profileId in $voiceProfileIds) {
        $profileMatched = $debugText -match ('desync profile ' + [regex]::Escape($profileId) + ' \((?!no_action\))[^)]*\) matches')
        if ($profileMatched) {
            $freshHandshakeObserved = $true
            if ($debugText -match ("\* lua 'fake_" + [regex]::Escape($profileId) + '_')) {
                $strategyActionObserved = $true
            }
        }
    }
    $rawTwoWayAudioObserved = $heardOtherParticipant -and $otherParticipantHeardTester -and
        $freshHandshakeObserved -and $strategyActionObserved
    $acceptanceEligible = $ipsetEntryCount -gt 0 -and -not $networkContaminated
    $twoWayAudioConfirmed = $rawTwoWayAudioObserved -and $acceptanceEligible
    $interestingDebug = @()
    if ($debugText) {
        $interestingDebug = @($debugText -split "`r?`n" | Where-Object {
            $_ -match 'discord|stun|l7proto=|desync profile|using cached|udp_in|udp_out|lua fake'
        })
    }
    if ($interestingDebug.Count -gt 4000) {
        $interestingDebug = @($interestingDebug | Select-Object -Last 4000)
    }
    if ($interestingDebug.Count -eq 0) {
        @('No Discord/STUN/profile lines were found in the winws2 debug log.') | Set-Content -LiteralPath $debugRelevant -Encoding utf8
    } else {
        $interestingDebug | Set-Content -LiteralPath $debugRelevant -Encoding utf8
    }

    Add-Report 'Zapret 2 NEXT - Discord voice diagnostic'
    Add-Report "Time: $($startedAt.ToString('yyyy-MM-dd HH:mm:ss zzz'))"
    Add-Report "Preset: $Preset"
    Add-Report "Capture seconds: $DurationSeconds"
    Add-Report "OS: $([Environment]::OSVersion.VersionString)"
    Add-Report "LoadedIPSetEntries: $ipsetEntryCount"
    Add-Report "NetworkContaminated: $networkContaminated"
    Add-Report "AcceptanceEligible: $acceptanceEligible"
    foreach ($reason in $networkContaminationReasons) { Add-Report "CONTAMINATION: $reason" }
    Add-Report ''
    Add-Report 'Discord process and socket observations'
    Add-Report "Observed Discord PIDs: $(@($discordPids | Sort-Object) -join ', ')"
    Add-Report "Observed Discord UDP local ports: $(@($localPorts | Sort-Object) -join ', ')"
    Add-Report "Matching PktMon metadata lines: $($voiceLines.Count)"
    Add-Report ''
    if ($endpointRows.Count -eq 0) {
        Add-Report 'No Discord-owned UDP endpoint was observed.'
    } else {
        foreach ($row in $endpointRows | Sort-Object LocalPort, PID) {
            Add-Report ("{0} PID={1} Local={2}:{3}" -f $row.FirstSeen, $row.PID, $row.LocalAddress, $row.LocalPort)
        }
    }
    Add-Report ''
    Add-Report 'winws2 recognition counters'
    Add-Report "discord_ip_discovery mentions: $([regex]::Matches($debugText, 'discord_ip_discovery').Count)"
    Add-Report "l7proto=discord mentions: $([regex]::Matches($debugText, 'l7proto=discord').Count)"
    Add-Report "l7proto=stun mentions: $([regex]::Matches($debugText, 'l7proto=stun').Count)"
    Add-Report "matching profile messages: $([regex]::Matches($debugText, 'desync profile [0-9]+ .* matches').Count)"
    Add-Report "profile-not-found messages: $([regex]::Matches($debugText, 'desync profile not found|matching desync profile not found').Count)"
    Add-Report ''
    Add-Report 'Manual voice confirmation'
    Add-Report "PingMs: $(if ($null -eq $pingMs) { 'unknown' } else { $pingMs })"
    Add-Report "HeardOtherParticipant: $heardOtherParticipant"
    Add-Report "OtherParticipantHeardTester: $otherParticipantHeardTester"
    Add-Report "ScreenShare: $screenShare"
    Add-Report "FreshHandshakeObserved: $freshHandshakeObserved"
    Add-Report "StrategyActionObserved: $strategyActionObserved"
    Add-Report "RawTwoWayAudioObserved: $rawTwoWayAudioObserved"
    Add-Report "TwoWayAudioConfirmed: $twoWayAudioConfirmed"
    Add-Report ''
    Add-Report 'Files to inspect'
    Add-Report 'winws2-debug-relevant.log - profile and protocol decisions'
    Add-Report 'packets-discord-ports.txt - packet headers for Discord-owned local UDP ports'
    Add-Report 'pktmon-counters.txt and pktmon-stats.txt - packet/drop counters'
    Add-Report ''
    Add-Report 'Privacy'
    Add-Report 'The ZIP contains IP addresses, ports, process IDs, timestamps and local paths.'
    Add-Report 'It does not include packet payload dumps. The raw ETL is deleted.'
    $report | Set-Content -LiteralPath $reportPath -Encoding utf8

    Remove-Item -LiteralPath $etlPath, $packetText -Force -ErrorAction SilentlyContinue
    $zipFiles = @(
        $reportPath, $debugRelevant, $voicePacketText, $counterText, $statsText,
        $stdoutLog, $stderrLog, $configPath
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
    Compress-Archive -LiteralPath $zipFiles -DestinationPath $zipPath -CompressionLevel Optimal

    Write-Host ''
    if ($twoWayAudioConfirmed) {
        Write-Host ('Diagnostic completed: {0} voice evidence is confirmed.' -f $Preset) -ForegroundColor Green
    } else {
        Write-Host ('Diagnostic completed, but {0} voice evidence is NOT confirmed.' -f $Preset) -ForegroundColor Red
    }
    Write-Host "Attach this ZIP: $zipPath" -ForegroundColor Cyan
    Write-Host 'The diagnostic winws2 instance has been stopped.' -ForegroundColor Yellow
    if ($twoWayAudioConfirmed) { exit 0 } else { exit 2 }
} catch {
    Write-Host ''
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    if (Test-Path -LiteralPath $resultDir) {
        Write-Host "Partial logs: $resultDir" -ForegroundColor DarkYellow
    }
    exit 1
} finally {
    Stop-OwnedResources
}
