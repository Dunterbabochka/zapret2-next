"""Measure the real console in a disposable install; never touch live services.

Warm measurements only. Cold boot/UAC/network performance needs a Windows VM.
"""
from __future__ import annotations

import argparse
import ctypes
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import statistics
import time
import uuid

spec = importlib.util.spec_from_file_location("console_test", Path(__file__).with_name("test-release-console.py"))
console_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(console_module)
Console = console_module.Console
w = console_module.w
kernel = console_module.kernel


class MemoryCounters(ctypes.Structure):
    _fields_ = [("cb", w.DWORD), ("faults", w.DWORD)] + [(name, ctypes.c_size_t) for name in
                 ("peak_rss", "rss", "peak_paged", "paged", "peak_nonpaged", "nonpaged", "pagefile", "peak_pagefile")]


kernel.OpenProcess.argtypes = [w.DWORD, w.BOOL, w.DWORD]
kernel.OpenProcess.restype = w.HANDLE
psapi = ctypes.WinDLL('psapi', use_last_error=True)
psapi.GetProcessMemoryInfo.argtypes = [w.HANDLE, ctypes.POINTER(MemoryCounters), w.DWORD]
kernel.GetProcessTimes.argtypes = [w.HANDLE] + [ctypes.POINTER(w.FILETIME)] * 4


def resources():
    process_ids = (w.DWORD * 128)()
    count = kernel.GetConsoleProcessList(process_ids, len(process_ids))
    result = {}
    for pid in process_ids[:count]:
        if pid == os.getpid():
            continue
        handle = kernel.OpenProcess(0x410, False, pid)
        if not handle:
            continue
        try:
            times = [w.FILETIME() for _ in range(4)]
            memory = MemoryCounters()
            memory.cb = ctypes.sizeof(memory)
            if not kernel.GetProcessTimes(handle, *(ctypes.byref(t) for t in times)) or not psapi.GetProcessMemoryInfo(handle, ctypes.byref(memory), memory.cb):
                raise ctypes.WinError(ctypes.get_last_error())
            ticks = sum((t.dwHighDateTime << 32) + t.dwLowDateTime for t in times[2:])
            result[pid] = {'cpu_ms': ticks/10_000, 'rss_mib': memory.rss/1024**2, 'peak_rss_mib': memory.peak_rss/1024**2}
        finally:
            kernel.CloseHandle(handle)
    return result


def prepare(source: Path, fixture: Path):
    fixture.mkdir(parents=True)
    shutil.copytree(source / "utils", fixture / "utils")
    shutil.copytree(source / ".service", fixture / ".service")
    (fixture / "utils/check_updates.enabled").unlink(missing_ok=True)
    bat = (source / "service.bat").read_text(encoding="utf-8-sig")
    if (source / "utils/menu.ps1").exists():
        script = (fixture / "utils/menu.ps1").read_text(encoding="utf-8-sig")
        script = script.replace("Test-ZapretMenuAdministrator", "Test-BenchmarkAdministrator")
        # Boundary overrides stay inside the fixture, never in production.
        marker = "# Menu entry point."
        boundary = """
function Test-BenchmarkAdministrator { return $true }
function Get-ZapretMenuService { [pscustomobject]@{State='Stopped';Preset='general'} }
function Get-ZapretMenuTelegram { return 'DISABLED' }
"""
        script = script.replace(marker, boundary + "\n" + marker)
        (fixture / "utils/menu.ps1").write_text(script, encoding="utf-8-sig")
    else:
        bat = bat.replace("fltmc >nul 2>&1", "cmd /d /c exit 0", 1)
        bat = bat.replace("-MenuBootstrap !LOG_BOOTSTRAP_OPTIONS!", "-MenuBootstrap -SkipTelegramStatus", 1)
        bat = re.sub(r"(?ms)^:read_status\n.*?(?=^:read_settings\n)",
                     ':read_status\nset "CURRENT_PRESET=general"\nset "SERVICE_STATUS=Stopped"\nset "TELEGRAM_STATUS=DISABLED"\ncall :read_settings\nexit /b\n\n', bat)
    (fixture / "service.bat").write_bytes(bat.replace("\n", "\r\n").encode("utf-8"))


def measure(fixture: Path, runs: int, idle_seconds: float, navigation_rounds: int):
    samples = []
    for _ in range(runs):
        started = time.perf_counter()
        console = Console(["cmd.exe", "/d", "/c", str(fixture / "service.bat")])
        try:
            console.wait_text("Select option (0-15):", timeout=15)
            ready = time.perf_counter()
            start_resources = resources()
            back_samples = []
            rss_samples = []
            for _round in range(navigation_rounds):
                # Diagnostics -> Back is a reversible real navigation path.
                console.type("13\r")
                console.wait_text("Select option (0-5):", timeout=5)
                before_back = time.perf_counter()
                console.type("0\r")
                console.wait_text("Select option (0-15):", timeout=5)
                back_samples.append((time.perf_counter()-before_back)*1000)
                if _round % 25 == 24 or _round == navigation_rounds-1:
                    rss_samples.append({'round': _round+1, 'rss_mib': sum(value['rss_mib'] for value in resources().values())})
            idle_before = resources()
            time.sleep(idle_seconds)
            idle_after = resources()
            idle_cpu = sum(value['cpu_ms']-idle_before[pid]['cpu_ms'] for pid, value in idle_after.items() if pid in idle_before)
            rss = sum(value['rss_mib'] for value in idle_after.values())
            rss_growth = rss-sum(value['rss_mib'] for value in start_resources.values())
            back = time.perf_counter()
            console.type("0\r")
            assert console.process.wait(timeout=10) == 0
            samples.append({"ready_ms": (ready-started)*1000, "back_ms": statistics.median(back_samples),
                            "exit_ms": (time.perf_counter()-back)*1000, "console_processes": len(idle_after),
                            "idle_cpu_ms": idle_cpu, "rss_mib": rss, "navigation_rss_growth_mib": rss_growth})
            samples[-1]['navigation_rss_samples'] = rss_samples
            samples[-1]['back_samples_ms'] = back_samples
        finally:
            console.close()
    result = {"kind": "warm, isolated service/Telegram boundaries, auto-check disabled", "samples": samples}
    result.update(idle_seconds=idle_seconds, navigation_rounds=navigation_rounds)
    for field in ("ready_ms", "back_ms", "exit_ms", "console_processes", "idle_cpu_ms", "rss_mib", "navigation_rss_growth_mib"):
        values = sorted(row[field] for row in samples)
        result[field] = {"median": statistics.median(values), "p95": values[max(0, int(len(values)*.95+.999)-1)]}
    # back_ms above compares per-run medians; also expose the full distribution
    # so slow individual transitions are not hidden by that aggregation.
    events = sorted(value for sample in samples for value in sample['back_samples_ms'])
    result['back_events_ms'] = {'median': statistics.median(events),
                              'p95': events[max(0, int(len(events)*.95+.999)-1)]}
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--runs", type=int, default=10)
    parser.add_argument("--idle-seconds", type=float, default=1)
    parser.add_argument("--navigation-rounds", type=int, default=1)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.runs < 1 or args.navigation_rounds < 1 or args.idle_seconds < 0:
        parser.error("runs/navigation-rounds must be positive; idle-seconds must be nonnegative")
    fixture = args.source / "runtime" / ("startup-benchmark-" + uuid.uuid4().hex)
    prepare(args.source, fixture)
    result = measure(fixture, args.runs, args.idle_seconds, args.navigation_rounds)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps({key: value for key, value in result.items() if key != "samples"}, indent=2))


if __name__ == "__main__":
    main()
