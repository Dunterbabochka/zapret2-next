param(
    [Parameter(Mandatory = $true)]
    [string]$Config,

    [Parameter(Mandatory = $true)]
    [string]$LogPrefix,

    [switch]$Validate,

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
Remove-Item -LiteralPath $stdoutLog, $stderrLog -Force -ErrorAction SilentlyContinue

$argument = '@"' + $configPath + '"'
try {
    $process = Start-Process -FilePath $winws -ArgumentList $argument -WorkingDirectory (Split-Path -Parent $winws) -WindowStyle Hidden -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog -PassThru
} catch {
    Write-Host "[ERROR] Could not launch winws2: $($_.Exception.Message)" -ForegroundColor Red
    Show-EngineLog
    exit 12
}

if ($Validate) {
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) {
        Write-Host "[ERROR] winws2 rejected the generated config (exit $($process.ExitCode))." -ForegroundColor Red
        Show-EngineLog
        exit 13
    }
    exit 0
}

Start-Sleep -Seconds $StartupWaitSeconds
$process.Refresh()
if ($process.HasExited) {
    Write-Host "[ERROR] winws2 stopped during startup (exit $($process.ExitCode))." -ForegroundColor Red
    Show-EngineLog
    exit 14
}

exit 0
