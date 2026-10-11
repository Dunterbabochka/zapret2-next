param(
    [Parameter(Mandatory)]
    [ValidatePattern('^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')]
    [string]$Version,
    [string]$OutputDirectory,
    [switch]$Beta
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'telegram-control.ps1')
Assert-ZapretTelegramRuntime -Root $root
. (Join-Path $PSScriptRoot 'preset-catalog.ps1')
$strategyLaunchers = @($publicPresets | ForEach-Object {
    if ($_ -eq 'general') { 'general.bat' } else { "general ($_)" + '.bat' }
})
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
foreach ($sourceDir in @('bin','lua','lists','presets','utils','strategies','.service')) {
    $sourcePath = (Join-Path $root $sourceDir).TrimEnd('\')
    if ($out -eq $sourcePath -or $out.StartsWith($sourcePath + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'OutputDirectory cannot be inside a packaged source directory.'
    }
}
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null

$topFiles = @(
    'README.md','LICENSE.txt','SECURITY.md','THIRD_PARTY_NOTICES.md','ENGINE_VERSION','SHA256SUMS.txt',
    'service.bat'
)
$dirs = @('bin','lua','lists','presets','utils','strategies','.service')
foreach ($file in $topFiles) { Copy-Item (Join-Path $root $file) $stage -Force }
$publicDocs = @('MANUAL_TEST.md', 'STABILITY.md', 'COMPATIBILITY.md', 'CUSTOM-PARAMETERS.md', 'TELEGRAM.md', 'ADVANCED.md', 'MAINTAINING.md', 'SUPPORT.md')
New-Item -ItemType Directory -Path (Join-Path $stage 'docs') -Force | Out-Null
foreach ($document in $publicDocs) {
    Copy-Item -LiteralPath (Join-Path $root ('docs\' + $document)) -Destination (Join-Path $stage 'docs') -Force
}
foreach ($dir in $dirs) {
    $sourceDir = Join-Path $root $dir
    foreach ($file in Get-ChildItem -LiteralPath $sourceDir -Recurse -File -Force) {
        if ($dir -eq 'strategies' -and $file.Name -notin $strategyLaunchers) { continue }
        if ($file.Name -match '\.(?:backup|bak|tmp|old|orig|swp|download|lock|log)$' -or
            $file.Name -in @('list-general-user.txt','list-exclude-user.txt','ipset-exclude-user.txt')) { continue }
        $relative = $file.FullName.Substring($root.Length + 1)
        $target = Join-Path $stage $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $target -Force
    }
}
foreach ($launcher in $strategyLaunchers) {
    if (-not (Test-Path -LiteralPath (Join-Path $stage ('strategies\' + $launcher)) -PathType Leaf)) {
        throw "Missing public strategy launcher: $launcher"
    }
}
# Only provenance and the upstream license are shipped; developer Python
# sources and tests stay outside the ready-to-use Windows archive.
$telegramNoticeDir = Join-Path $stage 'docs\third_party\tg-ws-proxy'
New-Item -ItemType Directory -Path $telegramNoticeDir -Force | Out-Null
foreach ($notice in @('LICENSE', 'SOURCE.json')) {
    Copy-Item -LiteralPath (Join-Path $root "packaging\third_party\tg-ws-proxy\$notice") -Destination $telegramNoticeDir -Force
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
    Copy-Item -LiteralPath (Join-Path $root 'docs\BETA_GUIDE_RU.txt') -Destination (Join-Path $stage 'docs') -Force
} else {
    Remove-Item -LiteralPath (Join-Path $stage 'utils\START BETA TEST.bat') -Force
}

foreach ($sourceOnlyPath in @(
    'utils\build-release.ps1',
    'utils\build-telegram.ps1',
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
    'NEXT AGGRESSIVE.txt.in'
)) {
    Remove-Item (Join-Path $stage "presets\$experimentalPreset") -Force -ErrorAction SilentlyContinue
}
Compress-Archive -Path $stage -DestinationPath $zip -CompressionLevel Optimal
$zipHash = (Get-FileHash $zip -Algorithm SHA256).Hash
[IO.File]::WriteAllText((Join-Path $out 'release-sha256.txt'), "$zipHash  $(Split-Path $zip -Leaf)`r`n", [Text.Encoding]::ASCII)
Write-Host "Release archive: $zip" -ForegroundColor Green
Write-Host "SHA256: $zipHash" -ForegroundColor Green
