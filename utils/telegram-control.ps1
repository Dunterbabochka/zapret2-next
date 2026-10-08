# Telegram runs in the current user's interactive session. Scheduler/process
# operations are isolated behind functions so offline tests never touch Windows.
function Get-ZapretTelegramCurrentIdentity {
    return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}

function Get-ZapretTelegramSessionId {
    return [Diagnostics.Process]::GetCurrentProcess().SessionId
}

function Get-ZapretTelegramShellProcessId {
    if (-not ('ZapretTelegram.NativeShell' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace ZapretTelegram {
    public static class NativeShell {
        [DllImport("user32.dll")]
        public static extern IntPtr GetShellWindow();
        [DllImport("user32.dll", SetLastError = true)]
        public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    }
}
'@ -ErrorAction Stop
    }
    $window = [ZapretTelegram.NativeShell]::GetShellWindow()
    if ($window -eq [IntPtr]::Zero) { return 0 }
    $shellProcessId = [uint32]0
    $threadId = [ZapretTelegram.NativeShell]::GetWindowThreadProcessId($window, [ref]$shellProcessId)
    if (-not $threadId -or -not $shellProcessId) { throw 'Cannot identify the Windows desktop shell.' }
    return $shellProcessId
}

function Get-ZapretTelegramIdentity {
    $shellProcessId = Get-ZapretTelegramShellProcessId
    if (-not $shellProcessId) { return Get-ZapretTelegramCurrentIdentity }
    $shell = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $shellProcessId) -ErrorAction Stop
    if (-not $shell -or $shell.SessionId -ne (Get-ZapretTelegramSessionId)) {
        throw 'Cannot identify the desktop user in this Windows session.'
    }
    $owner = Invoke-CimMethod -InputObject $shell -MethodName GetOwnerSid -ErrorAction Stop
    if ($owner.ReturnValue -ne 0 -or [string]$owner.Sid -notmatch '^S-1-\d+(?:-\d+)+$') {
        throw 'Cannot resolve the Windows desktop user SID.'
    }
    try { return (New-Object Security.Principal.SecurityIdentifier([string]$owner.Sid)).Value }
    catch { throw 'The Windows desktop user SID is invalid.' }
}

function Get-ZapretTelegramContext {
    param([Parameter(Mandatory)][string]$Root)
    $bundle = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $sid = Get-ZapretTelegramIdentity
    $runtime = Join-Path (Join-Path $bundle 'runtime\telegram') $sid
    return [pscustomobject]@{
        Root = $bundle
        SID = $sid
        TaskName = 'Zapret2Next-Telegram-' + $sid
        Executable = Join-Path $bundle 'bin\telegram\zapret-telegram.exe'
        Manifest = Join-Path $bundle 'bin\telegram\SHA256SUMS.txt'
        Runtime = $runtime
        Config = Join-Path $runtime 'config.json'
        Log = Join-Path $runtime 'proxy.log'
    }
}

function Set-ZapretTelegramRuntimeAccess {
    param($Context)
    # service.bat may be elevated while the task deliberately runs limited.
    # Grant only this user Modify; keep administration and SYSTEM recovery.
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $propagation = [Security.AccessControl.PropagationFlags]::None
    foreach ($entry in @(
        @{ SID = $Context.SID; Rights = [Security.AccessControl.FileSystemRights]::Modify },
        @{ SID = 'S-1-5-18'; Rights = [Security.AccessControl.FileSystemRights]::FullControl },
        @{ SID = 'S-1-5-32-544'; Rights = [Security.AccessControl.FileSystemRights]::FullControl }
    )) {
        $identity = New-Object Security.Principal.SecurityIdentifier($entry.SID)
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity, $entry.Rights, $inheritance, $propagation, [Security.AccessControl.AccessControlType]::Allow)
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Context.Runtime -AclObject $acl -ErrorAction Stop
}

function Initialize-ZapretTelegramRuntime {
    param($Context)
    New-Item -ItemType Directory -Path $Context.Runtime -Force | Out-Null
    Set-ZapretTelegramRuntimeAccess $Context
}

function Get-ZapretTelegramArguments {
    param($Context)
    return '--config "' + $Context.Config + '"'
}

function Get-ZapretTelegramTask {
    param($Context)
    # Enumerating with Stop avoids treating an access error as a missing task.
    return Get-ScheduledTask -TaskPath '\' -ErrorAction Stop |
        Where-Object { $_.TaskName -eq $Context.TaskName }
}

function Test-ZapretTelegramTaskPrincipal {
    param($Principal, [string]$SID)
    if (-not $Principal) { return $false }
    $principalSID = [string]$Principal.UserId
    if ($principalSID -ine $SID) {
        # Task Scheduler can return a resolved account name even when registered
        # with a SID. Compare its identity rather than its display spelling.
        try { $principalSID = (New-Object Security.Principal.NTAccount($principalSID)).Translate([Security.Principal.SecurityIdentifier]).Value }
        catch {
            # The provider may shorten a local account to "user". On Windows a
            # bare lookup can fail when that name is also the computer name.
            # Qualify only local-looking names, then still compare the SID.
            if ($principalSID.Contains('\') -or $principalSID.Contains('@')) { return $false }
            try { $principalSID = (New-Object Security.Principal.NTAccount([Environment]::MachineName, $principalSID)).Translate([Security.Principal.SecurityIdentifier]).Value }
            catch { return $false }
        }
    }
    if ($principalSID -ine $SID) { return $false }
    if ([string]$Principal.LogonType -ne 'Interactive') { return $false }
    if ([string]$Principal.RunLevel -ne 'Limited') { return $false }
    return $true
}

function Test-ZapretTelegramTaskOwner {
    param($Context, $Task)
    if (-not $Task) { return $false }
    $actions = @($Task.Actions)
    if ($actions.Count -ne 1) { return $false }
    $action = $actions[0]
    if (-not [IO.Path]::IsPathRooted([string]$action.Execute)) { return $false }
    if ([IO.Path]::GetFullPath([string]$action.Execute) -ine $Context.Executable) { return $false }
    if ([string]$action.Arguments -cne (Get-ZapretTelegramArguments $Context)) { return $false }
    return Test-ZapretTelegramTaskPrincipal $Task.Principal $Context.SID
}

function Assert-ZapretTelegramTaskOwner {
    param($Context, $Task)
    if ($Task -and -not (Test-ZapretTelegramTaskOwner $Context $Task)) {
        throw 'The Telegram task belongs to another folder or configuration. Disable it using that bundle first.'
    }
}

function Get-ZapretTelegramTaskSnapshot {
    param($Context)
    $task = Get-ZapretTelegramTask $Context
    Assert-ZapretTelegramTaskOwner $Context $task
    if (-not $task) { return $null }
    return [pscustomobject]@{
        Xml = Export-ScheduledTask -TaskName $Context.TaskName -TaskPath '\' -ErrorAction Stop
        WasRunning = [string]$task.State -in @('Running', 'Queued')
    }
}

function Set-ZapretTelegramTaskRegistration {
    param($Context)
    Assert-ZapretTelegramTaskOwner $Context (Get-ZapretTelegramTask $Context)
    $action = New-ScheduledTaskAction -Execute $Context.Executable -Argument (Get-ZapretTelegramArguments $Context) -WorkingDirectory $Context.Root
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $Context.SID
    $principal = New-ScheduledTaskPrincipal -UserId $Context.SID -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval ([TimeSpan]::FromMinutes(1)) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
    $task = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Zapret 2 NEXT local Telegram WebSocket proxy'
    # The CIM constructor can normalize a supplied SID to a bare account name
    # that cannot be resolved when registering. Serialize the unambiguous SID.
    $task.Principal.UserId = $Context.SID
    Register-ScheduledTask -TaskName $Context.TaskName -TaskPath '\' -InputObject $task -Force -ErrorAction Stop | Out-Null
}

function Restore-ZapretTelegramTaskRegistration {
    param($Context, $Snapshot)
    Register-ScheduledTask -TaskName $Context.TaskName -TaskPath '\' -Xml $Snapshot.Xml -Force -ErrorAction Stop | Out-Null
}

function Start-ZapretTelegramTask {
    param($Context)
    $task = Get-ZapretTelegramTask $Context
    Assert-ZapretTelegramTaskOwner $Context $task
    if (-not $task) { throw 'The Telegram task is not installed.' }
    Start-ScheduledTask -TaskName $Context.TaskName -TaskPath '\' -ErrorAction Stop
}

function Remove-ZapretTelegramTaskRegistration {
    param($Context)
    $task = Get-ZapretTelegramTask $Context
    Assert-ZapretTelegramTaskOwner $Context $task
    if ($task) { Unregister-ScheduledTask -TaskName $Context.TaskName -TaskPath '\' -Confirm:$false -ErrorAction Stop }
}

function Get-ZapretTelegramProcesses {
    return @(Get-CimInstance Win32_Process -Filter "Name='zapret-telegram.exe'" -ErrorAction Stop)
}

function Test-ZapretTelegramProcessOwner {
    param($Context, $Process)
    if (-not $Process -or -not $Process.ExecutablePath) { return $false }
    if ([IO.Path]::GetFullPath([string]$Process.ExecutablePath) -ine $Context.Executable) { return $false }
    # Match the generated, quoted config argument as a complete argument. Never
    # claim a different config merely because it has a common path prefix.
    $expected = [regex]::Escape((Get-ZapretTelegramArguments $Context))
    return [string]$Process.CommandLine -match ('(?:^|\s)' + $expected + '(?:\s|$)')
}

function Get-ZapretTelegramListeners {
    param([int]$Port)
    return @(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object { $_.LocalPort -eq $Port })
}

function Test-ZapretTelegramListenerOwner {
    param($Context, $Listener, [object[]]$Processes)
    if ([string]$Listener.LocalAddress -ne '127.0.0.1') { return $false }
    $process = @($Processes | Where-Object { $_.ProcessId -eq $Listener.OwningProcess })
    return $process.Count -eq 1 -and (Test-ZapretTelegramProcessOwner $Context $process[0])
}

function Assert-ZapretTelegramPortOwner {
    param($Context, [int]$Port, [switch]$AllowOwned)
    $listeners = @(Get-ZapretTelegramListeners $Port)
    if (-not $listeners.Count) { return }
    $processes = @(Get-ZapretTelegramProcesses)
    foreach ($listener in $listeners) {
        if (-not $AllowOwned -or -not (Test-ZapretTelegramListenerOwner $Context $listener $processes)) {
            throw "Local port $Port is used by another process. Stop that process or use a different Telegram config port."
        }
    }
}

function Test-ZapretTelegramFreePort {
    param([int]$Port)
    if (@(Get-ZapretTelegramListeners $Port).Count) { return $false }
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
    try { $listener.Start(); return $true } catch [Net.Sockets.SocketException] { return $false } finally { $listener.Stop() }
}

function New-ZapretTelegramConfig {
    $port = 0
    foreach ($candidate in 1443..1474) {
        if (Test-ZapretTelegramFreePort $candidate) { $port = $candidate; break }
    }
    if (-not $port) { throw 'No free local Telegram port was found in 1443-1474.' }
    $bytes = New-Object byte[] 16
    $random = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $random.GetBytes($bytes) } finally { $random.Dispose() }
    $secret = ([BitConverter]::ToString($bytes)).Replace('-', '').ToLowerInvariant()
    return [pscustomobject][ordered]@{ version = 1; host = '127.0.0.1'; port = $port; secret = $secret; cfproxy = $true }
}

function Read-ZapretTelegramConfig {
    param($Context)
    if (-not [IO.File]::Exists($Context.Config)) { return $null }
    try { $config = [IO.File]::ReadAllText($Context.Config) | ConvertFrom-Json -ErrorAction Stop }
    catch { throw 'The Telegram config is not valid JSON. Restore your saved config from backup.' }
    if ($config.version -isnot [int] -or $config.version -ne 1 -or $config.host -cne '127.0.0.1' -or $config.port -isnot [int] -or $config.port -lt 1024 -or $config.port -gt 65535 -or [string]$config.secret -cnotmatch '^[0-9a-f]{32}$' -or $config.cfproxy -isnot [bool]) {
        throw 'Invalid Telegram config. Expected integer version 1, host 127.0.0.1, a TCP port in 1024-65535, a 32-character lowercase hex secret and boolean cfproxy.'
    }
    return $config
}

function Write-ZapretTelegramAtomicBytes {
    param([string]$Path, [byte[]]$Bytes)
    $temporary = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllBytes($temporary, $Bytes)
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, $null) }
        else { [IO.File]::Move($temporary, $Path) }
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

function Write-ZapretTelegramConfig {
    param($Context, $Config)
    $json = ($Config | ConvertTo-Json -Depth 4) + [Environment]::NewLine
    Write-ZapretTelegramAtomicBytes -Path $Context.Config -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($json))
}

function Assert-ZapretTelegramBinary {
    param($Context)
    if (-not [IO.File]::Exists($Context.Executable) -or -not [IO.File]::Exists($Context.Manifest)) {
        throw 'The Telegram executable or SHA256 manifest is missing. Use the complete release package or run utils\build-telegram.ps1.'
    }
    $directory = [IO.Path]::GetFullPath((Split-Path -Parent $Context.Executable)).TrimEnd('\') + '\'
    $seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $executableCount = 0
    foreach ($line in [IO.File]::ReadAllLines($Context.Manifest)) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) { continue }
        if ($line -notmatch '^([0-9a-fA-F]{64})[ \t]+\*?(.+)$') { throw 'Invalid Telegram SHA256 manifest.' }
        $hash = $Matches[1]
        $relative = $Matches[2].Replace('\', '/').Trim()
        if ($relative.StartsWith('bin/telegram/', [StringComparison]::OrdinalIgnoreCase)) { $relative = $relative.Substring(13) }
        if ([IO.Path]::IsPathRooted($relative) -or $relative.Contains(':')) { throw 'Telegram SHA256 manifest paths must be relative to bin\telegram.' }
        $path = [IO.Path]::GetFullPath((Join-Path $directory $relative.Replace('/', '\')))
        if (-not $path.StartsWith($directory, [StringComparison]::OrdinalIgnoreCase)) { throw 'Telegram SHA256 manifest path escapes bin\telegram.' }
        if (-not $seen.Add($path)) { throw 'Duplicate Telegram SHA256 manifest entry.' }
        if (-not [IO.File]::Exists($path)) { throw "A Telegram runtime file is missing: $relative" }
        $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash
        if ($actual -ine $hash) { throw "Telegram runtime SHA256 mismatch: $relative. Restore it from the release package." }
        if ($path -ieq $Context.Executable) { $executableCount++ }
    }
    if ($executableCount -ne 1) { throw 'The Telegram SHA256 manifest must contain exactly one executable entry.' }
}

function Assert-ZapretTelegramRuntime {
    param([Parameter(Mandatory)][string]$Root)
    # Release integrity checks do not require a desktop, WMI or a user token.
    $bundle = [IO.Path]::GetFullPath($Root)
    $binaryContext = [pscustomobject]@{
        Executable = Join-Path $bundle 'bin\telegram\zapret-telegram.exe'
        Manifest = Join-Path $bundle 'bin\telegram\SHA256SUMS.txt'
    }
    Assert-ZapretTelegramBinary $binaryContext
}

function Stop-ZapretTelegramOwnedProcesses {
    param($Context)
    foreach ($process in @(Get-ZapretTelegramProcesses)) {
        if (-not (Test-ZapretTelegramProcessOwner $Context $process)) { continue }
        # Re-read immediately before termination to reduce PID-reuse races.
        $current = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $process.ProcessId) -ErrorAction Stop
        if ($current -and (Test-ZapretTelegramProcessOwner $Context $current)) {
            $result = Invoke-CimMethod -InputObject $current -MethodName Terminate -ErrorAction Stop
            if ($result.ReturnValue -ne 0) { throw "Cannot stop the owned Telegram process (Windows $($result.ReturnValue))." }
        }
    }
}

function Stop-ZapretTelegramTask {
    param($Context)
    $task = Get-ZapretTelegramTask $Context
    Assert-ZapretTelegramTaskOwner $Context $task
    if ($task -and [string]$task.State -in @('Running', 'Queued')) {
        Stop-ScheduledTask -TaskName $Context.TaskName -TaskPath '\' -ErrorAction Stop
    }
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        $owned = @(Get-ZapretTelegramProcesses | Where-Object { Test-ZapretTelegramProcessOwner $Context $_ })
        if (-not $owned.Count) { return }
        Start-Sleep -Milliseconds 200
    }
    Stop-ZapretTelegramOwnedProcesses $Context
    for ($attempt = 0; $attempt -lt 25; $attempt++) {
        if (-not @(Get-ZapretTelegramProcesses | Where-Object { Test-ZapretTelegramProcessOwner $Context $_ }).Count) { return }
        Start-Sleep -Milliseconds 200
    }
    throw 'The owned Telegram process did not stop.'
}

function Get-ZapretTelegramStartupError {
    param($Context)
    $path = Join-Path $Context.Runtime 'startup-error.json'
    if (-not [IO.File]::Exists($path)) { return '' }
    try {
        $errorReport = [IO.File]::ReadAllText($path) | ConvertFrom-Json -ErrorAction Stop
        $message = ([string]$errorReport.error + ': ' + [string]$errorReport.message) -replace '[\x00-\x1f\x7f]', ' '
        $message = $message -replace '(?i)(?:dd)?[0-9a-f]{32}', '[redacted]'
        if ($message.Length -gt 500) { $message = $message.Substring(0, 500) }
        return $message
    } catch { return 'A startup error report exists but could not be read.' }
}

function Wait-ZapretTelegramReady {
    param($Context, [int]$Port, [int]$TimeoutSeconds = 25)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        $task = Get-ZapretTelegramTask $Context
        Assert-ZapretTelegramTaskOwner $Context $task
        $listeners = @(Get-ZapretTelegramListeners $Port)
        $processes = @(Get-ZapretTelegramProcesses)
        foreach ($listener in $listeners) {
            if (-not (Test-ZapretTelegramListenerOwner $Context $listener $processes)) {
                throw "Local port $Port was taken by another process during startup."
            }
        }
        if ($task -and [string]$task.State -eq 'Running' -and $listeners.Count) { return }
        Start-Sleep -Milliseconds 300
    } while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    $info = Get-ScheduledTaskInfo -TaskName $Context.TaskName -TaskPath '\' -ErrorAction Stop
    $startup = Get-ZapretTelegramStartupError $Context
    $detail = if ($startup) { ' Startup error: ' + $startup } else { '' }
    throw "Telegram did not start on 127.0.0.1:$Port (task result $($info.LastTaskResult)).$detail See $($Context.Log)."
}

function Enable-ZapretTelegram {
    param([Parameter(Mandatory)][string]$Root, [switch]$RequireInstalled)
    $context = Get-ZapretTelegramContext $Root
    Assert-ZapretTelegramBinary $context
    Initialize-ZapretTelegramRuntime $context
    $lock = [IO.File]::Open((Join-Path $context.Runtime 'operation.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    $snapshot = $null
    $original = $null
    $configChanged = $false
    $taskChanged = $false
    $stopped = $false
    try {
        $snapshot = Get-ZapretTelegramTaskSnapshot $context
        if ($RequireInstalled -and -not $snapshot) { throw 'Telegram is not enabled. Select Enable first.' }
        if ([IO.File]::Exists($context.Config)) { $original = [IO.File]::ReadAllBytes($context.Config) }
        $config = Read-ZapretTelegramConfig $context
        if (-not $config) { $config = New-ZapretTelegramConfig }
        Assert-ZapretTelegramPortOwner $context $config.port -AllowOwned:([bool]$snapshot)
        if ($snapshot) {
            $stopped = $true
            Stop-ZapretTelegramTask $context
        }
        if ($null -eq $original) {
            Write-ZapretTelegramConfig $context $config
            $configChanged = $true
        }
        # Registration can partially succeed before it throws.
        $taskChanged = $true
        Set-ZapretTelegramTaskRegistration $context
        Start-ZapretTelegramTask $context
        Wait-ZapretTelegramReady $context $config.port
        Write-Host "[OK] Telegram proxy enabled at 127.0.0.1:$($config.port); starts when this user signs in." -ForegroundColor Green
    } catch {
        $failure = $_.Exception.Message
        if ($taskChanged -or $stopped -or $configChanged) {
            try {
                Stop-ZapretTelegramTask $context
                if ($configChanged) {
                    if ($null -ne $original) { Write-ZapretTelegramAtomicBytes $context.Config $original }
                    elseif ([IO.File]::Exists($context.Config)) { [IO.File]::Delete($context.Config) }
                }
                if ($taskChanged) {
                    if ($snapshot) { Restore-ZapretTelegramTaskRegistration $context $snapshot }
                    else { Remove-ZapretTelegramTaskRegistration $context }
                }
                if ($snapshot -and $snapshot.WasRunning) { Start-ZapretTelegramTask $context }
                Write-Host '[WARN] Previous Telegram task and config restored.' -ForegroundColor Yellow
            } catch { throw "$failure Rollback also failed: $($_.Exception.Message). Check the Telegram task and $($context.Config)." }
        }
        throw $failure
    } finally { $lock.Dispose() }
}

function Disable-ZapretTelegram {
    param([Parameter(Mandatory)][string]$Root)
    $context = Get-ZapretTelegramContext $Root
    Initialize-ZapretTelegramRuntime $context
    $lock = [IO.File]::Open((Join-Path $context.Runtime 'operation.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    try {
        Assert-ZapretTelegramTaskOwner $context (Get-ZapretTelegramTask $context)
        Stop-ZapretTelegramTask $context
        Remove-ZapretTelegramTaskRegistration $context
        Write-Host '[OK] Telegram autostart and proxy stopped. Saved connection settings are preserved.' -ForegroundColor Green
        Write-Host 'Disable this proxy in Telegram: Settings > Advanced > Connection type.' -ForegroundColor Yellow
    } finally { $lock.Dispose() }
}

function Restart-ZapretTelegram {
    param([Parameter(Mandatory)][string]$Root)
    Enable-ZapretTelegram -Root $Root -RequireInstalled
}

function Get-ZapretTelegramStatus {
    param([Parameter(Mandatory)][string]$Root, [switch]$Compact)
    $context = Get-ZapretTelegramContext $Root
    $state = 'ERROR'
    $taskState = 'Unavailable'
    $listener = 'Not checked'
    $endpoint = '-'
    $detail = ''
    try {
        $task = Get-ZapretTelegramTask $context
        if ($task -and -not (Test-ZapretTelegramTaskOwner $context $task)) {
            $state = 'OTHER_FOLDER'; $taskState = 'Owned by another bundle'
        } else {
            $taskState = if ($task) { [string]$task.State } else { 'Not installed' }
            $config = Read-ZapretTelegramConfig $context
            $state = if ($task) { 'STOPPED' } else { 'DISABLED' }
            $listener = 'Not listening'
            if ($config) {
                $endpoint = '127.0.0.1:' + $config.port
                $listeners = @(Get-ZapretTelegramListeners $config.port)
                if ($listeners.Count) {
                    $processes = @(Get-ZapretTelegramProcesses)
                    $foreign = @($listeners | Where-Object { -not (Test-ZapretTelegramListenerOwner $context $_ $processes) })
                    if ($foreign.Count) { $state = 'PORT_CONFLICT'; $listener = 'Owned by another process' }
                    else {
                        $listener = 'Owned by this bundle'
                        $state = if ($task -and $taskState -eq 'Running') { 'RUNNING' } else { 'UNMANAGED' }
                    }
                }
            } elseif ($task) { $state = 'CONFIG_MISSING' }
            if ($state -eq 'STOPPED') { $detail = Get-ZapretTelegramStartupError $context }
        }
    } catch { $detail = $_.Exception.Message; $state = 'ERROR' }
    if ($Compact) { return $state }
    # The secret and complete config never become part of the status output.
    return [pscustomobject][ordered]@{ State = $state; Task = $taskState; Listener = $listener; Endpoint = $endpoint; Log = $context.Log; Detail = $detail }
}

function Get-ZapretTelegramConnectTask {
    param($Context)
    return Get-ScheduledTask -TaskPath '\' -ErrorAction Stop |
        Where-Object { $_.TaskName -eq ($Context.TaskName + '-Connect') }
}

function Test-ZapretTelegramConnectTaskOwner {
    param($Context, $Task, [string]$Executable, [string]$Arguments)
    if (-not $Task) { return $false }
    $actions = @($Task.Actions)
    if ($actions.Count -ne 1) { return $false }
    $action = $actions[0]
    if (-not [IO.Path]::IsPathRooted([string]$action.Execute)) { return $false }
    if ([IO.Path]::GetFullPath([string]$action.Execute) -ine $Executable -or [string]$action.Arguments -cne $Arguments) { return $false }
    if ([string]$action.WorkingDirectory -ine $Context.Root) { return $false }
    return Test-ZapretTelegramTaskPrincipal $Task.Principal $Context.SID
}

function Open-ZapretTelegramLink {
    param([string]$Uri, $Context)
    # URI values come from validated config; enforce their grammar before they
    # become a PowerShell command in another user's interactive session.
    if ($Uri -cnotmatch '^tg://proxy\?server=127\.0\.0\.1&port=([0-9]{4,5})&secret=dd[0-9a-f]{32}$' -or [int]$Matches[1] -lt 1024 -or [int]$Matches[1] -gt 65535) {
        throw 'Invalid Telegram proxy link.'
    }
    if (-not $Context -or (Get-ZapretTelegramCurrentIdentity) -eq $Context.SID) {
        Start-Process -FilePath $Uri -ErrorAction Stop | Out-Null
        return
    }
    $executable = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoProfile -WindowStyle Hidden -Command "Start-Process -FilePath ''' + $Uri + ''' -ErrorAction Stop"'
    $taskName = $Context.TaskName + '-Connect'
    $lock = [IO.File]::Open((Join-Path $Context.Runtime 'operation.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    $changed = $false
    try {
        $existing = Get-ZapretTelegramConnectTask $Context
        if ($existing) {
            if (-not (Test-ZapretTelegramConnectTaskOwner $Context $existing $executable $arguments)) {
                throw 'The Telegram connect task belongs to another folder or configuration.'
            }
            if ([string]$existing.State -in @('Running', 'Queued')) { throw 'A Telegram connect request is already running. Try again after it completes.' }
            Unregister-ScheduledTask -TaskName $taskName -TaskPath '\' -Confirm:$false -ErrorAction Stop
        }
        $action = New-ScheduledTaskAction -Execute $executable -Argument $arguments -WorkingDirectory $Context.Root
        $principal = New-ScheduledTaskPrincipal -UserId $Context.SID -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::FromSeconds(30)) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
        $task = New-ScheduledTask -Action $action -Principal $principal -Settings $settings -Description 'Open Telegram proxy settings for the Windows desktop user'
        $task.Principal.UserId = $Context.SID
        $changed = $true
        # No Force: a competing task must never be replaced between the check
        # above and this registration.
        Register-ScheduledTask -TaskName $taskName -TaskPath '\' -InputObject $task -ErrorAction Stop | Out-Null
        $before = Get-ScheduledTaskInfo -TaskName $taskName -TaskPath '\' -ErrorAction Stop
        Start-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction Stop
        $timer = [Diagnostics.Stopwatch]::StartNew()
        do {
            $current = Get-ZapretTelegramConnectTask $Context
            if (-not (Test-ZapretTelegramConnectTaskOwner $Context $current $executable $arguments)) { throw 'The Telegram connect task changed while it was starting.' }
            $info = Get-ScheduledTaskInfo -TaskName $taskName -TaskPath '\' -ErrorAction Stop
            if ([string]$current.State -notin @('Running', 'Queued') -and $info.LastRunTime -gt $before.LastRunTime) {
                if ($info.LastTaskResult -ne 0) { throw "Telegram could not open the proxy link for the desktop user (task result $($info.LastTaskResult))." }
                return
            }
            Start-Sleep -Milliseconds 200
        } while ($timer.Elapsed.TotalSeconds -lt 10)
        throw 'Opening Telegram for the desktop user timed out.'
    } finally {
        try {
            if ($changed) {
                $current = Get-ZapretTelegramConnectTask $Context
                if (Test-ZapretTelegramConnectTaskOwner $Context $current $executable $arguments) {
                    if ([string]$current.State -in @('Running', 'Queued')) { Stop-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction Stop }
                    Unregister-ScheduledTask -TaskName $taskName -TaskPath '\' -Confirm:$false -ErrorAction Stop
                }
            }
        } finally { $lock.Dispose() }
    }
}

function Connect-ZapretTelegram {
    param([Parameter(Mandatory)][string]$Root)
    if ((Get-ZapretTelegramStatus $Root -Compact) -ne 'RUNNING') { throw 'The Telegram proxy is not running. Select Enable or Restart first.' }
    $context = Get-ZapretTelegramContext $Root
    $config = Read-ZapretTelegramConfig $context
    $uri = 'tg://proxy?server=127.0.0.1&port=' + $config.port + '&secret=dd' + $config.secret
    Open-ZapretTelegramLink $uri $context
    Write-Host '[OK] Confirm Connect in Telegram. Messages and media stay encrypted by Telegram.' -ForegroundColor Green
}

function Start-ZapretTelegramDiagnosticProcess {
    param($Context, [string]$Report)
    $arguments = '--diagnose ' + (Get-ZapretTelegramArguments $Context) + ' --output "' + $Report + '"'
    return Start-Process -FilePath $Context.Executable -ArgumentList $arguments -WorkingDirectory $Context.Root -WindowStyle Hidden -PassThru -ErrorAction Stop
}

function Stop-ZapretTelegramDiagnosticProcesses {
    param($Context, [string]$Report)
    $arguments = '--diagnose ' + (Get-ZapretTelegramArguments $Context) + ' --output "' + $Report + '"'
    $expected = '(?:^|\s)' + [regex]::Escape($arguments) + '(?:\s|$)'
    foreach ($process in @(Get-ZapretTelegramProcesses)) {
        if (-not (Test-ZapretTelegramProcessOwner $Context $process) -or [string]$process.CommandLine -notmatch $expected) { continue }
        $current = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $process.ProcessId) -ErrorAction Stop
        if ($current -and (Test-ZapretTelegramProcessOwner $Context $current) -and [string]$current.CommandLine -match $expected) {
            $result = Invoke-CimMethod -InputObject $current -MethodName Terminate -ErrorAction Stop
            if ($result.ReturnValue -ne 0) { throw "Cannot stop the timed-out Telegram diagnostic (Windows $($result.ReturnValue))." }
        }
    }
}

function Invoke-ZapretTelegramDiagnostics {
    param([Parameter(Mandatory)][string]$Root, [ValidateRange(1, 120)][int]$TimeoutSeconds = 45)
    $context = Get-ZapretTelegramContext $Root
    Assert-ZapretTelegramBinary $context
    if (-not (Read-ZapretTelegramConfig $context)) { throw 'Select Enable first to create the Telegram config.' }
    New-Item -ItemType Directory -Path $context.Runtime -Force | Out-Null
    $report = Join-Path $context.Runtime ('diagnostic-' + [Guid]::NewGuid().ToString('N') + '.json')
    $process = Start-ZapretTelegramDiagnosticProcess $context $report
    try {
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            # A frozen onefile EXE may have a bootloader and a child. Stop only
            # this exact diagnostic invocation, leaving the background proxy.
            Stop-ZapretTelegramDiagnosticProcesses $context $report
            if (-not $process.HasExited) { $process.Kill() }
            $process.WaitForExit(5000) | Out-Null
            throw 'Telegram endpoint diagnostics timed out.'
        }
        $process.Refresh()
        if (-not [IO.File]::Exists($report)) { throw "Telegram diagnostics produced no report (exit $($process.ExitCode))." }
        try { $result = [IO.File]::ReadAllText($report) | ConvertFrom-Json -ErrorAction Stop }
        catch { throw 'Telegram diagnostics produced an invalid JSON report.' }
        Write-Host "Telegram endpoint diagnostics: $report" -ForegroundColor Cyan
        # Output only selected public fields, never the config or secret.
        if ($result.ok -eq $false) { throw "Telegram diagnostics failed: $($result.message)" }
        foreach ($item in @($result.direct_ws)) {
            $kind = if ($item.media) { 'media' } else { 'messages' }
            $availability = if ($item.available) { 'reachable via ' + $item.route } else { 'unreachable' }
            Write-Host ("DC {0} {1}: {2}" -f $item.dc, $kind, $availability)
        }
        $cf = if (-not $result.cfproxy.enabled) { 'disabled in config' }
              elseif ($result.cfproxy.available -eq $true) { 'sample endpoint reachable' }
              elseif ($result.cfproxy.available -eq $false) { 'sample endpoint unreachable' }
              else { 'not checked' }
        Write-Host ('Cloudflare fallback: ' + $cf)
        Write-Host 'Endpoint reachability does not verify your Telegram account, messages, media or calls. Test those in Telegram.' -ForegroundColor Yellow
        if ($process.ExitCode -ne 0) { throw "Telegram endpoint diagnostics reported a failure (exit $($process.ExitCode)). See $report." }
    } finally { $process.Dispose() }
}
