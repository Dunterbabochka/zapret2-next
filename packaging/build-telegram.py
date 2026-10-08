"""Build the pinned headless Windows runtime and its integrity/license manifests."""
from __future__ import annotations

import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / "third_party" / "tg-ws-proxy"
OUT = ROOT / "bin" / "telegram"
WORK = ROOT / "runtime" / "telegram-build"


def verify_sources():
    manifest = json.loads((VENDOR / "SOURCE.json").read_text(encoding="utf-8"))
    for relative, expected in manifest["sha256"].items():
        actual = hashlib.sha256((VENDOR / relative).read_bytes()).hexdigest()
        if actual != expected:
            raise RuntimeError(f"Pinned Telegram source changed: {relative}")


def collect_licenses():
    license_dir = OUT / "licenses"
    license_dir.mkdir(parents=True, exist_ok=True)
    (license_dir / "tg-ws-proxy.txt").write_bytes((VENDOR / "LICENSE").read_bytes())
    lines = ["Zapret 2 NEXT Telegram runtime dependency licenses", ""]
    for line in (ROOT / "packaging" / "telegram-requirements.txt").read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        name, version = line.split("==")
        dist = importlib.metadata.distribution(name)
        if dist.version != version:
            raise RuntimeError(f"Install packaging/telegram-requirements.txt: {name} must be {version}")
        lines.append(f"{name} {version}")
        for file in dist.files or []:
            if ".dist-info/" in str(file) and any(x in file.name.upper() for x in ("LICENSE", "COPYING", "NOTICE")):
                target = license_dir / name / Path(str(file)).name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(Path(dist.locate_file(file)).read_bytes())
    python_license = Path(sys.base_prefix) / "LICENSE.txt"
    if not python_license.is_file():
        raise RuntimeError("Python LICENSE.txt is required for redistribution")
    (license_dir / "Python.txt").write_bytes(python_license.read_bytes())
    (OUT / "DEPENDENCIES.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")


def main():
    if sys.platform != "win32" or sys.maxsize <= 2**32:
        raise RuntimeError("Build Telegram runtime on Windows x64")
    verify_sources()
    OUT.mkdir(parents=True, exist_ok=True)
    WORK.mkdir(parents=True, exist_ok=True)
    # Check all installed versions before starting an expensive build.
    collect_licenses()
    subprocess.run([
        sys.executable, "-m", "PyInstaller", "--noconfirm", "--clean",
        "--onefile", "--windowed", "--noupx", "--name", "zapret-telegram",
        "--paths", str(VENDOR), "--collect-data", "certifi",
        "--hidden-import", "cryptography.hazmat.backends.openssl",
        "--distpath", str(OUT), "--workpath", str(WORK / "work"),
        "--specpath", str(WORK), str(ROOT / "telegram" / "launcher.py"),
    ], cwd=ROOT, check=True)
    report_path = WORK / "frozen-smoke.json"
    report_path.unlink(missing_ok=True)
    # Keep smoke-test extraction inside the workspace in restricted runners.
    smoke_env = os.environ.copy()
    (WORK / "tmp").mkdir(exist_ok=True)
    smoke_env["TMP"] = smoke_env["TEMP"] = str(WORK / "tmp")
    subprocess.run([str(OUT / "zapret-telegram.exe"), "--self-test", "--output", str(report_path)],
                   timeout=45, check=True, env=smoke_env)
    report = json.loads(report_path.read_text())
    if not report.get("ok"):
        raise RuntimeError("Frozen Telegram smoke test failed")
    provenance = {"upstream_version": report["upstream_version"],
                  "upstream_commit": json.loads((VENDOR / "SOURCE.json").read_text())["commit"],
                  "launcher_sha256": hashlib.sha256((ROOT / "telegram" / "launcher.py").read_bytes()).hexdigest(),
                  "python": sys.version.split()[0], "architecture": "windows-x86_64",
                  "entry_point": "telegram/launcher.py"}
    (OUT / "BUILD.json").write_text(json.dumps(provenance, indent=2) + "\n", encoding="utf-8")
    entries = []
    for path in sorted(OUT.rglob("*")):
        if path.is_file() and path.name != "SHA256SUMS.txt":
            entries.append(f"{hashlib.sha256(path.read_bytes()).hexdigest().upper()}  {path.relative_to(OUT).as_posix()}")
    (OUT / "SHA256SUMS.txt").write_text("\n".join(entries) + "\n", encoding="ascii")
    # Keep the bundle's public integrity catalog in sync with a rebuilt runtime.
    sums = ROOT / "SHA256SUMS.txt"
    retained = [line for line in sums.read_text(encoding="utf-8-sig").splitlines()
                if not line.split() or not line.split()[-1].startswith("bin/telegram/")]
    retained.extend(line.split("  ", 1)[0] + "  bin/telegram/" + line.split("  ", 1)[1] for line in entries)
    retained.append(hashlib.sha256((OUT / "SHA256SUMS.txt").read_bytes()).hexdigest().upper()
                    + "  bin/telegram/SHA256SUMS.txt")
    sums.write_text("\n".join(retained) + "\n", encoding="utf-8")
    print(f"Telegram runtime built and verified: {OUT / 'zapret-telegram.exe'}")


if __name__ == "__main__":
    main()
