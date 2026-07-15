param(
    [string]$Version = '0.1.0-beta.1',
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = Join-Path $root 'dist' }
$out = [IO.Path]::GetFullPath($OutputDirectory)
$work = Join-Path $out '_beta-build'
$kitName = "zapret2-next-beta-kit-$Version"
$kit = Join-Path $out $kitName
$zip = "$kit.zip"
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
if (Test-Path -LiteralPath $kit) { Remove-Item -LiteralPath $kit -Recurse -Force }
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
New-Item -ItemType Directory -Force -Path $work, $kit | Out-Null
& (Join-Path $PSScriptRoot 'build-release.ps1') -Version $Version -OutputDirectory $work
$releaseZip = Join-Path $work "zapret2-next-v$Version.zip"
$extract = Join-Path $work 'extracted'
Expand-Archive -LiteralPath $releaseZip -DestinationPath $extract -Force
$app = Join-Path $kit 'zapret2-next'
Move-Item -LiteralPath (Join-Path $extract ('zapret2-next-v' + $Version)) -Destination $app
Copy-Item -LiteralPath (Join-Path $root 'BETA_GUIDE_RU.txt'), (Join-Path $root 'BETA_COORDINATOR_RU.txt'), (Join-Path $root 'BETA_PRIVACY_RU.txt'), (Join-Path $root 'START BETA TEST.bat') -Destination $kit -Force
Get-ChildItem -LiteralPath $kit -Recurse -File | ForEach-Object { "{0}  {1}" -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash, $_.FullName.Substring($kit.Length + 1).Replace('\', '/') } | Set-Content -LiteralPath (Join-Path $kit 'CONTENTS-SHA256.txt') -Encoding ascii
Compress-Archive -Path $kit -DestinationPath $zip -CompressionLevel Optimal
$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
[IO.File]::WriteAllText("$zip.sha256", "$hash  $([IO.Path]::GetFileName($zip))
", [Text.Encoding]::ASCII)
Remove-Item -LiteralPath $work -Recurse -Force
Write-Host "Beta kit: $zip" -ForegroundColor Green
Write-Host "SHA256: $hash" -ForegroundColor Green
