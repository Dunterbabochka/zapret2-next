param(
    [string]$Version = '0.1.0',
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\dist')
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$out = [IO.Path]::GetFullPath($OutputDirectory)
$stage = Join-Path $out "zapret2-next-v$Version"
$zip = Join-Path $out "zapret2-next-v$Version.zip"

if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
if (Test-Path $zip) { Remove-Item $zip -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null

$topFiles = @(
    'README.md','LICENSE.txt','THIRD_PARTY_NOTICES.md','ENGINE_VERSION','SHA256SUMS.txt',
    'service.bat','general.bat','general (ALT).bat','general (ALT3).bat','general (ALT5).bat',
    'general (ALT11).bat','general (ALT12).bat','general (FAKE TLS AUTO).bat','general (FAKE TLS AUTO ALT2).bat',
    'general (SIMPLE FAKE).bat'
)
$dirs = @('bin','lua','lists','presets','utils','windivert.filter','.service')
foreach ($file in $topFiles) { Copy-Item (Join-Path $root $file) $stage -Force }
foreach ($dir in $dirs) { Copy-Item (Join-Path $root $dir) (Join-Path $stage $dir) -Recurse -Force }
Remove-Item (Join-Path $stage 'utils\build-release.ps1') -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $stage 'utils\configure-repository.ps1') -Force -ErrorAction SilentlyContinue

Compress-Archive -Path $stage -DestinationPath $zip -CompressionLevel Optimal
$zipHash = (Get-FileHash $zip -Algorithm SHA256).Hash
[IO.File]::WriteAllText((Join-Path $out 'release-sha256.txt'), "$zipHash  $(Split-Path $zip -Leaf)`r`n", [Text.Encoding]::ASCII)
Write-Host "Release archive: $zip" -ForegroundColor Green
Write-Host "SHA256: $zipHash" -ForegroundColor Green
