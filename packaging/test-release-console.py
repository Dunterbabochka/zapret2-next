"""Exercise cmd.exe and actual console input in an isolated hidden console.

Only the fixture's status/actions and HTTP boundary are substituted. No live
service queries, service changes, desktop keyboard input or GitHub requests.
"""
import argparse
import ctypes
from ctypes import wintypes as w
import json
import re
import shutil
import subprocess
import time
import uuid
import zipfile
from pathlib import Path


kernel = ctypes.WinDLL("kernel32", use_last_error=True)


class Coord(ctypes.Structure):
    _fields_ = [("X", w.SHORT), ("Y", w.SHORT)]


class Rect(ctypes.Structure):
    _fields_ = [("Left", w.SHORT), ("Top", w.SHORT), ("Right", w.SHORT), ("Bottom", w.SHORT)]


class BufferInfo(ctypes.Structure):
    _fields_ = [("size", Coord), ("cursor", Coord), ("attributes", w.WORD), ("window", Rect), ("maxsize", Coord)]


class KeyEvent(ctypes.Structure):
    _fields_ = [("down", w.BOOL), ("repeat", w.WORD), ("virtual", w.WORD), ("scan", w.WORD), ("char", w.WCHAR), ("control", w.DWORD)]


class Event(ctypes.Union):
    _fields_ = [("key", KeyEvent), ("padding", ctypes.c_byte * 16)]


class InputRecord(ctypes.Structure):
    _fields_ = [("kind", w.WORD), ("event", Event)]


kernel.CreateFileW.argtypes = [w.LPCWSTR, w.DWORD, w.DWORD, w.LPVOID, w.DWORD, w.DWORD, w.HANDLE]
kernel.CreateFileW.restype = w.HANDLE
kernel.AttachConsole.argtypes = [w.DWORD]
kernel.AttachConsole.restype = w.BOOL
kernel.GetConsoleScreenBufferInfo.argtypes = [w.HANDLE, ctypes.POINTER(BufferInfo)]
kernel.ReadConsoleOutputCharacterW.argtypes = [w.HANDLE, w.LPWSTR, w.DWORD, Coord, ctypes.POINTER(w.DWORD)]
kernel.ReadConsoleOutputAttribute.argtypes = [w.HANDLE, ctypes.POINTER(w.WORD), w.DWORD, Coord, ctypes.POINTER(w.DWORD)]
kernel.WriteConsoleInputW.argtypes = [w.HANDLE, ctypes.POINTER(InputRecord), w.DWORD, ctypes.POINTER(w.DWORD)]
kernel.CloseHandle.argtypes = [w.HANDLE]


class Console:
    def __init__(self, command):
        startup = subprocess.STARTUPINFO()
        startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        startup.wShowWindow = 0
        self.process = subprocess.Popen(command, creationflags=subprocess.CREATE_NEW_CONSOLE, startupinfo=startup)
        kernel.FreeConsole()
        deadline = time.monotonic() + 5
        while not kernel.AttachConsole(self.process.pid):
            if self.process.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError("Could not attach to the isolated test console")
            time.sleep(0.025)
        self.output = kernel.CreateFileW("CONOUT$", 0x80000000, 3, None, 3, 0, None)
        self.input = kernel.CreateFileW("CONIN$", 0xC0000000, 3, None, 3, 0, None)

    def text(self):
        info = BufferInfo()
        if not kernel.GetConsoleScreenBufferInfo(self.output, ctypes.byref(info)):
            raise ctypes.WinError(ctypes.get_last_error())
        length = min(info.size.X * info.size.Y, 100_000)
        buffer = ctypes.create_unicode_buffer(length)
        read = w.DWORD()
        if not kernel.ReadConsoleOutputCharacterW(self.output, buffer, length, Coord(0, 0), ctypes.byref(read)):
            raise ctypes.WinError(ctypes.get_last_error())
        return buffer[:read.value]

    def wait_text(self, expected, timeout=10):
        alternatives = (expected,) if isinstance(expected, str) else expected
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if any(value in self.text() for value in alternatives):
                return
            if self.process.poll() is not None:
                break
            time.sleep(0.025)
        raise AssertionError(f"Console did not show {expected!r}: {self.text()!r}")

    def type(self, text):
        records = (InputRecord * (len(text) * 2))()
        for index, char in enumerate(text):
            for offset, down in enumerate((True, False)):
                record = records[index * 2 + offset]
                record.kind = 1
                record.event.key = KeyEvent(down, 1, 13 if char == "\r" else ord(char.upper()), 0, char, 0)
        written = w.DWORD()
        if not kernel.WriteConsoleInputW(self.input, records, len(records), ctypes.byref(written)):
            raise ctypes.WinError(ctypes.get_last_error())

    def close(self):
        if self.process.poll() is None:
            self.process.kill()
            self.process.wait()
        kernel.CloseHandle(self.output)
        kernel.CloseHandle(self.input)
        kernel.FreeConsole()


def test_preset_window(source, fixture):
    # Execute the real startup through its first input prompt. Cut off all
    # administrator/service/network boundaries, which are irrelevant to colors.
    script = (source / "utils/test-presets.ps1").read_text(encoding="utf-8-sig")
    startup, boundary, _ = script.partition("$principal = [Security.Principal.WindowsPrincipal]")
    assert boundary, "Preset startup boundary changed"
    probe = fixture / "utils/preset-window-probe.ps1"
    probe.write_text(startup + "\nWrite-Host 'PRESET-WINDOW-READY'\n"
                     "[void][Console]::ReadLine()\n} finally { Complete-ZapretLogOperation }\n",
                     encoding="utf-8-sig")
    wrapper = fixture / "preset-window.ps1"
    wrapper.write_text("$Host.UI.RawUI.BackgroundColor='DarkBlue'\nClear-Host\n"
                       "& (Join-Path $PSScriptRoot 'utils/preset-window-probe.ps1')\n",
                       encoding="utf-8-sig")
    console = Console(["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(wrapper)])
    try:
        console.wait_text("PRESET-WINDOW-READY")
        info = BufferInfo()
        assert kernel.GetConsoleScreenBufferInfo(console.output, ctypes.byref(info))
        assert info.attributes & 0xF0 == 0, "Preset console kept a blue default background"
        assert info.window.Right - info.window.Left + 1 <= 110, "Preset console is too wide"
        assert info.window.Bottom - info.window.Top + 1 <= 35, "Preset console is too tall"
        color, read = w.WORD(), w.DWORD()
        assert kernel.ReadConsoleOutputAttribute(console.output, ctypes.byref(color), 1,
                                                  Coord(info.window.Right, info.window.Bottom), ctypes.byref(read))
        assert read.value == 1 and color.value & 0xF0 == 0, "Empty console area was not cleared to black"
        console.type("\r")
        assert console.process.wait(timeout=5) == 0
    finally:
        console.close()
    print("[OK] Preset tests replace the saved blue background with black and bound the window size")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--port", required=True)
    args = parser.parse_args()
    fixture = args.root / ("Console install with spaces " + uuid.uuid4().hex[:8])
    fixture.mkdir()
    shutil.copytree(args.source / "utils", fixture / "utils")
    shutil.copytree(args.source / ".service", fixture / ".service")
    (fixture / ".service" / "version.txt").write_text("9.9.0", encoding="ascii")
    service = (args.source / "service.bat").read_text(encoding="utf-8-sig")
    service = service.replace("fltmc >nul 2>&1", "cmd /d /c exit 0", 1)
    service = service.replace("-MenuBootstrap !LOG_BOOTSTRAP_OPTIONS!", "-MenuBootstrap -SkipTelegramStatus", 1)
    service = re.sub(r"(?ms)^:read_status\n.*?(?=^:read_settings\n)",
                     ":read_status\nset \"CURRENT_PRESET=general\"\nset \"SERVICE_STATUS=Stopped\"\nset \"TELEGRAM_STATUS=DISABLED\"\ncall :read_settings\nexit /b\n\n", service)
    labels = {"install_service": 1, "remove_service": 2, "show_status": 3, "game_filter": 4,
              "ipset_filter": 5, "update_toggle": 6, "voice_filter": 7, "fake_profiles": 8,
              "telegram": 9, "update_ipset": 10, "update_hosts": 11, "manual_update_check": 12,
              "tests": 14, "clear_discord_cache": 15, "update_release": 111}
    for label, result in labels.items():
        service = re.sub(r"(?ms)^:" + label + r"\n.*?(?=^:[a-z_]+\n|\Z)",
                         f":{label}\necho TEST-ACTION-{result}\nexit /b {result}\n\n", service)
    service = service.replace('-Action Export\n', '-Action Export -NoReveal\n')
    (fixture / "service.bat").write_bytes(service.replace("\n", "\r\n").encode("utf-8"))
    menu_path = fixture / "utils/menu.ps1"
    menu = menu_path.read_text(encoding="utf-8-sig")
    boundaries = """
function Test-ZapretMenuAdministrator { return $true }
function Get-ZapretMenuService { [pscustomobject]@{State='Stopped';Preset='general'} }
function Get-ZapretMenuTelegram { return 'DISABLED' }
function Invoke-ZapretMenuAction([int]$Selection) {
    if ($Selection -eq 13) { Show-ZapretDiagnosticsMenu; return }
    Write-Host ('TEST-ACTION-'+$Selection)
    $script:testResult=$Selection
    $script:menuExit=$true
}
"""
    menu = menu.replace("# Menu entry point.", boundaries + "\n# Menu entry point.")
    menu = menu.replace("exit $exitCode", "exit $(if ($null -ne $script:testResult) {$script:testResult} else {$exitCode})")
    menu = menu.replace("Start-Process explorer.exe -ArgumentList ('/select,\"'+$zip+'\"') | Out-Null", "# No Explorer in the isolated fixture.")
    menu_path.write_text(menu, encoding="utf-8-sig")
    script_path = fixture / "utils" / "update-release.ps1"
    script = script_path.read_text(encoding="utf-8-sig")
    insertion = ". (Join-Path $PSScriptRoot 'update-release-state.ps1')"
    boundary = """
function Get-ReleaseHttpTarget([string]$Url) {
    if ($Url -like 'https://api.github.com/*') { $path='/release' }
    else { $path='/assets/'+([Uri]$Url).Segments[-1] }
    [pscustomobject]@{Url=('http://127.0.0.1:PORT'+$path);Protocol='http'}
}
""".replace("PORT", args.port)
    script_path.write_text(script.replace("Initialize-ZapretLog -Root", boundary + "\nInitialize-ZapretLog -Root", 1), encoding="utf-8-sig")
    scenario = args.root / "scenario.json"
    scenario.write_text(json.dumps({"mode": "ok", "delay": 10}), encoding="utf-8")
    enabled = fixture / "utils" / "check_updates.enabled"
    enabled.write_text("enabled", encoding="ascii")
    # Reproduce the English Windows runner even on a Russian developer PC.
    # The real input helper must preserve Cyrillic notifications and typed 111.
    wrapper = fixture / "english-console.bat"
    wrapper.write_text('@echo off\nchcp 437 >nul\ncall "%~dp0service.bat"\nexit /b %errorlevel%\n', encoding="ascii")
    command = ["cmd.exe", "/d", "/c", str(wrapper)]
    # The production timeout is 10 seconds too, so a 10-second fixture response
    # intentionally times out. First prove that this never holds up the menu.
    console = Console(command)
    try:
        started = time.monotonic()
        console.wait_text(("Starting Zapret 2 NEXT...", "ZAPRET 2 NEXT SERVICE MANAGER"), timeout=2)
        console.wait_text("Select option (0-15):", timeout=8)
        assert time.monotonic() - started < 8, "Menu waited for the 10-second API response"
        console.type("0\r")
        assert console.process.wait(timeout=5) == 0
        assert time.monotonic() - started < 8, "Exit waited for the background HTTP request"
    finally:
        console.close()
    check = fixture / "runtime" / "release-update" / "check.json"
    deadline = time.monotonic() + 15
    while not check.exists():
        assert time.monotonic() < deadline, "Background timeout did not finish"
        time.sleep(0.05)
    assert json.loads(check.read_text(encoding="utf-8-sig"))["Status"] == "unavailable"
    sessions = fixture / "runtime" / "logs" / "sessions"
    assert len(list(sessions.iterdir())) == 1, "Background check created another management session"
    first_events = [json.loads(line) for path in sessions.glob("*/events.jsonl") for line in path.read_text(encoding="utf-8").splitlines()]
    assert not any(event["code"] == "OperationInterrupted" for event in first_events), "FOR /F bootstrap owner was mistaken for the menu owner"
    assert any(event["action"] == "Finish" for event in first_events), "Normal menu exit was not journaled"
    check.unlink()
    scenario.write_text(json.dumps({"mode": "ok", "delay": 2}), encoding="utf-8")
    console = Console(command)
    try:
        console.wait_text("Select option (0-15):", timeout=8)
        console.type("1")
        console.wait_text("Доступна новая версия 9.9.1", timeout=10)
        console.type("11\r")
        assert console.process.wait(timeout=5) == 111, "Notification lost the first typed digit"
        assert "TEST-ACTION-111" in console.text()
        events = [json.loads(line) for path in sessions.glob("*/events.jsonl") for line in path.read_text(encoding="utf-8").splitlines()]
        selected = [event for event in events if event.get("details", {}).get("selection") == 111]
        assert len(selected) == 1, "111 selection absent or duplicated in journal"
        assert any(event["action"] == "HTTP" and event["sessionId"] == selected[0]["sessionId"] for event in events), "Menu and background check lost shared session"
        print("[OK] cmd.exe menu accepts input during a delayed check; notification preserves 111")
    finally:
        console.close()
    scenario.write_text(json.dumps({"mode": "ok"}), encoding="utf-8")
    enabled.unlink()
    if check.exists():
        check.unlink()
    requests = (args.root / "requests.txt").read_text(encoding="utf-8")
    for choice in (0, 1, 10, 15):
        console = Console(command)
        try:
            console.wait_text("Select option (0-15):")
            console.type(f"{choice}\r")
            assert console.process.wait(timeout=5) == choice
        finally:
            console.close()
    assert (args.root / "requests.txt").read_text(encoding="utf-8") == requests, "Disabled auto-check made requests"
    console = Console(command)
    try:
        console.wait_text("Select option (0-15):")
        console.type("13\r")
        console.wait_text("Select option (0-5):")
        console.type("5\r")
        console.wait_text("Logs archive /", timeout=15)
        console.wait_text(". . .")
        console.type("\r")
        cleared = time.monotonic() + 5
        while ". . ." in console.text():
            assert time.monotonic() < cleared, "Export pause did not return to Diagnostics"
            time.sleep(0.02)
        console.wait_text("Select option (0-5):")
        console.type("0\r")
        console.wait_text("Select option (0-15):")
        console.type("0\r")
        assert console.process.wait(timeout=5) == 0
    finally:
        console.close()
    assert (args.root / "requests.txt").read_text(encoding="utf-8") == requests, "Logs-only export performed network diagnostics"
    print("[OK] Diagnostics -> 5 creates a logs archive through the real cmd.exe submenu")
    recovery = fixture / "runtime/release-update/recovery"
    recovery.mkdir(parents=True, exist_ok=True)
    worker = recovery / "update-release.ps1"
    for marker_name, recovery_exit in (("recovery-needed", 0), ("cleanup-pending", 0), ("recovery-needed", 1)):
        marker = recovery.parent / marker_name
        marker.write_text("test", encoding="ascii")
        ran = fixture / "recovery-ran"
        ran.unlink(missing_ok=True)
        worker.write_text(
            "param([string]$Action,[string]$Root)\n"
            "[IO.File]::WriteAllText((Join-Path $Root 'recovery-ran'),'yes')\n"
            + (f"[IO.File]::Delete((Join-Path $Root 'runtime/release-update/{marker_name}'))\n" if recovery_exit == 0 else "")
            + f"exit {recovery_exit}\n", encoding="utf-8-sig")
        console = Console(command)
        try:
            if recovery_exit == 0:
                console.wait_text("Select option (0-15):")
                console.type("0\r")
            assert console.process.wait(timeout=10) == recovery_exit
            assert ran.exists(), "Menu skipped required recovery"
            if recovery_exit:
                assert "Select option (0-15):" not in console.text(), "Menu opened after failed recovery"
        finally:
            console.close()
            marker.unlink(missing_ok=True)
    print("[OK] early recovery, deferred cleanup and failure blocking survive menu bootstrap")
    helper = fixture / "read-choice.bat"
    helper.write_text(f'@echo off\npowershell -NoProfile -ExecutionPolicy Bypass -File "{script_path}" -Action ReadMenuChoice\nexit /b %errorlevel%\n', encoding="ascii")
    for choice in ("0", "10", "111", "999"):
        result = subprocess.run(["cmd.exe", "/d", "/c", str(helper)], input=choice + "\n", text=True, capture_output=True, timeout=10)
        assert result.returncode == (255 if choice == "999" else 100 + int(choice)), (
            f"Redirected menu input {choice!r}: exit={result.returncode}, "
            f"stdout={result.stdout!r}, stderr={result.stderr!r}")
    export_command = ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(fixture / "utils" / "manage-logs.ps1"), "-Action", "Export", "-NoReveal"]
    exported = subprocess.run(export_command, stdin=subprocess.DEVNULL, text=True, capture_output=True, timeout=15)
    assert exported.returncode == 0, exported.stderr
    newest = max((fixture / "runtime" / "logs" / "exports").glob("*.zip"), key=lambda path: path.stat().st_mtime)
    with zipfile.ZipFile(newest) as archive:
        assert set(archive.namelist()) == {"LOGS.txt", "events.jsonl", "manifest.json"}
    print("[OK] shared menu/check session, normal exit journal and logs-only export")
    input_path = fixture / "utils/menu-input.ps1"
    saved_script = input_path.read_bytes()
    input_path.write_text("function Read-ReleaseMenuChoice { throw 'Injected input helper failure' }", encoding="utf-8-sig")
    console = Console(command)
    try:
        console.wait_text("Could not read the menu selection.")
        assert "TEST-ACTION-1" not in console.text(), "Helper error dispatched Install Service"
    finally:
        console.close()
        input_path.write_bytes(saved_script)
    print("[OK] ordinary menu actions, disabled auto-check and redirected cmd.exe input")
    test_preset_window(args.source, fixture)


if __name__ == "__main__":
    main()
