. (Join-Path $PSScriptRoot 'bundle-operation.ps1')
. (Join-Path $PSScriptRoot 'ipset-utils.ps1')
. (Join-Path $PSScriptRoot 'config-settings.ps1')
function Set-ReleaseMenuSetting([string]$Root, [string]$Name, [string]$Value) {
    $modes = @{
        'game_filter.mode'=@('off','tcp','udp','all');'ipset_filter.mode'=@('loaded','none','any')
        'voice_filter.mode'=@('off','standard','compatible');'discord_fake.mode'=@('current','steam','google')
        'game_fake.mode'=@('current','dbank-v2','steam')
    }
    if ($Name -in @('game_tcp.ports','game_udp.ports')) { $Value = ConvertTo-ZapretPortRange $Value }
    elseif ($Name -in @('discord_fake.mode','game_fake.mode')) {
        $kind = if ($Name -eq 'discord_fake.mode') { 'Discord' } else { 'Game' }
        $null = Get-ZapretFakePath $Root $Value $kind
    }
    elseif ($Name -ne 'fake-defaults' -and (-not $modes.ContainsKey($Name) -or $Value -notin $modes[$Name])) { throw 'Invalid setting.' }
    if ($Name -eq 'fake-defaults' -and $Value -cne 'current') { throw 'Invalid fake defaults.' }
    $gate = Enter-ZapretBundleOperation $Root
    try {
        $oldValue = try { if (Test-Path -LiteralPath (Join-Path $Root ('utils\'+$Name))) { ([IO.File]::ReadAllText((Join-Path $Root ('utils\'+$Name)))).Trim() } else { '' } } catch { Write-ZapretLogException $_ -Warning; '' }
        if ($Name -eq 'fake-defaults') {
            foreach ($file in @('discord_fake.mode','game_fake.mode')) {
                $path=Join-Path $Root ('utils\'+$file)
                if (-not [IO.File]::Exists($path) -or [IO.File]::ReadAllText($path).Trim() -cne 'current') { Write-AtomicTextFile $path "current`r`n" }
            }
        } elseif ($oldValue -cne $Value) { Write-AtomicTextFile -Path (Join-Path $Root ('utils\' + $Name)) -Content ($Value + "`r`n") }
    }
    finally { Exit-ZapretBundleOperation $gate }
    Write-ZapretLogEvent -Stage settings -Result saved -Code SettingsSaved -Details @{setting=$Name;oldValue=$oldValue;newValue=$Value}
}

function Switch-ReleaseMenuCheck([string]$Root) {
    $gate=Enter-ZapretBundleOperation $Root
    try {
        $path=Join-Path $Root 'utils\check_updates.enabled'
        if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }
        else { Write-AtomicTextFile $path "enabled`r`n" }
        Write-ZapretLogEvent -Stage settings -Result saved -Code SettingsSaved -Details @{setting='check_updates.enabled';autoCheck=[IO.File]::Exists($path)}
    } finally { Exit-ZapretBundleOperation $gate }
}
