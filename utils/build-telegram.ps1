param([string]$Python = 'python')
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
& $Python (Join-Path $root 'packaging\build-telegram.py')
if ($LASTEXITCODE -ne 0) { throw "Telegram binary build failed (exit $LASTEXITCODE)." }
