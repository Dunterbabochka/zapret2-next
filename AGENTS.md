# Zapret 2 NEXT contributor guidance

- Target Windows 10/11 x64 and the pinned Zapret 2 v1.0.2 runtime.
- Treat `../zapret2-v1.0.2` as the source of truth for engine binaries, Lua APIs and documentation.
- Treat the legacy UI snapshot as a reference for user-facing behavior only. Preserve required attribution in `THIRD_PARTY_NOTICES.md`.
- Treat `../Zapret 2 FORK NN` only as a porting reference. Never copy its binary, patched core Lua files, oversized preset library, links or branding.
- Public launchers call `utils/run-preset.bat`; strategy logic belongs in `presets/*.txt.in`.
- Do not introduce Zapret 1 `--dpi-desync` options. Use official Zapret 2 Lua functions.
- Keep `service.bat` service name fixed to `winws2`; the upstream binary registers that service name.
- Run `powershell -ExecutionPolicy Bypass -File utils/validate.ps1` after every change.
- Run `utils/validate-runtime.ps1` as Administrator after strategy or runtime changes.
- Do not claim a strategy works for a provider unless a recorded test supports the claim.
- Do not edit the three source snapshot directories.

## Staged implementation workflow

- At the start of every stage, read `docs/ROADMAP.md` and `docs/HANDOFF.md`, then run `git status` and `git log -1`.
- Complete only the one stage explicitly requested by the user.
- Preserve all unrelated dirty and untracked files. Do not edit the three source snapshot directories.
- Before finishing a stage, run its acceptance checks and `git diff --check`.
- Update `docs/HANDOFF.md` after implementation and testing, including unrelated dirty/untracked paths and verification results.
- Do not commit or push without a direct user instruction. When staging is requested, use an explicit allowlist containing only files from the completed stage.
- After a push, wait for CI and report its result in the final response.
- Use the reference fork only for consultation; the official pinned Zapret 2 v1.0.2 runtime remains the source of truth.
