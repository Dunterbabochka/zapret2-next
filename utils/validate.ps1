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
if ($serviceContent -notmatch 'accepted_service_presets\.txt' -or
    $serviceContent -notmatch 'Accepted local experimental presets' -or
    $serviceContent -notmatch 'CUSTOM SAFE' -or
    $serviceContent -notmatch 'ALT12' -or
    $serviceContent -notmatch 'CUSTOM BALANCED') {
    Add-ValidationError 'The service menu must expose the accepted local preset marker and its SAFE/ALT12/BALANCED labels.'
}
$acceptedServiceMarkerPath = Join-Path $PSScriptRoot 'accepted_service_presets.txt'
if (Test-Path -LiteralPath $acceptedServiceMarkerPath -PathType Leaf) {
    $acceptedServiceNames = @((Get-Content -LiteralPath $acceptedServiceMarkerPath) |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith('#') })
    $acceptedServiceAllowed = @('CUSTOM SAFE', 'ALT12', 'CUSTOM BALANCED')
    foreach ($acceptedServiceName in $acceptedServiceNames) {
        if ($acceptedServiceAllowed -notcontains $acceptedServiceName) {
            Add-ValidationError "Unknown or unaccepted local service preset: $acceptedServiceName"
            continue
        }
        $acceptedServicePresetPath = Join-Path $presetDir ($acceptedServiceName + '.txt.in')
        if (-not (Test-Path -LiteralPath $acceptedServicePresetPath -PathType Leaf)) {
            Add-ValidationError "Accepted local service preset is missing its template: $acceptedServiceName"
        }
    }
    if (@($acceptedServiceNames | Sort-Object -Unique).Count -ne $acceptedServiceNames.Count) {
        Add-ValidationError 'accepted_service_presets.txt must not contain duplicate preset names.'
    }
    if ($acceptedServiceNames -contains 'CUSTOM AGGRESSIVE') {
        Add-ValidationError 'CUSTOM AGGRESSIVE must remain out of the local service marker until voice acceptance exists.'
    }
}
$ipsetMenuBlock = [regex]::Match($serviceContent, '(?ms)^:ipset_filter\r?\n.*?(?=^:[A-Za-z_]+\r?$)').Value
if ($ipsetMenuBlock -notmatch 'utils\\ipset_filter\.mode') {
    Add-ValidationError 'The IPSet menu must persist its selection in ipset_filter.mode.'
}
if ($ipsetMenuBlock -match 'newmode=any' -or $ipsetMenuBlock -notmatch '(?i)any is diagnostic') {
    Add-ValidationError 'The service IPSet menu must keep any diagnostic-only and must not persist it as a normal cycle mode.'
}
if ($ipsetMenuBlock -match 'ipset-all\.txt|IPSET_BACKUP|type nul|copy /y') {
    Add-ValidationError 'The IPSet menu must not mutate or restore the loaded IPSet source.'
}

$noneEntries = @(Get-Content -LiteralPath (Join-Path $root 'lists\ipset-none.txt') |
    ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
if ($noneEntries.Count -ne 1 -or $noneEntries[0] -ne '203.0.113.113/32') {
    Add-ValidationError 'ipset-none.txt must contain only the TEST-NET sentinel.'
}
$discordWebListPath = Join-Path $root 'lists\list-discord-web.txt'
$discordWebEntries = if (Test-Path -LiteralPath $discordWebListPath -PathType Leaf) {
    @((Get-Content -LiteralPath $discordWebListPath) |
        ForEach-Object { $_.Trim().ToLowerInvariant() } |
        Where-Object { $_ -and -not $_.StartsWith('#') })
} else {
    @()
}
$customPresetFilesPresent = @('CUSTOM SAFE.txt.in', 'CUSTOM BALANCED.txt.in', 'CUSTOM AGGRESSIVE.txt.in' |
    Where-Object { Test-Path -LiteralPath (Join-Path $presetDir $_) -PathType Leaf }).Count -gt 0
if ($customPresetFilesPresent) {
    foreach ($requiredDiscordWebDomain in @('discord.com', 'gateway.discord.gg', 'cdn.discordapp.com', 'updates.discord.com')) {
        if ($discordWebEntries -notcontains $requiredDiscordWebDomain) {
            Add-ValidationError "Discord Web hostlist is missing: $requiredDiscordWebDomain"
        }
    }
}
$loadedIPSetPath = Join-Path $root 'lists\ipset-all.txt'
$loadedIPSetHasEntries = (Test-Path -LiteralPath $loadedIPSetPath -PathType Leaf) -and
    @((Get-Content -LiteralPath $loadedIPSetPath) | Where-Object { $_ -notmatch '^\s*(?:#|$)' }).Count -gt 0

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
$voiceDiagnosticContent = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'discord-voice-diagnostic.ps1') -Raw
foreach ($voiceDiagnosticToken in @(
    'AllowEmptyIPSet', 'AllowContaminatedNetwork', 'LoadedIPSetEntries',
    'NetworkContaminated', 'AcceptanceEligible', 'RawTwoWayAudioObserved'
)) {
    if ($voiceDiagnosticContent -notmatch [regex]::Escape($voiceDiagnosticToken)) {
        Add-ValidationError "Discord voice diagnostic contract is missing: $voiceDiagnosticToken"
    }
}
if ($voiceDiagnosticContent -match '(?s)\$oldWinws\s*\|\s*Stop-Process') {
    Add-ValidationError 'Discord voice diagnostic must not silently stop a pre-existing manual winws2 process.'
}

$releaseBuilderPath = Join-Path $PSScriptRoot 'build-release.ps1'
$releaseBuilderAvailable = Test-Path -LiteralPath $releaseBuilderPath -PathType Leaf
$releaseBuilder = if ($releaseBuilderAvailable) { Get-Content -LiteralPath $releaseBuilderPath -Raw } else { '' }
if ($releaseBuilderAvailable) {
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
    foreach ($excludedPreset in @(
        'ALT12.txt.in', 'VOICE.txt.in', 'FAKE TLS AUTO.txt.in', 'SIMPLE FAKE.txt.in',
        'CUSTOM SAFE.txt.in', 'CUSTOM BALANCED.txt.in', 'CUSTOM AGGRESSIVE.txt.in'
    )) {
        if ($releaseBuilder -notmatch [regex]::Escape("'$excludedPreset'")) {
            Add-ValidationError "Release builder must remove experimental preset: $excludedPreset"
        }
    }
}

if ($releaseBuilderAvailable -and $releaseBuilder -notmatch 'accepted_service_presets\.txt') {
    Add-ValidationError 'Release builder must remove the local accepted service marker.'
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

$alt12Path = Join-Path $presetDir 'ALT12.txt.in'
if (Test-Path -LiteralPath $alt12Path -PathType Leaf) {
    $alt12Output = Join-Path $runtimeDir 'ALT12-candidate-validate.txt'
    $alt12MaxBlob = Join-Path $root 'bin\fake\tls_clienthello_max_ru.bin'
    if (-not (Test-Path -LiteralPath $alt12MaxBlob -PathType Leaf) -or
        (Get-Item -LiteralPath $alt12MaxBlob).Length -ne 664) {
        Add-ValidationError 'ALT12 requires the 664-byte tls_clienthello_max_ru.bin blob.'
    }
    try {
        & $renderer -Preset 'ALT12' -Output $alt12Output -GameMode off -IPSetMode loaded -VoiceMode compatible | Out-Null
        $alt12Content = Get-Content -LiteralPath $alt12Output -Raw
        $alt12Lines = @($alt12Content -split "`r?`n" | ForEach-Object { $_.Trim() })
        if ($alt12Content -match '\{\{|--dpi-desync|@fake/|\.\./') { Add-ValidationError 'ALT12 candidate contains an unresolved token, Zapret 1 option, or relative resource path.' }
        if ($alt12Lines -notcontains '--wf-udp-out=443,19294-19344,50000-50100,12') { Add-ValidationError 'ALT12 candidate does not preserve the legacy UDP interception range.' }
        $alt12Voice = @(Get-ProfileLines -Content $alt12Content -Marker '# Discord Voice (must stay before the Game UDP fallback)')
        $expectedAlt12Voice = @(
            '--filter-udp=19294-19344,50000-50100'
            '--filter-l7=discord,stun'
            '--payload=discord_ip_discovery'
            '--lua-desync=fake:blob=stun:repeats=3'
            '--lua-desync=fake:blob=discord_voice:repeats=3'
            '--payload=stun'
            '--lua-desync=fake:blob=discord_voice:repeats=3'
        )
        if (($alt12Voice -join "`n") -cne ($expectedAlt12Voice -join "`n")) { Add-ValidationError 'ALT12 candidate does not preserve the three-fake legacy voice sequence.' }
        $alt12Discord = @(Get-ProfileLines -Content $alt12Content -Marker '# Discord media TLS')
        $expectedAlt12Discord = @(
            '--filter-tcp=2053,2083,2087,2096,8443'
            '--hostlist-domains=discord.media'
            '--payload=tls_client_hello'
            '--out-range=-d10'
            '--lua-desync=fake:blob=tls_google:tcp_ts=-1000:repeats=8'
            '--lua-desync=multisplit:pos=1:seqovl=681:seqovl_pattern=tls_google:tcp_ts_up'
        )
        if (($alt12Discord -join [Environment]::NewLine) -cne ($expectedAlt12Discord -join [Environment]::NewLine)) { Add-ValidationError 'ALT12 candidate does not preserve the isolated Discord media split profile.' }
        $alt12Google = @(Get-ProfileLines -Content $alt12Content -Marker '# Google/YouTube TLS')
        if ($alt12Google -notcontains '--lua-desync=hostfakesplit:host=www.google.com:ip_id=zero:tcp_ts=-1000:tcp_ts_up') { Add-ValidationError 'ALT12 candidate is missing the isolated Google hostfakesplit profile.' }
        if ($alt12Discord -contains '--lua-desync=hostfakesplit:host=www.google.com:ip_id=zero:tcp_ts=-1000:tcp_ts_up') { Add-ValidationError 'ALT12 hostfakesplit leaked into the Discord media profile.' }
        $expectedAlt12General = @(
            '--lua-desync=fake:blob=tls_max:tcp_ts=-1000:repeats=8'
            '--lua-desync=multisplit:pos=1:seqovl=664:seqovl_pattern=tls_max:tcp_ts_up'
        )
        foreach ($marker in @('# General HTTP', '# General TLS', '# IPSet fallback TCP', '# Optional game TCP filter')) {
            $profile = @(Get-ProfileLines -Content $alt12Content -Marker $marker)
            $profileActions = @($profile | Where-Object { $_ -match '^--lua-desync=' })
            if (($profileActions -join [Environment]::NewLine) -cne ($expectedAlt12General -join [Environment]::NewLine)) {
                Add-ValidationError "ALT12 candidate does not preserve the FlowSeal general profile in $marker."
            }
        }
        $alt12IpSetTcp = @(Get-ProfileLines -Content $alt12Content -Marker '# IPSet fallback TCP')
        if ($alt12IpSetTcp -notcontains '--filter-tcp=80,443,8443') { Add-ValidationError 'ALT12 candidate does not include the FlowSeal IPSet TCP port 8443.' }
        if ($alt12Content -notmatch 'tls_clienthello_max_ru\.bin') { Add-ValidationError 'ALT12 candidate does not reference tls_clienthello_max_ru.bin.' }
        Test-ReferencedFiles -ConfigPath $alt12Output -PresetName 'ALT12 candidate'
    } catch {
        Add-ValidationError "ALT12 candidate render failed: $($_.Exception.Message)"
    }
}

# The Discord Web scope is intentionally experimental. Public presets must keep
# their previous hostlist set and must not reference the CUSTOM-only list.
foreach ($publicPreset in $publicPresetNames) {
    $publicOutput = Join-Path $runtimeDir (('public-{0}-behavior.txt' -f ($publicPreset -replace ' ', '_')))
    try {
        & $renderer -Preset $publicPreset -Output $publicOutput -GameMode off -IPSetMode loaded -VoiceMode compatible | Out-Null
        $publicContent = Get-Content -LiteralPath $publicOutput -Raw
        if ($publicContent -match 'list-discord-web\.txt') {
            Add-ValidationError "$publicPreset unexpectedly references the CUSTOM-only Discord Web hostlist."
        }
    } catch {
        Add-ValidationError "$publicPreset public-behavior render failed: $($_.Exception.Message)"
    }
}

$customDefinitions = @(
    [pscustomobject]@{
        Name = 'CUSTOM SAFE'
        RequireTlsMax = $false
        RequirePort8443 = $false
        MaxRepeats = 4
        RequiredLines = @(
            '--lua-desync=fake:blob=http_iana:tcp_ts=-1000:repeats=3'
            '--lua-desync=multisplit:pos=2:seqovl=1:seqovl_pattern=zero:tcp_ts_up'
            '--lua-desync=fake:blob=tls_google:tcp_ts=-1000:repeats=3'
            '--lua-desync=multisplit:pos=2,midsld:seqovl=1:seqovl_pattern=zero:tcp_ts_up'
            '--lua-desync=fake:blob=tls_google:tcp_ts=-1000:repeats=4'
            '--lua-desync=multisplit:pos=1:seqovl=681:seqovl_pattern=tls_google:tcp_ts_up'
            '--lua-desync=fake:blob=tls_google:tcp_ts=-1000:repeats=2'
            '--lua-desync=multisplit:pos=2:seqovl=1:seqovl_pattern=zero:tcp_ts_up'
            '--lua-desync=fake:blob=quic_google:repeats=4'
        )
    }
    [pscustomobject]@{
        Name = 'CUSTOM BALANCED'
        RequireTlsMax = $false
        RequirePort8443 = $true
        MaxRepeats = 8
        RequiredLines = @(
            '--lua-desync=fake:blob=http_iana:tcp_ts=-1000:repeats=6'
            '--lua-desync=multisplit:pos=2,host+1,host+4:seqovl=8:seqovl_pattern=zero:tcp_ts_up'
            '--lua-desync=fake:blob=tls_google:tcp_ts=-1000:repeats=6'
            '--lua-desync=multisplit:pos=2,sniext+1,midsld:seqovl=8:seqovl_pattern=zero:tcp_ts_up'
            '--lua-desync=fake:blob=tls_google:tcp_ts=-1000:repeats=8'
            '--lua-desync=multisplit:pos=1:seqovl=681:seqovl_pattern=tls_google:tcp_ts_up'
            '--lua-desync=hostfakesplit:host=www.google.com:ip_id=zero:tcp_ts=-1000:tcp_ts_up'
            '--lua-desync=fake:blob=tls_google:tcp_ts=-1000:repeats=4'
            '--lua-desync=multisplit:pos=2:seqovl=8:seqovl_pattern=zero:tcp_ts_up'
            '--lua-desync=fake:blob=quic_google:repeats=8'
        )
    }
    [pscustomobject]@{
        Name = 'CUSTOM AGGRESSIVE'
        RequireTlsMax = $true
        RequirePort8443 = $true
        MaxRepeats = 11
        RequiredLines = @(
            '--lua-desync=fake:blob=tls_max:tcp_ts=-1000:repeats=11'
            '--lua-desync=multisplit:pos=1:seqovl=664:seqovl_pattern=tls_max:tcp_ts_up'
            '--lua-desync=fake:blob=tls_google:tcp_ts=-1000:repeats=10'
            '--lua-desync=multisplit:pos=1:seqovl=681:seqovl_pattern=tls_google:tcp_ts_up'
            '--lua-desync=hostfakesplit:host=www.google.com:ip_id=zero:tcp_ts=-1000:tcp_ts_up'
            '--lua-desync=fake:blob=quic_google:repeats=11'
        )
    }
)
$releaseBuilderForCustom = $releaseBuilder
$customRootBatches = @(Get-ChildItem -LiteralPath $root -Filter '*.bat' -File |
    Select-Object -ExpandProperty Name)
$customStaticCount = @($customDefinitions | Where-Object {
    Test-Path -LiteralPath (Join-Path $presetDir ($_.Name + '.txt.in')) -PathType Leaf
}).Count
foreach ($definition in $customDefinitions) {
    $customPath = Join-Path $presetDir ($definition.Name + '.txt.in')
    if (-not (Test-Path -LiteralPath $customPath -PathType Leaf)) {
        if ($customStaticCount -gt 0) {
            Add-ValidationError ('Missing experimental preset from an incomplete CUSTOM set: {0}' -f $definition.Name)
        }
        continue
    }
    $customTemplate = Get-Content -LiteralPath $customPath -Raw
    $customTemplateLines = @($customTemplate -split '\r?\n' | ForEach-Object { $_.Trim() })
    foreach ($section in @('TCP_HTTP', 'TCP_TLS', 'TCP_GENERIC', 'QUIC', 'DISCORD_MEDIA_TLS', 'GOOGLE_TLS', 'VOICE_COMPATIBLE')) {
        $sectionPattern = '(?m)^\[' + [regex]::Escape($section) + '\]\s*$'
        if ($customTemplate -notmatch $sectionPattern) {
            Add-ValidationError ('{0} is missing [{1}].' -f $definition.Name, $section)
        }
    }
    if ($customTemplate -match '(?i)--dpi-desync') {
        Add-ValidationError ('{0} contains a Zapret 1 option.' -f $definition.Name)
    }
    if ($customTemplate -match '(?m)^\[(?:WF_UDP|DISCORD_UDP|GAME_UDP)\]\s*$') {
        Add-ValidationError ('{0} couples an independent traffic mode to the web preset.' -f $definition.Name)
    }
    $templateActions = @($customTemplate -split '\r?\n' | Where-Object { $_ -match '^\s*--lua-desync=' })
    if ($templateActions.Count -gt 14) {
        Add-ValidationError ('{0} has more than the controlled action budget.' -f $definition.Name)
    }
    foreach ($requiredLine in $definition.RequiredLines) {
        if ($customTemplateLines -notcontains $requiredLine) {
            Add-ValidationError ('{0} drifted from the first-iteration parameter ledger: {1}' -f $definition.Name, $requiredLine)
        }
    }
    if ($definition.RequireTlsMax -and $customTemplate -notmatch 'tls_max') {
        Add-ValidationError ('{0} must explicitly use the tls_max blob.' -f $definition.Name)
    }
    if (-not $definition.RequireTlsMax -and $customTemplate -match 'tls_max') {
        Add-ValidationError ('{0} uses the aggressive tls_max blob.' -f $definition.Name)
    }
    if ($definition.RequirePort8443 -and $customTemplate -notmatch '(?m)^\[IPSET_TCP_PORTS\]\s*\r?\n8443\s*$') {
        Add-ValidationError ('{0} must scope the optional IPSet fallback to TCP 8443.' -f $definition.Name)
    }
    if (-not $definition.RequirePort8443 -and $customTemplate -match '(?m)^\[IPSET_TCP_PORTS\]') {
        Add-ValidationError ('{0} must not widen the IPSet TCP port set.' -f $definition.Name)
    }
    if ($customTemplate -notmatch '(?m)^\[VOICE_COMPATIBLE\]\s*\r?\n--filter-udp=19294-19344,50000-50100\r?\n--filter-l7=discord,stun') {
        Add-ValidationError ('{0} does not isolate the Discord voice/STUN range.' -f $definition.Name)
    }
    if ($customTemplate -notmatch '(?m)^\[DISCORD_MEDIA_TLS\]') {
        Add-ValidationError ('{0} does not define a Discord media profile.' -f $definition.Name)
    }
    if (@($customRootBatches | Where-Object { $_ -like ($definition.Name + '*') }).Count -gt 0) {
        Add-ValidationError ('{0} must not have a public launcher.' -f $definition.Name)
    }
    if ($releaseBuilderForCustom -notmatch [regex]::Escape($definition.Name + '.txt.in')) {
        Add-ValidationError ('Release builder must remove experimental preset: {0}' -f $definition.Name)
    }
    $safeCustom = $definition.Name -replace ' ', '_'
    $customOutput = Join-Path $runtimeDir ($safeCustom + '-candidate-validate.txt')
    try {
        & $renderer -Preset $definition.Name -Output $customOutput -GameMode off -IPSetMode loaded -VoiceMode compatible | Out-Null
        $customContent = Get-Content -LiteralPath $customOutput -Raw
        $customLines = @($customContent -split '\r?\n' | ForEach-Object { $_.Trim() })
        if ($customContent -match '\{\{|--dpi-desync|@\.\./|\.\./lists') {
            Add-ValidationError ('{0} generated an unresolved token, Zapret 1 option, or relative resource path.' -f $definition.Name)
        }
        if ($customContent -match '(?m)^--filter-(?:tcp|udp)=0-65535$' -or
            $customContent -match '(?m)^--filter-udp=1024-65535$') {
            Add-ValidationError ('{0} contains an unscoped all-UDP/all-port fallback.' -f $definition.Name)
        }
        if ($customContent -notmatch 'list-discord-web\.txt') {
            Add-ValidationError ('{0} is missing the CUSTOM-only Discord Web hostlist.' -f $definition.Name)
        }
        $customBlocks = @($customContent -split '(?m)^--new\r?$' | Where-Object { $_ -match '--lua-desync=' })
        foreach ($block in $customBlocks) {
            if ($block -notmatch '(?m)^--filter-(?:tcp|udp)=' -and $block -notmatch '(?m)^--filter-l7=') {
                Add-ValidationError ('{0} has a Lua action without a traffic filter.' -f $definition.Name)
            }
        }
        $repeats = @([regex]::Matches($customTemplate, 'repeats=(\d+)') |
            ForEach-Object { [int]$_.Groups[1].Value })
        if (@($repeats | Where-Object { $_ -gt $definition.MaxRepeats }).Count -gt 0) {
            Add-ValidationError ('{0} exceeds its declared repeat budget.' -f $definition.Name)
        }
        if ($definition.Name -eq 'CUSTOM SAFE' -and $customContent -match 'seqovl=664') {
            Add-ValidationError 'CUSTOM SAFE must not use the ALT12 tls_max overlap value.'
        }
        $expectedCustomVoice = @(
            '--filter-udp=19294-19344,50000-50100'
            '--filter-l7=discord,stun'
            '--payload=discord_ip_discovery'
            '--lua-desync=fake:blob=stun:repeats=3'
            '--lua-desync=fake:blob=discord_voice:repeats=3'
            '--payload=stun'
            '--lua-desync=fake:blob=discord_voice:repeats=3'
        )
        $customVoice = @(Get-ProfileLines -Content $customContent -Marker '# Discord Voice (must stay before the Game UDP fallback)')
        if (($customVoice -join [Environment]::NewLine) -cne ($expectedCustomVoice -join [Environment]::NewLine)) {
            Add-ValidationError ('{0} rendered a different Discord Voice sequence.' -f $definition.Name)
        }
        if ($customLines -notcontains '--wf-udp-out=443,19294-19344,50000-50100,12') {
            Add-ValidationError ('{0} rendered an unexpected UDP interception range.' -f $definition.Name)
        }
        foreach ($marker in @('# Discord media TLS', '# Google/YouTube TLS', '# Discord Web, Gateway, CDN and Updates', '# General HTTP', '# General TLS', '# IPSet fallback UDP', '# IPSet fallback TCP')) {
            if (@(Get-ProfileLines -Content $customContent -Marker $marker).Count -eq 0) {
                Add-ValidationError ('{0} is missing the rendered traffic scope {1}.' -f $definition.Name, $marker)
            }
        }
        Test-ReferencedFiles -ConfigPath $customOutput -PresetName $definition.Name
    } catch {
        Add-ValidationError ('{0} render failed: {1}' -f $definition.Name, $_.Exception.Message)
    }
}

$customHarnessPath = Join-Path $PSScriptRoot 'test-custom-presets.ps1'
if (-not (Test-Path -LiteralPath $customHarnessPath -PathType Leaf)) {
    if ($customStaticCount -gt 0) {
        Add-ValidationError 'The deterministic CUSTOM A/B harness is missing.'
    }
} else {
    $customHarnessText = Get-Content -LiteralPath $customHarnessPath -Raw
    foreach ($token in @(
        'DIRECT NO ZAPRET', 'CUSTOM SAFE', 'CUSTOM BALANCED', 'CUSTOM AGGRESSIVE',
        'GoogleMain', 'GoogleGstatic', '--http3-only', '--noproxy',
        'ProfileIds', 'ActualLuaActions', 'MandatoryEvidencePassed',
        '%{remote_ip}', '%{remote_port}', 'ProfileNotFoundCount',
        'manual-acceptance.csv', 'DiscordAppPastCheckingForUpdates',
        'GameLauncherStartOrUpdate', 'WindowsUpdateConnectivity',
        'YouTubeQuicObserved', 'ProbeAvailable', 'CurlSupportsHttp3',
        'DiscordUpdates', 'YouTubeVideoRedirect', 'ConfirmNetworkTest',
        'AllowEmptyIPSet', 'AllowContaminatedNetwork', 'Restore-OriginalState',
        'TieBreakPolicy', "'CUSTOM SAFE' = 0", "'ALT12' = 1"
    )) {
        if ($customHarnessText -notmatch [regex]::Escape($token)) {
            Add-ValidationError ('The CUSTOM A/B contract is missing: {0}' -f $token)
        }
    }
    if ($customHarnessText -notmatch '\$mandatoryPassed\s+-eq\s+\$mandatoryRows\.Count' -or
        $customHarnessText -notmatch '\$mandatoryEvidencePassed\s+-eq\s+\$mandatoryRows\.Count') {
        Add-ValidationError 'The CUSTOM A/B winner must require complete mandatory transport and profile/action evidence.'
    }
    try {
        & $customHarnessPath -SelfTest | Out-Host
    } catch {
        Add-ValidationError ('The CUSTOM A/B self-test failed: {0}' -f $_.Exception.Message)
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
                    $ipsetFile = if ($ipsetMode -eq 'loaded' -and $loadedIPSetHasEntries) { 'ipset-all.txt' } else { 'ipset-none.txt' }
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
Write-Host ('CUSTOM static candidates inspected: ' + $customStaticCount) -ForegroundColor DarkGray
exit 0
