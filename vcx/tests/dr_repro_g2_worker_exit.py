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
PEER = Path(__file__).with_name('runtime_peer.py')


def request(sock, buffer, method, params):
    ident = str(uuid.uuid4())
    sock.sendall((json.dumps({'id': ident, 'method': method, 'params': params}) + '\n').encode())
    while True:
        while b'\n' not in buffer[0]:
            chunk = sock.recv(65536)
            if not chunk:
                raise RuntimeError('worker closed the channel')
            buffer[0] += chunk
        line, buffer[0] = buffer[0].split(b'\n', 1)
        message = json.loads(line)
        if message.get('id') == ident:
            return message


def scenario(name, attach, live=False):
    folder = tempfile.mkdtemp(dir='/tmp', prefix='vcx-dr-')
    address = folder + '/w.sock'
    env = dict(os.environ, VCX_RUNTIME_HOME=folder + '/runtime', VCX_CONFIG_HOME=folder + '/config')
    log = open(folder + '/worker.log', 'w')
    command = []
    if live:
        Path(folder + '/command.json').write_text(json.dumps(['/usr/bin/python3', str(PEER), folder]))
        command = ['--runtime-fixture-command', folder + '/command.json']
    worker = subprocess.Popen([str(BINARY), '--runtime-worker', address, '--runtime-test', *command], env=env,
                              stdin=subprocess.DEVNULL, stdout=log, stderr=log)
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(8)
        deadline = time.monotonic() + 8
        while True:
            try:
                sock.connect(address)
                break
            except (FileNotFoundError, ConnectionRefusedError):
                if time.monotonic() > deadline or worker.poll() is not None:
                    raise RuntimeError('worker socket never became ready')
                time.sleep(0.05)
        buffer = [b'']
        hello = request(sock, buffer, 'hello', {'protocol': 1})
        detail = 'hello=' + ('ok' if 'result' in hello else hello['error']['code'])
        if attach:
            reply = request(sock, buffer, 'attach', {'sessionId': str(uuid.uuid4()), 'cwd': folder if live else folder + '/missing', 'prompt': ''})
            detail += ' attach=' + (reply['error']['code'] if 'error' in reply else 'accepted')
        if live:
            deadline = time.monotonic() + 8
            while not Path(folder + '/provider.json').exists() and time.monotonic() < deadline:
                time.sleep(0.05)
            detail += ' fake_agent=' + ('started' if Path(folder + '/provider.json').exists() else 'missing')
        sock.close()
        closed = time.monotonic()
        while worker.poll() is None and time.monotonic() - closed < 10:
            time.sleep(0.1)
        exited = worker.poll() is not None
        expected = not live
        detail += ' worker_pid=' + str(worker.pid) + ' exited=' + str(exited) + (' after=%.1fs code=%s' % (time.monotonic() - closed, worker.returncode) if exited else ' alive_after=10s')
        ok = exited == expected and (not live or 'fake_agent=started' in detail)
        print(('ok ' if ok else 'FAIL ') + name + ' ' + detail)
        return ok
    finally:
        if worker.poll() is None:
            os.kill(worker.pid, signal.SIGTERM)
            try:
                worker.wait(3)
            except subprocess.TimeoutExpired:
                os.kill(worker.pid, signal.SIGKILL)
                worker.wait()
        log.close()
        print('  cleanup ' + name + ': pid ' + str(worker.pid) + ' reaped=' + str(worker.returncode is not None))
        if live and Path(folder + '/provider.json').exists():
            agent = json.loads(Path(folder + '/provider.json').read_text())['pid']
            for _ in range(30):
                try:
                    os.kill(agent, 0)
                except ProcessLookupError:
                    break
                time.sleep(0.1)
            else:
                os.kill(agent, signal.SIGKILL)
            print('  cleanup ' + name + ': fake agent pid ' + str(agent) + ' gone')
        shutil.rmtree(folder, ignore_errors=True)


if not BINARY.exists():
    print('UNREACHED G2 no built binary at ' + str(BINARY))
    sys.exit(2)
results = [scenario('G2a-disconnect-before-attach', False), scenario('G2b-rejected-attach', True),
           scenario('G2c-live-session-stays', True, live=True)]
sys.exit(0 if all(results) else 1)
