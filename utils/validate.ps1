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
    $references = [Collections.Generic.List[string]]::new()
    foreach ($match in [regex]::Matches($content, '@(?:"([^"]+)"|([^\s\r\n]+))')) {
        $value = if ($match.Groups[1].Success) { $match.Groups[1].Value } else { $match.Groups[2].Value }
        $references.Add($value)
    }
    foreach ($match in [regex]::Matches(
        $content,
        '(?m)^--(?:hostlist|hostlist-exclude|ipset|ipset-exclude)=(?:"([^"]+)"|([^\r\n]+))$'
    )) {
        $value = if ($match.Groups[1].Success) { $match.Groups[1].Value } else { $match.Groups[2].Value }
        $references.Add($value)
    }
    foreach ($reference in $references) {
        $native = $reference -replace '/', '\'
        $path = if ([IO.Path]::IsPathRooted($native)) {
            [IO.Path]::GetFullPath($native)
        } else {
            [IO.Path]::GetFullPath((Join-Path $binDir $native))
        }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            Add-ValidationError "$PresetName references a missing file: $reference"
        }
    }
}

foreach ($scriptPath in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File) {
    $tokens = $null
    $parseErrors = $null
    [Management.Automation.Language.Parser]::ParseFile(
        $scriptPath.FullName,
        [ref]$tokens,
        [ref]$parseErrors
    ) | Out-Null
    foreach ($parseError in $parseErrors) {
        Add-ValidationError "$($scriptPath.Name) has a syntax error: $($parseError.Message)"
    }
}

$runnerContent = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'run-preset.bat') -Raw
if ($runnerContent -notmatch 'invoke-winws\.ps1') {
    Add-ValidationError 'run-preset.bat must use the logging winws2 launcher.'
}

$serviceContent = Get-Content -LiteralPath (Join-Path $root 'service.bat') -Raw
if ($serviceContent -notmatch '(?m)^echo {6}10\. Run Diagnostics\r?$' -or
    $serviceContent -notmatch '(?m)^echo {6}11\. Run Tests\r?$') {
    Add-ValidationError 'The two-digit service menu items are not aligned.'
}
if ($serviceContent -notmatch '(?m)^start "Zapret 2 NEXT tests" powershell -NoExit ') {
    Add-ValidationError 'The test console must stay open so failures remain visible.'
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
            $lines = @($content -split "`r?`n" | ForEach-Object { $_.Trim() })
            if ($content -match '\{\{') { Add-ValidationError "$name/$mode contains an unresolved token." }
            if ($content -match '--dpi-desync') { Add-ValidationError "$name/$mode contains a Zapret 1 option." }
            if ($content -match '(?:@|=)\.\./|@fake/') {
                Add-ValidationError "$name/$mode contains a cwd-dependent resource path."
            }
            $expectedRootDir = $root.Replace('\', '/')
            $expectedBinDir = [IO.Path]::GetFullPath((Join-Path $root 'bin')).Replace('\', '/')
            if ($lines -notcontains ('--chdir="' + $expectedBinDir + '"')) {
                Add-ValidationError "$name/$mode does not set an explicit quoted bin directory."
            }
            if ($lines -notcontains ('--lua-init=@"' + $expectedRootDir + '/lua/zapret-antidpi.lua"')) {
                Add-ValidationError "$name/$mode does not load the official antidpi library."
            }
            $expectedTcp = if ($mode -in @('tcp', 'all')) { '1024-65535' } else { '12' }
            $expectedUdp = if ($mode -in @('udp', 'all')) { '1024-65535' } else { '12' }
            if ($lines -notcontains "--filter-tcp=$expectedTcp") { Add-ValidationError "$name/$mode has the wrong game TCP filter." }
            if ($lines -notcontains "--filter-udp=$expectedUdp") { Add-ValidationError "$name/$mode has the wrong game UDP filter." }
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
