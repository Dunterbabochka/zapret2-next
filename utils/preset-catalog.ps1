# Preset catalogue shared by the wizard, simulations and validation.
#
# Classic and NEXT presets are the ones shipped upstream and are pinned here.
# Everything else found in presets\ is treated as a local addition: it is
# discovered automatically, shown in its own "Custom / other" menu column,
# validated with the same rules as the shipped presets and optional to launch.
#
# To add a strategy, drop presets\<NAME>.txt.in into the bundle. Optionally add
# strategies\general (<NAME>).bat for a manual launcher. No list to edit.

$classicPresets = @('general', 'ALT', 'ALT3', 'ALT5', 'ALT11', 'ALT12', 'ALT13', 'EXP', 'FAKE TLS AUTO ALT2')
$nextPresets = @('NEXT SAFE', 'NEXT BALANCED')

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

# Every preset name the bundle actually ships, in stable menu order.
function Get-ZapretAllPresets {
    $presetDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'presets'
    if (-not (Test-Path -LiteralPath $presetDir -PathType Container)) { return @() }
    @(Get-ChildItem -LiteralPath $presetDir -Filter '*.txt.in' -File |
        ForEach-Object { $_.Name -replace '\.txt\.in$', '' } |
        Where-Object { $presetTemplateNames -notcontains $_ } |
        Sort-Object)
}

# Presets added locally: present in the bundle but not shipped upstream and not hidden.
function Get-ZapretCustomPresets {
    $shipped = @($classicPresets + $nextPresets + $hiddenPresets)
    @(Get-ZapretAllPresets | Where-Object { $shipped -notcontains $_ })
}

# The single source of truth for "public" presets: shipped plus local additions.
# Anything referenced here must exist, so a dangling entry is a validation error.
function Get-ZapretPublicPresets {
    $present = @(Get-ZapretAllPresets)
    @(@($classicPresets + $nextPresets) + @(Get-ZapretCustomPresets) |
        Where-Object { $present -contains $_ })
}

# Shipped presets still require their launcher; local ones only need it if present.
function Get-ZapretRequiredLaunchers {
    @(@($classicPresets + $nextPresets) | ForEach-Object { Get-ZapretPresetLauncher $_ })
}