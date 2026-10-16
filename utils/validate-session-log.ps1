# Real filesystem/process/export tests; no services, traffic or user settings.
param([string]$Child='', [string]$Root='', [string]$Session='', [switch]$RequireLinks, [string]$Operation='')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'session-log.ps1')
if ($Child) {
    function Show-ZapretLogWarning { throw $Error[0] }
    Initialize-ZapretLog -Root $Root -Component tests -Action Scan -SessionId $Session -OperationId $Operation
    if ($Child -eq 'Crash') { [Environment]::Exit(91) }
    if ($Child -eq 'Hold') {
        $gate=Enter-ZapretLogGate $Root
        try {
            [IO.File]::WriteAllText((Join-Path $Root 'gate-ready'),'ready')
            $timer=[Diagnostics.Stopwatch]::StartNew()
            while (-not (Test-Path (Join-Path $Root 'gate-release')) -and $timer.Elapsed.TotalSeconds -lt 15) { Start-Sleep -Milliseconds 20 }
        } finally { Exit-ZapretLogGate $gate }
        Complete-ZapretLogOperation; exit 0
    }
    for ($i=0;$i -lt 100;$i++) { Write-ZapretLogEvent -Details @{count=$i}; Start-Sleep -Milliseconds 2 }
    Complete-ZapretLogOperation
    exit 0
}
$source=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$fixture=Join-Path $source ('runtime\log-tests-'+[guid]::NewGuid().ToString('N'))
$checks=0
function Assert-Log([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message }; $script:checks++ }
function New-LogTestSession([string]$TestRoot) {
    $env:ZAPRET_LOG_DISABLED='';$env:ZAPRET_LOG_SESSION='';$env:ZAPRET_LOG_ROOT=''
    Initialize-ZapretLog -Root $TestRoot -Component tests -Action Scan
    Assert-Log ([bool]$script:ZapretLog -and $env:ZAPRET_LOG_DISABLED -ne '1') 'Journal initialization failed'
}
function Read-LogArchive([string]$Path) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip=[IO.Compression.ZipFile]::OpenRead($Path)
    try {
        Assert-Log ((($zip.Entries.FullName | Sort-Object) -join ',') -eq 'events.jsonl,LOGS.txt,manifest.json') 'Unexpected log ZIP member'
        $content=''
        foreach ($entry in $zip.Entries) { $reader=[IO.StreamReader]::new($entry.Open()); try { $content+=$reader.ReadToEnd() } finally { $reader.Dispose() } }
        $content
    } finally { $zip.Dispose() }
}
try {
    $cliRoot=Join-Path $fixture 'CLI default root'
    [IO.Directory]::CreateDirectory((Join-Path $cliRoot 'utils')) | Out-Null
    foreach ($file in @('manage-logs.ps1','session-log.ps1')) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination (Join-Path $cliRoot ('utils\'+$file)) }
    $cli=Join-Path $cliRoot 'utils\manage-logs.ps1'
    $cliId=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cli -Action Start
    Assert-Log ($LASTEXITCODE -eq 0 -and $cliId -match '^[a-f0-9]{32}$') 'CLI Start default Root failed on Windows PowerShell'
    $bootstrap=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cli -Action Start -SessionId $cliId -MenuBootstrap -SkipTelegramStatus
    Assert-Log ($LASTEXITCODE -eq 0 -and @($bootstrap).Count -eq 1 -and $bootstrap -ceq ('SESSION='+$cliId)) 'Unelevated menu bootstrap queried Telegram or lost its session'
    $telegramStub=Join-Path $cliRoot 'utils\telegram-control.ps1'
    [IO.File]::WriteAllText($telegramStub,"function Get-ZapretTelegramStatus { param(`$Root,[switch]`$Compact,[switch]`$Fast); if (-not `$Fast) { throw 'Full status used during bootstrap' }; 'DISABLED' }",[Text.UTF8Encoding]::new($true))
    $bootstrap=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cli -Action Start -SessionId $cliId -MenuBootstrap
    Assert-Log ($LASTEXITCODE -eq 0 -and @($bootstrap).Count -eq 2 -and $bootstrap[0] -ceq ('SESSION='+$cliId) -and $bootstrap[1] -ceq 'TELEGRAM=DISABLED') 'Combined menu bootstrap output or fast status contract failed'
    [IO.File]::WriteAllText($telegramStub,"function Get-ZapretTelegramStatus { throw 'Injected status failure' }",[Text.UTF8Encoding]::new($true))
    $bootstrap=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cli -Action Start -SessionId $cliId -MenuBootstrap
    Assert-Log ($LASTEXITCODE -eq 0 -and @($bootstrap).Count -eq 2 -and $bootstrap[1] -ceq 'TELEGRAM=ERROR') 'Telegram status failure blocked the menu bootstrap'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cli -Action Finish -SessionId $cliId
    Assert-Log ($LASTEXITCODE -eq 0) 'CLI Finish failed'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cli -Action Export -NoReveal
    Assert-Log ($LASTEXITCODE -eq 0 -and @(Get-ChildItem (Join-Path $cliRoot 'runtime\logs\exports') -Filter '*.zip').Count -eq 1) 'CLI Export default Root failed'
    # A filename is user input even when it names a real local preset. Exercise
    # both initial writes and sanitizing already-stored events during export.
    & {
        $privacyRoot=Join-Path $fixture 'Local preset privacy'
        [IO.Directory]::CreateDirectory((Join-Path $privacyRoot 'utils')) | Out-Null
        [IO.Directory]::CreateDirectory((Join-Path $privacyRoot 'presets')) | Out-Null
        $logger=Join-Path $privacyRoot 'utils\session-log.ps1'
        Copy-Item -LiteralPath (Join-Path $source 'utils\session-log.ps1') -Destination $logger
        . $logger
        $presetName='PRIVATE_TOKEN_123'
        $presetPath=Join-Path $privacyRoot ('presets\'+$presetName+'.txt.in')
        [IO.File]::WriteAllText($presetPath,'# synthetic preset')
        New-LogTestSession $privacyRoot
        Write-ZapretLogEvent -Details @{preset=$presetName}
        Write-ZapretLogEvent -Details @{preset='general'}
        Complete-ZapretLogOperation
        $eventPath=Join-Path $script:ZapretLog.Directory 'events.jsonl'
        Assert-Log (-not [IO.File]::ReadAllText($eventPath).Contains($presetName)) 'Local preset name leaked during journal write'
        $text=Read-LogArchive (Export-ZapretSessionLogs -Root $privacyRoot -Archive)
        Assert-Log (-not $text.Contains($presetName) -and $text.Contains('CUSTOM') -and $text.Contains('general')) 'Preset export lost privacy or shipped names without templates'
        $stored=@((Get-ZapretLogSnapshot $privacyRoot).Events | Where-Object { $_.details.preset -eq 'CUSTOM' })[0]
        $stored.eventId=[guid]::NewGuid().ToString('N')
        $stored.details.preset=$presetName
        [IO.File]::AppendAllText($eventPath,(ConvertTo-Json -InputObject $stored -Depth 8 -Compress)+"`r`n")
        $text=Read-LogArchive (Export-ZapretSessionLogs -Root $privacyRoot -Archive)
        Assert-Log (-not $text.Contains($presetName)) 'Existing local preset name escaped export sanitization'
        Remove-Item -LiteralPath $presetPath
        $text=Read-LogArchive (Export-ZapretSessionLogs -Root $privacyRoot -Archive)
        Assert-Log ($text.Contains('CUSTOM') -and $text.Contains('general')) 'Recovery export depends on preset files still being present'
    }
    $testRoot=Join-Path $fixture 'Install with spaces'
    New-LogTestSession $testRoot
    $first=$script:ZapretLog.Id
    $canaries=@('PRIVATE_TOKEN_123','198.51.100.77','2001:db8::cafe','AA:BB:CC:DD:EE:FF','C:\Users\private-user\private-path','tg://proxy?secret=deadbeef','--secret=private-cookie')
    $private=$canaries -join ' '
    Write-ZapretLogEvent -Details @{secret=$private;script=$private;version=$private;preset=$private;exceptionType=$private;count=42;game='off';exitCode=28}
    try { throw $private } catch { Write-ZapretLogException $_ -Warning }
    Complete-ZapretLogOperation
    Assert-Log (Test-Path (Join-Path $script:ZapretLog.Directory 'SESSION.txt')) 'Standalone summary missing'
    $archive=Export-ZapretSessionLogs -Root $testRoot -Archive
    $text=Read-LogArchive $archive
    foreach ($value in $canaries) {
        Assert-Log (-not $text.Contains($value)) ('Private value in export: '+$value)
        foreach ($file in Get-ChildItem (Join-Path $testRoot 'runtime\logs\sessions') -File -Recurse) { Assert-Log (-not [IO.File]::ReadAllText($file.FullName).Contains($value)) 'Private value in sendable files' }
    }
    Assert-Log ($text.Contains('RuntimeException') -and $text.Contains('hresult')) 'Safe exception context missing'
    for ($i=0;$i -lt 6;$i++) { New-LogTestSession $testRoot; Complete-ZapretLogOperation; Start-Sleep -Milliseconds 5 }
    $paths=Get-ZapretLogPaths $testRoot
    Assert-Log (@(Get-ChildItem $paths.Sessions -Directory).Count -eq 5) 'Five-session retention failed'
    Assert-Log (-not (Test-Path (Join-Path $paths.Sessions $first))) 'Oldest session retained'
    # A live older owner must never be deleted by retention.
    New-LogTestSession $testRoot
    $active=$script:ZapretLog.Id
    for ($i=0;$i -lt 6;$i++) { New-LogTestSession $testRoot; Complete-ZapretLogOperation }
    Assert-Log (Test-Path (Join-Path $paths.Sessions $active)) 'Active session deleted'
    # Reclaim the deliberately retained active test lease.
    Get-ChildItem (Join-Path $paths.State $active) -Filter '*.json' | Remove-Item
    New-LogTestSession $testRoot
    $parallel=$script:ZapretLog.Id
    $children=@()
    for ($i=0;$i -lt 4;$i++) {
         $childArguments='-NoProfile -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -Child Write -Root "'+$testRoot+'" -Session '+$parallel+' -Operation '+$script:ZapretLog.OperationId
        $launched=Start-Process powershell.exe -ArgumentList $childArguments -WindowStyle Hidden -PassThru -RedirectStandardError (Join-Path $fixture ("child-$i.err"))
        $null=$launched.Handle; $children+=$launched
    }
    # Export while child writers are running.
    $null=Read-LogArchive (Export-ZapretSessionLogs -Root $testRoot -Archive)
    foreach ($testProcess in $children) { Assert-Log ($testProcess.WaitForExit(60000) -and $testProcess.ExitCode -eq 0) ('Parallel child failed: '+ ((Get-ChildItem $fixture -Filter '*.err' | Get-Content) -join ' ')) }
    $snapshot=Get-ZapretLogSnapshot $testRoot
    Assert-Log (@($snapshot.Events | Where-Object {$_.sessionId -eq $parallel -and $_.details.Contains('count')}).Count -eq 400) 'Parallel records lost'
    Assert-Log ($snapshot.Skipped -eq 0) 'Parallel JSONL corrupted'
    Assert-Log (Test-Path -LiteralPath $script:ZapretLog.Lease) 'Child with shared operation ID removed its parent lease'
    # A partial final write and unknown fields/values must not escape validation.
    $eventFile=Join-Path $script:ZapretLog.Directory 'events.jsonl'
    [IO.File]::AppendAllText($eventFile,"{broken`n")
    $safe=@($snapshot.Events | Select-Object -Last 1)[0]
    $unsafe=($safe | ConvertTo-Json -Depth 8 -Compress).Replace('"tests"','"'+$private+'"')
    [IO.File]::AppendAllText($eventFile,$unsafe+"`n")
    [IO.File]::WriteAllText((Join-Path $script:ZapretLog.Directory 'private.txt'),$private)
    $text=Read-LogArchive (Export-ZapretSessionLogs -Root $testRoot -Archive)
    Assert-Log (-not $text.Contains('PRIVATE_TOKEN_123')) 'Unexpected file or record included'
    Assert-Log ((Get-ZapretLogSnapshot $testRoot).Skipped -ge 2) 'Damaged records not reported'
    # Force actual segment rotation with valid safe records.
    $padded=([IO.File]::ReadAllLines($eventFile)[0] | ConvertFrom-Json)
    $padded | Add-Member -NotePropertyName ignoredPadding -NotePropertyValue ('x'*7000)
    $line=($padded | ConvertTo-Json -Depth 8 -Compress)+"`r`n"
    [IO.File]::WriteAllText($eventFile,($line*([int](3MB/[Text.Encoding]::UTF8.GetByteCount($line))+1)))
    Write-ZapretLogEvent
    Write-ZapretLogEvent
    Assert-Log (Test-Path (Join-Path $script:ZapretLog.Directory 'events.previous.jsonl')) 'Rotation missing'
    Assert-Log (@((Get-ZapretLogSnapshot $testRoot).Events | Where-Object code -eq 'JournalTruncated').Count -gt 0) 'Truncation not reported'
    Save-ZapretSessionSummary $testRoot
    Assert-Log ((Get-ChildItem $script:ZapretLog.Directory -File | Measure-Object Length -Sum).Sum -lt 10MB) 'Session exceeds 10 MiB'
    Complete-ZapretLogOperation
    for ($i=0;$i -lt 6;$i++) { $null=Export-ZapretSessionLogs -Root $testRoot -Archive }
    Assert-Log (@(Get-ChildItem $paths.Exports -Filter '*.zip').Count -eq 5) 'Export retention failed'
    # An interactive cmd shell can stay alive after Ctrl+C aborts a batch.
    $shellRoot=Join-Path $fixture 'Surviving shell'
    $env:ZAPRET_LOG_SESSION=''; $env:ZAPRET_LOG_ROOT=''
    Initialize-ZapretLog -Root $shellRoot -Component menu -Action Start -OwnerProcessId $PID
    $abortedId=$script:ZapretLog.Id
    $env:ZAPRET_LOG_SESSION=''
    Initialize-ZapretLog -Root $shellRoot -Component menu -Action Start -OwnerProcessId $PID
    $shellSnapshot=Get-ZapretLogSnapshot $shellRoot
    Assert-Log (@($shellSnapshot.Events | Where-Object {$_.sessionId -eq $abortedId -and $_.code -eq 'SessionInterrupted'}).Count -eq 1) 'Ctrl+C in surviving shell was not detected'
    Assert-Log (@($shellSnapshot.Sessions | Where-Object {$_.sessionId -eq $abortedId -and $_.status -eq 'interrupted'}).Count -eq 1) 'Aborted menu remained active'
    Complete-ZapretLogOperation
    # Abrupt process exit is recognized on the next initialization.
    $crashRoot=Join-Path $fixture 'Crash install'
    $testProcess=Start-Process powershell.exe -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -Child Crash -Root "'+$crashRoot+'"') -WindowStyle Hidden -PassThru
    Assert-Log ($testProcess.WaitForExit(15000) -and $testProcess.ExitCode -eq 91) 'Crash fixture failed'
    New-LogTestSession $crashRoot
    Assert-Log (@((Get-ZapretLogSnapshot $crashRoot).Events | Where-Object code -eq 'OperationInterrupted').Count -eq 1) 'Interrupted operation missing'
    # Simulate disk-full at the real append boundary; logging must never throw.
    $implementation=${function:Add-ZapretLogEventLocked}
    function Add-ZapretLogEventLocked { throw [IO.IOException]::new('Disk full') }
    Write-ZapretLogEvent
    Assert-Log ($env:ZAPRET_LOG_DISABLED -eq '1') 'Writer failure not isolated'
    ${function:Add-ZapretLogEventLocked}=$implementation
    Complete-ZapretLogOperation
    New-LogTestSession $crashRoot
    $holder=Start-Process powershell.exe -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -Child Hold -Root "'+$crashRoot+'" -Session '+$script:ZapretLog.Id) -WindowStyle Hidden -PassThru
    $null=$holder.Handle; $timer=[Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path (Join-Path $crashRoot 'gate-ready'))) { if ($timer.Elapsed.TotalSeconds -gt 10) { throw 'Holder did not start' }; Start-Sleep -Milliseconds 20 }
    try {
        Write-ZapretLogEvent -Details @{count=654321}
        Assert-Log ($env:ZAPRET_LOG_DISABLED -ne '1') 'Normal contention disabled the journal'
        Assert-Log (@((Get-ZapretLogSnapshot $crashRoot).Events | Where-Object {$_.details.Contains('count') -and $_.details['count'] -eq 654321}).Count -eq 1) 'Queued event missing from live export'
    }
    finally { [IO.File]::WriteAllText((Join-Path $crashRoot 'gate-release'),'release'); $null=$holder.WaitForExit(10000) }
    $queued=@((Get-ZapretLogSnapshot $crashRoot).Events | Where-Object {$_.details.Contains('count') -and $_.details['count'] -eq 654321})[0]
    Save-ZapretLogPending $script:ZapretLog $queued
    Write-ZapretLogEvent
    Assert-Log (@((Get-ZapretLogSnapshot $crashRoot).Events | Where-Object {$_.details.Contains('count') -and $_.details['count'] -eq 654321}).Count -eq 1) 'Recovered queue duplicated an event'
    Complete-ZapretLogOperation
    # Real locked metadata and event files must not alter the caller's outcome.
    New-LogTestSession $crashRoot
    $lockedFile=[IO.File]::Open((Join-Path $script:ZapretLog.Directory 'events.jsonl'),'Open','ReadWrite','None')
    try { Write-ZapretLogEvent; Assert-Log ($env:ZAPRET_LOG_DISABLED -eq '1') 'Locked log escaped isolation' } finally { $lockedFile.Dispose() }
    Complete-ZapretLogOperation
    $lockedId=$script:ZapretLog.Id
    $lockedFile=[IO.File]::Open((Join-Path $script:ZapretLog.Directory 'session.json'),'Open','ReadWrite','None')
    try {
        $env:ZAPRET_LOG_DISABLED=''
        Initialize-ZapretLog -Root $crashRoot -Component tests -Action Scan -SessionId $lockedId
        Assert-Log ($env:ZAPRET_LOG_DISABLED -eq '1') 'Unreadable metadata escaped isolation'
    } finally { $lockedFile.Dispose() }
    # A directory junction needs no symlink privilege and must also be excluded.
    New-LogTestSession $crashRoot
    $outsideDir=Join-Path $fixture 'Outside logs'; [IO.Directory]::CreateDirectory($outsideDir) | Out-Null
    [IO.File]::WriteAllText((Join-Path $outsideDir 'events.jsonl'),$private)
    $junction=Join-Path (Join-Path $crashRoot 'runtime\logs\sessions') ([guid]::NewGuid().ToString('N'))
    $created=$false
    try { New-Item -ItemType Junction -Path $junction -Target $outsideDir -ErrorAction Stop | Out-Null; $created=$true }
    catch { if ($RequireLinks) { throw }; Write-Host '[SKIP] Junction creation unavailable in this Windows token/sandbox.' }
    if ($created) {
        $text=Read-LogArchive (Export-ZapretSessionLogs -Root $crashRoot -Archive)
        Assert-Log (-not $text.Contains('PRIVATE_TOKEN_123')) 'Linked directory exported'
        [IO.Directory]::Delete($junction)
    }
    # Linked input directory must never be archived or traversed.
    New-LogTestSession $crashRoot
    $link=Join-Path $script:ZapretLog.Directory 'events.previous.jsonl'
    $outside=Join-Path $fixture 'outside.txt'; [IO.File]::WriteAllText($outside,$private)
    try {
        New-Item -ItemType SymbolicLink -Path $link -Target $outside -ErrorAction Stop | Out-Null
        $text=Read-LogArchive (Export-ZapretSessionLogs -Root $crashRoot -Archive)
        Assert-Log (-not $text.Contains('PRIVATE_TOKEN_123')) 'Linked file exported'
    } catch [UnauthorizedAccessException] { if ($RequireLinks) { throw }; Write-Host '[SKIP] Symlink creation requires elevation or Developer Mode.' }
    Complete-ZapretLogOperation
    Write-Host "[OK] Session journal: $checks checks." -ForegroundColor Green
} finally {
    $env:ZAPRET_LOG_DISABLED='';$env:ZAPRET_LOG_ROOT='';$env:ZAPRET_LOG_SESSION=''
    # Fixtures are retained for inspection, including crash and privacy cases.
}
