[CmdletBinding()]
param([switch]$NativeEngine)
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'issue-5-gw2\gw2-test.ps1') -FunctionsOnly
$script:root=$repo
$testPath=Join-Path $repo ('runtime\gw2-kit-tests-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testPath) | Out-Null
$script:count=0
function Assert-Test([bool]$Value,[string]$Name) {
    if (-not $Value) { throw "FAIL: $Name" }
    $script:count++; Write-Host "PASS: $Name"
}
function Assert-Throws([scriptblock]$Action,[string]$Name) {
    $thrown=$false
    try { & $Action } catch { $thrown=$true }
    Assert-Test $thrown $Name
}
Assert-GW2Components
Assert-Test $true 'Actual component preflight works in Windows PowerShell 5.1'
$atomicPath=Join-Path $testPath 'atomic-state.json'
Write-GW2Json $atomicPath @{value='before'}
Write-GW2Json $atomicPath @{value='after'}
Assert-Test ((Get-Content -LiteralPath $atomicPath -Raw | ConvertFrom-Json).value -eq 'after') 'Recovery JSON atomically replaces previous state'
$atomicLock=[IO.File]::Open($atomicPath,'Open','Read','None')
try { Assert-Throws { Write-GW2Json $atomicPath @{value='partial'} } 'Locked recovery state fails without truncating original' }
finally { $atomicLock.Dispose() }
Assert-Test ((Get-Content -LiteralPath $atomicPath -Raw | ConvertFrom-Json).value -eq 'after') 'Old recovery record remains valid after failed write'
Assert-Test (@(Get-ChildItem -LiteralPath $testPath -Filter '*.tmp').Count -eq 0) 'Failed atomic update removes its temporary file'
$ipset=Join-Path $testPath 'ipset.txt'
[IO.File]::WriteAllLines($ipset,@('# fixture','8.8.8.0/24','1.1.1.1','2001:4860::/32','2606:4700::1111'))
$set=Read-GW2IPSet @($ipset)
Assert-Test (Test-GW2IPSet $set '8.8.8.8') 'IPv4 CIDR includes host'
Assert-Test (-not (Test-GW2IPSet $set '8.8.9.8')) 'IPv4 adjacent subnet excluded'
Assert-Test (Test-GW2IPSet $set '1.1.1.1') 'IPv4 host entry'
Assert-Test (-not (Test-GW2IPSet $set '1.1.1.2')) 'IPv4 host does not widen'
Assert-Test (Test-GW2IPSet $set '2001:4860:4860::8888') 'IPv6 CIDR includes host'
Assert-Test (-not (Test-GW2IPSet $set '2001:4861::8888')) 'IPv6 adjacent prefix excluded'
Assert-Test (Test-GW2IPSet $set '2606:4700::1111') 'IPv6 exact host'
Assert-Test (Test-GW2IPSet $set '::ffff:8.8.8.8') 'IPv4 mapped connection matches IPv4 IPSet'
Assert-Throws { Get-GW2NetworkKey ([Net.IPAddress]::Parse('8.8.8.8')) 33 } 'Invalid IPv4 prefix rejected'
Assert-Throws { Get-GW2NetworkKey ([Net.IPAddress]::Parse('::1')) 129 } 'Invalid IPv6 prefix rejected'
Assert-Throws { ConvertTo-GW2Address 'not-an-address' } 'Invalid address rejected'
foreach ($address in @('127.0.0.1','10.0.1.2','192.168.1.2','172.31.1.2','169.254.1.2','100.64.1.2','::1','fd00::1','fe80::1','::ffff:192.168.1.2')) {
    Assert-Test (-not (Test-GW2PublicAddress $address)) ('Do not export local/proxy address '+$address)
}
Assert-Test (Test-GW2PublicAddress '8.8.8.8') 'Public IPv4 retained'
Assert-Test (Test-GW2PublicAddress '2606:4700::1111') 'Global IPv6 retained'
$targetPath=Join-Path $testPath 'observed-targets.txt'
[IO.File]::WriteAllText($targetPath,"8.8.8.8`r`n")
$loadedPath=Join-Path $repo 'lists\ipset-all.txt'
$currentLoadedConfig=New-GW2Config $repo $loadedPath @(80,443,6112)
$observed=New-GW2Config $repo $targetPath @(80,443,6112)
$normalizedLoaded=$currentLoadedConfig -replace '(?m)^--ipset=.*$','--ipset=TEST'
$normalizedObserved=$observed -replace '(?m)^--ipset=.*$','--ipset=TEST'
Assert-Test ($normalizedLoaded -ceq $normalizedObserved) 'A/B profiles differ only by included IPSet'
Assert-Test ($currentLoadedConfig -match '(?m)^--wf-tcp-out=80,443,6112\r?$') 'Interception limited to test TCP ports'
Assert-Test ($currentLoadedConfig -notmatch 'wf-udp|filter-udp|IPSetMode|--ipset=any|--hostlist') 'No UDP or broad any-address test'
$sections=Get-GW2Sections (Join-Path $repo 'presets\ALT11.txt.in')
Assert-Test ($currentLoadedConfig.EndsWith(($sections.GAME_TCP_ACTIONS -join "`r`n")+"`r`n")) 'Installed ALT11 game actions preserved'
Assert-Test ($currentLoadedConfig -match '--ipset-exclude=') 'Existing exclusions preserved'
Assert-Test ($currentLoadedConfig -notmatch '@\.\.|:@fake/') 'All Lua and fake paths resolved'
Assert-Throws { New-GW2Config $repo $targetPath @(0,6112) } 'Invalid interception port rejected'
$spaceRoot=Join-Path $testPath 'folder with spaces'
[IO.Directory]::CreateDirectory((Join-Path $spaceRoot 'presets')) | Out-Null
Copy-Item -LiteralPath (Join-Path $repo 'presets\ALT11.txt.in') -Destination (Join-Path $spaceRoot 'presets\ALT11.txt.in')
Copy-Item -LiteralPath (Join-Path $repo 'presets\_base.txt.in') -Destination (Join-Path $spaceRoot 'presets\_base.txt.in')
$spaced=New-GW2Config $spaceRoot $targetPath @(443,6112)
Assert-Test ($spaced.Contains('--lua-init=@"'+$spaceRoot.Replace('\','/')+'/lua/zapret-lib.lua"')) 'Paths containing spaces quoted'
$dollarRoot=Join-Path $testPath 'folder $1 with spaces'
[IO.Directory]::CreateDirectory((Join-Path $dollarRoot 'presets')) | Out-Null
Copy-Item -LiteralPath (Join-Path $repo 'presets\ALT11.txt.in') -Destination (Join-Path $dollarRoot 'presets\ALT11.txt.in')
Copy-Item -LiteralPath (Join-Path $repo 'presets\_base.txt.in') -Destination (Join-Path $dollarRoot 'presets\_base.txt.in')
$dollarConfig=New-GW2Config $dollarRoot $targetPath @(443,6112)
Assert-Test ($dollarConfig.Contains('=@"'+$dollarRoot.Replace('\','/')+'/lua/zapret-next.lua"')) 'Dollar sign preserved in preset Lua path'
Assert-Test ($dollarConfig.Contains(':@"'+$dollarRoot.Replace('\','/')+'/bin/fake/')) 'Dollar sign preserved in fake payload path'
$legacyRoot=Join-Path $testPath 'published-0.4.5'
[IO.Directory]::CreateDirectory((Join-Path $legacyRoot 'presets')) | Out-Null
$legacyPreset=@(& git -C $repo show 'v0.4.5:presets/ALT11.txt.in')
if ($LASTEXITCODE -ne 0) { throw 'Cannot read published v0.4.5 ALT11 from Git.' }
$legacyBase=@(& git -C $repo show 'v0.4.5:presets/_base.txt.in')
if ($LASTEXITCODE -ne 0) { throw 'Cannot read published v0.4.5 base template from Git.' }
[IO.File]::WriteAllLines((Join-Path $legacyRoot 'presets\ALT11.txt.in'),$legacyPreset,[Text.Encoding]::ASCII)
[IO.File]::WriteAllLines((Join-Path $legacyRoot 'presets\_base.txt.in'),$legacyBase,[Text.Encoding]::ASCII)
$legacyLoaded=New-GW2Config $legacyRoot $loadedPath @(80,443,6112)
$legacyObserved=New-GW2Config $legacyRoot $targetPath @(80,443,6112)
Assert-Test ($legacyLoaded -match '(?m)^--blob=tls_max:') 'Published 0.4.5 ALT11 inherits its required tls_max blob'
foreach ($config in @($currentLoadedConfig,$legacyLoaded)) {
    $defined=@([regex]::Matches($config,'(?m)^--blob=([A-Za-z0-9_]+):') | ForEach-Object { $_.Groups[1].Value })
    $references=@([regex]::Matches($config,'(?<!-)(?:blob|seqovl_pattern)=([A-Za-z0-9_]+)') | ForEach-Object { $_.Groups[1].Value })
    Assert-Test (@($references | Where-Object { $_ -notin $defined }).Count -eq 0) 'Every Lua payload reference has a declared blob'
}
$script:events=[Collections.Generic.List[string]]::new()
Invoke-GW2WithRestore { $script:events.Add('body') } { $script:events.Add('stop') } { $script:events.Add('restore') }
Assert-Test (($script:events -join ',') -eq 'body,stop,restore') 'Normal cleanup precedes service restoration'
$script:events.Clear()
Assert-Throws { Invoke-GW2WithRestore { throw [OperationCanceledException]::new() } { $script:events.Add('stop') } { $script:events.Add('restore') } } 'Cancellation propagated'
Assert-Test (($script:events -join ',') -eq 'stop,restore') 'Cancellation restores original service'
$script:events.Clear()
Assert-Throws { Invoke-GW2WithRestore { throw 'injected failure' } { $script:events.Add('stop') } { $script:events.Add('restore') } } 'Body failure propagated'
Assert-Test (($script:events -join ',') -eq 'stop,restore') 'Failure restores original service'
$script:events.Clear()
Assert-Throws { Invoke-GW2WithRestore {} { throw 'engine still running' } { $script:events.Add('restore') } } 'Cleanup failure propagated'
Assert-Test ($script:events.Count -eq 0) 'Do not restore service while test engine remains running'
$fixture=Join-Path $testPath 'settings'
[IO.Directory]::CreateDirectory((Join-Path $fixture 'utils')) | Out-Null
[IO.Directory]::CreateDirectory((Join-Path $fixture 'lists')) | Out-Null
[IO.File]::WriteAllText((Join-Path $fixture 'utils\game_filter.mode'),'off')
[IO.File]::WriteAllText((Join-Path $fixture 'lists\ipset-all.txt'),'8.8.8.8')
$before=Get-GW2SettingsHashes $fixture
Assert-Test (Test-GW2HashesEqual $before (Get-GW2SettingsHashes $fixture)) 'Unchanged settings detected'
[IO.File]::WriteAllText((Join-Path $fixture 'utils\game_filter.mode'),'tcp')
Assert-Test (-not (Test-GW2HashesEqual $before (Get-GW2SettingsHashes $fixture))) 'Changed mode detected'
[IO.File]::WriteAllText((Join-Path $fixture 'utils\game_filter.mode'),'off')
[IO.File]::WriteAllText((Join-Path $fixture 'lists\new-user.txt'),'private-list')
Assert-Test (-not (Test-GW2HashesEqual $before (Get-GW2SettingsHashes $fixture))) 'Added user list detected'
$originalStartOwned=${function:Start-GW2OwnedProcess}
$originalStartTest=${function:Start-GW2TestEngine}
$script:loaded=$set
$script:excluded=Read-GW2IPSet @()
function Get-Process { param($Name,$Id,$ErrorAction) return [pscustomobject]@{Id=1234} }
function Get-NetTCPConnection {
    param($ErrorAction)
    return @(
        [pscustomobject]@{OwningProcess=1234;RemoteAddress='8.8.8.8';RemotePort=6112;State='SynSent'},
        [pscustomobject]@{OwningProcess=1234;RemoteAddress='192.168.1.123';RemotePort=12345;State='Established'},
        [pscustomobject]@{OwningProcess=9999;RemoteAddress='9.9.9.9';RemotePort=443;State='Established'})
}
function Read-Host { param($Prompt) return '' }
function Read-GW2Outcome { Start-Sleep -Milliseconds 1500; return [pscustomobject]@{outcome='same-error';errorCode='58:11:5:512'} }
$ProgressPreference='SilentlyContinue'
$captured=Measure-GW2Attempt 'fixture' 'Capture fixture' -Seconds 1 -Ports @(6112)
Assert-Test ($captured.endpoints.Count -eq 1 -and $captured.endpoints[0].remoteIP -eq '8.8.8.8') 'Capture excludes other processes and private endpoints'
Assert-Test ($captured.nonPublicConnectionSamples -gt 0) 'Private connections counted without exporting address'
Assert-Test ($captured.captureSeconds -eq 1) 'Time spent entering outcome excluded from capture duration'
Assert-Test ($captured.endpoints[0].inLoadedIPSet -and $captured.endpoints[0].testPortCaptured) 'Captured endpoint is annotated with IPSet and interception'
$script:runPath=Join-Path $testPath 'export'
[IO.Directory]::CreateDirectory((Join-Path $script:runPath 'local')) | Out-Null
[IO.File]::WriteAllText((Join-Path $script:runPath 'local\raw.txt'),'SECRET_LOCAL_CANARY C:\Users\PrivateName\data 192.168.1.123')
$report=[ordered]@{schema='zapret2-next.issue-5-gw2';schemaVersion=1;status='completed';client='ArenaNet';bundleVersion='0.4.5';settingsPreserved=$true;serviceRestored=$true;failureStage='';attempts=@($captured)}
Save-GW2Report $report
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive=[IO.Compression.ZipFile]::OpenRead($script:runPath+'.zip')
try {
    Assert-Test (($archive.Entries.FullName | Sort-Object) -join ',' -eq 'connections.csv,REPORT.txt,results.json') 'Export contains only three approved files'
    $joined=''
    foreach ($entry in $archive.Entries) {
        $reader=[IO.StreamReader]::new($entry.Open())
        try { $joined+=$reader.ReadToEnd() } finally { $reader.Dispose() }
    }
    Assert-Test ($joined -notmatch 'SECRET_LOCAL_CANARY|PrivateName|192\.168\.1\.123') 'Local raw data excluded from export'
} finally { $archive.Dispose() }

$script:statePath=Join-Path $testPath 'validation-state.json'
$script:state=[ordered]@{engine=$null;wasRunning=$true;restoreNeeded=$true}
function Start-GW2OwnedProcess {
    param($Config,$Stdout,$Stderr)
    $script:engine=[pscustomobject]@{HasExited=$false}
    $script:engine | Add-Member ScriptMethod WaitForExit { param($Timeout) if (-not $this.HasExited) { throw [OperationCanceledException]::new() }; return $true }
    $script:engine | Add-Member ScriptMethod Kill { $this.HasExited=$true; $script:events.Add('kill-validation') }
    $script:engine | Add-Member ScriptMethod Dispose { $script:events.Add('dispose-validation') }
    $script:state.engine=@{config=$Config;id=1;startTicks='0'}
}
$script:events.Clear()
Assert-Throws { Invoke-GW2WithRestore { Start-GW2TestEngine 'cancel-fixture' $loadedPath @(6112) } { Stop-GW2TestEngine } { $script:events.Add('restore-original') } } 'Cancellation during native validation propagated'
Assert-Test (($script:events -join ',') -eq 'kill-validation,dispose-validation,restore-original') 'Interrupted validator killed before restoring service'
Assert-Test ($null -eq $script:engine -and $null -eq $script:state.engine) 'Validator recovery identity cleared only after cleanup'

if ($NativeEngine) {
    [IO.Directory]::CreateDirectory((Join-Path $legacyRoot 'bin\fake')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $legacyRoot 'lua')) | Out-Null
    foreach ($name in @('tls_clienthello_max_ru.bin','tls_clienthello_www_google_com.bin','quic_initial_www_google_com.bin','stun.bin','http_iana_org.bin','zero_512.bin','stun2.bin')) {
        Copy-Item -LiteralPath (Join-Path $repo ('bin\fake\'+$name)) -Destination (Join-Path $legacyRoot ('bin\fake\'+$name))
    }
    foreach ($name in @('zapret-lib.lua','zapret-antidpi.lua','zapret-auto.lua','zapret-next.lua')) { Copy-Item -LiteralPath (Join-Path $repo ('lua\'+$name)) -Destination (Join-Path $legacyRoot ('lua\'+$name)) }
    foreach ($entry in @(@('loaded',$currentLoadedConfig),@('observed',$observed),@('published-loaded',$legacyLoaded),@('published-observed',$legacyObserved))) {
        $config=Join-Path $testPath ($entry[0]+'.native.txt')
        [IO.File]::WriteAllText($config,($entry[1]+"--intercept=0`r`n--wf-dup-check=0`r`n--dry-run`r`n"),[Text.UTF8Encoding]::new($false))
        $stdout=Join-Path $testPath ($entry[0]+'.stdout')
        $stderr=Join-Path $testPath ($entry[0]+'.stderr')
        $previousCompatibility=$env:__COMPAT_LAYER
        try {
            # Match smoke-presets.py: these dry-runs disable interception and do not need UAC.
            $env:__COMPAT_LAYER='RunAsInvoker'
            $process=Start-Process (Join-Path $repo 'bin\winws2.exe') -ArgumentList ('@"'+$config+'"') -WorkingDirectory (Join-Path $repo 'bin') -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
        } finally { $env:__COMPAT_LAYER=$previousCompatibility }
        try {
            $null=$process.Handle
            if (-not $process.WaitForExit(30000)) { $process.Kill(); $process.WaitForExit(); throw 'Native dry-run timed out.' }
            $process.WaitForExit()
            Assert-Test ([bool](Select-String -LiteralPath $stdout -Pattern '^command line parameters verified$' -Quiet)) ('Native engine accepts '+$entry[0]+' profile')
        } finally { $process.Dispose() }
    }
}

# Mock SCM/process reads: these tests never change an actual Windows service.
$script:fakeService=[pscustomobject]@{Name='winws2';State='Running';ProcessId=123;PathName='"'+(Join-Path $repo 'bin\winws2.exe')+'" @"'+(Join-Path $repo 'runtime\service.txt')+'"'}
function Get-CimInstance { param($ClassName,$Filter) return $script:fakeService }
Assert-Test ($null -ne (Get-GW2Service)) 'Owned service accepted'
$script:fakeService.PathName='"C:\foreign\bin\winws2.exe" @"C:\foreign\runtime\service.txt"'
Assert-Throws { Get-GW2Service } 'Foreign service rejected'
$script:fakeService=[pscustomobject]@{Name='zapret';State='Running'}
Assert-Throws { Get-GW2Service } 'Active legacy service rejected'
function Assert-GW2NoManualEngine {}
function Get-GW2Service { return $script:fakeService }
function Save-GW2State {}
function Stop-Service { param($Name) $script:events.Add('stop-original'); $script:fakeService.State='Stopped' }
function Start-Service { param($Name) $script:events.Add('start-original'); $script:fakeService.State='Running' }
function Get-Service {
    param($Name)
    $value=[pscustomobject]@{Status=$script:fakeService.State}
    $value | Add-Member -MemberType ScriptMethod -Name WaitForStatus -Value { param($Status,$Timeout) }
    return $value
}
function Start-Sleep { param($Seconds,$Milliseconds) }
$script:fakeService=[pscustomobject]@{State='Running'}
$script:state=[ordered]@{wasRunning=$true;restoreNeeded=$false;engine=$null}
$script:events.Clear()
Stop-GW2OriginalService
Assert-Test ($script:state.restoreNeeded -and $script:fakeService.State -eq 'Stopped') 'Recovery flag set before original service stop'
Restore-GW2OriginalService
Assert-Test (-not $script:state.restoreNeeded -and ($script:events -join ',') -eq 'stop-original,start-original') 'Running service restored'
$script:fakeService.State='Stopped'; $script:state.wasRunning=$false; $script:events.Clear()
Stop-GW2OriginalService; Restore-GW2OriginalService
Assert-Test ($script:events.Count -eq 0 -and $script:fakeService.State -eq 'Stopped') 'Originally stopped service stays stopped'
$script:statePath=Join-Path $testPath 'recovery.json'
$script:fakeService.State='Stopped'
Write-GW2Json $script:statePath @{schema='zapret2-next.gw2-recovery-v1';wasRunning=$true;restoreNeeded=$true;engine=$null}
$script:events.Clear()
Restore-GW2InterruptedRun
Assert-Test (-not [IO.File]::Exists($script:statePath) -and $script:fakeService.State -eq 'Running') 'Interrupted run recovery restarts only original service and removes marker'
Write-GW2Json $script:statePath @{schema='foreign-schema';wasRunning=$true;restoreNeeded=$true;engine=$null}
Assert-Throws { Restore-GW2InterruptedRun } 'Unknown recovery schema rejected'
$recoveryConfig=Join-Path $PSScriptRoot 'issue-5-gw2\results\fixture\test.txt'
Write-GW2Json $script:statePath @{schema='zapret2-next.gw2-recovery-v1';wasRunning=$true;restoreNeeded=$true;engine=@{id=123;startTicks='0';config='C:\foreign\test.txt'}}
Assert-Throws { Restore-GW2InterruptedRun } 'Recovery rejects config outside the test folder'
function Get-Process {
    param($Id,$ErrorAction)
    return [pscustomobject]@{ Handle=1; StartTime=[DateTime]::UtcNow }
}
Write-GW2Json $script:statePath @{schema='zapret2-next.gw2-recovery-v1';wasRunning=$true;restoreNeeded=$true;engine=@{id=123;startTicks='0';config=$recoveryConfig}}
Assert-Throws { Restore-GW2InterruptedRun } 'Recovery refuses reused process ID'
Assert-Test ([IO.File]::Exists($script:statePath)) 'Failed recovery keeps marker for investigation'

$script:state=[ordered]@{engine=$null;wasRunning=$true;restoreNeeded=$true}
$script:fakeService.State='Running'
Assert-Throws { & $originalStartOwned (Join-Path $testPath 'test.txt') (Join-Path $testPath 'out') (Join-Path $testPath 'err') } 'Running original service blocks launching a second engine'
Assert-Test ($null -eq $script:state.engine) 'Blocked launch does not write pending process identity'
Write-GW2Json $script:statePath @{schema='zapret2-next.gw2-recovery-v1';wasRunning='false';restoreNeeded=$true;engine=$null}
Assert-Throws { Restore-GW2InterruptedRun } 'Corrupt recovery boolean rejected instead of starting service'
$script:fakeService.State='Stopped'
$script:fakeRecoveryProcess=[pscustomobject]@{Id=456;Handle=1;StartTime=[DateTime]::UtcNow;HasExited=$false}
$script:fakeRecoveryProcess | Add-Member ScriptMethod Kill { $this.HasExited=$true; $script:events.Add('kill-pending') }
$script:fakeRecoveryProcess | Add-Member ScriptMethod WaitForExit { param($Timeout) return $this.HasExited }
$script:fakeRecoveryProcess | Add-Member ScriptMethod Dispose { $script:events.Add('dispose-pending') }
$script:fakeRecoveryImage=[pscustomobject]@{ProcessId=456;ExecutablePath=(Join-Path $repo 'bin\winws2.exe');CommandLine=('"'+(Join-Path $repo 'bin\winws2.exe')+'" @"'+$recoveryConfig+'"')}
function Get-CimInstance { param($ClassName,$Filter) return $script:fakeRecoveryImage }
function Get-Process { param($Id,$ErrorAction) if ($Id -eq 456) { return $script:fakeRecoveryProcess } }
Write-GW2Json $script:statePath @{schema='zapret2-next.gw2-recovery-v1';wasRunning=$true;restoreNeeded=$true;engine=@{id=0;notBeforeUtc=[DateTime]::UtcNow.ToString('o');config=$recoveryConfig}}
$script:events.Clear()
Restore-GW2InterruptedRun
Assert-Test (($script:events -join ',') -eq 'kill-pending,dispose-pending,start-original') 'Interrupted launch between process creation and PID save is recovered'
Assert-Test (-not [IO.File]::Exists($script:statePath)) 'Pending launch recovery removes marker only after restoration'
$script:fakeRecoveryProcess.HasExited=$false
$script:fakeRecoveryProcess.StartTime=[DateTime]::UtcNow.AddHours(-1)
Write-GW2Json $script:statePath @{schema='zapret2-next.gw2-recovery-v1';wasRunning=$true;restoreNeeded=$true;engine=@{id=0;notBeforeUtc=[DateTime]::UtcNow.ToString('o');config=$recoveryConfig}}
$script:events.Clear()
Assert-Throws { Restore-GW2InterruptedRun } 'Pending launch recovery refuses an older matching process'
Assert-Test ($script:events.Count -eq 0) 'Older matching process left running'

# Exercise all four phases without SCM, network requests, native launches or input.
$script:planEmpty=$false; $script:planCancel=''; $script:planEngineCrash=$false
$script:planStarts=@()
function Wait-GW2Closed { $script:events.Add('wait-closed') }
function Stop-GW2OriginalService { $script:events.Add('pause-original') }
function Stop-GW2TestEngine { $script:events.Add('stop-test') }
function Restore-GW2OriginalService { $script:events.Add('restore-original') }
function Start-GW2TestEngine {
    param($Name,$IPSetPath,$Ports)
    $script:events.Add('start-'+$Name)
    $script:planStarts+=@{name=$Name;path=$IPSetPath;ports=($Ports -join ',')}
}
function Measure-GW2Attempt {
    param($Name,$Label,$Targets,$Ports)
    if ($script:planCancel -eq $Name) { throw [OperationCanceledException]::new() }
    $script:events.Add('measure-'+$Name)
    $endpoints=if ($script:planEmpty) { @() } elseif ($Name -eq 'tcp-loaded') { @([pscustomobject]@{remoteIP='9.9.9.9';remotePort=8443}) } else { @([pscustomobject]@{remoteIP='8.8.8.8';remotePort=6112}) }
    return [pscustomobject]@{name=$Name;endpoints=@($endpoints);engineExitedDuringCapture=($script:planEngineCrash -and $Name -eq 'tcp-loaded')}
}
$planReport=[ordered]@{attempts=@();status='running';serviceRestored=$false}
$script:events.Clear()
Invoke-GW2TestPlan $planReport
Assert-Test ($planReport.status -eq 'completed' -and $planReport.serviceRestored) 'Four-phase plan completes and restores original state'
Assert-Test (($planReport.attempts.name -join ',') -eq 'current,without-zapret,tcp-loaded,tcp-observed') 'Four-phase plan preserves test order'
Assert-Test ($script:planStarts.Count -eq 2 -and $script:planStarts[0].ports -eq $script:planStarts[1].ports) 'Same frozen TCP ports used for both A/B phases'
Assert-Test ((Get-Content -LiteralPath $script:planStarts[1].path) -contains '9.9.9.9') 'Observed target set includes newly seen server from third phase'
Assert-Test ($script:events[$script:events.Count-2] -eq 'stop-test' -and $script:events[$script:events.Count-1] -eq 'restore-original') 'Final test process stopped before original service restoration'
$script:planEmpty=$true; $script:planStarts=@(); $script:events.Clear()
$planReport=[ordered]@{attempts=@();status='running';serviceRestored=$false}
Invoke-GW2TestPlan $planReport
Assert-Test ($planReport.status -eq 'no-endpoints' -and $planReport.attempts.Count -eq 2 -and $planReport.serviceRestored) 'Missing connections produce partial report and restore service'
Assert-Test ($script:planStarts.Count -eq 0) 'No broad fallback profile launched without observed targets'
$script:planEmpty=$false; $script:planCancel='tcp-loaded'; $script:events.Clear()
$planReport=[ordered]@{attempts=@();status='running';serviceRestored=$false}
Assert-Throws { Invoke-GW2TestPlan $planReport } 'Cancellation during third phase propagated'
Assert-Test ($planReport.serviceRestored -and $script:events[$script:events.Count-1] -eq 'restore-original') 'Third-phase cancellation restores original state'
$script:planCancel=''; $script:planEngineCrash=$true
$planReport=[ordered]@{attempts=@();status='running';serviceRestored=$false}
Invoke-GW2TestPlan $planReport
Assert-Test ($planReport.status -eq 'failed' -and $planReport.serviceRestored) 'Engine exit cannot yield completed comparison'
Write-Host ("All $script:count checks passed. Artifacts: $testPath")
