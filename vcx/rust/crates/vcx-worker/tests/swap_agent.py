"""A stand-in for `codex app-server` whose one turn streams for a few seconds, for the live-update tests.

The answer is its own pid, then the numbers 1 to COUNT, one delta each, and no final text: what the session shows at
the end is exactly what crossed the pipe, so a delta lost or doubled by a worker swap shows. Every line is written in
two halves. A prompt holding `hold` keeps the line of HELD unfinished until the file RESUMED appears in the agent's
folder: the test asks for the swap meanwhile, so the worker leaves its image with half a line read.
"""
import json
import os
import sys
import threading
import time

THREAD = 'swap-thread'
TURN = 'swap-turn'
ANSWER = 'swap-answer'
COUNT = 150
HALF_LINE_PAUSE = 0.01
HELD = 20
RESUMED = 'swap-resumed'
HOLD_POLL = 0.005
HOLD_LIMIT = 20.0
RESULTS = {
    'thread/start': {'thread': {'id': THREAD}, 'model': 'fixture-model'},
    'model/list': {'data': [{'id': 'fixture-model', 'defaultReasoningEffort': 'high', 'supportedReasoningEfforts': [{'reasoningEffort': 'high'}]}]},
    'turn/start': {'turn': {'id': TURN}},
}
output_lock = threading.Lock()


def held():
    deadline = time.monotonic() + HOLD_LIMIT
    while not os.path.exists(RESUMED) and time.monotonic() < deadline:
        time.sleep(HOLD_POLL)


def send(value, pause=0.0, hold=False):
    line = json.dumps(value) + '\n'
    middle = len(line) // 2
    with output_lock:
        sys.stdout.write(line[:middle])
        sys.stdout.flush()
        time.sleep(pause)
        if hold:
            held()
        sys.stdout.write(line[middle:])
        sys.stdout.flush()


def event(method, params, pause=0.0, hold=False):
    send({'method': method, 'params': {'threadId': THREAD, **params}}, pause, hold)


def stream(holding):
    event('turn/started', {'turn': {'id': TURN}})
    event('item/agentMessage/delta', {'itemId': ANSWER, 'delta': f'{os.getpid()}:'})
    for number in range(1, COUNT + 1):
        event('item/agentMessage/delta', {'itemId': ANSWER, 'delta': f'{number} '}, HALF_LINE_PAUSE, holding and number == HELD)
        time.sleep(HALF_LINE_PAUSE)
    event('turn/completed', {'turn': {'id': TURN, 'status': 'completed'}})


for line in sys.stdin:
    message = json.loads(line)
    if 'method' not in message or 'id' not in message:
        continue
    send({'id': message['id'], 'result': RESULTS.get(message['method'], {})})
    if message['method'] == 'turn/start':
        prompt = ' '.join(piece.get('text', '') for piece in message['params'].get('input', []) if isinstance(piece, dict))
        threading.Thread(target=stream, args=('hold' in prompt,), daemon=True).start()
