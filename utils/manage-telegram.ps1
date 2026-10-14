param(
    [Parameter(Mandatory)]
    [ValidateSet('Enable', 'Disable', 'Restart', 'Connect', 'Status', 'Diagnose', 'Menu')]
    [string]$Action,
    [switch]$Compact
)

. (Join-Path $PSScriptRoot 'session-log.ps1')
Initialize-ZapretLog -Root ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))) -Component telegram -Action $Action
try {
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'telegram-control.ps1')
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))

function Invoke-TelegramManagerAction([string]$Selection) {
    Write-ZapretLogEvent -Action $Selection -Stage begin -Result started
    switch ($Selection) {
        'Enable' { Enable-ZapretTelegram $root; Connect-ZapretTelegram $root }
        'Disable' { Disable-ZapretTelegram $root }
        'Restart' { Restart-ZapretTelegram $root }
        'Connect' { Connect-ZapretTelegram $root }
        'Status' {
            if ($Compact) { Get-ZapretTelegramStatus $root -Compact -Fast }
            else {
                Get-ZapretTelegramStatus $root -Fast | Format-List | Out-Host
                try {
                    $service=Get-CimInstance Win32_Service -Filter "Name='winws2'" -ErrorAction Stop
                    $state=if (-not $service) {'absent'} elseif ($service.State -eq 'Running') {'running'} else {'stopped'}
                    Write-ZapretLogEvent -Component service -Action Status -Stage snapshot -Result $state -Code StateObserved
                } catch { Write-ZapretLogException $_ -Warning }
            }
        }
        'Diagnose' { Invoke-ZapretTelegramDiagnostics $root }
    }
    Write-ZapretLogEvent -Action $Selection -Stage end
}

try {
    if ($Action -eq 'Menu') {
        do {
            Clear-Host
            Write-Host 'Telegram Desktop proxy' -ForegroundColor Cyan
            Write-Host ('Status: ' + (Get-ZapretTelegramStatus $root -Compact -Fast))
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
            catch { Write-ZapretLogException $_ -Warning; Write-Host ("[ERROR] " + $_.Exception.Message) -ForegroundColor Red }
            Write-Host ''
            Read-Host 'Press Enter to continue' | Out-Null
        } while ($true)
    } else { Invoke-TelegramManagerAction $Action }
} catch { Write-ZapretLogException $_ -Warning;
    if ($Compact -and $Action -eq 'Status') { Write-Output 'ERROR' }
    else { Write-Host ("[ERROR] " + $_.Exception.Message) -ForegroundColor Red }
    Complete-ZapretLogOperation -ExitCode 1; exit 1
}
Complete-ZapretLogOperation -ExitCode 0; exit 0

} catch { Write-ZapretLogException $_; throw }
finally { Complete-ZapretLogOperation }
