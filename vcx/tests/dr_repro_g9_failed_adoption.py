import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import uuid

BINARY = Path(__file__).parents[1] / '.build/debug/VCX'


# A worker re-executed by a live update adopts each session from its manifest. One that does not decode (here a Claude
# account this build cannot read) must not leave its agent running on pipes nobody reads or closes.
def scenario():
    folder = tempfile.mkdtemp(dir='/tmp', prefix='vcx-dr-')
    runtime = Path(folder) / 'runtime'
    runtime.mkdir(mode=0o700)
    address = folder + '/w.sock'
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(address)
    listener.listen(8)
    lock = os.open(address + '.lock', os.O_CREAT | os.O_RDWR, 0o600)
    agent = subprocess.Popen(['/usr/bin/python3', '-c', 'import sys; sys.stdin.buffer.read()'], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    build = hashlib.sha256(BINARY.read_bytes()).hexdigest()
    session = {'sessionId': str(uuid.uuid4()).upper(), 'revision': 0, 'lastSequence': 0, 'backend': {
        'snapshot': {'cwd': folder, 'stateDirectory': folder + '/state'}, 'session': {},
        'connection': {'kind': 'claude', 'account': {'unknown': True}, 'cwd': folder, 'initialDirectory': folder, 'thread': 'fixture-thread',
                       'agent': {'pid': agent.pid, 'input': agent.stdin.fileno(), 'output': agent.stdout.fileno(), 'leftover': ''}}}}
    manifest = {'version': 1, 'build': build, 'instanceID': str(uuid.uuid4()).upper(), 'listener': listener.fileno(), 'lock': lock,
                'closedIDs': [], 'sessions': [session]}
    ticket = runtime / (str(uuid.uuid4()).upper() + '.swap.json')
    descriptor = os.open(ticket, os.O_CREAT | os.O_WRONLY | os.O_EXCL, 0o600)
    os.write(descriptor, json.dumps(manifest).encode())
    os.close(descriptor)
    env = dict(os.environ, VCX_RUNTIME_HOME=str(runtime), VCX_CONFIG_HOME=folder + '/config')
    log = open(folder + '/worker.log', 'w')
    worker = subprocess.Popen([str(BINARY), '--runtime-worker', address, '--runtime-test', '--adopt', str(ticket)], env=env,
                              stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                              pass_fds=(listener.fileno(), lock, agent.stdin.fileno(), agent.stdout.fileno()))
    # From here on only the worker holds the agent's pipes, as after a real execv.
    listener.close(); os.close(lock); agent.stdin.close(); agent.stdout.close()
    client = None
    try:
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.settimeout(8)
        deadline = time.monotonic() + 8
        while True:
            try:
                client.connect(address)
                break
            except (FileNotFoundError, ConnectionRefusedError):
                if time.monotonic() > deadline or worker.poll() is not None:
                    raise RuntimeError('adopted worker never answered')
                time.sleep(0.05)
        # A connected frontend keeps the worker up, as one reattaching its other sessions would.
        client.sendall((json.dumps({'id': 'h', 'method': 'hello', 'params': {'protocol': 1}}) + '\n').encode())
        reply = b''
        while b'\n' not in reply:
            reply += client.recv(65536)
        hello = json.loads(reply.split(b'\n')[0])
        started = time.monotonic()
        while agent.poll() is None and time.monotonic() - started < 5:
            time.sleep(0.1)
        exited = agent.poll() is not None
        logged = 'was not adopted' in Path(folder + '/worker.log').read_text()
        detail = 'hello=' + ('ok' if 'result' in hello else 'error') + ' adoption_failed_logged=' + str(logged) + ' agent_pid=' + str(agent.pid)
        detail += (' agent_exited after=%.1fs' % (time.monotonic() - started)) if exited else ' agent_alive_after=5s'
        ok = logged and exited
        print(('ok ' if ok else 'FAIL ') + 'G9-failed-adoption-ends-agent ' + detail)
        return ok
    finally:
        if client is not None:
            client.close()
        if worker.poll() is None:
            os.kill(worker.pid, signal.SIGTERM)
            try:
                worker.wait(3)
            except subprocess.TimeoutExpired:
                os.kill(worker.pid, signal.SIGKILL)
                worker.wait()
        log.close()
        print('  cleanup: worker pid ' + str(worker.pid) + ' reaped=' + str(worker.returncode is not None))
        if agent.poll() is None:
            agent.kill()
        agent.wait()
        print('  cleanup: agent pid ' + str(agent.pid) + ' reaped=' + str(agent.returncode is not None))
        shutil.rmtree(folder, ignore_errors=True)


if not BINARY.exists():
    print('UNREACHED G9 no built binary at ' + str(BINARY))
    sys.exit(2)
sys.exit(0 if scenario() else 1)
