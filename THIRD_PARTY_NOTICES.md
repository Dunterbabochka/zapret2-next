# Third-party notices

Zapret 2 NEXT distributes and/or adapts components from the following projects. Their names are retained here for license compliance, not to imply endorsement.

## zapret / zapret2

Copyright (c) 2016-2026 bol-van. Licensed under the MIT License.

Source: https://github.com/bol-van/zapret2

The `winws2.exe` binary, official Lua libraries, filter examples and fake payload files in this distribution originate from Zapret 2 v1.0.5.2.

The additional `quic_initial_dbankcloud_ru.bin` and `tls_clienthello_max_ru.bin` payloads are retained from the MIT-licensed Windows bundle identified below for ALT12 compatibility. The `tls_clienthello_max_ru.bin` file was copied from the local Flowseal reference snapshot on 2026-07-15; its SHA256 is 4EE0870ABE0A0128600B0095189987BA1D210DAE8BF963BC725AFF49CF922624.

The opt-in UDP fake selector also includes two payloads copied from the local Flowseal 1.10.1 reference snapshot on 2026-08-16. They remain disabled by default: `quic_initial_steamcommunity_com.bin` (SHA256 `2FE18B3BD20807D36704D0B072092EE49AE84EDCA907A4420AB9A0F0F28FDDCF`) and `quic_initial_dbankcloud_ru_v2.bin` (SHA256 `E065870CB0D13152E6132807BBF42218A9E7CD8D96F5602B61674CC540F3A56E`).

## Reused Windows bundle code

On 2026-10-23, the 22 Classic references were refreshed from the verified
Flowseal 1.10.4 tag (176f56dc3f11ce5915c26abcdde903f93d835b64). Fifteen presets
change their fake references from Max to Sferum, retaining the source packet
cutoffs, repeats and overlap sizes. The seven additional TLS/QUIC payloads,
the bundled IPSet, lesta.pw exclusion and Happ detection derive from that
MIT-licensed reference. Their hashes are recorded in SHA256SUMS.txt and
the command-file provenance in packaging/classic-reference.json. The
Zapret 2 engine and pinned upstream Lua libraries were not replaced.

Copyright (c) 2016-2026 bol-van  
Copyright (c) 2024-2026 Flowseal

Portions of the Windows menu, diagnostics and testing workflow were adapted under the MIT License. The original MIT copyright and permission notice is preserved by this notice and the accompanying license text.

On 2026-10-02, the local Flowseal 1.10.3 reference was compared with this bundle.
The `zendesk.com` and `live-video.net` hostlist entries were carried over while
preserving this project's existing entries. No additional engine binary or
Zapret 1 command-line preset was imported during that comparison.

On 2026-10-11, ALT13 and EXP were adapted from the local Flowseal 1.10.3
reference to native Zapret 2 Lua actions. `lua/zapret-next.lua` derives the
legacy altorder=1 host splitting sequence from bol-van's MIT-licensed
`hostfakesplit`; the pinned upstream Lua files are unchanged. The following
additional payloads were copied byte-for-byte from that reference:

- `tls_clienthello_sochi_park.bin`: SHA256 `AD552922ACFE029521DA884EA29F4BB28BB6BDCEE9B1A70B46ADBFD266C11D4D`.
- `stun2.bin`: SHA256 `B7C2497496039C541F7337AC8536813F0A1CF52363AB2FAA5213B7816D458813`.
- `quic_initial_4pda_to.bin`: SHA256 `E065870CB0D13152E6132807BBF42218A9E7CD8D96F5602B61674CC540F3A56E`.

On 2026-10-19, all 22 Classic presets were adapted from the same local Flowseal 1.10.3 reference, alongside its additional hostlist entries and diagnostic checks. Source command-file SHA256 values are recorded in `packaging/classic-reference.json`. Engine binaries and the pinned upstream Lua libraries were not replaced. Additional fake payloads, also available through the manual UDP selector, are:

- `quic_initial_5ka_ru.bin`: SHA256 `247DCD97F53BFAE5482E4B2B66ACDB01E48EE6C29C5CA526C9B241FA38C233B5`.
- `quic_initial_rutube_ru.bin`: SHA256 `74B1DFBDEC125263C9407436658B0A848B8F0A934B8063D11571A6A2146A4A7B`.
- `quic_initial_tencent_com.bin`: SHA256 `D250051D6200946A7BA0629C59C5641432957FA3513081A6C3C5AAA91A62AC03`.
- `tls_clienthello_4pda_to.bin`: SHA256 `EEFEAF09DDE8D69B1F176212541F63C68B314A33A335ECED99A8A29F17254DA8`.
- `tls_clienthello_5ka_ru.bin`: SHA256 `1E8871E272591C5A277D38A6166AF597C1FECB1CF58E85162E8F1968EC08D018`.
- `tls_clienthello_www_sferum_ru.bin`: SHA256 `E6DD8D724EECC6A7340BF64E2EBEC81C60BC4E078C6F702B4B6BA9BF184180AD`.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Telegram MTProto-to-WebSocket proxy

Copyright (c) 2026 Flowseal. Licensed under the MIT License.

Source: https://github.com/Flowseal/tg-ws-proxy

The optional `bin/telegram/zapret-telegram.exe` component adapts the headless
MTProto-to-WebSocket proxy core from `tg-ws-proxy` v1.11.1, pinned to commit
`18175fb4fe567cf6aef61f9d883eff010c9e66a8`. This bundle provides its own launcher,
configuration, diagnostics and Windows logon task management. The original MIT
copyright and permission notice is preserved in
`packaging/third_party/tg-ws-proxy/LICENSE` in the source checkout
(or `docs/third_party/tg-ws-proxy/LICENSE` in a release archive); its text accompanies the released component.

The frozen executable includes CPython, governed by the Python Software
Foundation License, and cryptography dependencies distributed under their own
licenses. The component's packaged license files are retained alongside the
executable. PyInstaller's bootloader is distributed under GPL with its exception
for generated executable bundles; the application code retains its own license.

## WinDivert

WinDivert is distributed under the user's choice of LGPLv3 or GPLv2.

Source and license: https://github.com/basil00/WinDivert

The included `WinDivert.dll` and `WinDivert64.sys` are unmodified binaries supplied with the pinned upstream Zapret 2 release.

## Cygwin runtime

The included `cygwin1.dll` is governed by the GNU GPL and the Cygwin linking exception.

Source and license information: https://cygwin.com/licensing.html

## dpi-checkers

The optional DPI test target list is obtained from `hyperion-cs/dpi-checkers`, licensed under Apache-2.0.

Source: https://github.com/hyperion-cs/dpi-checkers
