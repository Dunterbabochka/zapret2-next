param([string]$Repository)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $Repository) {
    $login = (& gh api user --jq .login).Trim()
    if (-not $login) { throw 'Could not determine the authenticated GitHub login.' }
    $Repository = "$login/zapret2-next"
}
if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw "Invalid repository slug: $Repository" }
[IO.File]::WriteAllText((Join-Path $root '.service\repository.txt'), "$Repository`r`n", [Text.Encoding]::ASCII)
Write-Host "Repository configured: $Repository" -ForegroundColor Green
