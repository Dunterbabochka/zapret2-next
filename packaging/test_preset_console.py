"""Run the real preset scan/pause in hidden consoles with isolated OS/network seams."""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('release_console', ROOT / 'packaging/test-release-console.py')
console_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(console_module)
Console = console_module.Console


class PresetConsoleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = ROOT / 'runtime' / ('preset-console-tests-' + uuid.uuid4().hex)
        shutil.copytree(ROOT / 'utils', cls.fixture / 'utils')
        shutil.copytree(ROOT / 'presets', cls.fixture / 'presets')
        (cls.fixture / 'bin').mkdir()
        (cls.fixture / 'bin/winws2.exe').write_text('fixture; never executed', encoding='ascii')
        source = (ROOT / 'utils/test-presets.ps1').read_text(encoding='utf-8-sig')
        check = 'if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {'
        assert source.count(check) == 1, 'Administrator boundary changed'
        (cls.fixture / 'utils/test-presets.ps1').write_text(source.replace(check, 'if ($env:PRESET_TEST_ADMIN_FAIL) {'),
                                                         encoding='utf-8-sig')
        (cls.fixture / 'utils/render-config.ps1').write_text(
            'param($Preset,$Output,$IPSetMode,[switch]$DryRun)\n'
            '[IO.File]::WriteAllText($Output,"# isolated fixture")\n', encoding='utf-8-sig')
        (cls.fixture / 'utils/invoke-winws.ps1').write_text(
            'param($Config,$LogPrefix,$StartupWaitSeconds,[switch]$Validate)\nexit 0\n', encoding='utf-8-sig')
        # Workers source this file in separate runspaces. Only the HTTP/ICMP
        # boundary is substituted; summary and ranking code remain production.
        with (cls.fixture / 'utils/network-checks.ps1').open('a', encoding='utf-8') as stream:
            stream.write('''
function Invoke-ZapretEndpointCheck($Target,$TimeoutSeconds,$RangeBytes) {
    $ok=-not [bool]$env:PRESET_TEST_WEB_FAIL
    [pscustomobject]@{
        Name=$Target.Name;Url=$Target.Url;PingStatus='1ms';PingSuccess=$true
        Checks=@([pscustomobject]@{Name='HTTP1.1';Status=$(if ($ok) {'OK'} else {'TIMEOUT'});Success=$ok;Detail='fixture';UploadedBytes=0;DownloadedBytes=0;DurationMs=1})
    }
}
''')
        cls.wrapper = cls.fixture / 'scan.ps1'
        cls.wrapper.write_text(r'''
param([string]$Scenario='success',[switch]$NonInteractive)
$ErrorActionPreference='Stop'
$env:ZAPRET_LOG_DISABLED='1'
$env:PRESET_TEST_ADMIN_FAIL=if ($Scenario -eq 'admin') {'1'} else {''}
$env:PRESET_TEST_WEB_FAIL=if ($Scenario -eq 'web-fail') {'1'} else {''}
function Get-Service { param($Name,$ErrorAction) }
function Get-CimInstance { param($ClassName,$Filter,$ErrorAction) }
function Get-Process { param($Name,$Id,$ErrorAction); if ($Id) { Microsoft.PowerShell.Management\Get-Process -Id $Id -ErrorAction $ErrorAction } }
function Stop-Service { throw 'Live service stop reached' }
function Start-Service { throw 'Live service start reached' }
function Stop-Process { param([Parameter(ValueFromPipeline=$true)]$InputObject,[switch]$Force); process { if ($null -ne $InputObject) { throw 'Live process stop reached' } } }
function Start-Process { throw 'Live process start reached' }
function Start-Sleep { param($Milliseconds,$Seconds) }
$options=@{Suite='standard';NonInteractive=$NonInteractive}
if ($Scenario -ne 'selection') { $options.Preset=if ($Scenario -eq 'throw') {'NO SUCH PRESET'} else {'ALT'} }
& (Join-Path $PSScriptRoot 'utils/test-presets.ps1') @options
exit $LASTEXITCODE
''', encoding='utf-8-sig')

    def command(self, scenario, noninteractive=False):
        command = ['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass',
                   '-File', str(self.wrapper), '-Scenario', scenario]
        if noninteractive:
            command.append('-NonInteractive')
        return command

    def test_key_exits_after_completion_and_failures(self):
        for scenario, expected_code, expected_text in (
            ('success', 0, 'Top preset by HTTP/TLS checks: ALT1 (ALT)'),
            ('web-fail', 2, 'No preset passed HTTP/TLS checks'),
            ('admin', 1, '[ERROR] Run tests as Administrator.'),
            ('throw', 1, '[ERROR] No matching presets found.'),
            ('selection', 0, 'Top preset by HTTP/TLS checks: ALT8'),
        ):
            with self.subTest(scenario=scenario):
                # AttachConsole/FreeConsole must not invalidate the unittest
                # runner's standard handles or affect later test modules.
                result = subprocess.run([sys.executable, __file__, '--console-probe', str(self.wrapper),
                                         scenario, str(expected_code), expected_text],
                                        stdin=subprocess.DEVNULL, capture_output=True, timeout=30,
                                        creationflags=subprocess.CREATE_NO_WINDOW)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_noninteractive_never_waits_for_a_key(self):
        for scenario, expected_code in (('success', 0), ('web-fail', 2), ('admin', 1), ('throw', 1)):
            with self.subTest(scenario=scenario):
                result = subprocess.run(self.command(scenario, noninteractive=True), cwd=ROOT,
                                        env={**os.environ, 'ZAPRET_LOG_DISABLED': '1'},
                                        stdin=subprocess.DEVNULL, capture_output=True, timeout=20,
                                        creationflags=subprocess.CREATE_NO_WINDOW)
                self.assertEqual(result.returncode, expected_code, result.stdout + result.stderr)
                self.assertNotIn(b'Press any key to close', result.stdout + result.stderr)


def check_console(wrapper, scenario, expected_code, expected_text):
    console = Console(['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass',
                       '-File', wrapper, '-Scenario', scenario])
    try:
        if scenario == 'selection':
            console.wait_text('Select 1-2', timeout=10)
            console.type('2\r')
            console.wait_text('Numbers/ranges', timeout=10)
            assert '[1] ALT1 (ALT)' in console.text()
            assert '[8] ALT8' in console.text()
            console.type('8\r')
        console.wait_text('Press any key to close...', timeout=20)
        screen = console.text()
        assert expected_text in screen, screen.rstrip()[-5000:]
        assert screen.count('Press any key to close...') == 1
        assert console.process.poll() is None, 'Console exited before the key'
        assert 'PS C:\\' not in screen
        console.type('x')
        assert console.process.wait(timeout=5) == expected_code
        if scenario == 'success':
            assert 'HTTP HEAD reachability only' in screen
        if scenario == 'web-fail':
            assert 'Top preset by HTTP/TLS checks:' not in screen
    finally:
        console.close()


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--console-probe':
        check_console(sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5])
    else:
        unittest.main()
