# Shared validation for menu, renderer and release migration. No system changes.
function ConvertTo-ZapretPortRange([string]$Value) {
    $value = $Value -replace '\s', ''
    if (-not $value -or $value.Length -gt 2048) { throw 'Enter ports/ranges from 1 to 65535.' }
    $items = foreach ($item in $value.Split(',')) {
        if ($item -notmatch '^([0-9]{1,5})(?:-([0-9]{1,5}))?$') { throw 'Invalid port range.' }
        $start = [int]$matches[1]
        $end = if ($matches[2]) { [int]$matches[2] } else { $start }
        if ($start -lt 1 -or $end -gt 65535 -or $start -gt $end) { throw 'Ports must be in 1-65535; ranges must be ascending.' }
        if ($start -eq $end) { [string]$start } else { "$start-$end" }
    }
    (@($items | Select-Object -Unique) -join ',')
}
function Get-ZapretGamePorts([string]$Root, [string]$Protocol) {
    $path = Join-Path $Root ('utils\game_' + $Protocol + '.ports')
    $value = if ([IO.File]::Exists($path)) { [IO.File]::ReadAllText($path).Trim() } else { '1024-65535' }
    ConvertTo-ZapretPortRange $value
}
function Test-ZapretFakeSelection([string]$Value, [string]$Kind) {
    $known = if ($Kind -eq 'Discord') { @('current','steam','google') } else { @('current','dbank-v2','steam') }
    $Value -in $known -or $Value -cmatch '^custom:[a-f0-9]{64}$'
}
function Get-ZapretFakeLabel([string]$Value) {
    if ($Value -cmatch '^custom:([a-f0-9]{64})$') { return 'custom/' + $matches[1].Substring(0,12) }
    $Value
}
function Get-ZapretFakePath([string]$Root, [string]$Value, [string]$Kind) {
    if (-not (Test-ZapretFakeSelection $Value $Kind)) { throw 'Unknown UDP fake profile.' }
    if ($Value -cmatch '^custom:([a-f0-9]{64})$') {
        $expected = $matches[1]
        $path = Join-Path $Root ('lists\fakes\' + $expected + '.bin')
    } else {
        $files = @{current='quic_initial_dbankcloud_ru.bin';steam='quic_initial_steamcommunity_com.bin';google='quic_initial_www_google_com.bin';'dbank-v2'='quic_initial_dbankcloud_ru_v2.bin'}
        $path = Join-Path $Root ('bin\fake\' + $files[$Value])
        $expected = ''
    }
    $file = Get-Item -LiteralPath $path -ErrorAction Stop
    if ($file.PSIsContainer -or $file.Length -lt 1 -or $file.Length -gt 65535) { throw 'UDP fake must contain 1-65535 bytes.' }
    # Never follow a directory junction or a linked payload out of the bundle.
    $current = $file.FullName
    $base = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    while ($current.Length -gt $base.Length) {
        if ([IO.File]::GetAttributes($current) -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked fake paths are not supported.' }
        $current = Split-Path -Parent $current
    }
    if ($expected -and (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $expected) { throw 'The selected custom fake was changed. Select it again.' }
    $file.FullName
}
function Get-ZapretFakeChoices([string]$Root) {
    foreach ($directory in @('bin\fake','lists\fakes')) {
        $folder = Join-Path $Root $directory
        if (-not [IO.Directory]::Exists($folder)) { continue }
        if ([IO.File]::GetAttributes($folder) -band [IO.FileAttributes]::ReparsePoint) { continue }
        foreach ($file in Get-ChildItem -LiteralPath $folder -Filter '*.bin' -File | Sort-Object Name) {
            if ($file.Length -lt 1 -or $file.Length -gt 65535 -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
            [pscustomobject]@{Name=$file.Name;Path=$file.FullName;Hash=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
        }
    }
}
function Import-ZapretFake([string]$Root, $Choice) {
    $bytes = [IO.File]::ReadAllBytes($Choice.Path)
    if ($bytes.Length -lt 1 -or $bytes.Length -gt 65535) { throw 'UDP fake must contain 1-65535 bytes.' }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
    if ($hash -cne $Choice.Hash) { throw 'The fake changed while selecting it. Try again.' }
    $folder = Join-Path $Root 'lists\fakes'
    [IO.Directory]::CreateDirectory($folder) | Out-Null
    if ([IO.File]::GetAttributes($folder) -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked custom fake directories are not supported.' }
    $path = Join-Path $folder ($hash + '.bin')
    if ([IO.File]::Exists($path) -and ([IO.File]::GetAttributes($path) -band [IO.FileAttributes]::ReparsePoint)) { throw 'Linked custom fake files are not supported.' }
    if (-not [IO.File]::Exists($path) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $hash) { Write-AtomicFileBytes $path $bytes }
    $selection = 'custom:' + $hash
    $null = Get-ZapretFakePath $Root $selection Discord
    $selection
}
