# Offline settings, migration, exclusion and diagnostic regressions. No SCM writes.
$ErrorActionPreference='Stop'
$source=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$fixture=Join-Path $source ('runtime\feature-tests-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixture) | Out-Null
foreach ($directory in @('utils','presets','lists')) { Copy-Item -LiteralPath (Join-Path $source $directory) -Destination $fixture -Recurse }
[IO.Directory]::CreateDirectory((Join-Path $fixture 'bin')) | Out-Null
Copy-Item -LiteralPath (Join-Path $source 'bin\fake') -Destination (Join-Path $fixture 'bin') -Recurse
. (Join-Path $fixture 'utils\session-log.ps1')
. (Join-Path $fixture 'utils\menu-settings.ps1')
. (Join-Path $fixture 'utils\update-release-state.ps1')
. (Join-Path $fixture 'utils\preset-catalog.ps1')
. (Join-Path $fixture 'utils\environment-diagnostics.ps1')
. (Join-Path $fixture 'utils\network-checks.ps1')
$checks=0
function Assert-Feature([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message }; $script:checks++ }
function Assert-Rejected([scriptblock]$Body) { $rejected=$false; try { & $Body | Out-Null } catch { $rejected=$true }; Assert-Feature $rejected 'Invalid setting was accepted.' }
Assert-Feature ((ConvertTo-ZapretPortRange '00102, 1024-1934,1936-65535') -ceq '102,1024-1934,1936-65535') 'Port normalization failed.'
foreach ($value in @('0','65536','10-1','1,,2','1;whoami','1-65536','-1','1,','1-2-3')) { Assert-Rejected { ConvertTo-ZapretPortRange $value } }
Set-ReleaseMenuSetting $fixture 'game_tcp.ports' '1024-1934,1936-65535'
Set-ReleaseMenuSetting $fixture 'game_udp.ports' '27015,30000-30100'
$choice=@(Get-ZapretFakeChoices $fixture | Where-Object Name -eq 'stun2.bin')[0]
$fake=Import-ZapretFake $fixture $choice
Set-ReleaseMenuSetting $fixture 'discord_fake.mode' $fake
Set-ReleaseMenuSetting $fixture 'game_fake.mode' $fake
Assert-Feature ((Get-FileHash $choice.Path).Hash -eq (Get-FileHash (Get-ZapretFakePath $fixture $fake Discord)).Hash) 'Import changed the selected bytes.'
$output=Join-Path $fixture 'runtime\ports.txt'
& (Join-Path $fixture 'utils\render-config.ps1') -Preset general -Output $output -GameMode all -VoiceMode compatible -IPSetMode loaded | Out-Null
$text=[IO.File]::ReadAllText($output)
Assert-Feature ($text.Contains('--filter-tcp=1024-1934,1936-65535') -and $text.Contains('--filter-udp=27015,30000-30100')) 'Game port ranges were not applied.'
Assert-Feature ($text.Contains('--wf-udp-out=443,19294-19344,50000-50100,27015,30000-30100')) 'UDP capture ignores the selected ports.'
$options=Get-ReleaseConfigOptions $output
Assert-Feature ($options.GameTcpPorts -ceq '1024-1934,1936-65535' -and $options.GameUdpPorts -ceq '27015,30000-30100' -and $options.DiscordFake -ceq $fake) 'Applied options were lost during migration.'
# Stored menu settings can differ from the applied configuration.
Set-ReleaseMenuSetting $fixture 'game_tcp.ports' '1234'
& (Join-Path $fixture 'utils\render-config.ps1') @options -Output ($output+'.migrated') | Out-Null
Assert-Feature ([IO.File]::ReadAllText($output) -ceq [IO.File]::ReadAllText($output+'.migrated')) 'Migration applied pending menu settings.'
$customPath=Get-ZapretFakePath $fixture $fake Discord
[IO.File]::WriteAllBytes($customPath,[byte[]]@(1,2,3))
Assert-Rejected { Get-ZapretFakePath $fixture $fake Discord }
$restored=Import-ZapretFake $fixture $choice
Assert-Feature ($restored -ceq $fake -and (Get-FileHash -LiteralPath (Get-ZapretFakePath $fixture $fake Discord)).Hash -eq $choice.Hash) 'Reselecting the source did not repair a changed custom fake.'
Set-ReleaseMenuSetting $fixture fake-defaults current
foreach ($preset in $publicPresets) {
    & (Join-Path $fixture 'utils\render-config.ps1') -Preset $preset -Output $output -GameMode off -IPSetMode loaded | Out-Null
    $content=[IO.File]::ReadAllText($output)
    $blocks=[regex]::Split($content,'(?m)^--new\r?$')
    foreach ($block in $blocks | Where-Object { $_ -match '# IPSet fallback (UDP|TCP)' }) {
        Assert-Feature ($block -match '--hostlist-exclude=.*list-exclude-user.txt' -and $block -match '--hostlist-exclude=.*list-exclude.txt') "IPSet exclusions missing: $preset"
    }
}
$snapshot=@{Processes=@('AdguardSvc.exe');Services=@(@{Name='EPWD';DisplayName='Check Point'},@{Name='IntelConnectivityNetworkService';DisplayName='Intel Connectivity Network Service'});Hosts="127.0.0.1 localhost`n1.2.3.4 youtube.com # note";DoH=$false;OneDrive=@($fixture)}
$findings=@(Get-ZapretEnvironmentDiagnostics $fixture $snapshot)
foreach ($code in @('AdGuard','CheckPoint','IntelConnectivity','YouTubeHosts','SecureDNS','OneDrivePath')) { Assert-Feature ($code -in $findings.Code) "Missing environment check: $code" }
$snapshot.Hosts='# 1.2.3.4 youtube.com';$snapshot.DoH=$true;$snapshot.OneDrive=@();$snapshot.Processes=@();$snapshot.Services=@()
Assert-Feature (@(Get-ZapretEnvironmentDiagnostics $fixture $snapshot).Count -eq 0) 'Inactive/commented settings generated a false warning.'
Assert-Feature ((Get-ZapretTransferStatus 48 'unknown option' 0 0 $true) -eq 'UNSUPPORTED') 'Unsupported curl options are counted as failures.'
Assert-Feature ((Get-ZapretTransferStatus 35 'SSL connect error' 0 0 $true) -eq 'TLS_ERROR') 'TLS handshake failure was hidden as unsupported.'
$event=@{schemaVersion=1;sessionId=('a'*32);operationId=('b'*32);component='renderer';action='Render';stage='settings';result='ok';code='None';utc=[datetime]::UtcNow;details=@{discordFake=('custom:'+('c'*64));oldValue='1234,4000-4010';setting='game_tcp.ports'}}
$safe=ConvertTo-ZapretSafeEvent $event
$shared=$safe | ConvertTo-Json -Depth 8
Assert-Feature ($safe.details.discordFake -ceq 'custom' -and -not $shared.Contains(('c'*64)) -and -not $shared.Contains('4000-4010')) 'Custom file identity or game ports leaked into sendable logs.'
Write-Host "Feature regressions passed: $checks checks; 24 public presets." -ForegroundColor Green
