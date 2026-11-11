"""Real loopback transfers: HEAD succeeds while a DPI-sized POST can stall."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import subprocess
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_HEAD(self):
        self.send_response(200)
        self.end_headers()

    def do_POST(self):
        self.rfile.read(int(self.headers['Content-Length']))
        if self.path == '/freeze':
            time.sleep(4)
            return
        data = b'x' * (65536 if self.path == '/echo' else 0)
        self.send_response(200)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)


class NetworkChecksTests(unittest.TestCase):
    def test_summary_excludes_ping_and_marks_partial_failures(self):
        script = r'''
$ErrorActionPreference='Stop'
. './utils/network-checks.ps1'
$cases=@{
    pingOnly=@([pscustomobject]@{Test='PING';Success=$true;Status='OK'})
    webFailPingOk=@([pscustomobject]@{Test='HTTP1.1';Success=$false;Status='TIMEOUT'},[pscustomobject]@{Test='PING';Success=$true;Status='OK'})
    partial=@([pscustomobject]@{Test='HTTP1.1';Success=$true;Status='OK'},[pscustomobject]@{Test='TLS1.3';Success=$false;Status='TLS_ERROR'})
    unsupported=@([pscustomobject]@{Test='TLS1.3';Success=$null;Status='UNSUPPORTED'})
    webOkPingFail=@([pscustomobject]@{Test='HTTP1.1';Success=$true;Status='OK'},[pscustomobject]@{Test='PING';Success=$false;Status='FAIL'})
    startupFailure=@([pscustomobject]@{Test='START';Success=$false;Status='FAIL'})
}
$result=@{}
foreach ($name in $cases.Keys) {
    $summary=Get-ZapretTestSummary $cases[$name]
    $result[$name]=@{Summary=$summary;Color=Get-ZapretTestSummaryColor $summary}
}
$result | ConvertTo-Json -Depth 5 -Compress
'''
        result = subprocess.run(['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', script],
                                cwd=ROOT, capture_output=True, text=True, timeout=15,
                                creationflags=subprocess.CREATE_NO_WINDOW)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        cases = json.loads(result.stdout)
        for name, passed, failed, total, color in (
            ('pingOnly', 0, 0, 0, 'DarkGray'),
            ('webFailPingOk', 0, 1, 1, 'Red'),
            ('partial', 1, 1, 2, 'Yellow'),
            ('unsupported', 0, 0, 1, 'DarkGray'),
            ('webOkPingFail', 1, 0, 1, 'Green'),
            ('startupFailure', 0, 1, 1, 'Red'),
        ):
            with self.subTest(name=name):
                summary = cases[name]['Summary']
                self.assertEqual((summary['Passed'], summary['Failed'], summary['Total']),
                                 (passed, failed, total))
                self.assertEqual(cases[name]['Color'], color)
        self.assertEqual(cases['unsupported']['Summary']['Unsupported'], 1)
        self.assertEqual(cases['webFailPingOk']['Summary']['PingPassed'], 1)

    def test_head_success_does_not_hide_post_freeze(self):
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        server.daemon_threads = True
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        script = r'''
$ErrorActionPreference='Stop'
. './utils/network-checks.ps1'
$rows=@()
foreach ($path in @('echo','freeze','empty')) {
    foreach ($kind in @('standard','dpi')) {
        $target=[pscustomobject]@{Name=$path;Url=('http://127.0.0.1:PORT/'+$path);Category=$kind;PingTarget=$null}
        $result=Invoke-ZapretEndpointCheck $target 1 65536
        $rows+=[pscustomobject]@{Path=$path;Kind=$kind;Checks=$result.Checks}
    }
}
$rows | ConvertTo-Json -Depth 8 -Compress
'''.replace('PORT', str(server.server_port))
        try:
            result = subprocess.run(['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', script],
                                    cwd=ROOT, capture_output=True, text=True, timeout=30,
                                    creationflags=subprocess.CREATE_NO_WINDOW)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            rows = json.loads(result.stdout)
            for row in rows:
                checks = row['Checks']
                if row['Kind'] == 'standard':
                    self.assertTrue(all(c['Status'] == 'OK' for c in checks), row)
                elif row['Path'] == 'echo':
                    self.assertTrue(all(c['Success'] and c['UploadedBytes'] == 65536 and
                                        c['DownloadedBytes'] == 65536 for c in checks), row)
                elif row['Path'] == 'freeze':
                    self.assertTrue(all(c['Status'] == 'LIKELY_BLOCKED' and not c['Success'] for c in checks), row)
                else:
                    self.assertTrue(all(c['Status'] == 'INCOMPLETE' and not c['Success'] for c in checks), row)
        finally:
            server.shutdown()
            server.server_close()


if __name__ == '__main__':
    unittest.main()
