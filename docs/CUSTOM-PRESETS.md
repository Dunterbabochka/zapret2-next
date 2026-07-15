# Experimental CUSTOM presets

These presets are deliberately separate from the public release and from the frozen ALT12 reference.

Current recommendation: keep ALT12 as the confirmed reference until a clean acceptance run proves a CUSTOM candidate. For the experimental ladder, test SAFE first, use BALANCED when SAFE is insufficient, and reserve AGGRESSIVE for networks where both lighter candidates fail. This is a testing order, not a provider compatibility claim.

| Preset | Intended role | Native Zapret 2 strategy | Main limit |
| --- | --- | --- | --- |
| CUSTOM SAFE | Low-intervention first candidate | Small HTTP/TLS fakes and one small multisplit; targeted Discord media, Google/YouTube TLS, QUIC and fixed Discord voice range | No tls_max, no extra IPSet TCP port; may be insufficient for difficult DPI |
| CUSTOM BALANCED | Daily experimental candidate | Moderate host/sni splits, isolated Discord media, Google hostfakesplit, QUIC repeats 8 | More packets are modified than SAFE; still requires clean provider testing |
| CUSTOM AGGRESSIVE | Difficult-DPI reserve | tls_max fake plus overlap 664, higher repeats, isolated media/Google/QUIC and TCP 8443 IPSet fallback | Higher side-effect risk and more CPU/packet overhead; not a default |

CUSTOM renders have an explicit Discord Web/Gateway/CDN/Updates hostlist for discord.com, gateway.discord.gg, cdn.discordapp.com and updates.discord.com. It is evaluated before the shared general TLS scope and uses the selected candidate's native TLS actions. Public presets do not reference this CUSTOM-only list, so their existing hostlist behavior is preserved.

All three templates use the official pinned Zapret 2 v1.0.2 Lua actions. They do not use Zapret 1 --dpi-desync. Discord Voice/STUN is kept in the explicit 19294-19344,50000-50100 range and is never a substitute for a fresh voice diagnostic.

## Required operating rules

- Keep Game=off unless a separate game test has been requested.
- IPSet=loaded is valid only when lists/ipset-all.txt contains non-comment entries. An empty or missing list is rendered as ipset-none; it must not become an implicit any.
- IPSet=any is diagnostic-only and is not a persistent recommendation.
- service.bat does not cycle into IPSet=any, and Compatibility Wizard never emits it as a persistent recommendation. Explicit renderer/wizard overrides retain it only for strategy discovery.
- Do not enable a proxy, VPN or TUN during the acceptance run. The A/B harness records these indicators and excludes contaminated candidates from ranking.
- A successful HTTP response is transport evidence only. Discord App startup, updater completion, Discord Web, YouTube playback and Voice require fresh manual checks.
- CUSTOM SAFE, ALT12 and CUSTOM BALANCED are now exposed only in the local `service.bat` menu through `utils/accepted_service_presets.txt`; CUSTOM AGGRESSIVE remains excluded because it has no fresh voice acceptance. None of them is added to Compatibility Wizard menus, public launchers or the public release allowlist.

## Deterministic web A/B run

Run from an Administrator PowerShell after updating the IPSet list:

    powershell -NoProfile -ExecutionPolicy Bypass -File .\utils\test-custom-presets.ps1 -TesterId tester-01 -Provider unknown -Region unknown -ConnectionType wifi -NonInteractive -ConfirmNetworkTest

The script runs the direct no-Zapret baseline, ALT12, CUSTOM SAFE, CUSTOM BALANCED and CUSTOM AGGRESSIVE with the same Discord/YouTube endpoint set. It also records Google Main/Gstatic TLS checks and QUIC probes for YouTube/Google. It writes REPORT.txt, results.json, web-results.csv, manual-acceptance.csv, rendered configs, winws2 startup logs and debug logs under runtime/custom-ab/<timestamp>. Each transport row records the remote IP/port, matched profile IDs and real Lua actions ending in desync. ICMP rows are retained for diagnostics and never affect ranking. If local curl lacks HTTP/3, QUIC rows are explicitly marked unavailable rather than failed; the manual checklist then requires browser-observed `h3` evidence.

Fill one manual-acceptance.csv row while the exact candidate named in that row is running. Record Discord startup past Checking for updates, updater completion, Web, YouTube playback, named ordinary sites, the exact game launcher, Windows Update connectivity and the associated fresh voice report ZIP. Values left as not-tested cannot support acceptance or a default recommendation.

A candidate is rankable only when every mandatory Discord/YouTube HTTP 1.1, TLS 1.2 and TLS 1.3 row succeeds, every such row contains profile/action evidence, no profile-not-found message is observed, and the run is not contaminated by proxy/VPN/TUN indicators.

If valid candidates have identical mandatory and ranked transport scores, the deterministic tie-break prefers CUSTOM SAFE, then ALT12, CUSTOM BALANCED and CUSTOM AGGRESSIVE. This encodes the low-intervention objective instead of selecting an alphabetic winner.

If the bundled IPSet is intentionally unavailable, -AllowEmptyIPSet is permitted only for a diagnostic run. Such a report is explicitly marked as not being a valid loaded-IPSet acceptance run. A proxy/VPN/TUN finding produces a prominent warning but does not block transport checks; affected results remain marked contaminated and excluded from ranking. Detection failures such as inaccessible adapter metadata are recorded as warnings, not treated as proof that a proxy is active.

The non-network harness contract can be checked without Administrator rights:

    powershell -NoProfile -ExecutionPolicy Bypass -File .\utils\test-custom-presets.ps1 -SelfTest

## Acceptance still required

For each final candidate, repeat the web run with a populated IPSet and a clean proxy/VPN/TUN preflight. Then perform a fresh Discord voice diagnostic (new UDP discovery/STUN handshake and observed Lua action), Discord App/Web/updater checks, YouTube playback, ordinary allowed-site checks, one explicitly named game launcher check and a Windows Update connectivity check. The voice diagnostic refuses an empty loaded IPSet, but network contamination is a warning: the run may proceed for diagnosis while `AcceptanceEligible` and `TwoWayAudioConfirmed` remain false. Compare the winner against ALT12 using the same Game/IPSet/Voice combination. Do not make a provider or universal claim until the result is reproduced on at least two independent networks.
