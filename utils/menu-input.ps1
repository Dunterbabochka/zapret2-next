. (Join-Path $PSScriptRoot 'release-info.ps1')
function Get-ReleaseMenuBanner([string]$Root, [hashtable]$State=$null) {
    try {
        if ($State) {
            $fingerprint=(@('runtime\release-update\check.json','.service\repository.txt','.service\version.txt') | ForEach-Object {
                $info=[IO.FileInfo]::new((Join-Path $Root $_))
                if ($info.Exists) { [string]$info.LastWriteTimeUtc.Ticks+':'+[string]$info.Length }
                else { 'missing' }
            }) -join '|'
            if ($State.Fingerprint -ceq $fingerprint -and $State.Timer.ElapsedMilliseconds -lt 2000) { return $State.Banner }
            $State.Fingerprint=$fingerprint
            $State.Timer.Restart()
            $State.Banner=''
        }
        $cache = Read-ReleaseJson (Join-Path (Get-ReleaseUpdateDirectory $Root) 'check.json')
        if ($cache -and $cache.Status -eq 'available' -and $cache.Repository -ceq (Get-ReleaseRepository $Root) -and
            (Test-ReleaseNewer $cache.Offer.Version (Get-ReleaseVersion $Root))) {
            $banner='Доступна новая версия ' + $cache.Offer.Version + '. Чтобы обновить Zapret, введите 111'
            if ($State) { $State.Banner=$banner }
            return $banner
        }
    } catch {}
    return ''
}
function Read-ReleaseMenuChoice([string]$Root, [scriptblock]$OnReady=$null) {
    $prompt = '   Select option (0-15): '
    # PowerShell 5.1 otherwise encodes Console.Write text in the OEM code page;
    # English Windows replaces the Cyrillic update notification with '?'.
    if (-not [Console]::IsOutputRedirected) { [Console]::OutputEncoding=[Text.UTF8Encoding]::new($false) }
    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
        $banner = Get-ReleaseMenuBanner $Root
        if ($banner) { [Console]::WriteLine($banner) }
        [Console]::Write($prompt)
        if ($OnReady) { & $OnReady }
        $answer = [Console]::ReadLine()
        if ($null -eq $answer) { return 0 }
        if ($answer -match '^(?:[0-9]|1[0-5]|111)$') { return [int]$answer }
        return 255
    }
    # Use a small local polling loop, not another process/network request for
    # every repaint. Reserve space above the prompt and preserve typed digits.
    [Console]::WriteLine('')
    [Console]::WriteLine('')
    $banner = ''; $answer = ''; $lastPoll = -250
    $timer=[Diagnostics.Stopwatch]::StartNew()
    $state=@{Fingerprint='';Banner='';Timer=[Diagnostics.Stopwatch]::StartNew()}
    [Console]::Write($prompt)
    if ($OnReady) { & $OnReady }
    while ($true) {
        if ($timer.ElapsedMilliseconds - $lastPoll -ge 250) {
            $next = Get-ReleaseMenuBanner $Root $state
            if ($next -cne $banner) {
                $banner = $next
                [Console]::Write("`r`n")
                if ($banner) { [Console]::WriteLine($banner) }
                [Console]::Write($prompt + $answer)
            }
            $lastPoll = $timer.ElapsedMilliseconds
        }
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq [ConsoleKey]::Enter) {
                [Console]::WriteLine('')
                if ($answer -match '^(?:[0-9]|1[0-5]|111)$') { return [int]$answer }
                return 255
            }
            if ($key.Key -eq [ConsoleKey]::Backspace) {
                if ($answer.Length) { $answer=$answer.Substring(0,$answer.Length-1);[Console]::Write("`b `b") }
            } elseif ($key.KeyChar -match '[0-9]' -and $answer.Length -lt 3) {
                $answer += $key.KeyChar; [Console]::Write($key.KeyChar)
            }
        } else { Start-Sleep -Milliseconds 25 }
    }
}
