#!/usr/bin/env python3
import json
import os
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def checkout(root):
    # An install from a scratch worktree must not leave the launcher on it: the worktree is deleted once its work lands.
    for folder in (root, *root.parents):
        git = folder / '.git'
        if git.is_file():
            pointer = git.read_text().strip().removeprefix('gitdir: ')
            if '/.git/worktrees/' in pointer:
                main = (folder / pointer.split('/.git/worktrees/')[0]).resolve() / root.relative_to(folder)
                if (main / 'cx.py').exists():
                    return main
        if git.exists():
            break
    return root


def install():
    root = Path(__file__).resolve().parent
    target = Path.home() / 'Applications/Vibe Code X.app'
    launchers = [Path.home() / '.local/bin' / name for name in ('vcx', 'cx')]
    codex = shutil.which('codex')
    for launcher in launchers:
        if launcher.exists() or launcher.is_symlink():
            alias = launcher.is_symlink() and codex and launcher.resolve() == Path(codex).resolve()
            owned = launcher.is_file() and not launcher.is_symlink() and any(marker in launcher.read_text() for marker in ('# cx launcher\n', '# vcx launcher\n'))
            if not alias and not owned:
                raise SystemExit(f'Refusing to replace an unrelated command: {launcher.name}')
    if target.exists():
        try:
            info = plistlib.loads((target / 'Contents/Info.plist').read_bytes())
        except (OSError, ValueError):
            raise SystemExit('Refusing to replace an unrelated application.')
        if info.get('CFBundleIdentifier') != 'com.mr.vcx':
            raise SystemExit('Refusing to replace an unrelated application.')
    subprocess.run([str(root / 'build.sh')], check=True)

    source = root / 'dist/Vibe Code X.app'
    target.parent.mkdir(parents=True, exist_ok=True)
    backup = target.with_name(f'.VCX-backup-{os.getpid()}.app')
    lsregister = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
    with tempfile.TemporaryDirectory(prefix='.VCX-install-', dir=target.parent) as directory:
        staging = Path(directory) / target.name
        try:
            subprocess.run(['/usr/bin/ditto', str(source), str(staging)], check=True)
            subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(staging)], check=True)
            subprocess.run([str(staging / 'Contents/MacOS/VCX'), '--version'], check=True)
            subprocess.run([str(staging / 'Contents/MacOS/VCX'), '--check'], check=True)
            had_target = target.exists()
            if had_target:
                target.rename(backup)
            try:
                staging.rename(target)
            except OSError:
                if had_target:
                    backup.rename(target)
                raise
            if had_target:
                shutil.rmtree(backup)
        finally:
            subprocess.run([lsregister, '-u', str(staging)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run([lsregister, '-f', str(target)], check=True)
    binary = target / 'Contents/MacOS/VCX'

    terminal = checkout(root)
    python = terminal / '.venv/bin/python'
    script = f'''#!/bin/sh
# vcx launcher
background=-g
for argument in "$@"; do
  case "$argument" in
    --focus) background= ;;
    -p|--print|--headless|--ensure-qwen) exec /usr/bin/python3 {shlex.quote(str(target / 'Contents/Resources/background.py'))} "$@" ;;
  esac
done
case "$1" in
  --terminal)
    shift
    if [ ! -x {shlex.quote(str(python))} ]; then
      python3 -m venv {shlex.quote(str(terminal / '.venv'))} || exit 1
      {shlex.quote(str(python))} -m pip install -r {shlex.quote(str(terminal / 'requirements.txt'))} || exit 1
    fi
    exec {shlex.quote(str(python))} {shlex.quote(str(terminal / 'cx.py'))} "$@"
    ;;
  --send|--set-model|--sessions|--version|--help|--check|--bug-check|--runtime-check|--runtime-protocol|--frontend-check|--runtime-bounds-check|--runtime-recovery-check|--runtime-load-check|--verify-runtime|--update-now)
    exec {shlex.quote(str(binary))} "$@"
    ;;
esac
exec /usr/bin/open -n $background -a {shlex.quote(str(target))} --args --cwd "$PWD" "$@"
'''
    for launcher in launchers:
        launcher.parent.mkdir(parents=True, exist_ok=True)
        temporary = launcher.with_name(f'.{launcher.name}-{os.getpid()}')
        temporary.write_text(script)
        temporary.chmod(0o755)
        temporary.replace(launcher)
    settings = Path.home() / 'Library/Application Support/VCX/settings.json'
    jarvis = Path.home() / 'self/jarvis/Sources/Jarvis/Windows.swift'
    if not settings.exists() and jarvis.exists():
        text = jarvis.read_text()
        values = {}
        for key, pattern in [('qwenProxy', r'env\["ALL_PROXY"\] = "([^"]+)"'), ('qwenURL', r'private let endpoint = "([^"]+)"'), ('qwenModel', r'static let model = "([^"]+)"')]:
            match = re.search(pattern, text)
            if match:
                values[key] = match[1]
        if values:
            settings.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            fd = os.open(settings, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, 'w') as stream:
                json.dump(values, stream)
    manual = '--manual' in sys.argv[1:]
    subprocess.run([str(binary), '--publish-update'] + (['--manual'] if manual else []), check=True)
    if manual:
        print('Installed Vibe Code X. Running sessions and windows stay on their build until vcx --update-now.')
    else:
        print('Installed Vibe Code X. Compatible open frontends update automatically; agent runtimes keep running.')


if __name__ == '__main__':
    install()
