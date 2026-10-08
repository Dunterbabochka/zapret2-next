# Offline failure-injection checks. Never touches real services or loaded lists.
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'ipset-utils.ps1')
. (Join-Path $PSScriptRoot 'service-control.ps1')
$fixture = Join-Path $root ('runtime\stability-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
$checks = 0

function Assert-Stability([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function Assert-Rejected([scriptblock]$Operation, [string]$Message) {
    $rejected = $false
    try { & $Operation | Out-Null } catch { $rejected = $true }
    Assert-Stability $rejected $Message
}
function Write-IPFixture([string]$Path, [int]$Count) {
    $lines = @(1..$Count | ForEach-Object { "192.0.2.$_`/32" })
    [IO.File]::WriteAllLines($Path, $lines, [Text.Encoding]::ASCII)
}
function Invoke-UpdateFixture([string[]]$ExtraArguments) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'update-ipset.ps1') @ExtraArguments | Out-Host
    return $LASTEXITCODE
}

# Replace every SCM operation before running service transaction scenarios.
function Get-ZapretServiceSnapshot { return $script:snapshot }
function Assert-ZapretNoManualEngine {
    if ($script:conflict) { throw 'Injected manual process conflict' }
}
function Stop-ZapretService { $script:events.Add('stop') }
function Start-ZapretService {
    $script:events.Add('start')
    if ($script:failStart) { $script:failStart = $false; throw 'Injected startup failure' }
}
function Set-ZapretServiceRegistration {
    param([string]$ImagePath, [string]$Strategy, [bool]$Create)
    $script:events.Add('register')
    if ($script:failRegister) { throw 'Injected partial registration failure' }
}
function Restore-ZapretServiceRegistration { param($Snapshot); $script:events.Add('restore-registration') }
function Remove-ZapretServiceRegistration { $script:events.Add('delete-new-service') }
function New-ZapretServiceCandidate {
    param([string]$Root, [string]$Preset, [string]$IPSetMode, [string]$Candidate)
    $script:events.Add('validate')
    if ($script:failValidation) { throw 'Injected invalid config' }
    [IO.File]::WriteAllText($Candidate, 'new config', [Text.UTF8Encoding]::new($false))
}
function Reset-ServiceFixture([bool]$Existing = $true) {
    $script:events = [Collections.Generic.List[string]]::new()
    $script:failValidation = $false
    $script:failStart = $false
    $script:failRegister = $false
    $script:conflict = $false
    $script:snapshot = if ($Existing) {
        [pscustomobject]@{ PathName = 'original image'; StartMode = 'Manual'; WasRunning = $true; Strategy = 'ALT' }
    } else { $null }
    $script:serviceRoot = Join-Path $fixture ([Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $serviceRoot 'runtime') -Force | Out-Null
    $script:serviceConfig = Join-Path $serviceRoot 'runtime\service.txt'
    if ($script:snapshot) { $script:snapshot.PathName = '"' + (Join-Path $serviceRoot 'bin\winws2.exe') + '" @"' + $serviceConfig + '"' }
    if ($Existing) { [IO.File]::WriteAllBytes($serviceConfig, [byte[]]@(239,187,191,111,108,100,13,10)) }
}

try {
    Write-Host 'Testing injected failures; ERROR/WARN messages below are expected.' -ForegroundColor Cyan
    $source = Join-Path $fixture 'source.txt'
    $destination = Join-Path $fixture 'loaded.txt'
    Write-IPFixture $source 10
    $valid = @('192.0.2.1/32', '2001:db8::1/128', '2001:db8::/64')
    [IO.File]::WriteAllLines($source, $valid, [Text.Encoding]::ASCII)
    Assert-Stability (@(Read-ValidatedIPSet $source 1).Count -eq 3) 'Valid IPv4/IPv6 rejected'
    foreach ($bad in @('999.1.1.1/32','192.0.2.1/33','2001:db8::/129','192.0.2.1/-1','192.0.2.1/0','::/0','127.1','12345','192.0.2.1/24/7','fe80::1%3','192.0.2.1/+24','<html>failure</html>')) {
        [IO.File]::WriteAllText($source, $bad)
        Assert-Rejected { Read-ValidatedIPSet $source 1 } "Invalid entry accepted: $bad"
    }
    [IO.File]::WriteAllLines($source, @('2001:db8::1/64','2001:0db8:0:0:0:0:0:1/64'))
    Assert-Rejected { Read-ValidatedIPSet $source 1 } 'Equivalent duplicate IPv6 accepted'
    Write-IPFixture $destination 100
    $before = (Get-FileHash $destination).Hash
    Write-IPFixture $source 40
    $code = Invoke-UpdateFixture @('-SourcePath', $source, '-Destination', $destination)
    Assert-Stability ($code -ne 0 -and (Get-FileHash $destination).Hash -eq $before) 'Shrunken update damaged the original list'
    Write-IPFixture $source 100
    Add-Content -LiteralPath $source '192.0.2.1/999'
    $code = Invoke-UpdateFixture @('-SourcePath', $source, '-Destination', $destination)
    Assert-Stability ($code -ne 0 -and (Get-FileHash $destination).Hash -eq $before) 'Malformed update damaged the original list'
    Write-IPFixture $source 101
    $held = [IO.File]::Open($destination + '.lock', 'OpenOrCreate', 'ReadWrite', 'None')
    try { $code = Invoke-UpdateFixture @('-SourcePath', $source, '-Destination', $destination) } finally { $held.Dispose() }
    Assert-Stability ($code -ne 0 -and (Get-FileHash $destination).Hash -eq $before) 'Concurrent updater bypassed the lock'
    $code = Invoke-UpdateFixture @('-SourcePath', $source, '-Destination', $destination)
    Assert-Stability ($code -eq 0 -and @(Read-ValidatedIPSet $destination).Count -eq 101) 'Valid update failed'
    Assert-Stability ((Get-FileHash ($destination + '.backup')).Hash -eq $before) 'Backup does not preserve the old list'
    $held = [IO.File]::Open($destination, 'Open', 'Read', 'Read')
    $before = (Get-FileHash $destination).Hash
    try { Assert-Rejected { Write-AtomicTextFile $destination 'replacement' } 'Locked destination was replaced' } finally { $held.Dispose() }
    Assert-Stability ((Get-FileHash $destination).Hash -eq $before) 'Failed atomic replacement damaged the destination'

    # Simulate a download that writes partial bytes and then times out.
    $wrapper = Join-Path $fixture 'partial-download.ps1'
    $escapedUpdater = (Join-Path $PSScriptRoot 'update-ipset.ps1').Replace("'", "''")
    $wrapperText = @'
param([string]$Destination)
function Invoke-WebRequest {
    param($Uri, $OutFile, $TimeoutSec, [switch]$UseBasicParsing)
    [IO.File]::WriteAllText($OutFile, '192.0.2.1/32')
    throw 'Injected timeout after partial download'
}
& '__UPDATER__' -RemoteUrl 'https://invalid.example/ipset' -Destination $Destination
exit $LASTEXITCODE
'@
    [IO.File]::WriteAllText($wrapper, $wrapperText.Replace('__UPDATER__', $escapedUpdater))
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Destination $destination | Out-Host
    Assert-Stability ($LASTEXITCODE -eq 0 -and @(Read-ValidatedIPSet $destination).Count -gt 1000) 'Partial download prevented bundled fallback'

    # Exercise the actual launcher with a harmless console executable. This
    # verifies timeout and exit handling without WinDivert or elevation.
    $engineRoot = Join-Path $fixture 'engine'
    New-Item -ItemType Directory -Path (Join-Path $engineRoot 'bin'), (Join-Path $engineRoot 'utils') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'invoke-winws.ps1') -Destination (Join-Path $engineRoot 'utils\invoke-winws.ps1')
    $engineSource = Join-Path $engineRoot 'FixtureEngine.cs'
    $engineCode = @'
using System;
using System.IO;
using System.Threading;
public class FixtureEngine {
    public static int Main(string[] args) {
        string mode = File.ReadAllText(args[0].Substring(1).Trim('"')).Trim();
        if (mode == "timeout") { Thread.Sleep(10000); }
        if (mode == "reject") { Console.Error.WriteLine("Injected engine rejection"); return 7; }
        Console.WriteLine("command line parameters verified");
        return 0;
    }
}
'@
    [IO.File]::WriteAllText($engineSource, $engineCode)
    $compiler = Join-Path $engineRoot 'compile.ps1'
    [IO.File]::WriteAllText($compiler, 'param($SourcePath, $OutputPath); $ErrorActionPreference = "Stop"; Add-Type -Path $SourcePath -OutputAssembly $OutputPath -OutputType ConsoleApplication')
    $fakeEngine = Join-Path $engineRoot 'bin\winws2.exe'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $compiler -SourcePath $engineSource -OutputPath $fakeEngine
    if ($LASTEXITCODE -ne 0) { throw 'Cannot compile isolated launcher fixture' }
    $fakeConfig = Join-Path $engineRoot 'config.txt'
    foreach ($case in @(@{Mode='success'; Exit=0}, @{Mode='reject'; Exit=13}, @{Mode='timeout'; Exit=16})) {
        [IO.File]::WriteAllText($fakeConfig, $case.Mode)
        $timer = [Diagnostics.Stopwatch]::StartNew()
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $engineRoot 'utils\invoke-winws.ps1') -Config $fakeConfig -LogPrefix (Join-Path $engineRoot $case.Mode) -Validate -ValidationTimeoutSeconds 1 | Out-Host
        $code = $LASTEXITCODE
        $timer.Stop()
        Assert-Stability ($code -eq $case.Exit) "Incorrect launcher exit for $($case.Mode): $code"
        if ($case.Mode -eq 'timeout') { Assert-Stability ($timer.Elapsed.TotalSeconds -lt 8) 'Engine validation did not enforce its timeout' }
    }

    Reset-ServiceFixture
    $before = (Get-FileHash $serviceConfig).Hash
    $script:failValidation = $true
    Assert-Rejected { Set-ZapretServiceConfiguration $serviceRoot general -Install } 'Invalid candidate accepted'
    Assert-Stability (($events -join ',') -eq 'validate' -and (Get-FileHash $serviceConfig).Hash -eq $before) 'Validation failure stopped or changed the service'
    Reset-ServiceFixture
    $before = (Get-FileHash $serviceConfig).Hash
    $script:conflict = $true
    Assert-Rejected { Set-ZapretServiceConfiguration $serviceRoot general -Install } 'Manual process conflict ignored'
    Assert-Stability ($events.Count -eq 0 -and (Get-FileHash $serviceConfig).Hash -eq $before) 'Conflict changed service state'
    Reset-ServiceFixture
    $before = (Get-FileHash $serviceConfig).Hash
    $script:failStart = $true
    Assert-Rejected { Set-ZapretServiceConfiguration $serviceRoot general -Install } 'Startup failure ignored'
    Assert-Stability ((Get-FileHash $serviceConfig).Hash -eq $before) 'Rollback did not restore exact original bytes'
    Assert-Stability (($events -join ',') -eq 'validate,stop,register,start,stop,restore-registration,start') 'Previous running service was not restored'
    Reset-ServiceFixture
    [IO.File]::WriteAllText($serviceConfig, '')
    $script:failStart = $true
    Assert-Rejected { Set-ZapretServiceConfiguration $serviceRoot general -Restart } 'Empty original rollback failure ignored'
    Assert-Stability ((Test-Path $serviceConfig) -and (Get-Item $serviceConfig).Length -eq 0) 'Empty original config was deleted during rollback'
    Reset-ServiceFixture
    $before = (Get-FileHash $serviceConfig).Hash
    $snapshot.WasRunning = $false
    $script:failStart = $true
    Assert-Rejected { Set-ZapretServiceConfiguration $serviceRoot general -Restart } 'Refresh startup failure ignored'
    Assert-Stability (($events -join ',') -eq 'validate,stop,start,stop' -and (Get-FileHash $serviceConfig).Hash -eq $before) 'Previously stopped service was restarted during rollback'
    Reset-ServiceFixture $false
    $script:failRegister = $true
    Assert-Rejected { Set-ZapretServiceConfiguration $serviceRoot general -Install } 'Partial new installation failure ignored'
    Assert-Stability (($events -join ',') -eq 'validate,register,delete-new-service' -and -not (Test-Path $serviceConfig)) 'Failed new installation was not removed'
    Reset-ServiceFixture
    $snapshot.PathName = '"C:\another-bundle\bin\winws2.exe" @"C:\another-bundle\runtime\service.txt"'
    Assert-Rejected { Set-ZapretServiceConfiguration $serviceRoot general -Restart } 'Refresh replaced another bundle configuration'
    Assert-Stability ($events.Count -eq 0) 'Refresh touched another bundle service'
    Reset-ServiceFixture
    Set-ZapretServiceConfiguration $serviceRoot general
    Assert-Stability (($events -join ',') -eq 'validate' -and [IO.File]::ReadAllText($serviceConfig) -eq 'new config') 'Deferred refresh stopped the service'
    Reset-ServiceFixture
    Set-ZapretServiceConfiguration $serviceRoot general -Install
    Assert-Stability (($events -join ',') -eq 'validate,stop,register,start') 'Successful reinstall skipped validation or state transitions'
    Reset-ServiceFixture
    $snapshot.PathName = 'foreign service image'
    Assert-Rejected { Remove-ZapretServiceConfiguration $serviceRoot } 'Removed a service from another bundle'
    Assert-Stability ($events.Count -eq 0 -and (Test-Path $serviceConfig)) 'Foreign service removal changed local state'
    Reset-ServiceFixture
    Remove-ZapretServiceConfiguration $serviceRoot
    Assert-Stability (($events -join ',') -eq 'delete-new-service' -and -not (Test-Path $serviceConfig)) 'Owned service removal left the config behind'
    Assert-Stability (@(Get-ChildItem $fixture -Recurse -File -Filter '*.tmp').Count -eq 0) 'Temporary files leaked after failure'
    Write-Host "Stability validation passed: $checks offline failure-injection checks." -ForegroundColor Green
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    if ($resolved.StartsWith((Join-Path $root 'runtime') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}

# Expected native failures were asserted above; return the successful suite result.
exit 0
