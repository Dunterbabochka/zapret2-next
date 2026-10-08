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

$stage = [IO.Path]::GetFullPath($stage)
$out = [IO.Path]::GetFullPath($out)
# Check resolved deletion targets before replacing an earlier build.
if (-not $stage.StartsWith($out.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or
    $root.StartsWith($stage.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or $stage -eq $root) {
    throw 'Release staging directory must remain inside the output directory and outside the source checkout.'
}
foreach ($sourceDir in @('bin','lua','lists','presets','utils','windivert.filter','.service')) {
    $sourcePath = (Join-Path $root $sourceDir).TrimEnd('\')
    if ($out -eq $sourcePath -or $out.StartsWith($sourcePath + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'OutputDirectory cannot be inside a packaged source directory.'
    }
}
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null

$topFiles = @(
    'README.md','LICENSE.txt','THIRD_PARTY_NOTICES.md','ENGINE_VERSION','SHA256SUMS.txt',
    'service.bat','general.bat','general (ALT).bat','general (ALT3).bat','general (ALT5).bat',
    'general (ALT11).bat','general (FAKE TLS AUTO ALT2).bat','diagnose discord voice.bat',
    'compatibility wizard.bat'
)
$dirs = @('bin','lua','lists','presets','utils','windivert.filter','.service')
foreach ($file in $topFiles) { Copy-Item (Join-Path $root $file) $stage -Force }
$publicDocs = @('MANUAL_TEST.md', 'STABILITY.md', 'COMPATIBILITY.md', 'CUSTOM-PARAMETERS.md', 'CUSTOM-PRESETS.md')
New-Item -ItemType Directory -Path (Join-Path $stage 'docs') -Force | Out-Null
foreach ($document in $publicDocs) {
    Copy-Item -LiteralPath (Join-Path $root ('docs\' + $document)) -Destination (Join-Path $stage 'docs') -Force
}
foreach ($dir in $dirs) {
    $sourceDir = Join-Path $root $dir
    foreach ($file in Get-ChildItem -LiteralPath $sourceDir -Recurse -File -Force) {
        if ($file.Name -match '\.(?:backup|bak|tmp|old|orig|swp|download|lock|log)$' -or
            $file.Name -in @('list-general-user.txt','list-exclude-user.txt','ipset-exclude-user.txt')) { continue }
        $relative = $file.FullName.Substring($root.Length + 1)
        $target = Join-Path $stage $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $target -Force
    }
}
# Always ship the bundled snapshot, not the maintainer's mutable loaded list.
Copy-Item -LiteralPath (Join-Path $stage '.service\ipset-service.txt') -Destination (Join-Path $stage 'lists\ipset-all.txt') -Force
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
