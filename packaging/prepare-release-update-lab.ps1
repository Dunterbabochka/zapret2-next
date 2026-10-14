# Creates two local release copies and a loopback HTTP fixture for a disposable
# Windows VM. Does not install services, start proxies, or publish releases.
param([string]$OutputDirectory)
$ErrorActionPreference='Stop'
$source=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $OutputDirectory) { $OutputDirectory=Join-Path $source ('runtime\update-lab-'+[Guid]::NewGuid().ToString('N')) }
$lab=[IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $lab) { throw 'Choose a new, empty OutputDirectory for the update lab.' }
New-Item -ItemType Directory -Path $lab -Force | Out-Null
$version=([IO.File]::ReadAllText((Join-Path $source '.service\version.txt'))).Trim()
& (Join-Path $source 'utils\build-release.ps1') -Version $version -OutputDirectory (Join-Path $lab 'build')
$base=Join-Path $lab ('build\zapret2-next-v'+$version)
$install=Join-Path $lab 'installed'
$package=Join-Path $lab 'zapret2-next-v9.9.1'
Copy-Item -LiteralPath $base -Destination $install -Recurse -Force
Copy-Item -LiteralPath $base -Destination $package -Recurse -Force
[IO.File]::WriteAllText((Join-Path $install '.service\version.txt'),'9.9.0',[Text.Encoding]::ASCII)
[IO.File]::WriteAllText((Join-Path $package '.service\version.txt'),'9.9.1',[Text.Encoding]::ASCII)
$escapedLab=$lab.Replace("'","''")
$adapter=@'

# LOCAL UPDATE LAB ONLY. Never publish this patched copy.
function Get-ReleaseHttpTarget([string]$Url) {
    $port=([IO.File]::ReadAllText('LABPATH\port.txt')).Trim()
    if ($Url -eq 'https://api.github.com/repos/Dunterbabochka/zapret2-next/releases/latest') { $path='/release' }
    elseif ($Url -like 'https://github.com/Dunterbabochka/zapret2-next/releases/download/*') { $path='/assets/'+([Uri]$Url).Segments[-1] }
    else { throw 'Unexpected request outside the local update lab.' }
    [pscustomobject]@{Url=('http://127.0.0.1:'+$port+$path);Protocol='http'}
}
'@
$adapter=$adapter.Replace('LABPATH',$escapedLab)
foreach ($root in @($install,$package)) {
    $path=Join-Path $root 'utils\update-release.ps1'
    $text=[IO.File]::ReadAllText($path)
    $needle=". (Join-Path `$PSScriptRoot 'update-release-state.ps1')"
    [IO.File]::WriteAllText($path,$text.Replace($needle,$needle+$adapter),[Text.UTF8Encoding]::new($true))
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($package,(Join-Path $lab 'valid.zip'),[IO.Compression.CompressionLevel]::Fastest,$true)
[IO.File]::WriteAllText((Join-Path $lab 'scenario.json'),'{"mode":"ok","version":"9.9.1"}',[Text.Encoding]::ASCII)
Write-Host 'Local update lab prepared. Use only in a disposable Windows VM.' -ForegroundColor Cyan
Write-Host ('Start the server: python "'+(Join-Path $source 'packaging\test-release-server.py')+'" --root "'+$lab+'"')
Write-Host ('Open the test installation: "'+(Join-Path $install 'service.bat')+'"')
Write-Host 'Install a strategy/enable Telegram in that VM, set non-default modes, then type 111.'
Write-Host 'No service or task has been changed by this preparation script.'
