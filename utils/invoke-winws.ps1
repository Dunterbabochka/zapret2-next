param(
    [Parameter(Mandatory = $true)]
    [string]$Config,

    [Parameter(Mandatory = $true)]
    [string]$LogPrefix,

    [switch]$Validate,

    [switch]$ReplaceExisting,

    [ValidateRange(1, 120)]
    [int]$ValidationTimeoutSeconds = 30,

    [ValidateRange(1, 30)]
    [int]$StartupWaitSeconds = 3
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$winws = Join-Path $root 'bin\winws2.exe'
$configPath = [IO.Path]::GetFullPath($Config)
$logBase = [IO.Path]::GetFullPath($LogPrefix)
$stdoutLog = $logBase + '.stdout.log'
$stderrLog = $logBase + '.stderr.log'

if ($root -match '[^\x00-\x7F]') {
    Write-Host '[WARN] Installation path contains non-ASCII characters. If winws2 reports chdir, move the bundle to C:\zapret2-next.' -ForegroundColor Yellow
}

function Show-EngineLog {
    $printed = $false
    foreach ($path in @($stderrLog, $stdoutLog)) {
        if (Test-Path -LiteralPath $path) {
            $lines = @(Get-Content -LiteralPath $path -ErrorAction SilentlyContinue)
            if ($lines.Count -gt 0) {
                if (-not $printed) {
                    Write-Host '----- winws2 output -----' -ForegroundColor DarkYellow
                    $printed = $true
                }
                $lines | ForEach-Object { Write-Host $_ }
            }
        }
    }
    if (-not $printed) {
        Write-Host '[WARN] winws2 produced no console output.' -ForegroundColor Yellow
    }
    Write-Host "Logs: $stderrLog ; $stdoutLog" -ForegroundColor DarkGray
}

if (-not (Test-Path -LiteralPath $winws -PathType Leaf)) {
    Write-Host "[ERROR] winws2.exe not found: $winws" -ForegroundColor Red
    exit 10
}
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    Write-Host "[ERROR] Config not found: $configPath" -ForegroundColor Red
    exit 11
}

$logDir = Split-Path -Parent $logBase
if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
}

$launchLock = $null
if (-not $Validate) {
    try {
        $launchLock = [IO.File]::Open((Join-Path $root 'runtime\engine-operation.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
        $services = @(Get-CimInstance Win32_Service -Filter "Name='winws2' OR Name='zapret'" -ErrorAction Stop)
        if (@($services | Where-Object { $_.State -ne 'Stopped' }).Count) {
            throw 'A Zapret service is active. Stop it before a manual launch.'
        }
        $existing = @(Get-CimInstance Win32_Process -Filter "Name='winws2.exe' OR Name='winws.exe'" -ErrorAction Stop)
        foreach ($engine in $existing) {
            if (-not $ReplaceExisting -or $engine.ExecutablePath -ne $winws) {
                throw 'Another winws process is running. Stop its bundle before starting this one.'
            }
        }
        foreach ($engine in $existing) {
            Stop-Process -Id $engine.ProcessId -Force -ErrorAction Stop
            $oldProcess = Get-Process -Id $engine.ProcessId -ErrorAction SilentlyContinue
            if ($oldProcess -and -not $oldProcess.WaitForExit(5000)) { throw 'Previous winws2 process did not stop.' }
        }
    } catch {
        if ($launchLock) { $launchLock.Dispose() }
        Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
        exit 15
    }
}

$argument = '@"' + $configPath + '"'
try {
    Remove-Item -LiteralPath $stdoutLog, $stderrLog -Force -ErrorAction SilentlyContinue
    $process = Start-Process -FilePath $winws -ArgumentList $argument -WorkingDirectory (Split-Path -Parent $winws) -WindowStyle Hidden -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog -PassThru
    # Retain the process handle so Windows PowerShell keeps the exit code.
    $null = $process.Handle
} catch {
    if ($launchLock) { $launchLock.Dispose() }
    Write-Host "[ERROR] Could not launch winws2: $($_.Exception.Message)" -ForegroundColor Red
    Show-EngineLog
    exit 12
}

if ($Validate) {
    if (-not $process.WaitForExit($ValidationTimeoutSeconds * 1000)) {
        $process.Kill()
        $process.WaitForExit()
        Write-Host "[ERROR] Config validation timed out after $ValidationTimeoutSeconds seconds." -ForegroundColor Red
        Show-EngineLog
        exit 16
    }
    $process.WaitForExit()
    $process.Refresh()
    $engineExitCode = try { $process.ExitCode } catch { $null }
    $verified = (Test-Path -LiteralPath $stdoutLog -PathType Leaf) -and
        ([bool](Select-String -LiteralPath $stdoutLog -Pattern '^command line parameters verified$' -Quiet))

    # Windows PowerShell can lose ExitCode for a short-lived Start-Process
    # child with redirected streams. The dry-run success marker is emitted by
    # winws2 only after its complete argument and file validation succeeds.
    if ($engineExitCode -eq 0 -or ($null -eq $engineExitCode -and $verified)) {
        exit 0
    } else {
        $displayExitCode = if ($null -eq $engineExitCode) { 'unknown' } else { $engineExitCode }
        Write-Host "[ERROR] winws2 rejected the generated config (exit $displayExitCode)." -ForegroundColor Red
        Show-EngineLog
        exit 13
    }
}

Start-Sleep -Seconds $StartupWaitSeconds
$process.Refresh()
if ($launchLock) { $launchLock.Dispose() }
if ($process.HasExited) {
    $process.WaitForExit()
    $process.Refresh()
    $displayExitCode = if ($null -eq $process.ExitCode) { 'unknown' } else { $process.ExitCode }
    Write-Host "[ERROR] winws2 stopped during startup (exit $displayExitCode)." -ForegroundColor Red
    Show-EngineLog
    exit 14
}

exit 0
