param(
    [string]$Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
)

$ErrorActionPreference = 'Stop'
$listDir = Join-Path $Root 'lists'
if (-not (Test-Path -LiteralPath $listDir -PathType Container)) {
    throw "Lists directory not found: $listDir"
}

$templates = @{
    'list-general-user.txt' = "# Replace this safe placeholder with domains to process.`r`ndomain.example.abc`r`n"
    'list-exclude-user.txt' = "# Replace this safe placeholder with domains to exclude.`r`ndomain.example.abc`r`n"
    'ipset-exclude-user.txt' = "# Replace this documentation IP with exclusions.`r`n203.0.113.113/32`r`n"
}
foreach ($name in $templates.Keys) {
    $path = Join-Path $listDir $name
    if (-not (Test-Path -LiteralPath $path)) {
        try {
            $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
            try {
                $bytes = [Text.Encoding]::ASCII.GetBytes($templates[$name])
                $stream.Write($bytes, 0, $bytes.Length)
            } finally {
                $stream.Dispose()
            }
        } catch [IO.IOException] {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw }
        }
    } elseif (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "User list path is not a file: $path"
    }
}
