# One cross-session, reentrant gate for operations that modify an installation.
# Keep it independent of files that are moved during a release update.
function Enter-ZapretBundleOperation {
    param([Parameter(Mandatory)][string]$Root)
    $canonical = [IO.Path]::GetFullPath($Root).TrimEnd('\').ToUpperInvariant()
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $key = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical))).Replace('-', '') }
    finally { $sha.Dispose() }
    $mutex = [Threading.Mutex]::new($false, ('Global\Zapret2Next-Bundle-' + $key))
    try {
        $acquired = $false
        try { $acquired = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw 'Another operation or release update is using this installation. Try again when it finishes.' }
        return $mutex
    } catch { $mutex.Dispose(); throw }
}

function Exit-ZapretBundleOperation {
    param($Gate)
    if ($Gate) { try { $Gate.ReleaseMutex() } finally { $Gate.Dispose() } }
}
