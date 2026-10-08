"""Transient frozen-runtime listener check; installs no task or Telegram settings."""
from __future__ import annotations

import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    runtime = ROOT / "runtime" / "telegram-build" / "listener-smoke"
    runtime.mkdir(parents=True, exist_ok=True)
    with socket.socket() as candidate:
        candidate.bind(("127.0.0.1", 0))
        port = candidate.getsockname()[1]
    secret = secrets.token_hex(16)
    config = runtime / "config.json"
    config.write_text(json.dumps({"version": 1, "host": "127.0.0.1", "port": port,
                                  "secret": secret, "cfproxy": False}), encoding="utf-8")
    env = os.environ.copy()
    env["TEMP"] = env["TMP"] = str(runtime)
    exe = ROOT / "bin" / "telegram" / "zapret-telegram.exe"
    process = subprocess.Popen([str(exe), "--config", str(config)], env=env,
                               creationflags=subprocess.CREATE_NO_WINDOW)
    try:
        deadline = time.monotonic() + 30
        while True:
            if process.poll() is not None:
                raise RuntimeError(f"Frozen listener exited unexpectedly ({process.returncode})")
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=.5) as client:
                    # No real account traffic: an invalid init is rejected locally.
                    client.sendall(b"\0" * 64)
                    client.shutdown(socket.SHUT_WR)
                    client.settimeout(3)
                    if client.recv(1):
                        raise RuntimeError("Invalid MTProto credentials were accepted")
                break
            except (ConnectionRefusedError, TimeoutError):
                if time.monotonic() > deadline:
                    raise RuntimeError("Frozen listener startup timeout") from None
                time.sleep(.1)
        log = (runtime / "proxy.log").read_text(encoding="utf-8")
        if secret in log or "tg://proxy?" not in log or "[redacted]" not in log:
            raise RuntimeError("Frozen listener credential redaction failed")
        if (runtime / "startup-error.json").exists():
            raise RuntimeError("Frozen listener reported a startup error")
    finally:
        # PyInstaller onefile uses a bootloader + child; terminate only the tree
        # created above. Never terminate unrelated processes by image name.
        if process.poll() is None:
            subprocess.run(["taskkill.exe", "/PID", str(process.pid), "/T", "/F"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
        process.wait(timeout=10)
        config.unlink(missing_ok=True)
    report = {"ok": True, "checks": ["frozen listener startup", "invalid MTProto rejected",
                                      "credential redaction", "own process tree stopped"]}
    (runtime / "result.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    print("Frozen Telegram listener smoke passed; no task or Telegram settings changed.")


if __name__ == "__main__":
    main()
