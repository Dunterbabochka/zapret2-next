# Stability changes, 2026-10-02

The local reference Windows bundle 1.10.3 was compared with this Zapret 2 bundle.
`zendesk.com` and `live-video.net` were added to the general hostlist; the
existing DoH entries and exclusions were preserved. Zapret 1 command lines and
engine binaries were not transplanted into Zapret 2 presets.

## Service and manual launch

Service installation validates a staged configuration with the pinned engine
before stopping an existing service. The manager waits for service transitions,
updates the existing registration, and restores the previous file, image path,
start mode and strategy metadata on failure. A previously running service is
started again; a previously stopped service remains stopped after rollback.
New services receive recovery restarts at 5, 15 and 60 seconds.

Manual launches and service changes share an operation lock. A manual launcher
may replace only a process using this bundle's executable, after configuration
validation. Active services and other bundles produce a conflict message.
Validation has a 30-second timeout and retains the process handle to read its
exit code reliably on Windows PowerShell 5.1. Service removal waits for a stop
and leaves shared WinDivert registrations and other manual processes alone.

## IPSet updates and packaging

Both IPSet tools use the same IPv4/IPv6 and CIDR parser, reject duplicates and
all-addresses `/0` rules, and refuse candidates smaller than half of a populated
list (at least 100 existing entries). The installed updater additionally
requires at least 10 entries; maintainer synchronization requires 1,000.
Updates use OS file locks, unique temporary files, atomic replacement and an
exact backup. Partial failed downloads are discarded before bundled fallback.
The two-file upstream sync restores only files it actually changed.

Release archives exclude temporary files, locks, logs, backups and local user
lists. Loaded IPSet is reset to the bundled snapshot, and mode files are reset
to defaults. The builder checks staging paths before deleting a previous build.

## Verification

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File utils\validate-stability.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File utils\validate.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File utils\validate-wizard.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File utils\compatibility-wizard.ps1 -SelfTest
```

The stability suite tests update corruption, truncation, concurrent updates,
partial downloads, exact-byte rollback, failed new installation, deferred
refresh and foreign service ownership. Service operations are mocked; it does
not install, stop or reconfigure an actual Windows service. CI also runs these
checks on Windows PowerShell 5.1.

Engine dry-run, Lua initialization and actual network/service smoke tests require
an elevated Windows session. Follow [MANUAL_TEST.md](MANUAL_TEST.md) before
publishing a stable release. Offline checks do not demonstrate provider-specific
Discord voice or YouTube connectivity.
