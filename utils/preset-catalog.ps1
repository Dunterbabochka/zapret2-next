# Preset catalogue shared by the wizard, simulations and validation.
#
# Installation, release packaging, wizard and support diagnostics share this
# catalogue: 22 Classic variants from the local reference and two NEXT presets.
#
# Local additions are a separate layer: presets that live in presets\ but are
# neither shipped nor hidden are discovered from disk, shown in their own
# "Custom / other" menu column and validated with the same rules as the shipped
# ones. To add a strategy, drop presets\<NAME>.txt.in into the bundle and,
# optionally, strategies\general (<NAME>).bat. Nothing else has to be edited.

$classicPresets = @('general', 'ALT', 'ALT2', 'ALT3', 'ALT4', 'ALT5', 'ALT6', 'ALT7', 'ALT8', 'ALT9',
    'ALT10', 'ALT11', 'ALT12', 'ALT13', 'EXP', 'FAKE TLS AUTO', 'FAKE TLS AUTO ALT',
    'FAKE TLS AUTO ALT2', 'FAKE TLS AUTO ALT3', 'SIMPLE FAKE', 'SIMPLE FAKE ALT', 'SIMPLE FAKE ALT2')
$nextPresets = @('NEXT SAFE', 'NEXT BALANCED')
$publicPresets = @($classicPresets + $nextPresets)

# Presets that exist in the bundle but must stay hidden from the install menu.
$hiddenPresets = @('NEXT AGGRESSIVE', 'VOICE')

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
        Where-Object { $presetTemplateNames -notcontains $_ -and $_ -match '^[A-Za-z0-9 _-]+$' } |
        Sort-Object)
}

# Local additions: present in the bundle but neither shipped nor hidden.
function Get-ZapretCustomPresets {
    $shipped = @($publicPresets + $hiddenPresets)
    @(Get-ZapretAllPresets | Where-Object { $shipped -notcontains $_ })
}

# Keep every shipped strategy at its fixed number. Missing shipped files must
# fail validation and menu installation instead of shifting later selections.
function Get-ZapretMenuPresets {
    @($publicPresets) + @(Get-ZapretCustomPresets)
}

# Shipped strategies still require their launcher; local ones only need it if present.
function Get-ZapretRequiredLaunchers {
    @(@($publicPresets) | ForEach-Object { Get-ZapretPresetLauncher $_ })
}
