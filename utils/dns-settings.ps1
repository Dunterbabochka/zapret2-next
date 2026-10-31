# Shared DNS readers/settings. Native code loads only when DNS is queried.
function Initialize-ZapretDnsNative {
    if (-not ('ZapretDns.Native' -as [type])) {
        Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'dns-native.cs'))) -ErrorAction Stop
    }
}
function Get-ZapretDnsApiVersion {
    $build=[int](Get-ItemPropertyValue -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name CurrentBuildNumber -ErrorAction Stop)
    if ($build -lt 19041) { throw 'DNS Settings requires Windows 10 version 2004 or newer.' }
    if ($build -ge 22000) { return 3 }
    return 1
}
function Get-ZapretDnsMachineId {
    [string](Get-ItemPropertyValue -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -ErrorAction Stop)
}
function Get-ZapretDnsPresets {
    @(
        [pscustomobject]@{Name='Google';IPv4=@('8.8.8.8','8.8.4.4');IPv6=@('2001:4860:4860::8888','2001:4860:4860::8844');Template='https://dns.google/dns-query'},
        [pscustomobject]@{Name='Cloudflare';IPv4=@('1.1.1.1','1.0.0.1');IPv6=@('2606:4700:4700::1111','2606:4700:4700::1001');Template='https://cloudflare-dns.com/dns-query'},
        [pscustomobject]@{Name='Quad9';IPv4=@('9.9.9.9','149.112.112.112');IPv6=@('2620:fe::fe','2620:fe::9');Template='https://dns.quad9.net/dns-query'}
    )
}
function Get-ZapretDnsAdapters {
    @(Get-NetAdapter -ErrorAction Stop | Sort-Object @{Expression={if ($_.Status -eq 'Up') {0} else {1}}},Name)
}
function Get-ZapretDnsDefaultAdapter([object[]]$Adapters) {
    $active=@($Adapters | Where-Object Status -eq 'Up')
    if (-not $active.Count) { return $null }
    $interfaces=@()
    try { $interfaces=@(Get-NetIPInterface -ErrorAction SilentlyContinue | Where-Object ConnectionState -eq 'Connected') } catch {}
    $metrics=@{}
    foreach ($interface in $interfaces) { $metrics[([string]$interface.InterfaceIndex+'/'+$interface.AddressFamily)]=[long]$interface.InterfaceMetric }
    $routes=@()
    try { $routes=@(Get-NetRoute -DestinationPrefix '0.0.0.0/0','::/0' -PolicyStore ActiveStore -ErrorAction SilentlyContinue) } catch {}
    $candidates=@(foreach ($route in $routes) {
        if ([string]$route.State -in @('Dead','Unreachable')) { continue }
        $adapter=@($active | Where-Object ifIndex -eq $route.InterfaceIndex)
        if (-not $adapter.Count) { continue }
        $key=[string]$route.InterfaceIndex+'/'+$route.AddressFamily
        $metric=if ($metrics.ContainsKey($key)) {$metrics[$key]} elseif ($null -ne $route.InterfaceMetric) {[long]$route.InterfaceMetric} else {[long][uint32]::MaxValue}
        [pscustomobject]@{Adapter=$adapter[0];Family=$(if ($route.DestinationPrefix -eq '0.0.0.0/0') {0} else {1});Metric=([long]$route.RouteMetric+$metric)}
    })
    # Prefer the default IPv4 route; IPv6 covers IPv6-only connections.
    if ($candidates.Count) { return ($candidates | Sort-Object Family,Metric,@{Expression={$_.Adapter.ifIndex}} | Select-Object -First 1).Adapter }
    # Local/offline networks may have no default route yet.
    return $active | Sort-Object @{Expression={
        $index=$_.ifIndex
        $values=@($interfaces | Where-Object InterfaceIndex -eq $index | Select-Object -ExpandProperty InterfaceMetric)
        if ($values.Count) { ($values | Measure-Object -Minimum).Minimum } else {[long][uint32]::MaxValue}
    }},ifIndex | Select-Object -First 1
}
function Select-ZapretDnsAdapter([guid]$CurrentId=[guid]::Empty) {
    Clear-ZapretMenu
    $adapters=@(Get-ZapretDnsAdapters)
    Write-Host 'Выберите сетевой адаптер:' -ForegroundColor Cyan
    for ($i=0;$i -lt $adapters.Count;$i++) {
        $mark=if ([guid]$adapters[$i].InterfaceGuid -eq $CurrentId) {' — выбран'} else {''}
        Write-Host ('  {0}. {1} [{2}]{3}' -f ($i+1),$adapters[$i].Name,$adapters[$i].Status,$mark)
    }
    Write-Host '  0. Назад'
    $pick=Read-ZapretMenuLine 'Адаптер (0 = назад): '
    if ($pick -eq '0') { return $null }
    $number=0
    if (-not [int]::TryParse($pick,[ref]$number) -or $number -lt 1 -or $number -gt $adapters.Count) {
        Write-Host 'Неверный номер адаптера.' -ForegroundColor Yellow
        Wait-ZapretMenu
        return $null
    }
    return $adapters[$number-1]
}
function Read-ZapretDnsNativeFamily([guid]$AdapterId,[bool]$IPv6,[uint32]$Version) {
    [ZapretDns.Native]::Read($AdapterId,$IPv6,$Version)
}
function Write-ZapretDnsNativeFamily([guid]$AdapterId,$Family) {
    [ZapretDns.Native]::Write($AdapterId,[ZapretDns.FamilySettings]$Family)
}
function Get-ZapretDnsSnapshot($Adapter) {
    $version=Get-ZapretDnsApiVersion
    $bindings=@(Get-NetAdapterBinding -Name ([WildcardPattern]::Escape($Adapter.Name)) -ComponentID ms_tcpip,ms_tcpip6 -ErrorAction Stop | Where-Object Enabled)
    $families=@(foreach ($binding in $bindings) {
        Read-ZapretDnsNativeFamily ([guid]$Adapter.InterfaceGuid) ($binding.ComponentID -eq 'ms_tcpip6') $version
    })
    if (-not $families.Count) { throw 'No enabled IPv4/IPv6 binding on this adapter.' }
    $defaults=@(); $defaultsKnown=$false; $inherited=@{}
    foreach ($family in $families) {
        foreach ($pair in @(@{Servers=$family.NameServer;Properties=$family.Properties},@{Servers=$family.ProfileNameServer;Properties=$family.ProfileProperties})) {
            $addresses=@(Split-ZapretDnsServers $pair.Servers)
            for ($i=0;$i -lt $addresses.Count;$i++) {
                if (-not @($pair.Properties | Where-Object { $null -ne $_ -and $_.Index -eq $i }).Count) { $inherited[$addresses[$i]]=$true }
            }
        }
    }
    if ($version -eq 3 -and $inherited.Count) {
        try {
            $defaults=@(Get-DnsClientDohServerAddress -ErrorAction Stop | Where-Object {
                $inherited.ContainsKey(([Net.IPAddress]::Parse($_.ServerAddress)).ToString())
            } | Select-Object ServerAddress,AutoUpgrade,AllowFallbackToUdp,DohTemplate)
            $defaultsKnown=$true
        } catch { $defaults=@() }
    }
    $profileId=(@(Get-NetConnectionProfile -InterfaceIndex $Adapter.ifIndex -ErrorAction SilentlyContinue | Select-Object -ExpandProperty InstanceID | Sort-Object) -join ',')
    [pscustomobject]@{SchemaVersion=1;MachineId=Get-ZapretDnsMachineId;AdapterId=([guid]$Adapter.InterfaceGuid).ToString('D');ProfileId=$profileId;CapturedUtc=[datetime]::UtcNow.ToString('o');Families=$families;DohDefaultsKnown=$defaultsKnown;DohDefaults=$defaults}
}
function Split-ZapretDnsServers([string]$Value) {
    @($Value -split '[,;\s]+' | Where-Object { $_ } | ForEach-Object { ([Net.IPAddress]::Parse($_)).ToString() })
}
function Assert-ZapretDnsSnapshot($Snapshot,[guid]$AdapterId) {
    if ($Snapshot.SchemaVersion -ne 1 -or $Snapshot.MachineId -cne (Get-ZapretDnsMachineId) -or
        [guid]$Snapshot.AdapterId -ne $AdapterId -or $Snapshot.ProfileId -isnot [string] -or @($Snapshot.Families).Count -notin @(1,2)) {
        throw 'DNS backup does not match this computer/adapter or has an unsupported format.'
    }
    $seen=@{}
    foreach ($family in $Snapshot.Families) {
        if ($family.IPv6 -isnot [bool] -or $family.Version -notin @(1,3) -or $seen.ContainsKey([string]$family.IPv6)) { throw 'Invalid DNS family in backup.' }
        $seen[[string]$family.IPv6]=$true
        foreach ($pair in @(@{Servers=$family.NameServer;Properties=$family.Properties},@{Servers=$family.ProfileNameServer;Properties=$family.ProfileProperties})) {
            $servers=@(Split-ZapretDnsServers $pair.Servers)
            foreach ($server in $servers) {
                if (([Net.IPAddress]::Parse($server).AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6) -ne $family.IPv6) { throw 'DNS backup contains a mismatched address family.' }
            }
            $indices=@{}
            foreach ($property in @($pair.Properties)) {
                if ($null -eq $property) { continue }
                $index=[uint32]0; $flags=[uint64]0
                if (-not [uint32]::TryParse([string]$property.Index,[ref]$index) -or
                    -not [uint64]::TryParse([string]$property.Flags,[ref]$flags) -or
                    $index -ge $servers.Count -or $indices.ContainsKey($index) -or ($flags -band 3) -eq 3) { throw 'Invalid DNS encryption property in backup.' }
                $indices[$index]=$true
                if ($property.Template -and (([uri]$property.Template).Scheme -ne 'https' -or -not ([uri]$property.Template).Host)) { throw 'Invalid DNS HTTPS template in backup.' }
            }
        }
    }
}
function Get-ZapretDnsBackupPath([string]$Root,[guid]$AdapterId) {
    Join-Path $Root ('runtime\dns-settings\'+$AdapterId.ToString('D')+'.json')
}
function Save-ZapretDnsBackup([string]$Path,$Snapshot) {
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) | Out-Null
    $temporary=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try {
        $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($Snapshot | ConvertTo-Json -Depth 12))
        $stream=[IO.File]::Open($temporary,'CreateNew','Write','None')
        try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        # Never replace the original settings with a later preset selection.
        [IO.File]::Move($temporary,$Path)
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}
function Read-ZapretDnsBackup([string]$Path,[guid]$AdapterId) {
    $snapshot=[IO.File]::ReadAllText($Path) | ConvertFrom-Json -ErrorAction Stop
    Assert-ZapretDnsSnapshot $snapshot $AdapterId
    return $snapshot
}
function Get-ZapretDnsEffectiveProperty($Snapshot,[string]$Address,$Properties,[int]$Index) {
    $explicit=@($Properties | Where-Object { $null -ne $_ -and $_.Index -eq $Index })
    if ($explicit.Count) { return $explicit[0] }
    if (-not $Snapshot.DohDefaultsKnown) { return $null }
    $policy=@($Snapshot.DohDefaults | Where-Object { ([Net.IPAddress]::Parse($_.ServerAddress)).ToString() -eq $Address })
    $flags=[uint64]0; $template=$null
    if ($policy.Count -and $policy[0].AutoUpgrade) {
        $flags=[uint64]1
        if ($policy[0].AllowFallbackToUdp) { $flags=$flags -bor 4 }
        $template=$policy[0].DohTemplate
    }
    [pscustomobject]@{Index=$Index;Flags=$flags;Template=$template}
}
function Get-ZapretDnsConfiguration($Snapshot) {
    $preset=$null
    foreach ($candidate in @(Get-ZapretDnsPresets)) {
        $isMatch=$true
        foreach ($family in $Snapshot.Families) {
            $expected=if ($family.IPv6) {$candidate.IPv6} else {$candidate.IPv4}
            $actual=if ($family.ProfileNameServer) {$family.ProfileNameServer} else {$family.NameServer}
            if ((@(Split-ZapretDnsServers $actual) -join ',') -cne ($expected -join ',')) { $isMatch=$false; break }
        }
        if ($isMatch) { $preset=$candidate; break }
    }
    $states=@(foreach ($family in $Snapshot.Families) {
        $servers=if ($family.ProfileNameServer) {$family.ProfileNameServer} else {$family.NameServer}
        $properties=if ($family.ProfileNameServer) {@($family.ProfileProperties)} else {@($family.Properties)}
        $addresses=@(Split-ZapretDnsServers $servers)
        for ($i=0;$i -lt $addresses.Count;$i++) {
            $property=Get-ZapretDnsEffectiveProperty $Snapshot $addresses[$i] $properties $i
            if ($property) {
                if (($property.Flags -band 3) -and -not ($property.Flags -band 4)) {'on'}
                elseif ($property.Flags -band 3) {'fallback'}
                elseif ($property.Flags -in @(0,4)) {'off'}
                else {'system'}
            } else {
                # No local override: the resolver may inherit machine-wide DoH.
                'system'
            }
        }
    })
    $https=if (@($Snapshot.Families | Where-Object Version -ne 3).Count) {'unavailable'}
        elseif (-not $states.Count) {'off'}
        elseif (@($states | Select-Object -Unique).Count -eq 1) {$states[0]}
        else {'mixed'}
    [pscustomobject]@{Preset=$preset;Https=$https}
}
function Format-ZapretDnsMenuStatus($Snapshot) {
    if (-not @($Snapshot.Families).Count) { return 'UNKNOWN' }
    $manual=@($Snapshot.Families | Where-Object { $_.NameServer -or $_.ProfileNameServer })
    if (-not $manual.Count) { return 'AUTO' }
    # An automatic second stack must not hide a known manually assigned provider.
    $configuration=Get-ZapretDnsConfiguration ([pscustomobject]@{Families=$manual;DohDefaultsKnown=$Snapshot.DohDefaultsKnown;DohDefaults=$Snapshot.DohDefaults})
    $provider=if ($configuration.Preset) {
        switch ($configuration.Preset.Name) { 'Google' {'GOOGLE'} 'Cloudflare' {'CL.FLARE'} 'Quad9' {'QUAD9'} }
    } else { 'CUSTOM' }
    $encryption=switch ($configuration.Https) {
        'on' {'HTTPS'}
        'off' {'HTTPS OFF'}
        'unavailable' {'HTTPS N/A'}
        'fallback' {'FALLBACK'}
        'system' {'SYSTEM'}
        default {'MIXED'}
    }
    return $provider+' | '+$encryption
}
function Get-ZapretDnsMenuStatus {
    $adapter=Get-ZapretDnsDefaultAdapter @(Get-ZapretDnsAdapters)
    if (-not $adapter) { return 'NO LINK' }
    Initialize-ZapretDnsNative
    Format-ZapretDnsMenuStatus (Get-ZapretDnsSnapshot $adapter)
}
function New-ZapretDnsConfiguration($Snapshot,$Preset,[bool]$Https,[switch]$Automatic) {
    # A detached JSON copy also exercises the persisted backup representation.
    $result=$Snapshot | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    foreach ($family in $result.Families) {
        $servers=if ($Automatic) {@()} elseif ($family.IPv6) {@($Preset.IPv6)} else {@($Preset.IPv4)}
        $family.NameServer=$servers -join ','
        # Clear a Wi-Fi profile override so it cannot silently shadow this preset.
        $family.ProfileNameServer=''
        $family.Properties=@(for ($i=0;$i -lt $servers.Count;$i++) {
            if ($family.Version -eq 3) {
                [pscustomobject]@{Index=[uint32]$i;Template=$(if ($Https) {$Preset.Template} else {$null});Flags=[uint64]$(if ($Https) {2} else {0})}
            }
        })
        $family.ProfileProperties=@()
    }
    return $result
}
function Set-ZapretDnsSnapshot($Snapshot,[guid]$AdapterId) {
    Assert-ZapretDnsSnapshot $Snapshot $AdapterId
    foreach ($family in $Snapshot.Families) { Write-ZapretDnsNativeFamily $AdapterId $family }
}
function Get-ZapretDnsPropertyKey($Property) {
    if ($null -eq $Property) { return 'unknown' }
    $flags=[uint64]$Property.Flags
    # Inactive templates and fallback alone do not enable encryption. Windows
    # may retain the URL even when this entry is unencrypted.
    if ($flags -in @(0,4)) { return 'off' }
    if ($flags -band 1) { return ([string]$flags+'|auto') }
    return ([string]$flags+'|'+[string]$Property.Template)
}
function Assert-ZapretDnsApplied($Expected,$Actual) {
    Assert-ZapretDnsSnapshot $Actual ([guid]$Expected.AdapterId)
    if (@($Expected.Families).Count -ne @($Actual.Families).Count) { throw 'The adapter bindings changed while applying DNS settings.' }
    foreach ($family in $Expected.Families) {
        $observed=@($Actual.Families | Where-Object IPv6 -eq $family.IPv6)
        if ($observed.Count -ne 1) { throw 'The adapter bindings changed while applying DNS settings.' }
        foreach ($field in @('NameServer','ProfileNameServer')) {
            if ((@(Split-ZapretDnsServers $family.$field) -join ',') -cne (@(Split-ZapretDnsServers $observed[0].$field) -join ',')) {
                throw 'Windows did not retain the requested DNS addresses.'
            }
        }
        foreach ($pair in @(@{Servers='NameServer';Properties='Properties'},@{Servers='ProfileNameServer';Properties='ProfileProperties'})) {
            $addresses=@(Split-ZapretDnsServers $family.($pair.Servers))
            for ($i=0;$i -lt $addresses.Count;$i++) {
                $wanted=@($family.($pair.Properties) | Where-Object { $null -ne $_ -and $_.Index -eq $i })
                $found=@($observed[0].($pair.Properties) | Where-Object { $null -ne $_ -and $_.Index -eq $i })
                # No override on either side preserves inheritance, including
                # backups created before effective defaults were recorded.
                if (-not $wanted.Count -and -not $found.Count) { continue }
                $wantedKey=if ($wanted.Count) { Get-ZapretDnsPropertyKey $wanted[0] } else {'inherit'}
                if ($found.Count) { $foundKey=Get-ZapretDnsPropertyKey $found[0] }
                elseif ($wantedKey -eq 'off') {
                    # A zero-flags DoH entry is removed by Windows. Accept this
                    # only after proving the inherited resolver is unencrypted.
                    $effective=Get-ZapretDnsEffectiveProperty $Actual $addresses[$i] @() $i
                    $foundKey=Get-ZapretDnsPropertyKey $effective
                } else { $foundKey='inherit' }
                if ($wantedKey -cne $foundKey) {
                    $stack=if ($family.IPv6) {'IPv6'} else {'IPv4'}
                    throw ('Windows did not retain the requested DNS encryption settings. {0}/{1}, server #{2}: expected {3}, observed {4}.' -f $stack,$pair.Properties,($i+1),$wantedKey.Split('|')[0],$foundKey.Split('|')[0])
                }
            }
        }
    }
}
function Invoke-ZapretDnsChange {
    param([string]$Root,$Adapter,[ValidateSet('Preset','ToggleHttps','Automatic','Restore')][string]$Action,[string]$PresetName)
    $adapterId=[guid]$Adapter.InterfaceGuid
    $mutex=[Threading.Mutex]::new($false,'Global\Zapret2Next-DnsSettings')
    $locked=$false
    try {
        try { $locked=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked=$true }
        if (-not $locked) { throw 'Another DNS settings operation is running. Try again when it finishes.' }
        $current=Get-ZapretDnsSnapshot $Adapter
        Assert-ZapretDnsSnapshot $current $adapterId
        $path=Get-ZapretDnsBackupPath $Root $adapterId
        $backup=if ([IO.File]::Exists($path)) { Read-ZapretDnsBackup $path $adapterId } else {$null}
        if ($backup -and $backup.ProfileId -cne $current.ProfileId) {
            throw 'The saved DNS settings belong to a different network profile. Reconnect to the original network and restore them first.'
        }
        if ($backup -and $Action -ne 'Restore' -and
            ((@($backup.Families.IPv6 | Sort-Object) -join ',') -cne (@($current.Families.IPv6 | Sort-Object) -join ','))) {
            throw 'IPv4/IPv6 bindings changed after saving DNS settings. Restore previous settings before selecting a new preset.'
        }
        if ($Action -eq 'Restore') {
            if (-not $backup) { throw 'No previous DNS settings have been saved for this adapter.' }
            $missing=@($backup.Families | Where-Object { $savedFamily=$_; -not @($current.Families | Where-Object IPv6 -eq $savedFamily.IPv6).Count })
            if ($missing.Count) { throw 'Re-enable the IPv4/IPv6 bindings saved in the backup before restoring DNS settings.' }
            $target=$backup | ConvertTo-Json -Depth 12 | ConvertFrom-Json
            # A protocol enabled later has never been changed by this backup.
            $target.Families=@($target.Families)+@($current.Families | Where-Object { $newFamily=$_; -not @($backup.Families | Where-Object IPv6 -eq $newFamily.IPv6).Count })
        } else {
            $configuration=Get-ZapretDnsConfiguration $current
            $https=$configuration.Https -eq 'on'
            $preset=if ($Action -eq 'Preset') { @(Get-ZapretDnsPresets | Where-Object Name -eq $PresetName)[0] } else {$configuration.Preset}
            if ($Action -eq 'ToggleHttps') {
                if ($configuration.Https -eq 'unavailable') { throw 'System DNS over HTTPS requires Windows 11. DNS presets remain available without encryption.' }
                if (-not $preset) { throw 'Select Google, Cloudflare or Quad9 first, then change HTTPS encryption.' }
                $https=-not $https
            }
            if ($Action -ne 'Automatic' -and -not $preset) { throw 'Unknown DNS preset.' }
            $target=New-ZapretDnsConfiguration $current $preset $https -Automatic:($Action -eq 'Automatic')
        }
        if (-not $backup) { Save-ZapretDnsBackup $path $current }
        try {
            Set-ZapretDnsSnapshot $target $adapterId
            Assert-ZapretDnsApplied $target (Get-ZapretDnsSnapshot $Adapter)
            Clear-DnsClientCache -ErrorAction Stop
        } catch {
            $failure=$_.Exception.Message
            try {
                Set-ZapretDnsSnapshot $current $adapterId
                Assert-ZapretDnsApplied $current (Get-ZapretDnsSnapshot $Adapter)
                Clear-DnsClientCache -ErrorAction Stop
            }
            catch { throw ('DNS change failed: '+$failure+' Rollback also failed. Use Restore previous settings. '+$_.Exception.Message) }
            throw ('DNS change failed; settings before this operation were restored. '+$failure)
        }
        if ($Action -eq 'Restore') { [IO.File]::Delete($path) }
    } finally { if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}
function Show-ZapretDnsMenu {
    Initialize-ZapretDnsNative
    $adapters=@(Get-ZapretDnsAdapters)
    $adapter=Get-ZapretDnsDefaultAdapter $adapters
    do {
        Clear-ZapretMenu
        $snapshot=$null
        $configuration=[pscustomobject]@{Https='unavailable';Preset=$null}
        Write-Host 'Настройки DNS' -ForegroundColor Cyan
        if ($adapter) {
            Write-Host ('Сетевой адаптер: '+$adapter.Name)
            try {
                $snapshot=Get-ZapretDnsSnapshot $adapter
                $configuration=Get-ZapretDnsConfiguration $snapshot
                $name=if ($configuration.Preset) {$configuration.Preset.Name} else {'Системные / пользовательские'}
                Write-Host ('Текущий DNS: '+$name)
                foreach ($family in $snapshot.Families) {
                    $servers=if ($family.ProfileNameServer) {$family.ProfileNameServer} elseif ($family.NameServer) {$family.NameServer} else {'автоматически'}
                    Write-Host ('  IPv{0}: {1}' -f $(if ($family.IPv6) {6} else {4}),$servers)
                }
            } catch { $snapshot=$null; Write-Host ('[ERROR] '+$_.Exception.Message) -ForegroundColor Red }
        } else {
            Write-Host 'Активный адаптер не найден. Выберите подключение в пункте 7.' -ForegroundColor Yellow
        }
        Write-Host "`n  1. Google       — 8.8.8.8 / 8.8.4.4`n  2. Cloudflare   — 1.1.1.1 / 1.0.0.1`n  3. Quad9        — 9.9.9.9 / 149.112.112.112"
        Write-Host ''
        $httpsVerb=if ($configuration.Https -eq 'on') {'Выключить'} else {'Включить'}
        Write-Host ('  4. {0} шифрование HTTPS [{1}]' -f $httpsVerb,$configuration.Https)
        Write-Host "  5. Вернуть DNS автоматически`n  6. Восстановить предыдущие настройки`n  7. Сменить сетевой адаптер`n  0. Назад`n"
        if ($snapshot -and $configuration.Https -eq 'unavailable') { Write-Host 'Системный DNS over HTTPS доступен в Windows 11.' -ForegroundColor Yellow }
        elseif ($configuration.Https -in @('system','mixed','fallback')) { Write-Host 'HTTPS: унаследованные или смешанные настройки. Пункт 4 включает только HTTPS.' }
        Write-Host 'HTTPS [on]: только зашифрованный DNS, без перехода на обычный при сбое.'
        $pick=Read-ZapretMenuLine 'Выберите пункт (0-7): '
        if ($pick -eq '0') { return }
        if ($pick -eq '7') {
            $currentId=if ($adapter) {[guid]$adapter.InterfaceGuid} else {[guid]::Empty}
            $selected=Select-ZapretDnsAdapter $currentId
            if ($selected) { $adapter=$selected }
            continue
        }
        $dnsAction=switch ($pick) {'1' {'Preset'} '2' {'Preset'} '3' {'Preset'} '4' {'ToggleHttps'} '5' {'Automatic'} '6' {'Restore'}}
        if (-not $dnsAction) { continue }
        if (-not $snapshot) { Write-Host 'Сначала выберите доступный адаптер в пункте 7.' -ForegroundColor Yellow; Wait-ZapretMenu; continue }
        $presetName=if ($dnsAction -eq 'Preset') {@(Get-ZapretDnsPresets)[[int]$pick-1].Name} else {''}
        try {
            $logAction=if ($dnsAction -eq 'Restore') {'Restore'} else {'SetSetting'}
            Invoke-ZapretMenuOperation menu $logAction { Invoke-ZapretDnsChange -Root $root -Adapter $adapter -Action $dnsAction -PresetName $presetName }
            Write-Host 'Настройки DNS применены.' -ForegroundColor Green
        } catch { Write-ZapretLogException $_ -Warning; Write-Host ('[ERROR] '+$_.Exception.Message) -ForegroundColor Red }
        Wait-ZapretMenu
    } while ($true)
}
