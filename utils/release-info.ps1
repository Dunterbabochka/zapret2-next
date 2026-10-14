# Lightweight local release metadata; no Windows management imports.
function Get-ReleaseUpdateDirectory([string]$Root) { Join-Path $Root 'runtime\release-update' }
function Write-ReleaseJson([string]$Path, $Value) {
    Write-AtomicTextFile -Path $Path -Content (($Value | ConvertTo-Json -Depth 24) + "`r`n") -Encoding ([Text.UTF8Encoding]::new($false))
}
function Read-ReleaseJson([string]$Path) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        # Menu polling must not prevent the worker's atomic cache replacement.
        $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true)
        try { $reader.ReadToEnd() | ConvertFrom-Json }
        finally { $reader.Dispose() }
    }
}
function Get-ReleaseRepository([string]$Root) {
    $repository = ([IO.File]::ReadAllText((Join-Path $Root '.service\repository.txt'))).Trim()
    if ($repository -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$') { throw 'Invalid release repository.' }
    return $repository
}
function Get-ReleaseVersion([string]$Root) {
    $version = ([IO.File]::ReadAllText((Join-Path $Root '.service\version.txt'))).Trim()
    if ($version -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') { throw 'Invalid installed version.' }
    return $version
}
function Test-ReleaseNewer([string]$Remote, [string]$Installed) {
    if ($Remote -notmatch '^\d+\.\d+\.\d+$') { return $false }
    $localBase = ($Installed -split '-', 2)[0]
    return ([version]$Remote -gt [version]$localBase -or ($Remote -eq $localBase -and $Installed.Contains('-')))
}
function Wait-ReleaseMenuHost([string]$Path,[int]$TimeoutMilliseconds=10000) {
    $text=[IO.File]::ReadAllText($Path)
    if ($text -ceq 'released') { return } # Older BAT menus have no persistent host.
    $release=$text | ConvertFrom-Json
    if (-not $release.ProcessId -or -not $release.StartedTicks) { throw 'Invalid menu release marker.' }
    $menu=Get-Process -Id ([int]$release.ProcessId) -ErrorAction SilentlyContinue
    if ($menu) {
        try {
            if ($menu.StartTime.ToUniversalTime().Ticks -eq [long]$release.StartedTicks -and -not $menu.WaitForExit($TimeoutMilliseconds)) { throw 'The old menu host did not exit.' }
        } finally { $menu.Dispose() }
    }
}
