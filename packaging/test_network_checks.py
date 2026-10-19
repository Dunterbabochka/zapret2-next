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
