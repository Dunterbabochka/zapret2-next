"""Offline launcher and encrypted transport tests; no Telegram access required."""
from __future__ import annotations

import asyncio
from contextlib import contextmanager
import hashlib
import json
import logging
from pathlib import Path
import struct
import sys
import shutil
import unittest
import uuid
from unittest.mock import AsyncMock, call, patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import launcher
from proxy._aes import Cipher, algorithms, modes
from proxy import tg_ws_proxy
from proxy.utils import (
    PROTO_TAG_ABRIDGED, PROTO_TAG_INTERMEDIATE, PROTO_TAG_SECURE,
)


SECRET = "0123456789abcdef0123456789abcdef"
TEST_TEMP_ROOT = Path(__file__).resolve().parents[1] / "runtime"


@contextmanager
def test_directory():
    # Python 3.14's Windows TemporaryDirectory applies an owner-only ACL that
    # excludes restricted runner tokens. Use inherited workspace permissions.
    root = TEST_TEMP_ROOT.resolve()
    root.mkdir(exist_ok=True)
    path = root / ("telegram-test-" + uuid.uuid4().hex)
    path.mkdir()
    try:
        yield path
    finally:
        if path.resolve().parent != root:
            raise RuntimeError("Refusing cleanup outside the test workspace")
        shutil.rmtree(path)


def config(**changes):
    result = {"version": 1, "host": "127.0.0.1", "port": 1443,
              "secret": SECRET, "cfproxy": True}
    result.update(changes)
    return result


class ConfigTests(unittest.TestCase):
    def load(self, value, *, bom=False):
        with test_directory() as directory:
            path = Path(directory) / "config.json"
            path.write_text(json.dumps(value), encoding="utf-8-sig" if bom else "utf-8")
            return launcher.load_config(path)

    def test_load_accepts_powershell_bom_and_normalizes_secret(self):
        self.assertEqual(self.load(config(secret=SECRET.upper()), bom=True), config())

    def test_port_boundaries_and_default_fallback(self):
        for port in (1024, 65535):
            with self.subTest(port=port):
                value = config(port=port)
                del value["cfproxy"]
                self.assertEqual(self.load(value), config(port=port))
        self.assertFalse(self.load(config(cfproxy=False))["cfproxy"])

    def test_rejects_non_loopback_listener_and_invalid_types(self):
        invalid = {
            "version": (None, 0, 2, True, 1.0, "1"),
            "host": (None, "0.0.0.0", "localhost", "::1", "127.0.0.2"),
            "port": (None, True, "1443", 1443.0, 1023, 65536),
            "secret": (None, 123, "a" * 31, "a" * 33, "g" * 32,
                       "dd" + SECRET, SECRET + "\n"),
            "cfproxy": (None, 0, 1, "true"),
        }
        for key, values in invalid.items():
            for value in values:
                with self.subTest(key=key, value=value):
                    with self.assertRaises(ValueError):
                        self.load(config(**{key: value}))
        for value in ([], None, "invalid"):
            with self.subTest(root=value), self.assertRaises(ValueError):
                self.load(value)

    def test_rejects_missing_required_values(self):
        for field in ("version", "host", "port", "secret"):
            with self.subTest(field=field), self.assertRaises(ValueError):
                value = config()
                del value[field]
                self.load(value)

    def test_secret_filter_removes_credentials_after_formatting(self):
        record = logging.LogRecord(
            "telegram-test", logging.INFO, "test", 1,
            "Secret: %s; tg://proxy?secret=dd%s&port=1443; secret=another-token",
            (SECRET.upper(), SECRET), None,
        )
        self.assertTrue(launcher.SecretFilter(SECRET).filter(record))
        text = record.getMessage()
        self.assertNotIn(SECRET, text.lower())
        self.assertNotIn("another-token", text)
        self.assertEqual(text.count("[redacted]"), 3)
        self.assertIn("&port=1443", text)

    def test_secret_filter_redacts_tracebacks_cached_exceptions_and_stack_info(self):
        for cached in (False, True):
            with self.subTest(cached=cached):
                try:
                    raise ValueError("Connection failed: secret=" + SECRET.upper())
                except ValueError:
                    record = logging.LogRecord(
                        "telegram-test", logging.ERROR, "test", 1,
                        "Proxy %s failed", (SECRET,), sys.exc_info(),
                        sinfo="Stack info contains " + SECRET,
                    )
                if cached:
                    record.exc_text = logging.Formatter().formatException(record.exc_info)
                    record.exc_info = None
                self.assertTrue(launcher.SecretFilter(SECRET).filter(record))
                text = logging.Formatter("%(message)s").format(record)
                self.assertNotIn(SECRET, text.lower())
                self.assertIn("Traceback", text)
                self.assertIn("ValueError", text)
                self.assertIn("Stack info contains [redacted]", text)
                self.assertGreaterEqual(text.count("[redacted]"), 3)

    def test_report_replacement_failure_preserves_original_and_cleans_temp(self):
        with test_directory() as directory:
            output = directory / "report.json"
            original = json.dumps({"previous": True})
            output.write_text(original, encoding="utf-8")
            with patch.object(launcher.os, "replace", side_effect=PermissionError("Report is busy")) as replace:
                with self.assertRaises(PermissionError):
                    launcher.write_report(output, {"new": True})
            self.assertEqual(output.read_text(encoding="utf-8"), original)
            source, destination = replace.call_args.args
            self.assertEqual(destination, output)
            self.assertFalse(source.exists())
            self.assertEqual(list(directory.iterdir()), [output])
            launcher.write_report(output, {"new": True})
            self.assertEqual(json.loads(output.read_text(encoding="utf-8")), {"new": True})
            self.assertEqual(list(directory.iterdir()), [output])

    def test_successful_start_clears_stale_startup_error(self):
        with test_directory() as directory:
            config_path = directory / "config.json"
            config_path.write_text(json.dumps(config()), encoding="utf-8")
            error_path = directory / "startup-error.json"
            error_path.write_text(json.dumps({"error": "previous failure"}), encoding="utf-8")
            serve = AsyncMock()
            with patch.object(launcher, "configure_logging"), \
                    patch.object(launcher, "configure_proxy"), \
                    patch.object(launcher, "serve", serve):
                self.assertEqual(launcher.main(["--config", str(config_path)]), 0)
            serve.assert_awaited_once()
            self.assertFalse(error_path.exists())

    def test_self_test_reports_bundled_crypto_and_h2(self):
        with test_directory() as directory:
            output = Path(directory) / "nested" / "self-test.json"
            self.assertEqual(launcher.main(["--self-test", "--output", str(output)]), 0)
            report = json.loads(output.read_text(encoding="utf-8"))
            self.assertTrue(report["ok"])
            self.assertEqual(report["upstream_version"], launcher.upstream_version)
            self.assertFalse(output.with_suffix(".json.tmp").exists())


class DiagnosticTests(unittest.IsolatedAsyncioTestCase):
    async def test_direct_probe_closes_connection_and_tries_sni_fronting(self):
        ws = AsyncMock()
        connect = AsyncMock(side_effect=[OSError("blocked"), ws])
        with patch.object(launcher.RawWebSocket, "connect", connect), \
                patch.object(launcher.proxy_config, "dc_redirects", {2: "192.0.2.2"}):
            report = await launcher.probe_ws(2, False)
        self.assertTrue(report["available"])
        self.assertEqual(report["route"], "direct-fronting")
        self.assertGreaterEqual(report["elapsed_ms"], 0)
        self.assertEqual(connect.await_args_list, [
            call("192.0.2.2", "kws2.web.telegram.org", timeout=4, sni=None),
            call("192.0.2.2", "kws2.web.telegram.org", timeout=4, sni="sprinthost.ru"),
        ])
        ws.close.assert_awaited_once()

    async def test_media_probe_exhausts_endpoints_and_reports_error_class(self):
        connect = AsyncMock(side_effect=[OSError(), launcher.WsHandshakeError(403, "HTTP/1.1 403 Forbidden"),
                                        asyncio.TimeoutError(), OSError()])
        with patch.object(launcher.RawWebSocket, "connect", connect), \
                patch.object(launcher.proxy_config, "dc_redirects", {4: "192.0.2.4"}):
            report = await launcher.probe_ws(4, True)
        self.assertEqual(report, {"dc": 4, "media": True,
                                  "available": False, "error": "OSError"})
        self.assertEqual([entry.args[1] for entry in connect.await_args_list], [
            "kws4-1.web.telegram.org", "kws4-1.web.telegram.org",
            "kws4.web.telegram.org", "kws4.web.telegram.org",
        ])

    async def test_successful_endpoint_remains_available_when_close_times_out(self):
        ws = AsyncMock()
        ws.close.side_effect = asyncio.TimeoutError()
        connect = AsyncMock(return_value=ws)
        with patch.object(launcher.RawWebSocket, "connect", connect), \
                patch.object(launcher.proxy_config, "dc_redirects", {2: "192.0.2.2"}):
            report = await launcher.probe_ws(2, False)
        self.assertTrue(report["available"])
        self.assertEqual(report["route"], "direct")
        connect.assert_awaited_once()
        ws.close.assert_awaited_once()

    async def test_direct_mode_probes_all_dc_media_pairs_without_cf_requests(self):
        async def probe(dc, media):
            return {"dc": dc, "media": media, "available": dc == 2}

        probe_mock = AsyncMock(side_effect=probe)
        connect = AsyncMock(side_effect=AssertionError("CF access in direct mode"))
        cfg = config(cfproxy=False)
        with patch.multiple(launcher.proxy_config, dc_redirects={4: "192.0.2.4", 2: "192.0.2.2"},
                            host="127.0.0.1", port=1443, secret=SECRET,
                            fallback_cfproxy=True, cfproxy_h2_media=True), \
                patch.object(launcher, "probe_ws", probe_mock), \
                patch.object(launcher.RawWebSocket, "connect", connect):
            report = await launcher.diagnose(cfg)
            self.assertFalse(launcher.proxy_config.fallback_cfproxy)
            self.assertFalse(launcher.proxy_config.h2_enabled)
        self.assertEqual(probe_mock.await_args_list, [
            call(2, False), call(2, True), call(4, False), call(4, True)])
        self.assertEqual(report["cfproxy"], {"enabled": False, "available": None})
        connect.assert_not_awaited()
        self.assertNotIn(SECRET, json.dumps(report))
        self.assertNotIn("secret", report)

    async def test_diagnostics_bound_direct_timeout_and_sample_fallback(self):
        async def probe(dc, media):
            if media:
                raise asyncio.TimeoutError()
            return {"dc": dc, "media": media, "available": False, "error": "OSError"}

        ws = AsyncMock()
        connect = AsyncMock(side_effect=[OSError(), ws,
                                        launcher.WsHandshakeError(302, "HTTP/1.1 302 Found")])
        with patch.multiple(launcher.proxy_config, dc_redirects={2: "192.0.2.2"},
                            host="127.0.0.1", port=1443, secret=SECRET,
                            fallback_cfproxy=False, cfproxy_h2_media=False), \
                patch.object(launcher, "probe_ws", AsyncMock(side_effect=probe)), \
                patch.object(launcher, "CFPROXY_DEFAULT_DOMAINS", [
                    "first.example", "second.example", "third.example", "unused.example"]), \
                patch.object(launcher.RawWebSocket, "connect", connect):
            report = await launcher.diagnose(config())
        self.assertEqual(report["direct_ws"][1], {
            "dc": 2, "media": True, "available": False, "error": "timeout"})
        self.assertEqual(report["cfproxy"], {
            "enabled": True, "available": True, "sample_only": True})
        self.assertEqual(connect.await_args_list, [
            call("kws2.first.example", "kws2.first.example", timeout=4),
            call("kws2.second.example", "kws2.second.example", timeout=4),
            call("kws2.third.example", "kws2.third.example", timeout=4),
        ])
        ws.close.assert_awaited_once()
        self.assertNotIn(SECRET, json.dumps(report))


def ctr(key, iv):
    return Cipher(algorithms.AES(key), modes.CTR(iv)).encryptor()


def client_init(secret, proto_tag, dc):
    """Independently construct the MTProxy client's 64-byte obfuscation init."""
    plain = bytearray(range(1, 65))
    plain[56:64] = proto_tag + struct.pack("<h", dc) + b"\x12\x34"
    prekey_iv = bytes(plain[8:56])
    encryptor = ctr(hashlib.sha256(prekey_iv[:32] + secret).digest(), prekey_iv[32:])
    encrypted = encryptor.update(bytes(plain))
    # The raw prekey and IV remain visible; only the last 8 bytes are encrypted.
    handshake = bytes(plain[:56]) + encrypted[56:64]
    reverse = prekey_iv[::-1]
    decryptor = ctr(hashlib.sha256(reverse[:32] + secret).digest(), reverse[32:])
    return handshake, encryptor, decryptor


def transport_packet(proto_tag, payload):
    if proto_tag == PROTO_TAG_ABRIDGED:
        words = len(payload) // 4
        if len(payload) % 4:
            raise ValueError("Abridged payload must be a multiple of 4 bytes")
        header = bytes([words]) if words < 127 else b"\x7f" + words.to_bytes(3, "little")
    else:
        header = struct.pack("<I", len(payload))
    return header + payload


class FakeTelegramWebSocket:
    """A Telegram-side obfuscated peer, independent of the proxy crypto helpers."""
    def __init__(self, response_packets, expected_count):
        self.response_packets = response_packets
        self.expected_count = expected_count
        self.received_packets = []
        self.received_ciphertext = []
        self.relay_init = None
        self.proto_tag = None
        self.dc = None
        self.closed = False
        self.queue = asyncio.Queue()

    async def send(self, frame):
        if self.relay_init is None:
            self.relay_init = frame
            self.incoming = ctr(frame[8:40], frame[40:56])
            init_plain = self.incoming.update(frame)
            self.proto_tag = init_plain[56:60]
            self.dc = struct.unpack("<h", init_plain[60:62])[0]
            reverse = frame[8:56][::-1]
            self.outgoing = ctr(reverse[:32], reverse[32:])
            return
        self.received_ciphertext.append(frame)
        self.received_packets.append(self.incoming.update(frame))
        if len(self.received_packets) == self.expected_count:
            ciphertext = self.outgoing.update(b"".join(self.response_packets))
            # Deliberately fragment upstream frames across transport headers.
            for fragment in (ciphertext[:1], ciphertext[1:7], ciphertext[7:]):
                await self.queue.put(fragment)

    async def send_batch(self, frames):
        for frame in frames:
            await self.send(frame)

    async def recv(self):
        return await self.queue.get()

    async def close(self):
        self.closed = True


class EncryptedProtocolTests(unittest.IsolatedAsyncioTestCase):
    async def roundtrip(self, proto_tag, dc):
        secret = bytes.fromhex(SECRET)
        init, client_encryptor, client_decryptor = client_init(secret, proto_tag, dc)
        requests = [transport_packet(proto_tag, b"MTProto-test"),
                    transport_packet(proto_tag, bytes(range(256)) * 2)]
        responses = [transport_packet(proto_tag, b"reply-packet-one"),
                     transport_packet(proto_tag, bytes(range(24)))]
        peer = FakeTelegramWebSocket(responses, len(requests))
        get = AsyncMock(return_value=peer)
        fallback = AsyncMock(side_effect=AssertionError("Unexpected network fallback"))
        handlers = []

        def accepted(reader, writer):
            handlers.append(asyncio.create_task(tg_ws_proxy._handle_client(reader, writer, secret)))

        writer = None
        with patch.object(tg_ws_proxy.ws_pool, "get", get), \
                patch.object(tg_ws_proxy, "do_fallback", fallback), \
                patch.multiple(launcher.proxy_config, fake_tls_domain="", proxy_protocol=False,
                               force_test_dc=False):
            server = await asyncio.start_server(accepted, "127.0.0.1", 0)
            try:
                port = server.sockets[0].getsockname()[1]
                reader, writer = await asyncio.open_connection("127.0.0.1", port)
                client_ciphertext = client_encryptor.update(b"".join(requests))
                # Exercise a fragmented init and incomplete packet header, then
                # coalesce the remaining packet bytes into one client write.
                for fragment in (init[:1], init[1:31], init[31:] + client_ciphertext[:2],
                                 client_ciphertext[2:]):
                    writer.write(fragment)
                    await writer.drain()
                    await asyncio.sleep(0)
                response_ciphertext = await asyncio.wait_for(
                    reader.readexactly(sum(map(len, responses))), timeout=3)
                self.assertEqual(client_decryptor.update(response_ciphertext), b"".join(responses))
                self.assertEqual(peer.received_packets, requests)
                self.assertNotEqual(b"".join(peer.received_ciphertext), client_ciphertext)
                self.assertEqual(len(peer.relay_init), 64)
                self.assertEqual(peer.proto_tag, proto_tag)
                relay_dc = abs(dc) - 10000 if abs(dc) >= 10000 else abs(dc)
                self.assertEqual(peer.dc, -relay_dc if dc < 0 else relay_dc)
                get.assert_awaited_once_with(relay_dc, dc < 0, is_test_dc=abs(dc) >= 10000)
                fallback.assert_not_awaited()
            finally:
                if writer is not None:
                    writer.close()
                    await writer.wait_closed()
                server.close()
                await server.wait_closed()
                for task in handlers:
                    try:
                        await asyncio.wait_for(task, timeout=3)
                    finally:
                        if not task.done():
                            task.cancel()
                await asyncio.gather(*handlers, return_exceptions=True)
        self.assertTrue(peer.closed)

    async def test_encrypted_padded_intermediate_roundtrip(self):
        await self.roundtrip(PROTO_TAG_SECURE, 2)

    async def test_encrypted_media_intermediate_roundtrip(self):
        await self.roundtrip(PROTO_TAG_INTERMEDIATE, -4)

    async def test_encrypted_abridged_test_dc_roundtrip_and_long_header(self):
        await self.roundtrip(PROTO_TAG_ABRIDGED, 10002)

    async def test_wrong_secret_has_no_upstream_session_and_closes_after_eof(self):
        secret = bytes.fromhex(SECRET)
        wrong_init, _, _ = client_init(b"\xff" * 16, PROTO_TAG_SECURE, 2)
        get = AsyncMock(side_effect=AssertionError("Bad secret reached upstream"))
        fallback = AsyncMock(side_effect=AssertionError("Bad secret reached fallback"))
        handlers = []

        def accepted(reader, writer):
            handlers.append(asyncio.create_task(tg_ws_proxy._handle_client(reader, writer, secret)))

        writer = None
        with patch.object(tg_ws_proxy.ws_pool, "get", get), \
                patch.object(tg_ws_proxy, "do_fallback", fallback), \
                patch.multiple(launcher.proxy_config, fake_tls_domain="", proxy_protocol=False):
            server = await asyncio.start_server(accepted, "127.0.0.1", 0)
            try:
                reader, writer = await asyncio.open_connection(
                    "127.0.0.1", server.sockets[0].getsockname()[1])
                writer.write(wrong_init + b"invalid-encrypted-payload")
                await writer.drain()
                # Upstream intentionally drains unauthenticated input until EOF.
                writer.write_eof()
                self.assertEqual(await asyncio.wait_for(reader.read(1), 3), b"")
                get.assert_not_awaited()
                fallback.assert_not_awaited()
            finally:
                if writer is not None:
                    writer.close()
                    await writer.wait_closed()
                server.close()
                await server.wait_closed()
                for task in handlers:
                    await asyncio.wait_for(task, 3)
                await asyncio.gather(*handlers, return_exceptions=True)


if __name__ == "__main__":
    unittest.main()
