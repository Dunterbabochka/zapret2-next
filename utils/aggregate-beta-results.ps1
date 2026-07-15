[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$InputDirectory,
    [string]$OutputDirectory,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($InputDirectory)) { $InputDirectory = Join-Path $root 'runtime\beta-results' }
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = Join-Path $root 'runtime\beta-summary' }
$expectedSchema = 'zapret2-next.compatibility-results'
$expectedVersion = 1

function Write-Utf8([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Read-ResultDocument([string]$Path) {
    try { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop } catch { throw "Invalid results.json: $($_.Exception.Message)" }
}

function Add-Document([object]$Document, [string]$Source, [Collections.Generic.List[object]]$Accepted, [Collections.Generic.List[object]]$Rejected) {
    if ($Document.schema -ne $expectedSchema -or [int]$Document.schemaVersion -ne $expectedVersion) {
        $Rejected.Add([pscustomobject]@{ Source = $Source; Reason = "Unsupported schema '$($Document.schema)' v$($Document.schemaVersion)." }); return
    }
    if (-not $Document.status -or -not $Document.tester) {
        $Rejected.Add([pscustomobject]@{ Source = $Source; Reason = 'Partial report: required status or tester metadata is missing.' }); return
    }
    $recommendation = $Document.recommendation
    $Accepted.Add([pscustomobject]@{
        Source = $Source; Status = [string]$Document.status; TesterId = [string]$Document.tester.TesterId; Provider = [string]$Document.tester.Provider
        RegionCity = [string]$Document.tester.RegionCity; ConnectionType = [string]$Document.tester.ConnectionType; WizardVersion = [string]$Document.wizardVersion
        WebPreset = if ($recommendation) { [string]$recommendation.WebPreset } else { '' }; VoiceMode = if ($recommendation) { [string]$recommendation.VoiceMode } else { '' }
        Confirmed = if ($recommendation) { [bool]$recommendation.Confirmed } else { $false }; StatePreserved = [bool]$Document.userStatePreserved
    })
}

function Invoke-Aggregation([string]$SourceDirectory, [string]$DestinationDirectory) {
    if (-not (Test-Path -LiteralPath $SourceDirectory -PathType Container)) { throw "Input directory does not exist: $SourceDirectory" }
    if (Test-Path -LiteralPath $DestinationDirectory) { Remove-Item -LiteralPath $DestinationDirectory -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $DestinationDirectory | Out-Null
    $accepted = [Collections.Generic.List[object]]::new(); $rejected = [Collections.Generic.List[object]]::new()
    foreach ($json in @(Get-ChildItem -LiteralPath $SourceDirectory -Recurse -Filter results.json -File)) {
        try { Add-Document (Read-ResultDocument $json.FullName) $json.FullName $accepted $rejected } catch { $rejected.Add([pscustomobject]@{ Source = $json.FullName; Reason = $_.Exception.Message }) }
    }
    $extractRoot = Join-Path $DestinationDirectory '_extract'
    foreach ($zip in @(Get-ChildItem -LiteralPath $SourceDirectory -Recurse -Filter '*.zip' -File)) {
        $extract = Join-Path $extractRoot ([IO.Path]::GetFileNameWithoutExtension($zip.Name))
        try {
            Expand-Archive -LiteralPath $zip.FullName -DestinationPath $extract -Force
            $results = @(Get-ChildItem -LiteralPath $extract -Recurse -Filter results.json -File)
            if ($results.Count -ne 1) { throw 'ZIP must contain exactly one results.json.' }
            Add-Document (Read-ResultDocument $results[0].FullName) $zip.FullName $accepted $rejected
        } catch { $rejected.Add([pscustomobject]@{ Source = $zip.FullName; Reason = $_.Exception.Message }) }
    }
    Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
    @($accepted) | Export-Csv -LiteralPath (Join-Path $DestinationDirectory 'accepted-results.csv') -NoTypeInformation -Encoding UTF8
    @($rejected) | Export-Csv -LiteralPath (Join-Path $DestinationDirectory 'rejected-results.csv') -NoTypeInformation -Encoding UTF8
    $summary = [ordered]@{ schema = 'zapret2-next.beta-summary'; schemaVersion = 1; generatedAtUtc = [DateTime]::UtcNow.ToString('o'); accepted = @($accepted); rejected = @($rejected) }
    Write-Utf8 (Join-Path $DestinationDirectory 'summary.json') (($summary | ConvertTo-Json -Depth 8) + "
")
    Write-Utf8 (Join-Path $DestinationDirectory 'SUMMARY.txt') ("Accepted: $($accepted.Count)
Rejected: $($rejected.Count)
Use rejected-results.csv to request a fresh, unmodified result ZIP.
")
    return $summary
}

if ($SelfTest) {
    $testRoot = Join-Path $root 'runtime\aggregate-self-test'
    $input = Join-Path $testRoot 'input'
    $output = Join-Path $testRoot 'output'
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $input | Out-Null
    $valid = @{ schema = $expectedSchema; schemaVersion = 1; status = 'completed-confirmed'; wizardVersion = 'simulation'; tester = @{ TesterId = 'mock'; Provider = 'mock'; RegionCity = ''; ConnectionType = 'mock' }; recommendation = @{ WebPreset = 'general'; VoiceMode = 'compatible'; Confirmed = $true }; userStatePreserved = $true }
    Write-Utf8 (Join-Path $input 'results.json') (($valid | ConvertTo-Json -Depth 5) + "`r`n")
    $partial = @{ schema = $expectedSchema; schemaVersion = 1 }
    $partialDir = Join-Path $input 'partial'
    New-Item -ItemType Directory -Force -Path $partialDir | Out-Null
    Write-Utf8 (Join-Path $partialDir 'results.json') (($partial | ConvertTo-Json) + "`r`n")
    $bad = $valid.Clone(); $bad.schemaVersion = 99
    $badDir = Join-Path $input 'bad'; New-Item -ItemType Directory -Force -Path $badDir | Out-Null
    Write-Utf8 (Join-Path $badDir 'results.json') (($bad | ConvertTo-Json -Depth 5) + "`r`n")
    Compress-Archive -Path (Join-Path $badDir '*') -DestinationPath (Join-Path $input 'incompatible.zip')
    Write-Utf8 (Join-Path $input 'corrupt.zip') 'not a zip'
    $summary = Invoke-Aggregation $input $output
    if ($summary.accepted.Count -ne 1 -or $summary.rejected.Count -lt 3) { throw 'Aggregator self-test did not classify valid, partial, corrupt, and incompatible inputs.' }
    Write-Host "Aggregator self-test passed: accepted=$($summary.accepted.Count), rejected=$($summary.rejected.Count)." -ForegroundColor Green
} else {
    $summary = Invoke-Aggregation $InputDirectory $OutputDirectory
    Write-Host "Aggregation completed: accepted=$($summary.accepted.Count), rejected=$($summary.rejected.Count)." -ForegroundColor Green
}
