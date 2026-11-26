"""A stand-in for `codex app-server` that answers one turn with a tool call and a streamed Markdown answer.

The Swift worker starts it through `--runtime-test --runtime-fixture-command`, so interop tests need no account.
With `--history <file>` it also behaves as Codex does across restarts: each thread gets its own id, the prompt comes
back as a userMessage item, and finished turns are kept in the file for `thread/resume` and `thread/turns/list`.
A prompt holding `fixture:hold` starts a turn that stays open until `turn/interrupt`; one holding `fixture:approve`
also asks for a command approval and ends once it is answered, accepted or declined. `fixture:limit` fails the turn
on the plan's usage limit unless the prompt carries the context VCX hands a fallback account; `fixture:ratelimit` fails
it on a server rate limit; `fixture:crash` writes an error to stderr and exits.
"""
import json
import os
import time
import sys
import threading
import uuid

THREAD = 'fixture-thread'
TURN = 'fixture-turn'
ANSWER = '## Fixture answer\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nDone with **bold** text.'
HISTORY = sys.argv[sys.argv.index('--history') + 1] if '--history' in sys.argv else None
HOLD = 'fixture:hold'
APPROVE = 'fixture:approve'
APPROVAL_ID = 7301
LIMIT = 'fixture:limit'
RATE_LIMIT = 'fixture:ratelimit'
CRASH = 'fixture:crash'
HANDOFF = 'Context from this conversation'
CRASH_STATUS = 3
LIMIT_ERROR = {'message': "You've hit your usage limit.", 'codexErrorInfo': 'usageLimitExceeded'}
RATE_LIMIT_ERROR = {'message': 'exceeded retry limit, last status: 429 Too Many Requests'}
HELD_TOOL = {'id': 'fixture-held-tool', 'type': 'commandExecution', 'command': 'fixture-held-tool'}
output_lock = threading.Lock()
awaiting = {}


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


def prompt_text(params):
    return ' '.join(piece.get('text', '') for piece in params.get('input', []) if isinstance(piece, dict))


def held(params):
    text = prompt_text(params)
    return HOLD in text or APPROVE in text


def failure(params):
    """The error the prompt names, `CRASH` for a crash, or None."""
    text = prompt_text(params)
    pieces = params.get('input', [])
    handed_off = bool(pieces) and isinstance(pieces[0], dict) and pieces[0].get('text', '').startswith(HANDOFF)
    if CRASH in text:
        return CRASH
    return LIMIT_ERROR if LIMIT in text and not handed_off else RATE_LIMIT_ERROR if RATE_LIMIT in text else None


def fail_turn(thread, turn, error):
    if error == CRASH:
        print('fatal: fixture crashed', file=sys.stderr, flush=True)
        time.sleep(0.1)
        os._exit(CRASH_STATUS)
    event('turn/started', {'turn': {'id': turn}}, thread)
    event('turn/completed', {'turn': {'id': turn, 'status': 'failed', 'error': error}}, thread)


def open_turn(thread, turn, params):
    event('turn/started', {'turn': {'id': turn}}, thread)
    event('item/started', {'item': {**HELD_TOOL, 'status': 'inProgress'}}, thread)
    if APPROVE in prompt_text(params):
        awaiting[APPROVAL_ID] = (thread, turn)
        request = {'threadId': thread, 'turnId': turn, 'itemId': HELD_TOOL['id'], 'command': HELD_TOOL['command']}
        send({'id': APPROVAL_ID, 'method': 'item/commandExecution/requestApproval', 'params': request})


def answered(message):
    thread, turn = awaiting.pop(message['id'])
    accepted = (message.get('result') or {}).get('decision') == 'accept'
    tool = {**HELD_TOOL, 'status': 'completed' if accepted else 'declined', 'exitCode': 0 if accepted else None}
    event('item/completed', {'item': tool}, thread)
    answer = {'id': 'fixture-held-answer', 'type': 'agentMessage', 'text': 'approved' if accepted else 'declined'}
    event('item/completed', {'item': answer}, thread)
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


def policy(result, params):
    """Echoes an asking policy, as Codex does: the thread then runs sandboxed."""
    if params.get('approvalPolicy') != 'on-request':
        return result
    return {**result, 'approvalPolicy': 'on-request', 'sandbox': {'type': 'workspaceWrite'}}


def answer_with_history(message):
    method, params = message['method'], message.get('params') or {}
    thread = params.get('threadId')
    if method == 'thread/start':
        thread = 'fixture-thread-' + uuid.uuid4().hex[:12]
        threads = load()
        threads[thread] = []
        save(threads)
        return policy({**RESULTS['thread/start'], 'thread': {'id': thread}}, params), None
    if method in ('thread/resume', 'thread/turns/list') and thread not in load():
        return None, {'code': -32600, 'message': 'thread not found: ' + str(thread)}
    if method == 'thread/resume':
        return {**RESULTS['thread/resume'], 'thread': {'id': thread}}, None
    if method == 'thread/turns/list':
        return {'data': load()[thread], 'nextCursor': None}, None
    if method == 'turn/start':
        turn = 'fixture-turn-' + uuid.uuid4().hex[:12]
        prompt = {'id': 'fixture-user-' + turn, 'type': 'userMessage', 'clientId': params.get('clientUserMessageId'), 'content': params.get('input', [])}
        if failure(params):
            threading.Timer(0, fail_turn, (thread, turn, failure(params))).start()
        elif held(params):
            threading.Timer(0, open_turn, (thread, turn, params)).start()
        else:
            threading.Timer(0, run_turn, (thread, turn, prompt)).start()
        return {'turn': {'id': turn}}, None
    return RESULTS.get(method, {}), None


for line in sys.stdin:
    message = json.loads(line)
    method = message.get('method')
    if method is None and message.get('id') in awaiting:
        answered(message)
        continue
    if method is None or 'id' not in message:
        continue
    if HISTORY:
        result, error = answer_with_history(message)
        send({'id': message['id'], 'error': error} if error else {'id': message['id'], 'result': result})
        if method == 'turn/interrupt':
            awaiting.clear()
            event('turn/completed', {'turn': {'id': (message.get('params') or {}).get('turnId'), 'status': 'interrupted'}}, (message.get('params') or {}).get('threadId'))
        continue
    params = message.get('params') or {}
    send({'id': message['id'], 'result': policy(RESULTS.get(method, {}), params) if method == 'thread/start' else RESULTS.get(method, {})})
    if method == 'turn/start' and failure(params):
        fail_turn(THREAD, TURN, failure(params))
    elif method == 'turn/start' and held(params):
        threading.Thread(target=open_turn, args=(THREAD, TURN, message.get('params') or {}), daemon=True).start()
    elif method == 'turn/start':
        threading.Thread(target=run_turn, daemon=True).start()
    elif method == 'turn/interrupt':
        awaiting.clear()
        event('turn/completed', {'turn': {'id': TURN, 'status': 'interrupted'}})
