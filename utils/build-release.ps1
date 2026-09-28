param(
    [Parameter(Mandatory)]
    [ValidatePattern('^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')]
    [string]$Version,
    [string]$OutputDirectory,
    [switch]$Beta
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$out = if ($OutputDirectory) {
    [IO.Path]::GetFullPath($OutputDirectory)
} else {
    Join-Path $root 'dist'
}
$stage = Join-Path $out "zapret2-next-v$Version"
$zip = Join-Path $out "zapret2-next-v$Version.zip"
$sourceVersionPath = Join-Path $root '.service\version.txt'
$sourceVersion = if (Test-Path -LiteralPath $sourceVersionPath -PathType Leaf) {
    (Get-Content -LiteralPath $sourceVersionPath -Raw).Trim()
} else {
    ''
}

if (-not $Beta -and $sourceVersion -ne $Version) {
    throw "Stable release version '$Version' does not match .service\version.txt ('$sourceVersion'). Update the version file before building."
}

if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
if (Test-Path $zip) { Remove-Item $zip -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null

$topFiles = @(
    'README.md','LICENSE.txt','THIRD_PARTY_NOTICES.md','ENGINE_VERSION','SHA256SUMS.txt',
    'service.bat','general.bat','general (ALT).bat','general (ALT3).bat','general (ALT5).bat',
    'general (ALT11).bat','general (FAKE TLS AUTO ALT2).bat','diagnose discord voice.bat',
    'compatibility wizard.bat'
)
$dirs = @('bin','lua','lists','presets','utils','windivert.filter','.service')
foreach ($file in $topFiles) { Copy-Item (Join-Path $root $file) $stage -Force }
foreach ($dir in $dirs) { Copy-Item (Join-Path $root $dir) (Join-Path $stage $dir) -Recurse -Force }
# Never publish the maintainer's local, ignored user lists in a release.
foreach ($name in @('list-general-user.txt', 'list-exclude-user.txt', 'ipset-exclude-user.txt')) {
    Remove-Item -LiteralPath (Join-Path $stage "lists\$name") -Force -ErrorAction SilentlyContinue
}
& (Join-Path $stage 'utils\ensure-user-lists.ps1') -Root $stage
[IO.File]::WriteAllText((Join-Path $stage '.service\version.txt'), "$Version`r`n", [Text.Encoding]::ASCII)

if ($Beta) {
    foreach ($file in @('START BETA TEST.bat', 'BETA_GUIDE_RU.txt')) {
        Copy-Item (Join-Path $root $file) $stage -Force
    }
}

foreach ($sourceOnlyPath in @(
    'utils\build-release.ps1',
    'utils\configure-repository.ps1',
    'utils\sync-upstream-ipset.ps1',
    'utils\test-custom-presets.ps1',
    'lists\ipset-all.txt.backup'
)) {
    Remove-Item (Join-Path $stage $sourceOnlyPath) -Force -ErrorAction SilentlyContinue
}

# The package must not inherit mutable owner settings from the source worktree.
$releaseModes = @{
    'game_filter.mode' = 'off'
    'ipset_filter.mode' = 'loaded'
    'voice_filter.mode' = 'compatible'
    'discord_fake.mode' = 'current'
    'game_fake.mode' = 'current'
}
foreach ($entry in $releaseModes.GetEnumerator()) {
    [IO.File]::WriteAllText((Join-Path $stage ('utils\' + $entry.Key)), $entry.Value + "`r`n", [Text.Encoding]::ASCII)
}
foreach ($experimentalPreset in @(
    'VOICE.txt.in', 'FAKE TLS AUTO.txt.in', 'SIMPLE FAKE.txt.in',
    'CUSTOM AGGRESSIVE.txt.in'
)) {
    Remove-Item (Join-Path $stage "presets\$experimentalPreset") -Force -ErrorAction SilentlyContinue
}
Compress-Archive -Path $stage -DestinationPath $zip -CompressionLevel Optimal
$zipHash = (Get-FileHash $zip -Algorithm SHA256).Hash
[IO.File]::WriteAllText((Join-Path $out 'release-sha256.txt'), "$zipHash  $(Split-Path $zip -Leaf)`r`n", [Text.Encoding]::ASCII)
Write-Host "Release archive: $zip" -ForegroundColor Green
Write-Host "SHA256: $zipHash" -ForegroundColor Green
