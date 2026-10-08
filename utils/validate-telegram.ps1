# Offline lifecycle checks. All scheduler, CIM, socket and launch operations are
# mocked before any Telegram action; no real task, process or Telegram is changed.
$ErrorActionPreference = 'Stop'
$bundleRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'telegram-control.ps1')
$runtimeAccessImplementation = ${function:Set-ZapretTelegramRuntimeAccess}
$identityImplementation = ${function:Get-ZapretTelegramIdentity}
$script:testSID = 'S-1-5-21-100-200-300-1001'
$fixture = Join-Path $bundleRoot ('runtime\telegram-tests-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
$checks = 0

function Assert-Telegram([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function Assert-TelegramRejected([scriptblock]$Operation, [string]$Message) {
    $rejected = $false
    try { & $Operation | Out-Null } catch { $rejected = $true }
    Assert-Telegram $rejected $Message
}

function Get-ZapretTelegramIdentity {
    if ($script:identityBroken) { throw 'Injected desktop identity access failure' }
    return $script:testSID
}
function Get-ZapretTelegramCurrentIdentity { return $script:processSID }
function Get-ZapretTelegramShellProcessId { return $script:shellProcessId }
function Get-ZapretTelegramSessionId { return 7 }
function Set-ZapretTelegramRuntimeAccess { param($Context); $script:aclSID=$Context.SID; $script:aclCalls++ }
function Set-Acl { param($LiteralPath, $AclObject); $script:capturedAcl=$AclObject }
function Get-ScheduledTask { param($TaskPath); return @($script:fakeTask, $script:fakeConnectTask) | Where-Object { $_ } }
function Export-ScheduledTask { param($TaskName, $TaskPath); return 'previous-task-xml' }
function New-ScheduledTaskAction {
    param($Execute, $Argument, $WorkingDirectory)
    return [pscustomobject]@{ Execute=$Execute; Arguments=$Argument; WorkingDirectory=$WorkingDirectory }
}
function New-ScheduledTaskTrigger { param([switch]$AtLogOn, $User); return [pscustomobject]@{ AtLogOn=[bool]$AtLogOn; User=$User } }
function New-ScheduledTaskPrincipal {
    param($UserId, $LogonType, $RunLevel)
    return [pscustomobject]@{ UserId=$UserId; LogonType=$LogonType; RunLevel=$RunLevel }
}
function New-ScheduledTaskSettingsSet {
    param($ExecutionTimeLimit, $RestartCount, $RestartInterval, [switch]$StartWhenAvailable, [switch]$AllowStartIfOnBatteries, [switch]$DontStopIfGoingOnBatteries, $MultipleInstances)
    return [pscustomobject]@{ ExecutionTimeLimit=$ExecutionTimeLimit; RestartCount=$RestartCount; RestartInterval=$RestartInterval; MultipleInstances=$MultipleInstances }
}
function New-ScheduledTask {
    param($Action, $Trigger, $Principal, $Settings, $Description)
    # The native CIM constructor normalizes SID to an account name. Production
    # must restore the raw SID on the final task before registration.
    $Principal.UserId = 'constructor-normalized-name'
    return [pscustomobject]@{ Actions=@($Action); Triggers=@($Trigger); Principal=$Principal; Settings=$Settings; State='Ready' }
}
function Register-ScheduledTask {
    param($TaskName, $TaskPath, $InputObject, $Xml, [switch]$Force)
    if ($TaskName.EndsWith('-Connect')) {
        $script:events.Add('connect-register')
        $InputObject | Add-Member -NotePropertyName TaskName -NotePropertyValue $TaskName
        $script:fakeConnectTask = $InputObject
        $script:registeredConnectTask = $InputObject
        if ($script:failConnectRegistration) { $script:failConnectRegistration=$false; throw 'Injected partial connect registration failure' }
        return
    }
    if ($Xml) {
        $script:events.Add('restore')
        $script:fakeTask = $script:previousTask
    } else {
        $script:events.Add('register')
        $InputObject | Add-Member -NotePropertyName TaskName -NotePropertyValue $TaskName
        $script:fakeTask = $InputObject
        if ($script:failRegistration) { $script:failRegistration = $false; throw 'Injected partial registration failure' }
    }
}
function Start-ScheduledTask {
    param($TaskName, $TaskPath)
    if ($TaskName.EndsWith('-Connect')) {
        $script:events.Add('connect-start')
        $script:connectLastRunTime = [DateTime]::UtcNow
        if ($script:failConnectStart) { throw 'Injected connect startup failure' }
        $script:fakeConnectTask.State = 'Ready'
        return
    }
    $script:events.Add('start')
    if ($script:failStart) { $script:failStart = $false; throw 'Injected startup failure' }
    $script:fakeTask.State = 'Running'
    $ctx = Get-ZapretTelegramContext $script:testRoot
    $config = Read-ZapretTelegramConfig $ctx
    $script:fakeProcesses += [pscustomobject]@{ ProcessId=1234; ExecutablePath=$ctx.Executable; CommandLine=('"' + $ctx.Executable + '" ' + (Get-ZapretTelegramArguments $ctx)) }
    $script:fakeListeners += [pscustomobject]@{ LocalPort=$config.port; LocalAddress='127.0.0.1'; OwningProcess=1234 }
}
function Stop-ScheduledTask {
    param($TaskName, $TaskPath)
    if ($TaskName.EndsWith('-Connect')) { $script:events.Add('connect-stop'); $script:fakeConnectTask.State='Ready'; return }
    $script:events.Add('stop')
    $script:fakeTask.State = 'Ready'
    if (-not $script:leaveProcess) {
        $script:fakeProcesses = @($script:fakeProcesses | Where-Object { $_.ProcessId -ne 1234 })
        $script:fakeListeners = @($script:fakeListeners | Where-Object { $_.OwningProcess -ne 1234 })
    }
}
function Unregister-ScheduledTask {
    param($TaskName, $TaskPath, [switch]$Confirm)
    if ($TaskName.EndsWith('-Connect')) { $script:events.Add('connect-unregister'); $script:fakeConnectTask=$null; return }
    $script:events.Add('unregister'); $script:fakeTask=$null
}
function Get-ScheduledTaskInfo {
    param($TaskName, $TaskPath)
    if ($TaskName.EndsWith('-Connect')) { return [pscustomobject]@{ LastTaskResult=$script:connectResult; LastRunTime=$script:connectLastRunTime } }
    return [pscustomobject]@{ LastTaskResult=7 }
}
function Get-CimInstance {
    param($ClassName, $Filter)
    if ($script:shellProcessId -and $Filter -eq ("ProcessId=" + $script:shellProcessId)) { return $script:shellProcess }
    if ($Filter -match '^ProcessId=(\d+)$') { return $script:fakeProcesses | Where-Object { $_.ProcessId -eq [int]$Matches[1] } }
    return $script:fakeProcesses
}
function Invoke-CimMethod {
    param($InputObject, $MethodName)
    if ($MethodName -eq 'GetOwnerSid') { return [pscustomobject]@{ ReturnValue=$script:shellOwnerResult; Sid=$script:shellOwnerSID } }
    $script:terminated.Add([int]$InputObject.ProcessId)
    $script:fakeProcesses = @($script:fakeProcesses | Where-Object { $_.ProcessId -ne $InputObject.ProcessId })
    $script:fakeListeners = @($script:fakeListeners | Where-Object { $_.OwningProcess -ne $InputObject.ProcessId })
    return [pscustomobject]@{ ReturnValue=0 }
}
function Get-NetTCPConnection { param($State); return $script:fakeListeners }
function Test-ZapretTelegramFreePort { param([int]$Port); return -not (@($script:fakeListeners | Where-Object { $_.LocalPort -eq $Port }).Count) }
function Start-Sleep { param($Milliseconds) }
function Start-Process { param($FilePath); $script:openedUri=$FilePath }
function Start-ZapretTelegramDiagnosticProcess {
    param($Context, [string]$Report)
    $script:diagnosticReport = $Report
    if ($script:diagnosticMode -eq 'failure') {
        [IO.File]::WriteAllText($Report, '{"ok":false,"error":"RuntimeError","message":"fixture failure"}')
    } else {
        [IO.File]::WriteAllText($Report, '{"module_version":"1","host":"127.0.0.1","port":1443,"direct_ws":[{"dc":2,"media":false,"available":true,"route":"direct"},{"dc":4,"media":true,"available":false}],"cfproxy":{"enabled":true,"available":false,"sample_only":true}}')
    }
    if ($script:diagnosticMode -eq 'timeout') {
        $command = '"' + $Context.Executable + '" --diagnose ' + (Get-ZapretTelegramArguments $Context) + ' --output "' + $Report + '"'
        $script:fakeProcesses += [pscustomobject]@{ ProcessId=8100; ExecutablePath=$Context.Executable; CommandLine=$command }
        $script:fakeProcesses += [pscustomobject]@{ ProcessId=8101; ExecutablePath=$Context.Executable; CommandLine=$command }
    }
    $fake = [pscustomobject]@{ ExitCode=0; HasExited=($script:diagnosticMode -ne 'timeout') }
    $fake | Add-Member ScriptMethod WaitForExit { param($Milliseconds); return $this.HasExited }
    $fake | Add-Member ScriptMethod Refresh { }
    $fake | Add-Member ScriptMethod Kill { $this.HasExited=$true }
    $fake | Add-Member ScriptMethod Dispose { $script:diagnosticDisposed=$true }
    return $fake
}

function Reset-TelegramFixture {
    $script:events = New-Object 'Collections.Generic.List[string]'
    $script:terminated = New-Object 'Collections.Generic.List[int]'
    $script:fakeTask = $null
    $script:fakeConnectTask = $null
    $script:registeredConnectTask = $null
    $script:connectLastRunTime = [DateTime]::MinValue
    $script:connectResult = 0
    $script:failConnectRegistration = $false
    $script:failConnectStart = $false
    $script:previousTask = $null
    $script:fakeProcesses = @()
    $script:fakeListeners = @()
    $script:failRegistration = $false
    $script:failStart = $false
    $script:leaveProcess = $false
    $script:openedUri = ''
    $script:aclSID = ''
    $script:aclCalls = 0
    $script:diagnosticMode = 'success'
    $script:diagnosticDisposed = $false
    $script:diagnosticReport = ''
    $script:processSID = $script:testSID
    $script:shellProcessId = 0
    $script:shellProcess = $null
    $script:shellOwnerResult = 0
    $script:shellOwnerSID = $script:testSID
    $script:identityBroken = $false
    # Spaces and Unicode exercise Windows quoting without requiring a real EXE.
    $script:testRoot = Join-Path $fixture ('bundle space-' + [Guid]::NewGuid().ToString('N'))
    $context = Get-ZapretTelegramContext $script:testRoot
    New-Item -ItemType Directory -Path (Split-Path $context.Executable), $context.Runtime -Force | Out-Null
    [IO.File]::WriteAllText($context.Executable, 'offline executable fixture')
    $hash = (Get-FileHash -LiteralPath $context.Executable -Algorithm SHA256).Hash
    [IO.File]::WriteAllText($context.Manifest, $hash + '  zapret-telegram.exe')
    return $context
}

try {
    Write-Host 'Testing Telegram with mocked Windows operations; injected WARN messages are expected.' -ForegroundColor Cyan
    $context = Reset-TelegramFixture
    Assert-Telegram ((& $identityImplementation) -eq $processSID) 'Headless identity does not fall back to the process user'
    $script:shellProcessId = 4321
    $script:shellProcess = [pscustomobject]@{ ProcessId=4321; SessionId=7 }
    $script:processSID = 'S-1-5-21-100-200-300-500'
    Assert-Telegram ((& $identityImplementation) -eq $testSID) 'Elevated manager did not select the desktop shell owner'
    $script:shellProcess.SessionId = 8
    Assert-TelegramRejected { & $identityImplementation } 'Shell from another Windows session was accepted'
    $script:shellProcess.SessionId = 7
    $script:shellOwnerSID = 'not-a-SID'
    Assert-TelegramRejected { & $identityImplementation } 'Invalid shell owner SID was accepted'
    $script:shellOwnerSID = $testSID
    $script:shellOwnerResult = 2
    Assert-TelegramRejected { & $identityImplementation } 'Inaccessible desktop owner silently fell back to the admin user'
    $context = Reset-TelegramFixture
    $script:fakeListeners = @([pscustomobject]@{ LocalPort=1443; LocalAddress='0.0.0.0'; OwningProcess=8888 })
    Enable-ZapretTelegram $testRoot
    $config = Read-ZapretTelegramConfig $context
    Assert-Telegram ($config.port -eq 1444) 'Occupied default port did not select a free alternative'
    Assert-Telegram ($context.Config -eq (Join-Path $testRoot ('runtime\telegram\' + $context.SID + '\config.json'))) 'Config is not isolated by current user SID'
    Assert-Telegram ($aclSID -eq $context.SID) 'Runtime was not prepared for the limited user token'
    Assert-Telegram ($config.secret -cmatch '^[0-9a-f]{32}$' -and $config.cfproxy -eq $true) 'Generated config does not contain a strong secret and CF default'
    Assert-Telegram (Test-ZapretTelegramTaskOwner $context $fakeTask) 'Registered task does not belong to this bundle'
    Assert-Telegram ($fakeTask.Principal.LogonType -eq 'Interactive' -and $fakeTask.Principal.RunLevel -eq 'Limited') 'Task elevates or loses interactive user context'
    Assert-Telegram ($fakeTask.Triggers[0].AtLogOn -and $fakeTask.Triggers[0].User -eq $context.SID) 'Logon task is not scoped to current user'
    Assert-Telegram ($fakeTask.Settings.ExecutionTimeLimit -eq [TimeSpan]::Zero -and $fakeTask.Settings.RestartCount -eq 3) 'Task has a time limit or no recovery'
    & $runtimeAccessImplementation $context
    $accessRules = @($capturedAcl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
    Assert-Telegram ($capturedAcl.AreAccessRulesProtected -and $accessRules.Count -eq 3) 'Runtime ACL inherited permissions or added unrelated identities'
    $userRule = @($accessRules | Where-Object { $_.IdentityReference.Value -eq $context.SID })
    $modifyRights = [Security.AccessControl.FileSystemRights]::Modify -bor [Security.AccessControl.FileSystemRights]::Synchronize
    Assert-Telegram ($userRule.Count -eq 1 -and $userRule[0].FileSystemRights -eq $modifyRights) 'Limited task user lacks exact Modify runtime access'
    Assert-Telegram ((Get-ZapretTelegramStatus $testRoot -Compact) -eq 'RUNNING') 'Owned listener was not recognized as running'
    $status = Get-ZapretTelegramStatus $testRoot | ConvertTo-Json
    Assert-Telegram (-not $status.Contains($config.secret)) 'Status exposed the secret'
    $script:testSID = 'S-1-5-21-100-200-300-1002'
    $otherUserContext = Get-ZapretTelegramContext $testRoot
    Assert-Telegram ($otherUserContext.Config -ne $context.Config -and $otherUserContext.TaskName -ne $context.TaskName) 'Different Windows users share config or task'
    Assert-Telegram (-not (Test-ZapretTelegramProcessOwner $otherUserContext $fakeProcesses[0])) 'Another Windows user can claim this bridge process'
    $script:testSID = $context.SID
    Connect-ZapretTelegram $testRoot
    Assert-Telegram ($openedUri -eq ('tg://proxy?server=127.0.0.1&port=1444&secret=dd' + $config.secret)) 'Connect generated an incorrect MTProto link'
    Assert-Telegram (-not $events.Contains('connect-register')) 'Same-user Connect unnecessarily created a task'
    $script:processSID = 'S-1-5-21-100-200-300-500'
    $script:openedUri = ''
    Connect-ZapretTelegram $testRoot
    Assert-Telegram (-not $openedUri -and -not $fakeConnectTask) 'Cross-user Connect launched Telegram as admin or left its temporary task'
    Assert-Telegram ($registeredConnectTask.Principal.UserId -eq $context.SID -and $registeredConnectTask.Principal.RunLevel -eq 'Limited') 'Cross-user Connect used the wrong identity or elevation'
    Assert-Telegram ($registeredConnectTask.Actions[0].Arguments.Contains('-WindowStyle Hidden') -and $registeredConnectTask.Actions[0].Arguments.Contains('tg://proxy?server=127.0.0.1')) 'Cross-user Connect lacks hidden launch or proxy URI'
    Assert-Telegram ($registeredConnectTask.Settings.ExecutionTimeLimit -eq [TimeSpan]::FromSeconds(30)) 'Connect launcher has no bounded task lifetime'
    $script:failConnectRegistration = $true
    Assert-TelegramRejected { Connect-ZapretTelegram $testRoot } 'Partial connect-task registration failure was ignored'
    Assert-Telegram (-not $fakeConnectTask -and $fakeTask.State -eq 'Running') 'Connect registration rollback left a task or stopped the proxy'
    $script:failConnectStart = $true
    Assert-TelegramRejected { Connect-ZapretTelegram $testRoot } 'Connect task startup failure was ignored'
    Assert-Telegram (-not $fakeConnectTask -and $fakeTask.State -eq 'Running') 'Failed connect did not remove only its own temporary task'
    $script:failConnectStart = $false
    $script:fakeConnectTask = $registeredConnectTask
    $script:fakeConnectTask.Actions[0].WorkingDirectory = Join-Path $fixture 'foreign-connect-bundle'
    $script:events.Clear()
    Assert-TelegramRejected { Connect-ZapretTelegram $testRoot } 'Foreign connect task was overwritten'
    Assert-Telegram ($events.Count -eq 0 -and $fakeConnectTask) 'Foreign connect task was changed during rejection'
    $script:fakeConnectTask = $null
    Assert-TelegramRejected { Open-ZapretTelegramLink "tg://proxy?server=127.0.0.1&port=1443&secret=dd';Get-Process;'" $context } 'Connect accepted a command-injection URI'
    $script:processSID = $context.SID
    $before = [IO.File]::ReadAllText($context.Config)
    Disable-ZapretTelegram $testRoot
    Assert-Telegram (-not $fakeTask -and [IO.File]::ReadAllText($context.Config) -ceq $before) 'Disable did not preserve config and secret'
    Enable-ZapretTelegram $testRoot
    Assert-Telegram ([IO.File]::ReadAllText($context.Config) -ceq $before) 'Re-enable replaced the persistent secret or port'

    # A task from a different bundle must never be overwritten or stopped.
    $fakeTask.Actions[0].Execute = Join-Path $fixture 'another-bundle\zapret-telegram.exe'
    $script:events.Clear()
    Assert-TelegramRejected { Enable-ZapretTelegram $testRoot } 'Enable overwrote another bundle task'
    Assert-TelegramRejected { Disable-ZapretTelegram $testRoot } 'Disable stopped another bundle task'
    Assert-Telegram ($events.Count -eq 0 -and [IO.File]::ReadAllText($context.Config) -ceq $before) 'Foreign task rejection changed the task or config'
    Assert-Telegram ((Get-ZapretTelegramStatus $testRoot -Compact) -eq 'OTHER_FOLDER') 'Compact foreign-task status is wrong'

    $context = Reset-TelegramFixture
    Enable-ZapretTelegram $testRoot
    $before = [IO.File]::ReadAllText($context.Config)
    $script:previousTask = $script:fakeTask
    $script:failRegistration = $true
    Assert-TelegramRejected { Enable-ZapretTelegram $testRoot } 'Partial task registration failure was ignored'
    Assert-Telegram ($events.Contains('restore') -and (Get-ZapretTelegramStatus $testRoot -Compact) -eq 'RUNNING') 'Partial task registration did not restore the running task'
    Assert-Telegram ([IO.File]::ReadAllText($context.Config) -ceq $before) 'Task rollback changed the existing secret'
    $script:previousTask = $script:fakeTask
    $script:failStart = $true
    Assert-TelegramRejected { Restart-ZapretTelegram $testRoot } 'Failed restart was accepted'
    Assert-Telegram ((Get-ZapretTelegramStatus $testRoot -Compact) -eq 'RUNNING' -and [IO.File]::ReadAllText($context.Config) -ceq $before) 'Failed restart did not restore old config and task'

    # Foreign listeners on a saved port cannot silently change proxy settings.
    $config = Read-ZapretTelegramConfig $context
    $script:fakeProcesses = @([pscustomobject]@{ ProcessId=9999; ExecutablePath='C:\unrelated.exe'; CommandLine='unrelated' })
    $script:fakeListeners = @([pscustomobject]@{ LocalPort=$config.port; LocalAddress='127.0.0.1'; OwningProcess=9999 })
    $script:events.Clear()
    Assert-TelegramRejected { Enable-ZapretTelegram $testRoot } 'Occupied saved port was accepted'
    Assert-Telegram ($events.Count -eq 0 -and [IO.File]::ReadAllText($context.Config) -ceq $before) 'Port conflict mutated the task or config'
    Assert-Telegram ((Get-ZapretTelegramStatus $testRoot -Compact) -eq 'PORT_CONFLICT') 'Foreign listener did not report port conflict'

    $context = Reset-TelegramFixture
    $script:failStart = $true
    Assert-TelegramRejected { Enable-ZapretTelegram $testRoot } 'New task startup failure was ignored'
    Assert-Telegram (-not $fakeTask -and -not [IO.File]::Exists($context.Config)) 'New task startup failure did not roll back registration and config'

    # Stop has a CIM fallback, but it must never kill a similarly named process.
    $context = Reset-TelegramFixture
    Enable-ZapretTelegram $testRoot
    $configBefore = [IO.File]::ReadAllText($context.Config)
    $script:fakeProcesses += [pscustomobject]@{ ProcessId=9000; ExecutablePath=$context.Executable; CommandLine=('"' + $context.Executable + '" --config "' + $context.Config + '.other"') }
    $script:fakeProcesses += [pscustomobject]@{ ProcessId=9001; ExecutablePath=(Join-Path $fixture 'other\zapret-telegram.exe'); CommandLine=(Get-ZapretTelegramArguments $context) }
    $script:leaveProcess = $true
    Disable-ZapretTelegram $testRoot
    Assert-Telegram ($terminated.Count -eq 1 -and $terminated[0] -eq 1234) 'Disable terminated an unrelated process'
    Assert-Telegram ($fakeProcesses.Count -eq 2 -and [IO.File]::ReadAllText($context.Config) -ceq $configBefore) 'Disable lost foreign processes or persistent config'

    $context = Reset-TelegramFixture
    [IO.File]::AppendAllText($context.Executable, 'tampered')
    Assert-TelegramRejected { Enable-ZapretTelegram $testRoot } 'Hash mismatch was accepted'
    Assert-Telegram ($events.Count -eq 0 -and -not [IO.File]::Exists($context.Config)) 'Hash failure changed the task or created a config'

    $context = Reset-TelegramFixture
    $metadata = Join-Path (Split-Path $context.Executable) 'BUILD.json'
    [IO.File]::WriteAllText($metadata, '{"version":"fixture"}')
    $metadataHash = (Get-FileHash -LiteralPath $metadata -Algorithm SHA256).Hash
    [IO.File]::AppendAllText($context.Manifest, [Environment]::NewLine + $metadataHash + '  BUILD.json')
    Assert-ZapretTelegramRuntime $testRoot
    $script:identityBroken = $true
    try { Assert-ZapretTelegramRuntime $testRoot; Assert-Telegram $true 'Runtime integrity unexpectedly required desktop identity' }
    finally { $script:identityBroken = $false }
    [IO.File]::AppendAllText($metadata, 'tampered')
    Assert-TelegramRejected { Assert-ZapretTelegramRuntime $testRoot } 'Runtime metadata hash mismatch was ignored'
    [IO.File]::WriteAllText($metadata, '{"version":"fixture"}')
    $manifest = [IO.File]::ReadAllText($context.Manifest)
    [IO.File]::AppendAllText($context.Manifest, [Environment]::NewLine + $metadataHash + '  ../BUILD.json')
    Assert-TelegramRejected { Assert-ZapretTelegramRuntime $testRoot } 'Runtime manifest traversal was accepted'
    [IO.File]::WriteAllText($context.Manifest, $manifest + [Environment]::NewLine + $metadataHash + '  ./BUILD.json')
    Assert-TelegramRejected { Assert-ZapretTelegramRuntime $testRoot } 'Canonical duplicate manifest entries were accepted'

    $context = Reset-TelegramFixture
    [IO.File]::WriteAllText($context.Config, '{"secret":"keep-me","host":"0.0.0.0"}')
    $badConfig = [IO.File]::ReadAllText($context.Config)
    Assert-TelegramRejected { Enable-ZapretTelegram $testRoot } 'Unsafe config was accepted'
    Assert-Telegram ($events.Count -eq 0 -and [IO.File]::ReadAllText($context.Config) -ceq $badConfig) 'Invalid config was overwritten'
    foreach ($invalid in @(
        '{"version":1,"host":"127.0.0.1","port":80,"secret":"0123456789abcdef0123456789abcdef","cfproxy":true}',
        '{"version":"1","host":"127.0.0.1","port":1443,"secret":"0123456789abcdef0123456789abcdef","cfproxy":true}'
    )) {
        [IO.File]::WriteAllText($context.Config, $invalid)
        Assert-TelegramRejected { Read-ZapretTelegramConfig $context } 'Invalid config version type or reserved port was accepted'
    }

    $context = Reset-TelegramFixture
    $held = [IO.File]::Open((Join-Path $context.Runtime 'operation.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    try { Assert-TelegramRejected { Enable-ZapretTelegram $testRoot } 'Concurrent lifecycle action bypassed the lock' }
    finally { $held.Dispose() }
    Assert-Telegram ($events.Count -eq 0 -and -not [IO.File]::Exists($context.Config)) 'Lock conflict changed task or config'

    $context = Reset-TelegramFixture
    $unconfiguredRoot = Join-Path $fixture 'unconfigured'
    Assert-Telegram ((Get-ZapretTelegramStatus $unconfiguredRoot -Compact) -eq 'DISABLED') 'Absent config status is incorrect'
    Assert-Telegram (-not [IO.Directory]::Exists($unconfiguredRoot) -and $aclCalls -eq 0) 'Read-only status created runtime directories or changed ACLs'
    $startup = Join-Path $context.Runtime 'startup-error.json'
    [IO.File]::WriteAllText($startup, '{"error":"OSError","message":"cannot bind; secret 0123456789abcdef0123456789abcdef"}')
    $startupMessage = Get-ZapretTelegramStartupError $context
    Assert-Telegram ($startupMessage.Contains('cannot bind') -and -not $startupMessage.Contains('0123456789abcdef0123456789abcdef')) 'Startup error did not redact secrets or lost useful detail'

    # Diagnostic cleanup must remove both onefile processes while leaving the
    # normal proxy and other diagnostic invocations untouched.
    $report = Join-Path $context.Runtime 'diagnostic-isolated.json'
    $command = '"' + $context.Executable + '" --diagnose ' + (Get-ZapretTelegramArguments $context) + ' --output "' + $report + '"'
    $script:fakeProcesses = @(
        [pscustomobject]@{ ProcessId=7000; ExecutablePath=$context.Executable; CommandLine=$command },
        [pscustomobject]@{ ProcessId=7001; ExecutablePath=$context.Executable; CommandLine=$command },
        [pscustomobject]@{ ProcessId=7002; ExecutablePath=$context.Executable; CommandLine=('"' + $context.Executable + '" ' + (Get-ZapretTelegramArguments $context)) },
        [pscustomobject]@{ ProcessId=7003; ExecutablePath=$context.Executable; CommandLine=($command.Replace($report, $report + '.other')) }
    )
    Stop-ZapretTelegramDiagnosticProcesses $context $report
    Assert-Telegram ($terminated.Count -eq 2 -and $terminated.Contains(7000) -and $terminated.Contains(7001)) 'Diagnostic timeout did not stop the exact onefile parent and child'
    Assert-Telegram ($fakeProcesses.Count -eq 2) 'Diagnostic timeout stopped unrelated proxy or diagnostic processes'

    $context = Reset-TelegramFixture
    Enable-ZapretTelegram $testRoot
    Invoke-ZapretTelegramDiagnostics $testRoot
    Assert-Telegram ([IO.File]::Exists($diagnosticReport) -and $diagnosticDisposed) 'Diagnostics did not save its report or dispose the process handle'
    $script:diagnosticMode = 'failure'
    Assert-TelegramRejected { Invoke-ZapretTelegramDiagnostics $testRoot } 'Launcher diagnostic error report was accepted'
    $script:diagnosticMode = 'timeout'
    Assert-TelegramRejected { Invoke-ZapretTelegramDiagnostics $testRoot -TimeoutSeconds 1 } 'Diagnostic process timeout was ignored'
    Assert-Telegram ($terminated.Count -eq 2 -and $fakeProcesses.Count -eq 1 -and $fakeProcesses[0].ProcessId -eq 1234) 'Full diagnostic timeout left onefile children or stopped the proxy'
    Assert-Telegram ((Get-ZapretTelegramStatus $testRoot -Compact) -eq 'RUNNING') 'Diagnostics changed the running proxy'
    Write-Host "[OK] $checks Telegram lifecycle checks passed without real Windows changes." -ForegroundColor Green
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    $allowed = [IO.Path]::GetFullPath((Join-Path $bundleRoot 'runtime')).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing to remove test fixture outside runtime.' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
