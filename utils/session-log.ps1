# Safe, bounded management journal. Never accepts arbitrary messages or command output.
# All public data passes the same allowlist on write AND on export.
if (-not (Get-Variable ZapretLog -Scope Script -ErrorAction SilentlyContinue)) { $script:ZapretLog = $null }
$script:ZapretLogVersion = 1
function Get-ZapretLogPaths([string]$Root) {
    $base = Join-Path ([IO.Path]::GetFullPath($Root)) 'runtime'
    @{ Base=(Join-Path $base 'logs'); Sessions=(Join-Path $base 'logs\sessions'); State=(Join-Path $base 'log-state'); Exports=(Join-Path $base 'logs\exports') }
}
function Assert-ZapretLogPath([string]$Root, [string]$Path) {
    $base = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe journal path.' }
    $current = $full
    while ($current -and $current.Length -ge $base.Length) {
        try {
            $attributes=[IO.File]::GetAttributes($current)
            if ($attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked journal path.' }
        } catch {
            $cause=$_.Exception
            while ($cause.InnerException) { $cause=$cause.InnerException }
            if ($cause -isnot [IO.FileNotFoundException] -and $cause -isnot [IO.DirectoryNotFoundException]) { throw }
        }
        $current = Split-Path -Parent $current
    }
    $full
}
function Write-ZapretLogJson([string]$Path, $Document) {
    $temp = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temp, (ConvertTo-Json -InputObject $Document -Depth 8 -Compress), [Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp, $Path, [NullString]::Value) } else { [IO.File]::Move($temp, $Path) }
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}
function Remove-ZapretLogTree([string]$Root, [string]$Path) {
    $null=Assert-ZapretLogPath $Root $Path
    foreach ($child in Get-ChildItem -LiteralPath $Path -Force) {
        $null=Assert-ZapretLogPath $Root $child.FullName
        if ($child.PSIsContainer) { Remove-ZapretLogTree $Root $child.FullName }
        else { Remove-Item -LiteralPath $child.FullName -Force }
    }
    Remove-Item -LiteralPath $Path -Force
}
function Read-ZapretLogJson([string]$Path) {
    $stream = [IO.FileStream]::new($Path, 'Open', 'Read', ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true)
    try { $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
}
function Enter-ZapretLogGate([string]$Root, [int]$TimeoutMilliseconds=1000, [string]$Scope='') {
    # Kernel waiters avoid starvation when several short-lived PowerShell
    # processes initialize at once. This gate is separate from the updater gate.
    $sha=[Security.Cryptography.SHA256]::Create()
    $identity=[IO.Path]::GetFullPath($Root).TrimEnd('\').ToUpperInvariant()
    if ($Scope) { $identity+='|'+$Scope }
    try { $key=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($identity))).Replace('-','') }
    finally { $sha.Dispose() }
    $mutex=[Threading.Mutex]::new($false,('Global\Zapret2Next-Journal-'+$key))
    try {
        $acquired=$false
        try { $acquired=$mutex.WaitOne($TimeoutMilliseconds) }
        catch {
            if ($_.Exception -is [Threading.AbandonedMutexException] -or $_.Exception.InnerException -is [Threading.AbandonedMutexException]) { $acquired=$true } else { throw }
        }
        if (-not $acquired) {
            if ($TimeoutMilliseconds -eq 0) { $mutex.Dispose(); return $null }
            throw [IO.IOException]::new('Journal is busy.')
        }
        return $mutex
    } catch { $mutex.Dispose(); throw }
}
function Exit-ZapretLogGate($Gate) {
    if ($Gate) { try { $Gate.ReleaseMutex() } finally { $Gate.Dispose() } }
}
function Show-ZapretLogWarning {
    if ($env:ZAPRET_LOG_DISABLED -eq '1') { return }
    $env:ZAPRET_LOG_DISABLED = '1'
    try {
        if ($script:ZapretLog) {
            $path = Join-Path $script:ZapretLog.State 'warning-shown'
            $warning = [IO.File]::Open($path, 'CreateNew', 'Write', 'None')
            $warning.Dispose()
        }
        [Console]::Error.WriteLine('[WARN] Session logging is unavailable. The requested operation will continue.')
    } catch {}
}
function Get-ZapretLogField($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    if ($Object -is [Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] }; return $null }
    $property=$Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}
function ConvertTo-ZapretSafeEvent($Event) {
    # Unknown fields and arbitrary strings are discarded, including ErrorRecord.Message.
    if ($Event.schemaVersion -ne 1 -or [string]$Event.sessionId -notmatch '^[a-f0-9]{32}$' -or
        [string]$Event.operationId -notmatch '^[a-f0-9]{32}$' -or
        [string]$Event.component -notin @('session','menu','update','service','engine','renderer','ipset','hosts','telegram','cache','support','wizard','voice','tests','diagnostics','logging') -or
        [string]$Event.action -notin @('Start','Finish','Check','Prepare','Apply','Recover','ReleaseMenu','ReadMenuChoice','SetSetting','ToggleCheck','Install','Refresh','Remove','Render','Validate','Launch','Update','Enable','Disable','Restart','Connect','Status','Diagnose','Menu','Export','Scan','Clear','Select','Restore','HTTP','Download','Checkpoint','Cleanup','Rollback') -or
        [string]$Event.stage -notin @('begin','end','result','request','retry','validate','extract','settings','files','stop','start','restore','rollback','cleanup','interrupted','truncated','selection','snapshot','handoff','ready','render') -or
        [string]$Event.result -notin @('started','ok','error','warning','canceled','interrupted','available','current','unavailable','running','stopped','absent','pending','saved','applied','deferred') -or
        [string]$Event.code -notin @('None','OperationFailed','OperationCanceled','OperationInterrupted','SessionInterrupted','JournalTruncated','JournalUnavailable','ExportIncomplete','HTTPFailed','DownloadRetry','UpdateFailed','RollbackFailed','CleanupPending','NativeFailed','InvalidSelection','StateObserved','SettingsSaved','SettingsApplied','SettingsDeferred')) { return $null }
    $date = [datetime]::MinValue
    if ($Event.utc -is [datetime]) { $date=[datetime]$Event.utc }
    elseif (-not [datetime]::TryParse([string]$Event.utc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$date)) { return $null }
    $safe = [ordered]@{ schemaVersion=1; utc=$date.ToUniversalTime().ToString('o'); sessionId=[string]$Event.sessionId
        operationId=[string]$Event.operationId; component=[string]$Event.component; action=[string]$Event.action
        stage=[string]$Event.stage; result=[string]$Event.result; code=[string]$Event.code }
    $eventId=Get-ZapretLogField $Event 'eventId'
    if ($eventId) {
        if ([string]$eventId -notmatch '^[a-f0-9]{32}$') { return $null }
        $safe.eventId=[string]$eventId
    }
    $details = [ordered]@{}
    $sourceDetails=Get-ZapretLogField $Event 'details'
    $pairs=@{}
    if ($sourceDetails -is [Collections.IDictionary]) { foreach ($key in $sourceDetails.Keys) { $pairs[[string]$key]=$sourceDetails[$key] } }
    elseif ($sourceDetails -is [pscustomobject]) { foreach ($property in $sourceDetails.PSObject.Properties) { $pairs[$property.Name]=$property.Value } }
    foreach ($key in $pairs.Keys) {
        $value=$pairs[$key]
        if ($key -in @('durationMs','exitCode','httpCode','curlCode','attempt','count','line','hresult','nativeErrorCode','bytes','port')) {
            $number=[long]0
            if ([long]::TryParse([string]$value,[ref]$number)) { $details[$key]=$number }
        } elseif ($key -in @('etagSent','etagReceived','truncated','autoCheck','statePreserved','serviceRestored')) {
            if ($value -is [bool]) { $details[$key]=[bool]$value }
        } elseif ($key -in @('version','fromVersion','toVersion','engineVersion','windowsVersion')) {
            if ([string]$value -match '^\d{1,5}(?:\.\d{1,5}){1,3}(?:-(?:alpha|beta|rc)(?:[.\d-])*)?$') { $details[$key]=[string]$value }
        } elseif ($key -in @('game','ipset','voice','discordFake','gameFake','oldValue','newValue')) {
            if ([string]$value -in @('off','tcp','udp','all','loaded','none','any','standard','compatible','current','steam','google','dbank-v2','enabled','disabled')) { $details[$key]=[string]$value }
        } else {
            $allowed=switch -Exact ($key) {
                'setting' { @('game_filter.mode','ipset_filter.mode','voice_filter.mode','discord_fake.mode','game_fake.mode','check_updates.enabled','fake-defaults') }
                'preset' {
                    $knownPresets=@('general','ALT','ALT3','ALT5','ALT11','ALT12','ALT13','EXP','FAKE TLS AUTO ALT2','NEXT SAFE','NEXT BALANCED','VOICE','CUSTOM SAFE','CUSTOM BALANCED','CUSTOM UNIVERSAL','CUSTOM')
                    # Local names are arbitrary user input, including when a
                    # preset exists. Keep them out of sendable logs and do not
                    # depend on templates still being present during recovery.
                    if ([string]$value -cnotin $knownPresets) { $value='CUSTOM' }
                    $knownPresets
                }
                'item' { @('bin','lua','presets','strategies','utils','docs','.service','README.md','LICENSE.txt','SECURITY.md','THIRD_PARTY_NOTICES.md','ENGINE_VERSION','SHA256SUMS.txt','service.bat') }
                'exceptionType' { @('IOException','UnauthorizedAccessException','InvalidOperationException','ArgumentException','Exception','MethodInvocationException','RuntimeException','OperationCanceledException','TimeoutException','Win32Exception','FileNotFoundException','DirectoryNotFoundException','InvalidDataException','CommandNotFoundException','ParseException','WebException') }
                'script' { @('service.bat','run-preset.bat','manage-service.ps1','service-control.ps1','render-config.ps1','invoke-winws.ps1','update-ipset.ps1','prepare-hosts.ps1','manage-telegram.ps1','telegram-control.ps1','clear-discord-cache.ps1','support-diagnostics.ps1','support-diagnostics-core.ps1','compatibility-wizard.ps1','compatibility-wizard-main.ps1','discord-voice-diagnostic.ps1','test-presets.ps1','update-release.ps1','update-release-core.ps1','update-release-state.ps1','session-log.ps1','manage-logs.ps1','validate.ps1','menu.ps1','menu-input.ps1','menu-settings.ps1','release-info.ps1','run-preset.ps1','engine-control.ps1') }
                'telegramState' { @('RUNNING','STOPPED','DISABLED','ERROR','OTHER_FOLDER','PORT_CONFLICT','UNMANAGED','CONFIG_MISSING') }
                'supportCode' { @('EnvironmentReadFailed','OperationBusy','EngineStartFailed','ScanFailed','Canceled','EngineCleanupFailed','ServiceRestoreFailed','StateChanged','StateReadFailed','EnvironmentBlocked','DNSResolutionFailed') }
                'fileOperation' { @('backup','install','restore') }
                'asset' { @('checksum','archive') }
                default { @() }
            }
            if ([string]$value -cin $allowed) { $details[$key]=[string]$value }
            elseif ($key -ceq 'selection' -and $value -is [int] -and $value -in @((0..15) + 111 + 255)) { $details.selection=[int]$value }
        }
    }
    $orderedDetails=[ordered]@{}
    foreach ($key in @($details.Keys | Sort-Object)) { $orderedDetails[$key]=$details[$key] }
    $safe.details=$orderedDetails
    [pscustomobject]$safe
}
function Add-ZapretLogEventLocked($Context, $Event) {
    if (-not (Get-ZapretLogField $Event 'eventId')) {
        $Event | Add-Member -NotePropertyName eventId -NotePropertyValue ([guid]::NewGuid().ToString('N')) -Force
    }
    $event = ConvertTo-ZapretSafeEvent $Event
    if (-not $event) { return }
    $path = Assert-ZapretLogPath $Context.Root (Join-Path $Context.Directory 'events.jsonl')
    # Two 3 MiB segments, a <=2 MiB queue and <=900 KiB summary stay below 10 MiB.
    $line = (ConvertTo-Json -InputObject $event -Depth 8 -Compress) + "`r`n"
    if ([IO.File]::Exists($path) -and (Get-Item -LiteralPath $path).Length + [Text.Encoding]::UTF8.GetByteCount($line) -gt 3MB) {
        $previous = Assert-ZapretLogPath $Context.Root (Join-Path $Context.Directory 'events.previous.jsonl')
        if ([IO.File]::Exists($previous)) { [IO.File]::Delete($previous) }
        [IO.File]::Move($path, $previous)
        $event.stage='truncated'; $event.result='warning'; $event.code='JournalTruncated'; $event.details=[ordered]@{truncated=$true}; $event.eventId=[guid]::NewGuid().ToString('N')
        [IO.File]::AppendAllText($path, ((ConvertTo-Json $event -Depth 8 -Compress) + "`r`n"), [Text.UTF8Encoding]::new($false))
    }
    [IO.File]::AppendAllText($path, $line, [Text.UTF8Encoding]::new($false))
}
function Save-ZapretLogPending($Context, $Event) {
    $safe=ConvertTo-ZapretSafeEvent $Event
    if (-not $safe) { return }
    $gate=Enter-ZapretLogGate $Context.Root 1000 ('queue-'+$Context.Id)
    try {
        $files=@(Get-ChildItem -LiteralPath $Context.State -Filter 'pending-*.jsonl' -File | Sort-Object CreationTimeUtc)
        $size=[long]0
        foreach ($file in $files) { $null=Assert-ZapretLogPath $Context.Root $file.FullName; $size+=$file.Length }
        $line=(ConvertTo-Json $safe -Depth 8 -Compress)+"`r`n"
        $bytes=[Text.Encoding]::UTF8.GetByteCount($line)
        $truncated=$false
        foreach ($file in $files) {
            if ($size+$bytes+2048 -le 2MB) { break }
            try { [IO.File]::Delete($file.FullName); $size-=$file.Length; $truncated=$true } catch {}
        }
        if ($size+$bytes+2048 -gt 2MB) { throw [IO.IOException]::new('Journal queue is full.') }
        $writer=[IO.Path]::GetFileNameWithoutExtension($Context.Lease)
        $path=Assert-ZapretLogPath $Context.Root (Join-Path $Context.State ('pending-'+$writer+'.jsonl'))
        if ($truncated) {
            $safe.stage='truncated'; $safe.result='warning'; $safe.code='JournalTruncated'; $safe.details=@{truncated=$true}; $safe.eventId=[guid]::NewGuid().ToString('N')
            [IO.File]::AppendAllText($path,((ConvertTo-Json $safe -Depth 8 -Compress)+"`r`n"),[Text.UTF8Encoding]::new($false))
        }
        [IO.File]::AppendAllText($path,$line,[Text.UTF8Encoding]::new($false))
    } finally { Exit-ZapretLogGate $gate }
}
function Flush-ZapretLogPendingLocked($Context) {
    $claims=@(); $gate=Enter-ZapretLogGate $Context.Root 1000 ('queue-'+$Context.Id)
    try {
        foreach ($file in Get-ChildItem -LiteralPath $Context.State -Filter 'pending-*.jsonl' -File) {
            $null=Assert-ZapretLogPath $Context.Root $file.FullName
            if ($file.Name -notmatch '^pending-[a-f0-9]{32}(?:\.drain-[a-f0-9]{32})?\.jsonl$') { continue }
            if ($file.Name -match '\.drain-') { $claims+=$file.FullName; continue }
            $claim=$file.FullName.Substring(0,$file.FullName.Length-6)+'.drain-'+[guid]::NewGuid().ToString('N')+'.jsonl'
            [IO.File]::Move($file.FullName,$claim); $claims+=$claim
        }
    } finally { Exit-ZapretLogGate $gate }
    foreach ($path in $claims) {
        if (-not [IO.File]::Exists($path)) { continue }
        foreach ($line in [IO.File]::ReadAllLines($path)) {
            try { $event=ConvertTo-ZapretSafeEvent ($line | ConvertFrom-Json) } catch { continue }
            if ($event -and $event.sessionId -ceq $Context.Id) { Add-ZapretLogEventLocked $Context $event }
        }
        $gate=Enter-ZapretLogGate $Context.Root 1000 ('queue-'+$Context.Id)
        try { [IO.File]::Delete($path) } finally { Exit-ZapretLogGate $gate }
    }
}
function Write-ZapretLogEvent {
    param([string]$Component='', [string]$Action='', [string]$Stage='result', [string]$Result='ok', [string]$Code='None', $Details=@{}, [string]$OperationId='')
    if (-not $script:ZapretLog -or $env:ZAPRET_LOG_DISABLED -eq '1') { return }
    $gate=$null
    try {
        $ctx=$script:ZapretLog
        if (-not $Component) { $Component=$ctx.Component }; if (-not $Action) { $Action=$ctx.Action }
        if (-not $OperationId) { $OperationId=$ctx.OperationId }
        $event=[pscustomobject]@{schemaVersion=1;eventId=[guid]::NewGuid().ToString('N');utc=[datetime]::UtcNow.ToString('o');sessionId=$ctx.Id;operationId=$OperationId;component=$Component;action=$Action;stage=$Stage;result=$Result;code=$Code;details=$Details}
        $gate=Enter-ZapretLogGate $ctx.Root 0
        if (-not $gate) { Save-ZapretLogPending $ctx $event; return }
        Flush-ZapretLogPendingLocked $ctx
        Add-ZapretLogEventLocked $ctx $event
    } catch { Show-ZapretLogWarning } finally { if ($gate) { Exit-ZapretLogGate $gate } }
}
function Invoke-ZapretLoggedOperation {
    param([string]$Root,[string]$Component,[string]$Action,[scriptblock]$Body)
    $previous=$script:ZapretLog
    $failed=$false
    try {
        Initialize-ZapretLog -Root $Root -Component $Component -Action $Action
        & $Body
    } catch { $failed=$true; Write-ZapretLogException $_; throw }
    finally {
        Complete-ZapretLogOperation -ExitCode $(if ($failed) {1} else {0})
        $script:ZapretLog=$previous
    }
}
function Write-ZapretLogSettingsSnapshot([string]$Root) {
    if (-not $script:ZapretLog -or $env:ZAPRET_LOG_DISABLED -eq '1') { return }
    $ctx=$script:ZapretLog; $gate=$null
    try {
        $events=[Collections.Generic.List[object]]::new()
        $defaults=@{'game_filter.mode'='off';'ipset_filter.mode'='loaded';'voice_filter.mode'='compatible';'discord_fake.mode'='current';'game_fake.mode'='current'}
        $details=@(foreach ($name in $defaults.Keys) {
            $path=Join-Path $Root ('utils\'+$name)
            $value=if ([IO.File]::Exists($path)) { [IO.File]::ReadAllText($path).Trim() } else {$defaults[$name]}
            @{setting=$name;newValue=$value}
        })+@(@{autoCheck=[IO.File]::Exists((Join-Path $Root 'utils\check_updates.enabled'))})
        foreach ($detail in $details) {
            $events.Add([pscustomobject]@{schemaVersion=1;eventId=[guid]::NewGuid().ToString('N');utc=[datetime]::UtcNow.ToString('o');sessionId=$ctx.Id;operationId=$ctx.OperationId;component=$ctx.Component;action='Status';stage='snapshot';result='saved';code='StateObserved';details=$detail})
        }
        $gate=Enter-ZapretLogGate $Root 0
        if ($gate) {
            Flush-ZapretLogPendingLocked $ctx
            foreach ($event in $events) { Add-ZapretLogEventLocked $ctx $event }
        } else { foreach ($event in $events) { Save-ZapretLogPending $ctx $event } }
    } catch { Show-ZapretLogWarning } finally { if ($gate) { Exit-ZapretLogGate $gate } }
}
function Write-ZapretLogException {
    param($Record, [string]$Code='OperationFailed', [switch]$Warning)
    if (-not $script:ZapretLog) { return }
    try {
    $canceled=$Record.Exception -is [OperationCanceledException]
    if (-not $Warning) { $script:ZapretLog.Result=if ($canceled) {'canceled'} else {'error'} }
    $exception=$Record.Exception
    while ($exception.InnerException) { $exception=$exception.InnerException }
    $details=@{exceptionType=$exception.GetType().Name;hresult=$exception.HResult}
    if ($exception -is [ComponentModel.Win32Exception]) { $details.nativeErrorCode=$exception.NativeErrorCode }
    if ($Record.InvocationInfo -and $Record.InvocationInfo.ScriptName) { $details.script=Split-Path -Leaf $Record.InvocationInfo.ScriptName; $details.line=$Record.InvocationInfo.ScriptLineNumber }
    Write-ZapretLogEvent -Result $(if ($Warning) {'warning'} elseif ($canceled) {'canceled'} else {'error'}) -Code $(if ($canceled) {'OperationCanceled'} else {$Code}) -Details $details
    } catch { Show-ZapretLogWarning }
}
function Test-ZapretLogLease($Lease) {
    try { $process=Get-Process -Id ([int]$Lease.processId) -ErrorAction Stop; return $process.StartTime.ToUniversalTime().Ticks -eq [long]$Lease.startedTicks }
    catch { return $false }
}
function Get-ZapretLogContext([string]$Root, [string]$Id) {
    $paths=Get-ZapretLogPaths $Root
    @{Root=$Root;Id=$Id;Directory=(Assert-ZapretLogPath $Root (Join-Path $paths.Sessions $Id));State=(Assert-ZapretLogPath $Root (Join-Path $paths.State $Id))}
}
function Close-ZapretPreviousMenuLocked([string]$Root, [string]$CurrentId, [int]$OwnerProcessId) {
    # CMD /K can survive Ctrl+C. A new invocation in that same shell proves
    # that its previous menu has ended, even though the shell PID is still live.
    $paths=Get-ZapretLogPaths $Root
    foreach ($dir in Get-ChildItem -LiteralPath $paths.Sessions -Directory | Where-Object { $_.Name -match '^[a-f0-9]{32}$' -and $_.Name -cne $CurrentId }) {
        $ctx=Get-ZapretLogContext $Root $dir.Name
        if (-not (Test-Path -LiteralPath $ctx.State)) { continue }
        foreach ($file in Get-ChildItem -LiteralPath $ctx.State -Filter '*.json' -File) {
            $null=Assert-ZapretLogPath $Root $file.FullName
            try { $lease=Read-ZapretLogJson $file.FullName } catch { continue }
            if ($lease.component -eq 'menu' -and $lease.action -eq 'Start' -and [int]$lease.processId -eq $OwnerProcessId) {
                Add-ZapretLogEventLocked $ctx ([pscustomobject]@{schemaVersion=1;utc=[datetime]::UtcNow.ToString('o');sessionId=$ctx.Id;operationId=[string]$lease.operationId;component='menu';action='Start';stage='interrupted';result='interrupted';code='SessionInterrupted';details=@{}})
                [IO.File]::Delete($file.FullName)
                $metaPath=Assert-ZapretLogPath $Root (Join-Path $ctx.Directory 'session.json')
                try { $meta=Read-ZapretLogJson $metaPath; $meta.status='interrupted'; Write-ZapretLogJson $metaPath $meta } catch {}
            }
        }
    }
}
function Update-ZapretLogRetentionLocked([string]$Root) {
    $paths=Get-ZapretLogPaths $Root
    $sessions=@(Get-ChildItem -LiteralPath $paths.Sessions -Directory -ErrorAction Stop | Where-Object Name -match '^[a-f0-9]{32}$' | Sort-Object CreationTimeUtc -Descending)
    $index=0
    foreach ($dir in $sessions) {
        $ctx=Get-ZapretLogContext $Root $dir.Name
        $null=Assert-ZapretLogPath $Root $dir.FullName
        $active=$false; $interrupted=$false
        if (Test-Path -LiteralPath $ctx.State) {
            foreach ($file in Get-ChildItem -LiteralPath $ctx.State -Filter '*.json' -File) {
                $null=Assert-ZapretLogPath $Root $file.FullName
                try { $lease=Read-ZapretLogJson $file.FullName } catch { continue }
                if (Test-ZapretLogLease $lease) { $active=$true; continue }
                $interrupted=$true
                Add-ZapretLogEventLocked $ctx ([pscustomobject]@{schemaVersion=1;utc=[datetime]::UtcNow.ToString('o');sessionId=$dir.Name;operationId=[string]$lease.operationId;component=[string]$lease.component;action=[string]$lease.action;stage='interrupted';result='interrupted';code='OperationInterrupted';details=@{}})
                [IO.File]::Delete($file.FullName)
            }
        }
        $metaPath=Assert-ZapretLogPath $Root (Join-Path $dir.FullName 'session.json')
        try {
            $meta=Read-ZapretLogJson $metaPath
            if (-not $active -and $meta.status -eq 'active') { $meta.status=if ($interrupted) {'interrupted'} else {'completed'}; Write-ZapretLogJson $metaPath $meta }
        } catch {}
        if ($index -ge 5 -and -not $active) {
            # Never follow a link while deleting a journal tree.
            Remove-ZapretLogTree $Root $dir.FullName
            if (Test-Path -LiteralPath $ctx.State) {
                Remove-ZapretLogTree $Root $ctx.State
            }
        }
        $index++
    }
}
function Initialize-ZapretLog {
    param([string]$Root, [string]$Component, [string]$Action, [string]$SessionId='', [int]$OwnerProcessId=0, [string]$OperationId='')
    $script:ZapretLog=$null
    if ($env:ZAPRET_LOG_DISABLED -eq '1') { return }
    $gate=$null
    try {
        $Root=[IO.Path]::GetFullPath($Root).TrimEnd('\')
        # Staged renderer/engine helpers belong to the installed updater session.
        if ($Component -in @('renderer','engine') -and $env:ZAPRET_LOG_ROOT -and $Root.StartsWith($env:ZAPRET_LOG_ROOT.TrimEnd('\')+'\runtime\',[StringComparison]::OrdinalIgnoreCase)) { $Root=$env:ZAPRET_LOG_ROOT }
        $paths=Get-ZapretLogPaths $Root
        foreach ($path in @($paths.Base,$paths.Sessions,$paths.State,$paths.Exports)) { $null=Assert-ZapretLogPath $Root $path; [IO.Directory]::CreateDirectory($path) | Out-Null }
        if (-not $SessionId -and $env:ZAPRET_LOG_ROOT -eq $Root) { $SessionId=$env:ZAPRET_LOG_SESSION }
        $isNew=$false
        if ($SessionId -notmatch '^[a-f0-9]{32}$' -or -not (Test-Path -LiteralPath (Join-Path $paths.Sessions $SessionId) -PathType Container)) { $SessionId=[Guid]::NewGuid().ToString('N'); $isNew=$true }
        $ctx=Get-ZapretLogContext $Root $SessionId
        if ($OperationId -notmatch '^[a-f0-9]{32}$') { $OperationId=[Guid]::NewGuid().ToString('N') }
        $ctx.Component=$Component; $ctx.Action=$Action; $ctx.OperationId=$OperationId; $ctx.Result='ok'; $ctx.Timer=[Diagnostics.Stopwatch]::StartNew(); $ctx.Finished=$false; $ctx.IsNew=$isNew
        $script:ZapretLog=$ctx
        $gate=Enter-ZapretLogGate $Root 5000
        [IO.Directory]::CreateDirectory($ctx.Directory) | Out-Null
        [IO.Directory]::CreateDirectory($ctx.State) | Out-Null
        $metaPath=Assert-ZapretLogPath $Root (Join-Path $ctx.Directory 'session.json')
        $version='unknown'
        try { $candidate=[IO.File]::ReadAllText((Join-Path $Root '.service\version.txt')).Trim(); if ($candidate -match '^\d{1,5}\.\d{1,5}\.\d{1,5}(?:-(?:alpha|beta|rc)(?:[.\d-])*)?$') { $version=$candidate } } catch {}
        if (-not [IO.File]::Exists($metaPath)) { Write-ZapretLogJson $metaPath @{schemaVersion=1;sessionId=$SessionId;startedUtc=[datetime]::UtcNow.ToString('o');version=$version;status='active'} }
        else { $meta=Read-ZapretLogJson $metaPath; if ($meta.status -ne 'active') { $meta.status='active'; Write-ZapretLogJson $metaPath $meta } }
        if (-not $OwnerProcessId) { $OwnerProcessId=$PID }
        $owner=Get-Process -Id $OwnerProcessId -ErrorAction Stop
        $ctx.Lease=Assert-ZapretLogPath $Root (Join-Path $ctx.State ([guid]::NewGuid().ToString('N')+'.json'))
        Write-ZapretLogJson $ctx.Lease @{processId=$OwnerProcessId;startedTicks=$owner.StartTime.ToUniversalTime().Ticks;operationId=$ctx.OperationId;component=$Component;action=$Action}
        $env:ZAPRET_LOG_ROOT=$Root; $env:ZAPRET_LOG_SESSION=$SessionId
        if ($Component -eq 'menu' -and $Action -eq 'Start' -and $isNew) { Close-ZapretPreviousMenuLocked $Root $SessionId $OwnerProcessId }
        # Every fresh process audits stale leases. A persistent host can reuse
        # that audit until a session boundary, recovery or export needs it again.
        if ($isNew -or $script:ZapretLogMaintainedRoot -ne $Root -or $Action -in @('Start','Apply','Recover','Export')) {
            Update-ZapretLogRetentionLocked $Root
            $script:ZapretLogMaintainedRoot=$Root
        }
        Exit-ZapretLogGate $gate; $gate=$null
        $engineVersion=''
        try { $engineLine=[IO.File]::ReadAllLines((Join-Path $Root 'ENGINE_VERSION')) | Select-Object -First 1; if ($engineLine -match '^zapret2_version=(\d+(?:\.\d+)+)$') { $engineVersion=$matches[1] } } catch {}
        Write-ZapretLogEvent -Stage begin -Result started -Details @{version=$version;engineVersion=$engineVersion;windowsVersion=[Environment]::OSVersion.Version.ToString()}
    } catch { Show-ZapretLogWarning } finally { if ($gate) { Exit-ZapretLogGate $gate } }
}
function Complete-ZapretLogOperation {
    param([int]$ExitCode=0, [string]$Result='')
    if (-not $script:ZapretLog -or $script:ZapretLog.Finished) { return }
    $ctx=$script:ZapretLog
    if (-not $Result) { $Result=if ($ExitCode -eq 2 -and $ctx.Component -in @('support','wizard')) {'canceled'} elseif ($ExitCode -ne 0) {'error'} else {$ctx.Result} }
    Write-ZapretLogEvent -Stage end -Result $Result -Code $(if ($Result -eq 'error') {'OperationFailed'} elseif ($Result -eq 'canceled') {'OperationCanceled'} else {'None'}) -Details @{exitCode=$ExitCode;durationMs=[long]$ctx.Timer.ElapsedMilliseconds}
    $ctx.Finished=$true
    try {
        $gate=Enter-ZapretLogGate $ctx.Root 0
        if ($gate) { try { Flush-ZapretLogPendingLocked $ctx } finally { Exit-ZapretLogGate $gate } }
        if ($ctx.Lease) { [IO.File]::Delete($ctx.Lease) }
        if ($ctx.IsNew -and $ctx.Component -ne 'menu') {
            $gate=Enter-ZapretLogGate $ctx.Root
            try { Update-ZapretLogRetentionLocked $ctx.Root } finally { Exit-ZapretLogGate $gate }
            Save-ZapretSessionSummary $ctx.Root
        }
    } catch {}
}
function Close-ZapretLogMenu([switch]$Handoff, [int]$OwnerProcessId=0, [int]$ExitCode=0) {
    if (-not $script:ZapretLog) { return }
    $gate=$null
    try {
        $ctx=$script:ZapretLog; $gate=Enter-ZapretLogGate $ctx.Root
        if (-not $OwnerProcessId) { $OwnerProcessId=[int](Get-CimInstance Win32_Process -Filter "ProcessId=$PID").ParentProcessId }
        foreach ($file in Get-ChildItem -LiteralPath $ctx.State -Filter '*.json' -File) {
            $null=Assert-ZapretLogPath $ctx.Root $file.FullName
            $lease=Read-ZapretLogJson $file.FullName
            if ($lease.component -eq 'menu' -and $lease.action -eq 'Start' -and [int]$lease.processId -eq $OwnerProcessId) { [IO.File]::Delete($file.FullName) }
        }
    } catch { Show-ZapretLogWarning } finally { if ($gate) { Exit-ZapretLogGate $gate } }
    Write-ZapretLogEvent -Component menu -Action Finish -Stage $(if ($Handoff) {'handoff'} else {'end'}) -Result $(if ($ExitCode) {'error'} else {'ok'}) -Details @{exitCode=$ExitCode}
}
function Get-ZapretLogSnapshot([string]$Root) {
    $paths=Get-ZapretLogPaths $Root
    $events=[Collections.Generic.List[object]]::new(); $sessions=[Collections.Generic.List[object]]::new(); $skipped=0
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($dir in @(Get-ChildItem -LiteralPath $paths.Sessions -Directory | Where-Object Name -match '^[a-f0-9]{32}$' | Sort-Object CreationTimeUtc -Descending | Select-Object -First 5)) {
        try {
            $null=Assert-ZapretLogPath $Root $dir.FullName
            $meta=Read-ZapretLogJson (Assert-ZapretLogPath $Root (Join-Path $dir.FullName 'session.json'))
            $safeVersion=if ([string]$meta.version -match '^\d{1,5}\.\d{1,5}\.\d{1,5}(?:-(?:alpha|beta|rc)(?:[.\d-])*)?$') {[string]$meta.version} else {'unknown'}
            $safeStatus=if ($meta.status -in @('active','completed','interrupted')) {[string]$meta.status} else {'unknown'}
            $sessions.Add([pscustomobject]@{sessionId=$dir.Name;version=$safeVersion;status=$safeStatus})
            $pathsToRead=@('events.previous.jsonl','events.jsonl') | ForEach-Object { Join-Path $dir.FullName $_ }
            $state=Assert-ZapretLogPath $Root (Join-Path $paths.State $dir.Name)
            if (Test-Path -LiteralPath $state) {
                $pathsToRead+=@(Get-ChildItem -LiteralPath $state -Filter 'pending-*.jsonl' -File | Where-Object Name -match '^pending-[a-f0-9]{32}(?:\.drain-[a-f0-9]{32})?\.jsonl$' | ForEach-Object FullName)
            }
            foreach ($inputPath in $pathsToRead) {
                $path=Assert-ZapretLogPath $Root $inputPath
                if (-not [IO.File]::Exists($path)) { continue }
                $stream=[IO.FileStream]::new($path,'Open','Read',([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
                $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8,$true)
                try {
                    if ($stream.Length -gt 4MB+16KB) { $skipped++; continue }
                    while (-not $reader.EndOfStream) {
                        $line=$reader.ReadLine()
                        if ($line.Length -gt 8192) { $skipped++; continue }
                        try {
                            $safe=ConvertTo-ZapretSafeEvent ($line | ConvertFrom-Json)
                            if ($safe -and $safe.sessionId -ceq $dir.Name) {
                                $identity=Get-ZapretLogField $safe 'eventId'
                                if (-not $identity -or $seen.Add($dir.Name+':'+$identity)) { $events.Add($safe) }
                            } else { $skipped++ }
                        } catch { $skipped++ }
                    }
                } finally { $reader.Dispose() }
            }
        } catch { $skipped++ }
    }
    @{Sessions=@($sessions.ToArray());Events=@($events.ToArray() | Sort-Object utc);Skipped=$skipped}
}
function Write-ZapretLogSnapshot([string]$Root, [string]$Directory, $Snapshot) {
    foreach ($name in @('LOGS.txt','events.jsonl','manifest.json')) { $null=Assert-ZapretLogPath $Root (Join-Path $Directory $name) }
    [IO.Directory]::CreateDirectory($Directory) | Out-Null
    $encoding=[Text.UTF8Encoding]::new($false)
    $json=[Collections.Generic.List[string]]::new(); $text=[Collections.Generic.List[string]]::new()
    $text.Add('Zapret 2 NEXT — management sessions (UTC). No traffic or raw command output.')
    $text.Add("Sessions: $($Snapshot.Sessions.Count); skipped records: $($Snapshot.Skipped)")
    foreach ($e in $Snapshot.Events) {
        $json.Add((ConvertTo-Json $e -Depth 8 -Compress))
        $text.Add("$($e.utc) [$($e.result)] $($e.component)/$($e.action)/$($e.stage) $($e.code) session=$($e.sessionId) operation=$($e.operationId) " + (ConvertTo-Json $e.details -Compress))
    }
    [IO.File]::WriteAllLines((Join-Path $Directory 'events.jsonl'), $json.ToArray(), $encoding)
    [IO.File]::WriteAllLines((Join-Path $Directory 'LOGS.txt'), $text.ToArray(), $encoding)
    Write-ZapretLogJson (Join-Path $Directory 'manifest.json') @{schema='zapret2-next.session-logs';schemaVersion=1;createdUtc=[datetime]::UtcNow.ToString('o');sessions=$Snapshot.Sessions;skippedRecords=$Snapshot.Skipped;truncated=(@($Snapshot.Events | Where-Object code -eq 'JournalTruncated').Count -gt 0);errorCount=(@($Snapshot.Events | Where-Object result -eq 'error').Count)}
}
function Save-ZapretSessionSummary([string]$Root, $Snapshot=$null) {
    if (-not $script:ZapretLog) { return }
    try {
        if (-not $Snapshot) { $Snapshot=Get-ZapretLogSnapshot $Root }
        $ctx=$script:ZapretLog
        $lines=@($snapshot.Events | Where-Object sessionId -eq $ctx.Id | Select-Object -Last 1500 | ForEach-Object { "$($_.utc) [$($_.result)] $($_.component)/$($_.action)/$($_.stage) $($_.code) " + (ConvertTo-Json $_.details -Compress) })
        $path=Assert-ZapretLogPath $Root (Join-Path $ctx.Directory 'SESSION.txt')
        $bounded=[Collections.Generic.List[string]]::new(); $size=0
        foreach ($line in $lines) { $size += [Text.Encoding]::UTF8.GetByteCount($line)+2; if ($size -gt 900KB) { break }; $bounded.Add($line) }
        [IO.File]::WriteAllLines($path, $bounded.ToArray(), [Text.UTF8Encoding]::new($false))
    } catch { Show-ZapretLogWarning }
}
function Export-ZapretSessionLogs {
    param([string]$Root, [string]$Directory='', [switch]$Archive)
    $paths=Get-ZapretLogPaths $Root; $gate=$null
    try {
        $gate=Enter-ZapretLogGate $Root
        Update-ZapretLogRetentionLocked $Root
    } catch { Write-ZapretLogException $_ -Code ExportIncomplete -Warning }
    finally { if ($gate) { Exit-ZapretLogGate $gate } }
    # Readers share deletion/rotation. Never hold the writers' gate while
    # parsing or compressing a potentially 40 MiB snapshot.
    $snapshot=Get-ZapretLogSnapshot $Root
    if (-not $Directory) { $Directory=Join-Path $paths.Exports ('logs-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8)) }
    $null=Assert-ZapretLogPath $Root $Directory
    Write-ZapretLogSnapshot $Root $Directory $snapshot
    Save-ZapretSessionSummary $Root $snapshot
    if (-not $Archive) { return $Directory }
    $zip=$Directory+'.zip'
    Compress-Archive -LiteralPath @((Join-Path $Directory 'LOGS.txt'),(Join-Path $Directory 'events.jsonl'),(Join-Path $Directory 'manifest.json')) -DestinationPath $zip -CompressionLevel Optimal
    try {
    foreach ($old in @(Get-ChildItem -LiteralPath $paths.Exports -Filter 'logs-*.zip' -File | Sort-Object CreationTimeUtc -Descending | Select-Object -Skip 5)) {
        $oldPath=Assert-ZapretLogPath $Root $old.FullName
        [IO.File]::Delete($oldPath)
        $oldDir=$oldPath.Substring(0,$oldPath.Length-4)
        if (Test-Path -LiteralPath $oldDir) {
            Remove-ZapretLogTree $Root $oldDir
        }
    }
    } catch { Write-ZapretLogException $_ -Code ExportIncomplete -Warning }
    $zip
}
