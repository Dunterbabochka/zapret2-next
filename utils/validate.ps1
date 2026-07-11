param([switch]$Quick)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$presetDir = Join-Path $root 'presets'
$runtimeDir = Join-Path $root 'runtime\validation'
$renderer = Join-Path $PSScriptRoot 'render-config.ps1'
$errors = [Collections.Generic.List[string]]::new()
$warnings = [Collections.Generic.List[string]]::new()

function Add-ValidationError([string]$Message) {
    $script:errors.Add($Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

function Test-ReferencedFiles([string]$ConfigPath, [string]$PresetName) {
    $binDir = Join-Path $root 'bin'
    $content = Get-Content -LiteralPath $ConfigPath -Raw
    foreach ($match in [regex]::Matches($content, '@([^\s\r\n]+)')) {
        $relative = $match.Groups[1].Value.Trim('"')
        $path = [IO.Path]::GetFullPath((Join-Path $binDir ($relative -replace '/', '\')))
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            Add-ValidationError "$PresetName references a missing file: $relative"
        }
    }
}

$presets = Get-ChildItem -LiteralPath $presetDir -Filter '*.txt.in' |
    Where-Object { $_.BaseName -notlike '_*' } |
    Sort-Object Name
if ($presets.Count -lt 6) { Add-ValidationError "Only $($presets.Count) public presets found; at least 6 are required." }

$originalModePath = Join-Path $root 'utils\game_filter.mode'
$originalMode = if (Test-Path $originalModePath) { Get-Content $originalModePath -Raw } else { $null }
$modes = if ($Quick) { @('off') } else { @('off', 'tcp', 'udp', 'all') }

try {
    foreach ($mode in $modes) {
        [IO.File]::WriteAllText($originalModePath, "$mode`r`n", [Text.Encoding]::ASCII)
        foreach ($preset in $presets) {
            $name = $preset.BaseName -replace '\.txt$', ''
            $output = Join-Path $runtimeDir ("{0}-{1}.txt" -f ($name -replace ' ', '_'), $mode)
            try {
                & $renderer -Preset $name -Output $output | Out-Null
            } catch {
                Add-ValidationError "$name/$mode render failed: $($_.Exception.Message)"
                continue
            }

            $content = Get-Content -LiteralPath $output -Raw
            if ($content -match '\{\{') { Add-ValidationError "$name/$mode contains an unresolved token." }
            if ($content -match '--dpi-desync') { Add-ValidationError "$name/$mode contains a Zapret 1 option." }
            if ($content -notmatch '(?m)^--chdir\s*$') { Add-ValidationError "$name/$mode does not set --chdir." }
            if ($content -notmatch '(?m)^--lua-init=@\.\./lua/zapret-antidpi\.lua$') { Add-ValidationError "$name/$mode does not load the official antidpi library." }
            $expectedTcp = if ($mode -in @('tcp', 'all')) { '1024-65535' } else { '12' }
            $expectedUdp = if ($mode -in @('udp', 'all')) { '1024-65535' } else { '12' }
            if ($content -notmatch "(?m)^--filter-tcp=$([regex]::Escape($expectedTcp))$") { Add-ValidationError "$name/$mode has the wrong game TCP filter." }
            if ($content -notmatch "(?m)^--filter-udp=$([regex]::Escape($expectedUdp))$") { Add-ValidationError "$name/$mode has the wrong game UDP filter." }
            Test-ReferencedFiles -ConfigPath $output -PresetName "$name/$mode"
        }
    }
} finally {
    if ($null -eq $originalMode) {
        Remove-Item -LiteralPath $originalModePath -Force -ErrorAction SilentlyContinue
    } else {
        [IO.File]::WriteAllText($originalModePath, $originalMode, [Text.Encoding]::ASCII)
    }
}

$forbidden = Get-ChildItem -LiteralPath $root -Recurse -File |
    Where-Object { $_.FullName -notmatch '[\\/](THIRD_PARTY_NOTICES\.md|LICENSE\.txt|validate\.ps1)$' -and $_.Extension -in @('.md', '.bat', '.ps1', '.txt', '.in', '.yml', '.yaml') } |
    Select-String -Pattern 'Flowseal|zapret-discord-youtube|vpndiscordyooutube|bypassblock|zapretvpns' -CaseSensitive:$false
foreach ($hit in $forbidden) {
    Add-ValidationError "Forbidden branding in $($hit.Path):$($hit.LineNumber)"
}

if ($errors.Count -gt 0) {
    Write-Host "Validation failed with $($errors.Count) error(s)." -ForegroundColor Red
    exit 1
}
Write-Host "Validation passed: $($presets.Count) presets, modes: $($modes -join ', ')." -ForegroundColor Green
exit 0
