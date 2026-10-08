# Service operations are kept separate so rollback can be tested without SCM.
function Get-ZapretServiceSnapshot {
    $service = Get-CimInstance Win32_Service -Filter "Name='winws2'" -ErrorAction Stop
    if (-not $service) { return $null }
    $metadata = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\winws2' -ErrorAction Stop
    return [pscustomobject]@{
        PathName = $service.PathName
        StartMode = if ($service.StartMode -eq 'Auto') { 'Automatic' } else { $service.StartMode }
        WasRunning = $service.State -ne 'Stopped'
        Strategy = $metadata.Zapret2NextStrategy
    }
}

function Assert-ZapretNoManualEngine {
    $service = Get-CimInstance Win32_Service -Filter "Name='winws2'" -ErrorAction Stop
    $servicePid = if ($service) { $service.ProcessId } else { 0 }
    $engines = @(Get-CimInstance Win32_Process -Filter "Name='winws2.exe' OR Name='winws.exe'" -ErrorAction Stop)
    if (@($engines | Where-Object { $_.ProcessId -ne $servicePid }).Count) {
        throw 'A manual or legacy winws process is running. Stop it before changing the service.'
    }
}

function Stop-ZapretService {
    $service = Get-Service winws2 -ErrorAction Stop
    if ($service.Status -ne 'Stopped') {
        if ($service.Status -ne 'StopPending') { $service.Stop() }
        $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
    }
}

function Start-ZapretService {
    $service = Get-Service winws2 -ErrorAction Stop
    if ($service.Status -ne 'Running' -and $service.Status -ne 'StartPending') { $service.Start() }
    $service.WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
    Start-Sleep -Seconds 3
    $service.Refresh()
    if ($service.Status -ne 'Running') { throw "Service stopped during startup ($($service.Status))." }
}

function Set-ZapretServiceRegistration {
    param([string]$ImagePath, [string]$Strategy, [bool]$Create)
    if ($Create) {
        New-Service -Name winws2 -BinaryPathName $ImagePath -DisplayName 'Zapret 2 NEXT' -StartupType Automatic -Description 'Zapret 2 NEXT DPI bypass service powered by Zapret 2' | Out-Null
        & sc.exe failure winws2 reset= 86400 actions= restart/5000/restart/15000/restart/60000 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Failed to configure service recovery (SC $LASTEXITCODE)." }
    } else {
        $service = Get-CimInstance Win32_Service -Filter "Name='winws2'" -ErrorAction Stop
        $result = Invoke-CimMethod -InputObject $service -MethodName Change -Arguments @{ PathName = $ImagePath; StartMode = 'Automatic' }
        if ($result.ReturnValue -ne 0) { throw "Service configuration failed (SCM $($result.ReturnValue))." }
    }
    Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\winws2' -Name Zapret2NextStrategy -Value $Strategy -Type String
}

function Restore-ZapretServiceRegistration {
    param($Snapshot)
    $service = Get-CimInstance Win32_Service -Filter "Name='winws2'" -ErrorAction Stop
    $result = Invoke-CimMethod -InputObject $service -MethodName Change -Arguments @{ PathName = $Snapshot.PathName; StartMode = $Snapshot.StartMode }
    if ($result.ReturnValue -ne 0) { throw "Cannot restore service registration (SCM $($result.ReturnValue))." }
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\winws2'
    if ($null -ne $Snapshot.Strategy) {
        Set-ItemProperty $key -Name Zapret2NextStrategy -Value $Snapshot.Strategy -Type String
    } else {
        Remove-ItemProperty $key -Name Zapret2NextStrategy -ErrorAction SilentlyContinue
    }
}

function Remove-ZapretServiceRegistration {
    if (Get-Service winws2 -ErrorAction SilentlyContinue) {
        Stop-ZapretService
        & sc.exe delete winws2 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Cannot remove failed new service (SC $LASTEXITCODE)." }
    }
}

function New-ZapretServiceCandidate {
    param([string]$Root, [string]$Preset, [string]$IPSetMode, [string]$Candidate)
    $renderer = Join-Path $Root 'utils\render-config.ps1'
    $dry = $Candidate + '.dry.txt'
    try {
        & $renderer -Preset $Preset -Output $Candidate -IPSetMode $IPSetMode | Out-Null
        & $renderer -Preset $Preset -Output $dry -IPSetMode $IPSetMode -DryRun | Out-Null
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'utils\invoke-winws.ps1') -Config $dry -LogPrefix (Join-Path $Root 'runtime\service-validate') -Validate
        if ($LASTEXITCODE -ne 0) { throw 'The engine rejected the new service config. See runtime\service-validate.*.log.' }
    } finally {
        Remove-Item -LiteralPath $dry -Force -ErrorAction SilentlyContinue
    }
}

function Remove-ZapretServiceConfiguration {
    param([string]$Root)
    $runtime = Join-Path $Root 'runtime'
    New-Item -ItemType Directory -Path $runtime -Force | Out-Null
    $lock = [IO.File]::Open((Join-Path $runtime 'engine-operation.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    try {
        $snapshot = Get-ZapretServiceSnapshot
        $config = Join-Path $runtime 'service.txt'
        $image = '"' + (Join-Path $Root 'bin\winws2.exe') + '" @"' + $config + '"'
        if ($snapshot) {
            if ($snapshot.PathName -ne $image) { throw 'The installed service belongs to another folder. Remove it using that bundle.' }
            Remove-ZapretServiceRegistration
        }
        Remove-Item -LiteralPath $config -Force -ErrorAction SilentlyContinue
        Write-Host '[OK] Zapret 2 NEXT service removed.' -ForegroundColor Green
    } finally {
        $lock.Dispose()
    }
}

function Set-ZapretServiceConfiguration {
    param([string]$Root, [string]$Preset, [string]$IPSetMode = 'loaded', [switch]$Install, [switch]$Restart)
    $runtime = Join-Path $Root 'runtime'
    New-Item -ItemType Directory -Path $runtime -Force | Out-Null
    $config = Join-Path $runtime 'service.txt'
    $image = '"' + (Join-Path $Root 'bin\winws2.exe') + '" @"' + $config + '"'
    $candidate = Join-Path $runtime ('service-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $lock = $null
    $changed = $false
    $registrationChanged = $false
    $stopped = $false
    try {
        $lock = [IO.File]::Open((Join-Path $runtime 'engine-operation.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
        $snapshot = Get-ZapretServiceSnapshot
        if (-not $Install -and -not $snapshot) { throw 'The winws2 service is not installed.' }
        if (-not $Install -and $snapshot.PathName -ne $image) {
            throw 'The installed service belongs to another folder or configuration. Use its Service Manager or install this bundle first.'
        }
        Assert-ZapretNoManualEngine
        $original = $null
        if ([IO.File]::Exists($config)) { $original = [IO.File]::ReadAllBytes($config) }
        New-ZapretServiceCandidate -Root $Root -Preset $Preset -IPSetMode $IPSetMode -Candidate $candidate
        if ($snapshot -and ($Install -or $Restart)) {
            $stopped = $true
            Stop-ZapretService
        }
        Write-AtomicTextFile -Path $config -Content ([IO.File]::ReadAllText($candidate)) -Encoding ([Text.UTF8Encoding]::new($false))
        $changed = $true
        if ($Install) {
            # Mark before the operation: a new service can be created even if
            # subsequent metadata/recovery configuration fails.
            $registrationChanged = $true
            Set-ZapretServiceRegistration -ImagePath $image -Strategy $Preset -Create (-not $snapshot)
        }
        if ($Install -or $Restart) { Start-ZapretService }
        Write-Host '[OK] Validated service configuration applied.' -ForegroundColor Green
    } catch {
        $failure = $_.Exception.Message
        if ($changed -or $stopped -or $registrationChanged) {
            try {
                if ($Install -or $Restart) {
                    if ($snapshot) { Stop-ZapretService } else { Remove-ZapretServiceRegistration }
                }
                if ($changed) {
                    if ($null -ne $original) {
                        Write-AtomicFileBytes -Path $config -Bytes $original
                    } else { Remove-Item -LiteralPath $config -Force }
                }
                if ($snapshot -and $registrationChanged) { Restore-ZapretServiceRegistration $snapshot }
                if ($snapshot -and $snapshot.WasRunning -and ($Install -or $Restart)) { Start-ZapretService }
                Write-Host '[WARN] Previous service configuration restored.' -ForegroundColor Yellow
            } catch {
                throw "$failure Rollback also failed: $($_.Exception.Message). Inspect runtime\service.txt and service state."
            }
        }
        throw $failure
    } finally {
        Remove-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue
        if ($lock) { $lock.Dispose() }
    }
}
