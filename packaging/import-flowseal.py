"""Import a local Flowseal Windows bundle as explicit Zapret 2 Lua presets.

Usage: python packaging/import-flowseal.py --source PATH
The source is read only. Engine binaries and mutable ACTIVE_* files are not copied.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def options(line):
    result = {}
    for match in re.finditer(r'--([\w-]+)(?:=("[^"]*"|[^\s]+))?', line):
        result.setdefault(match[1], []).append((match[2] or '').strip('"'))
    return result


def translate(source):
    blobs = {}

    def blob(value):
        if value.startswith('0x'):
            return value
        if value == '^!':
            return 'classic_clone'
        name = value.replace('%BIN%', '')
        if name.startswith('ACTIVE_DISCORD'):
            return 'discord_voice'
        if name.startswith('ACTIVE_GAME'):
            return 'game_udp'
        aliases = {'tls_clienthello_www_google_com.bin': 'tls_google',
                   'tls_clienthello_max_ru.bin': 'tls_max', 'stun.bin': 'stun',
                   'quic_initial_www_google_com.bin': 'quic_google',
                   'stun2.bin': 'stun2', 'quic_initial_4pda_to.bin': 'quic_4pda'}
        key = aliases.get(name, 'classic_' + name.removesuffix('.bin'))
        blobs[key] = name
        return key

    def actions(p, payload, udp=False):
        get = lambda key, default='': p.get('dpi-desync-' + key, [default])[-1]
        modes = p.get('dpi-desync', [''])[0].split(',')
        repeats = get('repeats', '1')
        fool = []
        for method in get('fooling').split(','):
            if method == 'ts': fool.append('tcp_ts=' + get('ts-increment', '-600000'))
            elif method == 'badseq': fool.extend(['tcp_seq=' + get('badseq-increment', '-10000'), 'tcp_ack=' + get('badack-increment', '-66000')])
            elif method == 'md5sig': fool.append('tcp_md5')
            elif method: raise ValueError('Unsupported fooling: ' + method)
        if p.get('ip-id'): fool.append('ip_id=' + p['ip-id'][0])
        if fool: fool.append('tcp_ts_up')
        result = []
        if 'syndata' in modes:
            result += ['--payload=empty', '--lua-desync=syndata', '--payload=' + payload]
        if 'fake' in modes:
            defaults = {'http': 'fake_default_http', 'tls': 'fake_default_tls',
                        'unknown': '0x' + '00' * 256, 'unknown-udp': 'game_udp',
                        'discord': 'discord_voice', 'stun': 'discord_voice', 'quic': 'quic_google'}
            kind = {'http_req': 'http', 'tls_client_hello': 'tls', 'discord_ip_discovery': 'discord'}.get(payload, payload)
            values = p.get('dpi-desync-fake-' + kind, [defaults[kind]])
            for value in values:
                fake = blob(value) if value not in defaults.values() else value
                if fake == 'classic_clone': result.append('--lua-desync=tls_client_hello_clone:blob=classic_clone:fallback=tls_google')
                args = ['blob=' + fake, 'repeats=' + repeats] + fool
                mods = get('fake-tls-mod')
                if kind == 'tls' and mods and mods != 'none': args.append('tls_mod=' + mods)
                if kind == 'unknown': args.append('payload=unknown')
                elif kind == 'unknown-udp': args.append('payload=unknown' if 'filter-l7' in p else 'payload=all')
                result.append('--lua-desync=fake:' + ':'.join(args))
        for mode in modes:
            if mode in ('fake', 'syndata', ''): continue
            args = []
            if mode in ('multisplit', 'multidisorder', 'fakedsplit'):
                args.append('pos=' + get('split-pos', '2'))
                if get('split-seqovl'): args.append('seqovl=' + get('split-seqovl'))
                if get('split-seqovl-pattern'): args.append('seqovl_pattern=' + blob(get('split-seqovl-pattern')))
                if mode == 'fakedsplit': args.append('pattern=' + blob(get('fakedsplit-pattern', '0x00')))
                if mode == 'multidisorder': mode = 'multidisorder_legacy'
                if mode == 'fakedsplit': args += fool + ['repeats=' + repeats]
                elif p.get('ip-id'): args.append('ip_id=' + p['ip-id'][0])
                if 'tcp_ts_up' not in args: args.append('tcp_ts_up')
            elif mode == 'hostfakesplit':
                mods = dict(item.split('=', 1) for item in get('hostfakesplit-mod', 'host=www.google.com').split(','))
                args += ['host=' + mods['host']] + fool + ['repeats=' + repeats]
                if mods.get('altorder') == '1': mode = 'next_hostfakesplit'
            else: raise ValueError('Unsupported desync: ' + mode)
            result.append('--lua-desync=' + mode + ':' + ':'.join(args))
        return result

    profiles = [options(line) for line in source.splitlines() if line.startswith('--filter-')]
    udp = [p for p in profiles if 'filter-udp' in p]
    tcp = [p for p in profiles if 'filter-tcp' in p]
    general = next((p for p in tcp if p.get('filter-tcp') == ['80,443'] and 'hostlist' in p), tcp[0])
    # ALT5 uses one combined HTTP/TLS profile without separate Google/media rules.
    media = next((p for p in tcp if 'hostlist-domains' in p), general)
    google = next((p for p in tcp if any('list-google' in v for v in p.get('hostlist', []))), general)
    ipset = next((p for p in tcp if 'ipset' in p and p['filter-tcp'][0] != '%GameFilterTCP%'), general)
    game = next(p for p in tcp if p['filter-tcp'][0] == '%GameFilterTCP%')
    quic = next((p for p in profiles if p.get('filter-l7') == ['quic']), next(p for p in udp if p.get('filter-udp') == ['443']))
    voice = next(p for p in udp if p.get('filter-l7', [''])[0].startswith('discord'))
    game_udp = next(p for p in udp if p['filter-udp'][0] == '%GameFilterUDP%')

    def mixed(p, unknown=False):
        result = []
        seen_syn = False
        for payload in ['http_req', 'tls_client_hello'] + (['unknown'] if unknown else []):
            translated = actions(p, payload)
            if translated[:2] == ['--payload=empty', '--lua-desync=syndata']:
                if seen_syn: translated = translated[2:]
                seen_syn = True
            result += ['--payload=' + payload] + translated
        return result

    sections = {'TCP_HTTP': actions(general, 'http_req'), 'TCP_TLS': actions(general, 'tls_client_hello'),
                'DISCORD_MEDIA_TLS': actions(media, 'tls_client_hello'), 'GOOGLE_TLS': actions(google, 'tls_client_hello'),
                'TCP_GENERIC': mixed(ipset), 'QUIC': actions(quic, 'quic', True),
                'IPSET_TCP_PORTS': [port for port in ipset['filter-tcp'][0].split(',') if port not in ('80','443')],
                'VOICE_COMPATIBLE': ['--filter-udp=' + voice['filter-udp'][0], '--filter-l7=' + voice['filter-l7'][0]]}
    if voice.get('dpi-desync-cutoff'): sections['VOICE_COMPATIBLE'].append('--out-range=<' + voice['dpi-desync-cutoff'][0])
    for payload in ['discord_ip_discovery', 'stun']:
        sections['VOICE_COMPATIBLE'] += ['--payload=' + payload] + actions(voice, payload, True)
    if 'unknown' in voice['filter-l7'][0]:
        sections['VOICE_COMPATIBLE'] += ['--payload=unknown'] + actions(voice, 'unknown-udp', True)
    sections['GAME_TCP_RANGE'] = ['<' + game.get('dpi-desync-cutoff', ['n4'])[0]]
    sections['GAME_TCP_ACTIONS'] = mixed(game, True)
    sections['GAME_UDP_RANGE'] = ['<' + game_udp.get('dpi-desync-cutoff', ['n4'])[0]]
    sections['GAME_UDP_ACTIONS'] = actions(game_udp, 'unknown-udp', True)
    if quic.get('filter-l7'):
        sections['QUIC_FILTER'] = (['--filter-udp=' + quic['filter-udp'][0]] if 'filter-udp' in quic else []) + ['--filter-l7=' + quic['filter-l7'][0]]
    if 'filter-l3' in general:
        sections['CLASSIC_TCP_PROFILE'] = ['--filter-l3=' + general['filter-l3'][0], '--filter-tcp=' + general['filter-tcp'][0],
            '--hostlist-exclude=../lists/list-exclude.txt', '--hostlist-exclude=../lists/list-exclude-user.txt',
            '--ipset-exclude=../lists/ipset-exclude.txt', '--ipset-exclude=../lists/ipset-exclude-user.txt',
            '--payload=empty', '--lua-desync=syndata', '--payload=http_req,tls_client_hello,unknown', '--lua-desync=multidisorder_legacy:pos=2']
    for protocol, p in [('TCP', ipset), ('UDP', next(p for p in udp if 'ipset' in p and p['filter-udp'][0] == '443'))]:
        if p.get('hostlist-exclude-domains'): sections['IPSET_' + protocol + '_EXCLUDE'] = ['--hostlist-exclude-domains=' + ','.join(p['hostlist-exclude-domains'])]
    base_blobs = {'tls_google', 'tls_max', 'quic_google', 'stun'}
    sections = {'PRESET_INIT': ['--lua-init=@../lua/zapret-next.lua'] + ['--blob=' + key + ':@fake/' + name for key, name in sorted(blobs.items()) if key not in base_blobs], **sections}
    return '\n'.join('[' + name + ']\n' + '\n'.join(lines) for name, lines in sections.items() if lines) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    args = parser.parse_args()
    provenance = []
    for path in sorted(args.source.glob('general*.bat')):
        name = 'general' if path.stem == 'general' else path.stem[9:-1]
        source = path.read_text(encoding='utf-8-sig')
        content = '# Classic reference: local Windows bundle 1.10.3; see docs/CLASSIC.md.\n' + translate(source)
        (ROOT / 'presets' / (name + '.txt.in')).write_text(content, encoding='utf-8')
        launcher = ROOT / 'strategies' / path.name
        launcher.write_bytes(('@echo off\r\ncall "%~dp0..\\utils\\run-preset.bat" "' + name + '"\r\n').encode())
        provenance.append({'preset': name, 'sourceFile': path.name, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()})
    for path in (args.source / 'bin').glob('*.bin'):
        if not path.name.startswith('ACTIVE_'):
            target = ROOT / 'bin' / 'fake' / path.name
            if target.exists() and target.read_bytes() != path.read_bytes(): raise ValueError('Bundled blob differs: ' + path.name)
            target.write_bytes(path.read_bytes())
    (ROOT / 'packaging' / 'classic-reference.json').write_text(json.dumps(provenance, indent=2) + '\n', encoding='utf-8')
    print('Imported', len(provenance), 'Classic presets')


if __name__ == '__main__':
    main()
