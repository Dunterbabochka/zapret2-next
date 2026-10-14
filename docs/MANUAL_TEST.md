# Windows release verification

Run these steps from an elevated PowerShell window on both Windows 10 x64 and Windows 11 x64. Record only the outcome, provider/region, and strategy; never publish packet captures or personal data.

## 1. Package integrity

```powershell
Get-FileHash .\bin\winws2.exe -Algorithm SHA256
powershell -ExecutionPolicy Bypass -File .\utils\validate.ps1
powershell -ExecutionPolicy Bypass -File .\utils\validate-stability.ps1
powershell -ExecutionPolicy Bypass -File .\utils\validate-wizard.ps1
powershell -ExecutionPolicy Bypass -File .\utils\compatibility-wizard.ps1 -SelfTest
powershell -ExecutionPolicy Bypass -File .\utils\validate-runtime.ps1
```

Expected: all shipped presets pass argument validation and Lua initialization.
The stability suite injects updater and service failures in isolated fixtures;
the wizard self-test simulates 13 outcomes without changing live services.

## 2. Manual launchers

1. Run `strategies/general.bat`, then verify that `winws2.exe` remains in Task Manager.
2. Confirm YouTube web/video and Discord web access.
3. Repeat for every remaining `strategies/general (?).bat` launcher. Only the manual process from the same folder may be replaced; a process from another bundle must produce a conflict message.
4. Where available, test Discord voice in both directions and one screen-share session.

## 3. Service Manager

1. Start `service.bat` as Administrator and install `general`.
2. Check status, reboot, then check status again.
3. Cycle Game Filter through off, TCP, UDP, and all; accept the safe restart prompt after each change.
4. Cycle IPSet through loaded and none, then restore loaded. The any mode remains diagnostic-only.
5. Run diagnostics and the standard preset test suite.
6. Reinstall a different strategy and verify that the existing service is updated after config validation and a completed stop, without deleting its registration.
7. Remove the service and verify that `sc query winws2` reports no service and its process has stopped. Other manual processes and shared WinDivert registrations must remain untouched.

## 4. Update safety

0. Run `utils/validate-release-update.ps1` for local HTTP, rollback, abrupt-process-exit and native console checks. For real service/Telegram smoke testing on a disposable Windows 10/11 VM, follow the local update lab instructions in `MAINTAINING.md`; no GitHub release is needed.
1. Check for updates while online and then while disconnected.
2. Select Update IPSet List offline. A failed or partial download must use a validated bundled snapshot. An invalid candidate or a shrink of more than 50% must preserve the prior list; successful replacement must keep its bytes in `.backup`.
3. Select Update Hosts File and verify that it only opens a suggested file; it must not modify the system hosts file.

## Release decision

Publish a stable release only if both Windows versions pass package/runtime checks, all public strategies start successfully, service install/remove works, and no new regressions are found. Otherwise keep the release draft and file an issue with sanitized diagnostics.

## Management session logs (Windows 10/11 VM)

1. Start `service.bat`, change a mode, decline the service restart, and inspect the session: saved settings and deferred application must be distinguishable. Check status and run quick diagnostics. Close normally, reopen, then close the console abruptly; the following launch must mark the unfinished session.
2. In the disposable update lab, update 9.9.0 → 9.9.1; the old menu, worker and reopened menu must share the log session. Repeat with API failure, truncated ZIP and a blocked replacement file. The code and rollback outcome must be visible and archived. Never use a working installation for deliberate interruption tests.
3. Use Diagnostics → 5 to export while Zapret and Telegram are running. Neither must restart; no network test is started. Check the selected ZIP in Explorer and its three explicit members. Create a normal support report and check the same three members under `logs/`.
4. Reopen six times and verify retention; run two menus concurrently and export during an action. Temporarily deny writes only in the disposable VM fixture: one logging warning must not change an action's result. Restore permissions afterward.
5. Inspect the archive and sendable session files for test secrets, addresses, usernames, private paths and list content. No additional watcher or startup task may appear. Existing advanced diagnostic/raw logs remain local and are outside the safe archive contract.
