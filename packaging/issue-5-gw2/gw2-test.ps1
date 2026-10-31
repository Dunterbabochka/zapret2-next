[CmdletBinding()]
param([switch]$Restore, [ValidateRange(20,120)][int]$CaptureSeconds=45, [switch]$FunctionsOnly, [switch]$ElevatedChild)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'gw2-core.ps1')
$script:root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\')
$script:statePath = Join-Path $PSScriptRoot 'active-state.json'
$script:engine = $null
$script:state = $null
$script:runPath = $null
$script:stage = 'preflight'

function Get-GW2Service {
    $services = @(Get-CimInstance Win32_Service -Filter "Name='winws2' OR Name='zapret'")
    foreach ($service in $services) {
        if ($service.Name -eq 'zapret' -and $service.State -ne 'Stopped') { throw 'An older Zapret service is running.' }
    }
    $service = @($services | Where-Object Name -eq winws2)
    if (-not $service.Count) { return $null }
    $expected = '"'+(Join-Path $script:root 'bin\winws2.exe')+'" @"'+(Join-Path $script:root 'runtime\service.txt')+'"'
    if ($service[0].PathName.Trim() -ine $expected) { throw 'The winws2 service belongs to another folder or has a different command.' }
    if ($service[0].State -notin @('Running','Stopped')) { throw 'The service is transitioning or paused.' }
    return $service[0]
}
function Assert-GW2NoManualEngine {
    $service = Get-GW2Service
    $servicePid = if ($service) { [int]$service.ProcessId } else { 0 }
    $processes = @(Get-CimInstance Win32_Process -Filter "Name='winws2.exe' OR Name='winws.exe'")
    if (@($processes | Where-Object { $_.ProcessId -ne $servicePid }).Count) { throw 'A manual or foreign winws process is running. Close it first.' }
}
function Save-GW2State { Write-GW2Json $script:statePath $script:state }
function Stop-GW2OriginalService {
    Assert-GW2NoManualEngine
    $service = Get-GW2Service
    if ($service -and $service.State -eq 'Running') {
        $script:state.restoreNeeded = $true
        Save-GW2State
        Stop-Service -Name winws2
        (Get-Service winws2).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
    }
}
function Stop-GW2TestEngine {
    if ($script:engine) {
        if (-not $script:engine.HasExited) { $script:engine.Kill() }
        if (-not $script:engine.WaitForExit(10000)) { throw 'Test engine did not stop.' }
        $script:engine.Dispose(); $script:engine = $null
    }
    if ($script:state -and $script:state.engine) { $script:state.engine=$null; Save-GW2State }
}
function Restore-GW2OriginalService {
    if (-not $script:state) { return }
    Assert-GW2NoManualEngine
    $service = Get-GW2Service
    if ($script:state.restoreNeeded) {
        if (-not $service) { throw 'Original service is missing; restore it through service.bat.' }
        if ($service.State -ne 'Running') {
            Start-Service winws2
            (Get-Service winws2).WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
        }
        Start-Sleep -Seconds 2
        if ((Get-Service winws2).Status -ne 'Running') { throw 'Original service exited after restart.' }
        $script:state.restoreNeeded=$false; Save-GW2State
    }
    $running = $service -and (Get-Service winws2).Status -eq 'Running'
    if ([bool]$running -ne [bool]$script:state.wasRunning) { throw 'Original service state was not restored.' }
}
function Restore-GW2InterruptedRun {
    $script:state = Get-Content -LiteralPath $script:statePath -Raw | ConvertFrom-Json
    if ($script:state.schema -ne 'zapret2-next.gw2-recovery-v1' -or $script:state.wasRunning -isnot [bool] -or $script:state.restoreNeeded -isnot [bool]) { throw 'Unknown or invalid recovery file.' }
    $null = Get-GW2Service
    if ($script:state.engine) {
        $record = $script:state.engine
        $config = [IO.Path]::GetFullPath([string]$record.config)
        $boundary = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'results')).TrimEnd('\')+'\'
        if (-not $config.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase)) { throw 'Recovery config is outside the test results.' }
        $pending=[int]$record.id -eq 0
        if ($pending) {
            $notBefore=[DateTime]::Parse([string]$record.notBeforeUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
            $candidates=@(Get-CimInstance Win32_Process -Filter "Name='winws2.exe'" | Where-Object {
                $_.ExecutablePath -ieq (Join-Path $script:root 'bin\winws2.exe') -and $_.CommandLine -match ('@"'+[regex]::Escape($config)+'"(?:\s|$)')
            })
            if ($candidates.Count -gt 1) { throw 'Multiple processes match the pending test launch.' }
            $process=if ($candidates.Count) { Get-Process -Id $candidates[0].ProcessId -ErrorAction SilentlyContinue } else { $null }
        } else { $process = Get-Process -Id ([int]$record.id) -ErrorAction SilentlyContinue }
        if ($process) {
            $null = $process.Handle
            $image = Get-CimInstance Win32_Process -Filter ('ProcessId='+$process.Id)
            $timeMatches=if ($pending) { $process.StartTime.ToUniversalTime() -ge $notBefore.AddSeconds(-2) } else { $process.StartTime.ToUniversalTime().Ticks.ToString() -eq [string]$record.startTicks }
            if (-not $timeMatches -or
                $image.ExecutablePath -ine (Join-Path $script:root 'bin\winws2.exe') -or
                $image.CommandLine -notmatch ('@"'+[regex]::Escape($config)+'"(?:\s|$)')) { throw 'Recovery process identity does not match. No process was stopped.' }
            $script:engine = $process
        }
    }
    Invoke-GW2WithRestore {} { Stop-GW2TestEngine } { Restore-GW2OriginalService }
    Remove-Item -LiteralPath $script:statePath
    Write-Host 'Исходное состояние службы восстановлено.' -ForegroundColor Green
}
function Assert-GW2Components {
    foreach ($relative in @('bin\winws2.exe','presets\ALT11.txt.in','presets\_base.txt.in','lists\ipset-all.txt','SHA256SUMS.txt')) {
        if (-not [IO.File]::Exists((Join-Path $script:root $relative))) { throw 'Extract GW2-TEST inside your existing zapret2-next folder.' }
    }
    $checked = 0
    foreach ($line in [IO.File]::ReadLines((Join-Path $script:root 'SHA256SUMS.txt'))) {
        if ($line -match '^([0-9a-fA-F]{64})\s+\*?((?:bin|lua)[/\\].+)$') {
            $expected=$matches[1]; $relative=$matches[2]
            if (($relative -split '[/\\]') -contains '..' -or [IO.Path]::IsPathRooted($relative)) { throw 'Unsafe component catalog path.' }
            $path = Join-Path $script:root $relative
            if (-not [IO.File]::Exists($path) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $expected) { throw 'Component SHA256 check failed. Use an intact release folder.' }
            $checked++
        }
    }
    if ($checked -lt 10) { throw 'Component catalog is incomplete.' }
}
function Wait-GW2Closed {
    while (@(Get-Process -Name 'Gw2-64','Gw2' -ErrorAction SilentlyContinue).Count) {
        if ((Read-Host 'Закройте GW2 полностью. Enter — проверить снова, Q — завершить') -match '^[qQ]$') { throw [OperationCanceledException]::new() }
    }
}
function Read-GW2Outcome {
    $answer = Read-Host 'Результат входа: 1 — выбор персонажа/игра; 2 — прежняя ошибка; 3 — другая ошибка; 0 — не проверено'
    $outcome = switch ($answer) { '1' {'login-ok'} '2' {'same-error'} '3' {'different-error'} default {'not-tested'} }
    $code = ''
    if ($answer -in @('2','3')) {
        $inputCode = Read-Host 'Числовой код ошибки (например 58:11:5:512), либо Enter'
        if ($inputCode -match '^\d{1,10}(?::\d{1,10}){0,9}$') { $code=$inputCode }
    }
    return [pscustomobject]@{ outcome=$outcome; errorCode=$code }
}
function Measure-GW2Attempt([string]$Name, [string]$Label, [string[]]$Targets=@(), [int[]]$Ports=@(), [ValidateRange(1,120)][int]$Seconds=$CaptureSeconds) {
    $script:stage = $Name
    Write-Host "`n$Label" -ForegroundColor Cyan
    if ((Read-Host 'Enter — начать; Q — завершить') -match '^[qQ]$') { throw [OperationCanceledException]::new() }
    $rows = @{}; $samples=0; $privateSamples=0; $gameSeen=$false; $readErrors=0; $engineExited=$false
    Write-Host "Запустите GW2 и попробуйте войти. Соединения собираются $Seconds секунд."
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt $Seconds) {
        if ($script:engine -and $script:engine.HasExited) { $engineExited=$true }
        $processes = @(Get-Process -Name 'Gw2-64','Gw2' -ErrorAction SilentlyContinue)
        if ($processes.Count) {
            $gameSeen=$true
            try {
                $pids = @($processes | ForEach-Object { $_.Id })
                $connections = @(Get-NetTCPConnection -ErrorAction Stop | Where-Object { $_.OwningProcess -in $pids -and $_.RemotePort -gt 0 })
                foreach ($connection in $connections) {
                    $address = (ConvertTo-GW2Address ([string]$connection.RemoteAddress)).ToString()
                    if (-not (Test-GW2PublicAddress $address)) { $privateSamples++; continue }
                    $key = $address+'/'+$connection.RemotePort
                    if (-not $rows.ContainsKey($key)) {
                        $rows[$key] = [pscustomobject]@{ remoteIP=$address; remotePort=[int]$connection.RemotePort; states=[Collections.Generic.HashSet[string]]::new(); samples=0 }
                    }
                    $null=$rows[$key].states.Add([string]$connection.State); $rows[$key].samples++
                }
            } catch { $readErrors++ }
        }
        $samples++
        Write-Progress -Activity $Label -Status ('Осталось примерно '+[Math]::Max(0,[int]($Seconds-$watch.Elapsed.TotalSeconds))+' с') -PercentComplete ([Math]::Min(100,[int](100*$watch.Elapsed.TotalSeconds/$Seconds)))
        Start-Sleep -Milliseconds 250
    }
    $watch.Stop()
    if ($script:engine -and $script:engine.HasExited) { $engineExited=$true }
    Write-Progress -Activity $Label -Completed
    if ($engineExited) { Write-Host 'Тестовый движок завершился. Результат этой фазы нельзя считать проверкой профиля.' -ForegroundColor Red }
    $answer = Read-GW2Outcome
    $endpoints = @($rows.Values | Sort-Object remoteIP,remotePort | ForEach-Object {
        [pscustomobject]@{ remoteIP=$_.remoteIP; remotePort=$_.remotePort; states=@($_.states | Sort-Object); samples=$_.samples
            inLoadedIPSet=(Test-GW2IPSet $script:loaded $_.remoteIP); excluded=(Test-GW2IPSet $script:excluded $_.remoteIP)
            inObservedTargetSet=($_.remoteIP -in $Targets); testPortCaptured=($_.remotePort -in $Ports) }
    })
    return [pscustomobject]@{ name=$Name; outcome=$answer.outcome; errorCode=$answer.errorCode; gameProcessObserved=$gameSeen
        captureSeconds=[int]$watch.Elapsed.TotalSeconds; samples=$samples; connectionReadErrors=$readErrors
        nonPublicConnectionSamples=$privateSamples; testPorts=@($Ports); endpoints=$endpoints; engineExitedDuringCapture=$engineExited }
}
function Start-GW2OwnedProcess([string]$Config, [string]$Stdout, [string]$Stderr) {
    Assert-GW2NoManualEngine
    $service=Get-GW2Service
    if ($service -and $service.State -ne 'Stopped') { throw 'The original service restarted during the test. No test engine was launched.' }
    $script:state.engine=@{ id=0; config=$Config; notBeforeUtc=[DateTime]::UtcNow.ToString('o') }
    Save-GW2State
    $winws=Join-Path $script:root 'bin\winws2.exe'
    $script:engine=Start-Process $winws -ArgumentList ('@"'+$Config+'"') -WorkingDirectory (Split-Path $winws) -WindowStyle Hidden -RedirectStandardOutput $Stdout -RedirectStandardError $Stderr -PassThru
    $null=$script:engine.Handle
    $script:state.engine=@{ id=$script:engine.Id; startTicks=$script:engine.StartTime.ToUniversalTime().Ticks.ToString(); config=$Config }
    Save-GW2State
}
function Start-GW2TestEngine([string]$Name, [string]$IPSetPath, [int[]]$Ports) {
    $config = Join-Path $script:runPath ('local\'+$Name+'.txt')
    $content = New-GW2Config $script:root $IPSetPath $Ports
    [IO.File]::WriteAllText($config,$content,[Text.UTF8Encoding]::new($false))
    $dry = $config+'.dry.txt'
    [IO.File]::WriteAllText($dry,($content+"--intercept=0`r`n--wf-dup-check=0`r`n--dry-run`r`n"),[Text.UTF8Encoding]::new($false))
    $stdout=$config+'.validate.stdout'; $stderr=$config+'.validate.stderr'
    try {
        Start-GW2OwnedProcess $dry $stdout $stderr
        if (-not $script:engine.WaitForExit(30000)) { throw 'Configuration validation timed out.' }
        $script:engine.WaitForExit()
        $exitCode=$script:engine.ExitCode
        if (($null -ne $exitCode -and $exitCode -ne 0) -or -not (Select-String -LiteralPath $stdout -Pattern '^command line parameters verified$' -Quiet)) { throw 'The installed engine rejected the diagnostic profile.' }
    } finally { Stop-GW2TestEngine }
    Start-GW2OwnedProcess $config ($config+'.stdout') ($config+'.stderr')
    Start-Sleep -Seconds 2
    if ($script:engine.HasExited) { throw 'Test engine exited during startup.' }
}
function Invoke-GW2TestPlan($Report) {
    Invoke-GW2WithRestore {
        Wait-GW2Closed
        $Report.attempts+=Measure-GW2Attempt 'current' '1/4 — исходное состояние Zapret'
        Wait-GW2Closed
        Stop-GW2OriginalService
        $Report.attempts+=Measure-GW2Attempt 'without-zapret' '2/4 — без Zapret'
        Wait-GW2Closed
        $ports=@(80,443,6112)+@($Report.attempts | ForEach-Object { $_.endpoints | ForEach-Object { $_.remotePort } })
        $ports=@($ports | Sort-Object -Unique)
        if ($ports.Count -gt 32) { throw 'Too many distinct game ports for a narrow diagnostic profile.' }
        $targets=@($Report.attempts | ForEach-Object { $_.endpoints | ForEach-Object { $_.remoteIP } } | Sort-Object -Unique)
        if (-not $targets.Count) { $Report.status='no-endpoints'; return }
        $script:stage='loaded-profile-start'
        Start-GW2TestEngine 'tcp-loaded' (Join-Path $script:root 'lists\ipset-all.txt') $ports
        $Report.attempts+=Measure-GW2Attempt 'tcp-loaded' '3/4 — TCP-часть ALT11, обычный IPSet' -Ports $ports
        Wait-GW2Closed
        Stop-GW2TestEngine
        $targets=@($Report.attempts | ForEach-Object { $_.endpoints | ForEach-Object { $_.remoteIP } } | Sort-Object -Unique)
        if ($targets.Count -gt 512) { throw 'Too many server addresses for a narrow diagnostic profile.' }
        $targetPath=Join-Path $script:runPath 'local\observed-targets.txt'
        [IO.File]::WriteAllLines($targetPath,$targets,[Text.Encoding]::ASCII)
        $script:stage='observed-profile-start'
        Start-GW2TestEngine 'tcp-observed' $targetPath $ports
        $Report.attempts+=Measure-GW2Attempt 'tcp-observed' '4/4 — та же TCP-часть ALT11, замеченные адреса серверов' -Targets $targets -Ports $ports
        $Report.status=if (@($Report.attempts | Where-Object engineExitedDuringCapture).Count) { 'failed' } else { 'completed' }
    } { Stop-GW2TestEngine } { Restore-GW2OriginalService; $Report.serviceRestored=$true }
}
function Save-GW2Report($Report) {
    $public = Join-Path $script:runPath 'report'
    [IO.Directory]::CreateDirectory($public) | Out-Null
    Write-GW2Json (Join-Path $public 'results.json') $Report
    $text = @('GW2 / Zapret 2 NEXT — Issue #5',('Статус: '+$Report.status),('Клиент: '+$Report.client),
        ('Сборка: '+$Report.bundleVersion),('Настройки сохранены: '+$Report.settingsPreserved),('Служба восстановлена: '+$Report.serviceRestored),
        'Проверяется реальный вход в игру. TCP-соединение само по себе не доказывает успешный вход.',
        'Фазы выполняются последовательно; краткий сбой сети и смена серверов могут влиять на сравнение.',
        'Непубличные адреса скрыты. Пароли, пакеты, локальные пути, локальные IP и PID в ZIP не входят.', '')
    $csv = @()
    foreach ($attempt in $Report.attempts) {
        $text += $attempt.name+': '+$attempt.outcome+'; code='+$attempt.errorCode+'; endpoints='+$attempt.endpoints.Count+'; readErrors='+$attempt.connectionReadErrors+'; engineExited='+[bool]$attempt.engineExitedDuringCapture
        foreach ($endpoint in $attempt.endpoints) {
            $csv += [pscustomobject]@{ stage=$attempt.name; remoteIP=$endpoint.remoteIP; remotePort=$endpoint.remotePort
                states=($endpoint.states -join ','); inLoadedIPSet=$endpoint.inLoadedIPSet; excluded=$endpoint.excluded
                inObservedTargetSet=$endpoint.inObservedTargetSet; testPortCaptured=$endpoint.testPortCaptured }
        }
    }
    $text += ''; $text += 'Тестовые профили содержат только TCP-часть ALT11. Они не устанавливаются как постоянная стратегия.'
    $text += 'observed-targets использует только замеченные публичные IP; новые серверы могут оказаться вне этого набора.'
    $text += 'Отсутствие записей не доказывает отсутствие сети: короткое соединение, DNS-сбой, прокси или другой процесс требуют отдельного разбора.'
    if ($Report.failureStage) { $text += 'Проверка прервана на этапе: '+$Report.failureStage+'. Подробности остаются в local.' }
    [IO.File]::WriteAllLines((Join-Path $public 'REPORT.txt'),$text,[Text.UTF8Encoding]::new($false))
    if ($csv.Count) { $csv | Export-Csv -LiteralPath (Join-Path $public 'connections.csv') -NoTypeInformation -Encoding UTF8 }
    else { [IO.File]::WriteAllText((Join-Path $public 'connections.csv'),'stage,remoteIP,remotePort,states,inLoadedIPSet,excluded,inObservedTargetSet,testPortCaptured') }
    $zip=$script:runPath+'.zip'
    Compress-Archive -LiteralPath @((Join-Path $public 'REPORT.txt'),(Join-Path $public 'results.json'),(Join-Path $public 'connections.csv')) -DestinationPath $zip
    Write-Host "`nПриложите к Issue только этот ZIP: $zip" -ForegroundColor Green
}

if ($FunctionsOnly) { return }
$lock=$null; $bundleGate=$null; $report=$null; $before=$null; $exitCode=0
try {
    if (-not [IO.File]::Exists((Join-Path $script:root 'bin\winws2.exe'))) { throw 'Распакуйте папку GW2-TEST внутрь установленной сборки Zapret 2 NEXT.' }
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    try { $admin=([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } finally { $identity.Dispose() }
    if (-not $admin) {
        $arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -CaptureSeconds '+$CaptureSeconds+' -ElevatedChild'
        if ($Restore) { $arguments+=' -Restore' }
        $child=Start-Process powershell.exe -ArgumentList $arguments -Verb RunAs -Wait -PassThru
        try { exit $child.ExitCode } finally { $child.Dispose() }
    }
    . (Join-Path $script:root 'utils\bundle-operation.ps1')
    $bundleGate=Enter-ZapretBundleOperation -Root $script:root
    $lock=[IO.File]::Open((Join-Path $PSScriptRoot 'test.lock'),'OpenOrCreate','ReadWrite','None')
    if ([IO.File]::Exists($script:statePath)) {
        if (-not $Restore) { throw 'Предыдущий тест прерван. Сначала запустите RESTORE.bat.' }
        Restore-GW2InterruptedRun
    } elseif ($Restore) { Write-Host 'Сохранённого незавершённого теста нет. Ничего не изменено.' }
    else {
        Assert-GW2Components
        Assert-GW2NoManualEngine
        $service=Get-GW2Service
        $script:loaded=Read-GW2IPSet @((Join-Path $script:root 'lists\ipset-all.txt'))
        if (-not $script:loaded.Count) { throw 'Loaded IPSet is empty; update it through the normal menu first.' }
        $script:excluded=Read-GW2IPSet @((Join-Path $script:root 'lists\ipset-exclude.txt'),(Join-Path $script:root 'lists\ipset-exclude-user.txt'))
        Write-Host 'Персональная проверка GW2 / Issue #5' -ForegroundColor Cyan
        Write-Host 'На время теста отключите VPN и другие средства обхода вручную. Не меняйте меню Zapret до завершения.'
        Write-Host 'Мастер временно остановит службу этой папки и затем восстановит её исходное состояние.'
        Write-Host 'Потребуется четыре раза полностью закрыть/запустить GW2 и отметить результат входа. Настройки не сохраняются.'
        Write-Host 'В ZIP попадут публичные адреса серверов GW2, порты, состояния соединений и числовой код ошибки.'
        if ((Read-Host 'S — начать, любой другой ввод — выйти') -ine 's') { exit 0 }
        $clientInput=Read-Host 'Клиент: 1 — ArenaNet; 2 — Steam; 0 — неизвестно'
        $client=switch ($clientInput) { '1' {'ArenaNet'} '2' {'Steam'} default {'unknown'} }
        $runName=[DateTime]::Now.ToString('yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8)
        $script:runPath=Join-Path $PSScriptRoot ('results\'+$runName)
        [IO.Directory]::CreateDirectory((Join-Path $script:runPath 'local')) | Out-Null
        $before=Get-GW2SettingsHashes $script:root
        $version=[IO.File]::ReadAllText((Join-Path $script:root '.service\version.txt')).Trim()
        if ($version -notmatch '^\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?$') { $version='unknown' }
        $originalPorts='unknown'
        $originalConfig=Join-Path $script:root 'runtime\service.txt'
        if ([IO.File]::Exists($originalConfig)) {
            $portMatch=[regex]::Match([IO.File]::ReadAllText($originalConfig),'(?m)^--wf-tcp-out=(\d+(?:-\d+)?(?:,\d+(?:-\d+)?)*)\s*$')
            if ($portMatch.Success -and $portMatch.Groups[1].Value.Length -le 4096) { $originalPorts=$portMatch.Groups[1].Value }
        }
        $report=[ordered]@{ schema='zapret2-next.issue-5-gw2'; schemaVersion=1; kitRevision='r2'; startedAtUtc=[DateTime]::UtcNow.ToString('o'); finishedAtUtc=''
            status='running'; bundleVersion=$version; client=$client; originalServicePresent=($null -ne $service)
            originalServiceRunning=($service -and $service.State -eq 'Running'); settingsPreserved=$false; serviceRestored=$false
            originalSettings=@{ game=(Get-GW2Setting $script:root 'game_filter.mode' @('off','tcp','udp','all')); ipset=(Get-GW2Setting $script:root 'ipset_filter.mode' @('loaded','none','any')); capturedTcpPorts=$originalPorts }
            loadedIPSetEntries=$script:loaded.Count; attempts=@(); failureStage='' }
        $script:state=[ordered]@{ schema='zapret2-next.gw2-recovery-v1'; wasRunning=[bool]$report.originalServiceRunning; restoreNeeded=$false; engine=$null }
        Save-GW2State
        Invoke-GW2TestPlan $report
    }
} catch {
    $exitCode=1
    Write-Host ('[ОШИБКА] '+$_.Exception.Message) -ForegroundColor Red
    if ($report) {
        $report.status=if ($_.Exception -is [OperationCanceledException]) { 'canceled' } else { 'failed' }
        $report.failureStage=$script:stage
        try { [IO.File]::WriteAllText((Join-Path $script:runPath 'local\error.txt'),($_ | Out-String)) } catch {}
    }
} finally {
    if ($report) {
        try { $report.settingsPreserved=Test-GW2HashesEqual $before (Get-GW2SettingsHashes $script:root) } catch { $report.settingsPreserved=$false }
        if (-not $report.settingsPreserved -or -not $report.serviceRestored) { $report.status='failed'; $exitCode=1 }
        if ($report.status -eq 'failed') { $exitCode=1 }
        $report.finishedAtUtc=[DateTime]::UtcNow.ToString('o')
        if ($report.serviceRestored -and -not $script:engine -and $script:state -and -not $script:state.engine) {
            Remove-Item -LiteralPath $script:statePath -ErrorAction SilentlyContinue
        } else { Write-Host 'Для восстановления запустите RESTORE.bat. Если не удалось — service.bat → Check Status / Install Service.' -ForegroundColor Yellow }
        try { Save-GW2Report $report } catch { $exitCode=1; Write-Host 'ZIP не создан. Текст и JSON находятся в папке results этого теста.' -ForegroundColor Red }
    }
    if ($lock) { $lock.Dispose() }
    if ($bundleGate) { Exit-ZapretBundleOperation $bundleGate }
}
if ($ElevatedChild -and -not [Console]::IsInputRedirected) { $null=Read-Host 'Enter — закрыть окно' }
exit $exitCode
