# OpenAI-compatible /v1/chat/completions that answers through `codex exec` (ChatGPT plan quota, no API key).
import json, os, subprocess, sys, tempfile, threading, time, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODEL, EFFORT, PORT = sys.argv[1], sys.argv[2], int(sys.argv[3])
MAX_PARALLEL_CODEX = 4
CODEX_TIMEOUT_S = 300
slots = threading.Semaphore(MAX_PARALLEL_CODEX)
LOG = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "proxy.log"), "a", buffering=1)
NOTE = "You are used as a plain text completion endpoint. Do not run commands or read files; answer in text only, following the instructions below exactly.\n\n"

def ask(messages):
    prompt = NOTE + "\n\n".join(f"[{m['role']}]\n{m['content'] if isinstance(m['content'], str) else json.dumps(m['content'])}" for m in messages)
    with tempfile.TemporaryDirectory() as t, slots:
        out = os.path.join(t, "out.txt")
        start = time.time()
        r = subprocess.run(["codex", "exec", "-m", MODEL, "-c", f'model_reasoning_effort="{EFFORT}"', "--ignore-user-config", "--ignore-rules",
                            "--ephemeral", "--skip-git-repo-check", "-s", "read-only", "-C", t, "-o", out, "-"],
                           input=prompt, capture_output=True, text=True, timeout=CODEX_TIMEOUT_S)
        text = open(out).read() if os.path.exists(out) else ""
        LOG.write(f"{time.strftime('%H:%M:%S')} exit={r.returncode} secs={time.time()-start:.0f} in={len(prompt)} out={len(text)}\n")
        return text

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        try: text = ask(body.get("messages", []))
        except Exception as e:
            LOG.write(f"error {type(e).__name__}\n"); text = ""
        if not text:
            self.send_response(500); self.end_headers(); return
        data = json.dumps({"id": "cx-" + uuid.uuid4().hex, "object": "chat.completion", "created": int(time.time()), "model": MODEL,
                           "choices": [{"index": 0, "message": {"role": "assistant", "content": text}, "finish_reason": "stop"}],
                           "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)

ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
