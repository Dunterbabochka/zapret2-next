# NEXT and additional Classic parameters

This is the fixed parameter ledger for the first controlled iteration. The rendered config in each A/B result directory is the authoritative copy used by winws2.

NEXT SAFE and NEXT BALANCED are public strategies, renamed from CUSTOM SAFE and CUSTOM BALANCED without changing their traffic actions. ALT12 is also public. NEXT AGGRESSIVE remains development-only and is excluded from the service menu, Compatibility Wizard and packaged presets. Old CUSTOM names remain renderer aliases.

| Candidate | HTTP | TLS | Generic/IPSet | Discord media | Google TLS | QUIC | Voice |
| --- | --- | --- | --- | --- | --- | --- | --- |
| ALT12 frozen reference | tls_max fake x8; multisplit pos 1, overlap 664, tls_max pattern, tcp_ts_up | tls_max fake x8; multisplit pos 1, overlap 664, tls_max pattern, tcp_ts_up | same tls_max pair; optional IPSet TCP 8443 | tls_google fake x8; multisplit pos 1, overlap 681, tls_google pattern | www.google.com hostfakesplit, ip_id zero, tcp timestamps | quic_google fake x11 | fixed UDP 19294-19344,50000-50100; STUN/discovery fakes x3 |
| NEXT SAFE | http_iana fake x3; multisplit pos 2, overlap 1, zero pattern, tcp_ts_up | tls_google fake x3; multisplit pos 2,midsld, overlap 1, zero pattern, tcp_ts_up | tls_google fake x2; multisplit pos 2, overlap 1, zero pattern, tcp_ts_up | tls_google fake x4; multisplit pos 1, overlap 681, tls_google pattern | tls_google fake x3; multisplit pos 2,midsld, overlap 1 | quic_google fake x4 | fixed UDP 19294-19344,50000-50100; STUN/discovery fakes x3 |
| NEXT BALANCED | http_iana fake x6; multisplit pos 2,host+1,host+4, overlap 8, zero pattern, tcp_ts_up | tls_google fake x6; multisplit pos 2,sniext+1,midsld, overlap 8, zero pattern, tcp_ts_up | tls_google fake x4; multisplit pos 2, overlap 8, zero pattern, tcp_ts_up; optional IPSet TCP 8443 | tls_google fake x8; multisplit pos 1, overlap 681, tls_google pattern | www.google.com hostfakesplit, ip_id zero, tcp timestamps | quic_google fake x8 | fixed UDP 19294-19344,50000-50100; STUN/discovery fakes x3 |
| NEXT AGGRESSIVE | tls_max fake x11; multisplit pos 1, overlap 664, tls_max pattern, tcp_ts_up | tls_max fake x11; multisplit pos 1, overlap 664, tls_max pattern, tcp_ts_up | tls_max fake x11; multisplit pos 1, overlap 664, tls_max pattern, tcp_ts_up; optional IPSet TCP 8443 | tls_google fake x10; multisplit pos 1, overlap 681, tls_google pattern | www.google.com hostfakesplit, ip_id zero, tcp timestamps | quic_google fake x11 | fixed UDP 19294-19344,50000-50100; STUN/discovery fakes x3 |

Fooling and packet-range boundaries are the existing native Lua parameters shown above; none of these candidates uses a global all-port strategy. The next iteration must change one parameter group at a time and record the resulting A/B JSON/CSV and fresh voice report. Do not edit ALT12 while comparing candidates.

## Fixed first-iteration scope and fooling ledger

- Every TCP fake in these candidates uses tcp_ts=-1000. Every multisplit uses tcp_ts_up; SAFE and BALANCED use the zero overlap pattern, while AGGRESSIVE uses the documented tls_max overlap pattern.
- General HTTP, general TLS, Google/YouTube TLS, Discord media TLS and IPSet TCP profiles use out-range=-d10. QUIC and IPSet UDP use out-range=-d5. Optional game profiles remain disabled by the port-12 sentinel; when explicitly enabled in a separate game test, Game TCP uses out-range=-d4 and Game UDP uses out-range=-n4.
- Discord Voice is scoped to UDP 19294-19344 and 50000-50100 plus discord/stun L7 and discovery/STUN payload filters. It has no broad UDP fallback and must be evaluated only through a fresh connection.
- SAFE changes the low-intervention fake/repeat/split group, BALANCED changes the moderate repeat/split group, and AGGRESSIVE changes the tls_max/repeat/overlap group. A later iteration must change only one of these groups and add a dated result row rather than silently rewriting this baseline.

## ALT13 and EXP adaptation

Both strategies are translated from the local Windows reference 1.10.3. Their payload provenance and hashes are recorded in `THIRD_PARTY_NOTICES.md` and `SHA256SUMS.txt`. They use the project's shared list exclusions, absolute resource paths and Game/IPSet/Voice mode controls. They have not been accepted through live web/voice testing on this network.

| Scope | ALT13 | EXP |
| --- | --- | --- |
| HTTP | Sochi fake x5; mail.ru host split | tls_max fake x4; multisplit pos 1, overlap 480, stun2 pattern |
| TLS | Sochi fake x5, stun2 fake x5; mail.ru host split | Same fake/split as HTTP |
| Host split order | Before host, fake host, after host, real host; `next_hostfakesplit` preserves altorder=1 | Native multisplit |
| Discord media | tls_google fake x7; overlap 681 | tls_google fake x8; overlap 681 |
| Google TLS | www.google.com hostfakesplit with TCP timestamps | Same with ip_id=zero |
| QUIC | Google fake x11 | Google fake x11; primary profile matches QUIC L7 |
| IPSet TCP | HTTP/TLS actions plus TCP 8443 | HTTP/TLS actions plus TCP 8443; excludes fonts.googleapis.com |
| Compatible Voice | Fixed voice ports, discord/stun, selected Discord fake x5 | Fixed voice ports, discord/stun/unknown, first four packets; Google + selected Discord fakes x4 for discovery/unknown, selected Discord fake x4 for STUN |
| Game TCP | First four packets; Sochi/STUN fakes and alternate host split | First four packets; stun2 + tls_max fakes x8 for TLS, tls_max x8 for HTTP, 256 zero bytes x8 for unknown; overlap 664 with tls_max pattern |
| Game UDP | Selected Game fake x10 | 4pda + selected Game fakes x5 |

Voice `standard` and `off` retain their shared behavior. Game ports stay at the disabled port-12 sentinel unless explicitly enabled. The additional functions are loaded only by presets that need them; the pinned upstream Lua files are unchanged.

## Local presets

Add a trusted `presets\<NAME>.txt.in` template to show it automatically in the service menu's `Custom / other` column. Names may contain Latin letters, digits, spaces, underscores and hyphens. An optional `strategies\general (<NAME>).bat` launcher must call `utils\run-preset.bat` with that same name. Templates can initialize Lua, so their contents must be reviewed before use.

The eleven shipped strategies keep their original numbers. Compatibility Wizard, automatic support scans and release launchers continue to use only those shipped strategies. `utils\validate.ps1` also checks local presets; menu installation validates the selected configuration with the engine before applying it. Safe journals replace arbitrary local names with `CUSTOM`.

Keep a separate backup of local templates and launchers before updating: the updater replaces the packaged `presets` and `strategies` directories. An active local preset missing from a new release causes update preparation to stop before replacement; switch to a shipped strategy and restore the local files after updating.
