# Shared by the installed updater and the maintainer's upstream sync tool.
function Read-ValidatedIPSet {
    param([string]$Path, [int]$MinimumEntries = 10)

    $entries = [Collections.Generic.List[string]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $lineNumber = 0
    foreach ($line in Get-Content -LiteralPath $Path -ErrorAction Stop) {
        $lineNumber++
        $entry = ([string]$line).Trim()
        if (-not $entry -or $entry.StartsWith('#')) { continue }
        $parts = $entry.Split('/')
        $address = $null
        # TryParse accepts abbreviated IPv4 and integer addresses, too.
        $isIPv4 = $parts[0] -match '^\d{1,3}(?:\.\d{1,3}){3}$'
        $isIPv6 = $parts[0].Contains(':') -and $parts[0] -match '^[0-9a-fA-F:.]+$'
        if ($parts.Count -gt 2 -or (-not $isIPv4 -and -not $isIPv6) -or
            -not [Net.IPAddress]::TryParse($parts[0], [ref]$address)) {
            throw "Invalid IP address at line $lineNumber`: $entry"
        }
        $maximum = if ($address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork) { 32 } else { 128 }
        $prefix = $maximum
        if ($parts.Count -eq 2 -and ($parts[1] -notmatch '^\d{1,3}$' -or
            -not [int]::TryParse($parts[1], [ref]$prefix) -or $prefix -gt $maximum)) {
            throw "Invalid CIDR prefix at line $lineNumber`: $entry"
        }
        if ($prefix -eq 0) { throw "Refusing an all-addresses CIDR at line $lineNumber`: $entry" }
        $normalized = $address.ToString()
        if ($parts.Count -eq 2) { $normalized += "/$prefix" }
        if (-not $seen.Add($normalized)) { throw "Duplicate IPSet entry at line $lineNumber`: $entry" }
        $entries.Add($normalized)
    }
    if ($entries.Count -lt $MinimumEntries) {
        throw "IPSet contains only $($entries.Count) entries; refusing a suspiciously small snapshot."
    }
    return $entries.ToArray()
}

function Assert-IPSetSize {
    param([int]$CandidateCount, [int]$CurrentCount)
    if ($CurrentCount -ge 100 -and $CandidateCount -lt [Math]::Ceiling($CurrentCount / 2.0)) {
        throw "IPSet shrank from $CurrentCount to $CandidateCount entries; refusing a suspiciously small snapshot."
    }
}

function Write-AtomicTextFile {
    param([string]$Path, [string]$Content, [Text.Encoding]$Encoding = [Text.Encoding]::ASCII, [string]$BackupPath)
    Write-AtomicFileBytes -Path $Path -Bytes ($Encoding.GetBytes($Content)) -BackupPath $BackupPath
}

function Write-AtomicFileBytes {
    param([string]$Path, [byte[]]$Bytes, [string]$BackupPath)
    $temporary = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllBytes($temporary, $Bytes)
        if ([IO.File]::Exists($Path)) {
            $replacementBackup = if ($BackupPath) { $BackupPath } else { [NullString]::Value }
            # Restricted Windows accounts may not copy the old file's ACLs;
            # the new file inherits permissions from the same directory.
            [IO.File]::Replace($temporary, $Path, $replacementBackup, $true)
        } else {
            [IO.File]::Move($temporary, $Path)
        }
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}
