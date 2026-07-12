param(
    [Parameter(Mandatory = $true)]
    [string]$Output,
    [string]$RemoteUrl
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$outputPath = [IO.Path]::GetFullPath($Output)
$bundledPath = Join-Path $root '.service\hosts'
$remoteTemp = $outputPath + '.remote'
$mappings = [Collections.Generic.List[string]]::new()
$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

function Add-HostsLines([string[]]$Lines) {
    foreach ($line in $Lines) {
        if ($line -match '^\s*([0-9a-fA-F:.]+)\s+([A-Za-z0-9._-]+)') {
            $mapping = "$($matches[1]) $($matches[2])"
            if ($seen.Add($mapping)) { $mappings.Add($mapping) }
        }
    }
}

function Test-PublicIPv4([string]$Value) {
    $address = $null
    if (-not [Net.IPAddress]::TryParse($Value, [ref]$address)) { return $false }
    if ($address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { return $false }
    $b = $address.GetAddressBytes()
    if ($b[0] -in @(0, 10, 127) -or $b[0] -ge 224) { return $false }
    if ($b[0] -eq 169 -and $b[1] -eq 254) { return $false }
    if ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) { return $false }
    if ($b[0] -eq 192 -and $b[1] -eq 168) { return $false }
    if ($b[0] -eq 100 -and $b[1] -ge 64 -and $b[1] -le 127) { return $false }
    if ($b[0] -eq 198 -and $b[1] -in @(18, 19)) { return $false }
    return $true
}

Remove-Item -LiteralPath $outputPath, $remoteTemp -Force -ErrorAction SilentlyContinue
if ($RemoteUrl) {
    try {
        Invoke-WebRequest -UseBasicParsing -TimeoutSec 15 -Uri $RemoteUrl -OutFile $remoteTemp
        Add-HostsLines -Lines @(Get-Content -LiteralPath $remoteTemp)
    } catch {
        Write-Host "[WARN] Remote hosts suggestions are unavailable: $($_.Exception.Message)" -ForegroundColor Yellow
    } finally {
        Remove-Item -LiteralPath $remoteTemp -Force -ErrorAction SilentlyContinue
    }
}

if (Test-Path -LiteralPath $bundledPath -PathType Leaf) {
    Add-HostsLines -Lines @(Get-Content -LiteralPath $bundledPath)
}

$domains = @(
    'raw.githubusercontent.com',
    'objects.githubusercontent.com',
    'discord.com',
    'gateway.discord.gg',
    'cdn.discordapp.com',
    'updates.discord.com',
    'www.youtube.com',
    'youtu.be',
    'i.ytimg.com',
    'redirector.googlevideo.com',
    'www.google.com',
    'www.gstatic.com',
    'web.telegram.org',
    'api.telegram.org'
)

$dohHeaders = @{ accept = 'application/dns-json' }
foreach ($domain in $domains) {
    try {
        $query = 'https://1.1.1.1/dns-query?name=' + [Uri]::EscapeDataString($domain) + '&type=A'
        $response = Invoke-RestMethod -UseBasicParsing -TimeoutSec 8 -Headers $dohHeaders -Uri $query
        $addresses = @($response.Answer |
            Where-Object { $_.type -eq 1 -and (Test-PublicIPv4 $_.data) } |
            ForEach-Object { $_.data } |
            Sort-Object -Unique)
        foreach ($address in $addresses) {
            $mapping = "$address $domain"
            if ($seen.Add($mapping)) { $mappings.Add($mapping) }
        }
    } catch {
        Write-Host "[WARN] DNS-over-HTTPS lookup failed for $domain" -ForegroundColor Yellow
    }
}

if ($mappings.Count -lt 5) {
    Write-Host '[ERROR] Too few valid hosts suggestions were produced.' -ForegroundColor Red
    exit 1
}

$header = @(
    '# Zapret 2 NEXT hosts suggestions'
    "# Generated: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'))"
    '# Review every entry before manually copying it to the Windows hosts file.'
    '# CDN addresses can change; this file is a point-in-time diagnostic aid.'
    ''
)
[IO.File]::WriteAllLines($outputPath, @($header + $mappings), [Text.Encoding]::ASCII)
Write-Host "[OK] Prepared $($mappings.Count) hosts suggestions: $outputPath" -ForegroundColor Green
exit 0
