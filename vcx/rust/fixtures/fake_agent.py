"""A stand-in for `codex app-server` that answers one turn with a tool call and a streamed Markdown answer.

The Swift worker starts it through `--runtime-test --runtime-fixture-command`, so interop tests need no account.
"""
import json
import sys
import threading

THREAD = 'fixture-thread'
TURN = 'fixture-turn'
ANSWER = '## Fixture answer\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nDone with **bold** text.'
output_lock = threading.Lock()


def send(value):
    with output_lock:
        print(json.dumps(value), flush=True)


def event(method, params):
    send({'method': method, 'params': {'threadId': THREAD, **params}})


def run_turn():
    event('turn/started', {'turn': {'id': TURN}})
    tool = {'id': 'fixture-tool', 'type': 'commandExecution', 'command': 'echo fixture'}
    event('item/started', {'item': {**tool, 'status': 'inProgress'}})
    event('item/completed', {'item': {**tool, 'status': 'completed', 'exitCode': 0, 'aggregatedOutput': 'fixture\n'}})
    for word in ANSWER.split(' '):
        event('item/agentMessage/delta', {'itemId': 'fixture-answer', 'delta': word + ' '})
    event('item/completed', {'item': {'id': 'fixture-answer', 'type': 'agentMessage', 'text': ANSWER}})
    event('turn/completed', {'turn': {'id': TURN, 'status': 'completed'}})


RESULTS = {
    'initialize': {'userAgent': 'fixture'},
    'account/read': {'account': {'type': 'chatgpt'}},
    'thread/start': {'thread': {'id': THREAD}, 'model': 'fixture-model', 'approvalPolicy': 'never', 'sandbox': {'type': 'dangerFullAccess'}},
    'thread/list': {'data': []},
    'thread/turns/list': {'data': []},
    'model/list': {'data': [{'id': 'fixture-model', 'defaultReasoningEffort': 'high', 'supportedReasoningEfforts': [{'reasoningEffort': 'high'}]}]},
    'turn/start': {'turn': {'id': TURN}},
}
RESULTS['thread/resume'] = RESULTS['thread/start']

for line in sys.stdin:
    message = json.loads(line)
    method = message.get('method')
    if method is None or 'id' not in message:
        continue
    send({'id': message['id'], 'result': RESULTS.get(method, {})})
    if method == 'turn/start':
        threading.Thread(target=run_turn, daemon=True).start()
    elif method == 'turn/interrupt':
        event('turn/completed', {'turn': {'id': TURN, 'status': 'interrupted'}})
