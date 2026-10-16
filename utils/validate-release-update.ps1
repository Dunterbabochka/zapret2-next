# Real HTTP, ZIP and file transactions; every Windows service/task/process
# boundary is replaced before invoking the updater. No GitHub writes.
param([switch]$SkipConsole, [switch]$RequireNativeEngine)
$ErrorActionPreference = 'Stop'
$sourceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'update-release-core.ps1')
. (Join-Path $PSScriptRoot 'update-release-state.ps1')
$fixture = Join-Path $sourceRoot ('runtime\release-update-tests-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
$checks = 0
$server = $null
$realConfigTest = ${function:Test-ReleaseConfig}
$realDiskTest = ${function:Assert-ReleaseDiskSpace}
$realMove = ${function:Move-ReleaseItem}
$realRemove = ${function:Remove-ReleaseTree}
$realWindowsState = ${function:Get-ReleaseWindowsState}
$realStartWindows = ${function:Start-ReleaseWindowsState}
$realStopWindows = ${function:Stop-ReleaseWindowsState}
$realStopDriver = ${function:Stop-ReleaseOwnedDriver}

function Assert-Update([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function Assert-UpdateRejected([scriptblock]$Operation, [string]$Message) {
    $rejected=$false
    try { & $Operation | Out-Null } catch { $rejected=$true }
    Assert-Update $rejected $Message
}
function Write-FixtureText([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))
}
function Set-ServerScenario([string]$Mode='ok', [string]$Version='9.9.1', [string]$Archive='valid.zip', [int]$Delay=0) {
    Write-ReleaseJson (Join-Path $fixture 'scenario.json') @{mode=$Mode;version=$Version;archive=$Archive;delay=$Delay}
}
function Get-ReleaseHttpTarget([string]$Url) {
    if ($Url -eq 'https://api.github.com/repos/Dunterbabochka/zapret2-next/releases/latest') { $path='/release' }
    elseif ($Url -match '^https://github.com/Dunterbabochka/zapret2-next/releases/download/v[0-9.]+/([^/]+)$') { $path='/assets/'+$matches[1] }
    else { throw 'A test attempted a non-fixture network request.' }
    return [pscustomobject]@{Url=('http://127.0.0.1:'+$script:fixturePort+$path);Protocol='http'}
}
function Get-ReleaseWindowsState([string]$Root) {
    $config = Join-Path $Root 'runtime\service.txt'
    $options = Get-ReleaseConfigOptions $config
    return [pscustomobject]@{
        Service=$(if ($script:noService) {$null} else {[pscustomobject]@{PathName=('"'+(Join-Path $Root 'bin\winws2.exe')+'" @"'+$config+'"');StartMode='Manual';WasRunning=(-not $script:stoppedService);Strategy=$options.Preset}})
        Configs=@([pscustomobject]@{Relative='runtime\service.txt';Options=$options;Original=[Convert]::ToBase64String([IO.File]::ReadAllBytes($config))})
        Manual=@();Telegram=@()
    }
}
function Stop-ReleaseWindowsState($Snapshot) { $script:events.Add('stop'); if ($script:failStop) { throw 'Injected stop failure' } }
function Stop-ReleaseInstalledProcesses($Root,$Snapshot) { $script:events.Add('stop-updated') }
function Stop-ReleaseOwnedDriver($Root) {
    $script:events.Add('driver-stop')
    if ($script:failDriverStop) { throw 'Injected driver stop failure' }
}
function Start-ReleaseWindowsState($Root,$Snapshot) {
    $script:events.Add('start')
    Assert-Update (Test-Path -LiteralPath (Join-Path $Root 'bin\winws2.exe')) 'Restart happened before files were restored'
    if ($script:failStart) { $script:failStart=$false;throw 'Injected start failure' }
    if ($script:failStartCount -gt 0) { $script:failStartCount--;throw 'Injected recovery/start failure' }
}
function Test-ReleaseConfig([string]$Root,$Config,[string]$Output,[switch]$DryRun) {
    if ($Config.Options -is [Collections.IDictionary]) { $preset=$Config.Options.Preset } else {$preset=$Config.Options.Preset}
    if (-not (Test-Path -LiteralPath (Join-Path $Root ('presets\'+$preset+'.txt.in')))) { throw 'Saved preset is absent from new release' }
    $options=@{}
    if ($Config.Options -is [Collections.IDictionary]) { foreach ($key in $Config.Options.Keys) {$options[$key]=$Config.Options[$key]} }
    else {foreach ($property in $Config.Options.PSObject.Properties) {$options[$property.Name]=$property.Value}}
    & (Join-Path $Root 'utils\render-config.ps1') @options -Output $Output -DryRun:$DryRun | Out-Null
    if ($script:rejectConfig) { throw 'Injected engine config rejection' }
}
function Invoke-ReleaseCheckpoint([string]$Name) {
    if ($script:failurePoint -ceq $Name) { throw ('Injected failure at '+$Name) }
}
function New-InstalledFixture([string]$Destination) {
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    foreach ($relative in @($script:releaseFiles + $script:releaseDirectories + @('lists'))) {
        Copy-Item -LiteralPath (Join-Path $sourceRoot $relative) -Destination $Destination -Recurse -Force
    }
    Write-FixtureText (Join-Path $Destination '.service\version.txt') '9.9.0'
    Initialize-ZapretLog -Root $Destination -Component update -Action Check
    Write-FixtureText (Join-Path $Destination 'utils\game_filter.mode') "all`r`n"
    Write-FixtureText (Join-Path $Destination 'utils\check_updates.enabled') "enabled`r`n"
    Write-FixtureText (Join-Path $Destination 'lists\list-general-user.txt') "# private`r`nmy-domain.example`r`n"
    Write-FixtureText (Join-Path $Destination 'lists\list-general.txt') "# customized base list`r`nexample.com`r`n"
    Write-FixtureText (Join-Path $Destination 'runtime\history\report.txt') 'preserved history'
    Write-FixtureText (Join-Path $Destination 'runtime\telegram\S-1-5-21-123\config.json') '{"port":1443,"secret":"private-fixture-secret"}'
    # Applied Game=off, pending menu Game=all must remain distinct.
    & (Join-Path $Destination 'utils\render-config.ps1') -Preset general -GameMode off -IPSetMode loaded -VoiceMode compatible -DiscordFake current -GameFake current -Output (Join-Path $Destination 'runtime\service.txt') | Out-Null
}
function Reset-PreparedFixture {
    if (Test-Path -LiteralPath $script:install) { Remove-ReleaseTree $fixture $script:install }
    Copy-Item -LiteralPath $script:template -Destination $script:install -Recurse -Force
    $script:events=[Collections.Generic.List[string]]::new()
    $script:failurePoint='';$script:failStart=$false;$script:failStop=$false;$script:noService=$false;$script:stoppedService=$false
    $script:failStartCount=0
    $script:failDriverStop=$false
    $transaction=Read-ReleaseJson (Join-Path (Get-ReleaseUpdateDirectory $script:install) 'transaction.json')
    Initialize-ZapretLog -Root $script:install -Component update -Action Apply -SessionId $transaction.LogSessionId
    $transaction.Root=$script:install
    $transaction.Windows=Get-ReleaseWindowsState $script:install
    $transaction.Fingerprint=Get-ReleaseFingerprint $script:install $transaction.Windows @(Get-ReleaseSettings $script:install)
    Save-ReleaseTransaction $script:install $transaction
    return $transaction
}
function Assert-Preserved([string]$Root) {
    foreach ($entry in $script:listHashes.GetEnumerator()) {
        Assert-Update ((Get-FileHash -LiteralPath (Join-Path $Root $entry.Key) -Algorithm SHA256).Hash -ceq $entry.Value) ('List bytes changed: '+$entry.Key)
    }
    foreach ($entry in $script:modeHashes.GetEnumerator()) {
        Assert-Update ((Get-FileHash -LiteralPath (Join-Path $Root $entry.Key) -Algorithm SHA256).Hash -ceq $entry.Value) ('Setting bytes changed: '+$entry.Key)
    }
    Assert-Update (([IO.File]::ReadAllText((Join-Path $Root 'utils\game_filter.mode'))).Trim() -eq 'all') 'Pending mode was lost'
    Assert-Update ((Get-ReleaseConfigOptions (Join-Path $Root 'runtime\service.txt')).GameMode -eq 'off') 'Pending settings replaced the applied configuration'
    Assert-Update (([IO.File]::ReadAllText((Join-Path $Root 'lists\list-general-user.txt'))).Contains('my-domain.example')) 'User list was overwritten'
    Assert-Update (([IO.File]::ReadAllText((Join-Path $Root 'lists\list-general.txt'))).Contains('customized base list')) 'Base list was overwritten'
    Assert-Update ([IO.File]::ReadAllText((Join-Path $Root 'runtime\history\report.txt')) -eq 'preserved history') 'History was lost'
    Assert-Update ([IO.File]::ReadAllText((Join-Path $Root 'runtime\telegram\S-1-5-21-123\config.json')) -eq '{"port":1443,"secret":"private-fixture-secret"}') 'Telegram config was changed'
}

try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $package = Join-Path $fixture 'zapret2-next-v9.9.1'
    New-InstalledFixture $package
    Remove-ReleaseTree $package (Join-Path $package 'runtime')
    Write-FixtureText (Join-Path $package '.service\version.txt') '9.9.1'
    Write-FixtureText (Join-Path $package 'lists\new-required.txt') 'new bundled list'
    [IO.Compression.ZipFile]::CreateFromDirectory($package,(Join-Path $fixture 'valid.zip'),[IO.Compression.CompressionLevel]::Fastest,$true)
    # Windows PowerShell Compress-Archive emits backslashes, including trailing
    # directory separators. Such entries must never become zero-byte files.
    $windowsZip=Join-Path $fixture 'windows-separators.zip'
    $archive=[IO.Compression.ZipFile]::Open($windowsZip,[IO.Compression.ZipArchiveMode]::Create)
    try {
        $null=$archive.CreateEntry('zapret2-next-v9.9.1\docs\third_party\')
        $entry=$archive.CreateEntry('zapret2-next-v9.9.1\docs\third_party\nested\LICENSE')
        $writer=[IO.StreamWriter]::new($entry.Open())
        try {$writer.Write('Windows ZIP directory fixture')} finally {$writer.Dispose()}
    } finally {$archive.Dispose()}
    $windowsStage=Expand-ReleasePackage $windowsZip (Join-Path $fixture 'windows-unpacked') '9.9.1'
    Assert-Update ([IO.Directory]::Exists((Join-Path $windowsStage 'docs\third_party'))) 'Windows ZIP directory was extracted as a file'
    Assert-Update ([IO.File]::ReadAllText((Join-Path $windowsStage 'docs\third_party\nested\LICENSE')) -ceq 'Windows ZIP directory fixture') 'Windows ZIP nested content was not extracted'
    Write-FixtureText (Join-Path $fixture 'invalid.zip') 'not a ZIP'
    Set-ServerScenario
    $server = Start-Process python -ArgumentList ('"'+(Join-Path $sourceRoot 'packaging\test-release-server.py')+'" --root "'+$fixture+'"') -WindowStyle Hidden -PassThru
    $timer=[Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath (Join-Path $fixture 'port.txt'))) {
        if ($server.HasExited -or $timer.Elapsed.TotalSeconds -gt 10) { throw 'Local release server did not start.' }
        Start-Sleep -Milliseconds 50
    }
    $script:fixturePort=([IO.File]::ReadAllText((Join-Path $fixture 'port.txt'))).Trim()
    $script:template=Join-Path $fixture 'prepared-template'
    $script:install=Join-Path $fixture 'Install with spaces'
    $script:events=[Collections.Generic.List[string]]::new()
    New-InstalledFixture $script:template
    $script:listHashes=@{};$script:modeHashes=@{}
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $script:template 'lists') -File -Recurse -Force) {
        if ($file.Name -like '*.lock') {continue}
        $script:listHashes[$file.FullName.Substring($script:template.Length+1)]=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
    foreach ($name in $script:releaseModeNames) {
        $path=Join-Path $script:template ('utils\'+$name)
        if (Test-Path -LiteralPath $path) {$script:modeHashes['utils\'+$name]=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash}
    }

    Assert-Update (Test-ReleaseNewer '0.10.0' '0.9.9') 'Numeric version ordering failed'
    Assert-Update (Test-ReleaseNewer '1.0.0' '1.0.0-beta.1') 'Stable upgrade from beta failed'
    Assert-Update (-not (Test-ReleaseNewer '0.4.0' '0.4.1')) 'Downgrade was offered'
    Assert-Update (-not (Test-ReleaseNewer '0.5.0-beta.1' '0.4.1')) 'Beta was offered'
    $check=Invoke-ReleaseCheck $script:template
    Assert-Update ($check.Status -eq 'available') 'Available release was not detected'
    Set-ServerScenario 'not-modified'
    $check=Invoke-ReleaseCheck $script:template
    Assert-Update ($check.Status -eq 'available' -and $check.ETag -eq '"fixture-v1"') 'ETag/304 did not retain metadata'
    Assert-Update (@((Get-ZapretLogSnapshot $script:template).Events | Where-Object {$_.action -eq 'HTTP' -and $_.details.httpCode -eq 304}).Count -gt 0) 'Conditional HTTP result not logged'
    foreach ($mode in @('unavailable','missing-asset','foreign-asset','beta','draft')) {
        Set-ServerScenario $mode
        Assert-Update ((Invoke-ReleaseCheck $script:template -Force).Status -eq 'unavailable') ("Invalid release accepted: "+$mode)
    }
    foreach ($version in @('9.9.0','9.8.9')) {
        Set-ServerScenario 'ok' $version
        Assert-Update ((Invoke-ReleaseCheck $script:template -Force).Status -eq 'current') 'Same/older release offered'
    }
    foreach ($mode in @('bad-hash','truncated')) {
        $beforeRequests=if (Test-Path (Join-Path $fixture 'requests.txt')) {@([IO.File]::ReadAllLines((Join-Path $fixture 'requests.txt')) | Where-Object {$_ -eq '/archive'}).Count} else {0}
        Set-ServerScenario $mode
        Assert-UpdateRejected { Invoke-ReleasePrepare $script:template } ("Broken download accepted: "+$mode)
        Assert-Update ($script:events.Count -eq 0 -and (Get-ReleaseVersion $script:template) -eq '9.9.0') 'Failed preparation changed a running installation'
        if ($mode -eq 'truncated') {
            $afterRequests=@([IO.File]::ReadAllLines((Join-Path $fixture 'requests.txt')) | Where-Object {$_ -eq '/archive'}).Count
            Assert-Update (($afterRequests-$beforeRequests) -eq 2) 'A partial download did not retry exactly once'
            Assert-Update (@((Get-ZapretLogSnapshot $script:template).Events | Where-Object code -eq 'DownloadRetry').Count -gt 0) 'Download retry not logged'
        }
    }
    Set-ServerScenario 'ok' '9.9.1' 'invalid.zip'
    Assert-UpdateRejected { Invoke-ReleasePrepare $script:template } 'Invalid ZIP accepted'
    Set-ServerScenario 'ok' '9.9.2'
    Assert-UpdateRejected { Invoke-ReleasePrepare $script:template } 'Wrong internal version was accepted'
    foreach ($names in @(@('zapret2-next-v9.9.1/../escape.txt'),@('zapret2-next-v9.9.1/C:/escape.txt'),@('zapret2-next-v9.9.1/NUL.txt'),@('zapret2-next-v9.9.1/a','zapret2-next-v9.9.1/A'))) {
        $badZip=Join-Path $fixture ('unsafe-'+[Guid]::NewGuid().ToString('N')+'.zip')
        $zip=[IO.Compression.ZipFile]::Open($badZip,'Create')
        try { foreach ($name in $names) { $null=$zip.CreateEntry($name) } } finally {$zip.Dispose()}
        Assert-UpdateRejected { Expand-ReleasePackage $badZip (Join-Path $fixture 'unsafe-unpacked') '9.9.1' } 'Unsafe ZIP path was accepted'
    }
    Set-ServerScenario
    $transaction=Invoke-ReleasePrepare $script:template
    Assert-Update ($transaction.Status -eq 'prepared' -and $script:events.Count -eq 0) 'Preparation stopped installed processes'
    Assert-UpdateRejected { Invoke-ReleasePrepare $sourceRoot } 'Git checkout accepted for replacement'
    function Assert-ReleaseDiskSpace { throw 'Injected insufficient disk space' }
    Assert-UpdateRejected { Invoke-ReleasePrepare $script:template } 'Insufficient space was ignored'
    Set-Item Function:Assert-ReleaseDiskSpace $realDiskTest
    $script:rejectConfig=$true
    Assert-UpdateRejected { Invoke-ReleasePrepare $script:template } 'Rejected selected config did not abort preparation'
    $script:rejectConfig=$false
    Write-FixtureText (Join-Path $script:template 'utils\game_filter.mode') 'invalid-mode'
    Assert-UpdateRejected { Invoke-ReleasePrepare $script:template } 'Invalid saved mode was silently reset'
    Write-FixtureText (Join-Path $script:template 'utils\game_filter.mode') "all`r`n"
    $oldConfig=[IO.File]::ReadAllBytes((Join-Path $script:template 'runtime\service.txt'))
    [IO.File]::AppendAllText((Join-Path $script:template 'runtime\service.txt'),"`r`n--unknown-custom-option=1")
    Assert-UpdateRejected { Invoke-ReleasePrepare $script:template } 'Manual edits to the active configuration were dropped silently'
    [IO.File]::WriteAllBytes((Join-Path $script:template 'runtime\service.txt'),$oldConfig)

    $transaction=Reset-PreparedFixture
    $result=Invoke-ReleaseApply $script:install
    Assert-Update ($result.Status -eq 'committed' -and (Get-ReleaseVersion $script:install) -eq '9.9.1') 'Update did not commit'
    Assert-Update (Test-Path -LiteralPath (Join-Path $script:install 'lists\new-required.txt')) 'A new required list was not added'
    Assert-Update (-not (Test-Path -LiteralPath (Join-Path (Get-ReleaseSession $script:install $result) 'backup'))) 'Old release was not deleted after success'
    Assert-Preserved $script:install
    Assert-Update (($script:events -join ',') -eq 'stop,driver-stop,start') 'Driver was not unloaded between engine stop and file replacement'
    $logEvents=(Get-ZapretLogSnapshot $script:install).Events
    Assert-Update (@($logEvents | Where-Object {$_.component -eq 'update' -and $_.stage -eq 'files'}).Count -gt 0) 'File replacement steps missing from journal'
    Assert-Update (Test-Path (Join-Path $script:install 'runtime\release-update\recovery\session-log.ps1')) 'Recovery logger missing'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:install 'runtime\release-update\recovery\manage-logs.ps1') -Root $script:install -Action Export -NoReveal
    Assert-Update ($LASTEXITCODE -eq 0) 'Standalone recovery logs exporter failed'

    $transaction=Reset-PreparedFixture
    $locked=[IO.File]::Open((Join-Path $script:install 'bin\winws2.exe'),'Open','Read','None')
    try { Assert-UpdateRejected { Invoke-ReleaseApply $script:install } 'A locked engine was replaced' }
    finally {$locked.Dispose()}
    Assert-Update ((Get-ReleaseVersion $script:install) -eq '9.9.0' -and (Read-ReleaseTransaction $script:install).Status -eq 'rolled-back') 'Locked files damaged the installation'
    $transaction=Reset-PreparedFixture
    function Remove-ReleaseTree($Parent,$Path) {
        if ($Path -match '\\backup$') { throw 'Injected locked backup' }
        & $script:realRemove $Parent $Path
    }
    $result=Invoke-ReleaseApply $script:install
    Assert-Update ($result.Status -eq 'committed' -and $result.CleanupPending) 'Cleanup error rolled back a successful update'
    Set-Item Function:Remove-ReleaseTree $realRemove
    Invoke-ReleaseRecover $script:install
    Assert-Update (-not (Read-ReleaseTransaction $script:install).CleanupPending) 'Deferred cleanup was not retried'

    $transaction=Reset-PreparedFixture
    $script:failDriverStop=$true
    Assert-UpdateRejected { Invoke-ReleaseApply $script:install } 'Driver stop failure did not abort replacement'
    Assert-Update ((Read-ReleaseTransaction $script:install).Status -eq 'rolled-back' -and (Get-ReleaseVersion $script:install) -eq '9.9.0') 'Driver stop failure damaged the installed version'
    Assert-Update ($script:events.Contains('start')) 'Engine was not restored after driver stop failure'
    Assert-Update (@($script:events | Where-Object {$_ -eq 'driver-stop'}).Count -eq 1) 'Rollback retried a failing driver stop before any file replacement'

    # Model the loaded .sys with a real file lock, released only by driver stop.
    & {
        $script:driverEvents=[Collections.Generic.List[string]]::new()
        $script:driverState=[pscustomobject]@{State='Running';PathName=('\??\'+(Join-Path $script:install 'bin\WinDivert64.sys'))}
        $script:driverQueries=0
        function Get-CimInstance {param($ClassName,$Filter);$script:driverQueries++;return $script:driverState}
        function Get-ReleaseEngineProcesses {return @()}
        $script:driverService=[pscustomobject]@{Status='Running'}
        $script:driverService | Add-Member ScriptMethod Stop {
            $script:driverEvents.Add('stop')
            if ($script:driverLock) { $script:driverLock.Dispose();$script:driverLock=$null }
            $script:driverState=$null
        }
        $script:driverService | Add-Member ScriptMethod WaitForStatus {throw 'WinDivert registration was removed during unload'}
        function Get-Service {param($Name);return $script:driverService}
        $driverFixture=Join-Path $fixture 'driver-backup'
        Write-FixtureText (Join-Path $driverFixture 'WinDivert64.sys') 'mapped driver'
        $script:driverLock=[IO.File]::Open((Join-Path $driverFixture 'WinDivert64.sys'),'Open','Read','None')
        try {
            Assert-UpdateRejected { & $realRemove $fixture $driverFixture } 'Driver fixture was not locked'
            & $realStopDriver $script:install
            & $realRemove $fixture $driverFixture
            Assert-Update (-not (Test-Path -LiteralPath $driverFixture)) 'Unloaded driver backup could not be removed'
            Assert-Update (($script:driverEvents -join ',') -eq 'stop' -and $script:driverQueries -ge 2) 'Removed driver registration was not accepted as an unload'
        } finally { if ($script:driverLock) {$script:driverLock.Dispose();$script:driverLock=$null} }
        $script:driverEvents.Clear()
        $script:driverState=[pscustomobject]@{State='Running';PathName='\??\C:\OtherBundle\bin\WinDivert64.sys'}
        & $realStopDriver $script:install
        Assert-Update ($script:driverEvents.Count -eq 0) 'Another bundle driver was stopped'
        $script:driverState=$null
        & $realStopDriver $script:install
        Assert-Update ($script:driverEvents.Count -eq 0) 'An absent driver was stopped'
    }

    $points=@('stopped','started') + @($transaction.Items | ForEach-Object { 'old:'+$_.Relative; 'new:'+$_.Relative })
    foreach ($point in $points) {
        $transaction=Reset-PreparedFixture
        $script:failurePoint=$point
        Assert-UpdateRejected { Invoke-ReleaseApply $script:install } ("Failure injection did not fail: "+$point)
        Assert-Update ((Read-ReleaseTransaction $script:install).Status -eq 'rolled-back' -and (Get-ReleaseVersion $script:install) -eq '9.9.0') ("Rollback failed at "+$point)
        Assert-Preserved $script:install
    }
    $transaction=Reset-PreparedFixture
    $script:failStart=$true
    Assert-UpdateRejected { Invoke-ReleaseApply $script:install } 'Failed startup was accepted'
    Assert-Update ((Read-ReleaseTransaction $script:install).Status -eq 'rolled-back') 'Failed startup did not roll back'
    $transaction=Reset-PreparedFixture
    $script:failStop=$true
    Assert-UpdateRejected { Invoke-ReleaseApply $script:install } 'Failed stop was ignored'
    Assert-Update ((Read-ReleaseTransaction $script:install).Status -eq 'rolled-back') 'Failed stop did not restore the old state'
    $transaction=Reset-PreparedFixture
    $script:failStartCount=2
    Assert-UpdateRejected { Invoke-ReleaseApply $script:install } 'Failed rollback was not reported'
    Assert-Update ((Read-ReleaseTransaction $script:install).Status -eq 'rollback-failed') 'Rollback failure lost its recovery journal'
    Invoke-ReleaseRecover $script:install
    Assert-Update ((Read-ReleaseTransaction $script:install).Status -eq 'rolled-back') 'A failed rollback could not be retried'
    $transaction=Reset-PreparedFixture
    Write-FixtureText (Join-Path $script:install 'utils\game_filter.mode') 'tcp'
    Assert-UpdateRejected { Invoke-ReleaseApply $script:install } 'Concurrent settings change was ignored'
    Assert-Update ($script:events.Count -eq 0) 'Changed settings caused service interruption'

    foreach ($point in $points) {
        $transaction=Reset-PreparedFixture
        $arguments='-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $sourceRoot 'packaging\test-release-crash.ps1')+'" -Root "'+$script:install+'" -Source "'+$sourceRoot+'" -Point "'+$point+'"'
        $child=Start-Process powershell.exe -ArgumentList $arguments -WindowStyle Hidden -PassThru
        $null=$child.Handle
        if (-not $child.WaitForExit(30000)) { $child.Kill();throw 'Crash fixture timed out' }
        Assert-Update ($child.ExitCode -eq 91) ('Crash checkpoint was not reached: '+$point)
        $child.Dispose()
        Initialize-ZapretLog -Root $script:install -Component update -Action Recover -SessionId $transaction.LogSessionId
        Invoke-ReleaseRecover $script:install
        Assert-Update (@((Get-ZapretLogSnapshot $script:install).Events | Where-Object code -eq 'OperationInterrupted').Count -gt 0) 'Crash not recorded in original session'
        Assert-Update ((Read-ReleaseTransaction $script:install).Status -eq 'rolled-back' -and (Get-ReleaseVersion $script:install) -eq '9.9.0') ('Crash recovery failed at '+$point)
        Assert-Preserved $script:install
    }

    # All other processes must fail before writes while the transaction gate is held.
    $gate=Enter-ZapretBundleOperation $script:install
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $sourceRoot 'utils\update-release.ps1') -Root $script:install -Action SetSetting -Name game_filter.mode -Value tcp
        Assert-Update ($LASTEXITCODE -ne 0) 'A second process modified settings during the update'
    } finally { Exit-ZapretBundleOperation $gate }

    # Exercise the actual Windows boundary implementation with fake SCM/task
    # providers, including two different Windows users and a disabled task.
    & {
        $script:boundaryEvents=[Collections.Generic.List[string]]::new()
        $script:boundaryService=[pscustomobject]@{PathName=('"'+(Join-Path $script:install 'bin\winws2.exe')+'" @"'+(Join-Path $script:install 'runtime\service.txt')+'"');StartMode='Manual';WasRunning=$true;Strategy='general'}
        $script:boundaryEngines=@()
        function Get-ZapretServiceSnapshot {return $script:boundaryService}
        function Get-CimInstance {param($ClassName,$Filter);return [pscustomobject]@{State='Running';ProcessId=123}}
        function Get-ReleaseEngineProcesses {return $script:boundaryEngines}
        function Get-ZapretTelegramProcesses {return @()}
        $script:boundaryTasks=@()
        foreach ($n in 1..2) {
            $sid='S-1-5-21-100-200-300-'+$n
            $config=Join-Path $script:install ('runtime\telegram\'+$sid+'\config.json')
            Write-FixtureText $config ('{"version":1,"host":"127.0.0.1","port":'+(1442+$n)+',"secret":"0123456789abcdef0123456789abcdef","cfproxy":true}')
            $script:boundaryTasks += [pscustomobject]@{TaskName=('Zapret2Next-Telegram-'+$sid);State=$(if($n -eq 1){'Running'}else{'Disabled'})
                Principal=[pscustomobject]@{UserId=$sid;LogonType='Interactive';RunLevel='Limited'}
                Actions=@([pscustomobject]@{Execute=(Join-Path $script:install 'bin\telegram\zapret-telegram.exe');Arguments=('--config "'+$config+'"')})}
        }
        function Get-ScheduledTask {param($TaskPath);return $script:boundaryTasks}
        function Export-ScheduledTask {param($TaskName,$TaskPath);return '<Task>'+ $TaskName +'</Task>'}
        function Disable-ScheduledTask {param($TaskName,$TaskPath);$script:boundaryEvents.Add('disable:'+$TaskName)}
        function Enable-ScheduledTask {param($TaskName,$TaskPath);$script:boundaryEvents.Add('enable:'+$TaskName)}
        function Stop-ZapretTelegramTask($Context) {$script:boundaryEvents.Add('tg-stop:'+$Context.SID)}
        function Start-ZapretTelegramTask($Context) {$script:boundaryEvents.Add('tg-start:'+$Context.SID)}
        function Wait-ZapretTelegramReady($Context,$Port) {Assert-Update ($Port -eq 1443) 'Telegram endpoint changed during migration'}
        function Restore-ZapretTelegramTaskRegistration($Context,$Snapshot) {Assert-Update ($Snapshot.Xml.Contains($Context.TaskName)) 'Task XML was not preserved'}
        function Stop-ZapretService {$script:boundaryEvents.Add('service-stop')}
        function Start-ZapretService {$script:boundaryEvents.Add('service-start')}
        function Restore-ZapretServiceRegistration($Snapshot) {Assert-Update ($Snapshot.StartMode -eq 'Manual') 'Service start mode was lost'}
        $snapshot=& $realWindowsState $script:install
        Assert-Update ($snapshot.Telegram.Count -eq 2 -and $snapshot.Telegram[0].Port -eq 1443 -and $snapshot.Telegram[1].Port -eq 1444) 'Multiple Telegram users were not captured'
        & $realStopWindows $snapshot
        & $realStartWindows $script:install $snapshot
        Assert-Update ($script:boundaryEvents.Contains('service-start')) 'Running service was not restarted'
        Assert-Update (@($script:boundaryEvents | Where-Object {$_ -like 'tg-start:*'}).Count -eq 1) 'Disabled/stopped Telegram task was started'
        $script:boundaryEvents.Clear();$snapshot.Service.WasRunning=$false
        & $realStartWindows $script:install $snapshot
        Assert-Update (-not $script:boundaryEvents.Contains('service-start')) 'Stopped service was started'
        $script:boundaryEvents.Clear();$snapshot.Service=$null
        & $realStartWindows $script:install $snapshot
        Assert-Update (-not $script:boundaryEvents.Contains('service-start')) 'Absent service was installed'
        $script:boundaryService.PathName='foreign.exe'
        Assert-UpdateRejected {& $realWindowsState $script:install} 'Foreign service was accepted'
        $script:boundaryService=$null
        $script:boundaryEngines=@([pscustomobject]@{ProcessId=456;ExecutablePath=(Join-Path $script:install 'bin\winws2.exe');CommandLine='unknown command'})
        Assert-UpdateRejected {& $realWindowsState $script:install} 'Unknown manual engine was accepted'
    }

    # Native dry-run of just the selected config; it does not intercept traffic.
    $script:failurePoint=''
    $nativeConfig=Get-ReleaseWindowsState $script:install
    $administrator=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($administrator) {
        & $realConfigTest $script:install $nativeConfig.Configs[0] (Join-Path $fixture 'native.dry.txt') -DryRun
        Write-Host '[OK] selected configuration accepted by the real engine'
    } elseif ($RequireNativeEngine) { throw 'Native engine validation requires an elevated Windows session.' }
    else { Write-Host '[SKIP] native winws2 dry-run requires elevation; required by CI and the Windows VM smoke test.' -ForegroundColor Yellow }

    if (-not $SkipConsole) {
        & python (Join-Path $sourceRoot 'packaging\test-release-console.py') --root $fixture --source $sourceRoot --port $script:fixturePort
        Assert-Update ($LASTEXITCODE -eq 0) 'Native cmd.exe/input test failed'
    }
    Write-Host "Release update validation passed: $checks checks." -ForegroundColor Green
} finally {
    if ($server -and -not $server.HasExited) { $server.Kill();$server.WaitForExit() }
    if ($server) { $server.Dispose() }
}
