"""Compare frozen boot/import cost without starting a proxy or making requests.

Use the pinned build environment from packaging/telegram-requirements.txt.
This measures --self-test, not listener readiness or cold boot performance.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import statistics
import subprocess
import sys
import time
import uuid


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--runs', type=int, default=10)
    args = parser.parse_args()
    if args.runs < 1:
        parser.error('--runs must be positive')
    root = Path(__file__).resolve().parents[1]
    output = root / 'runtime' / ('telegram-layout-' + uuid.uuid4().hex)
    output.mkdir(parents=True)
    results = {'kind': 'warm frozen --self-test; no proxy, listeners or network', 'layouts': {}}
    for layout in ('onefile', 'onedir'):
        directory = output / layout
        build = subprocess.run([sys.executable, str(root / 'packaging/build-telegram.py'),
                                '--layout', layout, '--output', str(directory)],
                               capture_output=True, text=True)
        (output / (layout+'-build.log')).write_text(build.stdout+'\n'+build.stderr, encoding='utf-8')
        if build.returncode:
            results['layouts'][layout] = {'status': 'build unavailable', 'exit': build.returncode}
            continue
        executable = directory / ('zapret-telegram.exe' if layout == 'onefile' else 'zapret-telegram/zapret-telegram.exe')
        samples = []
        for index in range(args.runs):
            report = output / f'{layout}-{index}.json'
            started = time.perf_counter()
            subprocess.run([str(executable), '--self-test', '--output', str(report)], check=True, timeout=45)
            samples.append((time.perf_counter()-started)*1000)
            if not json.loads(report.read_text(encoding='utf-8')).get('ok'):
                raise RuntimeError('Frozen self-test failed')
        ordered = sorted(samples)
        results['layouts'][layout] = {'status': 'measured', 'samples_ms': samples,
                                     'median_ms': statistics.median(samples),
                                     'p95_ms': ordered[max(0, int(len(samples)*.95+.999)-1)],
                                     'bytes': sum(p.stat().st_size for p in directory.rglob('*') if p.is_file())}
    path = output / 'results.json'
    path.write_text(json.dumps(results, indent=2), encoding='utf-8')
    print(json.dumps(results, indent=2))
    print(path)


if __name__ == '__main__':
    main()
