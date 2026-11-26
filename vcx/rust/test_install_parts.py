#!/usr/bin/env python3
"""Each part of VCX Rust upgraded on its own by `build-rust.sh --install [page] [worker] [app]`, on a scratch install
and isolated homes: the installed VCX Rust, the Swift app and their state are never touched. The scratch app runs
windowless, its session on the scratch bundle's Rust worker talking to the fixture agent. A part is made to differ by
changing its installed copy, so no source is edited. Run: python3 vcx/rust/test_install_parts.py
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
SCRIPT = HERE.parent / 'build-rust.sh'
TEMPLATE = HERE / 'template'
FIXTURE = HERE / 'fixtures/fake_agent.py'
WAIT = 60
POLL = 0.2
SOCKET_WAIT = 30
PAGE_MARK = "document.querySelector('meta[name=vcx-page]')?.content ?? 'none'"
TIMES = {}


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


def replace(path, data):
    """Writes a new file over `path` by a rename, as an install does: a running process keeps its image."""
    new = path.with_name(path.name + '.test')
    new.write_bytes(data)
    new.chmod(path.stat().st_mode)
    new.replace(path)


class Parts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Unix socket paths are capped near 104 bytes, so the folders sit in /tmp.
        cls.root = Path(f'/tmp/vcxp-{os.getpid()}')
        shutil.rmtree(cls.root, ignore_errors=True)
        for name in ('Applications', 'shared', 'config', 'state', 'work'):
            (cls.root / name).mkdir(parents=True, mode=0o700)
        cls.bundle = cls.root / 'Applications/VCX Rust.app'
        cls.page = cls.root / 'config/page'
        cls.worker = cls.bundle / 'Contents/MacOS/vcx-worker'
        cls.frontend = cls.bundle / 'Contents/MacOS/vcx-rust'
        cls.control = cls.root / 'state/control.sock'
        cls.env = {k: v for k, v in os.environ.items() if not k.startswith(('VCX_', 'CLAUDE_CODE_SESSION_ID', 'BUILD_STACK'))}
        cls.env.update(
            VCX_RUST_INSTALL_DIR=str(cls.root / 'Applications'),
            VCX_CONFIG_HOME=str(cls.root / 'shared'), VCX_RUST_CONFIG_HOME=str(cls.root / 'config'),
            VCX_RUST_STATE_HOME=str(cls.root / 'state'), VCX_RUST_RUNTIME_HOME=str(cls.root / 'state/runtime'),
            VCX_STATE_HOME=str(cls.root / 'worker-state'), VCX_RUNTIME_HOME=str(cls.root / 'worker-runtime'),
            VCX_UPDATE_STATE=str(cls.root / 'update'))
        first = cls.install(timed='--install, first on the scratch folder')
        assert first.returncode == 0, first.stdout + first.stderr
        (cls.root / 'command.json').write_text(json.dumps(['/usr/bin/python3', str(FIXTURE)]))
        settings = {'worker': str(cls.worker), 'workerArguments': ['--runtime-test', '--runtime-fixture-command', str(cls.root / 'command.json')]}
        (cls.root / 'config/settings.json').write_text(json.dumps(settings))
        folder = cls.root / 'work/parts'
        folder.mkdir()
        cls.log = open(cls.root / 'app.log', 'ab')
        cls.app = subprocess.Popen([str(cls.frontend), '--windowless', '--cwd', str(folder.resolve()), 'hello'], env=cls.env,
                                   stdin=subprocess.DEVNULL, stdout=cls.log, stderr=cls.log, start_new_session=True)

    @classmethod
    def tearDownClass(cls):
        ask(cls.control, {'quit': {}})
        cls.app.kill()
        cls.app.wait()
        cls.log.close()
        # The workers the app started: every process whose command line names this run's folder.
        subprocess.run(['/usr/bin/pkill', '-9', '-f', str(cls.root)], capture_output=True)
        shutil.rmtree(cls.root, ignore_errors=True)
        print('\n' + '\n'.join(f'{name}: {seconds:.1f} s' for name, seconds in TIMES.items()))

    @classmethod
    def install(cls, *parts, timed=None):
        started = time.monotonic()
        result = subprocess.run([str(SCRIPT), '--install', *parts], env=cls.env, capture_output=True, text=True)
        TIMES[timed or ('--install ' + ' '.join(parts)).strip()] = time.monotonic() - started
        return result

    def wait(self, what, done):
        deadline = time.monotonic() + WAIT
        last = None
        while time.monotonic() < deadline:
            last = what()
            if done(last):
                return last
            time.sleep(POLL)
        self.fail(f'never reached: {last!r}; app log: {(self.root / "app.log").read_text()}')

    def window(self):
        report = self.wait(lambda: ask(self.control, {'report': {}}), lambda report: report and len(report['windows']) == 1 and report['windows'][0]['sessionId'])
        return report['pid'], report['windows'][0]['sessionId']

    def mark(self, session):
        answer = ask(self.control, {'evaluate': {'to': session, 'script': PAGE_MARK}})
        try:
            return json.loads(answer['result'])
        except (TypeError, KeyError, ValueError):
            return None

    def image(self, path):
        """The inode of the executable a running process of `path` was started from, and its pid."""
        pids = [line.split(None, 1)[0] for line in subprocess.run(['ps', '-axo', 'pid=,comm='], capture_output=True, text=True).stdout.splitlines()
                if line.split(None, 1)[1:] == [str(path)]]
        self.assertEqual(len(pids), 1, f'{path} runs as {pids}')
        fields = subprocess.run(['lsof', '-a', '-p', pids[0], '-d', 'txt', '-F', 'in'], capture_output=True, text=True).stdout.splitlines()
        inode = next(fields[at - 1][1:] for at, field in enumerate(fields) if field == 'n' + str(path.resolve()))
        return int(pids[0]), int(inode)

    def state(self):
        """What a part's upgrade may change: each running image and the app's control socket (a new one after an exec)."""
        self.window()
        return {'app': self.image(self.frontend), 'worker': self.image(self.worker), 'control': self.control.stat().st_ino}

    def installed(self):
        return {str(path): path.stat().st_ino for path in sorted(self.bundle.rglob('*')) if path.is_file()}

    def verify_signature(self):
        check = subprocess.run(['codesign', '--verify', '--deep', '--strict', str(self.bundle)], capture_output=True, text=True)
        self.assertEqual(check.returncode, 0, check.stderr)

    def test_an_install_of_unchanged_parts_replaces_and_signals_nothing(self):
        before, files = self.state(), self.installed()

        result = self.install(timed='--install, nothing changed')

        self.assertEqual(result.returncode, 0, result.stderr)
        for line in ('page: unchanged', 'worker: unchanged', 'app: unchanged', '0 files replaced'):
            self.assertIn(line, result.stdout)
        self.assertNotIn('updating', result.stdout)
        self.assertEqual((self.installed(), self.state()), (files, before))

    def test_a_page_install_reaches_the_running_window_with_no_cargo_and_no_restart(self):
        before = self.state()
        session = self.window()[1]
        index = self.page / 'index.html'
        replace(index, index.read_text().replace('<head>', '<head>\n<meta name="vcx-page" content="stale">', 1).encode())
        self.wait(lambda: self.mark(session), lambda mark: mark == 'stale')

        result = self.install('page')

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('page: installed', result.stdout)
        self.assertNotIn('Compiling', result.stderr + result.stdout)
        self.assertNotIn('build-stack', result.stderr + result.stdout)
        self.wait(lambda: self.mark(session), lambda mark: mark == 'none')
        self.assertEqual(subprocess.run(['diff', '-rq', str(TEMPLATE), str(self.page)]).returncode, 0)
        self.assertEqual((self.state(), self.window()[1]), (before, session))

    def test_a_worker_install_replaces_and_updates_only_the_workers(self):
        before, session = self.state(), self.window()[1]
        replace(self.worker, self.worker.read_bytes())
        subprocess.run(['codesign', '--force', '--sign', '-', '--identifier', 'vcx-worker-stale', str(self.worker)], check=True, capture_output=True)

        result = self.install('worker')

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('worker: replaced', result.stdout)
        self.assertIn(f'updating worker {before["worker"][0]}', result.stdout)
        self.assertNotIn('updating app', result.stdout)
        after = self.wait(self.state, lambda state: state['worker'][1] == self.worker.stat().st_ino)
        self.assertEqual(after['worker'][0], before['worker'][0])
        self.assertEqual((after['app'], after['control'], self.window()[1]), (before['app'], before['control'], session))
        self.verify_signature()

    def test_an_app_install_replaces_and_relaunches_only_the_app(self):
        before, session = self.state(), self.window()[1]
        runner = self.bundle / 'Contents/Resources/background.py'
        replace(runner, runner.read_bytes() + b'\n# stale\n')

        result = self.install('app')

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('app: replaced', result.stdout)
        self.assertIn(f'updating app {before["app"][0]}', result.stdout)
        self.assertNotIn('updating worker', result.stdout)
        after = self.wait(self.state, lambda state: state['control'] != before['control'])
        self.assertEqual(after['app'][0], before['app'][0])
        self.assertEqual((after['worker'], self.window()[1]), (before['worker'], session))
        self.verify_signature()


if __name__ == '__main__':
    unittest.main()
