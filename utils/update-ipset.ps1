param(
    [string]$RemoteUrl,
    [string]$Destination
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $Destination) { $Destination = Join-Path $root 'lists\ipset-all.txt' }
$destinationPath = [IO.Path]::GetFullPath($Destination)
$bundledPath = Join-Path $root '.service\ipset-service.txt'
$temporaryPath = $destinationPath + '.download'
$backupPath = $destinationPath + '.backup'
$sourceLabel = $null

function Test-IpsetFile([string]$Path) {
    $entries = @(Get-Content -LiteralPath $Path |
        Where-Object { $_ -and $_ -notmatch '^\s*#' })
    if ($entries.Count -lt 10) { throw "IPSet contains only $($entries.Count) entries." }
    $invalid = @($entries |
        Where-Object { $_ -notmatch '^\s*([0-9a-fA-F:.]+)(/\d+)?\s*$' })
    if ($invalid.Count) {
        throw "IPSet contains an invalid entry: $($invalid[0])"
    }
    return $entries.Count
}

Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
try {
    if ($RemoteUrl) {
        try {
            Invoke-WebRequest -UseBasicParsing -TimeoutSec 20 -Uri $RemoteUrl -OutFile $temporaryPath
            $sourceLabel = 'remote repository'
        } catch {
            Write-Host "[WARN] Remote IPSet is unavailable: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    if (-not (Test-Path -LiteralPath $temporaryPath -PathType Leaf)) {
        if (-not (Test-Path -LiteralPath $bundledPath -PathType Leaf)) {
            throw 'Neither remote nor bundled IPSet is available.'
        }
        Copy-Item -LiteralPath $bundledPath -Destination $temporaryPath -Force
        $sourceLabel = 'bundled snapshot'
    }

    $entryCount = Test-IpsetFile -Path $temporaryPath
    if (Test-Path -LiteralPath $destinationPath -PathType Leaf) {
        Copy-Item -LiteralPath $destinationPath -Destination $backupPath -Force
    }
    Move-Item -LiteralPath $temporaryPath -Destination $destinationPath -Force
    Write-Host "[OK] IPSet updated atomically from $sourceLabel ($entryCount entries)." -ForegroundColor Green
    exit 0
} catch {
    Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    Write-Host "[ERROR] IPSet update failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'The current list was preserved.' -ForegroundColor Yellow
    exit 1
}
