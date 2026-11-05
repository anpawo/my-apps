import http.server
import json
import shlex
import sys

mode = sys.argv[1]


def send(value):
    print(json.dumps(value), flush=True)


if mode == 'http':
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            self.send_response(200)
            self.send_header('Content-Type', 'application/x-ndjson')
            self.end_headers()
            if body['messages'][-1]['content'] == 'TOOLS':
                self.wfile.write((json.dumps({'message': {'content': '', 'tool_calls': [{'function': {'name': 'run_command', 'arguments': {'command': 'printf native-tool-check'}}}]}, 'done': True}) + '\n').encode())
                return
            text = body['messages'][-1]['content']
            if text.startswith('DIRECTORY_TOOLS '):
                commands = ['cd ' + shlex.quote(text.removeprefix('DIRECTORY_TOOLS ')), 'pwd -L']
                calls = [{'function': {'name': 'run_command', 'arguments': {'command': command}}} for command in commands]
                self.wfile.write((json.dumps({'message': {'content': '', 'tool_calls': calls}, 'done': True}) + '\n').encode())
                return
            for text in ([body['messages'][0]['content']] if text == 'CONTEXT' else [body['model']] if text == 'MODEL' else ['Hello ', 'from Qwen']):
                self.wfile.write((json.dumps({'message': {'content': text}, 'done': False}) + '\n').encode())
                self.wfile.flush()
            self.wfile.write(b'{"message":{"content":""},"done":true}\n')

        def log_message(self, *args):
            pass

    server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
    print(server.server_port, flush=True)
    server.serve_forever()
else:
    # After WAIT, the turn holds every prompt in its queue until READ, as Claude does until its running tool returns.
    holding, queue = False, []
    for line in sys.stdin:
        message = json.loads(line)
        if mode == 'claude':
            if message.get('type') == 'control_request':
                subtype = message.get('request', {}).get('subtype')
                if subtype == 'cancel_async_message':
                    uuid = message['request']['message_uuid']
                    cancelled = any(queued == uuid for queued, _ in queue)
                    queue = [(queued, text) for queued, text in queue if queued != uuid]
                    send({'type': 'control_response', 'response': {'subtype': 'success', 'request_id': message['request_id'], 'response': {'cancelled': cancelled}}})
                    if cancelled:
                        send({'type': 'command_lifecycle', 'command_uuid': uuid, 'state': 'cancelled'})
                    continue
                if subtype == 'apply_flag_settings':
                    settings = message['request']['settings']
                    error = settings.get('model') == 'reject-me' or settings.get('effortLevel') not in [None, 'low', 'medium', 'high']
                    response = {'subtype': 'error', 'request_id': message['request_id'], 'error': 'Fixture settings rejected'} if error else {'subtype': 'success', 'request_id': message['request_id'], 'response': {'settings': settings}}
                    send({'type': 'control_response', 'response': response})
                    continue
                if subtype == 'set_model' and message['request'].get('model') == 'reject-me':
                    send({'type': 'control_response', 'response': {'subtype': 'error', 'request_id': message['request_id'], 'error': 'Fixture model rejected'}})
                    continue
                result = {'commands': [{'name': 'fixture-skill', 'description': 'Fixture skill', 'aliases': ['fixture-alias']}], 'models': [{'value': 'default', 'resolvedModel': 'fixture-claude-1'}, {'value': 'fixture-claude', 'resolvedModel': 'fixture-claude-1'}], 'current_permission_mode': 'bypassPermissions'} if subtype == 'initialize' else {'mcpServers': [{'name': 'fixture-mcp', 'status': 'connected'}]}
                if subtype == 'initialize' and '--append-system-prompt' in sys.argv:
                    result['appendedSystemPrompt'] = sys.argv[sys.argv.index('--append-system-prompt') + 1]
                send({'type': 'control_response', 'response': {'subtype': 'success', 'request_id': message['request_id'], 'response': result}})
            if message.get('type') == 'user':
                uuid, text = message.get('uuid'), ''.join(block.get('text', '') for block in message['message']['content'])
                if holding:
                    send({'type': 'command_lifecycle', 'command_uuid': uuid, 'state': 'queued'})
                    queue.append((uuid, text))
                    if text == 'READ':
                        for queued, _ in queue:
                            send({'type': 'command_lifecycle', 'command_uuid': queued, 'state': 'started'})
                        answer = 'Read: ' + ', '.join(text for _, text in queue)
                        send({'type': 'assistant', 'message': {'id': 'msg-read', 'content': [{'type': 'text', 'text': answer}]}})
                        send({'type': 'result', 'is_error': False, 'result': answer, 'queued_turn_count': 0})
                        holding, queue = False, []
                    continue
                if text == 'WAIT':
                    holding = True
                    send({'type': 'command_lifecycle', 'command_uuid': uuid, 'state': 'queued'})
                    send({'type': 'command_lifecycle', 'command_uuid': uuid, 'state': 'started'})
                    continue
                send({'type': 'system', 'subtype': 'init', 'model': 'test-claude'})
                send({'type': 'stream_event', 'event': {'type': 'message_start', 'message': {'id': 'msg-1'}}})
                send({'type': 'stream_event', 'event': {'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'text', 'text': ''}}})
                send({'type': 'stream_event', 'event': {'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'text_delta', 'text': 'Hello from Claude'}}})
                send({'type': 'assistant', 'message': {'id': 'msg-1', 'content': [{'type': 'text', 'text': 'Hello from Claude'}]}})
                send({'type': 'result', 'is_error': False, 'result': 'Hello from Claude'})
            continue
        method = message.get('method')
        if method == 'initialize':
            send({'id': message['id'], 'result': {'userAgent': 'native-check'}})
        elif method == 'echo':
            send({'method': 'test/event', 'params': {'value': 7}})
            send({'id': message['id'], 'result': message['params']})
        elif method == 'fail':
            send({'id': message['id'], 'error': {'code': -1, 'message': 'Expected test failure'}})
        elif method == 'timeout':
            continue
        elif method == 'exit':
            sys.exit(0)
        elif method and 'id' in message:
            send({'id': message['id'], 'result': {}})
