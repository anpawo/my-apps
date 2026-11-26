#!/usr/bin/env python3
"""The switch of the vcx command between the Swift app and VCX Rust, run on isolated folders: his ~/.local/bin/vcx,
the mac.vcx-update job and the Swift app's state are only read. launchctl is a stub that logs its calls, and the
launcher's `open` is a stub that starts the installed VCX Rust binary windowless, its sessions on the bundle's Rust
worker talking to the fixture agent. Run: python3 vcx/rust/launchers/test_switch.py
"""
import json
import os
import shutil
import signal
import socket
import subprocess
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SWITCH = HERE / 'switch.sh'
HOME = Path.home()
REAL_LAUNCHER = HOME / '.local/bin/vcx'
RUST_APP = HOME / 'Applications/VCX Rust.app'
SWIFT_APP = HOME / 'Applications/Vibe Code X.app'
FIXTURE = HERE.parent / 'fixtures/fake_agent.py'
SERVICE = f'gui/{os.getuid()}/mac.vcx-update'
WAIT = 60
POLL = 0.2
SOCKET_WAIT = 90

# Starts what the launcher asked of `open` without LaunchServices: the app binary, windowless, detached, its pid kept.
OPEN_RUST = '''#!/bin/sh
root="$(dirname "$(dirname "$0")")"
while [ "$1" != --args ]; do shift; done
shift
nohup "$VCX_TEST_BINARY" --windowless "$@" >> "$root/app.log" 2>&1 &
echo $! >> "$root/app.pids"
'''
# Records what the launcher asked of `open`, and starts nothing.
OPEN_RECORD = '''#!/bin/sh
root="$(dirname "$(dirname "$0")")"
printf '%s\\n' "$@" > "$root/open.args"
'''


class Switch(unittest.TestCase):
    def setUp(self):
        if not REAL_LAUNCHER.is_file() or b'Vibe Code X.app' not in REAL_LAUNCHER.read_bytes():
            self.skipTest('his ~/.local/bin/vcx is not the Swift launcher: nothing to start from')
        # Unix socket paths are capped near 104 bytes, so the folders sit in /tmp.
        self.root = Path(f'/tmp/vcxl-{os.getpid()}-{self._testMethodName[-8:]}')
        shutil.rmtree(self.root, ignore_errors=True)
        for name in ('bin', 'stub', 'shared', 'config', 'state', 'update', 'work'):
            (self.root / name).mkdir(parents=True, mode=0o700)
        self.swift = REAL_LAUNCHER.read_bytes()
        (self.root / 'bin/vcx').write_bytes(self.swift)
        (self.root / 'bin/vcx').chmod(0o755)
        self.stub('launchctl', '#!/bin/sh\necho "$*" >> "$(dirname "$(dirname "$0")")/launchctl.log"\n')
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(('VCX_', 'CLAUDE_CODE_SESSION_ID')) and k not in ('PWD', 'OLDPWD')}
        self.env.update(
            PATH=f'{self.root}/stub:/usr/bin:/bin:/usr/sbin:/sbin',
            VCX_BIN_HOME=str(self.root / 'bin'), VCX_UPDATE_HOME=str(self.root / 'update'),
            VCX_CONFIG_HOME=str(self.root / 'shared'), VCX_RUST_CONFIG_HOME=str(self.root / 'config'),
            VCX_RUST_STATE_HOME=str(self.root / 'state'), VCX_RUST_RUNTIME_HOME=str(self.root / 'state/runtime'),
            VCX_STATE_HOME=str(self.root / 'worker-state'), VCX_RUNTIME_HOME=str(self.root / 'worker-runtime'),
            VCX_TEST_BINARY=str(RUST_APP / 'Contents/MacOS/vcx-rust'))

    def tearDown(self):
        root = getattr(self, 'root', None)
        if root is None:
            return
        control = root / 'state/control.sock'
        if control.exists():
            ask(control, {'quit': {}})
        pids = root / 'app.pids'
        for pid in (pids.read_text().split() if pids.exists() else []):
            try:
                os.kill(int(pid), signal.SIGKILL)
            except ProcessLookupError:
                pass
        # Workers the app started: every process whose command line names this run's own folder.
        subprocess.run(['/usr/bin/pkill', '-9', '-f', str(root)], capture_output=True)
        shutil.rmtree(root, ignore_errors=True)

    def stub(self, name, text):
        path = self.root / 'stub' / name
        path.write_text(text)
        path.chmod(0o755)

    def switch(self, *arguments):
        return subprocess.run([str(SWITCH), *arguments], env=self.env, capture_output=True, text=True)

    def vcx(self, *arguments, launcher=None, cwd=None):
        return subprocess.run([str(launcher or self.root / 'bin/vcx'), *arguments], env=self.env, cwd=cwd or self.root,
                              capture_output=True, text=True, timeout=SOCKET_WAIT)

    def launchctl(self):
        log = self.root / 'launchctl.log'
        return log.read_text().splitlines() if log.exists() else []

    def with_open(self, text):
        """The launcher now in place, its `open` swapped for a stub (the Swift test does the same)."""
        self.stub('open', text)
        copy = self.root / 'stub/vcx'
        copy.write_text((self.root / 'bin/vcx').read_text().replace('/usr/bin/open', str(self.root / 'stub/open')))
        copy.chmod(0o755)
        return copy

    def folder(self, name):
        path = self.root / 'work' / name
        path.mkdir(parents=True, exist_ok=True)
        return path.resolve()

    def wait(self, what, done):
        deadline = time.monotonic() + WAIT
        last = None
        while time.monotonic() < deadline:
            last = what()
            if done(last):
                return last
            time.sleep(POLL)
        self.fail(f'never reached: {last!r}; app log: {read(self.root / "app.log")}')

    def windows(self):
        answer = ask(self.root / 'state/control.sock', {'report': {}})
        return (answer or {}).get('windows', [])

    def test_to_rust_puts_the_rust_launcher_in_place_and_pauses_the_swift_install_job(self):
        result = self.switch('--to', 'rust')

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / 'bin/vcx').read_bytes(), (HERE / 'vcx').read_bytes())
        self.assertEqual((self.root / 'state/launchers/vcx.swift').read_bytes(), self.swift)
        self.assertEqual(self.launchctl(), [f'disable {SERVICE}', f'print {SERVICE}', f'bootout {SERVICE}'])
        self.assertEqual(self.switch('--status').stdout.strip(), 'vcx starts: rust')

    def test_to_swift_puts_the_swift_launcher_back_byte_for_byte_and_resumes_the_install_job(self):
        self.switch('--to', 'rust')

        result = self.switch('--to', 'swift')

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / 'bin/vcx').read_bytes(), self.swift)
        plist = HOME / 'Library/LaunchAgents/mac.vcx-update.plist'
        self.assertEqual(self.launchctl()[-2:], [f'enable {SERVICE}', f'bootstrap gui/{os.getuid()} {plist}'])
        self.assertEqual(self.switch('--status').stdout.strip(), 'vcx starts: swift')

    def test_switched_back_vcx_asks_open_for_the_swift_app_as_before(self):
        self.switch('--to', 'rust')
        self.switch('--to', 'swift')
        launcher = self.with_open(OPEN_RECORD)
        project = self.folder('project')

        self.vcx('--cwd', 'work/project', '--', 'hello there', launcher=launcher)

        self.assertEqual(read(self.root / 'open.args').splitlines(),
                         ['-n', '-g', '-a', str(SWIFT_APP), '--args', '--cwd', os.path.realpath(self.root), '--cwd', f'{os.path.realpath(self.root)}/work/project', '--', 'hello there'])
        self.assertTrue(project.is_dir())

    def test_refuses_to_replace_a_command_that_is_not_a_vcx_launcher(self):
        (self.root / 'bin/vcx').write_text('#!/bin/sh\necho mine\n')

        result = self.switch('--to', 'rust')

        self.assertEqual(result.returncode, 1)
        self.assertEqual((self.root / 'bin/vcx').read_text(), '#!/bin/sh\necho mine\n')
        self.assertEqual(self.launchctl(), [])

    def test_waits_for_a_swift_install_under_way_and_changes_nothing(self):
        (self.root / 'update/building').write_text('0\tinstalling\n')

        result = self.switch('--to', 'rust')

        self.assertEqual(result.returncode, 1)
        self.assertEqual((self.root / 'bin/vcx').read_bytes(), self.swift)
        self.assertEqual(self.launchctl(), [f'disable {SERVICE}', f'enable {SERVICE}'])

    def test_switched_vcx_opens_sessions_in_vcx_rust_and_answers_every_command(self):
        settings = {'worker': str(RUST_APP / 'Contents/MacOS/vcx-worker'),
                    'workerArguments': ['--runtime-test', '--runtime-fixture-command', str(self.root / 'command.json')]}
        (self.root / 'command.json').write_text(json.dumps(['/usr/bin/python3', str(FIXTURE)]))
        (self.root / 'config/settings.json').write_text(json.dumps(settings))
        self.switch('--to', 'rust')
        launcher = self.with_open(OPEN_RUST)
        first, second, moved = self.folder('first'), self.folder('second'), self.folder('moved')

        self.assertIn('No VCX Rust window is open.', self.vcx('--sessions', launcher=launcher).stdout)
        self.assertEqual(self.vcx('--cwd', 'work/first', '--', 'hello', launcher=launcher).returncode, 0)
        self.wait(self.windows, lambda windows: len(windows) == 1 and drew_turns(windows[0], 1))
        self.assertEqual(self.vcx('--cwd', str(second), 'second', launcher=launcher).returncode, 0)
        windows = self.wait(self.windows, lambda windows: len(windows) == 2 and all(drew_turns(w, 1) for w in windows))
        listed = self.wait(lambda: self.vcx('--sessions', launcher=launcher).stdout.splitlines(), lambda lines: len(lines) == 2)
        sent = self.vcx('--send', listed[0].split('\t')[0], 'ping', launcher=launcher)
        moved_to = self.vcx('--set-dir', listed[1].split('\t')[0], str(moved), launcher=launcher)
        version = self.vcx('--version', launcher=launcher)
        printed = self.vcx('-p', '--help', launcher=launcher)
        refused = self.vcx('--update-now', launcher=launcher)

        self.assertEqual({w['cwd'] for w in windows}, {str(first), str(second)})
        self.assertEqual(len(set(read(self.root / 'app.pids').split())), 2, 'the second launch went through open too')
        self.assertRegex(sent.stdout, r'^(Sent to|Queued for) ', sent.stderr)
        self.assertIn('now works in', moved_to.stdout, moved_to.stderr)
        self.assertTrue(version.stdout.startswith('vcx-rust '), version.stdout)
        self.assertEqual(printed.returncode, 0, printed.stderr)
        self.assertIn('usage: vcx -p', printed.stdout)
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn('no live update', refused.stderr)

    # The launcher hands `--resume native:<record>` over and the window reopens on that record, but the Rust worker
    # starts a new conversation for a `native:` resume (vcx-worker backend.rs `resume_target`): Rust worker's gap.
    @unittest.expectedFailure
    def test_switched_vcx_reopens_a_closed_window_from_its_record(self):
        settings = {'worker': str(RUST_APP / 'Contents/MacOS/vcx-worker'),
                    'workerArguments': ['--runtime-test', '--runtime-fixture-command', str(self.root / 'command.json')]}
        (self.root / 'command.json').write_text(json.dumps(['/usr/bin/python3', str(FIXTURE)]))
        (self.root / 'config/settings.json').write_text(json.dumps(settings))
        self.switch('--to', 'rust')
        launcher = self.with_open(OPEN_RUST)
        project = self.folder('project')
        self.vcx('--cwd', str(project), '--', 'remember this', launcher=launcher)
        self.wait(self.windows, lambda windows: len(windows) == 1 and drew_turns(windows[0], 1))
        record = self.wait(lambda: saved_record(self.root / 'state/windows.json'), bool)
        name = self.vcx('--sessions', launcher=launcher).stdout.split('\t')[0]
        closed = self.vcx('--close', name, launcher=launcher)
        self.wait(self.windows, lambda windows: windows == [])

        reopened = self.vcx('--cwd', str(project), '--resume', f'native:{record}', launcher=launcher)

        self.assertIn('Closed', closed.stdout, closed.stderr)
        self.assertEqual(reopened.returncode, 0, reopened.stderr)
        windows = self.wait(self.windows, lambda windows: len(windows) == 1 and drew_turns(windows[0], 1))
        self.assertEqual(windows[0]['cwd'], str(project))

    def test_switched_vcx_keeps_the_terminal_interface(self):
        python = HOME / 'self/my-apps/vcx/.venv/bin/python'
        if not python.exists():
            self.skipTest('no terminal interface virtualenv in the main checkout: the launcher would make one')
        if subprocess.run([str(python), '-c', 'pass'], capture_output=True).returncode != 0:
            self.skipTest('the main checkout\'s .venv cannot start its Python: vcx --terminal fails on the Swift launcher too')
        self.switch('--to', 'rust')

        result = self.vcx('--terminal', '--help')

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('usage', result.stdout.lower())


def ask(path, body):
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stream:
            stream.settimeout(SOCKET_WAIT)
            stream.connect(str(path))
            stream.sendall((json.dumps(body) + '\n').encode())
            line = stream.makefile().readline()
        return json.loads(line) if line else None
    except (OSError, ValueError):
        return None


def drew_turns(window, turns):
    """As tests/app.rs counts them: the fixture reuses item ids, so turns are counted by their prompts."""
    kinds = [row.get('kind') for row in (window.get('page') or {}).get('rows', [])]
    return kinds.count('user') == turns and 'assistant' in kinds and window.get('idle') is True


def saved_record(windows_file):
    try:
        return next((entry['recordID'] for entry in json.loads(windows_file.read_text()) if entry.get('recordID')), None)
    except (OSError, ValueError):
        return None


def read(path):
    return path.read_text() if path.exists() else ''


if __name__ == '__main__':
    unittest.main(verbosity=2)
