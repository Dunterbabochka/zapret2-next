"""Validate the public engine configs and ALT13 packet ordering without interception."""
from pathlib import Path
import argparse
import ctypes
import os
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'runtime' / 'preset-smoke'
PRESETS = ['general', 'ALT', 'ALT3', 'ALT5', 'ALT11', 'ALT12', 'ALT13', 'EXP',
           'FAKE TLS AUTO ALT2', 'NEXT SAFE', 'NEXT BALANCED']


def run(args):
    environment = os.environ.copy()
    is_engine = Path(args[0]).name.lower() == 'winws2.exe'
    if is_engine:
        # Avoid a UAC prompt for dry-run; Lua startup still requires an admin token.
        # Suppress the executable's elevation manifest for this child process only.
        environment['__COMPAT_LAYER'] = 'RunAsInvoker'
    deadline = time.monotonic() + 60
    for attempt in range(1, 4):
        result = subprocess.run(args, cwd=ROOT, capture_output=True, text=True,
                                errors='replace', timeout=max(0, deadline - time.monotonic()),
                                env=environment, creationflags=subprocess.CREATE_NO_WINDOW)
        # STATUS_DLL_INIT_FAILED occurs before the executable reads the config.
        # These smoke runs disable interception; retry only this startup failure
        # and keep all attempts inside the original timeout.
        if (is_engine and (result.returncode & 0xFFFFFFFF) == 0xC0000142 and
                attempt < 3 and time.monotonic() + 0.2 < deadline):
            print(f'[WARN] winws2 DLL initialization failed (0xC0000142); retrying smoke ({attempt + 1}/3).', flush=True)
            time.sleep(0.2)
            continue
        if result.returncode:
            raise RuntimeError(f'{args[0]} exited {result.returncode}\n{result.stdout}\n{result.stderr}')
        return result.stdout + result.stderr


def render(preset, suffix, *options):
    config = OUT / f'{preset.replace(" ", "_")}-{suffix}.txt'
    run(['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
         str(ROOT / 'utils/render-config.ps1'), '-Preset', preset, '-Output', str(config),
         '-GameMode', 'all', '-IPSetMode', 'loaded', '-VoiceMode', 'compatible', *options])
    return config


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--arguments-only', action='store_true',
                        help='Skip Lua startup, which still requires WinDivert access on Windows.')
    options = parser.parse_args()
    if not options.arguments_only and not ctypes.windll.shell32.IsUserAnAdmin():
        raise SystemExit('Lua startup requires Administrator rights on Windows. Use --arguments-only for dry-run checks.')
    OUT.mkdir(parents=True, exist_ok=True)

    for preset in PRESETS:
        modes = [('dry', ('-DryRun', '-InterceptOff'))]
        if not options.arguments_only:
            modes.append(('lua', ('-InterceptOff',)))
        for kind, switches in modes:
            config = render(preset, kind, *switches)
            log = run([str(ROOT / 'bin/winws2.exe'), f'@{config}'])
            (OUT / f'{preset.replace(" ", "_")}-{kind}.log').write_text(log, encoding='utf-8')
        # These values come from the original ALT13/EXP command-line strategies.
        # Verify the behaviors most likely to get lost in a Zapret 1 -> 2 translation.
        text = config.read_text(encoding='utf-8')
        if preset == 'ALT13':
            assert '--lua-desync=next_hostfakesplit:host=mail.ru:tcp_ts=-1000:tcp_ts_up:repeats=5' in text
            assert '--lua-desync=fake:blob=tls_google:tcp_ts=-1000:repeats=7' in text
            assert '--lua-desync=fake:blob=discord_voice:repeats=5' in text
        if preset == 'EXP':
            assert '--filter-l7=quic' in text
            assert '--hostlist-exclude-domains=fonts.googleapis.com' in text
            assert '--lua-desync=multisplit:pos=1:seqovl=480:seqovl_pattern=stun2:tcp_ts_up' in text
            assert '--lua-desync=fake:blob=unknown_tcp:tcp_ts=-1000:repeats=8:payload=unknown' in text
            assert '--lua-desync=fake:blob=quic_4pda:repeats=5:payload=all' in text
            assert '--lua-desync=fake:blob=game_udp:repeats=5:payload=all' in text
        print(f'[OK] {preset}: arguments and blobs' + ('' if options.arguments_only else ', Lua load'), flush=True)

    for role in ('SAFE', 'BALANCED', 'AGGRESSIVE'):
        canonical = render(f'NEXT {role}', 'alias', '-InterceptOff').read_bytes()
        legacy = render(f'CUSTOM {role}', 'alias', '-InterceptOff').read_bytes()
        assert canonical == legacy, f'CUSTOM {role} alias changed behavior'
    print('[OK] All three legacy CUSTOM aliases render identical NEXT configs', flush=True)

    if options.arguments_only:
        print('[SKIP] Engine Lua initialization and packet-order test require WinDivert access on Windows.')
        return

    config = render('ALT13', 'packet-order', '-InterceptOff')
    with config.open('a', encoding='utf-8') as stream:
        stream.write(f'\n--lua-init=@"{(ROOT / "packaging/test-hostfakesplit.lua").as_posix()}"\n')
    log = run([str(ROOT / 'bin/winws2.exe'), f'@{config}'])
    assert 'ALT13 altorder=1 offline regression passed' in log, log
    print('[OK] ALT13 packet order, fooling, replay, failed sends and bypass cases', flush=True)


if __name__ == '__main__':
    main()
