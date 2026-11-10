#!/usr/bin/env python3
"""Keep one installed Qiming and one Xcode development app; remove generated copies only."""
import argparse
import fcntl
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
INSTALLED = Path('/Applications/Qiming.app')
LSREGISTER = Path('/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister')
IDENTIFIER = 'com.qiming.mac'


def bundle_id(app):
    try:
        return plistlib.loads((app / 'Contents/Info.plist').read_bytes()).get('CFBundleIdentifier')
    except (OSError, plistlib.InvalidFileException):
        return None


def development_app():
    import json
    env = os.environ.copy()
    env.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
    result = subprocess.run(['xcodebuild', '-project', str(ROOT / 'Qiming.xcodeproj'),
        '-scheme', 'Qiming', '-configuration', 'Debug', '-showBuildSettings', '-json'],
        env=env, cwd=ROOT, capture_output=True, text=True, check=True)
    settings = next(item['buildSettings'] for item in json.loads(result.stdout) if item['target'] == 'Qiming')
    return Path(settings['TARGET_BUILD_DIR']) / settings['FULL_PRODUCT_NAME']


def running(app):
    result = subprocess.run(['pgrep', '-f', '^' + re.escape(str(app / 'Contents/MacOS')) + '/'],
                            capture_output=True, text=True)
    if result.returncode not in (0, 1):
        raise RuntimeError('Cannot check running apps: ' + result.stderr.strip())
    return result.returncode == 0


def unregister(app):
    # Remove this path only; never reset the global Launch Services database.
    subprocess.run([str(LSREGISTER), '-u', str(app)], capture_output=True, check=True)


def cleanup(dry_run=False):
    dev = development_app()
    keep = {INSTALLED.resolve(), dev.resolve()}
    roots = [ROOT / 'build', dev.parents[1]]
    candidates = {p for root in roots if root.exists() for p in root.rglob('*.app')}
    for app in sorted(candidates):
        if app.is_symlink() or app.resolve() in keep:
            continue
        known_review = app == ROOT / 'build/GlassMaterialReview.app' and bundle_id(app) == 'com.qiming.glass-review'
        if bundle_id(app) != IDENTIFIER and not known_review:
            continue
        if running(app):
            raise RuntimeError(f'Quit this old build before cleanup: {app}')
        print(('Would remove: ' if dry_run else 'Removing generated copy: ') + str(app))
        if not dry_run:
            unregister(app)
            shutil.rmtree(app)
    print(f'Keep installed: {INSTALLED}')
    print(f'Keep development: {dev}')


def signature_hash(app):
    result = subprocess.run(['codesign', '-d', '--verbose=4', str(app)], capture_output=True, text=True, check=True)
    return next(line for line in result.stderr.splitlines() if line.startswith('CDHash='))


def same_signed_build(source, target):
    if not target.is_dir():
        return False
    try:
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(target)], capture_output=True, check=True)
        return all(signature_hash(source / path) == signature_hash(target / path)
                   for path in (Path('.'), Path('Contents/Library/HelperTools/QimingHelper')))
    except (subprocess.CalledProcessError, StopIteration):
        return False


def install(source):
    source = source.resolve()
    if source.name != 'Qiming.app' or bundle_id(source) != IDENTIFIER:
        raise RuntimeError(f'Not a Qiming Release app: {source}')
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(source)], check=True)
    if same_signed_build(source, INSTALLED):
        print('Installed Qiming already matches this signed build; keeping its existing location.')
        return
    if running(INSTALLED):
        raise RuntimeError('Quit Qiming before replacing /Applications/Qiming.app. The installed app was not changed.')
    if INSTALLED.is_symlink() or (INSTALLED.exists() and bundle_id(INSTALLED) != IDENTIFIER):
        raise RuntimeError('Refusing to replace an unexpected /Applications/Qiming.app.')
    # Prepare and verify first, then replace the old app. The staging directory is not indexed.
    staging = Path(tempfile.mkdtemp(prefix='.Qiming-update-', suffix='.noindex', dir=INSTALLED.parent))
    staged = staging / 'Qiming.app'
    previous = staging / 'Previous.app'
    try:
        subprocess.run(['/usr/bin/ditto', str(source), str(staged)], check=True)
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(staged)], check=True)
        if INSTALLED.exists():
            INSTALLED.rename(previous)
        try:
            staged.rename(INSTALLED)
        except BaseException:
            if previous.exists():
                previous.rename(INSTALLED)
            raise
        if previous.exists():
            shutil.rmtree(previous)
        subprocess.run([str(LSREGISTER), '-f', str(INSTALLED)], capture_output=True, check=True)
        print(f'Updated in place: {INSTALLED}')
    finally:
        # Retain the old app if a rollback itself failed.
        if not previous.exists():
            shutil.rmtree(staging)


def verify_startup():
    if running(INSTALLED):
        raise RuntimeError('Quit Qiming before verifying the installed build on startup.')
    with tempfile.TemporaryDirectory(prefix='qiming-update-') as directory:
        receipt = Path(directory) / 'status.txt'
        subprocess.run(['/usr/bin/open', '-a', str(INSTALLED), '--args', '--update-receipt', str(receipt)], check=True)
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            if receipt.is_file():
                result = receipt.read_text(encoding='utf-8')
                if result == 'OK\n':
                    print('Update complete: the installed Qiming received a healthy helper status reply.')
                    return
                raise RuntimeError('Helper startup verification failed: ' + result.removeprefix('ERROR\n').strip())
            time.sleep(0.25)
    raise RuntimeError('No helper status receipt from the installed Qiming within 45 seconds.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    clean = commands.add_parser('cleanup')
    clean.add_argument('--dry-run', action='store_true')
    deploy = commands.add_parser('install')
    deploy.add_argument('source', type=Path)
    commands.add_parser('verify-startup')
    run = commands.add_parser('run')
    run.add_argument('argv', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if os.environ.get('QIMING_BUILD_LOCK_HELD') != '1':
        # Serialize managed builds/tests/cleanup so one job cannot delete another's app mid-build.
        lock_path = ROOT / 'build/.qiming-build.lock'
        lock_path.parent.mkdir(parents=True, exist_ok=True)
        with lock_path.open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            env = os.environ.copy()
            env['QIMING_BUILD_LOCK_HELD'] = '1'
            command = args.argv if args.command == 'run' else [sys.executable, str(Path(__file__).resolve()), *sys.argv[1:]]
            if not command:
                parser.error('run requires a command')
            raise SystemExit(subprocess.run(command, cwd=ROOT, env=env).returncode)
    if args.command == 'run':
        if not args.argv:
            parser.error('run requires a command')
        raise SystemExit(subprocess.run(args.argv, cwd=ROOT).returncode)
    if args.command == 'install':
        install(args.source)
    elif args.command == 'verify-startup':
        verify_startup()
    else:
        cleanup(args.dry_run)


if __name__ == '__main__':
    main()
