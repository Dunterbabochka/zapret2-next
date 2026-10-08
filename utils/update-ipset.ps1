param(
    [string]$RemoteUrl,
    [string]$Destination,
    [string]$SourcePath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ipset-utils.ps1')
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $Destination) { $Destination = Join-Path $root 'lists\ipset-all.txt' }
$destinationPath = [IO.Path]::GetFullPath($Destination)
$bundledPath = Join-Path $root '.service\ipset-service.txt'
$temporaryPath = $destinationPath + '.' + [Guid]::NewGuid().ToString('N') + '.download'
$lock = $null

try {
    # The OS releases this lock on a crash. Never unlink a possibly open lock.
    $lock = [IO.File]::Open($destinationPath + '.lock', 'OpenOrCreate', 'ReadWrite', 'None')
    $sourceLabel = 'bundled snapshot'
    if ($SourcePath) {
        Copy-Item -LiteralPath $SourcePath -Destination $temporaryPath
        $sourceLabel = 'local snapshot'
    } elseif ($RemoteUrl) {
        try {
            Invoke-WebRequest -UseBasicParsing -TimeoutSec 20 -Uri $RemoteUrl -OutFile $temporaryPath
            $sourceLabel = 'remote repository'
        } catch {
            # A timed-out request can leave a partial file behind.
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
            Write-Host "[WARN] Remote IPSet is unavailable: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    if (-not (Test-Path -LiteralPath $temporaryPath -PathType Leaf)) {
        Copy-Item -LiteralPath $bundledPath -Destination $temporaryPath
    }
    $candidateEntries = @(Read-ValidatedIPSet $temporaryPath)
    $currentEntries = if (Test-Path -LiteralPath $destinationPath -PathType Leaf) {
        @(Get-Content -LiteralPath $destinationPath | ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith('#') })
    } else { @() }
    Assert-IPSetSize $candidateEntries.Count $currentEntries.Count
    $currentSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $candidateSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $currentEntries) { [void]$currentSet.Add($entry) }
    foreach ($entry in $candidateEntries) { [void]$candidateSet.Add($entry) }
    $addedCount = @($candidateEntries | Where-Object { -not $currentSet.Contains($_) }).Count
    $removedCount = @($currentEntries | Where-Object { -not $candidateSet.Contains($_) }).Count
    Write-Host "[INFO] IPSet candidate diff: +$addedCount / -$removedCount." -ForegroundColor Cyan
    Write-AtomicTextFile -Path $destinationPath -Content (($candidateEntries -join "`r`n") + "`r`n") -BackupPath ($destinationPath + '.backup')
    Write-Host "[OK] IPSet updated atomically from $sourceLabel ($($candidateEntries.Count) entries)." -ForegroundColor Green
} catch {
    Write-Host "[ERROR] IPSet update failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'The current list was preserved.' -ForegroundColor Yellow
    exit 1
} finally {
    Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    if ($lock) { $lock.Dispose() }
}
exit 0
