$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$errors = [Collections.Generic.List[string]]::new()

function Add-WizardValidationError([string]$Message) {
    $script:errors.Add($Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

$statePaths = @(
    (Join-Path $root 'utils\game_filter.mode'),
    (Join-Path $root 'utils\ipset_filter.mode'),
    (Join-Path $root 'utils\voice_filter.mode'),
    (Join-Path $root 'lists\ipset-all.txt')
)
$stateBefore = @{}
foreach ($path in $statePaths) {
    $stateBefore[$path] = if (Test-Path -LiteralPath $path -PathType Leaf) {
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    } else { '<missing>' }
}

$launcher = Join-Path $root 'compatibility wizard.bat'
$wizard = Join-Path $PSScriptRoot 'compatibility-wizard.ps1'
$targets = Join-Path $PSScriptRoot 'compatibility-targets.json'
$builder = Join-Path $PSScriptRoot 'build-release.ps1'
$modules = @(
    $wizard,
    (Join-Path $PSScriptRoot 'compatibility-wizard-core.ps1'),
    (Join-Path $PSScriptRoot 'compatibility-wizard-preflight.ps1'),
    (Join-Path $PSScriptRoot 'compatibility-wizard-network.ps1'),
    (Join-Path $PSScriptRoot 'compatibility-wizard-main.ps1'),
    (Join-Path $PSScriptRoot 'compatibility-wizard-simulation.ps1')
)
$requiredPaths = @($launcher, $targets) + $modules
if (Test-Path -LiteralPath $builder -PathType Leaf) {
    $requiredPaths += $builder
}
foreach ($path in $requiredPaths) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Add-WizardValidationError "Missing Stage 3 file: $path" }
}

if (Test-Path -LiteralPath $launcher -PathType Leaf) {
    $launcherText = Get-Content -LiteralPath $launcher -Raw
    if ($launcherText -notmatch 'fltmc' -or $launcherText -notmatch 'Verb RunAs' -or $launcherText -notmatch 'compatibility-wizard\.ps1') {
        Add-WizardValidationError 'The Compatibility Wizard launcher must elevate and call the local PowerShell entry point.'
    }
}
if (Test-Path -LiteralPath $builder -PathType Leaf) {
    $builderText = Get-Content -LiteralPath $builder -Raw
    if ($builderText -notmatch [regex]::Escape("'compatibility wizard.bat'")) {
        Add-WizardValidationError 'The release allowlist is missing compatibility wizard.bat.'
    }
}

try {
    $parsedTargets = Get-Content -LiteralPath $targets -Raw | ConvertFrom-Json
    $targetData = @($parsedTargets | ForEach-Object { $_ })
    if ($targetData.Count -lt 6) { Add-WizardValidationError 'The local endpoint file is unexpectedly small.' }
} catch {
    Add-WizardValidationError "The local endpoint file is invalid JSON: $($_.Exception.Message)"
}

$wizardText = @($modules | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object { Get-Content -LiteralPath $_ -Raw }) -join "`n"
foreach ($required in @(
    'REPORT.txt', 'results.json', 'web-results.csv', 'schemaVersion',
    "@('off', 'standard', 'compatible')", "-GameMode 'off'", "-IPSetMode 'any'",
    "-VoiceMode 'off'", 'final-recheck', 'Stop-ConflictState', 'Restore-ConflictState',
    'RawEtlIncluded = $false', 'userStatePreserved', 'privacyConsent',
    'FreshHandshakeObserved', 'StrategyActionObserved'
)) {
    if ($wizardText -notmatch [regex]::Escape($required)) { Add-WizardValidationError "Wizard contract is missing: $required" }
}
if ($wizardText -match '(?m)\$recommendedIPSet\s*=\s*[^\r\n]*\bany\b' -or
    $wizardText -match '(?i)IPSet any is explicitly recommended') {
    Add-WizardValidationError 'The Compatibility Wizard must never emit IPSet any as a persistent recommendation.'
}
if ($wizardText -notmatch '\$diagnosticIPSet') {
    Add-WizardValidationError 'The Compatibility Wizard must keep IPSet any in an explicit diagnostic-only variable.'
}
foreach ($forbiddenPattern in @(
    ('Invoke-' + 'RestMethod'),
    ('api' + '\.openai'),
    ('--dpi-' + 'desync')
)) {
    if ($wizardText -match $forbiddenPattern) {
        Add-WizardValidationError 'The Compatibility Wizard must remain local and use only Zapret 2 options.'
    }
}
if ($wizardText -match '(?i)(?:Set-Content|WriteAllText).*?(?:game_filter\.mode|ipset_filter\.mode|voice_filter\.mode|ipset-all\.txt)') {
    Add-WizardValidationError 'The Compatibility Wizard must not write saved modes or the loaded IPSet.'
}

try {
    & $wizard -ValidateContract
} catch {
    Add-WizardValidationError $_.Exception.Message
}

foreach ($path in $statePaths) {
    $after = if (Test-Path -LiteralPath $path -PathType Leaf) {
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    } else { '<missing>' }
    if ($after -ne $stateBefore[$path]) { Add-WizardValidationError "Contract validation changed user state: $path" }
}

if ($errors.Count) {
    Write-Host "Compatibility Wizard validation failed with $($errors.Count) error(s)." -ForegroundColor Red
    exit 1
}
Write-Host 'Compatibility Wizard validation passed.' -ForegroundColor Green
exit 0
