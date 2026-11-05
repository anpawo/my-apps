#!/usr/bin/env python3
"""Fake Claude stream-json agent (or Codex app-server with --codex) for the runtime live update check."""
import json
import os
import sys
import time

directory = sys.argv[1]
with open(os.path.join(directory, 'agent-starts'), 'a') as stream:
    stream.write(f'{os.getpid()}\n')
out = sys.stdout.buffer
replies = 0
partial = False


def send(message, tail=b''):
    out.write(json.dumps(message).encode() + b'\n' + tail)
    out.flush()


if '--codex' in sys.argv:
    thread = 'swap-codex-thread'
    for line in sys.stdin.buffer:
        message = json.loads(line)
        method, result = message.get('method'), {}
        if 'id' not in message:
            continue
        if method == 'thread/start':
            result = {'thread': {'id': thread}, 'model': 'codex-swap'}
        elif method in ('model/list', 'thread/list'):
            result = {'data': []}
        elif method == 'turn/start':
            replies += 1
            result = {'turn': {'id': f'codex-turn-{replies}'}}
        send({'id': message['id'], 'result': result})
        if method == 'turn/start':
            for name, params in [('turn/started', {'turn': result['turn']}),
                                 ('item/completed', {'item': {'id': f'codex-item-{replies}', 'type': 'agentMessage', 'text': f'codex reply {replies}'}}),
                                 ('turn/completed', {'turn': {**result['turn'], 'status': 'completed'}})]:
                send({'method': name, 'params': {'threadId': thread, **params}})
    sys.exit(0)

for line in sys.stdin.buffer:
    message = json.loads(line)
    if message.get('type') == 'control_request':
        response = {}
        if message.get('request', {}).get('subtype') == 'initialize':
            response = {'models': [{'value': 'default', 'resolvedModel': 'claude-swap'}, {'value': 'claude-swap'}]}
        send({'type': 'control_response', 'response': {'subtype': 'success', 'request_id': message['request_id'], 'response': response}})
    elif message.get('type') == 'user':
        text = ' '.join(piece.get('text', '') for piece in message['message']['content'] if isinstance(piece, dict))
        if partial:
            # Completes the line the previous image of the worker read but could not parse.
            out.write(b']}\n')
            partial = False
        hold = 'HOLD' in text
        if hold:
            open(os.path.join(directory, 'holding'), 'w').close()
            while not os.path.exists(os.path.join(directory, 'release')):
                time.sleep(0.02)
        replies += 1
        send({'type': 'assistant', 'message': {'id': f'swap-message-{replies}', 'role': 'assistant', 'content': [{'type': 'text', 'text': f'swap reply {replies}'}]}})
        tail = b'{"type":"system","subtype":"background_tasks_changed","tasks":[1,2' if hold else b''
        send({'type': 'result', 'subtype': 'success', 'user_message_uuids': [message.get('uuid')], 'queued_turn_count': 0}, tail)
        partial = hold
