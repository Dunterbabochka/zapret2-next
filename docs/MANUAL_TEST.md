# v0.1.0 manual release test

Run these steps from an elevated PowerShell window on both Windows 10 x64 and Windows 11 x64. Record only the outcome, provider/region, and strategy; never publish packet captures or personal data.

## 1. Package integrity

```powershell
Get-FileHash .\bin\winws2.exe -Algorithm SHA256
powershell -ExecutionPolicy Bypass -File .\utils\validate.ps1
powershell -ExecutionPolicy Bypass -File .\utils\validate-runtime.ps1
```

Expected: all eight presets pass argument validation and Lua initialization.

## 2. Manual launchers

1. Run `general.bat`, then verify that `winws2.exe` remains in Task Manager.
2. Confirm YouTube web/video and Discord web access.
3. Stop `winws2.exe` and repeat for every remaining `general (?).bat` launcher.
4. Where available, test Discord voice in both directions and one screen-share session.

## 3. Service Manager

1. Start `service.bat` as Administrator and install `general`.
2. Check status, reboot, then check status again.
3. Cycle Game Filter through off, TCP, UDP, and all; accept the safe restart prompt after each change.
4. Cycle IPSet through loaded, none, and any, then restore loaded.
5. Run diagnostics and the standard preset test suite.
6. Remove the service and verify that `sc query winws2` reports no service and no `winws2.exe` process remains.

## 4. Update safety

1. Check for updates while online and then while disconnected.
2. Select Update IPSet List and verify that a failed download leaves the prior list intact.
3. Select Update Hosts File and verify that it only opens a suggested file; it must not modify the system hosts file.

## Release decision

Publish `v0.1.0` only if both Windows versions pass package/runtime checks, at least six strategies start successfully, service install/remove works, and no new regressions are found. Otherwise keep the RC draft and file an issue with sanitized diagnostics.
