# A transfer result is separate from protocol support and DNS/certificate failures.
function Get-ZapretTransferStatus([int]$ExitCode, [string]$ErrorText, [long]$Uploaded, [long]$Downloaded, [bool]$Dpi) {
    if ($ExitCode -eq 0) { return 'OK' }
    if ($ExitCode -in @(4,48) -or $ErrorText -match '(?i)not supported|unsupported protocol|unknown option|unrecognized option') { return 'UNSUPPORTED' }
    if ($ExitCode -eq 6) { return 'DNS_ERROR' }
    if ($ExitCode -in @(35,51,58,60,77,80,90)) { return 'TLS_ERROR' }
    if ($Dpi -and $ExitCode -in @(18,28,52,55,56) -and ($Uploaded -ge 16384 -or $Downloaded -ge 16384)) { return 'LIKELY_BLOCKED' }
    if ($ExitCode -eq 28) { return 'TIMEOUT' }
    return 'FAIL'
}
function Invoke-ZapretEndpointCheck($Target, [int]$TimeoutSeconds=5, [int]$RangeBytes=65536) {
    $checks=@()
    $dpi=$Target.Category -eq 'dpi'
    $payloadFile=$null
    $errorFile=Join-Path ([IO.Path]::GetTempPath()) ('zapret-curl-'+[guid]::NewGuid().ToString('N')+'.err')
    try {
        if ($dpi) {
            $payloadFile=Join-Path ([IO.Path]::GetTempPath()) ('zapret-probe-'+[guid]::NewGuid().ToString('N')+'.bin')
            $bytes=New-Object byte[] $RangeBytes
            $rng=[Security.Cryptography.RandomNumberGenerator]::Create()
            try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
            [IO.File]::WriteAllBytes($payloadFile,$bytes)
        }
        if ($Target.Url) {
            foreach ($test in @(@{Name='HTTP1.1';Args=@('--http1.1')},@{Name='TLS1.2';Args=@('--tlsv1.2','--tls-max','1.2')},@{Name='TLS1.3';Args=@('--tlsv1.3','--tls-max','1.3')})) {
                $curlArguments=@('--noproxy','*','-sS','--max-time',"$TimeoutSeconds",'--connect-timeout',"$([Math]::Min(3,$TimeoutSeconds))",'-o','NUL','-w','%{http_code} %{size_upload} %{size_download} %{time_total}') + $test.Args
                if ($dpi) { $curlArguments+=@('--range',('0-'+($RangeBytes-1)),'--max-filesize','2097152','-X','POST','--data-binary',('@'+$payloadFile)) }
                else { $curlArguments+=@('-I') }
                $previous=$ErrorActionPreference
                try {
                    $ErrorActionPreference='Continue'
                    $output=(& curl.exe @curlArguments $Target.Url 2>$errorFile | Out-String).Trim()
                    $code=$LASTEXITCODE
                } finally { $ErrorActionPreference=$previous }
                $errorText=if ([IO.File]::Exists($errorFile)) { [IO.File]::ReadAllText($errorFile) } else { '' }
                $http='000'; $up=0L; $down=0L; $time=0.0
                if ($output -match '(?<http>\d{3})\s+(?<up>\d+)\s+(?<down>\d+)\s+(?<time>[0-9.]+)$') {
                    $http=$matches.http; $up=[long]$matches.up; $down=[long]$matches.down
                    $time=[double]::Parse($matches.time,[Globalization.CultureInfo]::InvariantCulture)
                }
                $status=Get-ZapretTransferStatus $code $errorText $up $down $dpi
                if ($status -eq 'OK' -and ($http -eq '000' -or ($dpi -and ($up -ne $RangeBytes -or $down -eq 0)))) { $status='INCOMPLETE' }
                $checks+=[pscustomobject]@{Name=$test.Name;Status=$status;Success=$(if ($status -eq 'UNSUPPORTED') {$null} else {$status -eq 'OK'});Detail="curl $code / HTTP $http";UploadedBytes=$up;DownloadedBytes=$down;DurationMs=[long]($time*1000)}
            }
        }
        $pingStatus='n/a'; $pingSuccess=$null
        if (-not $dpi -and $Target.PingTarget) {
            $client=New-Object Net.NetworkInformation.Ping
            try {
                $reply=$client.Send($Target.PingTarget,1000)
                $pingSuccess=$reply.Status -eq [Net.NetworkInformation.IPStatus]::Success
                $pingStatus=if ($pingSuccess) { "$($reply.RoundtripTime)ms" } else { [string]$reply.Status }
            } catch { $pingSuccess=$false; $pingStatus='Timeout' } finally { $client.Dispose() }
        }
        [pscustomobject]@{Name=$Target.Name;Url=$Target.Url;Checks=$checks;PingStatus=$pingStatus;PingSuccess=$pingSuccess}
    } finally {
        if ($payloadFile -and [IO.File]::Exists($payloadFile)) { [IO.File]::Delete($payloadFile) }
        if ([IO.File]::Exists($errorFile)) { [IO.File]::Delete($errorFile) }
    }
}
