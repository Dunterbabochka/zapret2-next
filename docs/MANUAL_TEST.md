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

1. Run `general.bat`, then verify that `winws2.exe` remains in Task Manager.
2. Confirm YouTube web/video and Discord web access.
3. Repeat for every remaining `general (?).bat` launcher. Only the manual process from the same folder may be replaced; a process from another bundle must produce a conflict message.
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

1. Check for updates while online and then while disconnected.
2. Select Update IPSet List offline. A failed or partial download must use a validated bundled snapshot. An invalid candidate or a shrink of more than 50% must preserve the prior list; successful replacement must keep its bytes in `.backup`.
3. Select Update Hosts File and verify that it only opens a suggested file; it must not modify the system hosts file.

## Release decision

Publish a stable release only if both Windows versions pass package/runtime checks, all public strategies start successfully, service install/remove works, and no new regressions are found. Otherwise keep the release draft and file an issue with sanitized diagnostics.
