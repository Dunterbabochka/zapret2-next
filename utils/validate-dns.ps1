# DNS regressions use in-memory adapters. The only live native calls read settings.
$ErrorActionPreference='Stop'
$sourceRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$fixture=Join-Path $sourceRoot ('runtime\dns-tests-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixture) | Out-Null
. (Join-Path $PSScriptRoot 'dns-settings.ps1')
Initialize-ZapretDnsNative
$checks=0
function Assert-Dns([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message }; $script:checks++ }
function Copy-DnsObject($Value) { ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $Value -Depth 15) }
function Assert-DnsRejected([scriptblock]$Body,[string]$Message) {
    $rejected=$false
    try { & $Body } catch { $rejected=$true }
    Assert-Dns $rejected $Message
}

# Compile on Windows PowerShell 5.1 and exercise the real read/free ABI.
$liveCount=0;$skippedLiveCount=0
foreach ($adapter in @(Get-ZapretDnsAdapters | Where-Object Status -eq Up)) {
    try {
        $bindings=@(Get-NetAdapterBinding -Name ([WildcardPattern]::Escape($adapter.Name)) -ComponentID ms_tcpip,ms_tcpip6 -ErrorAction Stop | Where-Object Enabled)
    } catch {
        # Hosted Windows runners expose service NICs with no IP bindings.
        # Only this expected absence is skipped; native/read failures still fail.
        if ($_.FullyQualifiedErrorId -like 'CmdletizationQuery_NotFound,*') { $skippedLiveCount++; continue }
        throw
    }
    if (-not $bindings.Count) { $skippedLiveCount++; continue }
    $snapshot=Get-ZapretDnsSnapshot $adapter
    Assert-ZapretDnsSnapshot $snapshot ([guid]$adapter.InterfaceGuid)
    Assert-Dns (@($snapshot.Families).Count -gt 0) 'Live adapter DNS read failed'
    foreach ($family in $snapshot.Families) {
        $typed=[ZapretDns.FamilySettings](Copy-DnsObject $family)
        Assert-Dns ($typed.IPv6 -eq $family.IPv6 -and $typed.Version -eq $family.Version) 'Backup cannot be converted to native settings'
    }
    $liveCount++
}

$script:dnsBuild='26200'
function Get-ItemPropertyValue { param($LiteralPath,$Name,$ErrorAction); if ($Name -eq 'CurrentBuildNumber') {$script:dnsBuild} else {'fixture-machine'} }
Assert-Dns ((Get-ZapretDnsApiVersion) -eq 3) 'Windows 11 must support per-interface DoH'
$script:dnsBuild='19045'
Assert-Dns ((Get-ZapretDnsApiVersion) -eq 1) 'Windows 10 must use the unencrypted DNS API'
$script:dnsBuild='18363'
Assert-DnsRejected { Get-ZapretDnsApiVersion } 'Unsupported Windows build was allowed to change DNS'
$script:dnsBuild='26200'

$script:dnsAdapters=@(
    [pscustomobject]@{Name='Fixture Ethernet';InterfaceGuid='11111111-1111-1111-1111-111111111111';Status='Up';ifIndex=101},
    [pscustomobject]@{Name='Fixture Wi-Fi';InterfaceGuid='22222222-2222-2222-2222-222222222222';Status='Up';ifIndex=102}
)
$adapter=$script:dnsAdapters[0];$other=$script:dnsAdapters[1]
$script:dnsInterfaces=@(
    [pscustomobject]@{InterfaceIndex=101;AddressFamily='IPv4';ConnectionState='Connected';InterfaceMetric=5},
    [pscustomobject]@{InterfaceIndex=102;AddressFamily='IPv4';ConnectionState='Connected';InterfaceMetric=25}
)
$script:dnsRoutes=@(
    [pscustomobject]@{InterfaceIndex=101;AddressFamily='IPv4';DestinationPrefix='0.0.0.0/0';RouteMetric=100;InterfaceMetric=5;State='Alive'},
    [pscustomobject]@{InterfaceIndex=102;AddressFamily='IPv4';DestinationPrefix='0.0.0.0/0';RouteMetric=1;InterfaceMetric=25;State='Alive'}
)
$script:dnsRouteFailure=$false;$script:dnsInterfaceFailure=$false
function Get-NetRoute { param($DestinationPrefix,$PolicyStore,$ErrorAction); if ($script:dnsRouteFailure) {throw 'Injected route lookup error'}; $script:dnsRoutes }
function Get-NetIPInterface { param($ErrorAction); if ($script:dnsInterfaceFailure) {throw 'Injected interface lookup error'}; $script:dnsInterfaces }
$defaultRoutes=@($script:dnsRoutes | ForEach-Object { Copy-DnsObject $_ })
Assert-Dns ((Get-ZapretDnsDefaultAdapter $script:dnsAdapters).InterfaceGuid -eq $other.InterfaceGuid) 'Auto-selection ignored the combined route/interface metric'
$script:dnsRoutes[0].RouteMetric=5
Assert-Dns ((Get-ZapretDnsDefaultAdapter $script:dnsAdapters).InterfaceGuid -eq $adapter.InterfaceGuid) 'Auto-selection ignored a better default route'
$script:dnsRoutes[0].State='Dead'
Assert-Dns ((Get-ZapretDnsDefaultAdapter $script:dnsAdapters).InterfaceGuid -eq $other.InterfaceGuid) 'Auto-selection used a dead route'
$script:dnsRoutes=@($defaultRoutes | ForEach-Object { Copy-DnsObject $_ })
$script:dnsAdapters[1].Status='Disconnected'
Assert-Dns ((Get-ZapretDnsDefaultAdapter $script:dnsAdapters).InterfaceGuid -eq $adapter.InterfaceGuid) 'Auto-selection used a disconnected adapter'
$script:dnsAdapters[1].Status='Up'
$script:dnsRoutes=@([pscustomobject]@{InterfaceIndex=102;AddressFamily='IPv6';DestinationPrefix='::/0';RouteMetric=1;InterfaceMetric=25;State='Alive'})
Assert-Dns ((Get-ZapretDnsDefaultAdapter $script:dnsAdapters).InterfaceGuid -eq $other.InterfaceGuid) 'IPv6-only default route was not selected'
$script:dnsRoutes+=Copy-DnsObject $defaultRoutes[0]
Assert-Dns ((Get-ZapretDnsDefaultAdapter $script:dnsAdapters).InterfaceGuid -eq $adapter.InterfaceGuid) 'IPv4 default route preference was lost'
$script:dnsRoutes=@()
Assert-Dns ((Get-ZapretDnsDefaultAdapter $script:dnsAdapters).InterfaceGuid -eq $adapter.InterfaceGuid) 'Offline fallback ignored connected interface metrics'
$script:dnsRouteFailure=$true
Assert-Dns ((Get-ZapretDnsDefaultAdapter $script:dnsAdapters).InterfaceGuid -eq $adapter.InterfaceGuid) 'Route lookup failure prevented the offline fallback'
$script:dnsInterfaceFailure=$true
Assert-Dns ((Get-ZapretDnsDefaultAdapter $script:dnsAdapters).InterfaceGuid -eq $adapter.InterfaceGuid) 'Missing interface metrics prevented a deterministic fallback'
$script:dnsRouteFailure=$false;$script:dnsInterfaceFailure=$false
$script:dnsRoutes=@($defaultRoutes | ForEach-Object { Copy-DnsObject $_ })
Assert-Dns ($null -eq (Get-ZapretDnsDefaultAdapter @())) 'Empty adapter list produced an automatic target'
foreach ($item in $script:dnsAdapters) {$item.Status='Disconnected'}
Assert-Dns ($null -eq (Get-ZapretDnsDefaultAdapter $script:dnsAdapters)) 'No active adapter produced an automatic target'
foreach ($item in $script:dnsAdapters) {$item.Status='Up'}
$script:dnsState=@{}
foreach ($item in $script:dnsAdapters) {
    foreach ($ipv6 in @($false,$true)) {
        $script:dnsState[$item.InterfaceGuid+'/'+$ipv6]=[pscustomobject]@{
            IPv6=$ipv6;Version=3;NameServer='';ProfileNameServer='';Properties=@();ProfileProperties=@()
        }
    }
}
$script:dnsBindings=@('ms_tcpip','ms_tcpip6')
function Get-NetAdapterBinding { param($Name,$ComponentID,$ErrorAction); foreach ($id in $script:dnsBindings) {[pscustomobject]@{Enabled=$true;ComponentID=$id}} }
$script:dnsProfile='fixture-network'
function Get-NetConnectionProfile { param($InterfaceIndex,$ErrorAction); [pscustomobject]@{InstanceID=$script:dnsProfile} }
function Get-ZapretDnsAdapters { $script:dnsAdapters }
$script:dnsDefaultUpgrade=$false;$script:dnsDefaultLookupFailure=$false
function Get-DnsClientDohServerAddress {
    param($ErrorAction)
    if ($script:dnsDefaultLookupFailure) { throw 'Injected DoH defaults lookup error' }
    foreach ($preset in @(Get-ZapretDnsPresets)) {
        foreach ($address in @($preset.IPv4)+@($preset.IPv6)) {
            [pscustomobject]@{ServerAddress=$address;AutoUpgrade=$script:dnsDefaultUpgrade;AllowFallbackToUdp=$false;DohTemplate=$preset.Template}
        }
    }
}
function Read-ZapretDnsNativeFamily {
    param([guid]$AdapterId,[bool]$IPv6,[uint32]$Version)
    $value=Copy-DnsObject $script:dnsState[$AdapterId.ToString('D')+'/'+$IPv6]
    $value.Version=$Version
    return $value
}
$script:dnsWrites=[Collections.Generic.List[object]]::new()
$script:dnsFailWrite=-1;$script:dnsFailWrites=@();$script:dnsIgnoreWrite=-1;$script:dnsFailCache=0;$script:dnsCacheClears=0
$script:dnsDropZeroProperties=$true;$script:dnsRetainInactiveTemplate=$false
function Write-ZapretDnsNativeFamily {
    param([guid]$AdapterId,$Family)
    $script:dnsWrites.Add((Copy-DnsObject $Family))
    if ($script:dnsWrites.Count -eq $script:dnsFailWrite -or $script:dnsFailWrites -contains $script:dnsWrites.Count) { throw 'Injected native write failure' }
    if ($script:dnsWrites.Count -eq $script:dnsIgnoreWrite) { return }
    # Ensure production JSON-to-native conversion also accepts nested DoH fields.
    $typed=[ZapretDns.FamilySettings]$Family
    $key=$AdapterId.ToString('D')+'/'+$Family.IPv6
    $value=Copy-DnsObject $typed
    foreach ($field in @('Properties','ProfileProperties')) {
        if ($script:dnsRetainInactiveTemplate) {
            foreach ($property in $value.$field) {
                if ($property.Flags -eq 0) {
                    $previous=@($script:dnsState[$key].$field | Where-Object Index -eq $property.Index)
                    if ($previous.Count) { $property.Template=$previous[0].Template }
                }
            }
        }
        # Observed Windows 11 behavior: flags=0 removes the DoH override.
        if ($script:dnsDropZeroProperties) { $value.$field=@($value.$field | Where-Object Flags -ne 0) }
    }
    $script:dnsState[$key]=$value
}
function Clear-DnsClientCache {
    param($ErrorAction)
    $script:dnsCacheClears++
    if ($script:dnsFailCache -gt 0) { $script:dnsFailCache--; throw 'Injected cache failure' }
}
$original=Get-ZapretDnsSnapshot $adapter
$untouched=Get-ZapretDnsSnapshot $other
Assert-Dns ((Format-ZapretDnsMenuStatus $original) -eq 'AUTO') 'Automatic DNS must be labeled AUTO'
$legacy=Copy-DnsObject $original
$legacy.PSObject.Properties.Remove('DohDefaultsKnown')
$legacy.PSObject.Properties.Remove('DohDefaults')
Assert-ZapretDnsApplied $legacy $original;$checks++
$expectedOn=New-ZapretDnsConfiguration $original @(Get-ZapretDnsPresets)[0] $true
foreach ($corruption in @('endpoint','fallback','discovery')) {
    $changed=Copy-DnsObject $expectedOn
    switch ($corruption) {
        endpoint {$changed.Families[0].Properties[0].Template='https://different.example/dns-query'}
        fallback {$changed.Families[0].Properties[0].Flags=6}
        discovery {$changed.Families[0].Properties[0].Flags=18}
    }
    Assert-DnsRejected { Assert-ZapretDnsApplied $expectedOn $changed } ('Encryption verification accepted an unexpected '+$corruption)
}
$partial=New-ZapretDnsConfiguration $original @(Get-ZapretDnsPresets)[0] $false
$partial.Families[1].NameServer='';$partial.Families[1].Properties=@()
Assert-Dns ((Format-ZapretDnsMenuStatus $partial) -eq 'GOOGLE | HTTPS OFF') 'Automatic IPv6 hid the manually configured IPv4 provider'
$backupPath=Get-ZapretDnsBackupPath $fixture ([guid]$adapter.InterfaceGuid)
Assert-DnsRejected { Invoke-ZapretDnsChange $fixture $adapter Restore } 'Restore without a backup succeeded'
Assert-DnsRejected { Invoke-ZapretDnsChange $fixture $adapter ToggleHttps } 'HTTPS must require a known preset'
Assert-DnsRejected { Invoke-ZapretDnsChange $fixture $adapter Preset Invalid } 'Unknown DNS preset was accepted'
Assert-Dns ($script:dnsWrites.Count -eq 0 -and -not [IO.File]::Exists($backupPath)) 'Rejected action changed DNS or saved a backup'

Invoke-ZapretDnsChange $fixture $adapter Preset Google
$saved=[IO.File]::ReadAllText($backupPath)
$current=Get-ZapretDnsSnapshot $adapter
Assert-Dns ((Get-ZapretDnsConfiguration $current).Preset.Name -eq 'Google') 'Google preset was not selected'
Assert-Dns ((Get-ZapretDnsConfiguration $current).Https -eq 'off') 'Selecting a preset must start with encryption off'
Assert-Dns ((Format-ZapretDnsMenuStatus $current) -eq 'GOOGLE | HTTPS OFF') 'Google without encryption has the wrong main-menu label'
Assert-Dns ((Get-ZapretDnsMenuStatus) -eq 'AUTO') 'The status must follow the default connection rather than another adapter'
$script:dnsRoutes[0].RouteMetric=0
Assert-Dns ((Get-ZapretDnsMenuStatus) -eq 'GOOGLE | HTTPS OFF') 'Live status ignored DNS configured on the default connection'
$script:dnsRoutes[0].RouteMetric=100
Assert-ZapretDnsApplied $original (Read-ZapretDnsBackup $backupPath ([guid]$adapter.InterfaceGuid))
Assert-ZapretDnsApplied $untouched (Get-ZapretDnsSnapshot $other)
$checks+=2
Invoke-ZapretDnsChange $fixture $adapter ToggleHttps
$current=Get-ZapretDnsSnapshot $adapter
Assert-Dns ((Get-ZapretDnsConfiguration $current).Https -eq 'on') 'HTTPS toggle did not enable encryption'
Assert-Dns ((Format-ZapretDnsMenuStatus $current) -eq 'GOOGLE | HTTPS') 'Enabled Google DoH has the wrong main-menu label'
foreach ($failure in @('inherited-https','unknown-defaults')) {
    $script:dnsDefaultUpgrade=$failure -eq 'inherited-https'
    $script:dnsDefaultLookupFailure=$failure -eq 'unknown-defaults'
    Assert-DnsRejected { Invoke-ZapretDnsChange $fixture $adapter ToggleHttps } ('Disabled mode was accepted without proof: '+$failure)
    Assert-Dns ((Get-ZapretDnsConfiguration (Get-ZapretDnsSnapshot $adapter)).Https -eq 'on') 'Failed disable did not restore the original HTTPS mode'
    $script:dnsDefaultUpgrade=$false;$script:dnsDefaultLookupFailure=$false
}
foreach ($family in $current.Families) {
    Assert-Dns (@($family.Properties).Count -eq 2) 'Both DNS servers must have encryption configured'
    Assert-Dns (@($family.Properties | Where-Object { $_.Flags -ne 2 -or $_.Template -ne 'https://dns.google/dns-query' }).Count -eq 0) 'HTTPS must use the provider endpoint with no UDP fallback'
}
foreach ($preset in @('Cloudflare','Quad9','Google')) {
    Invoke-ZapretDnsChange $fixture $adapter Preset $preset
    $status=Get-ZapretDnsConfiguration (Get-ZapretDnsSnapshot $adapter)
    Assert-Dns ($status.Preset.Name -eq $preset -and $status.Https -eq 'on') 'Changing provider must retain enabled HTTPS'
    $label=if ($preset -eq 'Cloudflare') {'CL.FLARE'} else {$preset.ToUpperInvariant()}
    Assert-Dns ((Format-ZapretDnsMenuStatus (Get-ZapretDnsSnapshot $adapter)) -eq ($label+' | HTTPS')) 'The status did not follow the new DNS provider'
    Assert-Dns ([IO.File]::ReadAllText($backupPath) -ceq $saved) 'Changing providers overwrote the original backup'
}
Invoke-ZapretDnsChange $fixture $adapter ToggleHttps
$disabled=Get-ZapretDnsSnapshot $adapter
Assert-Dns ((Get-ZapretDnsConfiguration $disabled).Https -eq 'off') 'HTTPS toggle did not disable encryption'
Assert-Dns (@($disabled.Families | Where-Object { $_.Properties.Count }).Count -eq 0 -and $disabled.DohDefaultsKnown) 'Deleted zero-flag entries were not resolved through Windows defaults'
Invoke-ZapretDnsChange $fixture $adapter ToggleHttps
$script:dnsDropZeroProperties=$false;$script:dnsRetainInactiveTemplate=$true
Invoke-ZapretDnsChange $fixture $adapter ToggleHttps
$disabled=Get-ZapretDnsSnapshot $adapter
Assert-Dns ((Get-ZapretDnsConfiguration $disabled).Https -eq 'off' -and [bool]$disabled.Families[0].Properties[0].Template) 'An inactive retained template prevented disabling HTTPS'
$script:dnsDropZeroProperties=$true;$script:dnsRetainInactiveTemplate=$false
Invoke-ZapretDnsChange $fixture $adapter Automatic
$current=Get-ZapretDnsSnapshot $adapter
Assert-Dns (@($current.Families | Where-Object { $_.NameServer -or $_.ProfileNameServer -or $_.Properties.Count }).Count -eq 0) 'Automatic DNS did not clear static addresses and profile overrides'
Assert-Dns ((Format-ZapretDnsMenuStatus $current) -eq 'AUTO') 'Returning to automatic DNS did not restore the AUTO label'
Assert-Dns ([IO.File]::ReadAllText($backupPath) -ceq $saved) 'Automatic DNS overwrote the original backup'
Invoke-ZapretDnsChange $fixture $adapter Restore
Assert-ZapretDnsApplied $original (Get-ZapretDnsSnapshot $adapter);$checks++
Assert-Dns (-not [IO.File]::Exists($backupPath)) 'Successful restoration did not release the backup'

# Mixed static IPv4 + automatic IPv6, Wi-Fi profile override and custom DoH.
$script:dnsState[$adapter.InterfaceGuid+'/False']=[pscustomobject]@{
    IPv6=$false;Version=3;NameServer='192.0.2.53,192.0.2.54';ProfileNameServer='198.51.100.53'
    Properties=@([pscustomobject]@{Index=0;Template='https://resolver.example/dns-query';Flags=6},[pscustomobject]@{Index=1;Template=$null;Flags=17})
    ProfileProperties=@([pscustomobject]@{Index=0;Template=$null;Flags=1})
}
$custom=Get-ZapretDnsSnapshot $adapter
Assert-Dns ((Format-ZapretDnsMenuStatus $custom) -eq 'CUSTOM | HTTPS') 'Custom DNS was mislabeled as a managed preset'
Invoke-ZapretDnsChange $fixture $adapter Preset Cloudflare
Assert-Dns (-not (Get-ZapretDnsSnapshot $adapter).Families[0].ProfileNameServer) 'Wi-Fi profile DNS shadowed the selected preset'
Invoke-ZapretDnsChange $fixture $adapter Restore
Assert-ZapretDnsApplied $custom (Get-ZapretDnsSnapshot $adapter);$checks++

Invoke-ZapretDnsChange $fixture $adapter Preset Google
Invoke-ZapretDnsChange $fixture $other Preset Google
if ((Get-ZapretDnsConfiguration (Get-ZapretDnsSnapshot $adapter)).Https -eq 'on') { Invoke-ZapretDnsChange $fixture $adapter ToggleHttps }
Invoke-ZapretDnsChange $fixture $adapter ToggleHttps
Assert-Dns ((Get-ZapretDnsConfiguration (Get-ZapretDnsSnapshot $other)).Https -eq 'off') 'HTTPS on one adapter changed another adapter using the same provider'
Invoke-ZapretDnsChange $fixture $other Restore
Assert-Dns ((Get-ZapretDnsConfiguration (Get-ZapretDnsSnapshot $adapter)).Https -eq 'on') 'Restoring another adapter disabled HTTPS'
$count=$script:dnsWrites.Count
$script:dnsProfile='different-network'
Assert-DnsRejected { Invoke-ZapretDnsChange $fixture $adapter Restore } 'Restoration overwrote a different network profile'
Assert-Dns ($script:dnsWrites.Count -eq $count) 'Network profile mismatch allowed native writes'
$script:dnsProfile='fixture-network'
Invoke-ZapretDnsChange $fixture $adapter Restore

# A partial dual-stack write, silent policy rejection and cache error all roll back.
foreach ($failure in @('write','ignored','cache')) {
    $before=Get-ZapretDnsSnapshot $adapter
    $script:dnsFailWrite=if ($failure -eq 'write') {$script:dnsWrites.Count+2} else {-1}
    $script:dnsIgnoreWrite=if ($failure -eq 'ignored') {$script:dnsWrites.Count+2} else {-1}
    $script:dnsFailCache=if ($failure -eq 'cache') {1} else {0}
    Assert-DnsRejected { Invoke-ZapretDnsChange $fixture $adapter Preset Quad9 } ('Failure was not reported: '+$failure)
    Assert-ZapretDnsApplied $before (Get-ZapretDnsSnapshot $adapter);$checks++
    Assert-Dns ([IO.File]::Exists($backupPath)) 'Failed change lost the original settings'
    Invoke-ZapretDnsChange $fixture $adapter Restore
}
$script:dnsFailWrite=-1;$script:dnsIgnoreWrite=-1

$before=Get-ZapretDnsSnapshot $adapter
$script:dnsFailWrites=@(($script:dnsWrites.Count+2),($script:dnsWrites.Count+3))
$failureMessage=''
try { Invoke-ZapretDnsChange $fixture $adapter Preset Quad9 } catch { $failureMessage=$_.Exception.Message }
Assert-Dns ($failureMessage.Contains('Rollback also failed') -and [IO.File]::Exists($backupPath)) 'Double failure lost recovery instructions or the original backup'
$script:dnsFailWrites=@()
Invoke-ZapretDnsChange $fixture $adapter Restore
Assert-ZapretDnsApplied $before (Get-ZapretDnsSnapshot $adapter);$checks++

$script:dnsBindings=@('ms_tcpip')
$beforeOtherFamily=Copy-DnsObject $script:dnsState[$adapter.InterfaceGuid+'/True']
Invoke-ZapretDnsChange $fixture $adapter Preset Google
Assert-Dns (@((Get-ZapretDnsSnapshot $adapter).Families).Count -eq 1) 'Disabled IPv6 was enabled by a DNS preset'
Assert-Dns ((ConvertTo-Json -InputObject $beforeOtherFamily -Depth 12) -ceq (ConvertTo-Json -InputObject $script:dnsState[$adapter.InterfaceGuid+'/True'] -Depth 12)) 'A preset overwrote a disabled protocol'
$script:dnsBindings=@('ms_tcpip','ms_tcpip6')
$count=$script:dnsWrites.Count
Assert-DnsRejected { Invoke-ZapretDnsChange $fixture $adapter Preset Quad9 } 'Changed bindings discarded uncaptured settings'
Assert-Dns ($script:dnsWrites.Count -eq $count) 'Changed bindings allowed writes without a complete backup'
Invoke-ZapretDnsChange $fixture $adapter Restore
Assert-Dns ((ConvertTo-Json -InputObject $beforeOtherFamily -Depth 12) -ceq (ConvertTo-Json -InputObject $script:dnsState[$adapter.InterfaceGuid+'/True'] -Depth 12)) 'Restoration overwrote a protocol enabled after the backup'

$blockedRoot=Join-Path $fixture 'blocked-backup'
[IO.Directory]::CreateDirectory((Join-Path $blockedRoot 'runtime')) | Out-Null
[IO.File]::WriteAllText((Join-Path $blockedRoot 'runtime\dns-settings'),'not a directory')
$count=$script:dnsWrites.Count
Assert-DnsRejected { Invoke-ZapretDnsChange $blockedRoot $adapter Preset Google } 'DNS changed without a writable backup location'
Assert-Dns ($script:dnsWrites.Count -eq $count) 'Backup failure allowed native writes'

# An invalid/moved/corrupt backup must stop before any native writes.
Invoke-ZapretDnsChange $fixture $adapter Preset Google
$valid=[IO.File]::ReadAllText($backupPath)
foreach ($mutation in @('machine','adapter','family','address','flags','json')) {
    $corrupt=ConvertFrom-Json $valid
    switch ($mutation) {
        machine {$corrupt.MachineId='different-machine'}
        adapter {$corrupt.AdapterId=$other.InterfaceGuid}
        family {$corrupt.Families[0].IPv6=$true}
        address {$corrupt.Families[0].NameServer='not-an-address'}
        flags {$corrupt.Families[0].Properties[0].Flags='invalid'}
    }
    $text=if ($mutation -eq 'json') {'{broken'} else {$corrupt | ConvertTo-Json -Depth 12}
    [IO.File]::WriteAllText($backupPath,$text)
    $count=$script:dnsWrites.Count
    Assert-DnsRejected { Invoke-ZapretDnsChange $fixture $adapter Restore } ('Invalid backup was accepted: '+$mutation)
    Assert-Dns ($script:dnsWrites.Count -eq $count) 'Invalid backup allowed a partial restoration'
}
[IO.File]::WriteAllText($backupPath,$valid)
Invoke-ZapretDnsChange $fixture $adapter Restore

$script:dnsBuild='19045'
Invoke-ZapretDnsChange $fixture $adapter Preset Google
$count=$script:dnsWrites.Count
Assert-DnsRejected { Invoke-ZapretDnsChange $fixture $adapter ToggleHttps } 'Windows 10 allowed HTTPS encryption'
Assert-Dns ($script:dnsWrites.Count -eq $count -and (Get-ZapretDnsConfiguration (Get-ZapretDnsSnapshot $adapter)).Https -eq 'unavailable') 'Windows 10 HTTPS refusal changed DNS'
Assert-Dns ((Format-ZapretDnsMenuStatus (Get-ZapretDnsSnapshot $adapter)) -eq 'GOOGLE | HTTPS N/A') 'Windows 10 encryption availability was mislabeled'
Invoke-ZapretDnsChange $fixture $adapter Restore
$script:dnsBuild='26200'

# Exercise the actual submenu with a queued keyboard: no mutation on open/back,
# and all six actions dispatch to the selected adapter.
. (Join-Path $sourceRoot 'utils\menu.ps1') -LibraryOnly
. (Join-Path $sourceRoot 'utils\dns-settings.ps1')
# Re-load only the UI function; keep native boundaries isolated below.
function Initialize-ZapretDnsNative {}
function Get-ZapretDnsAdapters { $script:dnsAdapters }
function Clear-ZapretMenu {}
function Wait-ZapretMenu {}
$script:dnsPrompts=[Collections.Generic.List[string]]::new()
function Read-ZapretMenuLine { param($Prompt); $script:dnsPrompts.Add($Prompt); if (-not $script:dnsAnswers.Count) {throw 'Unexpected DNS menu input'}; $script:dnsAnswers.Dequeue() }
function Invoke-ZapretMenuOperation { param($Component,$Action,$Body); & $Body }
$script:dnsActions=[Collections.Generic.List[object]]::new()
function Invoke-ZapretDnsChange { param($Root,$Adapter,$Action,$PresetName); $script:dnsActions.Add(@{Adapter=$Adapter.InterfaceGuid;Action=$Action;Preset=$PresetName}) }
function Get-ZapretDnsSnapshot { param($Adapter); if ($script:dnsReadFailure -and $Adapter.InterfaceGuid -eq $script:dnsAdapters[0].InterfaceGuid) {throw 'Injected DNS read failure'}; $script:uiSnapshot }
$script:dnsReadFailure=$false
$script:uiSnapshot=$original
$script:dnsAnswers=[Collections.Generic.Queue[string]]::new()
$script:dnsAnswers.Enqueue('0')
Show-ZapretDnsMenu 6>&1 | Out-Null
Assert-Dns ($script:dnsActions.Count -eq 0 -and $script:dnsPrompts.Count -eq 1 -and $script:dnsPrompts[0] -match '0-7') 'Opening DNS settings required an adapter selection or changed DNS'
$script:dnsAnswers.Enqueue('0')
$lines=@(Show-ZapretDnsMenu 6>&1 | ForEach-Object {[string]$_})
Assert-Dns ($script:dnsActions.Count -eq 0 -and [bool]($lines -match 'HTTPS \[off\]') -and [bool]($lines -match 'Сетевой адаптер: Fixture Wi-Fi') -and [bool]($lines -match '7\. Сменить сетевой адаптер')) 'Automatic adapter, HTTPS state or manual selection item was not displayed'
foreach ($answer in @('1','2','3','4','5','6','0')) {$script:dnsAnswers.Enqueue($answer)}
Show-ZapretDnsMenu 6>&1 | Out-Null
Assert-Dns (($script:dnsActions.Action -join ',') -ceq 'Preset,Preset,Preset,ToggleHttps,Automatic,Restore') 'DNS menu dispatch did not match the displayed actions'
Assert-Dns (($script:dnsActions.Preset -join ',') -ceq 'Google,Cloudflare,Quad9,,,') 'DNS provider selection was misnumbered'
Assert-Dns (@($script:dnsActions | Where-Object Adapter -ne $other.InterfaceGuid).Count -eq 0) 'DNS menu changed the wrong adapter'

$script:dnsActions.Clear()
foreach ($answer in @('7','1','1','2','0')) {$script:dnsAnswers.Enqueue($answer)}
Show-ZapretDnsMenu 6>&1 | Out-Null
Assert-Dns ($script:dnsActions.Count -eq 2 -and @($script:dnsActions | Where-Object Adapter -ne $script:dnsAdapters[0].InterfaceGuid).Count -eq 0) 'Manual adapter selection was ignored or did not persist in the submenu'
$script:dnsActions.Clear()
foreach ($answer in @('7','0','1','0')) {$script:dnsAnswers.Enqueue($answer)}
Show-ZapretDnsMenu 6>&1 | Out-Null
Assert-Dns ($script:dnsActions.Count -eq 1 -and $script:dnsActions[0].Adapter -eq $other.InterfaceGuid) 'Cancelling the adapter list discarded the automatic target'
$script:dnsActions.Clear()
foreach ($answer in @('7','999999999999','1','0')) {$script:dnsAnswers.Enqueue($answer)}
Show-ZapretDnsMenu 6>&1 | Out-Null
Assert-Dns ($script:dnsActions.Count -eq 1 -and $script:dnsActions[0].Adapter -eq $other.InterfaceGuid) 'Invalid adapter input changed the current target'
$script:dnsActions.Clear()
$script:dnsReadFailure=$true
foreach ($answer in @('7','1','1','7','2','1','0')) {$script:dnsAnswers.Enqueue($answer)}
Show-ZapretDnsMenu 6>&1 | Out-Null
Assert-Dns ($script:dnsActions.Count -eq 1 -and $script:dnsActions[0].Adapter -eq $other.InterfaceGuid) 'Unreadable adapter allowed changes or prevented selecting another adapter'
$script:dnsReadFailure=$false
$script:dnsActions.Clear()
foreach ($item in $script:dnsAdapters) {$item.Status='Disconnected'}
foreach ($answer in @('1','7','2','1','0')) {$script:dnsAnswers.Enqueue($answer)}
Show-ZapretDnsMenu 6>&1 | Out-Null
Assert-Dns ($script:dnsActions.Count -eq 1 -and $script:dnsActions[0].Adapter -eq $other.InterfaceGuid) 'No active connection prevented manual selection or changed DNS without a target'
foreach ($item in $script:dnsAdapters) {$item.Status='Up'}
$script:dnsRoutes[0].RouteMetric=0
$script:dnsActions.Clear()
foreach ($answer in @('1','0')) {$script:dnsAnswers.Enqueue($answer)}
Show-ZapretDnsMenu 6>&1 | Out-Null
Assert-Dns ($script:dnsActions[0].Adapter -eq $script:dnsAdapters[0].InterfaceGuid) 'Reopening DNS settings did not refresh the default connection'

# Dispatch the real main menu, replacing only external actions.
& {
    $script:mainDnsCalls=[Collections.Generic.List[string]]::new()
    function Show-ZapretMenuDnsSettings { $script:mainDnsCalls.Add('dns') }
    function Show-ZapretDiagnosticsMenu { $script:mainDnsCalls.Add('diagnostics') }
    function Update-ZapretMenuService {}
    function Invoke-ZapretMenuChild { param($File,$Arguments); $script:mainDnsCalls.Add($File) }
    function Start-Process { param($FilePath,$ArgumentList,$WindowStyle); if ($ArgumentList -like '*test-presets.ps1*') {$script:mainDnsCalls.Add('tests')} }
    foreach ($choice in 10..16) { Invoke-ZapretMenuAction $choice 6>&1 | Out-Null }
    Assert-Dns (($script:mainDnsCalls -join ',') -ceq 'dns,update-ipset.ps1,prepare-hosts.ps1,update-release.ps1,diagnostics,tests,clear-discord-cache.ps1') 'Renumbered main menu dispatched the wrong action'
    $modes=@{Game='off';IPSet='loaded';Voice='compatible';DiscordFakeLabel='current';GameFakeLabel='current';Update='disabled'}
    $text=@(Show-ZapretMenu ([pscustomobject]@{Preset='general';State='Stopped'}) $modes 'DISABLED' 6>&1 | ForEach-Object {[string]$_}) -join "`n"
    $numbers=@([regex]::Matches($text,'(?m)^\s+(\d+)\. ') | ForEach-Object {$_.Groups[1].Value}) -join ','
    Assert-Dns ($numbers -ceq '1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,0') 'Main menu numbers are not sequential'
    $label='CL.FLARE | HTTPS OFF'
    $rendered=@(Show-ZapretMenu ([pscustomobject]@{Preset='general';State='Stopped'}) $modes 'DISABLED' $label 6>&1 | ForEach-Object {[string]$_}) -join "`n"
    Assert-Dns ($rendered.Contains(('10. DNS Settings        ['+$label+']'))) 'Main menu did not render the current DNS status'
}

# Local observation caching must expire, refresh after submenu actions and
# report failures without claiming a stale preset is active.
& {
    $script:dnsMenuStatusCache=$null
    $script:dnsStatusQueries=0;$script:dnsNextStatus='GOOGLE | HTTPS'
    $script:dnsStatusThrows=$false
    function Get-ZapretDnsMenuStatus {
        $script:dnsStatusQueries++
        if ($script:dnsStatusThrows) { throw 'Injected DNS status error' }
        return $script:dnsNextStatus
    }
    Assert-Dns ((Get-ZapretMenuDnsStatus) -eq 'GOOGLE | HTTPS') 'Initial status query lost the provider'
    $null=Get-ZapretMenuDnsStatus
    Assert-Dns ($script:dnsStatusQueries -eq 1) 'Rapid navigation repeated the DNS query'
    $script:dnsMenuStatusCache.Timer=[pscustomobject]@{ElapsedMilliseconds=2000}
    $script:dnsNextStatus='CL.FLARE | HTTPS OFF'
    Assert-Dns ((Get-ZapretMenuDnsStatus) -eq 'CL.FLARE | HTTPS OFF' -and $script:dnsStatusQueries -eq 2) 'Expired status cache did not refresh'
    function Show-ZapretDnsMenu { $script:dnsNextStatus='AUTO' }
    Show-ZapretMenuDnsSettings
    Assert-Dns ((Get-ZapretMenuDnsStatus) -eq 'AUTO' -and $script:dnsStatusQueries -eq 3) 'Returning from DNS settings kept a stale status'
    function Show-ZapretDnsMenu { throw 'Injected DNS submenu error' }
    Assert-DnsRejected { Show-ZapretMenuDnsSettings } 'Submenu failure was swallowed'
    $script:dnsStatusThrows=$true
    Assert-Dns ((Get-ZapretMenuDnsStatus) -eq 'UNKNOWN') 'Status failure displayed a previously active DNS preset'
}

$probe=Join-Path $fixture 'menu-input-probe.ps1'
[IO.File]::WriteAllText($probe,@'
param($SourceRoot,$Root)
. (Join-Path $SourceRoot 'utils\menu-input.ps1')
'CHOICE:'+(Read-ReleaseMenuChoice $Root)
'@,[Text.UTF8Encoding]::new($true))
foreach ($case in @(@{Input='10';Expected=10},@{Input='16';Expected=16},@{Input='17';Expected=255},@{Input='111';Expected=111},@{Input='0';Expected=0})) {
    $output=$case.Input | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $probe -SourceRoot $sourceRoot -Root $fixture
    # Use the production input function, with no update cache in the test root.
    Assert-Dns ($LASTEXITCODE -eq 0 -and [bool]($output -match ('CHOICE:'+$case.Expected+'$'))) 'Main menu input rejected DNS or accepted an invalid option'
}
Write-Host "[OK] DNS settings: $checks checks; $liveCount live adapters read only; $skippedLiveCount service/non-IP adapters skipped. System DNS was not changed."
