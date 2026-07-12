param(
    [string[]]$Preset,
    [ValidateSet('standard', 'dpi', 'both')]
    [string]$Suite = 'standard',
    [ValidateRange(1, 30)]
    [int]$TimeoutSeconds = 5,
    [ValidateRange(1, 32)]
    [int]$MaxParallel = 8,
    [switch]$NonInteractive
)

$suiteWasSpecified = $PSBoundParameters.ContainsKey('Suite')
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$renderer = Join-Path $PSScriptRoot 'render-config.ps1'
$starter = Join-Path $PSScriptRoot 'invoke-winws.ps1'
$winws = Join-Path $root 'bin\winws2.exe'
$resultsDir = Join-Path $root 'runtime\test-results'
New-Item -ItemType Directory -Force -Path $resultsDir | Out-Null

try { $Host.UI.RawUI.WindowTitle = 'Zapret 2 NEXT - Preset tests' } catch {}
if (-not $NonInteractive) { Clear-Host }
Write-Host 'Zapret 2 NEXT test environment' -ForegroundColor Cyan
Write-Host '----------------------------------------' -ForegroundColor DarkCyan

$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host '[ERROR] Run tests as Administrator.' -ForegroundColor Red
    exit 1
}
Write-Host '[OK] Administrator rights' -ForegroundColor Green
if (-not (Test-Path $winws)) {
    Write-Host "[ERROR] winws2.exe not found: $winws" -ForegroundColor Red
    exit 1
}
Write-Host '[OK] winws2.exe' -ForegroundColor Green
if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
    Write-Host '[ERROR] curl.exe is required.' -ForegroundColor Red
    exit 1
}
Write-Host '[OK] curl.exe' -ForegroundColor Green

$presetFiles = Get-ChildItem (Join-Path $root 'presets') -Filter '*.txt.in' |
    Where-Object { $_.BaseName -notlike '_*' } |
    Sort-Object { [regex]::Replace($_.Name, '(\d+)', { $args[0].Value.PadLeft(8, '0') }) }
if ($Preset) {
    $wanted = @($Preset | ForEach-Object { $_.ToLowerInvariant() })
    $presetFiles = @($presetFiles | Where-Object { $wanted -contains (($_.BaseName -replace '\.txt$', '').ToLowerInvariant()) })
}
if (-not $presetFiles) { throw 'No matching presets found.' }

function Stop-Winws2 {
    Get-Process winws2 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
}

function Invoke-WebChecks {
    param(
        [array]$Targets,
        [int]$Timeout,
        [int]$Parallel
    )

    $pool = [RunspaceFactory]::CreateRunspacePool(1, $Parallel)
    $pool.Open()
    $worker = {
        param($Target, $TimeoutSeconds)

        $checks = @()
        if ($Target.Url) {
            $tests = @(
                @{ Name='HTTP1.1'; Args=@('--http1.1') },
                @{ Name='TLS1.2'; Args=@('--tlsv1.2','--tls-max','1.2') },
                @{ Name='TLS1.3'; Args=@('--tlsv1.3','--tls-max','1.3') }
            )
            foreach ($test in $tests) {
                $previousErrorAction = $ErrorActionPreference
                try {
                    $ErrorActionPreference = 'Continue'
                    $output = & curl.exe -I -sS --max-time $TimeoutSeconds -o NUL -w '%{http_code}' @($test.Args) $Target.Url 2>$null
                    $curlExitCode = $LASTEXITCODE
                } finally {
                    $ErrorActionPreference = $previousErrorAction
                }
                $code = ($output | Out-String).Trim()
                $ok = $curlExitCode -eq 0 -and $code -match '^\d{3}$' -and $code -ne '000'
                $checks += [pscustomobject]@{
                    Name = $test.Name
                    Status = if ($ok) { 'OK' } else { 'FAIL' }
                    Success = $ok
                    Detail = if ($ok) { $code } else { "curl $curlExitCode / HTTP $(if ($code) { $code } else { 'none' })" }
                }
            }
        }

        $pingStatus = 'n/a'
        $pingSuccess = $null
        if ($Target.PingTarget) {
            $pingClient = [Net.NetworkInformation.Ping]::new()
            try {
                $reply = $pingClient.Send($Target.PingTarget, [Math]::Max(1000, $TimeoutSeconds * 1000))
                if ($reply.Status -eq [Net.NetworkInformation.IPStatus]::Success) {
                    $pingStatus = "$($reply.RoundtripTime)ms"
                    $pingSuccess = $true
                } else {
                    $pingStatus = $reply.Status.ToString()
                    $pingSuccess = $false
                }
            } catch {
                $pingStatus = 'Timeout'
                $pingSuccess = $false
            } finally {
                $pingClient.Dispose()
            }
        }

        [pscustomobject]@{
            Name = $Target.Name
            Url = $Target.Url
            Checks = $checks
            PingStatus = $pingStatus
            PingSuccess = $pingSuccess
        }
    }

    $jobs = @()
    foreach ($target in $Targets) {
        $powershell = [PowerShell]::Create().AddScript($worker)
        [void]$powershell.AddArgument($target)
        [void]$powershell.AddArgument($Timeout)
        $powershell.RunspacePool = $pool
        $jobs += [pscustomobject]@{
            PowerShell = $powershell
            Handle = $powershell.BeginInvoke()
            Name = $target.Name
        }
    }

    $results = @()
    try {
        foreach ($job in $jobs) {
            try {
                $result = @($job.PowerShell.EndInvoke($job.Handle)) | Select-Object -First 1
                if ($result) { $results += $result }
            } catch {
                $results += [pscustomobject]@{
                    Name = $job.Name
                    Url = $null
                    Checks = @([pscustomobject]@{ Name='RUNSPACE'; Status='FAIL'; Success=$false; Detail=$_.Exception.Message })
                    PingStatus = 'Timeout'
                    PingSuccess = $false
                }
            } finally {
                $job.PowerShell.Dispose()
            }
        }
    } finally {
        $pool.Close()
        $pool.Dispose()
    }

    $maxNameLength = [Math]::Max(12, [int](($results | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum))
    $rows = @()
    foreach ($result in $results) {
        Write-Host ('  ' + $result.Name.PadRight($maxNameLength) + '  ') -NoNewline
        foreach ($check in $result.Checks) {
            $color = if ($check.Success) { 'Green' } else { 'Red' }
            Write-Host ("{0}: " -f $check.Name) -NoNewline -ForegroundColor DarkGray
            Write-Host $check.Status.PadRight(5) -NoNewline -ForegroundColor $color
            $rows += [pscustomobject]@{
                Target = $result.Name
                Test = $check.Name
                Success = [bool]$check.Success
                Detail = $check.Detail
            }
        }
        if ($null -ne $result.PingSuccess) {
            Write-Host '| Ping: ' -NoNewline -ForegroundColor DarkGray
            Write-Host $result.PingStatus -ForegroundColor $(if ($result.PingSuccess) { 'Cyan' } else { 'Red' })
            $rows += [pscustomobject]@{
                Target = $result.Name
                Test = 'PING'
                Success = [bool]$result.PingSuccess
                Detail = $result.PingStatus
            }
        } else {
            Write-Host ''
        }
    }
    return $rows
}

function Get-StandardTargets {
    $items = @()
    Get-Content (Join-Path $PSScriptRoot 'targets.txt') | ForEach-Object {
        if ($_ -match '^\s*([A-Za-z0-9_]+)\s*=\s*"([^"]+)"') {
            $name = $matches[1]
            $value = $matches[2]
            if ($value -like 'PING:*') {
                $items += [pscustomobject]@{ Name=$name; Url=$null; PingTarget=$value.Substring(5); Category='standard' }
            } else {
                $hostName = $value -replace '^https?://', '' -replace '/.*$', ''
                $items += [pscustomobject]@{ Name=$name; Url=$value; PingTarget=$hostName; Category='standard' }
            }
        }
    }
    return $items
}

function Get-DpiTargets {
    try {
        $suiteUrl = 'https://hyperion-cs.github.io/dpi-checkers/ru/tcp-16-20/suite.v2.json'
        $suiteData = Invoke-RestMethod -Uri $suiteUrl -TimeoutSec $TimeoutSeconds
        $index = 0
        return @($suiteData | Select-Object -First 20 | ForEach-Object {
            $index++
            $id = if ($_.id) { $_.id } else { $index }
            [pscustomobject]@{
                Name = "DPI_$id"
                Url = "https://$($_.host)"
                PingTarget = $_.host
                Category = 'dpi'
            }
        })
    } catch {
        Write-Host '[WARN] DPI checker suite is unavailable; skipping it.' -ForegroundColor Yellow
        return @()
    }
}

function Read-SuiteSelection {
    while ($true) {
        Write-Host ''
        Write-Host 'Test type:' -ForegroundColor Cyan
        Write-Host '  [1] Standard targets (fast)' -ForegroundColor Gray
        Write-Host '  [2] DPI checker targets' -ForegroundColor Gray
        Write-Host '  [3] Both' -ForegroundColor Gray
        switch ((Read-Host 'Select 1-3')) {
            '1' { return 'standard' }
            '2' { return 'dpi' }
            '3' { return 'both' }
            default { Write-Host 'Invalid selection.' -ForegroundColor Yellow }
        }
    }
}

function Select-PresetFiles([array]$Files) {
    Write-Host ''
    Write-Host 'Preset selection:' -ForegroundColor Cyan
    Write-Host "  [1] All presets ($($Files.Count))" -ForegroundColor Gray
    Write-Host '  [2] Selected presets' -ForegroundColor Gray
    if ((Read-Host 'Select 1-2') -ne '2') { return $Files }

    Write-Host ''
    for ($i = 0; $i -lt $Files.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1), ($Files[$i].BaseName -replace '\.txt$', '')) -ForegroundColor Gray
    }
    while ($true) {
        $inputValue = (Read-Host 'Numbers/ranges (example: 1,3,5-7; 0 = all)').Trim()
        if ($inputValue -eq '0') { return $Files }
        $indices = @()
        foreach ($part in ($inputValue -split '[,\s]+')) {
            if ($part -match '^(\d+)-(\d+)$') {
                $from = [int]$matches[1]
                $to = [int]$matches[2]
                if ($from -le $to) { $indices += $from..$to }
            } elseif ($part -match '^\d+$') {
                $indices += [int]$part
            }
        }
        $valid = @($indices | Sort-Object -Unique | Where-Object { $_ -ge 1 -and $_ -le $Files.Count })
        if ($valid.Count) {
            return @($valid | ForEach-Object { $Files[$_ - 1] })
        }
        Write-Host 'No valid presets selected.' -ForegroundColor Yellow
    }
}

if (-not $suiteWasSpecified -and -not $NonInteractive) {
    $Suite = Read-SuiteSelection
}
if (-not $Preset -and -not $NonInteractive) {
    $presetFiles = @(Select-PresetFiles -Files $presetFiles)
}

$targets = @()
if ($Suite -in @('standard','both')) { $targets += Get-StandardTargets }
if ($Suite -in @('dpi','both')) { $targets += Get-DpiTargets }
$targets = @($targets | Sort-Object Name -Unique)
if (-not $targets) { throw 'No test targets available.' }

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '              ZAPRET 2 NEXT PRESET TESTS' -ForegroundColor Cyan
Write-Host ("              Mode: {0}" -f $Suite.ToUpperInvariant()) -ForegroundColor Cyan
Write-Host ("              Presets: {0} | Targets: {1}" -f $presetFiles.Count, $targets.Count) -ForegroundColor Cyan
Write-Host ("              Parallel workers: {0}" -f $MaxParallel) -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan

$serviceWasRunning = (Get-Service winws2 -ErrorAction SilentlyContinue).Status -eq 'Running'
$savedProcesses = @()
try {
    $savedProcesses = @(Get-CimInstance Win32_Process -Filter "Name='winws2.exe'" -ErrorAction SilentlyContinue |
        Select-Object ExecutablePath, CommandLine)
} catch {}

$all = @()
$presetNumber = 0
try {
    if ($serviceWasRunning) { Stop-Service winws2 -Force -ErrorAction SilentlyContinue }
    Stop-Winws2
    foreach ($file in $presetFiles) {
        $presetNumber++
        $name = $file.BaseName -replace '\.txt$', ''
        $safeName = $name -replace ' ', '_'
        $config = Join-Path $root ("runtime\test-{0}.txt" -f $safeName)
        $dryConfig = Join-Path $root ("runtime\test-{0}-validate.txt" -f $safeName)
        $logPrefix = Join-Path $resultsDir ("{0}-{1}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $safeName)
        $timer = [Diagnostics.Stopwatch]::StartNew()

        Write-Host ''
        Write-Host '------------------------------------------------------------' -ForegroundColor DarkCyan
        Write-Host ("  [{0}/{1}] {2}" -f $presetNumber, $presetFiles.Count, $name) -ForegroundColor Yellow
        Write-Host '------------------------------------------------------------' -ForegroundColor DarkCyan
        Stop-Winws2

        & $renderer -Preset $name -Output $config | Out-Null
        & $renderer -Preset $name -Output $dryConfig -DryRun | Out-Null
        Write-Host '  > Validating configuration...' -ForegroundColor DarkGray
        & $starter -Config $dryConfig -LogPrefix ($logPrefix + '-validate') -Validate
        if ($LASTEXITCODE -ne 0) {
            Write-Host '  [X] Configuration validation failed.' -ForegroundColor Red
            $all += [pscustomobject]@{ Preset=$name; Target='(process)'; Test='VALIDATE'; Success=$false; Detail="winws2 rejected config; see $logPrefix-validate.*.log" }
            continue
        }
        Write-Host '  > Starting winws2...' -ForegroundColor DarkGray
        & $starter -Config $config -LogPrefix $logPrefix -StartupWaitSeconds 3
        if ($LASTEXITCODE -ne 0) {
            Write-Host '  [X] winws2 failed to start.' -ForegroundColor Red
            $all += [pscustomobject]@{ Preset=$name; Target='(process)'; Test='START'; Success=$false; Detail="startup failed; see $logPrefix.*.log" }
            Stop-Winws2
            continue
        }
        Write-Host ("  > Testing targets (parallel: {0})..." -f $MaxParallel) -ForegroundColor DarkGray
        $rows = Invoke-WebChecks -Targets $targets -Timeout $TimeoutSeconds -Parallel $MaxParallel
        foreach ($row in $rows) {
            $all += [pscustomobject]@{ Preset=$name; Target=$row.Target; Test=$row.Test; Success=$row.Success; Detail=$row.Detail }
        }
        $passed = @($rows | Where-Object Success).Count
        $timer.Stop()
        Write-Host ("  > Completed in {0:N1}s: {1}/{2} checks passed." -f $timer.Elapsed.TotalSeconds, $passed, $rows.Count) -ForegroundColor $(if($passed){'Green'}else{'Red'})
        Stop-Winws2
    }
} finally {
    Stop-Winws2
    if ($serviceWasRunning) {
        Start-Service winws2 -ErrorAction SilentlyContinue
    } elseif ($savedProcesses) {
        foreach ($saved in $savedProcesses) {
            if (-not $saved.ExecutablePath -or -not $saved.CommandLine) { continue }
            $args = $saved.CommandLine
            if ($args.StartsWith('"' + $saved.ExecutablePath + '"')) { $args = $args.Substring($saved.ExecutablePath.Length + 2).Trim() }
            try { Start-Process -FilePath $saved.ExecutablePath -ArgumentList $args -WorkingDirectory (Split-Path $saved.ExecutablePath) -WindowStyle Hidden | Out-Null } catch {}
        }
    }
}

$stamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$csv = Join-Path $resultsDir "results-$stamp.csv"
$all | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $csv

$summary = $all | Group-Object Preset | ForEach-Object {
    $passed = @($_.Group | Where-Object Success).Count
    [pscustomobject]@{ Preset=$_.Name; Passed=$passed; Failed=$_.Count-$passed; Total=$_.Count }
}

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '                         RESULTS' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
foreach ($item in $summary) {
    Write-Host ("  {0} : " -f $item.Preset) -NoNewline
    Write-Host ("OK={0} FAIL={1} TOTAL={2}" -f $item.Passed, $item.Failed, $item.Total) -ForegroundColor $(if($item.Failed){'Yellow'}else{'Green'})
}

$best = $summary |
    Sort-Object @{Expression='Passed'; Descending=$true}, @{Expression='Failed'; Ascending=$true} |
    Select-Object -First 1
if ($best) {
    Write-Host ''
    Write-Host ("  Best preset: {0} ({1}/{2})" -f $best.Preset, $best.Passed, $best.Total) -ForegroundColor Green
}
Write-Host ("  Results saved: {0}" -f $csv) -ForegroundColor Green

$exitCode = if (@($all | Where-Object { -not $_.Success }).Count) { 2 } else { 0 }
if (-not $NonInteractive) {
    Write-Host ''
    Write-Host 'Press any key to close...' -ForegroundColor Yellow
    [void][Console]::ReadKey($true)
}
exit $exitCode
