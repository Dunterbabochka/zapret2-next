# Standalone Issue #5 diagnostics. No dependency on the menu or native helper DLL.
function Write-GW2Json([string]$Path, $Value) {
    $temporary=$Path+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary,$Path,[NullString]::Value) }
        else { [IO.File]::Move($temporary,$Path) }
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}
function ConvertTo-GW2Address([string]$Value) {
    $address = $null
    if (-not [Net.IPAddress]::TryParse($Value, [ref]$address)) { throw 'Invalid IP address.' }
    if ($address.IsIPv4MappedToIPv6) { $address = $address.MapToIPv4() }
    return $address
}
function Get-GW2NetworkKey([Net.IPAddress]$Address, [int]$Prefix) {
    $bytes = $Address.GetAddressBytes()
    if ($Prefix -lt 0 -or $Prefix -gt $bytes.Length * 8) { throw 'Invalid CIDR prefix.' }
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        $bits = [Math]::Min(8, [Math]::Max(0, $Prefix - $i * 8))
        $bytes[$i] = $bytes[$i] -band ((255 -shl (8 - $bits)) -band 255)
    }
    return [BitConverter]::ToString($bytes)
}
function Read-GW2IPSet([string[]]$Paths) {
    $groups = @{}; $count = 0
    foreach ($path in $Paths) {
        if (-not [IO.File]::Exists($path)) { continue }
        foreach ($line in [IO.File]::ReadLines($path)) {
            $line = $line.Trim()
            if (-not $line -or $line.StartsWith('#')) { continue }
            $parts = $line.Split('/')
            if ($parts.Count -gt 2) { throw 'Invalid IPSet entry.' }
            $address = ConvertTo-GW2Address $parts[0]
            $length = $address.GetAddressBytes().Length
            $prefix = $length * 8
            if ($parts.Count -eq 2 -and ($parts[1] -notmatch '^\d{1,3}$' -or -not [int]::TryParse($parts[1], [ref]$prefix))) { throw 'Invalid IPSet prefix.' }
            $key = "$length/$prefix"
            if (-not $groups.ContainsKey($key)) {
                $groups[$key] = [pscustomobject]@{ Length=$length; Prefix=$prefix; Networks=[Collections.Generic.HashSet[string]]::new() }
            }
            $null = $groups[$key].Networks.Add((Get-GW2NetworkKey $address $prefix)); $count++
        }
    }
    return [pscustomobject]@{ Groups=$groups; Count=$count }
}
function Test-GW2IPSet($Set, [string]$Value) {
    $address = ConvertTo-GW2Address $Value
    foreach ($group in $Set.Groups.Values) {
        if ($group.Length -eq $address.GetAddressBytes().Length -and $group.Networks.Contains((Get-GW2NetworkKey $address $group.Prefix))) { return $true }
    }
    return $false
}
function Test-GW2PublicAddress([string]$Value) {
    $address = ConvertTo-GW2Address $Value
    $bytes = $address.GetAddressBytes()
    if ($bytes.Length -eq 4) {
        return -not ($bytes[0] -in @(0,10,127) -or $bytes[0] -ge 224 -or
            ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or
            ($bytes[0] -eq 192 -and $bytes[1] -eq 168) -or
            ($bytes[0] -eq 169 -and $bytes[1] -eq 254) -or
            ($bytes[0] -eq 100 -and $bytes[1] -ge 64 -and $bytes[1] -le 127))
    }
    # Only IPv6 global unicast; local/proxy addresses are counted, never exported.
    return ($bytes[0] -band 224) -eq 32
}
function Get-GW2Sections([string]$Path) {
    $sections = @{}; $name = ''
    foreach ($line in [IO.File]::ReadLines($Path)) {
        if ($line -match '^\[([A-Z_]+)\]\s*$') { $name=$matches[1]; $sections[$name]=@(); continue }
        if ($name -and $line.Trim() -and -not $line.Trim().StartsWith('#')) { $sections[$name] += $line.Trim() }
    }
    return $sections
}
function New-GW2Config([string]$Root, [string]$IPSetPath, [int[]]$Ports) {
    $sections = Get-GW2Sections (Join-Path $Root 'presets\ALT11.txt.in')
    foreach ($key in @('PRESET_INIT','GAME_TCP_RANGE','GAME_TCP_ACTIONS')) {
        if (-not $sections.ContainsKey($key) -or -not $sections[$key].Count) { throw "ALT11 section missing: $key" }
    }
    if (($sections.GAME_TCP_RANGE -join '') -notmatch '^[-<][nd][1-9][0-9]?$') { throw 'Invalid ALT11 game range.' }
    if (-not $Ports.Count -or @($Ports | Where-Object { $_ -lt 1 -or $_ -gt 65535 }).Count) { throw 'Invalid test ports.' }
    $rootPath = $Root.Replace('\','/').TrimEnd('/')
    $lines = @('--debug=0','--ctrack-disable=0', ('--chdir="'+$rootPath+'/bin"'),
        ('--wf-tcp-out='+ (($Ports | Sort-Object -Unique) -join ',')))
    foreach ($lua in @('zapret-lib.lua','zapret-antidpi.lua','zapret-auto.lua')) { $lines += '--lua-init=@"'+$rootPath+'/lua/'+$lua+'"' }
    # Published 0.4.5 ALT11 references tls_max from _base rather than PRESET_INIT.
    foreach ($line in [IO.File]::ReadLines((Join-Path $Root 'presets\_base.txt.in'))) {
        if ($line -match '^--blob=[A-Za-z0-9_]+:@fake/[^"\r\n]+$') {
            $lines += [regex]::Replace($line, ':@fake/([^\r\n]+)$', { param($match) ':@"'+$rootPath+'/bin/fake/'+$match.Groups[1].Value+'"' })
        }
    }
    foreach ($line in $sections.PRESET_INIT) {
        $line = [regex]::Replace($line, '=@\.\./lua/([^\r\n]+)$', { param($match) '=@"'+$rootPath+'/lua/'+$match.Groups[1].Value+'"' })
        $line = [regex]::Replace($line, ':@fake/([^\r\n]+)$', { param($match) ':@"'+$rootPath+'/bin/fake/'+$match.Groups[1].Value+'"' })
        $lines += $line
    }
    $lines += '--filter-tcp='+ (($Ports | Sort-Object -Unique) -join ',')
    $lines += '--ipset="'+$IPSetPath.Replace('\','/')+'"'
    foreach ($name in @('ipset-exclude.txt','ipset-exclude-user.txt')) {
        if ([IO.File]::Exists((Join-Path $Root ('lists\'+$name)))) { $lines += '--ipset-exclude="'+$rootPath+'/lists/'+$name+'"' }
    }
    $lines += '--payload=all'
    $lines += '--out-range='+ ($sections.GAME_TCP_RANGE -join '')
    $lines += $sections.GAME_TCP_ACTIONS
    return ($lines -join "`r`n") + "`r`n"
}
function Get-GW2Setting([string]$Root, [string]$Name, [string[]]$Allowed) {
    $path = Join-Path $Root ('utils\'+$Name)
    if (-not [IO.File]::Exists($path)) { return 'default' }
    $value = [IO.File]::ReadAllText($path).Trim().ToLowerInvariant()
    if ($value -in $Allowed) { return $value }
    return 'unknown'
}
function Get-GW2SettingsHashes([string]$Root) {
    $paths = @('runtime\service.txt')
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $Root 'utils') -File) {
        if ($file.Extension -in @('.mode','.ports','.enabled')) { $paths += 'utils\'+$file.Name }
    }
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $Root 'lists') -File) { $paths += 'lists\'+$file.Name }
    $hashes = @{}
    foreach ($relative in $paths) {
        $path = Join-Path $Root $relative
        $hashes[$relative] = if ([IO.File]::Exists($path)) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash } else { 'missing' }
    }
    return $hashes
}
function Test-GW2HashesEqual($Before, $After) {
    if ($Before.Count -ne $After.Count) { return $false }
    foreach ($key in $Before.Keys) { if (-not $After.ContainsKey($key) -or $Before[$key] -ne $After[$key]) { return $false } }
    return $true
}
function Invoke-GW2WithRestore([scriptblock]$Body, [scriptblock]$StopEngine, [scriptblock]$RestoreService) {
    try { & $Body } finally {
        # Never start the original service on top of an engine that failed to stop.
        & $StopEngine
        & $RestoreService
    }
}
