"""A stand-in for `codex app-server` that answers one turn with a tool call and a streamed Markdown answer.

The Swift worker starts it through `--runtime-test --runtime-fixture-command`, so interop tests need no account.
With `--history <file>` it also behaves as Codex does across restarts: each thread gets its own id, the prompt comes
back as a userMessage item, and finished turns are kept in the file for `thread/resume` and `thread/turns/list`.
A prompt holding `fixture:hold` starts a turn that stays open until `turn/interrupt`; one holding `fixture:approve`
also asks for a command approval and ends once it is answered, accepted or declined. `fixture:limit` fails the turn
on the plan's usage limit unless the prompt carries the context VCX hands a fallback account; `fixture:ratelimit` fails
it on a server rate limit; `fixture:crash` writes an error to stderr and exits. `fixture:pending:<absolute path>` leaves
the turn/start request unanswered until a file exists at that path, then answers it and runs the turn as usual;
`fixture:heavy:<MiB>` answers with an agentMessage that many mebibytes long. `fixture:dropped` fails the turn as a
dropped connection does; `fixture:apiretry` holds the turn as `fixture:hold` does after announcing an API retry.
`fixture:question` (one question, `pick`) and `fixture:twoquestions` (`first`, `second`) hold the turn on a question and
answer with the answers received. `thread/compact/start` reports the thread compacted; `review/start` runs a turn
whose answer names the review target.
`fixture:opened` answers with the JSON of what the last thread/start or thread/resume was given (developer
instructions, dynamic tool names) and the session files in the agent's own environment.
`skills/list` and `hooks/list` read `skills/<name>/SKILL.md` and `hooks.json` in its Codex home: `CODEX_HOME`, else
`.codex` in the test worker's `VCX_RUNTIME_HOME`, never his own; with neither, both lists are empty.
`fixture:edit:<absolute path>` writes that file and reports it as a fileChange item before the turn's tool.
`fixture:cd:<absolute path>` reports a finished `cd '<path>'` command before the turn's tool. `fixture:echo` answers
with the JSON of the turn's `cwd` and its whole input text.
Started with `--route` (the worker's test router, in Haiku's place), it reads the question after `-p`, prints the
folder the first `fixture:route:<folder>` in it names, or `none`, and exits.
A `routing-timeout` file in the test worker's `VCX_RUNTIME_HOME` fails the next thread/start or thread/resume once, as
Codex's workspace routing does when it times out, and is removed.
`fixture:quiet` holds the turn as `fixture:hold` does but shows nothing. A steer holding `fixture:queued` is reported
waiting in the agent's queue (`vcx/userQueue`), as Claude reports one, and `vcx/unsend` takes it back.
`fixture:lastopen` answers with the JSON of every parameter the last thread/start or thread/resume was given.
"""
import json
import os
import re
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
QUESTION = 'fixture:question'
TWO_QUESTIONS = 'fixture:twoquestions'
LIMIT = 'fixture:limit'
RATE_LIMIT = 'fixture:ratelimit'
CRASH = 'fixture:crash'
DROPPED = 'fixture:dropped'
API_RETRY = 'fixture:apiretry'
QUIET = 'fixture:quiet'
QUEUED = 'fixture:queued'
LAST_OPEN = 'fixture:lastopen'
HANDOFF = 'Context from this conversation'
CRASH_STATUS = 3
LIMIT_ERROR = {'message': "You've hit your usage limit.", 'codexErrorInfo': 'usageLimitExceeded'}
RATE_LIMIT_ERROR = {'message': 'exceeded retry limit, last status: 429 Too Many Requests'}
DROPPED_ERROR = {'message': 'stream disconnected before completion: error sending request'}
HELD_TOOL = {'id': 'fixture-held-tool', 'type': 'commandExecution', 'command': 'fixture-held-tool'}
PENDING = re.compile(r'fixture:pending:(\S+)')
PENDING_POLL_SECONDS = 0.02
HEAVY = re.compile(r'fixture:heavy:(\d+)')
EDIT = re.compile(r'fixture:edit:(\S+)')
CD = re.compile(r'fixture:cd:(\S+)')
ECHO = 'fixture:echo'
ROUTE = re.compile(r'fixture:route:(\S+)')
MEBIBYTE = 1024 * 1024
OPENED = 'fixture:opened'
ROUTING_TIMEOUT_FLAG = 'routing-timeout'
ROUTING_TIMEOUT_ERROR = {'code': -32603, 'message': 'workspace routing discovery timed out'}
SESSION_FILES = ('FLEET_CONTEXT_FILE', 'VCX_PROGRESS_FILE', 'VCX_TASK_FILE')
opened = {}
queued = set()
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


def run_turn(thread=THREAD, turn=TURN, prompt=None, text=ANSWER, edit=None, cd=None):
    event('turn/started', {'turn': {'id': turn}}, thread)
    items = []
    if prompt is not None:
        event('item/started', {'item': prompt}, thread)
        event('item/completed', {'item': prompt}, thread)
        items.append(prompt)
    if edit is not None:
        os.makedirs(os.path.dirname(edit), exist_ok=True)
        with open(edit, 'w') as file:
            file.write('fixture\n')
        change = {'id': 'fixture-edit', 'type': 'fileChange', 'status': 'completed', 'changes': [{'path': edit, 'kind': 'add'}]}
        event('item/completed', {'item': change}, thread)
    if cd is not None:
        command = {'id': 'fixture-cd', 'type': 'commandExecution', 'status': 'completed', 'exitCode': 0, 'command': "cd '" + cd + "'"}
        event('item/completed', {'item': command}, thread)
    tool = {'id': 'fixture-tool', 'type': 'commandExecution', 'command': 'echo fixture'}
    if HISTORY:
        tool['id'] = 'fixture-tool-' + turn
    event('item/started', {'item': {**tool, 'status': 'inProgress'}}, thread)
    done = {**tool, 'status': 'completed', 'exitCode': 0, 'aggregatedOutput': 'fixture\n'}
    event('item/completed', {'item': done}, thread)
    answer_id = 'fixture-answer-' + turn if HISTORY else 'fixture-answer'
    # Each heavy answer is its own item, so a conversation grows with them.
    answer_id += '' if text == ANSWER else '-' + uuid.uuid4().hex
    # A heavy answer arrives whole: as deltas it would cost a frame per word.
    for word in ANSWER.split(' ') if text == ANSWER else []:
        event('item/agentMessage/delta', {'itemId': answer_id, 'delta': word + ' '}, thread)
    answer = {'id': answer_id, 'type': 'agentMessage', 'text': text}
    event('item/completed', {'item': answer}, thread)
    if HISTORY:
        threads = load()
        threads.setdefault(thread, []).append({'id': turn, 'status': 'completed', 'items': items + [done, answer]})
        save(threads)
    event('turn/completed', {'turn': {'id': turn, 'status': 'completed'}}, thread)


def prompt_text(params):
    return ' '.join(piece.get('text', '') for piece in params.get('input', []) if isinstance(piece, dict))


def answer_text(params):
    if LAST_OPEN in prompt_text(params):
        return json.dumps(opened, sort_keys=True)
    if OPENED in prompt_text(params):
        tools = [tool.get('name') for tool in opened.get('dynamicTools') or []]
        environment = {key: os.environ.get(key) for key in SESSION_FILES}
        return json.dumps({'developerInstructions': opened.get('developerInstructions'), 'dynamicTools': tools, 'environment': environment})
    if ECHO in prompt_text(params):
        return json.dumps({'cwd': params.get('cwd'), 'input': prompt_text(params)})
    heavy = HEAVY.search(prompt_text(params))
    return 'x' * (int(heavy.group(1)) * MEBIBYTE) if heavy else ANSWER


def held(params):
    text = prompt_text(params)
    return any(marker in text for marker in (HOLD, APPROVE, API_RETRY, QUESTION, TWO_QUESTIONS, QUIET))


def failure(params):
    """The error the prompt names, `CRASH` for a crash, or None."""
    text = prompt_text(params)
    pieces = params.get('input', [])
    handed_off = bool(pieces) and isinstance(pieces[0], dict) and pieces[0].get('text', '').startswith(HANDOFF)
    if CRASH in text:
        return CRASH
    if DROPPED in text:
        return DROPPED_ERROR
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
    if QUIET in prompt_text(params):
        return
    event('item/started', {'item': {**HELD_TOOL, 'status': 'inProgress'}}, thread)
    if API_RETRY in prompt_text(params):
        # Claude's announced API retry, which the adapters pass on as `vcx/apiRetry`.
        event('vcx/apiRetry', {'delay': 0}, thread)
    if APPROVE in prompt_text(params):
        awaiting[APPROVAL_ID] = (thread, turn)
        request = {'threadId': thread, 'turnId': turn, 'itemId': HELD_TOOL['id'], 'command': HELD_TOOL['command']}
        send({'id': APPROVAL_ID, 'method': 'item/commandExecution/requestApproval', 'params': request})
    asked = ['first', 'second'] if TWO_QUESTIONS in prompt_text(params) else ['pick'] if QUESTION in prompt_text(params) else []
    if asked:
        awaiting[APPROVAL_ID] = (thread, turn)
        questions = [{'id': id, 'header': id, 'question': 'Which ' + id + '?', 'options': None} for id in asked]
        send({'id': APPROVAL_ID, 'method': 'item/tool/requestUserInput', 'params': {'threadId': thread, 'turnId': turn, 'itemId': HELD_TOOL['id'], 'questions': questions}})


def answered(message):
    thread, turn = awaiting.pop(message['id'])
    result = message.get('result') or {}
    accepted = result.get('decision') == 'accept' or 'answers' in result
    tool = {**HELD_TOOL, 'status': 'completed' if accepted else 'declined', 'exitCode': 0 if accepted else None}
    event('item/completed', {'item': tool}, thread)
    text = 'answers ' + json.dumps(result['answers'], sort_keys=True) if 'answers' in result else 'approved' if accepted else 'declined'
    answer = {'id': 'fixture-held-answer', 'type': 'agentMessage', 'text': text}
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


def codex_home():
    if os.environ.get('CODEX_HOME'):
        return os.environ['CODEX_HOME']
    runtime = os.environ.get('VCX_RUNTIME_HOME')
    return os.path.join(runtime, '.codex') if runtime else None


def skills_list(params):
    root = os.path.join(codex_home() or '', 'skills')
    skills = []
    for name in sorted(os.listdir(root)) if codex_home() and os.path.isdir(root) else []:
        path = os.path.join(root, name, 'SKILL.md')
        if not os.path.isfile(path):
            continue
        with open(path) as file:
            parts = file.read().split('---')
        header = parts[1] if len(parts) > 2 else ''
        fields = dict(line.split(':', 1) for line in header.splitlines() if ':' in line)
        skills.append({'name': fields.get('name', name).strip(), 'description': fields.get('description', '').strip(), 'path': path, 'enabled': True})
    return {'data': [{'cwd': cwd, 'skills': skills, 'errors': []} for cwd in params.get('cwds', [])]}


def hooks_list(params):
    path = os.path.join(codex_home() or '', 'hooks.json')
    events = {}
    if codex_home() and os.path.isfile(path):
        with open(path) as file:
            events = json.load(file).get('hooks', {})
    hooks = [{**hook, 'eventName': event, 'matcher': group.get('matcher')} for event, groups in events.items() for group in groups for hook in group.get('hooks', [])]
    return {'data': [{'hooks': hooks}]}


HOME_LISTS = {'skills/list': skills_list, 'hooks/list': hooks_list}


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
            threading.Timer(0, run_turn, (thread, turn, prompt, answer_text(params))).start()
        return {'turn': {'id': turn}}, None
    return RESULTS.get(method, {}), None


def routing_timed_out():
    runtime = os.environ.get('VCX_RUNTIME_HOME')
    flag = os.path.join(runtime, ROUTING_TIMEOUT_FLAG) if runtime else None
    if not flag or not os.path.exists(flag):
        return False
    os.remove(flag)
    return True


def respond(message):
    method = message['method']
    if method in ('thread/start', 'thread/resume') and routing_timed_out():
        send({'id': message['id'], 'error': ROUTING_TIMEOUT_ERROR})
        return
    if method in HOME_LISTS:
        send({'id': message['id'], 'result': HOME_LISTS[method](message.get('params') or {})})
        return
    if method == 'vcx/unsend':
        prompt = (message.get('params') or {}).get('id')
        send({'id': message['id'], 'result': {'cancelled': prompt in queued}})
        queued.discard(prompt)
        return
    if method in ('thread/start', 'thread/resume'):
        opened.clear()
        opened.update(message.get('params') or {})
    if HISTORY:
        result, error = answer_with_history(message)
        send({'id': message['id'], 'error': error} if error else {'id': message['id'], 'result': result})
        if method == 'turn/interrupt':
            awaiting.clear()
            event('turn/completed', {'turn': {'id': (message.get('params') or {}).get('turnId'), 'status': 'interrupted'}}, (message.get('params') or {}).get('threadId'))
        return
    params = message.get('params') or {}
    send({'id': message['id'], 'result': policy(RESULTS.get(method, {}), params) if method == 'thread/start' else RESULTS.get(method, {})})
    if method == 'turn/start' and failure(params):
        fail_turn(THREAD, TURN, failure(params))
    elif method == 'turn/start' and held(params):
        threading.Thread(target=open_turn, args=(THREAD, TURN, message.get('params') or {}), daemon=True).start()
    elif method == 'turn/start':
        edit, cd = EDIT.search(prompt_text(params)), CD.search(prompt_text(params))
        threading.Thread(target=run_turn, kwargs={'text': answer_text(params), 'edit': edit and edit.group(1), 'cd': cd and cd.group(1)}, daemon=True).start()
    elif method == 'turn/steer' and QUEUED in prompt_text(params):
        queued.add(params.get('clientUserMessageId'))
        event('vcx/userQueue', {'id': params.get('clientUserMessageId'), 'queued': True})
    elif method == 'turn/interrupt':
        awaiting.clear()
        event('turn/completed', {'turn': {'id': TURN, 'status': 'interrupted'}})
    elif method == 'thread/compact/start':
        event('thread/compacted', {})
    elif method == 'review/start':
        threading.Thread(target=run_turn, kwargs={'text': 'Review of ' + json.dumps(params.get('target'), sort_keys=True)}, daemon=True).start()


def respond_once_present(path, message):
    while not os.path.exists(path):
        time.sleep(PENDING_POLL_SECONDS)
    respond(message)


if '--route' in sys.argv:
    folder = ROUTE.search(sys.argv[sys.argv.index('-p') + 1])
    print(folder.group(1) if folder else 'none')
    sys.exit(0)

for line in sys.stdin:
    message = json.loads(line)
    method = message.get('method')
    if method is None and message.get('id') in awaiting:
        answered(message)
        continue
    if method is None or 'id' not in message:
        continue
    pending = PENDING.search(prompt_text(message.get('params') or {})) if method == 'turn/start' else None
    if pending:
        threading.Thread(target=respond_once_present, args=(pending.group(1), message), daemon=True).start()
    else:
        respond(message)
