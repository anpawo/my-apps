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


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


# A frontend that leaves while its first attach still builds the session (crash, closed window) never saved a window
# file, so nothing can reattach it: the worker must end that session's agent and exit instead of keeping both forever.
def scenario():
    folder = tempfile.mkdtemp(dir='/tmp', prefix='vcx-dr-')
    address = folder + '/w.sock'
    env = dict(os.environ, VCX_RUNTIME_HOME=folder + '/runtime', VCX_CONFIG_HOME=folder + '/config')
    Path(folder + '/command.json').write_text(json.dumps(['/usr/bin/python3', str(PEER), folder]))
    log = open(folder + '/worker.log', 'w')
    worker = subprocess.Popen([str(BINARY), '--runtime-worker', address, '--runtime-test', '--runtime-fixture-command', folder + '/command.json'],
                              env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
    agent = None
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
        sock.sendall((json.dumps({'id': 'h', 'method': 'hello', 'params': {'protocol': 1}}) + '\n').encode())
        buffer = b''
        while b'\n' not in buffer:
            buffer += sock.recv(65536)
        attach = {'id': 'a', 'method': 'attach', 'params': {'sessionId': str(uuid.uuid4()), 'cwd': folder, 'prompt': ''}}
        # The attach and the disconnect reach the worker together: the session is built after its frontend left.
        sock.sendall((json.dumps(attach) + '\n').encode())
        sock.close()
        closed = time.monotonic()
        deadline = closed + 8
        while not Path(folder + '/provider.json').exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        if Path(folder + '/provider.json').exists():
            agent = json.loads(Path(folder + '/provider.json').read_text())['pid']
        while worker.poll() is None and time.monotonic() - closed < 15:
            time.sleep(0.1)
        exited = worker.poll() is not None
        agent_alive = agent is not None and alive(agent)
        detail = 'fake_agent=' + ('started' if agent else 'missing') + ' worker_pid=' + str(worker.pid)
        detail += (' worker_exited after=%.1fs' % (time.monotonic() - closed)) if exited else ' worker_alive_after=15s'
        detail += ' agent_alive=' + str(agent_alive)
        ok = agent is not None and exited and not agent_alive
        print(('ok ' if ok else 'FAIL ') + 'G3-superseded-first-attach ' + detail)
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
        print('  cleanup: worker pid ' + str(worker.pid) + ' reaped=' + str(worker.returncode is not None))
        if agent is not None:
            for _ in range(30):
                if not alive(agent):
                    break
                time.sleep(0.1)
            else:
                os.kill(agent, signal.SIGKILL)
            print('  cleanup: fake agent pid ' + str(agent) + ' gone')
        shutil.rmtree(folder, ignore_errors=True)


if not BINARY.exists():
    print('UNREACHED G3 no built binary at ' + str(BINARY))
    sys.exit(2)
sys.exit(0 if scenario() else 1)
