# Preset catalogue shared by the wizard, simulations and validation.
#
# $classicPresets, $nextPresets and $publicPresets keep their original contract:
# the release builder, the compatibility wizard and the support diagnostics all
# iterate $publicPresets, and the wizard asserts its exact size. Do not rename or
# redefine it.
#
# Local additions are a separate layer: presets that live in presets\ but are
# neither shipped nor hidden are discovered from disk, shown in their own
# "Custom / other" menu column and validated with the same rules as the shipped
# ones. To add a strategy, drop presets\<NAME>.txt.in into the bundle and,
# optionally, strategies\general (<NAME>).bat. Nothing else has to be edited.

$classicPresets = @('general', 'ALT', 'ALT3', 'ALT5', 'ALT11', 'ALT12', 'ALT13', 'EXP', 'FAKE TLS AUTO ALT2')
$nextPresets = @('NEXT SAFE', 'NEXT BALANCED')
$publicPresets = @($classicPresets + $nextPresets)

# Presets that exist in the bundle but must stay hidden from the install menu.
$hiddenPresets = @('NEXT AGGRESSIVE', 'VOICE', 'FAKE TLS AUTO', 'SIMPLE FAKE')

# Files in presets\ that are templates rather than strategies.
$presetTemplateNames = @('_base', '_profiles')

function Get-ZapretPresetPath([string]$preset) {
    Join-Path (Split-Path -Parent $PSScriptRoot) ('presets\' + $preset + '.txt.in')
}

function Get-ZapretPresetLauncher([string]$preset) {
    if ($preset -eq 'general') { return 'general.bat' }
    'general (' + $preset + ').bat'
}

# Every strategy the bundle actually ships, in stable order.
function Get-ZapretAllPresets {
    $presetDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'presets'
    if (-not (Test-Path -LiteralPath $presetDir -PathType Container)) { return @() }
    @(Get-ChildItem -LiteralPath $presetDir -Filter '*.txt.in' -File |
        ForEach-Object { $_.Name -replace '\.txt\.in$', '' } |
        Where-Object { $presetTemplateNames -notcontains $_ } |
        Sort-Object)
}

# Local additions: present in the bundle but neither shipped nor hidden.
function Get-ZapretCustomPresets {
    $shipped = @($publicPresets + $hiddenPresets)
    @(Get-ZapretAllPresets | Where-Object { $shipped -notcontains $_ })
}

# Shipped strategies plus local additions, skipping any name whose file is gone
# so a removed preset degrades gracefully instead of breaking the wizard.
function Get-ZapretMenuPresets {
    $present = @(Get-ZapretAllPresets)
    @(@($publicPresets) + @(Get-ZapretCustomPresets) | Where-Object { $present -contains $_ })
}

# Shipped strategies still require their launcher; local ones only need it if present.
function Get-ZapretRequiredLaunchers {
    @(@($publicPresets) | ForEach-Object { Get-ZapretPresetLauncher $_ })
}