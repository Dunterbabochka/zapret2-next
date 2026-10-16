# Isolated renderer/menu/function contracts; no real service or Telegram changes.
$ErrorActionPreference='Stop'
$sourceRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$fixture=Join-Path $sourceRoot ('runtime\startup-tests-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixture) | Out-Null
foreach ($directory in @('utils','presets','lists','.service')) { Copy-Item -LiteralPath (Join-Path $sourceRoot $directory) -Destination $fixture -Recurse }
[IO.Directory]::CreateDirectory((Join-Path $fixture 'bin')) | Out-Null
Copy-Item -LiteralPath (Join-Path $sourceRoot 'bin\fake') -Destination (Join-Path $fixture 'bin') -Recurse
. (Join-Path $fixture 'utils\menu.ps1') -LibraryOnly
$checks=0
function Assert-Startup([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message }; $script:checks++ }
$env:ZAPRET_LOG_ROOT=''; $env:ZAPRET_LOG_SESSION=''; $env:ZAPRET_LOG_DISABLED=''
Initialize-ZapretLog -Root $fixture -Component menu -Action Start -OwnerProcessId $PID
$menuContext=$script:ZapretLog
Invoke-ZapretMenuOperation service Refresh { Write-ZapretLogEvent -Stage settings }
Assert-Startup ([object]::ReferenceEquals($menuContext,$script:ZapretLog)) 'Nested operation lost the menu log context'
try { Invoke-ZapretMenuOperation service Refresh { throw 'Injected nested failure' } } catch {}
Assert-Startup ([object]::ReferenceEquals($menuContext,$script:ZapretLog)) 'Failed nested operation lost the menu log context'
Write-ZapretLogSettingsSnapshot $fixture
Assert-Startup (@((Get-ZapretLogSnapshot $fixture).Events | Where-Object stage -eq snapshot).Count -eq 6) 'Batched snapshot lost settings'

$bannerState=@{Fingerprint='';Banner='';Timer=[Diagnostics.Stopwatch]::StartNew()}
$errorCount=$Error.Count
for ($i=0;$i -lt 20;$i++) { $null=Get-ReleaseMenuBanner $fixture $bannerState }
Assert-Startup ($Error.Count -eq $errorCount) 'Missing update cache generated repeated exceptions'
$checkDirectory=Join-Path $fixture 'runtime\release-update'
[IO.Directory]::CreateDirectory($checkDirectory) | Out-Null
$checkPath=Join-Path $checkDirectory 'check.json'
$offer=@{Status='available';Repository=Get-ReleaseRepository $fixture;Offer=@{Version='9.9.1'}}
Write-ReleaseJson $checkPath $offer
$banner=Get-ReleaseMenuBanner $fixture $bannerState
Assert-Startup ($banner.Contains('9.9.1')) 'Changed cache was not displayed'
$stamp=[IO.File]::GetLastWriteTimeUtc($checkPath)
$offer.Offer.Version='9.9.2';Write-ReleaseJson $checkPath $offer
[IO.File]::SetLastWriteTimeUtc($checkPath,$stamp)
Start-Sleep -Milliseconds 2100
Assert-Startup ((Get-ReleaseMenuBanner $fixture $bannerState).Contains('9.9.2')) 'Periodic full refresh missed replacement with the same timestamp/size'

$releaseMarker=Join-Path $fixture 'menu-released'
$owner=Get-Process -Id $PID
try { $ownerTicks=$owner.StartTime.ToUniversalTime().Ticks } finally { $owner.Dispose() }
[IO.File]::WriteAllText($releaseMarker,(@{ProcessId=$PID;StartedTicks=$ownerTicks} | ConvertTo-Json))
$blocked=$false
try { Wait-ReleaseMenuHost $releaseMarker 20 } catch { $blocked=$true }
Assert-Startup $blocked 'Update released a live persistent menu host'
[IO.File]::WriteAllText($releaseMarker,(@{ProcessId=$PID;StartedTicks=($ownerTicks-1)} | ConvertTo-Json))
Wait-ReleaseMenuHost $releaseMarker 20
Assert-Startup $true 'PID reuse must not block an unrelated process'
[IO.File]::WriteAllText($releaseMarker,'released')
Wait-ReleaseMenuHost $releaseMarker 20
[IO.File]::WriteAllText($releaseMarker,'{}')
$blocked=$false
try { Wait-ReleaseMenuHost $releaseMarker 20 } catch { $blocked=$true }
Assert-Startup $blocked 'Malformed release marker was accepted'

# Compare both outputs byte-for-byte with independently rendered public configs.
$renderer=Join-Path $fixture 'utils\render-config.ps1'
$out=Join-Path $fixture 'runtime\normal.txt';$dry=Join-Path $fixture 'runtime\pair.dry.txt';$reference=Join-Path $fixture 'runtime\reference.dry.txt'
foreach ($presetFile in Get-ChildItem (Join-Path $fixture 'presets') -Filter '*.txt.in' | Where-Object Name -NotLike '_*') {
    $preset=$presetFile.Name.Substring(0,$presetFile.Name.Length-7)
    foreach ($ipset in @('loaded','none','any')) {
        & $renderer -Preset $preset -Output $out -ValidationOutput $dry -IPSetMode $ipset | Out-Null
        & $renderer -Preset $preset -Output $reference -IPSetMode $ipset -DryRun | Out-Null
        Assert-Startup ([Convert]::ToBase64String([IO.File]::ReadAllBytes($dry)) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($reference))) "Paired validation differs: $preset/$ipset"
    }
}
$listPath=Join-Path $fixture 'lists\ipset-all.txt'
foreach ($case in @(@{Text='';Loaded=$false},@{Text="# comments`r`n `r`n";Loaded=$false},@{Text="# comment`r`n192.0.2.1/32`r`n";Loaded=$true},@{Text=("# comment`r`n"*5000)+"192.0.2.2/32`r`n";Loaded=$true})) {
    [IO.File]::WriteAllText($listPath,$case.Text,[Text.UTF8Encoding]::new($true))
    & $renderer -Preset general -Output $out -IPSetMode loaded | Out-Null
    $text=[IO.File]::ReadAllText($out)
    $file=if ($case.Loaded) {'ipset-all.txt'} else {'ipset-none.txt'}
    $expected='--ipset="'+(Join-Path $fixture ('lists\'+$file)).Replace('\','/')+'"'
    Assert-Startup ($text.Contains($expected)) 'Streaming IPSet presence changed the selected source'
}

# Exercise the real settings UI with only Windows/action boundaries replaced.
$script:answers=[Collections.Generic.Queue[string]]::new()
$script:refreshes=[Collections.Generic.List[object]]::new()
function Read-ZapretMenuLine { param($Prompt); if (-not $script:answers.Count) { throw 'Unexpected input request' }; $script:answers.Dequeue() }
function Wait-ZapretMenu {}
function Clear-ZapretMenu {}
function Get-ZapretMenuService { [pscustomobject]@{State='Running';Preset='general'} }
function Set-ZapretServiceConfiguration { param($Root,$Preset,$IPSetMode,[switch]$Restart,[switch]$Install); $script:refreshes.Add(@{Restart=[bool]$Restart;Install=[bool]$Install;IPSet=$IPSetMode;Preset=$Preset}) }
foreach ($case in @(@{Selection=4;Input='2';File='game_filter.mode';Value='tcp'},@{Selection=7;Input='1';File='voice_filter.mode';Value='standard'},@{Selection=8;Input='2';File='discord_fake.mode';Value='steam'},@{Selection=8;Input='5';File='game_fake.mode';Value='dbank-v2'})) {
    $script:answers.Enqueue($case.Input);$script:answers.Enqueue('N')
    Set-ZapretMenuMode $case.Selection
    Assert-Startup ([IO.File]::ReadAllText((Join-Path $fixture ('utils\'+$case.File))).Trim() -ceq $case.Value) 'Settings menu wrote the wrong mode'
    Assert-Startup (-not $script:refreshes[$script:refreshes.Count-1].Restart) 'Declined restart was ignored'
}
$path=Join-Path $fixture 'utils\game_filter.mode'
$before=[IO.File]::GetLastWriteTimeUtc($path)
Start-Sleep -Milliseconds 20
$script:answers.Enqueue('2');$script:answers.Enqueue('Y')
Set-ZapretMenuMode 4
Assert-Startup ([IO.File]::GetLastWriteTimeUtc($path) -eq $before) 'Repeated mode unnecessarily rewrote the file'
Assert-Startup ($script:refreshes[$script:refreshes.Count-1].Restart) 'Repeated selection lost explicit application of deferred settings'
$script:answers.Enqueue('Y');Set-ZapretMenuMode 5
Assert-Startup ([IO.File]::ReadAllText((Join-Path $fixture 'utils\ipset_filter.mode')).Trim() -eq 'none') 'IPSet toggle failed'
$script:answers.Enqueue('Y');Set-ZapretMenuMode 5
Assert-Startup ([IO.File]::ReadAllText((Join-Path $fixture 'utils\ipset_filter.mode')).Trim() -eq 'loaded') 'IPSet toggle persisted diagnostic any'
$script:answers.Enqueue('7');$script:answers.Enqueue('Y');Set-ZapretMenuMode 8
Assert-Startup ((Get-ZapretMenuModes).DiscordFake -eq 'current' -and (Get-ZapretMenuModes).GameFake -eq 'current') 'Fake defaults failed'
$count=$script:refreshes.Count
$script:answers.Enqueue('0');Set-ZapretMenuMode 8
Assert-Startup ($script:refreshes.Count -eq $count) 'Cancel applied a setting'
$script:answers.Enqueue('11');$script:answers.Enqueue('Y');Install-ZapretMenuService
Assert-Startup ($script:refreshes[$script:refreshes.Count-1].Preset -eq 'NEXT BALANCED' -and $script:refreshes[$script:refreshes.Count-1].Install) 'Preset mapping or install confirmation changed'

# Run the production engine coordinator with only the native process boundary
# replaced. No running strategy or Telegram task is stopped by these cases.
& {
    . (Join-Path $fixture 'utils\engine-control.ps1')
    [IO.File]::WriteAllText((Join-Path $fixture 'bin\winws2.exe'),'fixture: never executed')
    function Get-ZapretManualLaunchState { return @() }
    function Start-Process {
        param($FilePath,$ArgumentList,$WorkingDirectory,$WindowStyle,$RedirectStandardOutput,$RedirectStandardError,[switch]$PassThru)
        $script:engineAttempts++
        if (-not $script:engineSteps.Count) { throw 'Unexpected engine retry' }
        $step=$script:engineSteps.Dequeue()
        [IO.File]::WriteAllText($RedirectStandardOutput,$(if ($step.Marker) {"command line parameters verified`r`n"} else {''}))
        [IO.File]::WriteAllText($RedirectStandardError,('attempt-'+$script:engineAttempts))
        $process=[pscustomobject]@{Handle=1;ExitCode=$step.Code;HasExited=$step.Exited;WaitResult=$step.Exited}
        $process | Add-Member ScriptMethod WaitForExit {
            param([int]$Milliseconds)
            if ($PSBoundParameters.ContainsKey('Milliseconds')) { $script:engineWaits.Add($Milliseconds); return $this.WaitResult }
        }
        $process | Add-Member ScriptMethod Refresh {}
        $process | Add-Member ScriptMethod Dispose {$script:engineDisposals++}
        $process | Add-Member ScriptMethod Kill {$script:engineKills++;$this.HasExited=$true}
        return $process
    }
    $dll=@{Code=-1073741502;Marker=$false;Exited=$true}
    $good=@{Code=0;Marker=$true;Exited=$true}
    $cases=@(
        @{Name='transient';Steps=@($dll,$good);Result=0;Attempts=2;Validate=$true},
        @{Name='two-transient';Steps=@($dll,$dll,$good);Result=0;Attempts=3;Validate=$true},
        @{Name='persistent';Steps=@($dll,$dll,$dll);Result=13;Attempts=3;Validate=$true},
        @{Name='config-error';Steps=@(@{Code=1;Marker=$false;Exited=$true});Result=13;Attempts=1;Validate=$true},
        @{Name='missing-marker';Steps=@(@{Code=0;Marker=$false;Exited=$true});Result=13;Attempts=1;Validate=$true},
        @{Name='lost-exit-code';Steps=@(@{Code=$null;Marker=$true;Exited=$true});Result=0;Attempts=1;Validate=$true},
        @{Name='marker-with-error';Steps=@(@{Code=1;Marker=$true;Exited=$true});Result=13;Attempts=1;Validate=$true},
        @{Name='timeout';Steps=@(@{Code=$null;Marker=$false;Exited=$false});Result=16;Attempts=1;Validate=$true},
        @{Name='live-init-error';Steps=@($dll);Result=14;Attempts=1;Validate=$false},
        @{Name='live-running';Steps=@(@{Code=$null;Marker=$false;Exited=$false});Result=0;Attempts=1;Validate=$false}
    )
    foreach ($case in $cases) {
        $script:engineSteps=[Collections.Generic.Queue[object]]::new()
        foreach ($step in $case.Steps) {$script:engineSteps.Enqueue($step)}
        $script:engineAttempts=0;$script:engineDisposals=0;$script:engineKills=0
        $script:engineWaits=[Collections.Generic.List[int]]::new()
        $prefix=Join-Path $fixture ('runtime\engine-'+$case.Name)
        $result=Invoke-ZapretEngine -Config $out -LogPrefix $prefix -Validate:$case.Validate
        Assert-Startup ($result -eq $case.Result) ('Engine result: '+$case.Name)
        Assert-Startup ($script:engineAttempts -eq $case.Attempts) ('Engine retry policy: '+$case.Name)
        Assert-Startup ($script:engineDisposals -eq $case.Attempts) ('Engine process handle leaked: '+$case.Name)
        Assert-Startup ($script:engineKills -eq $(if($case.Name -eq 'timeout'){1}else{0})) ('Unexpected process termination: '+$case.Name)
        if ($case.Attempts -gt 1) {
            Assert-Startup ([IO.File]::ReadAllText($prefix+'.stderr.log.attempt-1') -ceq 'attempt-1') 'Failed initialization log was overwritten'
            Assert-Startup ($script:engineWaits[$case.Attempts-1] -lt $script:engineWaits[0]) 'Retries reset the validation timeout'
        }
    }
}

# Native helper loading must verify its catalog before executing the assembly.
[IO.Directory]::CreateDirectory((Join-Path $fixture 'bin')) | Out-Null
$native=Join-Path $fixture 'bin\zapret-native.dll'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $sourceRoot 'utils\build-native-helper.ps1') -Output $native
Assert-Startup ($LASTEXITCODE -eq 0) 'Precompiled native helper build failed'
[IO.File]::WriteAllText((Join-Path $fixture 'SHA256SUMS.txt'),((Get-FileHash $native -Algorithm SHA256).Hash+'  bin/zapret-native.dll'))
$probe=Join-Path $fixture 'probe.ps1'
[IO.File]::WriteAllText($probe,('param($Root); $ErrorActionPreference="Stop"; . (Join-Path $Root "utils\telegram-control.ps1"); $null=Get-ZapretTelegramShellProcessId'))
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $probe -Root $fixture
Assert-Startup ($LASTEXITCODE -eq 0) 'Precompiled native helper load failed'
[IO.File]::AppendAllText($native,'corrupt')
$ErrorActionPreference='Continue'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $probe -Root $fixture 2>$null
$ErrorActionPreference='Stop'
Assert-Startup ($LASTEXITCODE -ne 0) 'Corrupt native helper was loaded'

Close-ZapretLogMenu -OwnerProcessId $PID
Complete-ZapretLogOperation
Write-Host "[OK] Startup/menu contracts: $checks checks. Live services and Telegram were not changed."
# The expected corrupt-helper subprocess exits 1. GitHub's PowerShell wrapper
# propagates LASTEXITCODE even when every assertion passed.
exit 0
