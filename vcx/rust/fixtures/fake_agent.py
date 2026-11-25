"""A stand-in for `codex app-server` that answers one turn with a tool call and a streamed Markdown answer.

The Swift worker starts it through `--runtime-test --runtime-fixture-command`, so interop tests need no account.
With `--history <file>` it also behaves as Codex does across restarts: each thread gets its own id, the prompt comes
back as a userMessage item, and finished turns are kept in the file for `thread/resume` and `thread/turns/list`.
"""
import json
import os
import sys
import threading
import uuid

THREAD = 'fixture-thread'
TURN = 'fixture-turn'
ANSWER = '## Fixture answer\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nDone with **bold** text.'
HISTORY = sys.argv[sys.argv.index('--history') + 1] if '--history' in sys.argv else None
output_lock = threading.Lock()


def send(value):
    with output_lock:
        print(json.dumps(value), flush=True)


def event(method, params, thread=THREAD):
    send({'method': method, 'params': {'threadId': thread, **params}})


def load():
    try:
        with open(HISTORY) as file:
            return json.load(file)
    except FileNotFoundError:
        return {}


def save(threads):
    temporary = HISTORY + '.tmp'
    with open(temporary, 'w') as file:
        json.dump(threads, file)
    os.replace(temporary, HISTORY)


def run_turn(thread=THREAD, turn=TURN, prompt=None):
    event('turn/started', {'turn': {'id': turn}}, thread)
    items = []
    if prompt is not None:
        event('item/started', {'item': prompt}, thread)
        event('item/completed', {'item': prompt}, thread)
        items.append(prompt)
    tool = {'id': 'fixture-tool', 'type': 'commandExecution', 'command': 'echo fixture'}
    if HISTORY:
        tool['id'] = 'fixture-tool-' + turn
    event('item/started', {'item': {**tool, 'status': 'inProgress'}}, thread)
    done = {**tool, 'status': 'completed', 'exitCode': 0, 'aggregatedOutput': 'fixture\n'}
    event('item/completed', {'item': done}, thread)
    answer_id = 'fixture-answer-' + turn if HISTORY else 'fixture-answer'
    for word in ANSWER.split(' '):
        event('item/agentMessage/delta', {'itemId': answer_id, 'delta': word + ' '}, thread)
    answer = {'id': answer_id, 'type': 'agentMessage', 'text': ANSWER}
    event('item/completed', {'item': answer}, thread)
    if HISTORY:
        threads = load()
        threads.setdefault(thread, []).append({'id': turn, 'status': 'completed', 'items': items + [done, answer]})
        save(threads)
    event('turn/completed', {'turn': {'id': turn, 'status': 'completed'}}, thread)


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


def answer_with_history(message):
    method, params = message['method'], message.get('params') or {}
    thread = params.get('threadId')
    if method == 'thread/start':
        thread = 'fixture-thread-' + uuid.uuid4().hex[:12]
        threads = load()
        threads[thread] = []
        save(threads)
        return {**RESULTS['thread/start'], 'thread': {'id': thread}}, None
    if method in ('thread/resume', 'thread/turns/list') and thread not in load():
        return None, {'code': -32600, 'message': 'thread not found: ' + str(thread)}
    if method == 'thread/resume':
        return {**RESULTS['thread/resume'], 'thread': {'id': thread}}, None
    if method == 'thread/turns/list':
        return {'data': load()[thread], 'nextCursor': None}, None
    if method == 'turn/start':
        turn = 'fixture-turn-' + uuid.uuid4().hex[:12]
        prompt = {'id': 'fixture-user-' + turn, 'type': 'userMessage', 'clientId': params.get('clientUserMessageId'), 'content': params.get('input', [])}
        threading.Timer(0, run_turn, (thread, turn, prompt)).start()
        return {'turn': {'id': turn}}, None
    return RESULTS.get(method, {}), None


for line in sys.stdin:
    message = json.loads(line)
    method = message.get('method')
    if method is None or 'id' not in message:
        continue
    if HISTORY:
        result, error = answer_with_history(message)
        send({'id': message['id'], 'error': error} if error else {'id': message['id'], 'result': result})
        if method == 'turn/interrupt':
            event('turn/completed', {'turn': {'id': (message.get('params') or {}).get('turnId'), 'status': 'interrupted'}}, (message.get('params') or {}).get('threadId'))
        continue
    send({'id': message['id'], 'result': RESULTS.get(method, {})})
    if method == 'turn/start':
        threading.Thread(target=run_turn, daemon=True).start()
    elif method == 'turn/interrupt':
        event('turn/completed', {'turn': {'id': TURN, 'status': 'interrupted'}})
