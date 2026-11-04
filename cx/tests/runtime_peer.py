import atexit
import json
import os
import signal
import subprocess
import sys
import threading
from pathlib import Path


if sys.argv[1] == '--tool':
    directory = Path(sys.argv[2])
    temporary = directory / 'tool-started.tmp'
    temporary.write_text(json.dumps({'pid': os.getpid(), 'providerPID': os.getppid(), 'count': int(sys.argv[3])}))
    temporary.replace(directory / 'tool-started.json')
    with (directory / 'release-tool').open('rb', buffering=0) as gate:
        gate.read(1)
    sys.exit(0)

directory = Path(sys.argv[1])
output_lock = threading.Lock()
ledger_lock = threading.Lock()
turns = 0
approvals = 0
tool = None
preack = (directory / 'preack-mode').exists()
pending_turn_request = None


def close_tool():
    if tool is not None and tool.poll() is None:
        tool.terminate()
        tool.wait(timeout=2)


atexit.register(close_tool)
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))


def send(value):
    with output_lock:
        print(json.dumps(value), flush=True)


def record(name, value):
    with ledger_lock:
        temporary = directory / (name + '.tmp')
        temporary.write_text(json.dumps(value))
        temporary.replace(directory / name)


def event(method, params):
    send({'method': method, 'params': {'threadId': 'runtime-fixture-thread', **params}})


def running_turn():
    global tool
    event('turn/started', {'turn': {'id': 'runtime-fixture-turn'}})
    if not preack:
        event('item/started', {'item': {'id': 'runtime-fixture-tool', 'type': 'commandExecution', 'command': 'fixture-tool', 'status': 'inProgress'}})
        tool = subprocess.Popen([sys.executable, __file__, '--tool', str(directory), str(turns)], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        tool.wait()
        for delta in ['fixture ', 'stream ', 'continues']:
            event('item/agentMessage/delta', {'itemId': 'runtime-fixture-answer', 'delta': delta})
        event('item/completed', {'item': {'id': 'runtime-fixture-tool', 'type': 'commandExecution', 'command': 'fixture-tool', 'status': 'completed', 'exitCode': 0}})
    send({'id': 731, 'method': 'item/commandExecution/requestApproval', 'params': {'threadId': 'runtime-fixture-thread', 'turnId': 'runtime-fixture-turn', 'itemId': 'runtime-fixture-approved-tool', 'command': 'fixture-approved-tool'}})
    record('approval-pending.json', {'pid': os.getpid(), 'request': 731})


record('provider.json', {'pid': os.getpid(), 'cwd': os.getcwd()})
for line in sys.stdin:
    message = json.loads(line)
    method = message.get('method')
    if message.get('id') == 731 and 'result' in message:
        approvals += 1
        record('approval-result.json', {'pid': os.getpid(), 'count': approvals, 'result': message['result']})
        event('item/completed', {'item': {'id': 'runtime-fixture-approved-tool', 'type': 'commandExecution', 'command': 'fixture-approved-tool', 'status': 'completed', 'exitCode': 0}})
        event('item/completed', {'item': {'id': 'runtime-fixture-answer', 'type': 'agentMessage', 'text': 'fixture stream continues; fixture complete'}})
        event('turn/completed', {'turn': {'id': 'runtime-fixture-turn', 'status': 'completed'}})
        if pending_turn_request is not None:
            send({'id': pending_turn_request, 'result': {'turn': {'id': 'runtime-fixture-turn'}}})
            pending_turn_request = None
        record('turn-completed.json', {'pid': os.getpid(), 'turns': turns, 'approvals': approvals})
        continue
    if method == 'initialized' or method is None:
        continue
    result = {}
    if method == 'initialize':
        result = {'userAgent': 'runtime-fixture'}
    elif method == 'account/read':
        result = {'account': {'type': 'chatgpt'}}
    elif method in ('thread/start', 'thread/resume'):
        result = {'thread': {'id': 'runtime-fixture-thread'}, 'model': 'fixture-model', 'approvalPolicy': 'on-request', 'sandbox': {'type': 'workspaceWrite'}}
    elif method in ('thread/list', 'thread/turns/list'):
        result = {'data': []}
    elif method == 'model/list':
        result = {'data': [{'id': 'fixture-model', 'defaultReasoningEffort': 'high', 'supportedReasoningEfforts': [{'reasoningEffort': 'high'}]}]}
    elif method == 'turn/start':
        turns += 1
        record('turns.json', {'count': turns})
        result = {'turn': {'id': 'runtime-fixture-turn'}}
        if preack:
            pending_turn_request = message['id']
            threading.Thread(target=running_turn, daemon=True).start()
            continue
    elif method == 'turn/interrupt':
        record('interrupted.json', {'count': 1})
        event('turn/completed', {'turn': {'id': 'runtime-fixture-turn', 'status': 'interrupted'}})
    send({'id': message['id'], 'result': result})
    if method == 'turn/start':
        threading.Thread(target=running_turn, daemon=True).start()
