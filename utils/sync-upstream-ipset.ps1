[CmdletBinding()]
param(
    [string]$RemoteUrl = 'https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/main/.service/ipset-service.txt',
    [string]$SourcePath,
    [string]$ReportDirectory,
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ipset-utils.ps1')
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
    # Refuse a suspiciously small snapshot in both update entry points.
    Read-ValidatedIPSet -Path $Path -MinimumEntries 1000
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
Assert-IPSetSize $candidate.Count $current.Count
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
    'Applied: False'
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
$locks = [Collections.Generic.List[IO.FileStream]]::new()
$applied = [Collections.Generic.List[string]]::new()
try {
    # Acquire both locks before capturing originals or writing either file.
    foreach ($destination in $destinations) {
        $locks.Add([IO.File]::Open($destination + '.lock', 'OpenOrCreate', 'ReadWrite', 'None'))
    }
    foreach ($destination in $destinations) {
        $original[$destination] = $null
        if (Test-Path -LiteralPath $destination -PathType Leaf) {
            $original[$destination] = [IO.File]::ReadAllBytes($destination)
        }
        if ($null -ne $original[$destination]) {
            $oldCount = @(Get-Content -LiteralPath $destination | Where-Object { $_ -notmatch '^\s*(?:#|$)' }).Count
            Assert-IPSetSize $candidate.Count $oldCount
        }
    }
    foreach ($destination in $destinations) {
        Write-AtomicTextFile -Path $destination -Content $normalized
        $applied.Add($destination)
    }
} catch {
    foreach ($destination in $applied) {
        if ($null -ne $original[$destination]) {
            Write-AtomicFileBytes -Path $destination -Bytes $original[$destination]
        } elseif (Test-Path -LiteralPath $destination) {
            Remove-Item -LiteralPath $destination -Force
        }
    }
    throw "IPSet apply failed and original files were restored: $($_.Exception.Message)"
} finally {
    foreach ($heldLock in $locks) { $heldLock.Dispose() }
}

Write-Host '[OK] Updated .service\ipset-service.txt and lists\ipset-all.txt.' -ForegroundColor Green
$summary[-1] = 'Applied: True'
[IO.File]::WriteAllLines((Join-Path $reportRoot 'SUMMARY.txt'), $summary, [Text.Encoding]::UTF8)
exit 0
