param(
    [string[]]$Preset,
    [ValidateSet('standard', 'dpi', 'both')]
    [string]$Suite = 'both',
    [int]$TimeoutSeconds = 6
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$renderer = Join-Path $PSScriptRoot 'render-config.ps1'
$winws = Join-Path $root 'bin\winws2.exe'
$resultsDir = Join-Path $root 'runtime\test-results'
New-Item -ItemType Directory -Force -Path $resultsDir | Out-Null

$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host '[ERROR] Run tests as Administrator.' -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $winws)) { throw "winws2.exe not found: $winws" }
if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) { throw 'curl.exe is required.' }

$presetFiles = Get-ChildItem (Join-Path $root 'presets') -Filter '*.txt.in' |
    Where-Object { $_.BaseName -notlike '_*' } |
    Sort-Object Name
if ($Preset) {
    $wanted = @($Preset | ForEach-Object { $_.ToLowerInvariant() })
    $presetFiles = @($presetFiles | Where-Object { $wanted -contains (($_.BaseName -replace '\.txt$', '').ToLowerInvariant()) })
}
if (-not $presetFiles) { throw 'No matching presets found.' }

function Stop-Winws2 {
    Get-Process winws2 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
}

function Invoke-WebChecks([array]$Targets) {
    $rows = @()
    foreach ($target in $Targets) {
        if ($target -like 'PING:*') {
            $hostName = $target.Substring(5)
            $ok = Test-Connection -ComputerName $hostName -Count 1 -Quiet -ErrorAction SilentlyContinue
            $rows += [pscustomobject]@{ Target=$target; Test='PING'; Success=$ok; Detail=if($ok){'OK'}else{'timeout'} }
            continue
        }
        $tests = @(
            @{ Name='HTTP1.1'; Args=@('--http1.1') },
            @{ Name='TLS1.2'; Args=@('--tlsv1.2','--tls-max','1.2') },
            @{ Name='TLS1.3'; Args=@('--tlsv1.3','--tls-max','1.3') }
        )
        foreach ($test in $tests) {
            $output = & curl.exe -I -sS --max-time $TimeoutSeconds -o NUL -w '%{http_code}' @($test.Args) $target 2>&1
            $code = ($output | Out-String).Trim()
            $ok = $LASTEXITCODE -eq 0 -and $code -match '^\d{3}$' -and $code -ne '000'
            $rows += [pscustomobject]@{ Target=$target; Test=$test.Name; Success=$ok; Detail=$code }
        }
    }
    return $rows
}

function Get-StandardTargets {
    $items = @()
    Get-Content (Join-Path $PSScriptRoot 'targets.txt') | ForEach-Object {
        if ($_ -match '^\s*[A-Za-z0-9_]+\s*=\s*"([^"]+)"') { $items += $matches[1] }
    }
    return $items
}

function Get-DpiTargets {
    try {
        $suiteUrl = 'https://hyperion-cs.github.io/dpi-checkers/ru/tcp-16-20/suite.v2.json'
        $suiteData = Invoke-RestMethod -Uri $suiteUrl -TimeoutSec $TimeoutSeconds
        return @($suiteData | Select-Object -First 20 | ForEach-Object { "https://$($_.host)" })
    } catch {
        Write-Host '[WARN] DPI checker suite is unavailable; skipping it.' -ForegroundColor Yellow
        return @()
    }
}

$targets = @()
if ($Suite -in @('standard','both')) { $targets += Get-StandardTargets }
if ($Suite -in @('dpi','both')) { $targets += Get-DpiTargets }
$targets = @($targets | Sort-Object -Unique)
if (-not $targets) { throw 'No test targets available.' }

$serviceWasRunning = (Get-Service winws2 -ErrorAction SilentlyContinue).Status -eq 'Running'
$savedProcesses = @()
try {
    $savedProcesses = @(Get-CimInstance Win32_Process -Filter "Name='winws2.exe'" -ErrorAction SilentlyContinue |
        Select-Object ExecutablePath, CommandLine)
} catch {}

$all = @()
try {
    if ($serviceWasRunning) { Stop-Service winws2 -Force -ErrorAction SilentlyContinue }
    Stop-Winws2
    foreach ($file in $presetFiles) {
        $name = $file.BaseName -replace '\.txt$', ''
        $config = Join-Path $root ("runtime\test-{0}.txt" -f ($name -replace ' ', '_'))
        & $renderer -Preset $name -Output $config | Out-Null
        Write-Host "`n[$name] starting winws2..." -ForegroundColor Cyan
        $argument = '@"' + $config + '"'
        $proc = Start-Process -FilePath $winws -ArgumentList $argument -WorkingDirectory (Split-Path $winws) -WindowStyle Hidden -PassThru
        Start-Sleep -Seconds 3
        if ($proc.HasExited) {
            $all += [pscustomobject]@{ Preset=$name; Target='(process)'; Test='START'; Success=$false; Detail="exit $($proc.ExitCode)" }
            continue
        }
        $rows = Invoke-WebChecks -Targets $targets
        foreach ($row in $rows) {
            $all += [pscustomobject]@{ Preset=$name; Target=$row.Target; Test=$row.Test; Success=$row.Success; Detail=$row.Detail }
        }
        $passed = @($rows | Where-Object Success).Count
        Write-Host "[$name] passed $passed/$($rows.Count) checks." -ForegroundColor $(if($passed){'Green'}else{'Red'})
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
Write-Host "`nResults: $csv" -ForegroundColor Green
$summary = $all | Group-Object Preset | ForEach-Object {
    [pscustomobject]@{ Preset=$_.Name; Passed=@($_.Group | Where-Object Success).Count; Total=$_.Count }
}
$summary | Format-Table -AutoSize
if (@($all | Where-Object { -not $_.Success }).Count -gt 0) { exit 2 }
exit 0
