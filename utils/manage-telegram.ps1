param(
    [Parameter(Mandatory)]
    [ValidateSet('Enable', 'Disable', 'Restart', 'Connect', 'Status', 'Diagnose', 'Menu')]
    [string]$Action,
    [switch]$Compact
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'telegram-control.ps1')
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))

function Invoke-TelegramManagerAction([string]$Selection) {
    switch ($Selection) {
        'Enable' { Enable-ZapretTelegram $root; Connect-ZapretTelegram $root }
        'Disable' { Disable-ZapretTelegram $root }
        'Restart' { Restart-ZapretTelegram $root }
        'Connect' { Connect-ZapretTelegram $root }
        'Status' {
            if ($Compact) { Get-ZapretTelegramStatus $root -Compact }
            else { Get-ZapretTelegramStatus $root | Format-List | Out-Host }
        }
        'Diagnose' { Invoke-ZapretTelegramDiagnostics $root }
    }
}

try {
    if ($Action -eq 'Menu') {
        do {
            Clear-Host
            Write-Host 'Telegram Desktop proxy' -ForegroundColor Cyan
            Write-Host ('Status: ' + (Get-ZapretTelegramStatus $root -Compact))
            Write-Host ''
            Write-Host '  1. Enable and connect Telegram'
            Write-Host '  2. Connect Telegram'
            Write-Host '  3. Restart proxy'
            Write-Host '  4. Disable proxy'
            Write-Host '  5. Show status'
            Write-Host '  6. Diagnose Telegram endpoints'
            Write-Host '  0. Back'
            Write-Host ''
            $selection = Read-Host 'Select option (0-6)'
            if ($selection -eq '0') { break }
            $menuAction = switch ($selection) { '1' {'Enable'} '2' {'Connect'} '3' {'Restart'} '4' {'Disable'} '5' {'Status'} '6' {'Diagnose'} }
            if (-not $menuAction) { continue }
            try { Invoke-TelegramManagerAction $menuAction }
            catch { Write-Host ("[ERROR] " + $_.Exception.Message) -ForegroundColor Red }
            Write-Host ''
            Read-Host 'Press Enter to continue' | Out-Null
        } while ($true)
    } else { Invoke-TelegramManagerAction $Action }
} catch {
    if ($Compact -and $Action -eq 'Status') { Write-Output 'ERROR' }
    else { Write-Host ("[ERROR] " + $_.Exception.Message) -ForegroundColor Red }
    exit 1
}
exit 0
