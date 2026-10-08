"""Headless, loopback-only entry point for the bundled Telegram bridge."""
from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
from pathlib import Path
import re
import signal
import sys
import time
import traceback
import uuid
from contextlib import suppress

if not getattr(sys, "frozen", False):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "third_party" / "tg-ws-proxy"))

from proxy import __version__ as upstream_version
from proxy.config import proxy_config, CFPROXY_DEFAULT_DOMAINS
from proxy.raw_websocket import RawWebSocket, WsHandshakeError
from proxy.utils import ws_domains, DomainCensorFilter
from proxy import tg_ws_proxy
from utils.logging_setup import build_log_handler

MODULE_VERSION = "1"


def load_config(path: Path) -> dict:
    with path.open(encoding="utf-8-sig") as stream:
        cfg = json.load(stream)
    if not isinstance(cfg, dict) or type(cfg.get("version")) is not int or cfg["version"] != 1:
        raise ValueError("Unsupported Telegram config version; expected 1")
    if cfg.get("host") != "127.0.0.1":
        raise ValueError("Telegram proxy must listen on 127.0.0.1")
    port = cfg.get("port")
    if type(port) is not int or not 1024 <= port <= 65535:
        raise ValueError("Telegram port must be an integer between 1024 and 65535")
    if not isinstance(cfg.get("secret"), str) or not re.fullmatch(r"[a-fA-F0-9]{32}", cfg["secret"]):
        raise ValueError("Telegram secret must contain 32 hexadecimal characters")
    if type(cfg.get("cfproxy", True)) is not bool:
        raise ValueError("Telegram cfproxy must be a boolean")
    return {"version": 1, "host": "127.0.0.1", "port": port,
            "secret": cfg["secret"].lower(), "cfproxy": cfg.get("cfproxy", True)}


def configure_proxy(cfg: dict) -> None:
    proxy_config.host = cfg["host"]
    proxy_config.port = cfg["port"]
    proxy_config.secret = cfg["secret"]
    proxy_config.fallback_cfproxy = cfg["cfproxy"]
    proxy_config.cfproxy_h2_media = cfg["cfproxy"]


class SecretFilter(logging.Filter):
    def __init__(self, secret: str):
        super().__init__()
        self.secret = secret

    def redact(self, msg: str) -> str:
        msg = re.sub(re.escape(self.secret), "[redacted]", msg, flags=re.IGNORECASE)
        return re.sub(r"(?i)(secret=)[^\s&]+", r"\1[redacted]", msg)

    def filter(self, record: logging.LogRecord) -> bool:
        # The upstream banner and exceptions can contain proxy links. Never put
        # a reusable credential in logs or diagnostic archives.
        msg = self.redact(record.getMessage())
        record.msg, record.args = msg, ()
        if record.exc_info:
            record.exc_text = self.redact("".join(traceback.format_exception(*record.exc_info)))
            record.exc_info = None
        elif record.exc_text:
            record.exc_text = self.redact(record.exc_text)
        if record.stack_info:
            record.stack_info = self.redact(record.stack_info)
        return True


def configure_logging(config_path: Path, secret: str) -> None:
    handler = build_log_handler(str(config_path.parent / "proxy.log"), log_max_mb=2, backups=2)
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    handler.addFilter(DomainCensorFilter())
    handler.addFilter(SecretFilter(secret))
    root = logging.getLogger()
    root.handlers.clear()
    root.addHandler(handler)
    root.setLevel(logging.INFO)
    for name in ("httpx", "httpcore", "asyncio"):
        logging.getLogger(name).setLevel(logging.WARNING)


class InstanceLock:
    """An OS-held byte lock; crashes release it without leaving a stale PID."""
    def __init__(self, path: Path):
        self.path = path
        self.stream = None

    def __enter__(self):
        import msvcrt
        self.stream = self.path.open("a+b")
        self.stream.seek(0)
        if not self.stream.read(1):
            self.stream.write(b"0")
            self.stream.flush()
        self.stream.seek(0)
        try:
            msvcrt.locking(self.stream.fileno(), msvcrt.LK_NBLCK, 1)
        except OSError:
            self.stream.close()
            raise RuntimeError("Telegram proxy from this folder is already running") from None
        return self

    def __exit__(self, *_):
        import msvcrt
        self.stream.seek(0)
        msvcrt.locking(self.stream.fileno(), msvcrt.LK_UNLCK, 1)
        self.stream.close()


async def serve() -> None:
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for signum in (signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, lambda *_: loop.call_soon_threadsafe(stop.set))
    # Direct mode must also avoid fetching the upstream CF domain pool.
    if not proxy_config.fallback_cfproxy:
        tg_ws_proxy.start_cfproxy_domain_refresh = lambda: None
    await tg_ws_proxy._run(stop)


async def probe_ws(dc: int, media: bool) -> dict:
    started = time.monotonic()
    error = "unavailable"
    for domain in ws_domains(dc, media):
        for fronted in (False, True):
            try:
                ws = await RawWebSocket.connect(
                    proxy_config.dc_redirects[dc], domain, timeout=4,
                    sni="sprinthost.ru" if fronted else None)
                with suppress(OSError, asyncio.TimeoutError):
                    await asyncio.wait_for(ws.close(), 1)
                return {"dc": dc, "media": media, "available": True,
                        "route": "direct-fronting" if fronted else "direct",
                        "elapsed_ms": round((time.monotonic() - started) * 1000)}
            except (OSError, ValueError, asyncio.TimeoutError, WsHandshakeError) as exc:
                error = type(exc).__name__
    return {"dc": dc, "media": media, "available": False, "error": error}


async def diagnose(cfg: dict) -> dict:
    configure_proxy(cfg)
    async def bounded_probe(dc, media):
        try:
            return await asyncio.wait_for(probe_ws(dc, media), timeout=18)
        except asyncio.TimeoutError:
            return {"dc": dc, "media": media, "available": False, "error": "timeout"}
    direct = await asyncio.gather(*(bounded_probe(dc, media)
                                  for dc in sorted(proxy_config.dc_redirects)
                                  for media in (False, True)))
    cf = {"enabled": cfg["cfproxy"], "available": None}
    if cfg["cfproxy"]:
        # Probe a small bounded sample. The running bridge independently refreshes
        # the full CF pool; a failed sample is not a verdict on all fallback routes.
        async def probe_cf(base):
            domain = f"kws2.{base}"
            try:
                ws = await asyncio.wait_for(RawWebSocket.connect(domain, domain, timeout=4), 5)
                with suppress(OSError, asyncio.TimeoutError):
                    await asyncio.wait_for(ws.close(), 1)
                return True
            except (OSError, ValueError, asyncio.TimeoutError, WsHandshakeError):
                return False
        cf["available"] = any(await asyncio.gather(*(probe_cf(base) for base in CFPROXY_DEFAULT_DOMAINS[:3])))
        cf["sample_only"] = True
    return {"module_version": MODULE_VERSION, "upstream_version": upstream_version,
            "host": cfg["host"], "port": cfg["port"], "direct_ws": direct,
            "cfproxy": cf, "scope": "WebSocket endpoint handshake only; verify messages, media and calls in Telegram"}


def write_report(path: Path, report: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    pending = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    try:
        pending.write_text(json.dumps(report, ensure_ascii=True, indent=2), encoding="utf-8")
        os.replace(pending, path)
    finally:
        pending.unlink(missing_ok=True)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Zapret 2 NEXT Telegram bridge")
    parser.add_argument("--config", type=Path)
    parser.add_argument("--diagnose", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    if args.self_test:
        if not args.output:
            parser.error("--self-test requires --output")
        # Frozen-build smoke test verifies crypto and HTTP/2 are actually bundled.
        from proxy._aes import Cipher, algorithms, modes
        from h2.connection import H2Connection
        payload = b"telegram-build-smoke"
        ciphertext = Cipher(algorithms.AES(b"a" * 32), modes.CTR(b"b" * 16)).encryptor().update(payload)
        restored = Cipher(algorithms.AES(b"a" * 32), modes.CTR(b"b" * 16)).encryptor().update(ciphertext)
        H2Connection().initiate_connection()
        if restored != payload:
            raise RuntimeError("Bundled AES roundtrip failed")
        write_report(args.output, {"ok": True, "module_version": MODULE_VERSION,
                                   "upstream_version": upstream_version})
        return 0
    if not args.config or (args.diagnose and not args.output):
        parser.error("--config is required; diagnostics also require --output")
    config_path = args.config.resolve()
    try:
        cfg = load_config(config_path)
        if args.diagnose:
            write_report(args.output.resolve(), asyncio.run(diagnose(cfg)))
            return 0
        configure_proxy(cfg)
        configure_logging(config_path, cfg["secret"])
        with InstanceLock(config_path.parent / "proxy.lock"):
            (config_path.parent / "startup-error.json").unlink(missing_ok=True)
            asyncio.run(serve())
        return 0
    except Exception as exc:
        # Errors are actionable even in a windowless scheduled task. No config
        # contents/credentials are written to this report.
        if args.diagnose and args.output:
            write_report(args.output.resolve(), {"ok": False, "error": type(exc).__name__, "message": str(exc)})
        elif config_path.parent.is_dir():
            write_report(config_path.parent / "startup-error.json",
                         {"error": type(exc).__name__, "message": str(exc)})
        logging.getLogger(__name__).exception("Telegram bridge stopped")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
