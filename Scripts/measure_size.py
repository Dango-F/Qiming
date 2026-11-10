#!/usr/bin/env python3
"""Count the entire app, including embedded helper and localization resources."""
import json
import subprocess
import sys
from pathlib import Path

app = Path(sys.argv[1] if len(sys.argv) > 1 else '/Applications/Qiming.app').resolve()
if not app.is_dir():
    raise SystemExit(f'App not found: {app}')
archive = Path(__file__).resolve().parent.parent / 'build/artifacts/Qiming-local-development.zip'
archive.parent.mkdir(parents=True, exist_ok=True)
subprocess.run(['/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(archive)], check=True)
files = [p for p in app.rglob('*') if p.is_file()]
logical = sum(p.stat().st_size for p in files)
allocated = sum(p.stat().st_blocks * 512 for p in app.rglob('*'))
report = {'app': str(app), 'architecture': 'arm64', 'installed_logical_bytes': logical,
          'allocated_bytes': allocated, 'download_bytes': archive.stat().st_size,
          'installed_within_5_MB': logical <= 5_000_000, 'download_within_3_MB': archive.stat().st_size <= 3_000_000,
          'includes': ['main executable', 'embedded helper', 'launch daemon plist', 'all localization resources', 'compiled app icon (Assets.car and AppIcon.icns)'],
          'signing': 'Local development build; Developer ID / notarization not performed'}
print(json.dumps(report, ensure_ascii=False, indent=2))
if not report['installed_within_5_MB'] or not report['download_within_3_MB']:
    raise SystemExit(1)
