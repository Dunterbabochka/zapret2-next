[CmdletBinding()]
param([string]$OutputDirectory)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $OutputDirectory) { $OutputDirectory=Join-Path $root 'dist\issue-5-gw2' }
$output=[IO.Path]::GetFullPath($OutputDirectory)
if ($output -eq $root -or -not $output.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Output must stay inside the repository.' }
$source=Join-Path $PSScriptRoot 'issue-5-gw2'
$stage=Join-Path $output 'GW2-TEST'
$files=@('START.bat','RESTORE.bat','gw2-core.ps1','gw2-test.ps1','README_RU.txt')
if ([IO.Directory]::Exists($stage)) {
    $actual=@(Get-ChildItem -LiteralPath $stage -Force)
    if (@($actual | Where-Object { $_.PSIsContainer -or $_.Name -notin $files }).Count) { throw 'Staging folder contains unexpected files; use a fresh output directory.' }
}
[IO.Directory]::CreateDirectory($stage) | Out-Null
foreach ($name in $files) { Copy-Item -LiteralPath (Join-Path $source $name) -Destination (Join-Path $stage $name) -Force }
foreach ($name in @('gw2-core.ps1','gw2-test.ps1')) {
    $tokens=$null; $errors=$null
    $null=[Management.Automation.Language.Parser]::ParseFile((Join-Path $stage $name),[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw "PowerShell parse failed: $name" }
}
$zip=Join-Path $output 'GW2-TEST-Issue-5-r2.zip'
if ([IO.File]::Exists($zip)) { [IO.File]::Delete($zip) }
Compress-Archive -LiteralPath $stage -DestinationPath $zip
$rar=Join-Path $output 'GW2-TEST-Issue-5-r2.rar'
$rarExe=@('C:\Program Files\WinRAR\Rar.exe','C:\Program Files (x86)\WinRAR\Rar.exe') | Where-Object { [IO.File]::Exists($_) } | Select-Object -First 1
if ($rarExe) {
    if ([IO.File]::Exists($rar)) { [IO.File]::Delete($rar) }
    Push-Location $output
    try {
        & $rarExe a -r -idq $rar 'GW2-TEST'
        if ($LASTEXITCODE -ne 0) { throw 'RAR creation failed.' }
        & $rarExe t -idq $rar
        if ($LASTEXITCODE -ne 0) { throw 'RAR integrity check failed.' }
    } finally { Pop-Location }
}
Copy-Item -LiteralPath (Join-Path $source 'MESSAGE_RU.txt') -Destination (Join-Path $output 'MESSAGE_RU.txt') -Force
$hashes=@()
foreach ($path in @($zip)+@($rar | Where-Object { $rarExe })) {
    if ([IO.File]::Exists($path)) { $hashes+=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()+'  '+[IO.Path]::GetFileName($path) }
}
[IO.File]::WriteAllLines((Join-Path $output 'SHA256SUMS.txt'),$hashes,[Text.Encoding]::ASCII)
Write-Host ('Built: '+$output)
