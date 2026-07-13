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
    $serviceContent -notmatch '(?m)^echo {6}11\. Run Tests\r?$' -or
    $serviceContent -notmatch '(?m)^echo {6}12\. Discord Voice') {
    Add-ValidationError 'The two-digit service menu items are not aligned or Discord Voice is missing.'
}
if ($serviceContent -notmatch 'Select option \(0-12\):' -or
    $serviceContent -notmatch 'goto voice_filter' -or
    $serviceContent -notmatch 'Strategy: !CURRENT_PRESET!   Game: !GAME_MODE!   IPSet: !IPSET_MODE!   Voice: !VOICE_MODE!') {
    Add-ValidationError 'The service menu must expose the combined configuration status and Discord Voice control.'
}
if ($serviceContent -notmatch ':get_service_status' -or
    $serviceContent -notmatch 'Get-Service -Name' -or
    $serviceContent -notmatch 'call :wait_for_service_status Stopped' -or
    $serviceContent -notmatch 'call :wait_for_service_status Running') {
    Add-ValidationError 'The service manager must use locale-independent status reads and wait for stop/start transitions.'
}
if ($serviceContent -notmatch '(?m)^start "Zapret 2 NEXT tests" powershell -NoExit ') {
    Add-ValidationError 'The test console must stay open so failures remain visible.'
}
$ipsetMenuBlock = [regex]::Match($serviceContent, '(?ms)^:ipset_filter\r?\n.*?(?=^:[A-Za-z_]+\r?$)').Value
if ($ipsetMenuBlock -notmatch 'utils\\ipset_filter\.mode') {
    Add-ValidationError 'The IPSet menu must persist its selection in ipset_filter.mode.'
}
if ($ipsetMenuBlock -match 'ipset-all\.txt|IPSET_BACKUP|type nul|copy /y') {
    Add-ValidationError 'The IPSet menu must not mutate or restore the loaded IPSet source.'
}

$noneEntries = @(Get-Content -LiteralPath (Join-Path $root 'lists\ipset-none.txt') |
    ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
if ($noneEntries.Count -ne 1 -or $noneEntries[0] -ne '203.0.113.113/32') {
    Add-ValidationError 'ipset-none.txt must contain only the TEST-NET sentinel.'
}

$publicPresetNames = @('general', 'ALT', 'ALT3', 'ALT5', 'ALT11', 'FAKE TLS AUTO ALT2')
$presets = foreach ($name in $publicPresetNames) {
    $path = Join-Path $presetDir "$name.txt.in"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Add-ValidationError "Missing public preset: $name"
        continue
    }
    Get-Item -LiteralPath $path
}
if ($presets.Count -ne $publicPresetNames.Count) {
    Add-ValidationError "Expected $($publicPresetNames.Count) public presets; found $($presets.Count)."
}

$expectedPublicLaunchers = @(
    'general.bat', 'general (ALT).bat', 'general (ALT3).bat', 'general (ALT5).bat',
    'general (ALT11).bat', 'general (FAKE TLS AUTO ALT2).bat'
)
$rootBatches = @(Get-ChildItem -LiteralPath $root -Filter '*.bat' -File | Select-Object -ExpandProperty Name)
foreach ($launcher in $expectedPublicLaunchers) {
    if ($rootBatches -notcontains $launcher) { Add-ValidationError "Missing public launcher: $launcher" }
}
foreach ($experimentalLauncher in @('general (ALT12).bat', 'general (VOICE).bat', 'general (FAKE TLS AUTO).bat', 'general (SIMPLE FAKE).bat')) {
    if ($rootBatches -contains $experimentalLauncher) { Add-ValidationError "Experimental launcher must not be public: $experimentalLauncher" }
}
if ($rootBatches -notcontains 'diagnose discord voice.bat') {
    Add-ValidationError 'The Discord voice diagnostic launcher is missing.'
}

$releaseBuilder = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'build-release.ps1') -Raw
foreach ($requiredReleaseFile in @($expectedPublicLaunchers + 'diagnose discord voice.bat')) {
    if ($releaseBuilder -notmatch [regex]::Escape("'$requiredReleaseFile'")) {
        Add-ValidationError "Release allowlist is missing: $requiredReleaseFile"
    }
}
foreach ($excludedReleaseFile in @('general (ALT12).bat', 'general (VOICE).bat', 'general (FAKE TLS AUTO).bat', 'general (SIMPLE FAKE).bat')) {
    if ($releaseBuilder -match [regex]::Escape("'$excludedReleaseFile'")) {
        Add-ValidationError "Release allowlist includes an experimental launcher: $excludedReleaseFile"
    }
}
foreach ($excludedPreset in @('ALT12.txt.in', 'VOICE.txt.in', 'FAKE TLS AUTO.txt.in', 'SIMPLE FAKE.txt.in')) {
    if ($releaseBuilder -notmatch [regex]::Escape("'$excludedPreset'")) {
        Add-ValidationError "Release builder must remove experimental preset: $excludedPreset"
    }
}

$gameModes = if ($Quick) { @('off') } else { @('off', 'tcp', 'udp', 'all') }
$ipsetModes = if ($Quick) { @('loaded') } else { @('loaded', 'none', 'any') }
$voiceModes = if ($Quick) { @('compatible') } else { @('compatible', 'standard', 'off') }
$renderCount = 0
$expectedRootDir = $root.Replace('\', '/')
$expectedBinDir = [IO.Path]::GetFullPath((Join-Path $root 'bin')).Replace('\', '/')

function Get-ProfileLines([string]$Content, [string]$Marker) {
    $blocks = @(($Content -split '(?m)^--new\r?$') | Where-Object { $_.Contains($Marker) })
    if ($blocks.Count -ne 1) { return @() }
    return @($blocks[0] -split "`r?`n" |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith('#') })
}

function Get-SavedMode([string]$Path, [string]$Default, [string[]]$Allowed) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $lines = @(Get-Content -LiteralPath $Path -TotalCount 1)
        if ($lines.Count -gt 0) {
            $value = ([string]$lines[0]).Trim().ToLowerInvariant()
            if ($value -in $Allowed) { return $value }
        }
    }
    return $Default
}

$statePaths = @(
    (Join-Path $root 'utils\game_filter.mode'),
    (Join-Path $root 'utils\ipset_filter.mode'),
    (Join-Path $root 'utils\voice_filter.mode'),
    (Join-Path $root 'lists\ipset-all.txt')
)
$stateBefore = @{}
foreach ($path in $statePaths) {
    $stateBefore[$path] = if (Test-Path -LiteralPath $path -PathType Leaf) {
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    } else {
        '<missing>'
    }
}

foreach ($preset in $presets) {
    $presetTemplate = Get-Content -LiteralPath $preset.FullName -Raw
    $legacySections = @([regex]::Matches($presetTemplate, '(?m)^\[(?:WF_UDP|DISCORD_UDP|GAME_UDP)\]\s*$') |
        ForEach-Object { $_.Value })
    if ($legacySections.Count -gt 0) {
        Add-ValidationError "$($preset.Name) still couples a web preset to independent modes: $($legacySections -join ', ')."
    }
}

foreach ($gameMode in $gameModes) {
    foreach ($ipsetMode in $ipsetModes) {
        foreach ($voiceMode in $voiceModes) {
            foreach ($preset in $presets) {
                $name = $preset.BaseName -replace '\.txt$', ''
                $label = "$name/game=$gameMode/ipset=$ipsetMode/voice=$voiceMode"
                $safeName = $name -replace ' ', '_'
                $output = Join-Path $runtimeDir ("{0}-g-{1}-i-{2}-v-{3}.txt" -f $safeName, $gameMode, $ipsetMode, $voiceMode)
                try {
                    & $renderer -Preset $name -Output $output -GameMode $gameMode -IPSetMode $ipsetMode -VoiceMode $voiceMode | Out-Null
                    $renderCount++
                } catch {
                    Add-ValidationError "$label render failed: $($_.Exception.Message)"
                    continue
                }

                $content = Get-Content -LiteralPath $output -Raw
                $lines = @($content -split "`r?`n" | ForEach-Object { $_.Trim() })
                if ($content -match '\{\{') { Add-ValidationError "$label contains an unresolved token." }
                if ($content -match '--dpi-desync') { Add-ValidationError "$label contains a Zapret 1 option." }
                if ($content -match '(?:@|=)\.\./|@fake/') {
                    Add-ValidationError "$label contains a cwd-dependent resource path."
                }
                if ($lines -notcontains '--debug=0') { Add-ValidationError "$label unexpectedly enables debug logging." }
                if ($lines -notcontains ('--chdir="' + $expectedBinDir + '"')) {
                    Add-ValidationError "$label does not set an explicit quoted bin directory."
                }
                if ($lines -notcontains ('--lua-init=@"' + $expectedRootDir + '/lua/zapret-antidpi.lua"')) {
                    Add-ValidationError "$label does not load the official antidpi library."
                }
                foreach ($header in @(
                    "# Game filter: $gameMode",
                    "# IPSet filter: $ipsetMode",
                    "# Discord Voice: $voiceMode"
                )) {
                    if ($lines -notcontains $header) { Add-ValidationError "$label is missing header '$header'." }
                }

                $expectedTcp = if ($gameMode -in @('tcp', 'all')) { '1024-65535' } else { '12' }
                $expectedUdp = if ($gameMode -in @('udp', 'all')) { '1024-65535' } else { '12' }
                $gameTcpProfile = @(Get-ProfileLines -Content $content -Marker '# Optional game TCP filter')
                $gameUdpProfile = @(Get-ProfileLines -Content $content -Marker '# Optional game UDP profile')
                if ($gameTcpProfile.Count -eq 0 -or $gameTcpProfile[0] -ne "--filter-tcp=$expectedTcp") {
                    Add-ValidationError "$label has the wrong Game TCP profile."
                }
                if ($gameUdpProfile.Count -eq 0 -or $gameUdpProfile[0] -ne "--filter-udp=$expectedUdp") {
                    Add-ValidationError "$label has the wrong Game UDP profile."
                }

                $expectedVoiceProfile = switch ($voiceMode) {
                    'compatible' {
                        @(
                            '--filter-udp=1024-65535'
                            '--filter-l7=stun,discord'
                            '--payload=stun,discord_ip_discovery'
                            '--lua-desync=fake:blob=discord_voice:repeats=3'
                            '--payload=all'
                            '--out-range=n2-n4'
                            '--lua-desync=fake:blob=discord_voice:repeats=10'
                        )
                    }
                    'standard' {
                        @(
                            '--filter-udp=1024-65535'
                            '--filter-l7=stun,discord'
                            '--payload=stun,discord_ip_discovery'
                            '--lua-desync=fake:blob=0x00000000000000000000000000000000:repeats=2'
                        )
                    }
                    'off' {
                        @(
                            '--filter-udp=1024-65535'
                            '--filter-l7=stun,discord'
                        )
                    }
                }
                $voiceMarker = '# Discord Voice (must stay before the Game UDP fallback)'
                $voiceProfile = @(Get-ProfileLines -Content $content -Marker $voiceMarker)
                if (($voiceProfile -join "`n") -cne ($expectedVoiceProfile -join "`n")) {
                    Add-ValidationError "$label has the wrong Discord Voice profile."
                }
                $voiceIndex = $content.IndexOf($voiceMarker, [StringComparison]::Ordinal)
                $gameUdpIndex = $content.IndexOf('# Optional game UDP profile', [StringComparison]::Ordinal)
                if ($voiceIndex -lt 0 -or $gameUdpIndex -lt 0 -or $voiceIndex -ge $gameUdpIndex) {
                    Add-ValidationError "$label does not keep Discord Voice before the Game UDP fallback."
                }

                $expectedWfUdp = if ($voiceMode -eq 'compatible' -or $gameMode -in @('udp', 'all')) {
                    '1024-65535'
                } else {
                    "443,19294-19344,50000-50100,$expectedUdp"
                }
                if ($lines -notcontains "--wf-udp-out=$expectedWfUdp") {
                    Add-ValidationError "$label has the wrong UDP interception range."
                }

                $ipsetLines = @($lines | Where-Object { $_ -match '^--ipset=' })
                if ($ipsetMode -eq 'any') {
                    if ($ipsetLines.Count -ne 0) { Add-ValidationError "$label must not constrain profiles with an IPSet." }
                } else {
                    $ipsetFile = if ($ipsetMode -eq 'loaded') { 'ipset-all.txt' } else { 'ipset-none.txt' }
                    $expectedIPSetPath = [IO.Path]::GetFullPath((Join-Path $root "lists\$ipsetFile")).Replace('\', '/')
                    $expectedIPSetLine = '--ipset="' + $expectedIPSetPath + '"'
                    if ($ipsetLines.Count -ne 4 -or @($ipsetLines | Where-Object { $_ -eq $expectedIPSetLine }).Count -ne 4) {
                        Add-ValidationError "$label does not use the stable $ipsetMode IPSet source in every fallback profile."
                    }
                }

                Test-ReferencedFiles -ConfigPath $output -PresetName $label
            }
        }
    }
}

$dryOutput = Join-Path $runtimeDir 'general-dry-run.txt'
try {
    & $renderer -Preset 'general' -Output $dryOutput -GameMode off -IPSetMode loaded -VoiceMode compatible -DryRun | Out-Null
    $dryLines = @(Get-Content -LiteralPath $dryOutput | ForEach-Object { $_.Trim() })
    if ($dryLines -notcontains '--dry-run') { Add-ValidationError 'Dry-run config does not enable --dry-run.' }
    if ($dryLines -notcontains '--wf-dup-check=0') { Add-ValidationError 'Dry-run config does not disable duplicate-filter checks.' }
} catch {
    Add-ValidationError "Dry-run render failed: $($_.Exception.Message)"
}

$debugOutput = Join-Path $runtimeDir 'general-debug-override.txt'
$debugLog = Join-Path $runtimeDir 'renderer debug.log'
try {
    & $renderer -Preset 'general' -Output $debugOutput -GameMode off -IPSetMode any -VoiceMode off -DebugLog $debugLog | Out-Null
    $debugLines = @(Get-Content -LiteralPath $debugOutput | ForEach-Object { $_.Trim() })
    $expectedDebugPath = [IO.Path]::GetFullPath($debugLog).Replace('\', '/')
    if ($debugLines -notcontains ('--debug=@"' + $expectedDebugPath + '"')) {
        Add-ValidationError 'DebugLog override is not rendered as an absolute quoted path.'
    }
} catch {
    Add-ValidationError "DebugLog override render failed: $($_.Exception.Message)"
}

$savedOutput = Join-Path $runtimeDir 'general-saved-modes.txt'
try {
    & $renderer -Preset 'general' -Output $savedOutput | Out-Null
    $savedLines = @(Get-Content -LiteralPath $savedOutput | ForEach-Object { $_.Trim() })
    $savedGameMode = Get-SavedMode (Join-Path $root 'utils\game_filter.mode') 'off' @('off', 'tcp', 'udp', 'all')
    $savedIPSetMode = Get-SavedMode (Join-Path $root 'utils\ipset_filter.mode') 'loaded' @('loaded', 'none', 'any')
    $savedVoiceMode = Get-SavedMode (Join-Path $root 'utils\voice_filter.mode') 'compatible' @('compatible', 'standard', 'off')
    foreach ($header in @(
        "# Game filter: $savedGameMode",
        "# IPSet filter: $savedIPSetMode",
        "# Discord Voice: $savedVoiceMode"
    )) {
        if ($savedLines -notcontains $header) { Add-ValidationError "Saved-mode render is missing header '$header'." }
    }
} catch {
    Add-ValidationError "Saved-mode render failed: $($_.Exception.Message)"
}

foreach ($path in $statePaths) {
    $stateAfter = if (Test-Path -LiteralPath $path -PathType Leaf) {
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    } else {
        '<missing>'
    }
    if ($stateAfter -ne $stateBefore[$path]) {
        Add-ValidationError "Validation changed user state: $path"
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
Write-Host "Validation passed: $($presets.Count) presets, $renderCount configurations (Game: $($gameModes -join ', '); IPSet: $($ipsetModes -join ', '); Voice: $($voiceModes -join ', '))." -ForegroundColor Green
exit 0
