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

try {
    Write-Host 'Automatic support report / Автоматический отчёт' -ForegroundColor Cyan
    if ([string]::IsNullOrWhiteSpace($Provider)) {
        $Provider = Read-RequiredValue 'Провайдер / Internet provider'
        $RegionCity = (Read-Host 'Область или город (желательно; Enter = пропустить, q = отмена)').Trim()
        if ($RegionCity -match '^(?i:q|quit|cancel)$') { throw [OperationCanceledException]::new() }
    }
    $artifact = Invoke-SupportDiagnostics -Provider $Provider -RegionCity $RegionCity
    if ($artifact.Status -eq 'blocked') {
        Write-Host 'Проверку остановило препятствие в окружении. Его результат записан в отчёт.' -ForegroundColor Yellow
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
}
