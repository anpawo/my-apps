"""The fixture agent as Codex keeps a saved conversation: `fake_agent.py --history` behind UUID thread IDs and a rollout file.

The conversation archive takes only UUID threads whose history file exists, so each `fixture-thread-<12 hex>` goes
out as `00000000-0000-4000-8000-<12 hex>` and comes back translated, and a thread started or resumed gets
`$CODEX_HOME/sessions/rollout-<uuid>.jsonl` with Codex's `session_meta` header, its path in `thread.path`. The
history file and the Codex home sit in the test worker's own folder (the parent of `VCX_RUNTIME_HOME`), never his.
"""
import json
import os
import re
import subprocess
import sys
import threading

FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', '..', 'fixtures', 'fake_agent.py')
FOLDER = os.path.dirname(os.environ['VCX_RUNTIME_HOME'])
OUTGOING = re.compile(r'fixture-thread-([0-9a-f]{12})')
INCOMING = re.compile(r'00000000-0000-4000-8000-([0-9a-f]{12})')
UUID_PREFIX = '00000000-0000-4000-8000-'
OPENING = ('thread/start', 'thread/resume')
opening = set()


def rollout(thread):
    home = os.environ.get('CODEX_HOME') or os.path.join(FOLDER, 'home', '.codex')
    if not os.path.realpath(home).startswith(os.path.realpath(FOLDER) + os.sep):
        raise SystemExit('records_agent: CODEX_HOME is outside the test folder')
    folder = os.path.join(home, 'sessions')
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, 'rollout-' + thread + '.jsonl')
    if not os.path.exists(path):
        with open(path, 'w') as file:
            file.write(json.dumps({'type': 'session_meta', 'payload': {'id': thread}}) + '\n')
    return path


def answer(line):
    message = json.loads(line)
    thread = (message.get('result') or {}).get('thread') if message.get('id') in opening else None
    if isinstance(thread, dict) and thread.get('id', '').startswith(UUID_PREFIX):
        opening.discard(message['id'])
        thread['path'] = rollout(thread['id'])
        return json.dumps(message) + '\n'
    return line


def relay(agent):
    for line in agent.stdout:
        sys.stdout.write(answer(OUTGOING.sub(UUID_PREFIX + r'\1', line)))
        sys.stdout.flush()
    os._exit(agent.wait())


agent = subprocess.Popen(['/usr/bin/python3', FIXTURE, '--history', os.path.join(FOLDER, 'history.json')], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
threading.Thread(target=relay, args=(agent,), daemon=True).start()
for line in sys.stdin:
    message = json.loads(line)
    if message.get('method') in OPENING:
        opening.add(message.get('id'))
    agent.stdin.write(INCOMING.sub(r'fixture-thread-\1', line))
    agent.stdin.flush()
agent.stdin.close()
os._exit(agent.wait())
