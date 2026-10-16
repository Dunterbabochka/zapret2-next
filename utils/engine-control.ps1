. (Join-Path $PSScriptRoot 'session-log.ps1')
function Get-ZapretManualLaunchState([string]$Root,[switch]$ReplaceExisting) {
    $services=@(Get-CimInstance Win32_Service -Filter "Name='winws2' OR Name='zapret'" -ErrorAction Stop)
    if (@($services | Where-Object { $_.State -ne 'Stopped' }).Count) { throw 'A Zapret service is active. Stop it before a manual launch.' }
    $winws=Join-Path $Root 'bin\winws2.exe'
    $existing=@(Get-CimInstance Win32_Process -Filter "Name='winws2.exe' OR Name='winws.exe'" -ErrorAction Stop)
    foreach ($engine in $existing) {
        if (-not $ReplaceExisting -or $engine.ExecutablePath -ne $winws) { throw 'Another winws process is running. Stop its bundle before starting this one.' }
    }
    return $existing
}
function Invoke-ZapretEngine {
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

$previousLog=$script:ZapretLog
$launchLock=$null; $bundleGate=$null; $process=$null
Initialize-ZapretLog -Root ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))) -Component engine -Action $(if ($Validate) {'Validate'} else {'Launch'})
try {

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'bundle-operation.ps1')
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
    Complete-ZapretLogOperation -ExitCode 10; return 10
}
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    Write-Host "[ERROR] Config not found: $configPath" -ForegroundColor Red
    Complete-ZapretLogOperation -ExitCode 11; return 11
}

$logDir = Split-Path -Parent $logBase
if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
}

$launchLock = $null
$bundleGate = $null
if (-not $Validate) {
    try {
        $bundleGate = Enter-ZapretBundleOperation $root
        $launchLock = [IO.File]::Open((Join-Path $root 'runtime\engine-operation.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
        $existing = @(Get-ZapretManualLaunchState -Root $root -ReplaceExisting:$ReplaceExisting)
        foreach ($engine in $existing) {
            Stop-Process -Id $engine.ProcessId -Force -ErrorAction Stop
            $oldProcess = Get-Process -Id $engine.ProcessId -ErrorAction SilentlyContinue
            if ($oldProcess -and -not $oldProcess.WaitForExit(5000)) { throw 'Previous winws2 process did not stop.' }
        }
    } catch { Write-ZapretLogException $_ -Warning;
        if ($launchLock) { $launchLock.Dispose(); $launchLock=$null }
        Exit-ZapretBundleOperation $bundleGate; $bundleGate=$null
        Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
        Complete-ZapretLogOperation -ExitCode 15; return 15
    }
}

$argument = '@"' + $configPath + '"'
$validationTimer=[Diagnostics.Stopwatch]::StartNew()
for ($attempt=1; $attempt -le 3; $attempt++) {
try {
    Remove-Item -LiteralPath $stdoutLog, $stderrLog -Force -ErrorAction SilentlyContinue
    $process = Start-Process -FilePath $winws -ArgumentList $argument -WorkingDirectory (Split-Path -Parent $winws) -WindowStyle Hidden -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog -PassThru
    # Retain the process handle so Windows PowerShell keeps the exit code.
    $null = $process.Handle
} catch { Write-ZapretLogException $_ -Warning;
    if ($launchLock) { $launchLock.Dispose(); $launchLock=$null }
    Exit-ZapretBundleOperation $bundleGate; $bundleGate=$null
    Write-Host "[ERROR] Could not launch winws2: $($_.Exception.Message)" -ForegroundColor Red
    Show-EngineLog
    Complete-ZapretLogOperation -ExitCode 12; return 12
}

if ($Validate) {
    $remaining=[Math]::Max(0,($ValidationTimeoutSeconds * 1000)-[int]$validationTimer.ElapsedMilliseconds)
    if (-not $process.WaitForExit($remaining)) {
        $process.Kill()
        $process.WaitForExit()
        Write-Host "[ERROR] Config validation timed out after $ValidationTimeoutSeconds seconds." -ForegroundColor Red
        Show-EngineLog
        Complete-ZapretLogOperation -ExitCode 16; return 16
    }
    $process.WaitForExit()
    $process.Refresh()
    $engineExitCode = try { $process.ExitCode } catch { Write-ZapretLogException $_ -Warning; $null }
    $verified = (Test-Path -LiteralPath $stdoutLog -PathType Leaf) -and
        ([bool](Select-String -LiteralPath $stdoutLog -Pattern '^command line parameters verified$' -Quiet))

    # STATUS_DLL_INIT_FAILED happens before winws2 can read the config and can
    # be transient on Windows. Retry only dry-runs, within the original timeout;
    # never treat an initialization failure as a successful config check.
    if ($engineExitCode -eq -1073741502 -and $attempt -lt 3 -and
        $validationTimer.ElapsedMilliseconds + 200 -lt $ValidationTimeoutSeconds * 1000) {
        Write-ZapretLogEvent -Stage retry -Result warning -Code NativeFailed -Details @{exitCode=$engineExitCode;attempt=$attempt}
        Write-Host "[WARN] winws2 DLL initialization failed (0xC0000142); retrying validation ($($attempt+1)/3)." -ForegroundColor Yellow
        foreach ($path in @($stdoutLog,$stderrLog)) {
            if ([IO.File]::Exists($path)) { Copy-Item -LiteralPath $path -Destination ($path+'.attempt-'+$attempt) -Force }
        }
        $process.Dispose(); $process=$null
        Start-Sleep -Milliseconds 200
        continue
    }

    # Windows PowerShell can lose ExitCode for a short-lived Start-Process
    # child with redirected streams. The dry-run success marker is emitted by
    # winws2 only after its complete argument and file validation succeeds.
    if ($verified -and ($engineExitCode -eq 0 -or $null -eq $engineExitCode)) {
        Complete-ZapretLogOperation -ExitCode 0; return 0
    } else {
        $displayExitCode = if ($null -eq $engineExitCode) { 'unknown' } else { $engineExitCode }
        Write-ZapretLogEvent -Stage validate -Result error -Code NativeFailed -Details @{exitCode=$engineExitCode;attempt=$attempt}
        if ($engineExitCode -eq -1073741502) {
            Write-Host '[ERROR] winws2 DLL initialization failed (0xC0000142). The configuration could not be checked.' -ForegroundColor Red
        } else {
            Write-Host "[ERROR] winws2 could not verify the generated config (exit $displayExitCode)." -ForegroundColor Red
        }
        Show-EngineLog
        Complete-ZapretLogOperation -ExitCode 13; return 13
    }
}
break # A real launch is started once; it must never use dry-run retries.
}

$null=$process.WaitForExit($StartupWaitSeconds * 1000)
$process.Refresh()
if ($launchLock) { $launchLock.Dispose(); $launchLock=$null }
Exit-ZapretBundleOperation $bundleGate; $bundleGate=$null
if ($process.HasExited) {
    $process.WaitForExit()
    $process.Refresh()
    $displayExitCode = if ($null -eq $process.ExitCode) { 'unknown' } else { $process.ExitCode }
    Write-ZapretLogEvent -Stage start -Result error -Code NativeFailed -Details @{exitCode=$displayExitCode}
    Write-Host "[ERROR] winws2 stopped during startup (exit $displayExitCode)." -ForegroundColor Red
    Show-EngineLog
    Complete-ZapretLogOperation -ExitCode 14; return 14
}

Complete-ZapretLogOperation -ExitCode 0; return 0

} catch { Write-ZapretLogException $_; throw }
finally {
    if ($process) { $process.Dispose() }
    if ($launchLock) { $launchLock.Dispose() }
    Exit-ZapretBundleOperation $bundleGate
    Complete-ZapretLogOperation
    $script:ZapretLog=$previousLog
}

}
