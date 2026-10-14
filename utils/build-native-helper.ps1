param([Parameter(Mandatory)][string]$Output)
$ErrorActionPreference='Stop'
$outputPath=[IO.Path]::GetFullPath($Output)
if ([IO.File]::Exists($outputPath)) { throw 'Native helper output already exists. Use a fresh staging directory.' }
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($outputPath)) | Out-Null
# The inline source remains the fallback for source checkouts and recovery workers.
$source=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'telegram-control.ps1'))
$match=[regex]::Match($source,"(?s)Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@ -ErrorAction Stop")
if (-not $match.Success) { throw 'Native shell source was not found.' }
Add-Type -TypeDefinition $match.Groups[1].Value -OutputAssembly $outputPath -ErrorAction Stop
