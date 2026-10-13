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

function Test-SupportServiceConfiguration {
    param([string]$ConfigPath = (Join-Path $root 'runtime\service.txt'))
    # A running engine can keep using files moved since startup. Verify its
    # saved references before stopping it, while recovery is still possible.
    $config = $ConfigPath
    if (-not (Test-Path -LiteralPath $config -PathType Leaf)) { return $false }
    try {
        $content = Get-Content -LiteralPath $config -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($content)) { return $false }
        $base = Join-Path $root 'bin'
        if ($content -match '(?m)^--chdir=(?:"([^"]+)"|([^\r\n]+))\r?$') {
            $base = if ($matches[1]) { $matches[1] } else { $matches[2].Trim() }
            if (-not [IO.Path]::IsPathRooted($base)) { $base = Join-Path $root $base }
        }
        if (-not (Test-Path -LiteralPath $base -PathType Container)) { return $false }
        $references = @([regex]::Matches($content, '@(?:"([^"]+)"|([^\s\r\n]+))')) +
            @([regex]::Matches($content, '(?m)^--(?:hostlist|hostlist-exclude|ipset|ipset-exclude)=(?:"([^"]+)"|([^\r\n]+))\r?$'))
        if (-not $references.Count) { return $false }
        foreach ($reference in $references) {
            $path = if ($reference.Groups[1].Success) { $reference.Groups[1].Value } else { $reference.Groups[2].Value.Trim() }
            if (-not [IO.Path]::IsPathRooted($path)) { $path = Join-Path $base $path }
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
        }
        return $true
    } catch { return $false }
}

function Get-SupportSoftwareLabel([object]$Finding) {
    # Only fixed product names may appear in the shared report. Never copy
    # service names, process IDs, command lines or paths from local evidence.
    $text = [string]$Finding.Code + ' ' + [string]$Finding.Message
    foreach ($product in @(
        @('tailscale(?:d)?', 'Tailscale'), @('proxifier', 'Proxifier'),
        @('goodbyedpi', 'GoodbyeDPI'), @('byedpi', 'ByeDPI'),
        @('spoofdpi', 'SpoofDPI'), @('ciadpi', 'ciadpi'),
        @('xray', 'Xray'), @('sing-box', 'sing-box'), @('nekoray', 'Nekoray'),
        @('v2rayn', 'v2rayN'), @('clash[^\s.()]*', 'Clash'),
        @('warp(?:-svc)?', 'WARP'), @('wireguard', 'WireGuard'),
        @('openvpn', 'OpenVPN'), @('adguard', 'AdGuard')
    )) {
        if ($text -match ('(?i)(?<![a-z0-9])' + $product[0] + '(?![a-z0-9])')) { return $product[1] }
    }
    return ''
}

function ConvertTo-SupportFinding([object]$Finding) {
    $code = ([string]$Finding.Code -split '-', 2)[0]
    $descriptions = @{
        Administrator=@('Права администратора', 'Откройте service.bat и подтвердите запрос Windows.')
        BFE=@('Служба фильтрации Windows BFE', 'Запустите службу BFE и повторите проверку.')
        File=@('Наличие компонентов сборки', 'Распакуйте полный ZIP релиза в отдельную папку.')
        curl=@('Сетевой инструмент curl', 'Проверьте наличие curl в Windows.')
        WinDivertDriver=@('Драйвер WinDivert', 'Если другая программа использует WinDivert, закройте её перед проверкой.')
        ComponentHashes=@('Контрольные суммы компонентов', 'Распакуйте полный ZIP релиза в отдельную папку.')
        IPSetEntries=@('Наличие IPSet', 'Обновите IPSet через service.bat.')
        ForeignZapret=@('Обнаружена другая копия Zapret или ручной процесс', 'Остановите другую сборку или запустите диагностику из папки установленной службы.')
        ServiceTransition=@('Служба Zapret переключается или приостановлена', 'Дождитесь завершения переключения службы и повторите проверку.')
        ServiceConfiguration=@('Файлы сохранённого конфига службы', 'В service.bat выберите 1. Install Service и прежнюю стратегию: конфиг будет создан заново с актуальными путями.')
        EngineEnumeration=@('Не удалось исключить ручной или старый движок Zapret', 'Проверьте состояние Zapret и права администратора.')
        WinINETProxy=@('В Windows включён системный прокси', 'Отключите прокси в Windows: Параметры → Сеть и Интернет → Прокси, затем повторите проверку.')
        WinINETAutoConfig=@('В Windows настроен сценарий автоматического прокси', 'Отключите сценарий в Windows: Параметры → Сеть и Интернет → Прокси, затем повторите проверку.')
        WinHTTPProxy=@('Настройка прокси WinHTTP', 'Проверьте и отключите прокси WinHTTP на время диагностики.')
        ProxyEnvironment=@('Настройки прокси в переменных окружения', 'На время проверки отключите HTTP_PROXY, HTTPS_PROXY и ALL_PROXY и заново откройте service.bat.')
        DefaultRoutes=@('Проверка маршрутов подключения', 'Проверьте, использует ли подключение VPN.')
        Adapter=@('Сетевой адаптер VPN или overlay', 'Если VPN направляет интернет-трафик через себя, отключите его на время проверки.')
        Adapters=@('Проверка сетевых адаптеров', 'Проверьте активные VPN-подключения.')
        SoftwareProcess=@('Обнаружена возможная конфликтующая программа', 'Проверьте, обрабатывает ли она интернет-трафик; если да, отключите её на время проверки.')
        SoftwareService=@('Обнаружена возможная конфликтующая служба', 'Проверьте, обрабатывает ли она интернет-трафик; если да, отключите её на время проверки.')
        SoftwareProcesses=@('Проверка конфликтующих программ', 'Проверьте активные программы VPN, прокси и обхода блокировок.')
        ZapretService=@('Состояние службы Zapret', '')
        ZapretProcess=@('Ручной процесс Zapret', 'Закройте ручной запуск Zapret перед проверкой.')
        Environment=@('Проверка окружения', 'Устраните препятствие и повторите проверку.')
    }
    if (-not $descriptions.ContainsKey($code)) { $code = 'Environment' }
    $severity = if ($Finding.Severity -in @('Pass','Info','Warning','Blocker')) { $Finding.Severity } else { 'Warning' }
    $message = $descriptions[$code][0]
    if ($code -in @('SoftwareProcess','SoftwareService')) {
        $product = Get-SupportSoftwareLabel $Finding
        if ($product) { $message += ': ' + $product }
    }
    if ($code -eq 'Adapter' -and $severity -eq 'Blocker') { $message = 'VPN или overlay использует маршрут по умолчанию' }
    if ($severity -eq 'Pass') {
        # A successful check must not claim that a proxy or conflict is present.
        $message = switch ($code) {
            'WinINETProxy' { 'Системный прокси Windows выключен' }
            'WinHTTPProxy' { 'WinHTTP настроен на прямое подключение' }
            'ProxyEnvironment' { 'Переменные прокси не обнаружены' }
            'WinDivertDriver' { 'Другой запущенный драйвер WinDivert не обнаружен' }
            'Adapter' { 'Основной сетевой адаптер' }
            default { $message }
        }
    }
    return [pscustomobject]@{
        code=$code; severity=$severity; message=$message
        action=if ($severity -in @('Blocker','Warning')) { $descriptions[$code][1] } else { '' }
    }
}

function Show-SupportFindings([array]$Findings) {
    $attention = @($Findings | Where-Object { $_.Severity -in @('Blocker','Warning') } |
        ForEach-Object { ConvertTo-SupportFinding $_ } | Sort-Object severity,message -Unique)
    foreach ($check in $attention) {
        $label = if ($check.severity -eq 'Blocker') { 'Нужно исправить' } else { 'Обратите внимание' }
        Write-Host "[$label] $($check.message)" -ForegroundColor Yellow
        if ($check.action) { Write-Host "  $($check.action)" }
    }
}

function Get-SupportEnvironment {
    $snapshot = Get-PreflightSnapshot -SkipVoiceChecks
    $findings = @($snapshot.Findings | ForEach-Object { $_.PSObject.Copy() })
    # Presence alone does not prove active filtering: Tailscale without an
    # exit-node/default route and an idle proxy UI must remain warnings.
    foreach ($finding in $findings) {
        if (($finding.Category -eq 'ConflictingSoftware' -and
                (Get-SupportSoftwareLabel $finding) -in @('GoodbyeDPI','ByeDPI','SpoofDPI','ciadpi')) -or
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
    if ($service -and -not $foreignService) {
        $serviceConfigOk = Test-SupportServiceConfiguration
        $findings += New-PreflightFinding 'ServiceConfiguration' $(if ($serviceConfigOk) { 'Pass' } else { 'Blocker' }) 'ZapretState' 'Saved service configuration references check'
    }
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
    $checks = @($script:support.findings | ForEach-Object { ConvertTo-SupportFinding $_ })
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
            'EngineCleanupFailed','ServiceRestoreFailed','StateChanged','StateReadFailed','EnvironmentBlocked','DNSResolutionFailed')
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
    foreach ($check in $document.checks) {
        $lines += "[$($check.severity)] $($check.message)"
        if ($check.action) { $lines += '  ' + $check.action }
    }
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
    $networkSummary = if ($document.webResults.Count) {
        'Проверена DNS/TLS/HTTP-доступность указанных адресов. Ответ HTTP сам по себе не подтверждает обход блокировки.'
    } else { 'Сетевые проверки не выполнялись; доступность адресов и работа стратегий не проверены.' }
    $lines += @('', "Коды проблем: $($document.issues -join ', ')", $networkSummary,
        'Звонки, демонстрация экрана и воспроизведение видео автоматически не проверялись.',
        'IPSet=any используется только для диагностики; настройки не применяются.',
        'Приложите этот ZIP к обращению на GitHub. Отправка выполняется вручную.')
    if ($document.issues -contains 'DNSResolutionFailed') {
        $lines += @('', 'В части запросов не удалось определить адрес сайта (ошибка DNS, curl=6).',
            'Это не подтверждает, что сайт не работает в браузере: его DNS, прокси и сохранённые соединения могут отличаться.',
            'Цели с такой ошибкой указаны в web-results.csv; подробности curl сохранены только в local/results-local.json.')
    }
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
        catch { Add-SupportIssue 'OperationBusy'; $script:support.status='blocked'; $exitCode=3; break }
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
            Add-SupportIssue 'EnvironmentReadFailed'; $script:support.status='blocked'; $exitCode=3
            $_ | Out-String | Set-Content -LiteralPath (Join-Path $script:resultDir 'errors-local.txt') -Encoding UTF8
            break
        }
        Show-SupportFindings $environment.Findings
        if ($environment.Blocked) {
            Add-SupportIssue 'EnvironmentBlocked'; $script:support.status='blocked'; $exitCode=3; break
        }
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
                try { $_ | Out-String | Set-Content -LiteralPath (Join-Path $script:resultDir 'service-restore-local.txt') -Encoding UTF8 } catch {}
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
        if (@($script:result.webResults | Where-Object CurlExitCode -eq 6).Count) { Add-SupportIssue 'DNSResolutionFailed' }
        try {
            Write-Utf8File (Join-Path $script:resultDir 'results-local.json') (($script:result | ConvertTo-Json -Depth 10) + "`r`n")
        } catch { Write-Host 'Подробности локальных проверок не удалось сохранить; подготовка ZIP продолжается.' -ForegroundColor Yellow }
        # The finally block also publishes blocked and canceled partial reports.
        $zip = Save-SupportArtifacts $run
        $script:supportArtifact = [pscustomobject]@{ ZipPath=$zip; Directory=$run; ExitCode=$exitCode; Status=$script:support.status; Issues=@($script:support.issues) }
    }
    return $script:supportArtifact
}
