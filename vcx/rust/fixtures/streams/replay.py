"""Plays an agent from a recording, for the adapter tests: each line the client sent in the recording waits for one
line on stdin, then the agent's lines up to the next one are printed. Ids the client chose (JSON-RPC `id`, Claude's
`request_id`, a prompt's `uuid`) are mapped to the ones it chose this time.

    python3 -I replay.py <recording.jsonl>
"""
import json
import sys

records = [json.loads(line) for line in open(sys.argv[1])]
ids = {}


def mapped(message):
    for key in ('id', 'request_id', 'uuid'):
        if key in message and json.dumps(message[key]) in ids:
            message[key] = ids[json.dumps(message[key])]
    response = message.get('response')
    if isinstance(response, dict) and json.dumps(response.get('request_id')) in ids:
        response['request_id'] = ids[json.dumps(response['request_id'])]
    return message


for record in records:
    if record['dir'] == 'send':
        line = sys.stdin.readline()
        if not line:
            sys.exit(0)
        sent = json.loads(line)
        for key in ('id', 'request_id', 'uuid'):
            if key in record['message'] and key in sent:
                ids[json.dumps(record['message'][key])] = sent[key]
    elif record['dir'] == 'recv':
        print(json.dumps(mapped(record['message'])), flush=True)
for line in sys.stdin:
    pass
