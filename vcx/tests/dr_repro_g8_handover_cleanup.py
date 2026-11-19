import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

BINARY = Path(__file__).parents[1] / '.build/debug/VCX'

# A frontend window close (each window of an update handover included) must not start a forced cleanup.py: the session
# lives on in its worker. A real close still does, in the worker. The binary runs --frontend-check from a copy whose
# resource folder holds a cleanup.py stub that only records who started it.
STUB = '''import json, os, sys
from pathlib import Path
with open(Path(__file__).with_name('calls.jsonl'), 'a') as calls:
    calls.write(json.dumps({'parent': os.getppid(), 'force': '--force' in sys.argv}) + '\\n')
'''


def scenario():
    folder = tempfile.mkdtemp(dir='/tmp', prefix='vcx-dr-')
    try:
        copy = Path(folder) / 'VCX'
        shutil.copy2(BINARY, copy)
        (Path(folder) / 'cleanup.py').write_text(STUB)
        check = subprocess.Popen([str(copy), '--frontend-check'], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        try:
            output, _ = check.communicate(timeout=300)
        except subprocess.TimeoutExpired:
            check.kill()
            output, _ = check.communicate()
        # Workers stopped at the end of the check start their stub last: wait until none still runs.
        for _ in range(100):
            if str(copy.with_name('cleanup.py')) not in subprocess.run(['/bin/ps', '-axo', 'command='], capture_output=True, text=True).stdout:
                break
            time.sleep(0.1)
        calls = [json.loads(line) for line in (Path(folder) / 'calls.jsonl').read_text().splitlines()] if (Path(folder) / 'calls.jsonl').exists() else []
        frontend = sum(1 for call in calls if call['force'] and call['parent'] == check.pid)
        worker = sum(1 for call in calls if call['force'] and call['parent'] != check.pid)
        last = output.strip().splitlines()[-1] if output.strip() else ''
        detail = 'frontend_check=' + ('passed' if check.returncode == 0 else 'failed(' + last + ')')
        detail += ' forced_cleanups_from_frontend=%d forced_cleanups_from_workers=%d check_pid=%d' % (frontend, worker, check.pid)
        ok = check.returncode == 0 and frontend == 0 and worker > 0
        print(('ok ' if ok else 'FAIL ') + 'G8-window-close-cleanup ' + detail)
        return ok
    finally:
        shutil.rmtree(folder, ignore_errors=True)


if not BINARY.exists():
    print('UNREACHED G8 no built binary at ' + str(BINARY))
    sys.exit(2)
sys.exit(0 if scenario() else 1)
