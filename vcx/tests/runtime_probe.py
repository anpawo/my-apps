import errno
import json
import os
import signal
import socket
import subprocess
import sys
import time
import uuid
from pathlib import Path


checks = 0
submission = {'text': 'runtime fixture turn', 'images': []}


def check(condition, message):
    global checks
    if not condition:
        raise RuntimeError(message)
    checks += 1


def wait_file(path, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        failure = path.parent / 'frontend-error.json'
        if failure.exists():
            error = json.loads(failure.read_text())
            raise RuntimeError(error['stage'] + ': ' + error['error'])
        if path.exists():
            return json.loads(path.read_text())
        time.sleep(0.01)
    raise RuntimeError('fixture milestone timed out: ' + path.name)


def record(path, value):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value))
    temporary.replace(path)


class Channel:
    def __init__(self, address):
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.socket.settimeout(8)
        deadline = time.monotonic() + 8
        while True:
            try:
                self.socket.connect(address)
                break
            except (FileNotFoundError, ConnectionRefusedError):
                if time.monotonic() >= deadline:
                    raise RuntimeError('runtime socket did not become ready')
                time.sleep(0.02)
        self.buffer = b''
        self.revisions = []
        self.patches = []

    def send(self, method, params):
        identifier = str(uuid.uuid4())
        self.socket.sendall((json.dumps({'id': identifier, 'method': method, 'params': params}) + '\n').encode())
        return identifier

    def read(self):
        while b'\n' not in self.buffer:
            chunk = self.socket.recv(65536)
            if not chunk:
                raise RuntimeError('runtime channel closed')
            self.buffer += chunk
            if len(self.buffer) > 32 * 1024 * 1024:
                raise RuntimeError('runtime probe frame exceeded bound')
        line, self.buffer = self.buffer.split(b'\n', 1)
        return json.loads(line)

    def reply(self, identifier):
        while True:
            message = self.read()
            if message.get('method') == 'session/update':
                self.revisions.append(message['params']['revision'])
                self.patches.append(message['params']['patch'])
            if message.get('id') == identifier:
                return message

    def call(self, method, params):
        response = self.reply(self.send(method, params))
        if 'error' in response:
            raise RuntimeError('runtime rejected ' + method)
        return response['result']

    def attach(self, session_id, cwd):
        hello = self.call('hello', {'protocol': 1})
        self.maximum_frame = hello['maximumFrameBytes']
        self.runtime_pid = hello['pid']
        check(0 < self.maximum_frame <= 32 * 1024 * 1024, 'runtime frame limit is unbounded')
        check(self.maximum_frame <= hello['maximumBufferedBytes'] <= 64 * 1024 * 1024, 'runtime peer buffer limit is unbounded')
        return self.call('attach', {'sessionId': session_id, 'cwd': cwd})

    def perform(self, attached, sequence, action, params, expect_error=False):
        response = self.reply(self.send('perform', {'sessionId': attached['sessionId'], 'lease': attached['lease'], 'sequence': sequence, 'action': action, 'params': params}))
        check(('error' in response) == expect_error, 'runtime command acceptance did not match expectation')
        return response.get('result')


def state_checks(attached, directory):
    state = attached['state']
    check(state['threadID'] == 'runtime-fixture-thread', 'conversation identity changed')
    check(Path(state['cwd']).resolve() == directory.resolve(), 'working folder changed')
    pieces = [{key: piece[key] for key in ('text', 'path') if key in piece} for piece in state['draft']]
    check(pieces == [{'text': 'unsent fixture draft'}, {'path': str(directory / 'attachment.png')}], 'text or image draft changed')
    check(state['draftGeneration'] >= 1, 'draft generation moved backwards')


def frontend(stage, address, directory, session_id):
    channel = Channel(address)
    if stage == 'first':
        attached = channel.attach(session_id, str(directory))
        deadline = time.monotonic() + 8
        while not attached['state']['ready']:
            if time.monotonic() >= deadline:
                raise RuntimeError('fixture session did not become ready')
            time.sleep(0.02)
            attached = channel.call('attach', {'sessionId': session_id, 'cwd': str(directory)})
        channel.send('perform', {'sessionId': session_id, 'lease': attached['lease'], 'sequence': 1, 'action': 'send', 'params': submission})
        wait_file(directory / 'tool-started.json')
        channel.perform(attached, 2, 'checkpoint', {'draft': [{'text': 'unsent fixture draft'}, {'path': str(directory / 'attachment.png')}], 'generation': 1})
        attached = channel.call('attach', {'sessionId': session_id, 'cwd': str(directory)})
        record(directory / 'first-ready.json', {'lease': attached['lease'], 'runtimePID': channel.runtime_pid, 'rowIDs': [row['id'] for row in attached['state']['rows']], 'itemIDs': [item['id'] for row in attached['state']['rows'] for item in row['items']], 'checks': checks})
        signal.pause()
    elif stage == 'second':
        attached = channel.attach(session_id, str(directory))
        state_checks(attached, directory)
        check(attached['state']['busy'], 'running turn stopped with first frontend')
        check(attached['lastSequence'] == 2, 'accepted command high water changed')
        previous = wait_file(directory / 'first-ready.json')
        check(channel.runtime_pid == previous['runtimePID'], 'runtime process changed across frontend replacement')
        check([row['id'] for row in attached['state']['rows']][:len(previous['rowIDs'])] == previous['rowIDs'], 'row identity changed across attach')
        check([item['id'] for row in attached['state']['rows'] for item in row['items']][:len(previous['itemIDs'])] == previous['itemIDs'], 'item identity changed across attach')
        channel.perform(attached, 1, 'send', submission)
        channel.perform(attached, 1, 'send', {'text': 'different payload', 'images': []}, expect_error=True)
        stale = {**attached, 'lease': wait_file(directory / 'first-ready.json')['lease']}
        channel.perform(stale, 3, 'stop', {}, expect_error=True)
        record(directory / 'second-ready.json', {'checks': checks})
        wait_file(directory / 'approval-pending.json')
        deadline = time.monotonic() + 8
        while True:
            attached = channel.call('attach', {'sessionId': session_id, 'cwd': str(directory)})
            permissions = attached['state']['permissions']
            if permissions and channel.patches:
                break
            if time.monotonic() > deadline:
                raise RuntimeError('runtime lost pending approval')
            time.sleep(0.02)
        check(len(permissions) == 1 and permissions[0]['rpcID'] == 731, 'typed provider approval identity changed')
        check(not (directory / 'interrupted.json').exists(), 'stale frontend interrupted the turn')
        check(all(a < b for a, b in zip(channel.revisions, channel.revisions[1:])), 'update revisions are not ordered')
        check(bool(channel.patches) and all('rows' not in patch for patch in channel.patches), 'streaming update retransmitted full transcript rows')
        record(directory / 'second-approval.json', {'permission': permissions[0], 'checks': checks})
        signal.pause()
    else:
        attached = channel.attach(session_id, str(directory))
        state_checks(attached, directory)
        check(channel.runtime_pid == wait_file(directory / 'first-ready.json')['runtimePID'], 'runtime process changed while approval was pending')
        previous = wait_file(directory / 'second-approval.json')['permission']
        permission = attached['state']['permissions'][0]
        check(permission['id'] == previous['id'] and permission['rpcID'] == previous['rpcID'], 'approval changed across frontend replacement')
        answer = {'rpcID': permission['rpcID'], 'method': permission['method'], 'result': {'decision': 'accept'}}
        channel.perform(attached, 3, 'answer', answer)
        wait_file(directory / 'turn-completed.json')
        channel.perform(attached, 3, 'answer', answer)
        channel.perform(attached, 4, 'answer', answer, expect_error=True)
        deadline = time.monotonic() + 8
        while True:
            attached = channel.call('attach', {'sessionId': session_id, 'cwd': str(directory)})
            if not attached['state']['busy']:
                break
            if time.monotonic() > deadline:
                raise RuntimeError('completed turn remained busy')
            time.sleep(0.02)
        check(not attached['state']['permissions'], 'answered approval remained pending')
        check('fixture stream continues; fixture complete' in json.dumps(attached['state']['rows']), 'streamed result did not survive replacement')
        channel.perform(attached, 5, 'command', {'text': '/vcx:quit'}, expect_error=True)
        channel.perform(attached, 6, 'send', {'text': '/quit', 'images': []}, expect_error=True)
        bad = Channel(address)
        rejected = bad.reply(bad.send('hello', {'protocol': 999}))
        check('error' in rejected, 'incompatible protocol was accepted')
        bad.socket.close()
        oversized = Channel(address)
        oversized.call('hello', {'protocol': 1})
        try:
            oversized.socket.sendall(json.dumps({'id': 'oversized', 'method': 'hello', 'params': {'protocol': 1, 'padding': 'x' * channel.maximum_frame}}).encode() + b'\n')
        except (BrokenPipeError, ConnectionResetError):
            pass
        try:
            check(not oversized.socket.recv(1), 'oversized frame remained connected')
        except ConnectionResetError:
            check(True, 'oversized frame was rejected')
        oversized.socket.close()
        channel.call('hello', {'protocol': 1})
        check(True, 'runtime remained usable after oversized frame')
        channel.socket.settimeout(0.25)
        try:
            while True:
                channel.read()
        except socket.timeout:
            pass
        try:
            channel.read()
            raise RuntimeError('idle session emitted an unsolicited update')
        except socket.timeout:
            check(True, 'idle stream stayed quiet')
        record(directory / 'third-done.json', {'checks': checks})


def preack_check(address, directory):
    for name in ['approval-pending.json', 'approval-result.json', 'turn-completed.json', 'turns.json']:
        (directory / name).unlink(missing_ok=True)
    (directory / 'preack-mode').touch()
    session_id = str(uuid.uuid4())
    original, replacement = Channel(address), Channel(address)
    try:
        attached = original.attach(session_id, str(directory))
        deadline = time.monotonic() + 8
        while not attached['state']['ready']:
            if time.monotonic() >= deadline:
                raise RuntimeError('pre-ack fixture session did not become ready')
            time.sleep(0.02)
            attached = original.call('attach', {'sessionId': session_id, 'cwd': str(directory)})
        submitted_draft = [{'text': submission['text']}]
        payload = {**submission, 'draft': submitted_draft, 'generation': 1}
        pending = original.send('perform', {'sessionId': session_id, 'lease': attached['lease'], 'sequence': 1, 'action': 'send', 'params': payload})
        wait_file(directory / 'approval-pending.json')
        original.perform(attached, 2, 'checkpoint', {'draft': submitted_draft, 'generation': 1})
        attached = original.call('attach', {'sessionId': session_id, 'cwd': str(directory)})
        check(not attached['state']['draft'], 'late checkpoint restored the consumed submission draft')
        draft = [{'text': 'unsent fixture draft'}, {'path': str(directory / 'attachment.png')}]
        original.perform(attached, 3, 'checkpoint', {'draft': draft, 'generation': 2, 'windowState': {'follow': False}})
        attached = replacement.attach(session_id, str(directory))
        state_checks(attached, directory)
        check(attached['state']['draftGeneration'] == 2, 'newer pre-ack draft generation was lost')
        check(attached['state']['busy'] and len(attached['state']['permissions']) == 1, 'pre-ack approval or running state was lost')
        check(attached['state']['windowState'] == {'follow': False}, 'pre-ack checkpoint lost window state')
        permission = attached['state']['permissions'][0]
        replacement.perform(attached, 4, 'answer', {'rpcID': permission['rpcID'], 'method': permission['method'], 'result': {'decision': 'accept'}})
        check('error' not in original.reply(pending), 'accepted pre-ack submission failed after frontend replacement')
        replacement.perform(attached, 1, 'send', payload)
        completed = wait_file(directory / 'turn-completed.json')
        check(completed['turns'] == 1 and completed['approvals'] == 1, 'pre-ack submission or approval repeated')
        attached = replacement.call('attach', {'sessionId': session_id, 'cwd': str(directory)})
        state_checks(attached, directory)
    finally:
        original.socket.close()
        replacement.socket.close()


def controller(address, directory):
    global checks
    session_id = str(uuid.uuid4())
    clients = []
    try:
        for stage, milestone in [('first', 'first-ready.json'), ('second', 'second-approval.json'), ('third', 'third-done.json')]:
            process = subprocess.Popen([sys.executable, __file__, '--frontend', stage, address, str(directory), session_id], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            clients.append(process)
            record(directory / 'clients.json', {'pids': [client.pid for client in clients]})
            if stage == 'second':
                wait_file(directory / 'second-ready.json')
                started = wait_file(directory / 'tool-started.json')
                os.kill(started['pid'], 0)
                os.kill(started['providerPID'], 0)
                check(True, 'provider and running tool survived frontend death')
                deadline = time.monotonic() + 8
                while True:
                    try:
                        descriptor = os.open(directory / 'release-tool', os.O_WRONLY | os.O_NONBLOCK)
                        os.write(descriptor, b'1')
                        os.close(descriptor)
                        break
                    except OSError as error:
                        if error.errno != errno.ENXIO or time.monotonic() > deadline:
                            raise
                        time.sleep(0.01)
            outcome = wait_file(directory / milestone)
            if stage != 'third':
                process.kill()
            process.wait(timeout=3)
            if stage == 'third':
                check(process.returncode == 0, 'replacement frontend failed')
            checks += outcome['checks']
        provider = wait_file(directory / 'provider.json')
        completed = wait_file(directory / 'turn-completed.json')
        check(provider['pid'] == completed['pid'], 'provider process was replaced')
        check(completed['turns'] == 1 and completed['approvals'] == 1, 'submission or approval executed more than once')
        check(wait_file(directory / 'tool-started.json')['count'] == 1, 'tool side effect repeated')
        check(not (directory / 'interrupted.json').exists(), 'frontend replacement interrupted provider')
        record(directory / 'session.json', {'sessionId': session_id})
        preack_check(address, directory)
    finally:
        for process in clients:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=3)


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    try:
        if sys.argv[1] == '--frontend':
            frontend(sys.argv[2], sys.argv[3], Path(sys.argv[4]), sys.argv[5])
        else:
            controller(sys.argv[1], Path(sys.argv[2]))
            print(json.dumps({'checks': checks}))
    except Exception as error:
        if len(sys.argv) > 1 and sys.argv[1] == '--frontend':
            record(Path(sys.argv[4]) / 'frontend-error.json', {'stage': sys.argv[2], 'error': str(error)})
        print(json.dumps({'error': str(error)}), flush=True)
        sys.exit(1)
