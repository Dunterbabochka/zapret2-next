param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9 _-]+$')]
    [string]$Preset,

    [Parameter(Mandatory = $true)]
    [string]$Output,

    [ValidateSet('off', 'tcp', 'udp', 'all')]
    [string]$GameMode,

    [ValidateSet('loaded', 'none', 'any')]
    [string]$IPSetMode,

    [ValidateSet('compatible', 'standard', 'off')]
    [string]$VoiceMode,

    [string]$DebugLog,

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

$parameterOverrides = @{}
foreach ($entry in $PSBoundParameters.GetEnumerator()) {
    $parameterOverrides[$entry.Key] = $entry.Value
}

function Get-ModeSetting {
    param(
        [string]$ParameterName,
        [string]$RelativePath,
        [string]$Default,
        [string[]]$Allowed
    )

    if ($parameterOverrides.ContainsKey($ParameterName)) {
        return ([string]$parameterOverrides[$ParameterName]).ToLowerInvariant()
    }

    $path = Join-Path $root $RelativePath
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $lines = @(Get-Content -LiteralPath $path -TotalCount 1)
        if ($lines.Count -gt 0) {
            $value = ([string]$lines[0]).Trim().ToLowerInvariant()
            if ($value -in $Allowed) { return $value }
        }
    }
    return $Default
}

$gameMode = Get-ModeSetting 'GameMode' 'utils\game_filter.mode' 'off' @('off', 'tcp', 'udp', 'all')
$ipsetMode = Get-ModeSetting 'IPSetMode' 'utils\ipset_filter.mode' 'loaded' @('loaded', 'none', 'any')
$voiceMode = Get-ModeSetting 'VoiceMode' 'utils\voice_filter.mode' 'compatible' @('compatible', 'standard', 'off')
$hasPresetCompatibleVoice = $sections.ContainsKey('VOICE_COMPATIBLE') -and $sections['VOICE_COMPATIBLE'].Count -gt 0
$ipsetTcpPorts = @()
if ($sections.ContainsKey('IPSET_TCP_PORTS')) {
    $ipsetTcpPorts = @($sections['IPSET_TCP_PORTS'] |
        ForEach-Object { ([string]$_).Trim() } |
        Where-Object { $_ })
    if (@($ipsetTcpPorts | Where-Object { $_ -notmatch '^\d+(?:-\d+)?$' }).Count -gt 0) {
        throw "Invalid [IPSET_TCP_PORTS] value in $presetPath"
    }
}
$ipsetTcpFilter = if ($ipsetTcpPorts.Count -gt 0) {
    '80,443,' + ($ipsetTcpPorts -join ',')
} else {
    '80,443'
}

$gameTcp = if ($gameMode -in @('tcp', 'all')) { '1024-65535' } else { '12' }
$gameUdp = if ($gameMode -in @('udp', 'all')) { '1024-65535' } else { '12' }
$wfUdp = if ($gameMode -in @('udp', 'all') -or ($voiceMode -eq 'compatible' -and -not $hasPresetCompatibleVoice)) {
    '1024-65535'
} else {
    "443,19294-19344,50000-50100,$gameUdp"
}
if ($wfUdp -notmatch '^\d+(?:-\d+)?(?:,\d+(?:-\d+)?)*$') {
    throw "Invalid [WF_UDP] value: $wfUdp"
}

$content = (Get-Content -LiteralPath $basePath -Raw) + "`r`n" + (Get-Content -LiteralPath $profilesPath -Raw)
foreach ($name in $required) {
    $value = ($sections[$name] -join "`r`n").Trim()
    $content = $content.Replace("{{$name}}", $value)
}
$googleTls = if ($sections.ContainsKey('GOOGLE_TLS') -and $sections['GOOGLE_TLS'].Count -gt 0) {
    ($sections['GOOGLE_TLS'] -join [Environment]::NewLine).Trim()
} else {
    ($sections['TCP_TLS'] -join [Environment]::NewLine).Trim()
}
$discordWebTls = if ($sections.ContainsKey('DISCORD_WEB_TLS') -and $sections['DISCORD_WEB_TLS'].Count -gt 0) {
    ($sections['DISCORD_WEB_TLS'] -join [Environment]::NewLine).Trim()
} else {
    ($sections['TCP_TLS'] -join [Environment]::NewLine).Trim()
}
$discordWebProfile = if ($Preset -match '^CUSTOM (SAFE|BALANCED|AGGRESSIVE)$') {
    @(
        '--filter-tcp=443'
        '--hostlist=../lists/list-discord-web.txt'
        '--payload=tls_client_hello'
        '--out-range=-d10'
        $discordWebTls
        '--new'
    ) -join "`r`n"
} else {
    ''
}
$discordMediaTls = if ($sections.ContainsKey('DISCORD_MEDIA_TLS') -and $sections['DISCORD_MEDIA_TLS'].Count -gt 0) {
    ($sections['DISCORD_MEDIA_TLS'] -join [Environment]::NewLine).Trim()
} else {
    ($sections['TCP_TLS'] -join [Environment]::NewLine).Trim()
}
$content = $content.Replace('{{DISCORD_MEDIA_TLS}}', $discordMediaTls)
$content = $content.Replace('{{GOOGLE_TLS}}', $googleTls)
$content = $content.Replace('{{DISCORD_WEB_TLS}}', $discordWebTls)
$content = $content.Replace('{{DISCORD_WEB_PROFILE}}', $discordWebProfile)
$content = $content.Replace('{{IPSET_TCP_FILTER}}', $ipsetTcpFilter)
$voiceUdpProfile = switch ($voiceMode) {
    'compatible' {
        if ($hasPresetCompatibleVoice) {
            ($sections['VOICE_COMPATIBLE'] -join [Environment]::NewLine).Trim()
        } else {
        @(
            '--filter-udp=1024-65535'
            '--filter-l7=stun,discord'
            '--payload=stun,discord_ip_discovery'
            '--lua-desync=fake:blob=discord_voice:repeats=3'
            '--payload=all'
            '--out-range=n2-n4'
            '--lua-desync=fake:blob=discord_voice:repeats=10'
        ) -join "`r`n"
        }
    }
    'standard' {
        @(
            '--filter-udp=1024-65535'
            '--filter-l7=stun,discord'
            '--payload=stun,discord_ip_discovery'
            '--lua-desync=fake:blob=0x00000000000000000000000000000000:repeats=2'
        ) -join "`r`n"
    }
    'off' {
        @(
            '--filter-udp=1024-65535'
            '--filter-l7=stun,discord'
        ) -join "`r`n"
    }
}
$content = $content.Replace('{{VOICE_UDP_PROFILE}}', $voiceUdpProfile)

$loadedIPSetPath = Join-Path $root 'lists\ipset-all.txt'
$loadedIPSetHasEntries = (Test-Path -LiteralPath $loadedIPSetPath -PathType Leaf) -and
    @((Get-Content -LiteralPath $loadedIPSetPath) | Where-Object { $_ -notmatch '^\s*(?:#|$)' }).Count -gt 0
$loadedIPSetSource = if ($loadedIPSetHasEntries) { '../lists/ipset-all.txt' } else { '../lists/ipset-none.txt' }
$ipsetInclude = switch ($ipsetMode) {
    'loaded' { "--ipset=$loadedIPSetSource" }
    'none' { '--ipset=../lists/ipset-none.txt' }
    'any' { '' }
}
$content = $content.Replace('{{IPSET_INCLUDE}}', $ipsetInclude)

$gameUdpProfile = @(
        "--filter-udp=$gameUdp"
        '{{IPSET_INCLUDE}}'
        '--ipset-exclude=../lists/ipset-exclude.txt'
        '--ipset-exclude=../lists/ipset-exclude-user.txt'
        '--payload=all'
        '--out-range=-n4'
        '--lua-desync=fake:blob=discord_voice:repeats=10:payload=all'
    ) -join "`r`n"
$gameUdpProfile = $gameUdpProfile.Replace('{{IPSET_INCLUDE}}', $ipsetInclude)
$content = $content.Replace('{{GAME_UDP_PROFILE}}', $gameUdpProfile)
$content = $content.Replace('{{PRESET}}', $Preset)
$content = $content.Replace('{{GAME_MODE}}', $gameMode)
$content = $content.Replace('{{IPSET_MODE}}', $ipsetMode)
$content = $content.Replace('{{VOICE_MODE}}', $voiceMode)
$content = $content.Replace('{{GAME_TCP}}', $gameTcp)
$content = $content.Replace('{{GAME_UDP}}', $gameUdp)
$content = $content.Replace('{{WF_UDP}}', $wfUdp)
$debugValue = '0'
if ($parameterOverrides.ContainsKey('DebugLog')) {
    if ([string]::IsNullOrWhiteSpace($DebugLog)) {
        throw 'DebugLog must be a non-empty file path.'
    }
    $debugPath = [IO.Path]::GetFullPath($DebugLog).Replace('\', '/')
    $debugValue = '@"' + $debugPath + '"'
}
$content = $content.Replace('{{DEBUG}}', $debugValue)
$rootDir = $root.Replace('\', '/')
$binDir = [IO.Path]::GetFullPath((Join-Path $root 'bin')).Replace('\', '/')

# winws2 v1.0.2 does not reliably apply --chdir before every file-valued
# Windows option. Emit quoted absolute paths while keeping templates readable.
$content = [regex]::Replace($content, '(?m)=@\.\./(lua|windivert\.filter)/([^\r\n]+)(?=\r?$)', '=@"{{ROOT_DIR}}/$1/$2"')
$content = [regex]::Replace($content, '(?m):@fake/([^\r\n]+)(?=\r?$)', ':@"{{BIN_DIR}}/fake/$1"')
$content = [regex]::Replace($content, '(?m)=\.\./lists/([^\r\n]+)(?=\r?$)', '="{{ROOT_DIR}}/lists/$1"')
$content = $content.Replace('{{ROOT_DIR}}', $rootDir)
$content = $content.Replace('{{BIN_DIR}}', $binDir)

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
    $content += "`r`n--wf-dup-check=0`r`n"
    $content += "`r`n--dry-run`r`n"
}

$outputPath = [IO.Path]::GetFullPath($Output)
$outputDir = Split-Path -Parent $outputPath
if (-not (Test-Path -LiteralPath $outputDir)) {
    New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
}
[IO.File]::WriteAllText($outputPath, $content.Trim() + "`r`n", [Text.Encoding]::ASCII)
Write-Output $outputPath
