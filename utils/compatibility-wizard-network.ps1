function Stop-WizardEngine {
    if ($null -eq $script:ownedEngine) { return }
    try {
        $script:ownedEngine.Refresh()
        if (-not $script:ownedEngine.HasExited) {
            Stop-Process -Id $script:ownedEngine.Id -Force -ErrorAction Stop
            $script:ownedEngine.WaitForExit()
        }
    } catch {
        if ($null -ne $script:result) { $script:result.errors += "Could not stop wizard engine PID $($script:ownedEngine.Id): $($_.Exception.Message)" }
    } finally {
        $script:ownedEngine = $null
        Start-Sleep -Milliseconds 500
    }
}

function Stop-ConflictState([object]$State) {
    $script:conflictsStopped = $true
    $actions = @()

    foreach ($savedService in @($State.Services)) {
        $service = Get-Service -Name $savedService.Name -ErrorAction SilentlyContinue
        if ($null -eq $service -or $service.Status -eq 'Stopped') { continue }
        $savedService.StoppedByWizard = $true
        Stop-Service -Name $savedService.Name -Force -ErrorAction Stop
        $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(15))
        $actions += [pscustomobject]@{ Type = 'Service'; Name = $savedService.Name; Action = 'Stopped'; Success = $true; Detail = $savedService.State }
    }

    foreach ($savedProcess in @($State.ManualProcesses)) {
        $process = Get-Process -Id $savedProcess.ProcessId -ErrorAction SilentlyContinue
        if ($null -eq $process) { continue }
        $savedProcess.StoppedByWizard = $true
        Stop-Process -Id $savedProcess.ProcessId -Force -ErrorAction Stop
        $process.WaitForExit()
        $actions += [pscustomobject]@{ Type = 'ManualProcess'; Name = $savedProcess.Name; Action = 'Stopped'; Success = $true; Detail = $savedProcess.CommandLine }
    }
    return $actions
}

function Get-SafeRestartArguments([object]$SavedProcess) {
    $executable = [string]$SavedProcess.ExecutablePath
    $commandLine = [string]$SavedProcess.CommandLine
    if ([string]::IsNullOrWhiteSpace($executable) -or -not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        return [pscustomobject]@{ Safe = $false; Arguments = ''; Reason = 'Executable path is missing or no longer exists.' }
    }
    if ([string]::IsNullOrWhiteSpace($commandLine)) {
        return [pscustomobject]@{ Safe = $false; Arguments = ''; Reason = 'The original command line was unavailable.' }
    }

    $quotedExecutable = '"' + $executable + '"'
    if ($commandLine.StartsWith($quotedExecutable, [StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ Safe = $true; Arguments = $commandLine.Substring($quotedExecutable.Length).Trim(); Reason = '' }
    }
    if ($commandLine.StartsWith($executable, [StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ Safe = $true; Arguments = $commandLine.Substring($executable.Length).Trim(); Reason = '' }
    }
    $leaf = Split-Path $executable -Leaf
    if ($commandLine.StartsWith($leaf, [StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ Safe = $true; Arguments = $commandLine.Substring($leaf.Length).Trim(); Reason = '' }
    }
    return [pscustomobject]@{ Safe = $false; Arguments = ''; Reason = 'The executable prefix could not be separated safely from the original command line.' }
}

function Restore-ConflictState([object]$State) {
    if ($null -eq $State) { return @() }
    $results = @()
    $foldersToOpen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    foreach ($savedService in @($State.Services | Where-Object { $_.WasRunning -and $_.StoppedByWizard })) {
        try {
            $service = Get-Service -Name $savedService.Name -ErrorAction Stop
            if ($service.Status -ne 'Running') {
                Start-Service -Name $savedService.Name -ErrorAction Stop
                $service.WaitForStatus('Running', [TimeSpan]::FromSeconds(15))
            }
            $results += [pscustomobject]@{ Type = 'Service'; Name = $savedService.Name; Action = 'RestoredRunning'; Success = $true; Detail = '' }
        } catch {
            $detail = "Start the service '$($savedService.Name)' manually. $($_.Exception.Message)"
            $results += [pscustomobject]@{ Type = 'Service'; Name = $savedService.Name; Action = 'ManualRestoreRequired'; Success = $false; Detail = $detail }
            Write-Host "[RESTORE ERROR] $detail" -ForegroundColor Red
        }
    }

    foreach ($savedProcess in @($State.ManualProcesses)) {
        $existing = Get-Process -Id $savedProcess.ProcessId -ErrorAction SilentlyContinue
        if ($null -eq $existing -and $savedProcess.ExecutablePath -and $savedProcess.CommandLine) {
            try {
                $existing = @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
                    [string]$_.ExecutablePath -eq [string]$savedProcess.ExecutablePath -and
                    [string]$_.CommandLine -eq [string]$savedProcess.CommandLine
                } | Select-Object -First 1)
                if ($existing.Count) { $existing = $existing[0] } else { $existing = $null }
            } catch { $existing = $null }
        }
        if ($null -ne $existing) {
            $existingPid = if ($existing.PSObject.Properties['Id']) { $existing.Id } else { $existing.ProcessId }
            $results += [pscustomobject]@{ Type = 'ManualProcess'; Name = $savedProcess.Name; Action = 'AlreadyRunning'; Success = $true; Detail = "PID=$existingPid; no duplicate restart attempted" }
            continue
        }

        $restart = Get-SafeRestartArguments $savedProcess
        $directory = if ($savedProcess.ExecutablePath) { Split-Path -Parent $savedProcess.ExecutablePath } else { '' }
        if (-not $restart.Safe) {
            $detail = "Run the original BAT again. Expected executable: '$($savedProcess.ExecutablePath)'. Original command: '$($savedProcess.CommandLine)'. Reason: $($restart.Reason)"
            $results += [pscustomobject]@{ Type = 'ManualProcess'; Name = $savedProcess.Name; Action = 'ManualRestoreRequired'; Success = $false; Detail = $detail }
            Write-Host "[RESTORE REQUIRED] $detail" -ForegroundColor Yellow
            if ($directory -and (Test-Path -LiteralPath $directory -PathType Container)) { [void]$foldersToOpen.Add($directory) }
            continue
        }
        try {
            $start = @{
                FilePath = $savedProcess.ExecutablePath
                WorkingDirectory = $directory
                WindowStyle = 'Hidden'
                PassThru = $true
            }
            if ($restart.Arguments) { $start.ArgumentList = $restart.Arguments }
            $restored = Start-Process @start
            $results += [pscustomobject]@{ Type = 'ManualProcess'; Name = $savedProcess.Name; Action = 'RestartedExactCommand'; Success = $true; Detail = "PID=$($restored.Id); $($savedProcess.CommandLine)" }
        } catch {
            $detail = "Run the original BAT again from '$directory'. Original command: '$($savedProcess.CommandLine)'. Error: $($_.Exception.Message)"
            $results += [pscustomobject]@{ Type = 'ManualProcess'; Name = $savedProcess.Name; Action = 'ManualRestoreRequired'; Success = $false; Detail = $detail }
            Write-Host "[RESTORE REQUIRED] $detail" -ForegroundColor Yellow
            if ($directory -and (Test-Path -LiteralPath $directory -PathType Container)) { [void]$foldersToOpen.Add($directory) }
        }
    }

    foreach ($folder in $foldersToOpen) {
        try { Start-Process -FilePath explorer.exe -ArgumentList $folder | Out-Null } catch {}
    }
    $script:conflictsStopped = $false
    return $results
}

function Start-WizardEngine {
    param(
        [string]$Preset,
        [ValidateSet('loaded', 'none', 'any')]
        [string]$IPSetMode,
        [ValidateSet('off', 'standard', 'compatible')]
        [string]$VoiceMode,
        [string]$Tag
    )

    Stop-WizardEngine
    $safeTag = ConvertTo-SafeName $Tag
    $configDir = Join-Path $script:resultDir 'configs'
    $logDir = Join-Path $script:resultDir 'logs'
    New-Item -ItemType Directory -Force -Path $configDir, $logDir | Out-Null
    $configPath = Join-Path $configDir "$safeTag.txt"
    $dryConfigPath = Join-Path $configDir "$safeTag-dry-run.txt"
    $debugLog = Join-Path $logDir "$safeTag-winws2-debug.log"
    $logPrefix = Join-Path $logDir "$safeTag-winws2"

    & $renderer -Preset $Preset -Output $configPath -GameMode 'off' -IPSetMode $IPSetMode -VoiceMode $VoiceMode -DebugLog $debugLog | Out-Null
    & $renderer -Preset $Preset -Output $dryConfigPath -GameMode 'off' -IPSetMode $IPSetMode -VoiceMode $VoiceMode -DryRun | Out-Null
    & $starter -Config $dryConfigPath -LogPrefix ($logPrefix + '-validate') -Validate
    if ($LASTEXITCODE -ne 0) { throw "winws2 rejected the $Preset/$VoiceMode/$IPSetMode configuration." }

    $stdoutLog = $logPrefix + '.stdout.log'
    $stderrLog = $logPrefix + '.stderr.log'
    $argument = '@"' + $configPath + '"'
    $script:ownedEngine = Start-Process -FilePath $winws -ArgumentList $argument `
        -WorkingDirectory (Split-Path -Parent $winws) -WindowStyle Hidden `
        -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog -PassThru
    Start-Sleep -Seconds 2
    $script:ownedEngine.Refresh()
    if ($script:ownedEngine.HasExited) {
        $output = @()
        if (Test-Path -LiteralPath $stderrLog) { $output += Get-Content -LiteralPath $stderrLog }
        if (Test-Path -LiteralPath $stdoutLog) { $output += Get-Content -LiteralPath $stdoutLog }
        throw "winws2 exited during startup: $($output -join ' | ')"
    }

    $run = [pscustomobject]@{
        StartedAtUtc = [DateTime]::UtcNow.ToString('o')
        Tag = $Tag
        Preset = $Preset
        GameMode = 'off'
        IPSetMode = $IPSetMode
        VoiceMode = $VoiceMode
        ProcessId = $script:ownedEngine.Id
        ConfigPath = $configPath
        DebugLog = $debugLog
        StdoutLog = $stdoutLog
        StderrLog = $stderrLog
    }
    $script:result.engineRuns += $run
    return $run
}

function Invoke-CurlEndpoint {
    param(
        [object]$Target,
        [string]$Phase,
        [string]$Preset,
        [int]$Pass,
        [string]$IPSetMode,
        [string]$VoiceMode
    )

    $format = 'http=%{http_code};time=%{time_total};ip=%{remote_ip};port=%{remote_port};url=%{url_effective}'
    $arguments = "-L -sS --noproxy * --connect-timeout $TimeoutSeconds --max-time $TimeoutSeconds -o NUL -A Zapret2NEXT-CompatibilityWizard/$wizardVersion -w $format `"$($Target.Url)`""
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $script:curlPath
    $startInfo.Arguments = $arguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $startedAt = [DateTime]::UtcNow
    [void]$process.Start()
    $processId = $process.Id
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $completed = $process.WaitForExit(($TimeoutSeconds + 5) * 1000)
    if (-not $completed) {
        try { $process.Kill() } catch {}
        $process.WaitForExit()
    }
    $stdout = $stdoutTask.Result.Trim()
    $stderr = $stderrTask.Result.Trim()
    $exitCode = if ($completed) { $process.ExitCode } else { 28 }
    $process.Dispose()

    $httpCode = '000'
    $remoteIP = ''
    $remotePort = ''
    $effectiveUrl = ''
    $durationMs = [Math]::Round(([DateTime]::UtcNow - $startedAt).TotalMilliseconds, 2)
    if ($stdout -match 'http=(?<http>[^;]*);time=(?<time>[^;]*);ip=(?<ip>[^;]*);port=(?<port>[^;]*);url=(?<url>.*)$') {
        $httpCode = $matches.http
        $remoteIP = $matches.ip
        $remotePort = $matches.port
        $effectiveUrl = $matches.url
        [double]$seconds = 0
        if ([double]::TryParse($matches.time, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$seconds)) {
            $durationMs = [Math]::Round($seconds * 1000, 2)
        }
    }
    $success = $completed -and $exitCode -eq 0 -and $httpCode -match '^\d{3}$' -and $httpCode -ne '000'
    if ($stderr.Length -gt 1000) { $stderr = $stderr.Substring(0, 1000) }

    return [pscustomobject]@{
        TimestampUtc = $startedAt.ToString('o')
        Phase = $Phase
        Preset = $Preset
        Pass = $Pass
        IPSetMode = $IPSetMode
        VoiceMode = $VoiceMode
        Target = $Target.Name
        Product = $Target.Product
        Mandatory = [bool]$Target.Mandatory
        Url = $Target.Url
        Success = [bool]$success
        CurlExitCode = $exitCode
        HttpCode = $httpCode
        DurationMs = $durationMs
        RemoteIP = $remoteIP
        RemotePort = $remotePort
        EffectiveUrl = $effectiveUrl
        ProcessName = 'curl.exe'
        ProcessId = $processId
        Error = $stderr
    }
}

function Invoke-WebPass {
    param(
        [string]$Preset,
        [int]$Pass,
        [string]$IPSetMode,
        [string]$VoiceMode,
        [string]$Phase
    )

    Write-Host "Web pass: phase=$Phase preset=$Preset pass=$Pass ipset=$IPSetMode voice=$VoiceMode" -ForegroundColor Cyan
    $rows = @()
    try {
        Start-WizardEngine -Preset $Preset -IPSetMode $IPSetMode -VoiceMode $VoiceMode -Tag "$Phase-$Preset-pass$Pass-$IPSetMode-$VoiceMode" | Out-Null
        foreach ($target in $script:targets) {
            $row = Invoke-CurlEndpoint -Target $target -Phase $Phase -Preset $Preset -Pass $Pass -IPSetMode $IPSetMode -VoiceMode $VoiceMode
            $rows += $row
            $script:result.webResults += $row
            $color = if ($row.Success) { 'Green' } else { 'Red' }
            Write-Host ("  {0,-24} HTTP={1} {2}ms {3}:{4}" -f $row.Target, $row.HttpCode, $row.DurationMs, $row.RemoteIP, $row.RemotePort) -ForegroundColor $color
        }
    } finally {
        Stop-WizardEngine
    }
    return $rows
}

function Get-DiscordNetworkObservations {
    param([string]$Phase, [string]$VoiceMode)

    $observations = @()
    foreach ($process in @(Get-Process -Name Discord -ErrorAction SilentlyContinue)) {
        $path = try { $process.Path } catch { '' }
        $observations += [pscustomobject]@{
            TimestampUtc = [DateTime]::UtcNow.ToString('o'); Phase = $Phase; VoiceMode = $VoiceMode
            ProcessName = $process.ProcessName; ProcessId = $process.Id; ExecutablePath = $path
            Protocol = 'Process'; LocalAddress = ''; LocalPort = ''; RemoteAddress = ''; RemotePort = ''; State = ''
        }
        foreach ($connection in @(Get-NetTCPConnection -OwningProcess $process.Id -ErrorAction SilentlyContinue)) {
            $observations += [pscustomobject]@{
                TimestampUtc = [DateTime]::UtcNow.ToString('o'); Phase = $Phase; VoiceMode = $VoiceMode
                ProcessName = $process.ProcessName; ProcessId = $process.Id; ExecutablePath = $path
                Protocol = 'TCP'; LocalAddress = $connection.LocalAddress; LocalPort = $connection.LocalPort
                RemoteAddress = $connection.RemoteAddress; RemotePort = $connection.RemotePort; State = $connection.State
            }
        }
        foreach ($endpoint in @(Get-NetUDPEndpoint -OwningProcess $process.Id -ErrorAction SilentlyContinue)) {
            $observations += [pscustomobject]@{
                TimestampUtc = [DateTime]::UtcNow.ToString('o'); Phase = $Phase; VoiceMode = $VoiceMode
                ProcessName = $process.ProcessName; ProcessId = $process.Id; ExecutablePath = $path
                Protocol = 'UDP'; LocalAddress = $endpoint.LocalAddress; LocalPort = $endpoint.LocalPort
                RemoteAddress = ''; RemotePort = ''; State = ''
            }
        }
    }
    return $observations
}

function Start-PktMonCapture([string]$Tag) {
    if ($script:pktMonOwned) { throw 'The wizard already owns a PktMon session.' }
    $captureDir = Join-Path $script:resultDir 'pktmon'
    New-Item -ItemType Directory -Force -Path $captureDir | Out-Null
    $safeTag = ConvertTo-SafeName $Tag
    $state = [pscustomobject]@{
        Tag = $safeTag
        EtlPath = Join-Path $captureDir "$safeTag.etl"
        AllMetadataPath = Join-Path $captureDir "$safeTag-all-metadata.tmp.txt"
        DiscordMetadataPath = Join-Path $captureDir "$safeTag-discord-metadata.txt"
        CountersPath = Join-Path $captureDir "$safeTag-counters.txt"
        StatsPath = Join-Path $captureDir "$safeTag-stats.txt"
    }
    $output = @(& pktmon.exe start --capture --comp nics --pkt-size 64 --flags 0x012 --file-name $state.EtlPath --file-size 16 --log-mode circular 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Could not start PktMon: $(($output | Out-String).Trim())" }
    $script:pktMonOwned = $true
    $script:pktMonState = $state
    return $state
}

function Stop-PktMonCapture {
    param([int[]]$DiscordLocalPorts = @())

    $state = $script:pktMonState
    if ($null -eq $state) { return $null }
    try {
        if ($script:pktMonOwned) {
            & pktmon.exe counters 2>&1 | Out-File -LiteralPath $state.CountersPath -Encoding utf8
            & pktmon.exe stop 2>&1 | Out-Null
            $script:pktMonOwned = $false
        }
        if (Test-Path -LiteralPath $state.EtlPath -PathType Leaf) {
            & pktmon.exe etl2txt $state.EtlPath --out $state.AllMetadataPath --brief --timestamp 2>&1 | Out-Null
            & pktmon.exe etl2txt $state.EtlPath --stats 2>&1 | Out-File -LiteralPath $state.StatsPath -Encoding utf8
        }
        $matching = @()
        if ((Test-Path -LiteralPath $state.AllMetadataPath -PathType Leaf) -and $DiscordLocalPorts.Count) {
            $escaped = @($DiscordLocalPorts | Sort-Object -Unique | ForEach-Object { [regex]::Escape([string]$_) })
            $pattern = '(?<!\d)(?:' + ($escaped -join '|') + ')(?!\d)'
            $matching = @(Get-Content -LiteralPath $state.AllMetadataPath | Where-Object { $_ -match $pattern })
        }
        if ($matching.Count) {
            $matching | Set-Content -LiteralPath $state.DiscordMetadataPath -Encoding utf8
        } else {
            @('No PktMon metadata matched Discord-owned UDP local ports.') | Set-Content -LiteralPath $state.DiscordMetadataPath -Encoding utf8
        }
    } finally {
        Remove-Item -LiteralPath $state.EtlPath, $state.AllMetadataPath -Force -ErrorAction SilentlyContinue
        $script:pktMonState = $null
    }
    return [pscustomobject]@{
        Tag = $state.Tag
        DiscordMetadataPath = $state.DiscordMetadataPath
        CountersPath = $state.CountersPath
        StatsPath = $state.StatsPath
        RawEtlIncluded = $false
    }
}

function Stop-WizardOwnedResources {
    if ($script:pktMonOwned -or $null -ne $script:pktMonState) {
        try { Stop-PktMonCapture | Out-Null } catch {
            try { & pktmon.exe stop 2>&1 | Out-Null } catch {}
            $script:pktMonOwned = $false
            $script:pktMonState = $null
        }
    }
    Stop-WizardEngine
}
