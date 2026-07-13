function New-PreflightFinding {
    param(
        [string]$Code,
        [ValidateSet('Pass', 'Info', 'Warning', 'Blocker')]
        [string]$Severity,
        [string]$Category,
        [string]$Message,
        [string]$Action = '',
        [bool]$NeedsDecision = $false,
        [string]$Evidence = ''
    )

    return [pscustomobject]@{
        Attempt = 0
        Code = $Code
        Severity = $Severity
        Category = $Category
        Message = $Message
        Action = $Action
        NeedsDecision = $NeedsDecision
        Decision = ''
        Evidence = $Evidence
    }
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ZapretConflictState {
    $services = @()
    try {
        $services = @(Get-CimInstance Win32_Service -ErrorAction Stop | Where-Object {
            $text = "$($_.Name) $($_.DisplayName) $($_.PathName)"
            $text -match '(?i)zapret|(?:^|[\\/\s\"])(?:winws|winws2)(?:\.exe)?(?:[\\/\s\"]|$)'
        } | ForEach-Object {
            [pscustomobject]@{
                Name = [string]$_.Name
                DisplayName = [string]$_.DisplayName
                State = [string]$_.State
                StartMode = [string]$_.StartMode
                ProcessId = [int]$_.ProcessId
                PathName = [string]$_.PathName
                WasRunning = ([string]$_.State -in @('Running', 'Start Pending', 'Continue Pending', 'Paused'))
                StoppedByWizard = $false
            }
        })
    } catch {}

    $servicePids = [Collections.Generic.HashSet[int]]::new()
    foreach ($service in $services) {
        if ($service.ProcessId -gt 0) { [void]$servicePids.Add($service.ProcessId) }
    }

    $manualProcesses = @()
    try {
        $manualProcesses = @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
            $_.Name -match '^(?i:winws|winws2|nfqws)\.exe$' -and -not $servicePids.Contains([int]$_.ProcessId)
        } | ForEach-Object {
            [pscustomobject]@{
                ProcessId = [int]$_.ProcessId
                ParentProcessId = [int]$_.ParentProcessId
                Name = [string]$_.Name
                ExecutablePath = [string]$_.ExecutablePath
                CommandLine = [string]$_.CommandLine
                StoppedByWizard = $false
            }
        })
    } catch {}

    return [pscustomobject]@{
        CapturedAtUtc = [DateTime]::UtcNow.ToString('o')
        Services = $services
        ManualProcesses = $manualProcesses
    }
}

function Get-PreflightSnapshot {
    $findings = [Collections.Generic.List[object]]::new()

    if (Test-IsAdministrator) {
        [void]$findings.Add((New-PreflightFinding 'Administrator' 'Pass' 'Runtime' 'Administrator rights are available.'))
    } else {
        [void]$findings.Add((New-PreflightFinding 'Administrator' 'Blocker' 'Runtime' 'Administrator rights are required.' 'Run compatibility wizard.bat and approve the UAC prompt.'))
    }

    $bfe = Get-Service -Name BFE -ErrorAction SilentlyContinue
    if ($null -ne $bfe -and $bfe.Status -eq 'Running') {
        [void]$findings.Add((New-PreflightFinding 'BFE' 'Pass' 'Runtime' 'Base Filtering Engine is running.'))
    } else {
        $state = if ($null -eq $bfe) { 'missing' } else { [string]$bfe.Status }
        [void]$findings.Add((New-PreflightFinding 'BFE' 'Blocker' 'Runtime' "Base Filtering Engine is $state." 'Start the BFE service before testing.'))
    }

    foreach ($requiredPath in @(
        $winws,
        (Join-Path $root 'bin\WinDivert.dll'),
        (Join-Path $root 'bin\WinDivert64.sys'),
        $renderer,
        $starter,
        $targetsPath
    )) {
        if (Test-Path -LiteralPath $requiredPath -PathType Leaf) {
            [void]$findings.Add((New-PreflightFinding ("File-" + (Split-Path $requiredPath -Leaf)) 'Pass' 'Runtime' "Found $requiredPath"))
        } else {
            [void]$findings.Add((New-PreflightFinding ("File-" + (Split-Path $requiredPath -Leaf)) 'Blocker' 'Runtime' "Required file is missing: $requiredPath" 'Restore the official release files.'))
        }
    }

    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($null -ne $curl) {
        $script:curlPath = $curl.Source
        [void]$findings.Add((New-PreflightFinding 'curl' 'Pass' 'Runtime' "curl.exe is available: $($curl.Source)"))
    } else {
        [void]$findings.Add((New-PreflightFinding 'curl' 'Blocker' 'Runtime' 'curl.exe is required for deterministic endpoint tests.' 'Repair the Windows curl installation.'))
    }

    $pktmon = Get-Command pktmon.exe -ErrorAction SilentlyContinue
    if ($null -ne $pktmon) {
        $previousErrorAction = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $pktmonStatus = @(& $pktmon.Source status 2>&1)
            $pktmonExitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousErrorAction
        }
        $pktmonText = ($pktmonStatus | Out-String).Trim()
        $pktmonRunning = $pktmonText -match '(?im)^\s*(?:logger\s+state|logging\s+state|состояние[^:]*):\s*(?:running|выполняется|запущен)'
        if ($pktmonExitCode -ne 0) {
            [void]$findings.Add((New-PreflightFinding 'PktMonAccess' 'Blocker' 'Runtime' 'PktMon state could not be read.' 'Run the elevated launcher and ensure no other PktMon owner blocks access.' $false $pktmonText))
        } elseif ($pktmonRunning) {
            [void]$findings.Add((New-PreflightFinding 'PktMonSession' 'Blocker' 'Runtime' 'A PktMon logging session is already running.' 'Stop the existing PktMon session manually, then rerun preflight.' $false $pktmonText))
        } else {
            [void]$findings.Add((New-PreflightFinding 'PktMon' 'Pass' 'Runtime' 'PktMon is available and no active logger was detected.' '' $false $pktmonText))
        }
    } else {
        [void]$findings.Add((New-PreflightFinding 'PktMon' 'Blocker' 'Runtime' 'PktMon is required for voice metadata collection.' 'Use a supported Windows 10/11 installation with PktMon.'))
    }

    try {
        $drivers = @(Get-CimInstance Win32_SystemDriver -ErrorAction Stop | Where-Object {
            $_.Name -match '^(?i:WinDivert)' -and $_.State -eq 'Running'
        })
        if ($drivers.Count) {
            $driverText = @($drivers | ForEach-Object { "$($_.Name) [$($_.State)]" }) -join '; '
            [void]$findings.Add((New-PreflightFinding 'WinDivertDriver' 'Warning' 'Runtime' "An active WinDivert driver was found: $driverText" 'The related Zapret state will be stopped only after confirmation; other WinDivert software must be closed manually.'))
        } else {
            [void]$findings.Add((New-PreflightFinding 'WinDivertDriver' 'Pass' 'Runtime' 'No already-running WinDivert driver was detected.'))
        }
    } catch {
        [void]$findings.Add((New-PreflightFinding 'WinDivertDriver' 'Warning' 'Runtime' 'Could not enumerate WinDivert driver state.' 'Review active packet-filtering software before continuing.' $true $_.Exception.Message))
    }

    $internetSettings = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    if ($null -ne $internetSettings) {
        $proxyEnableProperty = $internetSettings.PSObject.Properties['ProxyEnable']
        $proxyServerProperty = $internetSettings.PSObject.Properties['ProxyServer']
        $proxyOverrideProperty = $internetSettings.PSObject.Properties['ProxyOverride']
        $autoConfigProperty = $internetSettings.PSObject.Properties['AutoConfigURL']
        $proxyEnable = if ($null -ne $proxyEnableProperty) { [int]$proxyEnableProperty.Value } else { 0 }
        $proxyServer = if ($null -ne $proxyServerProperty) { [string]$proxyServerProperty.Value } else { '' }
        $proxyOverride = if ($null -ne $proxyOverrideProperty) { [string]$proxyOverrideProperty.Value } else { '' }
        $autoConfigUrl = if ($null -ne $autoConfigProperty) { [string]$autoConfigProperty.Value } else { '' }
        if ($proxyEnable -eq 1 -and -not [string]::IsNullOrWhiteSpace($proxyServer)) {
            [void]$findings.Add((New-PreflightFinding 'WinINETProxy' 'Blocker' 'Proxy' "Windows proxy is enabled: $proxyServer" 'Disable the proxy manually before testing.' $false $proxyOverride))
        }
        if (-not [string]::IsNullOrWhiteSpace($autoConfigUrl)) {
            [void]$findings.Add((New-PreflightFinding 'WinINETAutoConfig' 'Blocker' 'Proxy' "A proxy auto-configuration URL is set: $autoConfigUrl" 'Disable the PAC/automatic proxy manually before testing.'))
        }
    }
    if (@($findings | Where-Object Code -like 'WinINET*').Count -eq 0) {
        [void]$findings.Add((New-PreflightFinding 'WinINETProxy' 'Pass' 'Proxy' 'No enabled WinINET proxy or PAC URL was detected.'))
    }

    $previousErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $winHttpDump = @(& netsh.exe winhttp dump 2>&1)
        $winHttpExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorAction
    }
    $winHttpText = ($winHttpDump | Out-String).Trim()
    if ($winHttpExitCode -ne 0) {
        [void]$findings.Add((New-PreflightFinding 'WinHTTPProxy' 'Warning' 'Proxy' 'WinHTTP proxy state could not be read.' 'Confirm that no WinHTTP proxy is active.' $true $winHttpText))
    } elseif ($winHttpText -match '(?im)^\s*set\s+proxy\b') {
        [void]$findings.Add((New-PreflightFinding 'WinHTTPProxy' 'Blocker' 'Proxy' 'A WinHTTP proxy is configured.' 'Run netsh winhttp reset proxy only if that matches your intended system configuration, then rerun preflight.' $false $winHttpText))
    } elseif ($winHttpText -match '(?im)^\s*reset\s+proxy\b') {
        [void]$findings.Add((New-PreflightFinding 'WinHTTPProxy' 'Pass' 'Proxy' 'WinHTTP is configured for direct access.' '' $false $winHttpText))
    } else {
        [void]$findings.Add((New-PreflightFinding 'WinHTTPProxy' 'Warning' 'Proxy' 'WinHTTP returned an unrecognized proxy state.' 'Confirm explicitly that WinHTTP is not using a proxy.' $true $winHttpText))
    }

    $proxyNames = @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY')
    $proxyValues = [Collections.Generic.List[string]]::new()
    foreach ($scope in @('Process', 'User', 'Machine')) {
        foreach ($name in $proxyNames) {
            $value = [Environment]::GetEnvironmentVariable($name, $scope)
            if (-not [string]::IsNullOrWhiteSpace($value)) { $proxyValues.Add("$scope/$name=$value") }
        }
    }
    if ($proxyValues.Count) {
        [void]$findings.Add((New-PreflightFinding 'ProxyEnvironment' 'Blocker' 'Proxy' 'Proxy environment variables are present.' 'Remove or disable them manually before testing.' $false ($proxyValues -join '; ')))
    } else {
        [void]$findings.Add((New-PreflightFinding 'ProxyEnvironment' 'Pass' 'Proxy' 'No proxy environment variables were detected.'))
    }

    $defaultIndices = [Collections.Generic.HashSet[int]]::new()
    try {
        foreach ($route in @(Get-NetRoute -ErrorAction Stop | Where-Object {
            $_.DestinationPrefix -in @('0.0.0.0/0', '::/0') -and $_.State -eq 'Alive'
        })) {
            [void]$defaultIndices.Add([int]$route.InterfaceIndex)
        }
    } catch {
        [void]$findings.Add((New-PreflightFinding 'DefaultRoutes' 'Warning' 'Network' 'Could not enumerate default routes.' 'Review active adapters manually.' $true $_.Exception.Message))
    }

    try {
        $adapters = @(Get-CimInstance Win32_NetworkAdapter -ErrorAction Stop | Where-Object NetEnabled)
        foreach ($adapter in $adapters) {
            $name = [string]$adapter.NetConnectionID
            if ([string]::IsNullOrWhiteSpace($name)) { $name = [string]$adapter.Name }
            $description = [string]$adapter.Description
            $kind = Get-AdapterKind -Name $name -Description $description
            $isDefault = $defaultIndices.Contains([int]$adapter.InterfaceIndex)
            $message = "$name [$kind] default-route=$isDefault; $description"
            switch ($kind) {
                'Physical' {
                    if ($isDefault) { [void]$findings.Add((New-PreflightFinding ("Adapter-$($adapter.InterfaceIndex)") 'Pass' 'Network' $message)) }
                }
                'Virtual' {
                    [void]$findings.Add((New-PreflightFinding ("Adapter-$($adapter.InterfaceIndex)") 'Info' 'Network' $message 'Hyper-V/WSL/VM adapters are not treated as an automatic VPN blocker.' $isDefault))
                }
                'Overlay' {
                    [void]$findings.Add((New-PreflightFinding ("Adapter-$($adapter.InterfaceIndex)") 'Warning' 'Network' $message 'Confirm whether this overlay is carrying VPN/proxy or exit-node traffic.' $true))
                }
                'VpnCandidate' {
                    [void]$findings.Add((New-PreflightFinding ("Adapter-$($adapter.InterfaceIndex)") 'Warning' 'Network' $message 'Confirm whether this adapter is an active VPN.' $true))
                }
            }
        }
    } catch {
        [void]$findings.Add((New-PreflightFinding 'Adapters' 'Warning' 'Network' 'Could not enumerate active network adapters.' 'Review VPN and virtual adapters manually.' $true $_.Exception.Message))
    }

    $softwarePattern = '(?i)^(goodbyedpi|byedpi|spoofdpi|ciadpi|xray|sing-box|nekoray|v2rayn|clash[^.]*|warp-svc|wireguard|openvpn|tailscaled|proxifier|adguard)\.exe$'
    try {
        foreach ($process in @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object { $_.Name -match $softwarePattern })) {
            $isKnownDpiTool = $process.Name -match '^(?i:goodbyedpi|byedpi|spoofdpi|ciadpi)\.exe$'
            $severity = if ($isKnownDpiTool) { 'Blocker' } else { 'Warning' }
            [void]$findings.Add((New-PreflightFinding ("SoftwareProcess-$($process.ProcessId)") $severity 'ConflictingSoftware' "Potentially conflicting process: $($process.Name) PID=$($process.ProcessId)" 'Close confirmed DPI/VPN/proxy software manually before testing.' (-not $isKnownDpiTool) ([string]$process.CommandLine)))
        }
    } catch {
        [void]$findings.Add((New-PreflightFinding 'SoftwareProcesses' 'Warning' 'ConflictingSoftware' 'Could not enumerate potentially conflicting processes.' 'Review running DPI/VPN/proxy software manually.' $true $_.Exception.Message))
    }

    try {
        $servicePattern = '(?i)goodbyedpi|byedpi|spoofdpi|openvpn|wireguard|tailscale|warp|clash|xray|sing-box|adguard'
        foreach ($service in @(Get-CimInstance Win32_Service -ErrorAction Stop | Where-Object {
            $_.State -eq 'Running' -and "$($_.Name) $($_.DisplayName) $($_.PathName)" -match $servicePattern
        })) {
            [void]$findings.Add((New-PreflightFinding ("SoftwareService-$($service.Name)") 'Warning' 'ConflictingSoftware' "Potentially conflicting service: $($service.Name) ($($service.DisplayName))" 'Confirm whether it supplies active DPI/VPN/proxy filtering.' $true ([string]$service.PathName)))
        }
    } catch {}

    $zapretState = Get-ZapretConflictState
    foreach ($service in @($zapretState.Services)) {
        [void]$findings.Add((New-PreflightFinding ("ZapretService-$($service.Name)") 'Info' 'ZapretState' "Zapret service found: $($service.Name), state=$($service.State)" 'It will be stopped only after all checks and explicit confirmation, then restored in finally.' $false $service.PathName))
    }
    foreach ($process in @($zapretState.ManualProcesses)) {
        [void]$findings.Add((New-PreflightFinding ("ZapretProcess-$($process.ProcessId)") 'Info' 'ZapretState' "Manual Zapret process found: $($process.Name) PID=$($process.ProcessId)" 'It will be stopped only after explicit confirmation and restarted when the exact command is safe.' $false $process.CommandLine))
    }

    return [pscustomobject]@{ Findings = @($findings); ConflictState = $zapretState }
}

function Show-PreflightFindings([array]$Findings) {
    Write-Host ''
    Write-Host 'Preflight results' -ForegroundColor Cyan
    Write-Host '----------------------------------------' -ForegroundColor DarkCyan
    foreach ($finding in $Findings) {
        $color = switch ($finding.Severity) {
            'Pass' { 'Green' }
            'Info' { 'DarkCyan' }
            'Warning' { 'Yellow' }
            'Blocker' { 'Red' }
        }
        Write-Host ("[{0}] {1}: {2}" -f $finding.Severity.ToUpperInvariant(), $finding.Code, $finding.Message) -ForegroundColor $color
        if ($finding.Action) { Write-Host "       $($finding.Action)" -ForegroundColor DarkGray }
    }
}

function Resolve-PreflightDecisions([array]$Findings) {
    foreach ($finding in @($Findings | Where-Object NeedsDecision)) {
        Write-Host ''
        Write-Host "Warning requiring a decision: $($finding.Message)" -ForegroundColor Yellow
        if (Read-YesNo 'Is this currently carrying active VPN/proxy/DPI traffic?' 'No') {
            $finding.Decision = 'confirmed-active'
            $finding.Severity = 'Blocker'
            $finding.Action = 'Disable it manually, then rerun all preflight checks.'
        } else {
            $finding.Decision = 'confirmed-not-active'
        }
    }
}
