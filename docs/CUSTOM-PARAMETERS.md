# CUSTOM parameter ledger

This is the fixed parameter ledger for the first controlled iteration. The rendered config in each A/B result directory is the authoritative copy used by winws2.

| Candidate | HTTP | TLS | Generic/IPSet | Discord media | Google TLS | QUIC | Voice |
| --- | --- | --- | --- | --- | --- | --- | --- |
| ALT12 frozen reference | tls_max fake x8; multisplit pos 1, overlap 664, tls_max pattern, tcp_ts_up | tls_max fake x8; multisplit pos 1, overlap 664, tls_max pattern, tcp_ts_up | same tls_max pair; optional IPSet TCP 8443 | tls_google fake x8; multisplit pos 1, overlap 681, tls_google pattern | www.google.com hostfakesplit, ip_id zero, tcp timestamps | quic_google fake x11 | fixed UDP 19294-19344,50000-50100; STUN/discovery fakes x3 |
| CUSTOM SAFE | http_iana fake x3; multisplit pos 2, overlap 1, zero pattern, tcp_ts_up | tls_google fake x3; multisplit pos 2,midsld, overlap 1, zero pattern, tcp_ts_up | tls_google fake x2; multisplit pos 2, overlap 1, zero pattern, tcp_ts_up | tls_google fake x4; multisplit pos 1, overlap 681, tls_google pattern | tls_google fake x3; multisplit pos 2,midsld, overlap 1 | quic_google fake x4 | fixed UDP 19294-19344,50000-50100; STUN/discovery fakes x3 |
| CUSTOM BALANCED | http_iana fake x6; multisplit pos 2,host+1,host+4, overlap 8, zero pattern, tcp_ts_up | tls_google fake x6; multisplit pos 2,sniext+1,midsld, overlap 8, zero pattern, tcp_ts_up | tls_google fake x4; multisplit pos 2, overlap 8, zero pattern, tcp_ts_up; optional IPSet TCP 8443 | tls_google fake x8; multisplit pos 1, overlap 681, tls_google pattern | www.google.com hostfakesplit, ip_id zero, tcp timestamps | quic_google fake x8 | fixed UDP 19294-19344,50000-50100; STUN/discovery fakes x3 |
| CUSTOM AGGRESSIVE | tls_max fake x11; multisplit pos 1, overlap 664, tls_max pattern, tcp_ts_up | tls_max fake x11; multisplit pos 1, overlap 664, tls_max pattern, tcp_ts_up | tls_max fake x11; multisplit pos 1, overlap 664, tls_max pattern, tcp_ts_up; optional IPSet TCP 8443 | tls_google fake x10; multisplit pos 1, overlap 681, tls_google pattern | www.google.com hostfakesplit, ip_id zero, tcp timestamps | quic_google fake x11 | fixed UDP 19294-19344,50000-50100; STUN/discovery fakes x3 |

Fooling and packet-range boundaries are the existing native Lua parameters shown above; none of these candidates uses a global all-port strategy. The next iteration must change one parameter group at a time and record the resulting A/B JSON/CSV and fresh voice report. Do not edit ALT12 while comparing candidates.

## Fixed first-iteration scope and fooling ledger

- Every TCP fake in these candidates uses tcp_ts=-1000. Every multisplit uses tcp_ts_up; SAFE and BALANCED use the zero overlap pattern, while AGGRESSIVE uses the documented tls_max overlap pattern.
- General HTTP, general TLS, Google/YouTube TLS, Discord media TLS and IPSet TCP profiles use out-range=-d10. QUIC and IPSet UDP use out-range=-d5. Optional game profiles remain disabled by the port-12 sentinel; their ranges are -d4 if explicitly enabled in a separate game test.
- Discord Voice is scoped to UDP 19294-19344 and 50000-50100 plus discord/stun L7 and discovery/STUN payload filters. It has no broad UDP fallback and must be evaluated only through a fresh connection.
- SAFE changes the low-intervention fake/repeat/split group, BALANCED changes the moderate repeat/split group, and AGGRESSIVE changes the tls_max/repeat/overlap group. A later iteration must change only one of these groups and add a dated result row rather than silently rewriting this baseline.
