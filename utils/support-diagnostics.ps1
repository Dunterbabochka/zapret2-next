[CmdletBinding()]
param(
    [string]$Provider,
    [string]$RegionCity = '',
    [ValidateRange(3, 30)][int]$TimeoutSeconds = 8
)

. (Join-Path $PSScriptRoot 'compatibility-wizard-core.ps1') -TimeoutSeconds $TimeoutSeconds
. (Join-Path $PSScriptRoot 'compatibility-wizard-preflight.ps1')
. (Join-Path $PSScriptRoot 'compatibility-wizard-network.ps1')
. (Join-Path $PSScriptRoot 'compatibility-wizard-main.ps1')
. (Join-Path $PSScriptRoot 'service-control.ps1')
. (Join-Path $PSScriptRoot 'support-diagnostics-core.ps1')

$bundleGate = $null
try {
    Write-Host 'Automatic support report / Автоматический отчёт' -ForegroundColor Cyan
    if ([string]::IsNullOrWhiteSpace($Provider)) {
        $Provider = Read-RequiredValue 'Провайдер / Internet provider'
        $RegionCity = (Read-Host 'Область или город (желательно; Enter = пропустить, q = отмена)').Trim()
        if ($RegionCity -match '^(?i:q|quit|cancel)$') { throw [OperationCanceledException]::new() }
    }
    $bundleGate = Enter-ZapretBundleOperation $root
    $artifact = Invoke-SupportDiagnostics -Provider $Provider -RegionCity $RegionCity
    if ($artifact.Status -eq 'blocked') {
        Write-Host 'Стратегии пока не проверялись. Устраните указанные причины и повторите проверку; результат также записан в отчёт.' -ForegroundColor Yellow
    }
    if ($artifact.Issues -contains 'DNSResolutionFailed') {
        Write-Host 'Часть адресов не удалось определить через DNS. Это не подтверждает, что сайт не работает в браузере; подробности есть в отчёте.' -ForegroundColor Yellow
    }
    Write-Host "ZIP для обращения: $($artifact.ZipPath)" -ForegroundColor Cyan
    Write-Host 'Приложите этот ZIP к GitHub Issue. Он не отправляется автоматически.'
    Write-Host 'https://github.com/Dunterbabochka/zapret2-next/issues/new?template=strategy-report.yml'
    exit $artifact.ExitCode
} catch [OperationCanceledException] {
    Write-Host 'Проверка отменена.' -ForegroundColor Yellow
    exit 2
} catch {
    Write-Host 'Не удалось сохранить отчёт. Проверьте доступ к папке runtime/support-reports и свободное место.' -ForegroundColor Red
    exit 1
} finally { Exit-ZapretBundleOperation $bundleGate }
