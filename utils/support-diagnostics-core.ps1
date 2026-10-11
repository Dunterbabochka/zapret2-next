# Shared wizard probes keep their detailed output local. Only the explicit
# projection in New-SupportPublicDocument may cross the support ZIP boundary.
function Read-SupportSettings {
    $settings = [ordered]@{}
    foreach ($definition in @(
        @('game', 'game_filter.mode', 'off', @('off','tcp','udp','all')),
        @('ipset', 'ipset_filter.mode', 'loaded', @('loaded','none','any')),
        @('voice', 'voice_filter.mode', 'compatible', @('off','standard','compatible')),
        @('discordFake', 'discord_fake.mode', 'current', @('current','steam','google')),
        @('gameFake', 'game_fake.mode', 'current', @('current','steam','dbank-v2'))
    )) {
        $value = $definition[2]
        $path = Join-Path $root ('utils\' + $definition[1])
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $saved = (Get-Content -LiteralPath $path -Raw).Trim().ToLowerInvariant()
            if ($saved -in $definition[3]) { $value = $saved }
        }
        $settings[$definition[0]] = $value
    }
    return $settings
}

function Get-SupportStateHashes {
    $state = Get-UserStateHashes
    $config = Join-Path $root 'runtime\service.txt'
    $state['serviceConfig'] = if (Test-Path -LiteralPath $config -PathType Leaf) {
        (Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash
    } else { '<missing>' }
    return $state
}

function Test-SupportComponentHashes {
    $manifest = Join-Path $root 'SHA256SUMS.txt'
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { return $false }
    $count = 0
    foreach ($line in Get-Content -LiteralPath $manifest) {
        if (-not $line.Trim() -or $line.StartsWith('#')) { continue }
        if ($line -notmatch '^([A-Fa-f0-9]{64})\s+(.+)$') { return $false }
        $expected = $matches[1]
        $relative = $matches[2].Trim()
        if ([IO.Path]::IsPathRooted($relative) -or $relative.Contains(':')) { return $false }
        $path = [IO.Path]::GetFullPath((Join-Path $root $relative))
        if (-not $path.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { return $false }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $expected) { return $false }
        $count++
    }
    return $count -gt 0
}

function Get-SupportEnvironment {
    $snapshot = Get-PreflightSnapshot -SkipVoiceChecks
    $findings = @($snapshot.Findings)
    # There are no interactive VPN decisions in automatic mode. Active default
    # VPN routes or known filtering programs make the scan inconclusive.
    foreach ($finding in $findings) {
        if ($finding.Category -eq 'ConflictingSoftware' -or
            ($finding.Code -like 'Adapter-*' -and $finding.Message -match '(Overlay|VpnCandidate).*default-route=True')) {
            $finding.Severity = 'Blocker'
        }
    }
    $hashesOk = Test-SupportComponentHashes
    $findings += New-PreflightFinding 'ComponentHashes' $(if ($hashesOk) { 'Pass' } else { 'Blocker' }) 'Runtime' 'Component integrity check'
    $ipset = Join-Path $root 'lists\ipset-all.txt'
    $ipsetCount = if (Test-Path -LiteralPath $ipset -PathType Leaf) {
        @((Get-Content -LiteralPath $ipset) | Where-Object { $_ -notmatch '^\s*(?:#|$)' }).Count
    } else { 0 }
    $findings += New-PreflightFinding 'IPSetEntries' $(if ($ipsetCount -gt 0) { 'Pass' } else { 'Warning' }) 'Network' 'Loaded IPSet check'
    $service = Get-ZapretServiceSnapshot
    try { Assert-ZapretNoManualEngine } catch {
        $findings += New-PreflightFinding 'EngineEnumeration' 'Blocker' 'ZapretState' 'Cannot exclude a manual or legacy engine'
    }
    $expectedImage = '"' + (Join-Path $root 'bin\winws2.exe') + '" @"' + (Join-Path $root 'runtime\service.txt') + '"'
    $foreignService = $null -ne $service -and $service.PathName -ne $expectedImage
    $otherServices = @($snapshot.ConflictState.Services | Where-Object { $_.Name -ne 'winws2' -and $_.WasRunning })
    if ($foreignService -or $otherServices.Count -or @($snapshot.ConflictState.ManualProcesses).Count) {
        $findings += New-PreflightFinding 'ForeignZapret' 'Blocker' 'ZapretState' 'Another Zapret instance is present'
    }
    $unstable = @($snapshot.ConflictState.Services | Where-Object { $_.Name -eq 'winws2' -and $_.State -notin @('Running','Stopped') })
    if ($unstable.Count) { $findings += New-PreflightFinding 'ServiceTransition' 'Blocker' 'ZapretState' 'Service is transitioning or paused' }
    return [pscustomobject]@{
        Findings = $findings; Service = $service; IPSetEntries = $ipsetCount
        Blocked = @($findings | Where-Object Severity -eq 'Blocker').Count -gt 0
        PrivateSnapshot = $snapshot
    }
}

function Get-SupportVersions {
    $system = Get-WindowsInfo
    $version = (Get-Content -LiteralPath (Join-Path $root '.service\version.txt') -Raw).Trim()
    $engine = @(Get-Content -LiteralPath (Join-Path $root 'ENGINE_VERSION') | Where-Object { $_ -match '^zapret2_version=' })
    return [ordered]@{
        bundle = if ($version -match '^\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?$') { $version } else { 'unknown' }
        engine = if ($engine.Count -and $engine[0] -match '^zapret2_version=(\d+(?:\.\d+)+)$') { $matches[1] } else { 'unknown' }
        windows = if ($system.Version -match '^\d+(?:\.\d+)+$') { $system.Version } else { 'unknown' }
        architecture = if ([Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' }
    }
}

function Add-SupportIssue([string]$Code) {
    $script:support.issues += $Code
}

function Stop-SupportService { Stop-ZapretService }
function Restore-SupportService { Start-ZapretService }

function Invoke-SupportBaseline {
    foreach ($target in $script:targets) {
        $script:result.webResults += Invoke-CurlEndpoint -Target $target -Phase 'baseline' -Preset '' -Pass 1 -IPSetMode 'none' -VoiceMode 'off'
    }
}

function Invoke-SupportPreset([string]$Preset, [string]$IPSetMode) {
    try {
        Invoke-WebPass -Preset $Preset -Pass 1 -IPSetMode $IPSetMode -VoiceMode 'off' -Phase 'support-scan' | Out-Null
    } catch [OperationCanceledException] { throw } catch {
        # A broken preset must not prevent checks of the remaining strategies.
        $_ | Out-String | Add-Content -LiteralPath (Join-Path $script:resultDir 'errors-local.txt') -Encoding UTF8
        Add-SupportIssue 'EngineStartFailed'
        foreach ($target in $script:targets) {
            $script:result.webResults += [pscustomobject]@{
                Phase='support-scan'; Preset=$Preset; IPSetMode=$IPSetMode; VoiceMode='off'
                Target=$target.Name; Mandatory=[bool]$target.Mandatory; Success=$false
                CurlExitCode=-1; HttpCode='000'; DurationMs=0
            }
        }
    }
}

function ConvertTo-SupportErrorCode([int]$CurlExitCode) {
    switch ($CurlExitCode) {
        0 { 'None' }; 5 { 'ProxyResolution' }; 6 { 'DNS' }; 7 { 'Connection' }
        28 { 'Timeout' }; 35 { 'TLS' }; 51 { 'TLSCertificate' }; 60 { 'TLSCertificate' }
        -1 { 'EngineStart' }; default { 'Network' }
    }
}

function New-SupportPublicDocument {
    $versions = [ordered]@{}
    foreach ($key in @('bundle','engine','windows')) {
        $value = [string]$script:support.versions[$key]
        $versions[$key] = if ($value -match '^\d+(?:\.\d+)+(?:-[A-Za-z0-9.-]+)?$') { $value } else { 'unknown' }
    }
    $versions.architecture = if ($script:support.versions.architecture -in @('x64','x86')) { $script:support.versions.architecture } else { 'unknown' }
    $settings = [ordered]@{}
    foreach ($key in @('game','ipset','voice','discordFake','gameFake')) {
        $value = [string]$script:support.settings[$key]
        $settings[$key] = if ($value -in @('off','tcp','udp','all','loaded','none','any','standard','compatible','current','steam','google','dbank-v2')) { $value } else { 'unknown' }
    }
    $checks = @($script:support.findings | ForEach-Object {
        $code = ([string]$_.Code -split '-', 2)[0]
        if ($code -notin @('Administrator','BFE','File','curl','WinDivertDriver','WinINETProxy','WinINETAutoConfig',
            'WinHTTPProxy','ProxyEnvironment','DefaultRoutes','Adapter','Adapters','SoftwareProcess','SoftwareService',
            'SoftwareProcesses','ZapretService','ZapretProcess','ComponentHashes','IPSetEntries','ForeignZapret','ServiceTransition','EngineEnumeration')) { $code = 'Environment' }
        [pscustomobject]@{
            code = $code
            severity = if ($_.Severity -in @('Pass','Info','Warning','Blocker')) { $_.Severity } else { 'Warning' }
        }
    })
    $rows = @($script:result.webResults | ForEach-Object {
        $row = $_
        $target = @($script:targets | Where-Object { $_.Name -eq $row.Target } | Select-Object -First 1)
        if ($target.Count -eq 1 -and $row.Preset -in @(@('') + $publicPresets) -and
            $row.Phase -in @('baseline','support-scan') -and $row.IPSetMode -in @('none','loaded','any')) {
            [pscustomobject]@{
                phase = $row.Phase; preset = $row.Preset; ipset = $row.IPSetMode
                target = $target[0].Name; mandatory = [bool]$target[0].Mandatory
                reachable = [bool]$row.Success; curlExitCode = [int]$row.CurlExitCode
                httpCode = if ([string]$row.HttpCode -match '^\d{3}$') { [string]$row.HttpCode } else { '000' }
                durationMs = [Math]::Max(0, [Math]::Round([double]$row.DurationMs, 2))
                errorCode = ConvertTo-SupportErrorCode ([int]$row.CurlExitCode)
            }
        }
    })
    $issues = @($script:support.issues | Where-Object {
        $_ -in @('EnvironmentReadFailed','OperationBusy','EngineStartFailed','ScanFailed','Canceled',
            'EngineCleanupFailed','ServiceRestoreFailed','StateChanged','StateReadFailed')
    } | Select-Object -Unique)
    return [ordered]@{
        schema = 'zapret2-next.support-report'; schemaVersion = 1
        status = $script:support.status
        startedAtUtc = $script:support.startedAtUtc; finishedAtUtc = $script:support.finishedAtUtc
        provider = $script:support.provider; regionCity = $script:support.regionCity
        versions = $versions; settings = $settings
        ipsetEntries = [int]$script:support.ipsetEntries; checks = $checks; webResults = $rows; issues = $issues
        statePreserved = [bool]$script:support.statePreserved
        serviceRestored = [bool]$script:support.serviceRestored
        voiceTested = $false; videoPlaybackTested = $false; screenShareTested = $false
    }
}

function Save-SupportArtifacts([string]$RunDirectory) {
    $share = Join-Path $RunDirectory 'share'
    New-Item -ItemType Directory -Force -Path $share | Out-Null
    $document = New-SupportPublicDocument
    Write-Utf8File (Join-Path $share 'results.json') (($document | ConvertTo-Json -Depth 10) + "`r`n")
    $csv = Join-Path $share 'web-results.csv'
    if ($document.webResults.Count) { $document.webResults | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8 }
    else { Write-Utf8File $csv '"phase","preset","ipset","target","mandatory","reachable","curlExitCode","httpCode","durationMs","errorCode"' }
    $lines = @(
        'Zapret 2 NEXT — отчёт для обращения',
        "Статус: $($document.status)", "Провайдер: $($document.provider)", "Область/город: $($document.regionCity)",
        "Сборка: $($document.versions.bundle); движок: $($document.versions.engine); Windows: $($document.versions.windows)",
        "Начало UTC: $($document.startedAtUtc); окончание UTC: $($document.finishedAtUtc)",
        "Записей IPSet: $($document.ipsetEntries)",
        "Настройки сохранены: $($document.statePreserved); состояние службы восстановлено: $($document.serviceRestored)",
        '', 'Проверки окружения (подробности — в results.json):'
    )
    $explanations = @{
        Administrator='Права администратора'; BFE='Служба фильтрации Windows'; File='Компоненты сборки'; curl='Сетевой инструмент curl'
        WinDivertDriver='Драйвер WinDivert'; ComponentHashes='Контрольные суммы компонентов'; IPSetEntries='Наличие IPSet'
        ForeignZapret='Другая копия Zapret или ручной процесс'; ServiceTransition='Служба ещё переключается или приостановлена'
        EngineEnumeration='Не удалось исключить ручной или старый движок Zapret'
        WinINETProxy='Системный прокси'; WinINETAutoConfig='Автоматическая настройка прокси'; WinHTTPProxy='Прокси WinHTTP'
        ProxyEnvironment='Прокси в переменных окружения'; Adapter='Активный сетевой адаптер'; Adapters='Проверка адаптеров'
        DefaultRoutes='Маршруты подключения'; SoftwareProcess='Возможная конфликтующая программа'; SoftwareService='Возможная конфликтующая служба'
        SoftwareProcesses='Проверка программ'; ZapretService='Служба Zapret'; ZapretProcess='Ручной процесс Zapret'; Environment='Проверка окружения'
    }
    foreach ($check in $document.checks) { $lines += "[$($check.severity)] $($explanations[$check.code])" }
    $lines += @('', 'Доступность проверенных адресов:')
    foreach ($preset in @(@('') + $publicPresets)) {
        foreach ($mode in @('none','loaded','any')) {
            $rows = @($document.webResults | Where-Object { $_.preset -eq $preset -and $_.ipset -eq $mode })
            if ($rows.Count) {
                $name = if ($preset) { $preset } else { 'Без Zapret' }
                $lines += "${name}, IPSet=${mode}: $(@($rows | Where-Object reachable).Count)/$($rows.Count) адресов доступны"
            }
        }
    }
    $lines += @('', "Коды проблем: $($document.issues -join ', ')",
        'Проверена DNS/TLS/HTTP-доступность адресов. Ответ HTTP сам по себе не подтверждает обход блокировки.',
        'Звонки, демонстрация экрана и воспроизведение видео автоматически не проверялись.',
        'IPSet=any используется только для диагностики; настройки не применяются.',
        'Приложите этот ZIP к обращению на GitHub. Отправка выполняется вручную.')
    Write-Utf8File (Join-Path $share 'REPORT.txt') (($lines -join "`r`n") + "`r`n")
    $files = @('REPORT.txt','results.json','web-results.csv') | ForEach-Object { Join-Path $share $_ }
    # Never archive a runtime directory recursively: local logs can contain secrets.
    $zip = $RunDirectory + '.zip'
    Compress-Archive -LiteralPath $files -DestinationPath $zip -CompressionLevel Optimal
    return $zip
}

function Invoke-SupportDiagnostics {
    param([Parameter(Mandatory)][string]$Provider, [string]$RegionCity = '')
    if ([string]::IsNullOrWhiteSpace($Provider) -or $Provider.Length -gt 160 -or $RegionCity.Length -gt 160) {
        throw 'Provider is required; provider and region must be at most 160 characters.'
    }
    $id = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $run = Join-Path $root ('runtime\support-reports\support-' + $id)
    $script:resultDir = Join-Path $run 'local'
    New-Item -ItemType Directory -Force -Path $script:resultDir | Out-Null
    $script:result = [ordered]@{ errors=@(); engineRuns=@(); webResults=@() }
    $script:support = [ordered]@{
        provider=$Provider.Trim(); regionCity=$RegionCity.Trim(); status='started'
        startedAtUtc=[DateTime]::UtcNow.ToString('o'); finishedAtUtc=$null
        versions=@{ bundle='unknown'; engine='unknown'; windows='unknown'; architecture='unknown' }
        settings=@{}; findings=@(); ipsetEntries=0; issues=@(); statePreserved=$true; serviceRestored=$true
    }
    $script:targets = @()
    $lock = $null; $serviceStopped = $false; $stateBefore = $null; $exitCode = 0
    try {
        do {
        Write-Host 'Служба этой папки будет временно остановлена и восстановлена в конце проверки.' -ForegroundColor Yellow
        Write-Host 'Проверка всех стратегий может занять несколько минут. Показан прогресс; Ctrl+C — отмена.'
        if (-not (Read-YesNo 'Начать автоматическую проверку?' 'No')) { throw [OperationCanceledException]::new() }
        try { $lock = [IO.File]::Open((Join-Path $root 'runtime\engine-operation.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
        catch { Add-SupportIssue 'OperationBusy'; $script:support.status='blocked'; break }
        $stateBefore = Get-SupportStateHashes
        $script:support.settings = Read-SupportSettings
        try {
            $script:support.versions = Get-SupportVersions
            $script:targets = @(Get-WizardTargets)
            $environment = Get-SupportEnvironment
            $script:support.findings = @($environment.Findings)
            $script:support.ipsetEntries = $environment.IPSetEntries
            $environment.PrivateSnapshot | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $script:resultDir 'preflight-local.json') -Encoding UTF8
        } catch {
            Add-SupportIssue 'EnvironmentReadFailed'; $script:support.status='blocked'
            $_ | Out-String | Set-Content -LiteralPath (Join-Path $script:resultDir 'errors-local.txt') -Encoding UTF8
            break
        }
        if ($environment.Blocked) { $script:support.status='blocked'; break }
        if ($environment.Service -and $environment.Service.WasRunning) {
            $serviceStopped=$true; $script:support.serviceRestored=$false
            Stop-SupportService
        }
        Write-Progress -Activity 'Автоматическая диагностика' -Status 'Проверка без Zapret' -PercentComplete 0
        Invoke-SupportBaseline
        $failed = @(); $index=0
        foreach ($preset in $publicPresets) {
            Write-Progress -Activity 'Автоматическая диагностика' -Status "$preset / IPSet=loaded" -PercentComplete ([int](90 * $index / (2 * $publicPresets.Count)))
            Invoke-SupportPreset $preset 'loaded'
            $rows = @($script:result.webResults | Where-Object { $_.Preset -eq $preset -and $_.IPSetMode -eq 'loaded' -and $_.Mandatory })
            if (-not $rows.Count -or @($rows | Where-Object { -not $_.Success }).Count) { $failed += $preset }
            $index++
        }
        foreach ($preset in $failed) {
            Write-Progress -Activity 'Автоматическая диагностика' -Status "$preset / IPSet=any (диагностика)" -PercentComplete ([int](90 * $index / ($publicPresets.Count + $failed.Count)))
            Invoke-SupportPreset $preset 'any'; $index++
        }
        $script:support.status='completed'
        } while ($false)
    } catch [OperationCanceledException] {
        $script:support.status='canceled'; Add-SupportIssue 'Canceled'; $exitCode=2
    } catch {
        $script:support.status='failed'; Add-SupportIssue 'ScanFailed'; $exitCode=1
        $_ | Out-String | Add-Content -LiteralPath (Join-Path $script:resultDir 'errors-local.txt') -Encoding UTF8
    } finally {
        # Cleanup and restoration precede export, including export failures.
        try {
            Stop-WizardEngine
            if ($script:result.errors.Count) { throw 'Engine cleanup failed' }
        } catch { Add-SupportIssue 'EngineCleanupFailed'; $script:support.status='failed'; $exitCode=1 }
        if ($serviceStopped) {
            try { Restore-SupportService; $script:support.serviceRestored=$true }
            catch {
                Add-SupportIssue 'ServiceRestoreFailed'; $script:support.status='failed'; $exitCode=1
                Write-Host 'Не удалось запустить прежнюю службу. Откройте service.bat и установите прежнюю стратегию.' -ForegroundColor Red
            }
        }
        if ($null -ne $stateBefore) {
            try {
                $stateAfter = Get-SupportStateHashes
                foreach ($key in $stateBefore.Keys) {
                    if ($stateBefore[$key] -ne $stateAfter[$key]) { $script:support.statePreserved=$false }
                }
                if (-not $script:support.statePreserved) { Add-SupportIssue 'StateChanged'; $script:support.status='failed'; $exitCode=1 }
            } catch { $script:support.statePreserved=$false; Add-SupportIssue 'StateReadFailed'; $script:support.status='failed'; $exitCode=1 }
        }
        if ($lock) { $lock.Dispose() }
        $script:support.finishedAtUtc=[DateTime]::UtcNow.ToString('o')
        Write-Progress -Activity 'Автоматическая диагностика' -Completed
        # The finally block also publishes blocked and canceled partial reports.
        $zip = Save-SupportArtifacts $run
        $script:supportArtifact = [pscustomobject]@{ ZipPath=$zip; Directory=$run; ExitCode=$exitCode; Status=$script:support.status }
    }
    return $script:supportArtifact
}
