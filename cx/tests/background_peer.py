#!/usr/bin/env python3
import json
import os
from pathlib import Path
import subprocess
import sys
import time


def emit(value):
    print(json.dumps(value), flush=True)


provider = Path(sys.argv[0]).name
mode = os.environ.get('VCX_FIXTURE_MODE', 'success')
record = Path(os.environ['VCX_FIXTURE_CALLS'])
with record.open('a') as stream:
    stream.write(json.dumps({'provider': provider, 'arguments': sys.argv[1:], 'input': sys.stdin.read(), 'cwd': os.getcwd()}) + '\n')

if mode in ('hang', 'hang_after_tool'):
    child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'])
    emit({'type': 'thread.started', 'thread_id': 'fixture-thread'})
    if mode == 'hang_after_tool':
        item = {'id': 'once', 'type': 'command_execution', 'command': 'fixture_send_once'}
        emit({'type': 'item.started', 'item': item})
        emit({'type': 'item.completed', 'item': dict(item, status='completed', aggregated_output='SENT_ONCE')})
    Path(os.environ['VCX_FIXTURE_READY']).write_text(json.dumps({'provider': os.getpid(), 'child': child.pid}))
    time.sleep(30)
    sys.exit(0)

if provider == 'claude':
    if mode.startswith('claude_malformed_'):
        emit({'type': 'assistant', 'message': {'content': [{'type': 'tool_use', 'id': 'once', 'name': 'Bash', 'input': {'command': 'fixture_send_once'}}]}})
        emit({'type': 'user', 'message': {'content': [{'type': 'tool_result', 'tool_use_id': 'once', 'content': 'SENT_ONCE'}]}})
        emit({
            'claude_malformed_null_block': {'type': 'stream_event', 'event': {'content_block': None}},
            'claude_malformed_list_block': {'type': 'stream_event', 'event': {'content_block': []}},
            'claude_malformed_dict_content': {'type': 'assistant', 'message': {'content': {}}},
            'claude_malformed_string_content': {'type': 'assistant', 'message': {'content': 'invalid'}},
            'claude_malformed_null_content': {'type': 'assistant', 'message': {'content': None}},
            'claude_malformed_content_item': {'type': 'assistant', 'message': {'content': [None]}},
            'claude_malformed_tool_id': {'type': 'assistant', 'message': {'content': [{'type': 'tool_use', 'name': 'Bash'}]}},
            'claude_malformed_tool_name': {'type': 'assistant', 'message': {'content': [{'type': 'tool_use', 'id': 'broken', 'name': None}]}},
        }[mode])
        sys.exit(1)
    emit({'type': 'result', 'result': 'DONE: Fixture follow-up completed.', 'session_id': 'fixture-claude', 'is_error': False})
else:
    emit({'type': 'thread.started', 'thread_id': 'fixture-codex'})
    if mode in ('tool_quota', 'malformed_after_tool', 'malformed_shape_after_tool'):
        item = {'id': 'once', 'type': 'command_execution', 'command': 'fixture_send_once'}
        emit({'type': 'item.started', 'item': item})
        emit({'type': 'item.completed', 'item': dict(item, status='completed', aggregated_output='SENT_ONCE')})
        if mode == 'malformed_after_tool':
            print('{invalid JSON', flush=True)
        if mode == 'malformed_shape_after_tool':
            emit({'type': 'item.completed', 'item': None})
        emit({'type': 'turn.failed', 'error': {'message': 'Usage limit reached'}})
        sys.exit(1)
    emit({'type': 'item.completed', 'item': {'id': 'answer', 'type': 'agent_message', 'text': 'DONE: Fixture follow-up completed.'}})
    emit({'type': 'turn.completed', 'usage': {'input_tokens': 10, 'output_tokens': 8}})
