param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9 _-]+$')]
    [string]$Preset,

    [Parameter(Mandatory = $true)]
    [string]$Output,

    [switch]$InterceptOff,

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$presetPath = Join-Path $root ("presets\{0}.txt.in" -f $Preset)
$basePath = Join-Path $root 'presets\_base.txt.in'
$profilesPath = Join-Path $root 'presets\_profiles.txt.in'

foreach ($path in @($presetPath, $basePath, $profilesPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required template not found: $path"
    }
}

$sections = @{}
$current = $null
foreach ($line in Get-Content -LiteralPath $presetPath) {
    if ($line -match '^\[([A-Z_]+)\]\s*$') {
        $current = $matches[1]
        if ($sections.ContainsKey($current)) {
            throw "Duplicate section [$current] in $presetPath"
        }
        $sections[$current] = [Collections.Generic.List[string]]::new()
        continue
    }
    if ($null -ne $current) {
        $sections[$current].Add($line)
    }
}

$required = @('TCP_HTTP', 'TCP_TLS', 'TCP_GENERIC', 'QUIC')
foreach ($name in $required) {
    if (-not $sections.ContainsKey($name) -or $sections[$name].Count -eq 0) {
        throw "Missing or empty section [$name] in $presetPath"
    }
}

$gameModePath = Join-Path $root 'utils\game_filter.mode'
$gameMode = 'off'
if (Test-Path -LiteralPath $gameModePath) {
    $value = (Get-Content -LiteralPath $gameModePath -TotalCount 1).Trim().ToLowerInvariant()
    if ($value -in @('off', 'tcp', 'udp', 'all')) { $gameMode = $value }
}

$gameTcp = if ($gameMode -in @('tcp', 'all')) { '1024-65535' } else { '12' }
$gameUdp = if ($gameMode -in @('udp', 'all')) { '1024-65535' } else { '12' }

$content = (Get-Content -LiteralPath $basePath -Raw) + "`r`n" + (Get-Content -LiteralPath $profilesPath -Raw)
foreach ($name in $required) {
    $value = ($sections[$name] -join "`r`n").Trim()
    $content = $content.Replace("{{$name}}", $value)
}
$content = $content.Replace('{{PRESET}}', $Preset)
$content = $content.Replace('{{GAME_MODE}}', $gameMode)
$content = $content.Replace('{{GAME_TCP}}', $gameTcp)
$content = $content.Replace('{{GAME_UDP}}', $gameUdp)

if ($content -match '\{\{[A-Z_]+\}\}') {
    throw "Unresolved template token: $($matches[0])"
}
if ($content -match '--dpi-desync') {
    throw 'Zapret 1 option found in generated Zapret 2 config'
}
if ($InterceptOff) {
    $content += "`r`n--intercept=0`r`n"
}
if ($DryRun) {
    $content += "`r`n--dry-run`r`n"
}

$outputPath = [IO.Path]::GetFullPath($Output)
$outputDir = Split-Path -Parent $outputPath
if (-not (Test-Path -LiteralPath $outputDir)) {
    New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
}
[IO.File]::WriteAllText($outputPath, $content.Trim() + "`r`n", [Text.Encoding]::ASCII)
Write-Output $outputPath
