param(
    [switch]$SkipLuaLoad,
    [switch]$AllowEmptyIPSet
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$renderer = Join-Path $PSScriptRoot 'render-config.ps1'
$winws = Join-Path $root 'bin\winws2.exe'
$ipsetPath = Join-Path $root 'lists\ipset-all.txt'
$ipsetEntryCount = if (Test-Path -LiteralPath $ipsetPath -PathType Leaf) {
    @((Get-Content -LiteralPath $ipsetPath) | Where-Object { $_ -notmatch '^\s*(?:#|$)' }).Count
} else {
    0
}
$presets = Get-ChildItem (Join-Path $root 'presets') -Filter '*.txt.in' |
    Where-Object { $_.BaseName -notlike '_*' } | Sort-Object Name
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host '[ERROR] Run this runtime validation from an elevated PowerShell window.' -ForegroundColor Red
    exit 1
}
if ($ipsetEntryCount -eq 0 -and -not $AllowEmptyIPSet) {
    Write-Host '[ERROR] IPSet=loaded requires a populated lists\ipset-all.txt. Update the list or pass -AllowEmptyIPSet only for a diagnostic run.' -ForegroundColor Red
    exit 1
}
if ($AllowEmptyIPSet) {
    Write-Host '[WARN] Empty IPSet explicitly allowed for diagnostic runtime validation; this is not a loaded-IPSet acceptance run.' -ForegroundColor Yellow
}
$failures = @()

foreach ($file in $presets) {
    $name = $file.BaseName -replace '\.txt$', ''
    $safe = $name -replace ' ', '_'
    $dryConfig = Join-Path $root "runtime\runtime-check-$safe-dry.txt"
    & $renderer -Preset $name -Output $dryConfig -DryRun | Out-Null
    $dryOutput = & $winws ('@"' + $dryConfig + '"') 2>&1
    if ($LASTEXITCODE -ne 0) {
        $failures += "$name dry-run failed ($LASTEXITCODE): $($dryOutput -join ' ')"
        continue
    }
    Write-Host "[OK] $name argument and file validation" -ForegroundColor Green

    if (-not $SkipLuaLoad) {
        $luaConfig = Join-Path $root "runtime\runtime-check-$safe-lua.txt"
        & $renderer -Preset $name -Output $luaConfig -InterceptOff | Out-Null
        $luaOutput = & $winws ('@"' + $luaConfig + '"') 2>&1
        if ($LASTEXITCODE -ne 0) {
            $failures += "$name Lua initialization failed ($LASTEXITCODE): $($luaOutput -join ' ')"
        } else {
            Write-Host "[OK] $name Lua initialization" -ForegroundColor Green
        }
    }
}

if ($failures) {
    $failures | ForEach-Object { Write-Host "[ERROR] $_" -ForegroundColor Red }
    exit 1
}
Write-Host "Runtime validation passed for $($presets.Count) presets." -ForegroundColor Green
exit 0
