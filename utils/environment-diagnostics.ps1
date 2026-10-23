# Read-only checks shared by Quick check and the compatibility preflight.
function Get-ZapretEnvironmentDiagnostics([string]$Root, $Snapshot=$null) {
    if ($null -eq $Snapshot) {
        $services=@(); $processes=@(); $hosts=''; $doh=$null
        try { $services=@(Get-CimInstance Win32_Service -ErrorAction Stop) } catch {}
        try { $processes=@(Get-Process -ErrorAction Stop | ForEach-Object { $_.ProcessName + '.exe' }) } catch {}
        $hostsPath=Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
        try { $hosts=[IO.File]::ReadAllText($hostsPath) } catch {}
        $dns='HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\InterfaceSpecificParameters'
        try {
            if (Test-Path $dns) { $doh=@(Get-ChildItem $dns -Recurse -ErrorAction Stop | Get-ItemProperty -ErrorAction Stop | Where-Object { $_.DohFlags -gt 0 }).Count -gt 0 }
        } catch {}
        $Snapshot=@{Services=$services;Processes=$processes;Hosts=$hosts;DoH=$doh;OneDrive=@($env:OneDrive,$env:OneDriveConsumer,$env:OneDriveCommercial)}
    }
    $checks=@(
        @{Code='Happ';Pattern='(?i)\bHappService\b|\bhapp\.exe\b';Message='Happ network service or process is present.'},
        @{Code='AdGuard';Pattern='(?i)adguard';Message='AdGuard network filtering is present.'},
        @{Code='Killer';Pattern='(?i)killer';Message='Killer network services are present.'},
        @{Code='IntelConnectivity';Pattern='(?i)Intel.*Connectivity.*Network|IntelConnectivityNetworkService';Message='Intel Connectivity Network Service is present.'},
        @{Code='CheckPoint';Pattern='(?i)TracSrvWrapper|\bEPWD\b';Message='Check Point network services are present.'},
        @{Code='SmartByte';Pattern='(?i)SmartByte';Message='SmartByte network services are present.'}
    )
    $software=@($Snapshot.Processes) + @($Snapshot.Services | ForEach-Object { "$($_.Name) $($_.DisplayName)" })
    foreach ($check in $checks) {
        if ($software -match $check.Pattern) { [pscustomobject]@{Code=$check.Code;Severity='Warning';Message=$check.Message;Action='Temporarily disable the related network filter and retest; installed software alone does not prove a conflict.'} }
    }
    foreach ($line in ($Snapshot.Hosts -split '\r?\n')) {
        $entry=($line -split '#',2)[0]
        if ($entry -match '^\s*[0-9a-fA-F:.]+\s+.*\b(?:youtube\.com|youtu\.be)\b') {
            [pscustomobject]@{Code='YouTubeHosts';Severity='Warning';Message='The Windows hosts file overrides YouTube DNS.';Action='Review the YouTube hosts entries; stale addresses can break access.'}
            break
        }
    }
    if ($Snapshot.DoH -ne $true) {
        [pscustomobject]@{Code='SecureDNS';Severity='Info';Message='System encrypted DNS was not detected.';Action='Check secure DNS in your browser or Windows if name resolution fails; browser DoH cannot be inferred from this check.'}
    }
    foreach ($folder in @($Snapshot.OneDrive | Where-Object { $_ })) {
        $prefix=[IO.Path]::GetFullPath($folder).TrimEnd('\')
        $full=[IO.Path]::GetFullPath($Root).TrimEnd('\')
        if ($full -ieq $prefix -or $full.StartsWith($prefix+'\',[StringComparison]::OrdinalIgnoreCase)) {
            [pscustomobject]@{Code='OneDrivePath';Severity='Warning';Message='This bundle is inside a OneDrive directory.';Action='Use a local folder if cloud synchronization locks or removes components.'}
            break
        }
    }
    if ($Root -match '[\u0400-\u04ff]') {
        [pscustomobject]@{Code='UnicodePath';Severity='Info';Message='The bundle path contains Cyrillic characters.';Action='Unicode paths are supported; test a short local path if a third-party component fails.'}
    }
}
