#!/usr/bin/env python3
import os
import shlex
import shutil
import subprocess
import sys
import venv
from pathlib import Path


def install():
    root = Path(__file__).resolve().parent
    python = root / ".venv/bin/python"
    if not python.exists():
        venv.create(root / ".venv", with_pip=True)
    subprocess.run([str(python), "-m", "pip", "install", "-r", str(root / "requirements.txt")], check=True)
    subprocess.run([str(python), str(root / "cx.py"), "--version"], check=True)
    target = Path.home() / ".local/bin/cx"
    if target.exists() or target.is_symlink():
        codex = shutil.which("codex")
        original_alias = target.is_symlink() and codex and target.resolve() == Path(codex).resolve()
        our_launcher = target.is_file() and not target.is_symlink() and "# cx launcher\n" in target.read_text()
        if not original_alias and not our_launcher:
            sys.exit("Refusing to replace an existing cx command that this installer does not own.")
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_name(f".cx-{os.getpid()}")
    temporary.write_text(f'#!/bin/sh\n# cx launcher\nexec {shlex.quote(str(python))} {shlex.quote(str(root / "cx.py"))} "$@"\n')
    temporary.chmod(0o755)
    temporary.replace(target)
    print(f"Installed cx from {root}")


if __name__ == "__main__":
    install()
