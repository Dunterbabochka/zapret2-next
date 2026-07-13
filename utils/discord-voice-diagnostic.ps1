[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9 _-]+$')]
    [string]$Preset = 'VOICE',

    [ValidateRange(15, 180)]
    [int]$DurationSeconds = 45
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$renderer = Join-Path $PSScriptRoot 'render-config.ps1'
$winws = Join-Path $root 'bin\winws2.exe'
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

function Add-Report([string]$Line = '') {
    $script:report.Add($Line)
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
        Write-Host 'Stopping the existing manual winws2 instance...' -ForegroundColor Yellow
        $oldWinws | Stop-Process -Force
        Start-Sleep -Seconds 1
    }

    New-Item -ItemType Directory -Force -Path $resultDir | Out-Null
    & $renderer -Preset $Preset -Output $configPath -VoiceMode compatible -DebugLog $debugLog | Out-Null

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
    Write-Host 'Diagnostic completed.' -ForegroundColor Green
    Write-Host "Attach this ZIP: $zipPath" -ForegroundColor Cyan
    Write-Host 'The diagnostic winws2 instance has been stopped.' -ForegroundColor Yellow
    exit 0
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
