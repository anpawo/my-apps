#!/usr/bin/env python3
import argparse
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import signal
import shlex
import subprocess
import sys
import tempfile
import time
import urllib.parse
import uuid


HOME = Path.home()
CONFIG = Path(os.environ.get('VCX_CONFIG_HOME', HOME / 'Library/Application Support/VCX'))
STATE = Path(os.environ.get('VCX_STATE_HOME', HOME / '.local/state/cx'))
QUOTA = re.compile(r'usage.?limit|rate.?limit|weekly limit|hit your limit|out of credits|credit balance.*(?:low|exhaust)|insufficient.?quota', re.I)
AUTH = re.compile(r'not logged in|authentication (?:failed|required)|unauthorized|invalid (?:api key|authentication)|refresh token.*(?:expired|invalid)|please (?:run.*login|log in|login)', re.I)
CHILD = None


class ProviderUnavailable(RuntimeError):
    pass


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, name = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def read_json(path, default=None):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {} if default is None else default


def toml(value):
    if isinstance(value, dict):
        return '{' + ','.join(json.dumps(k) + '=' + toml(v) for k, v in value.items()) + '}'
    if isinstance(value, list):
        return '[' + ','.join(map(toml, value)) + ']'
    return json.dumps(value)


def preferences():
    return dict(defaultProvider='auto', mode='bypass', limits={}, accounts=[
        dict(id='claude-default', provider='claude'), dict(id='codex-default', provider='codex')],
        qwenURL='http://localhost:11434/api/chat', qwenProxy='', qwenModel='qwen3-8b-abl') | read_json(CONFIG / 'settings.json')


def mark_limit(account):
    CONFIG.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (CONFIG / 'settings.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        value = read_json(CONFIG / 'settings.json')
        value.setdefault('limits', {})[account['id']] = time.time() + 300
        write_json(CONFIG / 'settings.json', value)


def environment(account):
    env = {k: v for k, v in os.environ.items() if not k.startswith(('CLAUDE', 'CODEX', 'FLEET_')) and k not in (
        'ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'OPENAI_API_KEY', 'CODEX_API_KEY', 'VCX_SESSION_FORMAT')}
    env['PATH'] = str(HOME / '.local/bin') + ':/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin'
    if account.get('home'):
        env['CLAUDE_CONFIG_DIR' if account['provider'] == 'claude' else 'CODEX_HOME'] = account['home']
    return env


def command(args, data=None, env=None, timeout=None, cwd=None, on_line=None):
    global CHILD
    CHILD = subprocess.Popen(args, stdin=subprocess.PIPE if data is not None else subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, cwd=cwd, start_new_session=True)
    try:
        if on_line:
            deadline = time.monotonic() + timeout if timeout is not None else None
            chunks, errors, pending, scanned = [], [], bytearray(), 0
            outgoing = memoryview(data or b'')
            with selectors.DefaultSelector() as selector:
                for pipe in (CHILD.stdout, CHILD.stderr):
                    os.set_blocking(pipe.fileno(), False)
                    selector.register(pipe, selectors.EVENT_READ)
                if CHILD.stdin:
                    if outgoing:
                        os.set_blocking(CHILD.stdin.fileno(), False)
                        selector.register(CHILD.stdin, selectors.EVENT_WRITE)
                    else:
                        CHILD.stdin.close()
                while selector.get_map():
                    remaining = None if deadline is None else deadline - time.monotonic()
                    if remaining is not None and remaining <= 0:
                        raise subprocess.TimeoutExpired(args, timeout, output=b''.join(chunks), stderr=b''.join(errors))
                    for key, _ in selector.select(remaining):
                        pipe = key.fileobj
                        if pipe is CHILD.stdin:
                            try:
                                outgoing = outgoing[os.write(pipe.fileno(), outgoing[:65536]):]
                            except BrokenPipeError:
                                outgoing = outgoing[len(outgoing):]
                            if not outgoing:
                                selector.unregister(pipe)
                                pipe.close()
                            continue
                        value = os.read(pipe.fileno(), 65536)
                        if not value:
                            selector.unregister(pipe)
                            if pipe is CHILD.stdout and pending:
                                on_line(bytes(pending))
                                pending.clear()
                            continue
                        if pipe is CHILD.stderr:
                            errors.append(value)
                            continue
                        chunks.append(value)
                        pending.extend(value)
                        while (index := pending.find(b'\n', scanned)) >= 0:
                            line = bytes(pending[:index + 1])
                            del pending[:index + 1]
                            scanned = 0
                            on_line(line)
                        scanned = len(pending)
            CHILD.wait(timeout=None if deadline is None else max(0, deadline - time.monotonic()))
            return CHILD.returncode, b''.join(chunks), b''.join(errors)
        out, err = CHILD.communicate(data, timeout=timeout)
        return CHILD.returncode, out, err
    except BaseException:
        try:
            # Stop descendants before reaping the leader, while its PID still reserves our process group.
            if CHILD.returncode is None:
                os.killpg(CHILD.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        except PermissionError as error:
            try:
                CHILD.wait(timeout=0.1)
            except subprocess.TimeoutExpired:
                raise error
        CHILD.wait()
        raise
    finally:
        for pipe in (CHILD.stdin, CHILD.stdout, CHILD.stderr):
            if pipe:
                pipe.close()
        CHILD = None


def stop(signum, _):
    raise SystemExit(128 + signum)


def curl_args(prefs, url, seconds):
    parts = urllib.parse.urlsplit(url)
    if parts.scheme not in ('http', 'https') or not parts.hostname or parts.username or parts.password:
        raise ValueError('Invalid Qwen endpoint.')
    args = ['/usr/bin/curl', '--silent', '--show-error', '--fail-with-body', '--max-time', str(seconds)]
    proxy = prefs.get('qwenProxy', '')
    if proxy:
        parsed = urllib.parse.urlsplit(proxy)
        if parsed.scheme not in ('socks5', 'socks5h') or not parsed.hostname or not parsed.port or parsed.username or parsed.password:
            raise ValueError('Invalid Qwen proxy.')
        args += ['--proxy', proxy]
    return args + [url]


def ensure_qwen(prefs, run=command, sleep=time.sleep, now=time.monotonic):
    endpoint = urllib.parse.urlsplit(prefs['qwenURL'])
    tags = urllib.parse.urlunsplit(endpoint._replace(path='/api/tags', query='', fragment=''))
    probe = curl_args(prefs, tags, 3)
    if run(probe, timeout=5)[0] == 0:
        return
    if endpoint.hostname in ('localhost', '127.0.0.1', '::1'):
        raise ProviderUnavailable('The local Qwen server is unavailable.')
    if not prefs.get('qwenWake', False):
        raise ProviderUnavailable('Qwen is unavailable. Automatic Windows wake is disabled.')
    wake = HOME / 'self/jarvis/tools/wake-pc.py'
    if not wake.is_file():
        raise ProviderUnavailable('Qwen is unavailable and the Windows wake helper is missing.')
    code, _, _ = run(['/opt/homebrew/bin/python3', str(wake)], timeout=150)
    if code:
        raise ProviderUnavailable('The Windows wake request failed. Check the Freebox wake setup.')
    deadline = now() + 60
    while now() < deadline:
        if run(probe, timeout=5)[0] == 0:
            return
        sleep(2)
    raise ProviderUnavailable('Windows was sent a wake request, but Qwen did not become ready.')


def options(argv):
    parser = argparse.ArgumentParser(prog='vcx -p')
    parser.add_argument('-p', '--print', '--headless', action='store_true')
    parser.add_argument('--provider', choices=['auto', 'claude', 'codex', 'qwen'])
    parser.add_argument('--codex', action='store_true')
    parser.add_argument('--cwd', '-C', default=os.getcwd())
    parser.add_argument('--resume', '-r')
    parser.add_argument('--fork-session', action='store_true')
    parser.add_argument('--session-id')
    parser.add_argument('--session-id-format', choices=['native', 'uuid'], default=os.environ.get('VCX_SESSION_FORMAT', 'native'))
    parser.add_argument('--model')
    parser.add_argument('--output-format', choices=['text', 'json', 'stream-json'], default='text')
    parser.add_argument('--input-format', choices=['text', 'stream-json'], default='text')
    parser.add_argument('--system-prompt', default='')
    parser.add_argument('--append-system-prompt', default='')
    parser.add_argument('--append-system-prompt-file')
    parser.add_argument('--json-schema')
    parser.add_argument('--tools')
    parser.add_argument('--allowedTools', '--allowed-tools')
    parser.add_argument('--disallowedTools', '--disallowed-tools')
    parser.add_argument('--setting-sources')
    parser.add_argument('--settings')
    parser.add_argument('--mcp-config', action='append', default=[])
    parser.add_argument('--permission-mode')
    parser.add_argument('--effort')
    parser.add_argument('--max-turns', type=int)
    parser.add_argument('--add-dir', action='append', default=[])
    for name in ['strict-mcp-config', 'disable-slash-commands', 'no-session-persistence',
                 'dangerously-skip-permissions', 'restricted', 'verbose', 'include-partial-messages']:
        parser.add_argument('--' + name, action='store_true')
    parser.add_argument('prompt', nargs='*')
    args = parser.parse_args(argv)
    if not Path(args.cwd).is_dir():
        parser.error('Working folder does not exist.')
    if args.max_turns is not None and args.max_turns < 1:
        parser.error('--max-turns must be positive.')
    if args.json_schema:
        json.loads(args.json_schema)
    if args.append_system_prompt_file:
        args.append_system_prompt += '\n' + (Path(args.cwd) / args.append_system_prompt_file).read_text()
    return args


def candidates(prefs, args, current=None):
    preferred = args.provider or ('codex' if args.codex else prefs['defaultProvider'])
    order = ['claude', 'codex', 'qwen']
    if preferred != 'auto':
        order.remove(preferred)
        order.insert(0, preferred)
    accounts = prefs['accounts'] + [dict(id='qwen', provider='qwen')]
    result = [a for provider in order for a in accounts if a['provider'] == provider and a.get('enabled', True)]
    if current and preferred == 'auto':
        result.sort(key=lambda a: a['id'] != current)
    usage = read_json(HOME / '.local/state/claude-usage.json')
    return [a for a in result if prefs['limits'].get(a['id'], 0) <= time.time() and not (
        a['provider'] == 'claude' and usage.get('weeklyLimitReached') and usage.get('weeklyLimitResetAt', 0) > time.time())]


def content_text(content):
    return '\n'.join(p.get('text', '') for p in content if p.get('type') == 'text')


def bypass_allowed(args, prefs):
    return args.dangerously_skip_permissions or (args.permission_mode == 'bypassPermissions' if args.permission_mode else prefs['mode'] == 'bypass')


def tool_denied(payload, restrictions):
    tool = payload.get('tool_name', '')
    for rule in (restrictions or '').split(','):
        if not rule:
            continue
        name = rule.split('(', 1)[0]
        if tool.startswith(name) and '(' not in rule:
            return True
        if tool == 'Bash' and name == 'Bash':
            if not rule.endswith(':*)'):
                return True
            try:
                prefix = shlex.split(rule[5:-3])
                words = shlex.split(payload.get('tool_input', {}).get('command', ''))
                words = [part.strip(';|&()$') for word in words for part in shlex.split(word)]
            except ValueError:
                return True
            # Deny prefixes conservatively across shell wrappers and git options.
            remaining = iter(words)
            if prefix and all(any(Path(word).name == part for word in remaining) for part in prefix):
                return True
    return False


def tool_activity(result):
    rows = list(result.get('_rows', []))
    if rows:
        return rows
    calls, outputs = {}, {}
    for event in result.get('_events', []):
        block = event.get('event', {}).get('content_block', {})
        if block.get('type') == 'tool_use':
            calls[block['id']] = block
        content = event.get('message', {}).get('content', [])
        if not isinstance(content, list):
            continue
        for item in content:
            if item.get('type') == 'tool_use':
                calls[item['id']] = item
            elif item.get('type') == 'tool_result':
                outputs[item['tool_use_id']] = item
    for ident, item in calls.items():
        output = outputs.get(ident)
        rows.append({'kind': 'activity', 'items': [dict(id=ident, type='commandExecution', command=item['name'] + ' ' + json.dumps(item.get('input', {})),
                     aggregatedOutput=json.dumps(output.get('content', '')) if output else 'Outcome unknown: do not repeat without checking.', status='failed' if not output or output.get('is_error') else 'completed')]})
    return rows


def provider_event(line):
    if not line.startswith(b'{'):
        return None
    value = json.loads(line)
    for key in ('item', 'message', 'event', 'error', 'usage'):
        if key in value and not isinstance(value[key], dict):
            raise ValueError('The provider returned an invalid ' + key + ' event.')
    content = value.get('message', {}).get('content', [])
    if not isinstance(content, list) or any(not isinstance(item, dict) for item in content):
        raise ValueError('The provider returned invalid message content.')
    block = value.get('event', {}).get('content_block', {})
    if not isinstance(block, dict):
        raise ValueError('The provider returned an invalid content block.')
    for item in [block, *content]:
        fields = ('id', 'name') if item.get('type') == 'tool_use' else ('tool_use_id',) if item.get('type') == 'tool_result' else ()
        if any(not isinstance(item.get(field), str) for field in fields):
            raise ValueError('The provider returned an invalid tool event.')
    item = value.get('item', {})
    if item.get('type') == 'command_execution' and (not isinstance(item.get('id'), str) or not isinstance(item.get('command', ''), str)):
        raise ValueError('The provider returned an invalid command event.')
    if item.get('type') == 'agent_message' and not isinstance(item.get('text'), str):
        raise ValueError('The provider returned an invalid answer event.')
    if value.get('type') == 'thread.started' and not isinstance(value.get('thread_id'), str):
        raise ValueError('The provider returned an invalid thread identifier.')
    if value.get('type') == 'result' and not isinstance(value.get('result', ''), str):
        raise ValueError('The provider returned an invalid result.')
    if not isinstance(value.get('error', {}).get('message', ''), str):
        raise ValueError('The provider returned an invalid error event.')
    return value


class Runner:
    def __init__(self, args):
        self.args = args
        self.prefs = preferences()
        self.record_id = str(uuid.uuid4()).upper()
        self.record = {'cwd': str(Path(args.cwd).resolve()), 'rows': []}
        if args.resume and not args.resume.startswith('native:'):
            try:
                record_id = str(uuid.UUID(args.resume)).upper()
                key = hashlib.sha256(self.record['cwd'].encode()).hexdigest()[:24]
                if (STATE / 'native' / key / (record_id + '.json')).is_file():
                    args.resume = 'native:' + record_id
            except ValueError:
                pass
        self.backend = args.resume
        self.account = None
        self.lock = None
        self.activity = []
        self.cancelled = None
        if args.resume and args.resume.startswith('native:'):
            record_id = str(uuid.UUID(args.resume[7:])).upper()
            self.record_id = record_id
            self.record = read_json(self.snapshot())
            if not self.record.get('threadId') or self.record.get('cwd') != str(Path(args.cwd).resolve()):
                raise ValueError('The saved VCX conversation was not found in this working folder.')
            self.backend = self.record['threadId']
            self.account = self.record['accountId']
            if args.fork_session:
                self.record_id = str(uuid.uuid4()).upper()
        if self.backend and self.backend.startswith('claude:'):
            self.backend = self.backend[7:]
        if not args.no_session_persistence:
            path = STATE / 'locks' / (self.record_id + '.lock')
            path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            self.lock = path.open('a')
            fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def close(self):
        if self.lock:
            self.lock.close()
            self.lock = None

    def stream_event(self, value):
        if self.args.output_format == 'stream-json':
            print(json.dumps(value), flush=True)

    def snapshot(self):
        key = hashlib.sha256(self.record['cwd'].encode()).hexdigest()[:24]
        return STATE / 'native' / key / (self.record_id + '.json')

    def context(self):
        lines = []
        for row in self.record['rows'][-60:]:
            for item in row['items']:
                text = content_text(item.get('content', [])) if row['kind'] == 'user' else item.get('text', item.get('aggregatedOutput', ''))
                lines.append(row['kind'] + ': ' + text)
        return '\n'.join(lines)[-48000:]

    def turn(self, content):
        args = self.args
        failures = []
        for account in candidates(self.prefs, args, self.account):
            provider = account['provider']
            # Restricted file tools have no equivalent in the other command-line engines.
            if args.restricted and args.tools and set(args.tools.split(',')) - {'WebSearch', 'WebFetch'} and provider != 'claude':
                failures.append(provider + ': this task needs Claude restricted file tools')
                continue
            if provider == 'qwen' and args.tools and set(args.tools.split(',')) & {'WebSearch', 'WebFetch'}:
                failures.append('qwen: this task requires web verification')
                continue
            prior = self.context()
            same = not args.no_session_persistence and (self.account == account['id'] or self.account is None and (provider == ('codex' if args.codex else 'claude')))
            resume = self.backend if same else None
            task = list(content)
            self.activity = []
            failed = False
            if not same and (prior or self.backend):
                context = prior or ('The previous agent session is ' + self.backend + '. Read its transcript if needed.')
                task.insert(0, {'type': 'text', 'text': 'Continue the work below. Check existing work first and do not repeat completed actions.\n' + context})
            try:
                if provider == 'claude':
                    result = self.claude(account, task, resume)
                elif provider == 'codex':
                    result = self.codex(account, task, resume)
                else:
                    result = self.qwen(account, task)
            except ProviderUnavailable as error:
                failures.append(provider + ': ' + str(error))
                continue
            except FileNotFoundError:
                failures.append(provider + ': command not installed')
                if provider == 'claude':
                    break
                continue
            except subprocess.TimeoutExpired:
                failed = True
                result = {'is_error': True, 'result': provider + ' timed out; the task was not replayed.', '_rows': self.activity}
            except SystemExit as error:
                self.cancelled = error.code
                failed = True
                result = {'is_error': True, 'result': provider + ' was cancelled; the task was not replayed.', '_rows': self.activity}
            except (ValueError, RuntimeError, OSError) as error:
                failed = True
                result = {'is_error': True, 'result': provider + ': ' + str(error), '_rows': self.activity}
            if failed and provider == 'qwen':
                result['session_id'] = 'qwen:' + self.record_id
            activity = tool_activity(result)
            if not failed and result.get('is_error') and AUTH.search(result.get('result', '')) and not activity:
                failures.append(provider + ': authentication unavailable')
                # Only a usage limit may move a task off Claude.
                if provider == 'claude':
                    break
                continue
            if not failed and result.get('is_error') and QUOTA.search(result.get('result', '')):
                mark_limit(account)
                self.prefs = preferences()
                if not activity:
                    if result.get('session_id'):
                        self.backend = result['session_id']
                        self.account = account['id']
                    failures.append(provider + ': usage limit reached')
                    continue
                result['result'] = 'Usage limit reached after task tools ran. Automatic replay was stopped; check the activity before continuing.\n' + result.get('result', '')
            if result.get('is_error') and activity and args.no_session_persistence:
                result['result'] += '\nActivity:\n' + json.dumps(activity)
            self.account = account['id']
            self.backend = result.get('session_id', self.backend)
            self.record.update(accountId=account['id'], threadId=('claude:' if provider == 'claude' else '') + (self.backend or self.record_id))
            self.record['rows'].append({'kind': 'user', 'items': [dict(id=str(uuid.uuid4()), type='userMessage', content=content, sentAt=time.time())]})
            result.pop('_rows', None)
            self.record['rows'] += activity
            if '_events' not in result:
                events = []
                for row in activity:
                    for item in row['items']:
                        events += [dict(type='assistant', message={'content': [dict(type='tool_use', id=item['id'], name='Bash', input={'command': item['command']})]}),
                                   dict(type='user', message={'content': [dict(type='tool_result', tool_use_id=item['id'], content=item['aggregatedOutput'], is_error=item['status'] != 'completed')]})]
                if events:
                    result['_events'] = events
            self.record['rows'].append({'kind': 'assistant', 'items': [dict(id=str(uuid.uuid4()), type='agentMessage', text=result.get('result', ''), provider=provider.capitalize())]})
            self.record['title'] = self.record.get('title') or content_text(content)[:100]
            self.record.setdefault('draft', [])
            if not args.no_session_persistence:
                write_json(self.snapshot(), self.record)
                result['session_id'] = self.record_id if args.session_id_format == 'uuid' else 'native:' + self.record_id
            result['provider'] = provider
            result.setdefault('type', 'result')
            if args.json_schema and not result.get('is_error') and 'structured_output' not in result:
                try:
                    result['structured_output'] = json.loads(result['result'].strip().removeprefix('```json').removeprefix('```').removesuffix('```'))
                except ValueError:
                    result.update(is_error=True, result='The provider did not return valid structured JSON.')
            return result
        return {'type': 'result', 'is_error': True, 'result': '; '.join(failures) or 'No enabled provider is available.'}

    def claude(self, account, content, resume):
        args = self.args
        command_args = ['claude', '-p', '--input-format', 'stream-json', '--output-format', 'stream-json', '--verbose']
        for flag in ['model', 'system_prompt', 'append_system_prompt', 'json_schema', 'tools', 'allowedTools', 'disallowedTools',
                     'setting_sources', 'settings', 'permission_mode', 'effort', 'session_id']:
            value = getattr(args, flag)
            if value is not None and value != '' or flag in ('tools', 'setting_sources') and value == '':
                command_args += ['--' + flag.replace('_', '-'), value]
        for flag in ['strict_mcp_config', 'disable_slash_commands', 'no_session_persistence', 'dangerously_skip_permissions', 'restricted', 'fork_session']:
            if getattr(args, flag):
                command_args.append('--' + flag.replace('_', '-'))
        # Uncapped unless asked, as claude -p: a 30-turn default cut the watch audit and checker follow-ups.
        if args.max_turns:
            command_args += ['--max-turns', str(args.max_turns)]
        if not args.permission_mode and not args.dangerously_skip_permissions:
            # Claude Code 2.1.318 refuses bypassPermissions under --restricted; default denies WebFetch in -p, auto allows it.
            bypass = 'auto' if args.restricted else 'bypassPermissions'
            command_args += ['--permission-mode', bypass if self.prefs['mode'] == 'bypass' else 'default']
        for path in args.add_dir:
            command_args += ['--add-dir', path]
        for config in args.mcp_config:
            command_args += ['--mcp-config', config]
        if resume:
            command_args += ['--resume', resume]
        body = json.dumps({'type': 'user', 'message': {'role': 'user', 'content': content}}).encode() + b'\n'
        streamed = self.args.output_format == 'stream-json'
        events = []
        def receive(line):
            value = provider_event(line)
            if value is None:
                return
            events.append(value)
            if value.get('session_id'):
                self.backend = value['session_id']
            content = value.get('message', {}).get('content', [])
            if value.get('event', {}).get('content_block', {}).get('type') == 'tool_use' or isinstance(content, list) and any(item.get('type') in ('tool_use', 'tool_result') for item in content):
                self.activity = tool_activity({'_events': events})
            if value.get('type') != 'result':
                self.stream_event(value)
        code, out, err = command(command_args, body, environment(account), on_line=receive)
        if not events:
            for line in out.splitlines():
                receive(line)
        result = next((v for v in reversed(events) if v.get('type') == 'result'), None)
        if result is None:
            return {'is_error': True, 'result': err.decode(errors='replace') or 'Claude exited without a result (' + str(code) + ').', '_events': events, '_streamed': streamed}
        result['_events'] = events
        result['_streamed'] = streamed
        result['is_error'] = code != 0 or result.get('is_error', False)
        return result

    def codex(self, account, content, resume):
        args = self.args
        sealed = args.tools is not None
        settings = json.loads(args.settings) if args.settings and args.settings.lstrip().startswith('{') else read_json(Path(args.settings)) if args.settings else {}
        hooks = settings.get('hooks', {})
        if args.disallowedTools:
            guard = shlex.join(['/usr/bin/python3', str(Path(__file__).resolve()), '--check-denied-tools', args.disallowedTools])
            hooks = dict(hooks)
            hooks['PreToolUse'] = [{'matcher': '.*', 'hooks': [{'type': 'command', 'command': guard}]}] + hooks.get('PreToolUse', [])
        if sealed:
            guard = shlex.join(['/usr/bin/python3', str(Path(__file__).resolve()), '--check-tools', args.tools])
            hooks = dict(hooks)
            hooks['PreToolUse'] = [{'matcher': '.*', 'hooks': [{'type': 'command', 'command': guard}]}] + hooks.get('PreToolUse', [])
        local_tools = set((args.tools or '').split(',')) - {'', 'WebSearch', 'WebFetch'}
        if sealed and local_tools - {'Bash'}:
            return {'is_error': True, 'result': 'Codex cannot preserve this explicit local-tool allowlist.'}
        shell = not sealed or 'Bash' in local_tools
        if args.permission_mode and args.permission_mode not in ('bypassPermissions', 'default'):
            raise ValueError('Codex cannot preserve this permission mode in a background task.')
        if args.disallowedTools and 'Bash' in args.disallowedTools.split(','):
            shell = False
        cmd = ['codex', 'exec'] + (['fork' if args.fork_session else 'resume', resume] if resume else [])
        cmd += ['--json', '--skip-git-repo-check']
        if args.no_session_persistence:
            cmd += ['--ephemeral']
        if sealed:
            bypass = bypass_allowed(args, self.prefs)
            cmd += ['--ignore-user-config', '--ignore-rules', '-c', 'approval_policy="never"', '-c', 'sandbox_mode=' + json.dumps('danger-full-access' if shell and bypass else 'read-only'),
                    '-c', 'project_doc_max_bytes=0', '-c', 'features.shell_tool=' + json.dumps(shell), '-c', 'features.view_image=false',
                    '-c', 'features.code_mode=false', '-c', 'features.multi_agent=false', '-c', 'features.multi_agent_v2=false',
                    '-c', 'features.plugins=false', '-c', 'features.apps=false', '-c', 'features.hooks=false',
                    '-c', 'features.codex_hooks=false', '-c', 'features.skip_host_skill_discovery=true',
                    '-c', 'web_search="' + ('live' if args.tools and 'Web' in args.tools else 'disabled') + '"']
        else:
            if bypass_allowed(args, self.prefs):
                cmd += ['--dangerously-bypass-approvals-and-sandbox']
            else:
                cmd += ['--sandbox', 'read-only', '-c', 'approval_policy="never"']
            if not shell:
                cmd += ['-c', 'features.shell_tool=false']
        if not sealed and (args.strict_mcp_config or args.disallowedTools):
            if args.strict_mcp_config:
                cmd += ['-c', 'mcp_servers={}']
            config_files = [Path(account.get('home', HOME / '.codex')) / 'config.toml']
            config_files += [p / '.codex/config.toml' for p in [Path(args.cwd), *Path(args.cwd).parents]]
            for path in config_files:
                try:
                    text = path.read_text()
                except OSError:
                    continue
                for name in re.findall(r'^\[mcp_servers\.([A-Za-z0-9_-]+)\]', text, re.M):
                    if args.strict_mcp_config or any('mcp__' + name in tool for tool in args.disallowedTools.split(',')):
                        cmd += ['-c', 'mcp_servers.' + name + '.enabled=false']
        if args.disallowedTools:
            cmd += ['-c', 'features.apps=false', '-c', 'features.plugins=false']
        for config in args.mcp_config:
            if sealed:
                raise ValueError('An explicit MCP configuration cannot be added to a sealed tool allowlist.')
            value = json.loads(config) if config.lstrip().startswith('{') else json.loads((Path(args.cwd) / config).read_text())
            for name, server in value.get('mcpServers', {}).items():
                if server.get('type', 'stdio') not in ('stdio', 'http'):
                    raise ProviderUnavailable('This MCP transport requires Claude.')
                if 'command' in server:
                    entry = {key: server[key] for key in ('command', 'args', 'env') if key in server}
                elif 'url' in server:
                    entry = {'url': server['url'], 'http_headers': server.get('headers', {})}
                else:
                    raise ValueError('An MCP server needs a command or URL.')
                entry['enabled'] = not server.get('disabled', False)
                cmd += ['-c', 'mcp_servers=' + toml({name: entry})]
        if hooks:
            cmd += ['--dangerously-bypass-hook-trust', '-c', 'features.hooks=true', '-c', 'features.codex_hooks=true']
            for event, groups in hooks.items():
                cmd += ['-c', 'hooks.' + event + '=' + toml(groups)]
        if args.model and args.model not in ('haiku', 'sonnet', 'opus') and not args.model.startswith('claude-'):
            cmd += ['--model', args.model]
        if args.effort:
            cmd += ['-c', 'model_reasoning_effort=' + json.dumps(args.effort)]
        for path in args.add_dir:
            if not sealed:
                cmd += ['--add-dir', path]
        streamed = args.output_format == 'stream-json'
        emitted, received, started, activity = [], [], set(), {}
        def receive(line):
            event = provider_event(line)
            if event is None:
                return
            received.append(event)
            if event.get('type') == 'thread.started':
                self.backend = event.get('thread_id') or self.backend
            item = event.get('item', {})
            if event.get('type') in ('item.started', 'item.completed') and item.get('type') not in (None, 'agent_message', 'reasoning', 'error'):
                ident = item.get('id', str(uuid.uuid4()))
                complete = event['type'] == 'item.completed'
                activity[ident] = {'kind': 'activity', 'items': [dict(id=ident, type='commandExecution', command=item.get('command', item['type']),
                    aggregatedOutput=item.get('aggregated_output', json.dumps(item)) if complete else 'Outcome unknown: do not repeat without checking.',
                    status=item.get('status', 'completed') if complete else 'failed')]}
                self.activity = list(activity.values())
            events = []
            if event.get('type') in ('item.started', 'item.completed') and item.get('type') == 'command_execution':
                ident = item['id']
                if ident not in started:
                    started.add(ident)
                    events.append(dict(type='assistant', message={'content': [dict(type='tool_use', id=ident, name='Bash', input={'command': item.get('command', '')})]}))
                if event['type'] == 'item.completed':
                    events.append(dict(type='user', message={'content': [dict(type='tool_result', tool_use_id=ident, content=item.get('aggregated_output', ''), is_error=item.get('status') == 'failed')]}))
            if event.get('type') == 'item.completed' and item.get('type') == 'agent_message':
                events.append(dict(type='assistant', message={'role': 'assistant', 'content': [{'type': 'text', 'text': item['text']}]}))
            for value in events:
                emitted.append(value)
                self.stream_event(value)
        with tempfile.TemporaryDirectory(prefix='vcx-input-') as directory:
            for i, piece in enumerate(content):
                if piece.get('type') == 'image':
                    image = Path(directory) / (str(i) + '.png')
                    image.write_bytes(base64.b64decode(piece['source']['data'], validate=True))
                    cmd += ['--image', str(image)]
            if args.json_schema:
                schema = Path(directory) / 'schema.json'
                schema.write_text(args.json_schema)
                cmd += ['--output-schema', str(schema)]
            system = '\n\n'.join(filter(None, [args.system_prompt, args.append_system_prompt]))
            if system:
                cmd += ['-c', 'developer_instructions=' + json.dumps(system)]
            text = content_text(content)
            code, out, err = command(cmd + ['-'], text.encode(), environment(account), cwd=directory if sealed else None, on_line=receive)
        if not received:
            for line in out.splitlines():
                receive(line)
        events = received
        answers = [v['item']['text'] for v in events if v.get('type') == 'item.completed' and v.get('item', {}).get('type') == 'agent_message']
        failures = [v.get('error', {}).get('message', 'Codex turn failed') for v in events if v.get('type') == 'turn.failed']
        session = next((v['thread_id'] for v in events if v.get('type') == 'thread.started'), resume)
        text = failures[-1] if failures else answers[-1] if answers else err.decode(errors='replace') or 'Codex returned no answer.'
        rows = self.activity
        usage = next((v.get('usage', {}) for v in reversed(events) if v.get('type') == 'turn.completed'), {})
        result = {'is_error': code != 0 or bool(failures) or not answers, 'result': text, 'session_id': session, '_rows': rows,
                'usage': {'input_tokens': max(0, usage.get('input_tokens', 0) - usage.get('cached_input_tokens', 0)), 'cache_read_input_tokens': usage.get('cached_input_tokens', 0), 'output_tokens': usage.get('output_tokens', 0)}}
        if streamed:
            result.update(_events=emitted, _streamed=True)
        return result

    def qwen(self, account, content):
        if self.args.mcp_config:
            raise ProviderUnavailable('This task requires an MCP-capable provider.')
        ensure_qwen(self.prefs)
        args = self.args
        system = '\n\n'.join(filter(None, [args.system_prompt, args.append_system_prompt])) or 'You are Qwen in Vibe Code X. Complete the user request accurately. Check project instructions before changing files.'
        if args.tools is None:
            instructions = [HOME / '.claude/CLAUDE.md']
            for directory in reversed([Path(args.cwd), *Path(args.cwd).parents]):
                instructions += [directory / name for name in ('AGENTS.md', 'CLAUDE.md')]
            for path in dict.fromkeys(instructions):
                if path.is_file():
                    system += '\n\nInstructions from ' + str(path) + ':\n' + path.read_text()
            skills = []
            for root in [HOME / '.agents/skills', HOME / '.claude/skills', Path(args.cwd) / '.agents/skills', Path(args.cwd) / '.claude/skills']:
                skills += list(root.glob('*/SKILL.md'))
            for path in dict.fromkeys(p.resolve() for p in skills):
                metadata = re.match(r'---\s*\n(.*?)\n---', path.read_text(), re.S)
                if metadata:
                    system += '\n\nAvailable skill: ' + str(path) + '\n' + metadata[1]
            system += '\nRead the matching SKILL.md with run_command before performing a task that needs a listed skill.'
        messages = [{'role': 'system', 'content': system}]
        if self.context():
            messages.append({'role': 'user', 'content': 'Previous conversation:\n' + self.context()})
        message = {'role': 'user', 'content': content_text(content)}
        images = [p['source']['data'] for p in content if p.get('type') == 'image']
        if images:
            message['images'] = images
        messages.append(message)
        enabled = args.tools is None or 'Bash' in args.tools.split(',')
        if args.disallowedTools and 'Bash' in args.disallowedTools.split(','):
            enabled = False
        if enabled and (args.permission_mode not in (None, 'bypassPermissions', 'default') or not bypass_allowed(args, self.prefs)):
            raise ValueError('Qwen requires command approval; no command was run in the background.')
        tool = {'type': 'function', 'function': {'name': 'run_command', 'description': 'Run a shell command in the working folder.',
                'parameters': {'type': 'object', 'properties': {'command': {'type': 'string'}}, 'required': ['command']}}}
        rows = self.activity
        for _ in range(args.max_turns or 30):
            body = dict(model=self.prefs['qwenModel'], messages=messages, stream=False, think=False, keep_alive='5m')
            if enabled:
                body['tools'] = [tool]
            if args.json_schema:
                body['format'] = json.loads(args.json_schema)
            cmd = curl_args(self.prefs, self.prefs['qwenURL'], 120) + ['-H', 'Content-Type: application/json', '--data-binary', '@-']
            code, out, _ = command(cmd, json.dumps(body).encode(), timeout=125)
            if code:
                return {'is_error': True, 'result': 'Qwen request failed (' + str(code) + ').', '_rows': rows}
            response = json.loads(out)
            if response.get('error'):
                return {'is_error': True, 'result': response['error'], '_rows': rows}
            answer = response['message']
            messages.append(answer)
            calls = answer.get('tool_calls', [])
            if not calls:
                text = answer.get('content', '').rsplit('</think>', 1)[-1].strip()
                if '<think>' in text:
                    text = ''
                return {'is_error': not bool(text), 'result': text or 'Qwen returned no final answer.', 'session_id': 'qwen:' + self.record_id, '_rows': rows}
            for call in calls:
                function = call.get('function', {})
                script = function.get('arguments', {}).get('command', '')
                if not enabled or function.get('name') != 'run_command' or not script or '\0' in script or len(script) > 65536:
                    raise ValueError('Qwen requested a tool that this task does not allow.')
                if tool_denied({'tool_name': 'Bash', 'tool_input': {'command': script}}, args.disallowedTools):
                    messages.append({'role': 'tool', 'tool_name': 'run_command', 'content': 'The command is denied by this task. Do not retry it.'})
                    continue
                settings = read_json(HOME / '.codex/hooks.json') if args.setting_sources != '' else {}
                custom = json.loads(args.settings) if args.settings and args.settings.lstrip().startswith('{') else read_json(Path(args.settings)) if args.settings else {}
                allowed = True
                for group in settings.get('hooks', {}).get('PreToolUse', []) + custom.get('hooks', {}).get('PreToolUse', []):
                    if not re.search(group.get('matcher') or '.*', 'Bash'):
                        continue
                    for hook in group.get('hooks', []):
                        if hook.get('type') != 'command':
                            raise ValueError('Qwen cannot preserve this hook type.')
                        payload = json.dumps(dict(tool_name='Bash', tool_input={'command': script}, cwd=self.record['cwd'])).encode()
                        status, output, _ = command(['/bin/sh', '-c', hook['command']], payload, environment(account), timeout=hook.get('timeout', 30))
                        decision = json.loads(output) if output.strip() else {}
                        if status or decision.get('hookSpecificOutput', {}).get('permissionDecision') == 'deny':
                            allowed = False
                if not allowed:
                    messages.append({'role': 'tool', 'tool_name': 'run_command', 'content': 'The command was blocked by the permission hook. Do not retry it.'})
                    continue
                item = dict(id=str(uuid.uuid4()), type='commandExecution', command=script, aggregatedOutput='Outcome unknown: do not repeat without checking.', status='failed')
                rows.append({'kind': 'activity', 'items': [item]})
                code, out, err = command(['/bin/zsh', '-lc', script], env=environment(account), timeout=120)
                result = 'Exit: ' + str(code) + '\n' + (out + err).decode(errors='replace')[-16384:]
                messages.append({'role': 'tool', 'tool_name': 'run_command', 'content': result})
                item.update(aggregatedOutput=result, status='completed' if code == 0 else 'failed')
        return {'is_error': True, 'result': 'Qwen reached the tool-step limit; the task was not replayed.', '_rows': rows}


def emit(result, args):
    events = result.pop('_events', [])
    streamed = result.pop('_streamed', False)
    if result.get('is_error'):
        print(result.get('result', 'VCX failed.'), file=sys.stderr, flush=True)
    if args.output_format == 'json':
        print(json.dumps(result), flush=True)
    elif args.output_format == 'stream-json':
        for event in [] if streamed else events:
            if event.get('type') != 'result':
                print(json.dumps(event), flush=True)
        if not any(e.get('type') == 'assistant' and any(p.get('type') == 'text' for p in e.get('message', {}).get('content', [])) for e in events) and not streamed and result.get('result'):
            text = result['result']
            print(json.dumps({'type': 'stream_event', 'event': {'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'text_delta', 'text': text}}}), flush=True)
            print(json.dumps({'type': 'assistant', 'message': {'role': 'assistant', 'content': [{'type': 'text', 'text': text}]}}), flush=True)
        print(json.dumps(dict(result, type='result')), flush=True)
    else:
        print(result.get('result', ''), flush=True)


def main(argv=None):
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    values = sys.argv[1:] if argv is None else argv
    if len(values) == 2 and values[0] == '--check-denied-tools':
        if tool_denied(json.load(sys.stdin), values[1]):
            print('This tool invocation is denied by the task.', file=sys.stderr)
            return 2
        return 0
    if len(values) == 2 and values[0] == '--check-tools':
        payload = json.load(sys.stdin)
        allowed = set(values[1].split(','))
        tool = payload.get('tool_name', '')
        web = tool in ('web', 'web.run', 'webrun', 'web_search', 'web_search_preview', 'web_fetch', 'mcp__web__run')
        if tool not in allowed and not (web and allowed & {'WebSearch', 'WebFetch'}):
            print('This task does not allow tool ' + tool + '.', file=sys.stderr)
            return 2
        return 0
    if (argv or sys.argv[1:]) == ['--ensure-qwen']:
        ensure_qwen(preferences())
        return 0
    args = options(sys.argv[1:] if argv is None else argv)
    os.chdir(args.cwd)
    runner = Runner(args)
    try:
        if args.input_format == 'stream-json':
            status = 0
            for line in sys.stdin:
                value = json.loads(line)
                if value.get('type') != 'user':
                    continue
                content = value['message']['content']
                result = runner.turn([{'type': 'text', 'text': content}] if isinstance(content, str) else content)
                emit(result, args)
                status = int(bool(result.get('is_error')))
                if runner.cancelled:
                    return runner.cancelled
            return status
        text = ' '.join(args.prompt)
        if not sys.stdin.isatty():
            text += ('\n' if text else '') + sys.stdin.read()
        if not text.strip():
            raise ValueError('A background prompt is required.')
        result = runner.turn([{'type': 'text', 'text': text}])
        emit(result, args)
        return runner.cancelled or int(bool(result.get('is_error')))
    finally:
        runner.close()


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError) as error:
        print(json.dumps({'type': 'result', 'is_error': True, 'result': str(error)}), flush=True)
        sys.exit(1)
