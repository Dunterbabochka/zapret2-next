"""Loopback-only GitHub release fixture; never publishes or accesses GitHub."""
import argparse
import hashlib
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    args = parser.parse_args()
    root = args.root

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            config = json.loads((root / "scenario.json").read_text(encoding="utf-8-sig"))
            with (root / "requests.txt").open("a", encoding="utf-8") as stream:
                stream.write(self.path + "\n")
            mode = config.get("mode", "ok")
            version = config.get("version", "9.9.1")
            archive = root / config.get("archive", "valid.zip")
            data = archive.read_bytes()
            name = f"zapret2-next-v{version}.zip"
            base = f"https://github.com/Dunterbabochka/zapret2-next/releases/download/v{version}/"
            if self.path == "/release":
                time.sleep(config.get("delay", 0))
                if mode == "unavailable":
                    self.send_error(503)
                    return
                if self.headers.get("If-None-Match") == '"fixture-v1"' and mode == "not-modified":
                    self.send_response(304)
                    self.end_headers()
                    return
                assets = [
                    {"name": name, "state": "uploaded", "size": len(data), "browser_download_url": base + name},
                    {"name": "release-sha256.txt", "state": "uploaded", "size": 100, "browser_download_url": base + "release-sha256.txt"},
                ]
                if mode == "missing-asset":
                    assets.pop()
                if mode == "foreign-asset":
                    assets[0]["browser_download_url"] = assets[0]["browser_download_url"].replace("Dunterbabochka", "another-owner")
                payload = json.dumps({"tag_name": "v" + version, "draft": mode == "draft", "prerelease": mode == "beta", "assets": assets}).encode()
                self.send_response(200)
                self.send_header("ETag", '"fixture-v1"')
            elif self.path == "/assets/release-sha256.txt":
                digest = "0" * 64 if mode == "bad-hash" else hashlib.sha256(data).hexdigest()
                payload = f"{digest}  {name}\r\n".encode()
                self.send_response(200)
            elif self.path.startswith("/assets/"):
                # Exercise a real redirect without changing the metadata URL.
                self.send_response(302)
                self.send_header("Location", "/archive")
                self.end_headers()
                return
            elif self.path == "/archive":
                self.send_response(200)
                if mode == "truncated":
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    self.wfile.write(data[:32])
                    self.close_connection = True
                    return
                payload = data
            else:
                self.send_error(404)
                return
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            try:
                self.wfile.write(payload)
            except (BrokenPipeError, ConnectionResetError):
                pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    (root / "port.txt").write_text(str(server.server_port), encoding="ascii")
    server.serve_forever()


if __name__ == "__main__":
    main()
