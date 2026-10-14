# Transport, package validation and durable update state. Tests replace boundary
# functions, never disable checksum/path checks or operate on the developer tree.
. (Join-Path $PSScriptRoot 'session-log.ps1')
. (Join-Path $PSScriptRoot 'bundle-operation.ps1')
. (Join-Path $PSScriptRoot 'ipset-utils.ps1')
. (Join-Path $PSScriptRoot 'service-control.ps1')
. (Join-Path $PSScriptRoot 'telegram-control.ps1')

$script:releaseFiles = @('README.md','LICENSE.txt','SECURITY.md','THIRD_PARTY_NOTICES.md','ENGINE_VERSION','SHA256SUMS.txt','service.bat')
$script:releaseDirectories = @('bin','lua','presets','strategies','utils','docs','.service')
$script:releaseModeNames = @('game_filter.mode','ipset_filter.mode','voice_filter.mode','discord_fake.mode','game_fake.mode','check_updates.enabled')

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
function Assert-ReleaseChildPath([string]$Parent, [string]$Path) {
    $base = [IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { throw 'Update path escapes its working directory.' }
    return $full
}
function Assert-ReleaseNoLinks([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked update paths are not supported: $Path" }
    if ($item.PSIsContainer) {
        foreach ($child in Get-ChildItem -LiteralPath $Path -Force) { Assert-ReleaseNoLinks $child.FullName }
    }
}
function Remove-ReleaseTree([string]$Parent, [string]$Path) {
    $full = Assert-ReleaseChildPath $Parent $Path
    if (Test-Path -LiteralPath $full) {
        Assert-ReleaseNoLinks $full
        Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
    }
}
function Initialize-ReleaseUpdateDirectory([string]$Root) {
    $directory = Get-ReleaseUpdateDirectory $Root
    # Check ancestors as well: an existing junction must not redirect the worker.
    foreach ($path in @($Root, (Join-Path $Root 'runtime'), $directory)) {
        if (Test-Path -LiteralPath $path) {
            if ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Update directory cannot be a link.' }
        }
    }
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18','S-1-5-32-544', [Security.Principal.WindowsIdentity]::GetCurrent().User.Value)) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule(
            (New-Object Security.Principal.SecurityIdentifier($sid)), 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    # Set only the DACL. Set-Acl may request SeSecurityPrivilege for unrelated
    # audit sections on Windows PowerShell even for an owner-created folder.
    $info = [IO.DirectoryInfo]::new($directory)
    if ($info.PSObject.Methods['SetAccessControl']) { $info.SetAccessControl($acl) }
    else { [Security.AccessControl.FileSystemAclExtensions]::SetAccessControl($info, $acl) }
    return $directory
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
function Get-ReleaseApiUrl([string]$Repository) { 'https://api.github.com/repos/' + $Repository + '/releases/latest' }
function Assert-ReleaseAssetUrl([string]$Url, [string]$Repository, [string]$Tag, [string]$Name) {
    $expected = 'https://github.com/' + $Repository + '/releases/download/' + $Tag + '/' + $Name
    if ($Url -cne $expected) { throw 'Release asset does not belong to the configured repository/tag.' }
}
function Get-ReleaseHttpTarget([string]$Url) { [pscustomobject]@{Url=$Url;Protocol='https'} }
function Invoke-ReleaseHttp {
    param([string]$Url, [string]$Output, [string]$ETag = '', [switch]$Download)
    $headers = $Output + '.headers'
    $target = Get-ReleaseHttpTarget $Url
    $arguments = @('--silent','--show-error','--location','--max-redirs','5','--proto',('='+$target.Protocol),'--proto-redir',('='+$target.Protocol),
        '--connect-timeout','3','--max-time', $(if ($Download) {'300'} else {'10'}),
        '--user-agent','Zapret2Next-Updater','--header','Accept: application/vnd.github+json',
        '--header','X-GitHub-Api-Version: 2026-03-10','--dump-header',$headers,'--output',$Output,'--write-out','%{http_code}')
    if ($Download) { $arguments += @('--speed-limit','1024','--speed-time','30') }
    if ($ETag) {
        if ($ETag -match '[\r\n]' -or $ETag.Length -gt 256) { throw 'Invalid cached ETag.' }
        $nativeETag=$ETag
        # Windows PowerShell's legacy native argv strips unescaped quotes.
        if ($PSVersionTable.PSVersion.Major -le 5) { $nativeETag=$ETag.Replace('"','\"') }
        $arguments += @('--header', ('If-None-Match: ' + $nativeETag))
    }
    $arguments += @('--url',$target.Url)
    Write-ZapretLogEvent -Action HTTP -Stage request -Details @{etagSent=[bool]$ETag}
    $code = & curl.exe @arguments 2>$null
    $curlExit=$LASTEXITCODE
    $httpStatus=0; $null=[int]::TryParse([string]($code | Select-Object -Last 1),[ref]$httpStatus)
    $transportOk=$curlExit -eq 0 -and $httpStatus -ge 200 -and $httpStatus -lt 400
    Write-ZapretLogEvent -Action HTTP -Result $(if ($transportOk) {'ok'} else {'error'}) -Code $(if ($transportOk) {'None'} else {'HTTPFailed'}) -Details @{curlCode=$curlExit;httpCode=$httpStatus}
    if ($curlExit -ne 0) { throw 'GitHub download failed or timed out. The installed version has not been removed.' }
    $tag = ''
    foreach ($line in [IO.File]::ReadAllLines($headers)) { if ($line -match '^(?i:etag):\s*(.+)$') { $tag = $matches[1].Trim() } }
    Write-ZapretLogEvent -Action HTTP -Details @{etagReceived=[bool]$tag}
    return [pscustomobject]@{ Status = [int]($code | Select-Object -Last 1); ETag = $tag }
}
function ConvertTo-ReleaseOffer($Release, [string]$Repository) {
    if ($Release.draft -ne $false -or $Release.prerelease -ne $false -or [string]$Release.tag_name -notmatch '^v?(\d+\.\d+\.\d+)$') {
        throw 'GitHub did not return a stable release.'
    }
    $version = $matches[1]
    $tag = [string]$Release.tag_name
    $archiveName = 'zapret2-next-v' + $version + '.zip'
    $archive = @($Release.assets | Where-Object { $_.name -ceq $archiveName -and $_.state -eq 'uploaded' })
    $checksum = @($Release.assets | Where-Object { $_.name -ceq 'release-sha256.txt' -and $_.state -eq 'uploaded' })
    if ($archive.Count -ne 1 -or $checksum.Count -ne 1 -or [long]$archive[0].size -le 0) { throw 'The release ZIP or its checksum is missing.' }
    Assert-ReleaseAssetUrl $archive[0].browser_download_url $Repository $tag $archiveName
    Assert-ReleaseAssetUrl $checksum[0].browser_download_url $Repository $tag 'release-sha256.txt'
    return [pscustomobject]@{ Repository=$Repository; Version=$version; Tag=$tag; ArchiveName=$archiveName
        ArchiveUrl=[string]$archive[0].browser_download_url; ChecksumUrl=[string]$checksum[0].browser_download_url; Size=[long]$archive[0].size }
}
function Invoke-ReleaseCheck([string]$Root, [switch]$Force) {
    $directory = Initialize-ReleaseUpdateDirectory $Root
    $cachePath = Join-Path $directory 'check.json'
    $checkLock = $null
    $temporary = Join-Path $directory ([Guid]::NewGuid().ToString('N') + '.json')
    try {
        $checkLock = [IO.File]::Open((Join-Path $directory 'check.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
        $repository = Get-ReleaseRepository $Root
        $installed = Get-ReleaseVersion $Root
        $cache = try { Read-ReleaseJson $cachePath } catch { $null }
        $etag = ''
        if (-not $Force -and $cache -and $cache.Repository -ceq $repository -and $cache.Offer) { $etag = [string]$cache.ETag }
        $response = Invoke-ReleaseHttp -Url (Get-ReleaseApiUrl $repository) -Output $temporary -ETag $etag
        if ($response.Status -eq 304 -and $etag) { $offer = $cache.Offer }
        elseif ($response.Status -eq 200) { $offer = ConvertTo-ReleaseOffer (Read-ReleaseJson $temporary) $repository }
        else { throw "GitHub release check returned HTTP $($response.Status)." }
        $status = if (Test-ReleaseNewer $offer.Version $installed) { 'available' } else { 'current' }
        $result = [pscustomobject]@{ Status=$status; Repository=$repository; Installed=$installed; Offer=$offer
            ETag=$(if ($response.ETag) {$response.ETag} else {$etag}); CheckedUtc=[DateTime]::UtcNow.ToString('o'); Error='' }
        Write-ReleaseJson $cachePath $result
        Write-ZapretLogEvent -Action Check -Result $status -Details @{fromVersion=$installed;toVersion=$offer.Version}
        return $result
    } catch {
        Write-ZapretLogException $_ -Code HTTPFailed -Warning
        Write-ZapretLogEvent -Action Check -Result unavailable -Code HTTPFailed
        if (-not $checkLock) { return $null }
        $result = [pscustomobject]@{Status='unavailable';Repository='';Installed='';Offer=$null;ETag='';CheckedUtc=[DateTime]::UtcNow.ToString('o');Error=$_.Exception.Message}
        Write-ReleaseJson $cachePath $result
        return $result
    } finally {
        foreach ($path in @($temporary, ($temporary + '.headers'))) { if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) } }
        if ($checkLock) { $checkLock.Dispose() }
    }
}
function Save-ReleaseDownload([string]$Url, [string]$Path) {
    $assetKind=if ((Split-Path -Leaf $Path) -ceq 'release-sha256.txt') {'checksum'} else {'archive'}
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        try {
            Write-ZapretLogEvent -Action Download -Stage request -Details @{attempt=($attempt+1);asset=$assetKind}
            $response = Invoke-ReleaseHttp -Url $Url -Output $Path -Download
            if ($response.Status -ne 200) { throw "Release download returned HTTP $($response.Status)." }
            return
        } catch {
            if ([IO.File]::Exists($Path)) { [IO.File]::Delete($Path) }
            Write-ZapretLogException $_ -Warning
            if ($attempt -eq 1) { Write-ZapretLogEvent -Action Download -Stage end -Result error -Code HTTPFailed -Details @{attempt=2;asset=$assetKind}; throw }
            Write-ZapretLogEvent -Action Download -Stage retry -Result warning -Code DownloadRetry -Details @{attempt=2;asset=$assetKind}
        }
    }
}
function Expand-ReleasePackage([string]$Archive, [string]$Destination, [string]$Version) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $prefix = 'zapret2-next-v' + $Version + '/'
    $total = [long]0
    try {
        # Validate the entire directory before extracting even the first file.
        foreach ($entry in $zip.Entries) {
            $relative = $entry.FullName.Replace('\','/')
            if (-not $relative.StartsWith($prefix, [StringComparison]::Ordinal) -or $relative.Contains(':') -or
                $relative -match '(^|/)(\.{1,2})(/|$)|[\x00-\x1f]' -or $relative -match '[. ](/|$)' -or
                $relative -match '(?i)(^|/)(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:[./]|$)' -or
                (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) { throw 'Unsafe or unexpected release ZIP path.' }
            $path = Assert-ReleaseChildPath $Destination (Join-Path $Destination $relative.Replace('/','\'))
            if (-not $seen.Add($path.TrimEnd('\'))) { throw 'Duplicate release ZIP path.' }
            $total += $entry.Length
            if ($total -gt 1GB -or $zip.Entries.Count -gt 10000) { throw 'Release ZIP exceeds extraction limits.' }
        }
        foreach ($entry in $zip.Entries) {
            $path = Join-Path $Destination $entry.FullName.Replace('/','\')
            if ($entry.FullName.EndsWith('/')) { New-Item -ItemType Directory -Path $path -Force | Out-Null; continue }
            New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $path, $false)
        }
    } finally { $zip.Dispose() }
    return Join-Path $Destination $prefix.TrimEnd('/')
}
function Test-ReleaseManifest([string]$Root, [string]$Manifest) {
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($line in [IO.File]::ReadAllLines($Manifest)) {
        if (-not $line.Trim() -or $line.StartsWith('#')) { continue }
        if ($line -notmatch '^([0-9a-fA-F]{64})[ \t]+\*?(.+)$') { throw 'Invalid release integrity manifest.' }
        $hash = $matches[1]; $relative = $matches[2].Trim()
        if ([IO.Path]::IsPathRooted($relative) -or $relative.Contains(':')) { throw 'Invalid manifest path.' }
        $path = Assert-ReleaseChildPath $Root (Join-Path $Root $relative)
        if (-not $seen.Add($path)) { throw 'Duplicate integrity manifest entry.' }
        if (-not [IO.File]::Exists($path) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $hash) { throw "Release integrity check failed: $relative" }
    }
    if (-not $seen.Contains((Join-Path $Root 'bin\winws2.exe'))) { throw 'The integrity manifest does not cover the engine.' }
}
function Assert-ReleasePackage([string]$Stage, $Offer) {
    if ((Get-ReleaseVersion $Stage) -cne $Offer.Version -or (Get-ReleaseRepository $Stage) -cne $Offer.Repository) { throw 'Release version/repository does not match its archive.' }
    foreach ($relative in @($script:releaseFiles + $script:releaseDirectories + @('lists','utils\update-release.ps1','utils\update-release-core.ps1','utils\update-release-state.ps1','utils\bundle-operation.ps1','utils\render-config.ps1'))) {
        if (-not (Test-Path -LiteralPath (Join-Path $Stage $relative))) { throw "Incomplete release: $relative" }
    }
    foreach ($item in Get-ChildItem -LiteralPath $Stage -Force) {
        if ($item.Name -notin @($script:releaseFiles + $script:releaseDirectories + @('lists'))) { throw "Unexpected release content: $($item.Name)" }
    }
    Test-ReleaseManifest $Stage (Join-Path $Stage 'SHA256SUMS.txt')
    Assert-ZapretTelegramRuntime -Root $Stage
}
