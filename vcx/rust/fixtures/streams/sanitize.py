"""Turns a raw recording from `record.py` into the fixture the tests replay, with nothing of the account in it.

    python3 -I sanitize.py codex|claude <raw.jsonl> <project folder> <fixture.jsonl>

Ids become fixed fake ids (the same id keeps the same fake), paths under the home folder or the recording folder
become /Users/user and /tmp/vcx-fixture, and the lists that name the account's own tools, skills, plugins, hooks and
MCP servers are cut to neutral entries. Lines with nothing an adapter reads (moderation metadata, stderr) are dropped.
"""
import json
import os
import re
import sys

kind, raw_path, project, fixture_path = sys.argv[1:5]
HOME = os.path.expanduser('~')
FIXTURE_PROJECT = '/tmp/vcx-fixture/project'
UUID = re.compile(r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
EMAIL = re.compile(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}')
# Claude's message, tool and request ids: msg_…, toolu_…, req_…
PREFIXED = re.compile(r'\b(msg|toolu|req|call|exec)_[A-Za-z0-9]{8,}')
DROPPED_METHODS = {'turn/moderationMetadata'}
KEPT_BUILTINS = {'compact', 'context', 'cost', 'clear', 'model', 'review'}
ids = {}


def fake_uuid(match):
    value = match.group(0).lower()
    if value not in ids:
        ids[value] = '00000000-0000-4000-8000-%012d' % (len(ids) + 1)
    return ids[value]


def fake_prefixed(match):
    value = match.group(0)
    if value not in ids:
        ids[value] = '%s_fixture%04d' % (match.group(1), len(ids) + 1)
    return ids[value]


def scrub(text):
    for real in (os.path.realpath(project), project):
        text = text.replace(real, FIXTURE_PROJECT)
    text = text.replace(HOME, '/Users/user')
    text = EMAIL.sub('user@example.com', text)
    text = UUID.sub(fake_uuid, text)
    return PREFIXED.sub(fake_prefixed, text)


def clean(value):
    if isinstance(value, dict):
        return {scrub(k): clean(v) for k, v in value.items()}
    if isinstance(value, list):
        return [clean(v) for v in value]
    return scrub(value) if isinstance(value, str) else value


def codex(message):
    method = message.get('method')
    if method in DROPPED_METHODS:
        return None
    params, result = message.get('params') or {}, message.get('result') or {}
    if method == 'remoteControl/status/changed':
        params.update({'installationId': 'installation', 'serverName': 'mac'})
    if method == 'mcpServer/startupStatus/updated':
        params['name'] = 'fixture-mcp'
    if method in ('hook/started', 'hook/completed'):
        run = params['run']
        run.update({'id': 'hook-%d' % run.get('displayOrder', 0), 'sourcePath': '/Users/user/.codex/hooks.json'})
        run['entries'] = [{'kind': e.get('kind'), 'text': 'Hook context.'} for e in run.get('entries', [])]
    if method == 'account/rateLimits/updated':
        params['rateLimits']['credits']['balance'] = '0'
        params['rateLimits']['limitId'] = 'codex'
    if 'account' in result:
        result['account'] = {'type': result['account'].get('type'), 'email': 'user@example.com', 'planType': 'pro', 'workspaceName': None}
        result['userId'] = 'user'
        result['workspaceRouting'] = {'accountRoutingOverride': 'none', 'backendOrigin': 'https://chatgpt.com', 'chatgptAccountId': 'account'}
    # His login shell prints its own notices around the output, and a hook rewrites the command with his PATH.
    if method == 'item/commandExecution/outputDelta':
        params['delta'] = '\n'.join(line for line in params['delta'].split('\n') if line in ('vcx', ''))
    item = params.get('item') or {}
    if item.get('type') == 'commandExecution':
        item['command'] = "/bin/zsh -lc 'echo vcx'"
        item['commandActions'] = [{'type': a.get('type'), 'command': 'echo vcx'} for a in item.get('commandActions', [])]
        if item.get('aggregatedOutput'):
            item['aggregatedOutput'] = 'vcx\n'
    if 'data' in result and isinstance(result['data'], list):
        result['data'] = result['data'][:3]
    for holder in (result, result.get('thread') or {}, params.get('thread') or {}):
        if 'instructionSources' in holder:
            holder['instructionSources'] = ['/Users/user/.codex/AGENTS.md']
    return message


def claude(message):
    kind = message.get('type')
    if kind == 'control_response':
        body = message['response'].get('response') or {}
        if 'account' in body:
            body['account'] = {'apiProvider': 'firstParty', 'email': 'user@example.com', 'organization': 'Fixture', 'subscriptionType': 'max'}
        if 'commands' in body:
            body['commands'] = [c for c in body['commands'] if c.get('builtin') and c.get('name') in KEPT_BUILTINS]
            body['commands'].append({'name': 'fixture-skill', 'description': 'A fixture skill (user)', 'argumentHint': '', 'builtin': False})
        for key in ('agents',):
            if key in body:
                body[key] = []
        if 'pid' in body:
            body['pid'] = 4242
    if kind == 'system' and message.get('subtype') == 'init':
        message.update({'additional_directories': [], 'agents': [], 'plugins': [], 'mcp_servers': [],
                        'skills': ['fixture-skill'], 'messaging_socket_path': '/tmp/claude-fixture.sock'})
        message['slash_commands'] = [c for c in message.get('slash_commands', []) if c in KEPT_BUILTINS] + ['fixture-skill']
        message['terminal_slash_commands'] = [c for c in message.get('terminal_slash_commands', []) if c in KEPT_BUILTINS]
        message['memory_paths'] = {'auto': '/Users/user/.claude/projects/-tmp-vcx-fixture-project/memory'}
    if kind == 'result':
        message['credential_expires_at'] = '2026-01-01T00:00:00.000Z'
    return message


out = open(fixture_path, 'w')
for line in open(raw_path):
    record = json.loads(line)
    if record['dir'] == 'stderr':
        continue
    message = (codex if kind == 'codex' else claude)(record['message'])
    if message is not None:
        out.write(json.dumps({'t': record['t'], 'dir': record['dir'], 'message': clean(message)}) + '\n')
out.close()
