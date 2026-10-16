param([switch]$Quick)

. (Join-Path $PSScriptRoot 'session-log.ps1')
Initialize-ZapretLog -Root ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))) -Component diagnostics -Action Validate
try {

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$presetDir = Join-Path $root 'presets'
$runtimeDir = Join-Path $root 'runtime\validation'
$renderer = Join-Path $PSScriptRoot 'render-config.ps1'
$errors = [Collections.Generic.List[string]]::new()
$warnings = [Collections.Generic.List[string]]::new()

function Add-ValidationError([string]$Message) {
    $script:errors.Add($Message)
    Write-ZapretLogEvent -Stage validate -Result error -Code NativeFailed
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
$runnerHost = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'run-preset.ps1') -Raw
if ($runnerContent -notmatch 'run-preset\.ps1' -or $runnerHost -notmatch 'Invoke-ZapretEngine') {
    Add-ValidationError 'run-preset.bat must use the logging winws2 launcher.'
}

$serviceContent = Get-Content -LiteralPath (Join-Path $root 'service.bat') -Raw
$menuContent = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'menu.ps1') -Raw
$versionPath = Join-Path $root '.service\version.txt'
$projectVersion = if (Test-Path -LiteralPath $versionPath -PathType Leaf) {
    (Get-Content -LiteralPath $versionPath -Raw).Trim()
} else {
    ''
}
if ($projectVersion -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') {
    Add-ValidationError '.service\version.txt must contain one semantic version such as 0.2.1 or 0.3.0-beta.1.'
}
if ($menuContent -notmatch 'Get-ReleaseVersion \$root' -or
    $serviceContent -match '(?m)^set "VERSION=\d') {
    Add-ValidationError 'service.bat must read its installed version from .service\version.txt instead of hard-coding it.'
}
$updateContent = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'update-release-core.ps1') -Raw
if ($serviceContent -notmatch 'update-release\.ps1' -or $updateContent -notmatch '/releases/latest' -or
    $updateContent -notmatch 'Test-ReleaseNewer' -or $serviceContent -match 'RAW_BASE%/\.service/version\.txt') {
    Add-ValidationError 'Update checks must compare the installed package with the latest published GitHub Release, not the version file on main.'
}
$releaseBuilderPath = Join-Path $PSScriptRoot 'build-release.ps1'
$releaseBuilderAvailable = Test-Path -LiteralPath $releaseBuilderPath -PathType Leaf
$buildReleaseContent = if ($releaseBuilderAvailable) { Get-Content -LiteralPath $releaseBuilderPath -Raw } else { '' }
if ($releaseBuilderAvailable -and ($buildReleaseContent -notmatch 'Join-Path \$stage ''\.service\\version\.txt''' -or
    $buildReleaseContent -notmatch 'Stable release version')) {
    Add-ValidationError 'build-release.ps1 must stamp the requested version and reject mismatched stable releases.'
}
if ($menuContent -notmatch '13\. Run Diagnostics' -or
    $menuContent -notmatch '14\. Run Tests' -or
    $menuContent -notmatch '7\. Discord Voice' -or
    $menuContent -notmatch '8\. UDP Fake Profiles' -or
    $menuContent -notmatch '15\. Clear Discord Cache') {
    Add-ValidationError 'The service menu items are not aligned or a required settings/tool item is missing.'
}
if ($serviceContent -notmatch 'menu\.ps1' -or
    $menuContent -notmatch 'Read-ReleaseMenuChoice' -or
    $menuContent -notmatch 'Set-ZapretMenuMode' -or
    $menuContent -notmatch 'clear-discord-cache\.ps1' -or
    $menuContent -notmatch 'Strategy:.*Game:.*IPSet:.*Voice:' -or
    $menuContent -notmatch 'UDP fakes: Discord=.*Game=') {
    Add-ValidationError 'The service menu must expose the combined configuration, UDP fake selector and cache cleanup.'
}
if ($menuContent -notmatch '9\. Telegram' -or
    $menuContent -notmatch 'Show-ZapretTelegramMenu' -or
    $menuContent -notmatch 'telegram-control\.ps1') {
    Add-ValidationError 'The service menu must expose the bundled Telegram module.'
}
try {
    . (Join-Path $PSScriptRoot 'telegram-control.ps1')
    Assert-ZapretTelegramRuntime -Root $root
    $telegramLauncher = Join-Path $root 'telegram\launcher.py'
    if (Test-Path -LiteralPath $telegramLauncher -PathType Leaf) {
        $telegramBuild = Get-Content -LiteralPath (Join-Path $root 'bin\telegram\BUILD.json') -Raw | ConvertFrom-Json
        if ((Get-FileHash -LiteralPath $telegramLauncher -Algorithm SHA256).Hash -ine $telegramBuild.launcher_sha256) {
            throw 'Telegram launcher changed since the EXE was built. Run utils\build-telegram.ps1.'
        }
    }
} catch {
    Add-ValidationError "Telegram runtime integrity failed: $($_.Exception.Message)"
}
if ($menuContent -notmatch 'Get-Service -Name winws2' -or
    $menuContent -notmatch 'Set-ZapretServiceConfiguration') {
    Add-ValidationError 'The service manager must use locale-independent status reads and wait for stop/start transitions.'
}
foreach ($helper in @('ipset-utils.ps1', 'service-control.ps1', 'manage-service.ps1', 'validate-stability.ps1')) {
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $helper) -PathType Leaf)) {
        Add-ValidationError "Missing stability helper: $helper"
    }
}
if ($menuContent -notmatch 'Start-Process powershell.exe -ArgumentList \(''-NoExit ') {
    Add-ValidationError 'The test console must stay open so failures remain visible.'
}
$cacheCleanupPath = Join-Path $PSScriptRoot 'clear-discord-cache.ps1'
$cacheCleanupContent = if (Test-Path -LiteralPath $cacheCleanupPath -PathType Leaf) {
    Get-Content -LiteralPath $cacheCleanupPath -Raw
} else { '' }
foreach ($cacheToken in @('DiscordPTB', 'DiscordCanary', 'DiscordDevelopment', 'Code Cache', 'GPUCache', '[switch]$ListOnly', 'Continue? [y/N]', 'Remove-Item -LiteralPath')) {
    if ($cacheCleanupContent -notmatch [regex]::Escape($cacheToken)) {
        Add-ValidationError "Discord cache cleanup is missing its safety/channel contract: $cacheToken"
    }
}
$ipsetSyncPath = Join-Path $PSScriptRoot 'sync-upstream-ipset.ps1'
if ($releaseBuilderAvailable) {
    $ipsetSyncContent = if (Test-Path -LiteralPath $ipsetSyncPath -PathType Leaf) {
        Get-Content -LiteralPath $ipsetSyncPath -Raw
    } else { '' }
    foreach ($syncToken in @('[switch]$Apply', 'added.txt', 'removed.txt', 'SUMMARY.txt', 'suspiciously small snapshot', 'original files were restored')) {
        if ($ipsetSyncContent -notmatch [regex]::Escape($syncToken)) {
            Add-ValidationError "Upstream IPSet synchronization is missing its preview/apply safety contract: $syncToken"
        }
    }
}
if ($menuContent -notmatch 'discord_fake\.mode' -or
    $menuContent -notmatch 'game_fake\.mode' -or
    $menuContent -notmatch 'Get-ZapretMenuModes') {
    Add-ValidationError 'Service Manager must persist independent allowlisted Discord and Game fake selections.'
}
$rendererContent = Get-Content -LiteralPath $renderer -Raw
if ($rendererContent -notmatch "'steam' = 'quic_initial_steamcommunity_com\.bin'" -or
    $rendererContent -notmatch "'dbank-v2' = 'quic_initial_dbankcloud_ru_v2\.bin'" -or
    $rendererContent -notmatch 'blob=game_udp') {
    Add-ValidationError 'Renderer must map immutable allowlisted UDP fakes and keep Game UDP independent from Discord Voice.'
}
if ($releaseBuilderAvailable) {
    foreach ($releaseToken in @('sync-upstream-ipset.ps1', 'discord_fake.mode', 'game_fake.mode')) {
        if ($buildReleaseContent -notmatch [regex]::Escape($releaseToken)) {
            Add-ValidationError "Release builder is missing UDP fake/IPSet source-only policy: $releaseToken"
        }
    }
}
$fakePayloadHashes = [ordered]@{
    'quic_initial_steamcommunity_com.bin' = '2FE18B3BD20807D36704D0B072092EE49AE84EDCA907A4420AB9A0F0F28FDDCF'
    'quic_initial_dbankcloud_ru_v2.bin' = 'E065870CB0D13152E6132807BBF42218A9E7CD8D96F5602B61674CC540F3A56E'
    'tls_clienthello_sochi_park.bin' = 'AD552922ACFE029521DA884EA29F4BB28BB6BDCEE9B1A70B46ADBFD266C11D4D'
    'stun2.bin' = 'B7C2497496039C541F7337AC8536813F0A1CF52363AB2FAA5213B7816D458813'
    'quic_initial_4pda_to.bin' = 'E065870CB0D13152E6132807BBF42218A9E7CD8D96F5602B61674CC540F3A56E'
}
$sumContent = Get-Content -LiteralPath (Join-Path $root 'SHA256SUMS.txt') -Raw
foreach ($fakePayload in $fakePayloadHashes.GetEnumerator()) {
    $fakePayloadPath = Join-Path $root ('bin\fake\' + $fakePayload.Key)
    if (-not (Test-Path -LiteralPath $fakePayloadPath -PathType Leaf)) {
        Add-ValidationError "Missing opt-in UDP fake payload: $($fakePayload.Key)"
        continue
    }
    $actualFakeHash = (Get-FileHash -LiteralPath $fakePayloadPath -Algorithm SHA256).Hash
    if ($actualFakeHash -ne $fakePayload.Value) {
        Add-ValidationError "Unexpected SHA256 for opt-in UDP fake payload: $($fakePayload.Key)"
    }
    if ($sumContent -notmatch ('(?im)^' + $fakePayload.Value + '\s+bin/fake/' + [regex]::Escape($fakePayload.Key) + '\r?$')) {
        Add-ValidationError "SHA256SUMS.txt is missing opt-in UDP fake payload: $($fakePayload.Key)"
    }
}
if ($menuContent -notmatch 'Classic presets' -or $menuContent -notmatch 'NEXT presets' -or
    $menuContent -match 'Confirmed experimental presets|NEXT AGGRESSIVE') {
    Add-ValidationError 'Service selection must expose Classic and NEXT columns and keep AGGRESSIVE private.'
}
$ipsetMenuBlock = [regex]::Match($menuContent, '(?ms)^function Set-ZapretMenuMode.*?(?=^function )').Value
if ($ipsetMenuBlock -notmatch 'ipset_filter\.mode') {
    Add-ValidationError 'The IPSet menu must persist its selection in ipset_filter.mode.'
}
$ipsetCycle = [regex]::Match($ipsetMenuBlock, '(?m)^\s*5 \{[^\r\n]+').Value
if ($ipsetMenuBlock -match '\$value=''any''' -or $ipsetCycle -notmatch '''loaded''' -or
    $ipsetCycle -notmatch '''none''' -or $ipsetCycle -match '''any''') {
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
$customPresetFilesPresent = @('NEXT SAFE.txt.in', 'NEXT BALANCED.txt.in', 'NEXT AGGRESSIVE.txt.in' |
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

. (Join-Path $PSScriptRoot 'preset-catalog.ps1')
$publicPresetNames = @(Get-ZapretMenuPresets)
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

$expectedPublicLaunchers = @(Get-ZapretRequiredLaunchers)
$customLauncherNames = @(Get-ZapretCustomPresets | ForEach-Object { Get-ZapretPresetLauncher $_ } | Where-Object { Test-Path -LiteralPath (Join-Path $root ('strategies\' + $_)) -PathType Leaf })
$strategyDir = Join-Path $root 'strategies'
$rootOnlyBatches = @(Get-ChildItem -LiteralPath $root -Filter '*.bat' -File | ForEach-Object Name)
if ($rootOnlyBatches.Count -ne 1 -or $rootOnlyBatches[0] -ne 'service.bat') { Add-ValidationError 'Only service.bat may be a root launcher.' }
$rootBatches = @(Get-ChildItem -LiteralPath $strategyDir -Filter '*.bat' -File | Select-Object -ExpandProperty Name)
foreach ($launcher in $expectedPublicLaunchers) {
    if ($rootBatches -notcontains $launcher) { Add-ValidationError "Missing public launcher: $launcher" }
}
foreach ($experimentalLauncher in @('general (NEXT AGGRESSIVE).bat', 'general (VOICE).bat', 'general (FAKE TLS AUTO).bat', 'general (SIMPLE FAKE).bat')) {
    if ($rootBatches -contains $experimentalLauncher) { Add-ValidationError "Experimental launcher must not be public: $experimentalLauncher" }
}
foreach ($launcher in $customLauncherNames) {
    $preset = $launcher -replace '^general \((.+)\)\.bat$', '$1'
    $launcherContent = Get-Content -LiteralPath (Join-Path $strategyDir $launcher) -Raw
    if ($launcherContent -notmatch [regex]::Escape('run-preset.bat" "' + $preset + '"')) {
        Add-ValidationError "Custom launcher does not invoke its own preset: $launcher"
    }
}
if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'diagnose discord voice.bat'))) {
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
    foreach ($requiredReleaseFile in @('strategies', 'utils')) {
        if ($releaseBuilder -notmatch [regex]::Escape("'$requiredReleaseFile'")) {
            Add-ValidationError "Release allowlist is missing: $requiredReleaseFile"
        }
    }
    foreach ($excludedReleaseFile in @('general (NEXT AGGRESSIVE).bat', 'general (VOICE).bat', 'general (FAKE TLS AUTO).bat', 'general (SIMPLE FAKE).bat')) {
        if ($releaseBuilder -match [regex]::Escape("'$excludedReleaseFile'")) {
            Add-ValidationError "Release allowlist includes an experimental launcher: $excludedReleaseFile"
        }
    }
    foreach ($excludedPreset in @(
        'VOICE.txt.in', 'FAKE TLS AUTO.txt.in', 'SIMPLE FAKE.txt.in',
        'NEXT AGGRESSIVE.txt.in'
    )) {
        if ($releaseBuilder -notmatch [regex]::Escape("'$excludedPreset'")) {
            Add-ValidationError "Release builder must remove unsupported experimental preset: $excludedPreset"
        }
    }
    foreach ($publishedExperimentalPreset in @('ALT12.txt.in', 'NEXT SAFE.txt.in', 'NEXT BALANCED.txt.in')) {
        if ($releaseBuilder -match [regex]::Escape("'$publishedExperimentalPreset'")) {
            Add-ValidationError "Release builder must retain public preset: $publishedExperimentalPreset"
        }
    }
}

if ($releaseBuilderAvailable -and $releaseBuilder -match 'list-discord-web\.txt') {
    Add-ValidationError 'Release builder must retain the NEXT Discord Web hostlist.'
}
if ($releaseBuilderAvailable -and ($releaseBuilder -notmatch 'ipset-all\.txt\.backup' -or $releaseBuilder -notmatch 'The package must not inherit mutable owner settings')) {
    Add-ValidationError 'Release builder must remove the IPSet backup and reset mutable mode files.'
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
    (Join-Path $root 'utils\discord_fake.mode'),
    (Join-Path $root 'utils\game_fake.mode'),
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

# Classic strategies retain their hostlists; NEXT has an explicit Discord Web scope.
foreach ($publicPreset in $classicPresets) {
    $publicOutput = Join-Path $runtimeDir (('public-{0}-behavior.txt' -f ($publicPreset -replace ' ', '_')))
    try {
        & $renderer -Preset $publicPreset -Output $publicOutput -GameMode off -IPSetMode loaded -VoiceMode compatible | Out-Null
        $publicContent = Get-Content -LiteralPath $publicOutput -Raw
        if ($publicContent -match 'list-discord-web\.txt') {
            Add-ValidationError "$publicPreset unexpectedly references the NEXT-only Discord Web hostlist."
        }
    } catch {
        Add-ValidationError "$publicPreset public-behavior render failed: $($_.Exception.Message)"
    }
}

$customDefinitions = @(
    [pscustomobject]@{
        Name = 'NEXT SAFE'
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
        Name = 'NEXT BALANCED'
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
        Name = 'NEXT AGGRESSIVE'
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
$customRootBatches = @(Get-ChildItem -LiteralPath $strategyDir -Filter '*.bat' -File |
    Select-Object -ExpandProperty Name)
$customStaticCount = @($customDefinitions | Where-Object {
    Test-Path -LiteralPath (Join-Path $presetDir ($_.Name + '.txt.in')) -PathType Leaf
}).Count
$expectedCustomNames = if ($releaseBuilderAvailable) {
    @($customDefinitions | ForEach-Object Name)
} else {
    @('NEXT SAFE', 'NEXT BALANCED')
}
foreach ($definition in $customDefinitions) {
    $customPath = Join-Path $presetDir ($definition.Name + '.txt.in')
    if (-not (Test-Path -LiteralPath $customPath -PathType Leaf)) {
        if ($expectedCustomNames -contains $definition.Name) {
            Add-ValidationError ('Missing expected NEXT preset: {0}' -f $definition.Name)
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
    if ($definition.Name -eq 'NEXT AGGRESSIVE' -and $customRootBatches -contains 'general (NEXT AGGRESSIVE).bat') {
        Add-ValidationError ('{0} must not have a public launcher.' -f $definition.Name)
    }
    $customTemplateToken = [regex]::Escape($definition.Name + '.txt.in')
    if ($definition.Name -in @('NEXT SAFE', 'NEXT BALANCED')) {
        if ($releaseBuilderForCustom -match $customTemplateToken) {
            Add-ValidationError ('Release builder must retain confirmed public preset: {0}' -f $definition.Name)
        }
    } elseif ($releaseBuilderForCustom -notmatch $customTemplateToken) {
        Add-ValidationError ('Release builder must remove unsupported experimental preset: {0}' -f $definition.Name)
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
            Add-ValidationError ('{0} is missing the NEXT-only Discord Web hostlist.' -f $definition.Name)
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
        if ($definition.Name -eq 'NEXT SAFE' -and $customContent -match 'seqovl=664') {
            Add-ValidationError 'NEXT SAFE must not use the ALT12 tls_max overlap value.'
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
    if ($customStaticCount -gt 0 -and $releaseBuilderAvailable) {
        Add-ValidationError 'The deterministic NEXT A/B harness is missing from the source tree.'
    }
} else {
    $customHarnessText = Get-Content -LiteralPath $customHarnessPath -Raw
    foreach ($token in @(
        'DIRECT NO ZAPRET', 'NEXT SAFE', 'NEXT BALANCED', 'NEXT AGGRESSIVE',
        'GoogleMain', 'GoogleGstatic', '--http3-only', '--noproxy',
        'ProfileIds', 'ActualLuaActions', 'MandatoryEvidencePassed',
        '%{remote_ip}', '%{remote_port}', 'ProfileNotFoundCount',
        'manual-acceptance.csv', 'DiscordAppPastCheckingForUpdates',
        'GameLauncherStartOrUpdate', 'WindowsUpdateConnectivity',
        'YouTubeQuicObserved', 'ProbeAvailable', 'CurlSupportsHttp3',
        'DiscordUpdates', 'YouTubeVideoRedirect', 'ConfirmNetworkTest',
        'AllowEmptyIPSet', 'AllowContaminatedNetwork', 'Restore-OriginalState',
        'TieBreakPolicy', "'NEXT SAFE' = 0", "'ALT12' = 1"
    )) {
        if ($customHarnessText -notmatch [regex]::Escape($token)) {
            Add-ValidationError ('The NEXT A/B contract is missing: {0}' -f $token)
        }
    }
    if ($customHarnessText -notmatch '\$mandatoryPassed\s+-eq\s+\$mandatoryRows\.Count' -or
        $customHarnessText -notmatch '\$mandatoryEvidencePassed\s+-eq\s+\$mandatoryRows\.Count') {
        Add-ValidationError 'The NEXT A/B winner must require complete mandatory transport and profile/action evidence.'
    }
    try {
        $customSelfTestOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $customHarnessPath -SelfTest 2>&1
        $customSelfTestOutput | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw "NEXT A/B self-test exited with code $LASTEXITCODE."
        }
    } catch {
        Add-ValidationError ('The NEXT A/B self-test failed: {0}' -f $_.Exception.Message)
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
                    & $renderer -Preset $name -Output $output -GameMode $gameMode -IPSetMode $ipsetMode -VoiceMode $voiceMode -DiscordFake current -GameFake current | Out-Null
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
                    "# Discord Voice: $voiceMode",
                    '# Discord UDP fake: current',
                    '# Game UDP fake: current'
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
                if (($name -ne 'EXP' -and $gameUdpProfile -notcontains '--lua-desync=fake:blob=game_udp:repeats=10:payload=all') -or
                    ($name -eq 'EXP' -and ($gameUdpProfile -notcontains '--lua-desync=fake:blob=game_udp:repeats=5:payload=all' -or
                    $gameUdpProfile -notcontains '--lua-desync=fake:blob=quic_4pda:repeats=5:payload=all'))) {
                    Add-ValidationError "$label does not keep the Game UDP fake independent from Discord Voice."
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
                $presetTemplate = Get-Content -LiteralPath $preset.FullName -Raw
                $hasPresetVoice = $presetTemplate -match '(?m)^\[VOICE_COMPATIBLE\]'
                if ($voiceMode -eq 'compatible' -and $hasPresetVoice) {
                    $voiceSection = [regex]::Match($presetTemplate, '(?ms)^\[VOICE_COMPATIBLE\]\r?\n(.*?)(?=^\[|\z)').Groups[1].Value
                    $expectedVoiceProfile = @($voiceSection -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
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

                $expectedWfUdp = if (($voiceMode -eq 'compatible' -and -not $hasPresetVoice) -or $gameMode -in @('udp', 'all')) {
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

$discordFakeCatalog = [ordered]@{
    'current' = 'quic_initial_dbankcloud_ru.bin'
    'steam' = 'quic_initial_steamcommunity_com.bin'
    'google' = 'quic_initial_www_google_com.bin'
}
$gameFakeCatalog = [ordered]@{
    'current' = 'quic_initial_dbankcloud_ru.bin'
    'dbank-v2' = 'quic_initial_dbankcloud_ru_v2.bin'
    'steam' = 'quic_initial_steamcommunity_com.bin'
}
$fakeRenderCount = 0
foreach ($discordFakeEntry in $discordFakeCatalog.GetEnumerator()) {
    foreach ($gameFakeEntry in $gameFakeCatalog.GetEnumerator()) {
        $fakeLabel = "discord=$($discordFakeEntry.Key)/game=$($gameFakeEntry.Key)"
        $fakeOutput = Join-Path $runtimeDir ("fake-d-{0}-g-{1}.txt" -f $discordFakeEntry.Key, $gameFakeEntry.Key)
        try {
            & $renderer -Preset 'general' -Output $fakeOutput -GameMode udp -IPSetMode loaded -VoiceMode compatible -DiscordFake $discordFakeEntry.Key -GameFake $gameFakeEntry.Key | Out-Null
            $fakeRenderCount++
            $fakeLines = @(Get-Content -LiteralPath $fakeOutput | ForEach-Object { $_.Trim() })
            $expectedDiscordBlob = '--blob=discord_voice:@"' + $expectedBinDir + '/fake/' + $discordFakeEntry.Value + '"'
            $expectedGameBlob = '--blob=game_udp:@"' + $expectedBinDir + '/fake/' + $gameFakeEntry.Value + '"'
            foreach ($expectedLine in @(
                "# Discord UDP fake: $($discordFakeEntry.Key)",
                "# Game UDP fake: $($gameFakeEntry.Key)",
                $expectedDiscordBlob,
                $expectedGameBlob
            )) {
                if ($fakeLines -notcontains $expectedLine) {
                    Add-ValidationError "$fakeLabel is missing rendered line: $expectedLine"
                }
            }
            Test-ReferencedFiles -ConfigPath $fakeOutput -PresetName $fakeLabel
        } catch {
            Add-ValidationError "$fakeLabel render failed: $($_.Exception.Message)"
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
    $savedDiscordFake = Get-SavedMode (Join-Path $root 'utils\discord_fake.mode') 'current' @('current', 'steam', 'google')
    $savedGameFake = Get-SavedMode (Join-Path $root 'utils\game_fake.mode') 'current' @('current', 'dbank-v2', 'steam')
    foreach ($header in @(
        "# Game filter: $savedGameMode",
        "# IPSet filter: $savedIPSetMode",
        "# Discord Voice: $savedVoiceMode",
        "# Discord UDP fake: $savedDiscordFake",
        "# Game UDP fake: $savedGameFake"
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

$sourceFiles = @(Get-ChildItem -LiteralPath $root -File -Force) + @(
    Get-ChildItem -LiteralPath $root -Directory -Force |
        Where-Object { $_.Name -notin @('runtime', 'Results', 'dist', '.git') } |
        ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Recurse -File }
)
$brandingPattern = 'Flowseal|zapret-discord-youtube|vpndiscordyooutube|bypassblock|zapretvpns'
$telegramCreditPaths = @((Join-Path $root 'README.md'), (Join-Path $root 'docs\TELEGRAM.md'), (Join-Path $root 'docs\ADVANCED.md'))
$forbidden = $sourceFiles |
    Where-Object {
        $_.FullName -notmatch '[\\/](runtime|Results|dist)[\\/]' -and
        $_.FullName -notmatch '[\\/]bin[\\/]telegram[\\/]licenses[\\/]' -and
        $_.FullName -notmatch '[\\/](THIRD_PARTY_NOTICES\.md|LICENSE\.txt|validate\.ps1|sync-upstream-ipset\.ps1)$' -and
        $_.Extension -in @('.md', '.bat', '.ps1', '.txt', '.in', '.yml', '.yaml')
    } |
    Select-String -Pattern $brandingPattern -CaseSensitive:$false
foreach ($hit in $forbidden) {
    $brandingLine = $hit.Line
    if ($hit.Path -in $telegramCreditPaths) {
        # Credit the bundled upstreams without allowing unrelated branding.
        if ($hit.Path -in @((Join-Path $root 'README.md'), (Join-Path $root 'docs\ADVANCED.md'))) {
            $brandingLine = $brandingLine -replace '^(\*\*Classic\*\*.*)Flowseal(\. \*\*NEXT\*\*.*)$', '$1$2'
        }
        $brandingLine = $brandingLine -replace '(?i)https://github\.com/Flowseal/tg-ws-proxy\b', ''
        $brandingLine = $brandingLine -replace '(?i)\bFlowseal(?:/tg-ws-proxy|''s tg-ws-proxy)\b', ''
    }
    if ($brandingLine -match $brandingPattern) {
        Add-ValidationError "Forbidden branding in $($hit.Path):$($hit.LineNumber)"
    }
}

if ($errors.Count -gt 0) {
    Write-Host "Validation failed with $($errors.Count) error(s)." -ForegroundColor Red
    Complete-ZapretLogOperation -ExitCode 1; exit 1
}
Write-Host "Validation passed: $($presets.Count) presets, $renderCount configurations (Game: $($gameModes -join ', '); IPSet: $($ipsetModes -join ', '); Voice: $($voiceModes -join ', '))." -ForegroundColor Green
Write-Host "UDP fake selector combinations inspected: $fakeRenderCount." -ForegroundColor Green
Write-Host ('NEXT static candidates inspected: ' + $customStaticCount) -ForegroundColor DarkGray
Complete-ZapretLogOperation -ExitCode 0; exit 0

} catch { Write-ZapretLogException $_; throw }
finally { Complete-ZapretLogOperation }
