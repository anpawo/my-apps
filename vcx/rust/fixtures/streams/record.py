"""Records one real provider turn, every line both ways, as the VCX adapters speak to the agent.

    python3 -I record.py codex|claude <project folder> <raw output.jsonl>

The raw file holds account names, ids and paths: it stays outside the repo. `sanitize.py` turns it into the fixture
the tests replay. Each output line is {"t": milliseconds since start, "dir": "send"|"recv"|"stderr", "message": ...}.
"""
import json
import subprocess
import sys
import threading
import time
import uuid

PROMPT = 'Run the shell command `echo vcx` once, then reply with the single word: done.'
TURN_TIMEOUT = 300
REQUEST_TIMEOUT = 60

kind, project, output_path = sys.argv[1], sys.argv[2], sys.argv[3]
start = time.monotonic()
output = open(output_path, 'w')
lock = threading.Lock()
received = []
arrived = threading.Condition(lock)


def log(direction, message):
    output.write(json.dumps({'t': int((time.monotonic() - start) * 1000), 'dir': direction, 'message': message}) + '\n')
    output.flush()


if kind == 'codex':
    command = ['codex', 'app-server']
else:
    # No user settings (his hooks would print their context into the stream) and no MCP servers.
    command = ['claude', '-p', '--input-format', 'stream-json', '--output-format', 'stream-json', '--verbose',
               '--include-partial-messages', '--replay-user-messages', '--permission-prompt-tool', 'stdio',
               '--permission-mode', 'default', '--allow-dangerously-skip-permissions', '--setting-sources', 'project',
               '--strict-mcp-config', '--session-id', str(uuid.uuid4())]
agent = subprocess.Popen(command, cwd=project, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)


def send(message):
    with lock:
        log('send', message)
    agent.stdin.write(json.dumps(message) + '\n')
    agent.stdin.flush()


def read():
    for line in agent.stdout:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except ValueError:
            message = {'unparsed': line}
        with lock:
            log('recv', message)
            received.append(message)
            arrived.notify_all()
        answer(message)


def read_errors():
    for line in agent.stderr:
        with lock:
            log('stderr', line.rstrip('\n'))


def answer(message):
    if kind == 'codex' and 'id' in message and 'method' in message:
        send({'id': message['id'], 'result': {'decision': 'accept'}})
    if kind == 'claude' and message.get('type') == 'control_request':
        request = message.get('request', {})
        response = {'behavior': 'allow', 'updatedInput': request.get('input', {})}
        send({'type': 'control_response', 'response': {'subtype': 'success', 'request_id': message['request_id'], 'response': response}})


def wait(test, timeout):
    deadline = time.monotonic() + timeout
    with lock:
        while True:
            found = next((m for m in received if test(m)), None)
            if found is not None:
                return found
            left = deadline - time.monotonic()
            if left <= 0:
                raise SystemExit('timed out')
            arrived.wait(left)


threading.Thread(target=read, daemon=True).start()
threading.Thread(target=read_errors, daemon=True).start()

if kind == 'codex':
    def call(number, method, params):
        send({'id': number, 'method': method, 'params': params})
        return wait(lambda m: m.get('id') == number and 'method' not in m, REQUEST_TIMEOUT)

    call(1, 'initialize', {'clientInfo': {'name': 'vcx', 'title': 'Vibe Code X', 'version': '0.2.0'}, 'capabilities': {'experimentalApi': True}})
    send({'method': 'initialized'})
    call(2, 'account/read', {'refreshToken': False})
    call(3, 'model/list', {'limit': 100})
    thread = call(4, 'thread/start', {'cwd': project, 'approvalPolicy': 'on-request', 'sandbox': 'read-only', 'developerInstructions': ''})
    thread_id = thread['result']['thread']['id']
    call(5, 'turn/start', {'threadId': thread_id, 'input': [{'type': 'text', 'text': PROMPT}], 'cwd': project})
    wait(lambda m: m.get('method') == 'turn/completed', TURN_TIMEOUT)
else:
    send({'type': 'control_request', 'request_id': 'catalog', 'request': {'subtype': 'initialize'}})
    wait(lambda m: m.get('type') == 'control_response', REQUEST_TIMEOUT)
    send({'type': 'user', 'uuid': str(uuid.uuid4()), 'message': {'role': 'user', 'content': [{'type': 'text', 'text': PROMPT}]}})
    wait(lambda m: m.get('type') == 'result', TURN_TIMEOUT)

agent.stdin.close()
try:
    agent.wait(timeout=10)
except subprocess.TimeoutExpired:
    agent.terminate()
time.sleep(0.2)
with lock:
    output.close()
