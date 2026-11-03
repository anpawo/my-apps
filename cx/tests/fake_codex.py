import json
import sys


def send(message):
    print(json.dumps(message), flush=True)


for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    if method == "initialize":
        send({"id": message["id"], "result": {"userAgent": "test"}})
    elif method == "initialized":
        continue
    elif method == "echo":
        send({"method": "test/event", "params": {"value": 1}})
        send({"id": message["id"], "result": message["params"]})
    elif method == "fail":
        send({"id": message["id"], "error": {"code": -1, "message": "Expected failure"}})
    elif method == "request":
        send({"id": 999, "method": "item/tool/requestUserInput", "params": {"questions": []}})
        send({"id": message["id"], "result": {}})
    elif method == "exit":
        sys.exit(0)
    elif method:
        send({"id": message["id"], "result": {}})
