import http.server
import json
import sys


def send(value):
    print(json.dumps(value), flush=True)


if sys.argv[-1] == 'http':
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            self.send_response(200)
            self.send_header('Content-Type', 'application/x-ndjson')
            self.end_headers()
            if body['messages'][-1]['content'] == 'TOOLS':
                self.wfile.write((json.dumps({'message': {'content': '', 'tool_calls': [{'function': {'name': 'run_command', 'arguments': {'command': 'printf native-tool-check'}}}]}, 'done': True}) + '\n').encode())
                return
            for text in ['Hello ', 'from Qwen']:
                self.wfile.write((json.dumps({'message': {'content': text}, 'done': False}) + '\n').encode())
                self.wfile.flush()
            self.wfile.write(b'{"message":{"content":""},"done":true}\n')

        def log_message(self, *args):
            pass

    server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
    print(server.server_port, flush=True)
    server.serve_forever()
else:
    for line in sys.stdin:
        message = json.loads(line)
        if sys.argv[-1] == 'claude':
            if message.get('type') == 'user':
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
