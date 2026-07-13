[CmdletBinding()]
param(
    [ValidateRange(3, 30)]
    [int]$TimeoutSeconds = 8,

    [switch]$ValidateContract
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$renderer = Join-Path $PSScriptRoot 'render-config.ps1'
$starter = Join-Path $PSScriptRoot 'invoke-winws.ps1'
$winws = Join-Path $root 'bin\winws2.exe'
$targetsPath = Join-Path $PSScriptRoot 'compatibility-targets.json'
$publicPresets = @('general', 'ALT', 'ALT3', 'ALT5', 'ALT11', 'FAKE TLS AUTO ALT2')
$wizardVersion = '0.1.0-stage3'
$resultSchema = 'zapret2-next.compatibility-results'
$resultSchemaVersion = 1

$script:result = $null
$script:resultDir = $null
$script:zipPath = $null
$script:ownedEngine = $null
$script:pktMonOwned = $false
$script:pktMonState = $null
$script:conflictState = $null
$script:conflictsStopped = $false
$script:targets = @()
$script:curlPath = $null

function Write-Utf8File {
    param([string]$Path, [string]$Content)

    $encoding = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText($Path, $Content, $encoding)
}

function ConvertTo-SafeName([string]$Value) {
    $safe = [regex]::Replace($Value, '[^A-Za-z0-9_.-]+', '-')
    return $safe.Trim('-')
}

function Stop-Wizard([string]$Message) {
    throw [OperationCanceledException]::new($Message)
}

function Read-RequiredValue([string]$Prompt) {
    while ($true) {
        $value = Read-Host "$Prompt (q = cancel)"
        if ($value -match '^(?i:q|quit|cancel)$') { Stop-Wizard 'Canceled while entering tester metadata.' }
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
        Write-Host 'A value is required.' -ForegroundColor Yellow
    }
}

function Read-YesNo {
    param(
        [string]$Prompt,
        [ValidateSet('Yes', 'No')]
        [string]$Default = 'No'
    )

    $suffix = if ($Default -eq 'Yes') { '[Y/n/q]' } else { '[y/N/q]' }
    while ($true) {
        $value = (Read-Host "$Prompt $suffix").Trim().ToLowerInvariant()
        if (-not $value) { return $Default -eq 'Yes' }
        if ($value -in @('y', 'yes')) { return $true }
        if ($value -in @('n', 'no')) { return $false }
        if ($value -in @('q', 'quit', 'cancel')) { Stop-Wizard "Canceled at prompt: $Prompt" }
        Write-Host 'Enter y, n, or q.' -ForegroundColor Yellow
    }
}

function Read-ThreeWay([string]$Prompt) {
    while ($true) {
        $value = (Read-Host "$Prompt [y/n/s=skip/q]").Trim().ToLowerInvariant()
        switch ($value) {
            { $_ -in @('y', 'yes') } { return 'yes' }
            { $_ -in @('n', 'no') } { return 'no' }
            { $_ -in @('s', 'skip', '') } { return 'not-tested' }
            { $_ -in @('q', 'quit', 'cancel') } { Stop-Wizard "Canceled at prompt: $Prompt" }
            default { Write-Host 'Enter y, n, s, or q.' -ForegroundColor Yellow }
        }
    }
}

function Read-PingValue {
    while ($true) {
        $value = (Read-Host 'Discord voice ping in ms (number, unknown, or q)').Trim().ToLowerInvariant()
        if ($value -in @('q', 'quit', 'cancel')) { Stop-Wizard 'Canceled while recording voice ping.' }
        if ($value -in @('', 'unknown', 'n/a')) { return $null }
        if ($value -match '^\d{1,5}$') { return [int]$value }
        Write-Host 'Enter a number or unknown.' -ForegroundColor Yellow
    }
}

function Get-ConnectionType {
    Write-Host ''
    Write-Host 'Connection type:' -ForegroundColor Cyan
    Write-Host '  [1] Ethernet'
    Write-Host '  [2] Wi-Fi'
    Write-Host '  [3] Mobile / hotspot'
    Write-Host '  [4] Other'
    while ($true) {
        switch ((Read-Host 'Select 1-4 (q = cancel)').Trim().ToLowerInvariant()) {
            '1' { return 'Ethernet' }
            '2' { return 'Wi-Fi' }
            '3' { return 'Mobile / hotspot' }
            '4' { return Read-RequiredValue 'Describe the connection type' }
            { $_ -in @('q', 'quit', 'cancel') } { Stop-Wizard 'Canceled while entering connection type.' }
            default { Write-Host 'Select 1-4.' -ForegroundColor Yellow }
        }
    }
}

function Get-WizardTargets {
    if (-not (Test-Path -LiteralPath $targetsPath -PathType Leaf)) {
        throw "Compatibility target file is missing: $targetsPath"
    }
    $parsed = Get-Content -LiteralPath $targetsPath -Raw | ConvertFrom-Json
    $raw = @($parsed | ForEach-Object { $_ })
    $targets = @($raw | ForEach-Object {
        [pscustomobject]@{
            Name = [string]$_.name
            Product = [string]$_.product
            Mandatory = [bool]$_.mandatory
            Url = [string]$_.url
        }
    })
    return $targets
}

function Get-AdapterKind {
    param([string]$Name, [string]$Description)

    $text = "$Name $Description"
    if ($text -match '(?i)tailscale|zerotier|hamachi|radmin vpn') { return 'Overlay' }
    if ($text -match '(?i)hyper-v|vethernet|\bwsl\b|docker|virtualbox|vmware|loopback') { return 'Virtual' }
    if ($text -match '(?i)wireguard|openvpn|wintun|tap-windows|nordvpn|protonvpn|mullvad|amnezia|cloudflare warp|\bvpn\b') { return 'VpnCandidate' }
    return 'Physical'
}

function Get-PresetRanking {
    param([array]$Rows)

    $ranking = @()
    foreach ($group in @($Rows | Group-Object Preset)) {
        $items = @($group.Group)
        $passes = @($items | Select-Object -ExpandProperty Pass -Unique)
        $mandatoryRows = @($items | Where-Object Mandatory)
        $mandatoryPassed = @($mandatoryRows | Where-Object Success).Count
        $totalPassed = @($items | Where-Object Success).Count
        $completeMandatoryPasses = 0
        foreach ($pass in $passes) {
            $requiredInPass = @($mandatoryRows | Where-Object Pass -eq $pass)
            if ($requiredInPass.Count -gt 0 -and @($requiredInPass | Where-Object { -not $_.Success }).Count -eq 0) {
                $completeMandatoryPasses++
            }
        }
        $duration = if ($items.Count) {
            [Math]::Round([double](($items | Measure-Object DurationMs -Average).Average), 2)
        } else { [double]::PositiveInfinity }
        $ranking += [pscustomobject]@{
            Preset = $group.Name
            Passes = $passes.Count
            MandatoryRunRate = if ($passes.Count) { [Math]::Round($completeMandatoryPasses / $passes.Count, 6) } else { 0 }
            MandatorySuccessRate = if ($mandatoryRows.Count) { [Math]::Round($mandatoryPassed / $mandatoryRows.Count, 6) } else { 0 }
            OverallSuccessRate = if ($items.Count) { [Math]::Round($totalPassed / $items.Count, 6) } else { 0 }
            MandatoryPassed = $mandatoryPassed
            MandatoryTotal = $mandatoryRows.Count
            Passed = $totalPassed
            Total = $items.Count
            AverageDurationMs = $duration
        }
    }
    return @($ranking | Sort-Object `
        @{Expression = 'MandatoryRunRate'; Descending = $true},
        @{Expression = 'MandatorySuccessRate'; Descending = $true},
        @{Expression = 'OverallSuccessRate'; Descending = $true},
        @{Expression = 'AverageDurationMs'; Ascending = $true},
        @{Expression = 'Preset'; Ascending = $true})
}

function Get-UserStateHashes {
    $paths = @(
        'utils\game_filter.mode',
        'utils\ipset_filter.mode',
        'utils\voice_filter.mode',
        'lists\ipset-all.txt'
    )
    $state = [ordered]@{}
    foreach ($relative in $paths) {
        $path = Join-Path $root $relative
        $state[$relative] = if (Test-Path -LiteralPath $path -PathType Leaf) {
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        } else { '<missing>' }
    }
    return $state
}

function New-ResultDocument {
    param([hashtable]$Tester, [object]$SystemInfo, [hashtable]$StateBefore)

    return [ordered]@{
        schema = $resultSchema
        schemaVersion = $resultSchemaVersion
        wizardVersion = $wizardVersion
        status = 'started'
        startedAtUtc = [DateTime]::UtcNow.ToString('o')
        finishedAtUtc = $null
        privacyConsent = $true
        tester = $Tester
        system = $SystemInfo
        preflight = @()
        conflictState = $null
        engineRuns = @()
        webResults = @()
        ranking = @()
        manualResults = @()
        networkObservations = @()
        recommendation = $null
        restoration = @()
        userStateBefore = $StateBefore
        userStateAfter = $null
        userStatePreserved = $null
        errors = @()
    }
}

function New-TextReport {
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('Zapret 2 NEXT - Compatibility Wizard report')
    $lines.Add("Schema: $resultSchema v$resultSchemaVersion")
    $lines.Add("Wizard: $wizardVersion")
    $lines.Add("Status: $($script:result.status)")
    $lines.Add("Started UTC: $($script:result.startedAtUtc)")
    $lines.Add("Finished UTC: $($script:result.finishedAtUtc)")
    $lines.Add('')
    $lines.Add('Tester metadata')
    $lines.Add("Tester ID: $($script:result.tester.TesterId)")
    $lines.Add("Provider: $($script:result.tester.Provider)")
    $lines.Add("Region/city: $($script:result.tester.RegionCity)")
    $lines.Add("Connection: $($script:result.tester.ConnectionType)")
    $lines.Add("Windows: $($script:result.system.Caption) $($script:result.system.Version) build $($script:result.system.BuildNumber) $($script:result.system.OSArchitecture)")
    $lines.Add('')
    $lines.Add('Preflight')
    foreach ($item in @($script:result.preflight)) {
        $decision = if ($item.Decision) { " Decision=$($item.Decision)" } else { '' }
        $lines.Add("[$($item.Severity)] $($item.Code): $($item.Message)$decision")
    }
    $lines.Add('')
    $lines.Add('Web ranking')
    foreach ($item in @($script:result.ranking)) {
        $lines.Add(("{0}: required-run={1:P0}, required={2:P0}, overall={3:P0}, average={4}ms, passes={5}" -f
            $item.Preset, $item.MandatoryRunRate, $item.MandatorySuccessRate,
            $item.OverallSuccessRate, $item.AverageDurationMs, $item.Passes))
    }
    $lines.Add('')
    $lines.Add('Recommendation (NOT INSTALLED)')
    if ($null -ne $script:result.recommendation) {
        $recommendation = $script:result.recommendation
        $lines.Add("Web preset: $($recommendation.WebPreset)")
        $lines.Add("Discord Voice: $($recommendation.VoiceMode)")
        $lines.Add("Game Filter: $($recommendation.GameMode)")
        $lines.Add("IPSet Filter: $($recommendation.IPSetMode)")
        $lines.Add("Confirmed: $($recommendation.Confirmed)")
        foreach ($note in @($recommendation.Notes)) { $lines.Add("Note: $note") }
    } else {
        $lines.Add('No final combination was produced.')
    }
    $lines.Add('')
    $lines.Add("Saved mode/IPSet state preserved: $($script:result.userStatePreserved)")
    $lines.Add('The wizard only recommends settings. It does not install a service or write saved modes.')
    $lines.Add('')
    $lines.Add('Privacy')
    $lines.Add('The ZIP can contain provider/region metadata, exact IP addresses and ports, process IDs, timestamps, local paths, full winws2 debug logs, and filtered PktMon metadata.')
    $lines.Add('Packet payloads and raw ETL files are not included.')
    if (@($script:result.errors).Count) {
        $lines.Add('')
        $lines.Add('Errors / cancellation')
        foreach ($errorText in @($script:result.errors)) { $lines.Add([string]$errorText) }
    }
    return ($lines -join "`r`n") + "`r`n"
}

function Save-ResultArtifacts {
    if (-not $script:resultDir -or -not (Test-Path -LiteralPath $script:resultDir -PathType Container)) { return }

    Get-ChildItem -LiteralPath $script:resultDir -Recurse -Filter '*.etl' -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue

    $webCsv = Join-Path $script:resultDir 'web-results.csv'
    if (@($script:result.webResults).Count) {
        @($script:result.webResults) | Export-Csv -LiteralPath $webCsv -NoTypeInformation -Encoding UTF8
    } else {
        Write-Utf8File $webCsv '"TimestampUtc","Phase","Preset","Pass","IPSetMode","VoiceMode","Target","Product","Mandatory","Success","CurlExitCode","HttpCode","DurationMs","RemoteIP","RemotePort","ProcessId","Error"' + "`r`n"
    }

    if (@($script:result.preflight).Count) {
        @($script:result.preflight) | Export-Csv -LiteralPath (Join-Path $script:resultDir 'preflight.csv') -NoTypeInformation -Encoding UTF8
    }
    if (@($script:result.networkObservations).Count) {
        @($script:result.networkObservations) | Export-Csv -LiteralPath (Join-Path $script:resultDir 'network-observations.csv') -NoTypeInformation -Encoding UTF8
    }

    $json = $script:result | ConvertTo-Json -Depth 12
    Write-Utf8File (Join-Path $script:resultDir 'results.json') ($json + "`r`n")
    Write-Utf8File (Join-Path $script:resultDir 'REPORT.txt') (New-TextReport)

    if (Test-Path -LiteralPath $script:zipPath -PathType Leaf) {
        Remove-Item -LiteralPath $script:zipPath -Force
    }
    Compress-Archive -Path (Join-Path $script:resultDir '*') -DestinationPath $script:zipPath -CompressionLevel Optimal
}
