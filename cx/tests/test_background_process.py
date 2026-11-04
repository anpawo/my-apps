import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import select
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
HEADLESS = Path.home() / '.claude/skills/checker/headless.mjs'
spec = importlib.util.spec_from_file_location('background_process', ROOT / 'background.py')
bg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bg)


class BackgroundProcessTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='vcx-background-check-')
        self.addCleanup(self.directory.cleanup)
        self.home = Path(self.directory.name)
        self.config = self.home / 'config'
        self.state = self.home / 'state'
        self.calls = self.home / 'calls.jsonl'
        commands = self.home / '.local/bin'
        commands.mkdir(parents=True)
        peer = Path(__file__).with_name('background_peer.py').read_text()
        for provider in ('claude', 'codex'):
            command = commands / provider
            command.write_text('#!' + sys.executable + '\n' + peer.partition('\n')[2])
            command.chmod(0o700)
        launcher = commands / 'vcx'
        launcher.write_text('#!/bin/sh\nexec ' + shlex.join([sys.executable, str(ROOT / 'background.py')]) + ' "$@"\n')
        launcher.chmod(0o700)
        self.config.mkdir()
        (self.config / 'settings.json').write_text(json.dumps({'provider': 'codex', 'mode': 'bypass', 'limits': {}, 'accounts': [
            {'id': 'codex-fixture', 'provider': 'codex'}, {'id': 'claude-fixture', 'provider': 'claude'}]}))
        self.env = dict(os.environ, HOME=str(self.home), VCX_CONFIG_HOME=str(self.config), VCX_STATE_HOME=str(self.state),
                        VCX_FIXTURE_CALLS=str(self.calls), VCX_FIXTURE_READY=str(self.home / 'ready.json'))

    def run_cli(self, *options, mode='success', input='Fixture follow-up'):
        return subprocess.run([sys.executable, str(ROOT / 'background.py'), '-p', '--cwd', str(self.home),
                               '--output-format', 'json', *options], input=input, encoding='utf8',
                              capture_output=True, env=dict(self.env, VCX_FIXTURE_MODE=mode), timeout=5)

    def record(self, session):
        key = hashlib.sha256(str(self.home.resolve()).encode()).hexdigest()[:24]
        return self.state / 'native' / key / (session.removeprefix('native:') + '.json')

    def captured(self):
        return [json.loads(line) for line in self.calls.read_text().splitlines()]

    def test_watcher_json_result_resumes_same_provider_and_forks_without_rewriting_source(self):
        first = self.run_cli()
        self.assertEqual(first.returncode, 0, first.stderr)
        result = json.loads(first.stdout)
        self.assertEqual(result['provider'], 'codex')
        original = self.record(result['session_id']).read_bytes()
        second = self.run_cli('--resume', result['session_id'], '--fork-session')
        self.assertEqual(second.returncode, 0, second.stderr)
        fork = json.loads(second.stdout)
        self.assertNotEqual(fork['session_id'], result['session_id'])
        self.assertEqual(self.record(result['session_id']).read_bytes(), original)
        self.assertEqual(self.captured()[-1]['provider'], 'codex')
        self.assertEqual(self.captured()[-1]['arguments'][:3], ['exec', 'fork', 'fixture-codex'])
        third = self.run_cli('--resume', fork['session_id'])
        self.assertEqual(third.returncode, 0, third.stderr)
        self.assertEqual(json.loads(third.stdout)['session_id'], fork['session_id'])
        self.assertEqual(self.captured()[-1]['arguments'][:3], ['exec', 'resume', 'fixture-codex'])

    def test_watcher_respects_live_native_owner_and_can_fork_locked_source(self):
        first = self.run_cli()
        self.assertEqual(first.returncode, 0, first.stderr)
        session = json.loads(first.stdout)['session_id']
        source = self.record(session)
        original = source.read_bytes()
        lock_path = self.state / 'locks' / (session.removeprefix('native:') + '.lock')
        with lock_path.open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            busy = self.run_cli('--resume', session)
            self.assertEqual(busy.returncode, 1)
            self.assertTrue(json.loads(busy.stdout)['is_error'])
            self.assertEqual(len(self.captured()), 1, 'busy resume launched a provider')
            self.assertEqual(source.read_bytes(), original)
            forked = self.run_cli('--resume', session, '--fork-session')
            self.assertEqual(forked.returncode, 0, forked.stderr)
            self.assertNotEqual(json.loads(forked.stdout)['session_id'], session)
            self.assertEqual(self.captured()[-1]['arguments'][:3], ['exec', 'fork', 'fixture-codex'])
            self.assertEqual(source.read_bytes(), original)
        resumed = self.run_cli('--resume', session)
        self.assertEqual(resumed.returncode, 0, resumed.stderr)
        self.assertEqual(json.loads(resumed.stdout)['session_id'], session)
        self.assertEqual(self.captured()[-1]['arguments'][:3], ['exec', 'resume', 'fixture-codex'])

    def test_quota_after_tools_does_not_launch_fallback_at_real_process_boundary(self):
        result = self.run_cli(mode='tool_quota')
        self.assertEqual(result.returncode, 1, result.stderr)
        value = json.loads(result.stdout)
        self.assertTrue(value['is_error'])
        self.assertEqual([c['provider'] for c in self.captured()], ['codex'])
        self.assertIn('SENT_ONCE', self.record(value['session_id']).read_text())
        self.assertIn('Automatic replay was stopped', value['result'])

    @unittest.skipUnless(HEADLESS.is_file() and shutil.which('node'), 'installed checker helper and Node are required')
    def test_checker_wrapper_roundtrip_uses_native_resume_options(self):
        script = '''
const { runHeadless } = await import(process.env.VCX_HEADLESS_MODULE);
const result = runHeadless({cwd: process.env.HOME, input: 'Fixture follow-up',
    options: JSON.parse(process.env.VCX_HEADLESS_OPTIONS), timeout: 3000});
console.log(JSON.stringify({status: result.status, out: result.out, options: result.options}));
'''
        options = []
        for _ in range(2):
            result = subprocess.run([shutil.which('node'), '--input-type=module', '-'], input=script, encoding='utf8',
                                    capture_output=True, timeout=5, env=dict(self.env, VCX_HEADLESS_MODULE=HEADLESS.as_uri(),
                                    VCX_HEADLESS_OPTIONS=json.dumps(options)))
            self.assertEqual(result.returncode, 0, result.stderr)
            value = json.loads(result.stdout)
            self.assertEqual(value['status'], 0)
            self.assertEqual(value['out']['provider'], 'codex')
            self.assertEqual(value['options'], ['--resume', value['out']['session_id']])
            if options:
                self.assertEqual(value['options'], options)
            options = value['options']
        self.assertEqual(self.captured()[-1]['arguments'][:3], ['exec', 'resume', 'fixture-codex'])

    def test_malformed_events_keep_completed_tools_without_replay(self):
        for mode in ('malformed_after_tool', 'malformed_shape_after_tool'):
            with self.subTest(mode=mode):
                result = self.run_cli(mode=mode)
                self.assertEqual(result.returncode, 1)
                value = json.loads(result.stdout)
                self.assertTrue(value['is_error'])
                self.assertEqual(self.captured()[-1]['provider'], 'codex')
                self.assertIn('SENT_ONCE', self.record(value['session_id']).read_text())

    def test_nested_malformed_claude_events_keep_prior_actions(self):
        for suffix in ('null_block', 'list_block', 'dict_content', 'string_content', 'null_content', 'content_item', 'tool_id', 'tool_name'):
            with self.subTest(shape=suffix):
                count = len(self.captured()) if self.calls.exists() else 0
                result = self.run_cli('--provider', 'claude', mode='claude_malformed_' + suffix)
                self.assertEqual(result.returncode, 1)
                value = json.loads(result.stdout)
                self.assertTrue(value['is_error'])
                self.assertEqual([c['provider'] for c in self.captured()[count:]], ['claude'])
                self.assertIn('SENT_ONCE', self.record(value['session_id']).read_text())

    def test_stream_timeout_applies_before_stdout_eof(self):
        start = time.monotonic()
        with self.assertRaises(subprocess.TimeoutExpired):
            bg.command([sys.executable, '-c', 'import time; print("ready", flush=True); time.sleep(1.5)'],
                       timeout=0.1, on_line=lambda _: None)
        self.assertLess(time.monotonic() - start, 1)

    def test_stream_timeout_stops_descendant_after_provider_parent_exits(self):
        self.exited_parent_cleanup(cancelled=False)

    def test_cancellation_stops_descendant_after_provider_parent_exits(self):
        self.exited_parent_cleanup(cancelled=True)

    def exited_parent_cleanup(self, cancelled):
        ready = self.home / 'descendant.pid'
        release = self.home / 'release-descendant'
        child = '''
import pathlib, sys, time
until = time.monotonic() + 5
while not pathlib.Path(sys.argv[1]).exists() and time.monotonic() < until:
    time.sleep(0.01)
'''
        parent = '''
import os, pathlib, subprocess, sys
child = subprocess.Popen([sys.executable, '-c', sys.argv[1], sys.argv[3]])
pathlib.Path(sys.argv[2]).write_text(str(child.pid))
print('ready', flush=True)
os._exit(0)
'''
        def receive(_):
            os.waitid(os.P_PID, bg.CHILD.pid, os.WEXITED | os.WNOWAIT)
            if cancelled:
                bg.stop(signal.SIGTERM, None)
        try:
            with self.assertRaises(SystemExit if cancelled else subprocess.TimeoutExpired) as context:
                bg.command([sys.executable, '-c', parent, child, str(ready), str(release)], timeout=0.2, on_line=receive)
            if cancelled:
                self.assertEqual(context.exception.code, 128 + signal.SIGTERM)
            pid = int(ready.read_text())
            for _ in range(20):
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    break
                time.sleep(0.01)
            else:
                self.fail('provider exited but its pipe-holding descendant survived cleanup')
        finally:
            release.touch()

    def test_sigterm_stops_provider_and_its_child_without_fallback(self):
        process = subprocess.Popen([sys.executable, str(ROOT / 'background.py'), '-p', '--cwd', str(self.home),
                                    '--provider', 'codex', '--output-format', 'stream-json', 'Fixture follow-up'],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=dict(self.env, VCX_FIXTURE_MODE='hang'))
        pids = []
        try:
            ready = self.home / 'ready.json'
            deadline = time.monotonic() + 3
            while not ready.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(ready.exists(), 'fixture provider did not start')
            pids = list(json.loads(ready.read_text()).values())
            process.terminate()
            out, err = process.communicate(timeout=3)
            self.assertEqual(process.returncode, 128 + signal.SIGTERM, (out, err))
            self.assertEqual([c['provider'] for c in self.captured()], ['codex'])
            for pid in pids:
                for _ in range(100):
                    try:
                        os.kill(pid, 0)
                    except ProcessLookupError:
                        break
                    time.sleep(0.01)
                else:
                    self.fail('cancelled provider descendant survived')
        finally:
            if process.poll() is None:
                process.kill()
            process.communicate()
            for pid in pids:
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass

    def test_cancelled_tool_run_keeps_native_context_for_watcher(self):
        process = subprocess.Popen([sys.executable, str(ROOT / 'background.py'), '-p', '--cwd', str(self.home),
                                    '--provider', 'codex', '--output-format', 'stream-json', 'Fixture follow-up'],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=dict(self.env, VCX_FIXTURE_MODE='hang_after_tool'))
        prefix = b''
        try:
            deadline = time.monotonic() + 3
            while b'SENT_ONCE' not in prefix and time.monotonic() < deadline:
                if select.select([process.stdout], [], [], max(0, deadline - time.monotonic()))[0]:
                    prefix += os.read(process.stdout.fileno(), 65536)
            self.assertIn(b'SENT_ONCE', prefix, 'completed tool did not reach the stream')
            process.terminate()
            out, err = process.communicate(timeout=3)
            self.assertEqual(process.returncode, 128 + signal.SIGTERM, err)
            result = json.loads((prefix + out).splitlines()[-1])
            self.assertTrue(result['is_error'])
            record = json.loads(self.record(result['session_id']).read_text())
            self.assertEqual(record['threadId'], 'fixture-thread')
            self.assertIn('SENT_ONCE', json.dumps(record))
            self.assertEqual([call['provider'] for call in self.captured()], ['codex'])
        finally:
            if process.poll() is None:
                process.terminate()
            process.communicate(timeout=3)


if __name__ == '__main__':
    unittest.main()
