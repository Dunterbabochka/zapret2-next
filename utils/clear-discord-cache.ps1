[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$ListOnly
)

$ErrorActionPreference = 'Stop'
$appData = [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)
if ([string]::IsNullOrWhiteSpace($appData)) {
    throw 'Could not resolve the current user AppData directory.'
}
$appDataRoot = [IO.Path]::GetFullPath($appData).TrimEnd('\') + '\'

$channels = @(
    [pscustomobject]@{ Name = 'Discord Stable'; Directory = 'discord'; Process = 'Discord' }
    [pscustomobject]@{ Name = 'Discord PTB'; Directory = 'discordptb'; Process = 'DiscordPTB' }
    [pscustomobject]@{ Name = 'Discord Canary'; Directory = 'discordcanary'; Process = 'DiscordCanary' }
    [pscustomobject]@{ Name = 'Discord Development'; Directory = 'discorddevelopment'; Process = 'DiscordDevelopment' }
)
$cacheNames = @('Cache', 'Code Cache', 'GPUCache')
$targets = [Collections.Generic.List[object]]::new()

foreach ($channel in $channels) {
    $channelRoot = [IO.Path]::GetFullPath((Join-Path $appData $channel.Directory))
    if (-not ($channelRoot + '\').StartsWith($appDataRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe Discord cache root: $channelRoot"
    }
    foreach ($cacheName in $cacheNames) {
        $cachePath = [IO.Path]::GetFullPath((Join-Path $channelRoot $cacheName))
        if (($cachePath + '\').StartsWith($channelRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -and
            (Test-Path -LiteralPath $cachePath -PathType Container)) {
            $targets.Add([pscustomobject]@{
                Channel = $channel.Name
                Process = $channel.Process
                Path = $cachePath
            })
        }
    }
}

if ($targets.Count -eq 0) {
    Write-Host '[INFO] No Discord Cache, Code Cache or GPUCache directories were found.' -ForegroundColor Yellow
    exit 0
}

Write-Host 'The following Discord cache directories will be removed:' -ForegroundColor Yellow
foreach ($target in $targets) { Write-Host ('  {0}: {1}' -f $target.Channel, $target.Path) }
if ($ListOnly) {
    Write-Host '[INFO] List-only mode: no process was closed and no directory was removed.' -ForegroundColor Cyan
    exit 0
}
Write-Host 'Discord processes for the affected channels will be closed first.' -ForegroundColor Yellow

if (-not $Force) {
    $answer = (Read-Host 'Continue? [y/N]').Trim()
    if ($answer -notin @('y', 'yes')) {
        Write-Host '[INFO] Discord cache cleanup cancelled.' -ForegroundColor Yellow
        exit 0
    }
}

$failures = [Collections.Generic.List[string]]::new()
foreach ($processName in @($targets | Select-Object -ExpandProperty Process -Unique)) {
    foreach ($process in @(Get-Process -Name $processName -ErrorAction SilentlyContinue)) {
        try {
            Stop-Process -Id $process.Id -Force -ErrorAction Stop
            Write-Host "[OK] Closed $processName (PID $($process.Id))." -ForegroundColor Green
        } catch {
            $failures.Add("Could not close $processName PID $($process.Id): $($_.Exception.Message)")
        }
    }
}

foreach ($target in $targets) {
    try {
        Remove-Item -LiteralPath $target.Path -Recurse -Force -ErrorAction Stop
        Write-Host "[OK] Removed $($target.Path)" -ForegroundColor Green
    } catch {
        $failures.Add("Could not remove $($target.Path): $($_.Exception.Message)")
    }
}

if ($failures.Count -gt 0) {
    foreach ($failure in $failures) { Write-Host "[ERROR] $failure" -ForegroundColor Red }
    exit 1
}

Write-Host '[OK] Discord cache cleanup completed. Discord will recreate these directories on launch.' -ForegroundColor Green
exit 0
