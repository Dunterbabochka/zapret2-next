[CmdletBinding()]
param(
    [string]$RemoteUrl = 'https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/main/.service/ipset-service.txt',
    [string]$SourcePath,
    [string]$ReportDirectory,
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $ReportDirectory) {
    $ReportDirectory = Join-Path $root ('runtime\ipset-sync\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
$reportRoot = [IO.Path]::GetFullPath($ReportDirectory)
New-Item -ItemType Directory -Path $reportRoot -Force | Out-Null
$candidatePath = Join-Path $reportRoot 'candidate.txt'
$serviceDestination = Join-Path $root '.service\ipset-service.txt'
$listDestination = Join-Path $root 'lists\ipset-all.txt'

function Get-ValidatedIPSet([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "IPSet not found: $Path" }
    $entries = [Collections.Generic.List[string]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $lineNumber = 0
    foreach ($line in Get-Content -LiteralPath $Path) {
        $lineNumber++
        $entry = ([string]$line).Trim()
        if (-not $entry -or $entry.StartsWith('#')) { continue }
        $parts = $entry.Split('/', 2)
        $address = $null
        if (-not [Net.IPAddress]::TryParse($parts[0], [ref]$address)) {
            throw "Invalid IP address at line $lineNumber`: $entry"
        }
        if ($parts.Count -eq 2) {
            $prefix = 0
            $maximum = if ($address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork) { 32 } else { 128 }
            if (-not [int]::TryParse($parts[1], [ref]$prefix) -or $prefix -lt 0 -or $prefix -gt $maximum) {
                throw "Invalid CIDR prefix at line $lineNumber`: $entry"
            }
        }
        if (-not $seen.Add($entry)) { throw "Duplicate IPSet entry at line $lineNumber`: $entry" }
        $entries.Add($entry)
    }
    if ($entries.Count -lt 1000) { throw "IPSet contains only $($entries.Count) entries; refusing a suspiciously small snapshot." }
    return $entries
}

$sourceLabel = $null
if ($SourcePath) {
    $resolvedSource = [IO.Path]::GetFullPath($SourcePath)
    Copy-Item -LiteralPath $resolvedSource -Destination $candidatePath -Force
    $sourceLabel = $resolvedSource
} else {
    Invoke-WebRequest -UseBasicParsing -TimeoutSec 30 -Uri $RemoteUrl -OutFile $candidatePath
    $sourceLabel = $RemoteUrl
}

$candidate = @(Get-ValidatedIPSet $candidatePath)
$current = if (Test-Path -LiteralPath $serviceDestination -PathType Leaf) {
    @(Get-ValidatedIPSet $serviceDestination)
} else {
    @()
}
$candidateSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$currentSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($entry in $candidate) { [void]$candidateSet.Add($entry) }
foreach ($entry in $current) { [void]$currentSet.Add($entry) }
$added = @($candidate | Where-Object { -not $currentSet.Contains($_) })
$removed = @($current | Where-Object { -not $candidateSet.Contains($_) })

[IO.File]::WriteAllLines((Join-Path $reportRoot 'added.txt'), $added, [Text.Encoding]::ASCII)
[IO.File]::WriteAllLines((Join-Path $reportRoot 'removed.txt'), $removed, [Text.Encoding]::ASCII)
$summary = @(
    'Zapret 2 NEXT upstream IPSet synchronization preview'
    "Generated: $([DateTime]::UtcNow.ToString('o'))"
    "Source: $sourceLabel"
    "Current entries: $($current.Count)"
    "Candidate entries: $($candidate.Count)"
    "Added: $($added.Count)"
    "Removed: $($removed.Count)"
    "Candidate SHA256: $((Get-FileHash -LiteralPath $candidatePath -Algorithm SHA256).Hash)"
    "Applied: $($Apply.IsPresent)"
)
[IO.File]::WriteAllLines((Join-Path $reportRoot 'SUMMARY.txt'), $summary, [Text.Encoding]::UTF8)

Write-Host "[INFO] IPSet candidate: $($candidate.Count) entries; +$($added.Count) / -$($removed.Count)." -ForegroundColor Cyan
Write-Host "[INFO] Review report: $reportRoot" -ForegroundColor Cyan
if (-not $Apply) {
    Write-Host '[PREVIEW] No project file was changed. Re-run with -Apply after reviewing added.txt and removed.txt.' -ForegroundColor Yellow
    exit 0
}

$normalized = ($candidate -join "`r`n") + "`r`n"
$destinations = @($serviceDestination, $listDestination)
$original = @{}
$temporary = @{}
try {
    foreach ($destination in $destinations) {
        $original[$destination] = if (Test-Path -LiteralPath $destination -PathType Leaf) {
            [IO.File]::ReadAllBytes($destination)
        } else {
            $null
        }
        $temporary[$destination] = $destination + '.download'
        [IO.File]::WriteAllText($temporary[$destination], $normalized, [Text.Encoding]::ASCII)
        [void](Get-ValidatedIPSet $temporary[$destination])
    }
    foreach ($destination in $destinations) {
        Move-Item -LiteralPath $temporary[$destination] -Destination $destination -Force
    }
} catch {
    foreach ($destination in $destinations) {
        Remove-Item -LiteralPath ($destination + '.download') -Force -ErrorAction SilentlyContinue
        if ($null -ne $original[$destination]) {
            [IO.File]::WriteAllBytes($destination, $original[$destination])
        } elseif (Test-Path -LiteralPath $destination) {
            Remove-Item -LiteralPath $destination -Force
        }
    }
    throw "IPSet apply failed and original files were restored: $($_.Exception.Message)"
}

Write-Host '[OK] Updated .service\ipset-service.txt and lists\ipset-all.txt.' -ForegroundColor Green
exit 0
