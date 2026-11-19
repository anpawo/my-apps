import importlib.util
from pathlib import Path
import sys
import tempfile
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('background', Path(__file__).parents[1] / 'background.py')
bg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bg)

THREAD = '019a3c1e-7f2b-7c40-9d1e-5b2a8c4f6e10'

with tempfile.TemporaryDirectory() as folder:
    home = Path(folder)
    calls = []

    def fake_command(args, *rest, **kwargs):
        calls.append(list(args))
        return 1, b'', b'stubbed'

    def no_spawn(*a, **k):
        raise AssertionError('a real process was about to start: ' + repr(a[:1]))

    with patch.object(bg, 'HOME', home), patch.object(bg, 'CONFIG', home / 'config'), patch.object(bg, 'STATE', home / 'state'), \
            patch.object(bg, 'command', fake_command), patch.object(bg.subprocess, 'Popen', no_spawn):
        runner = bg.Runner(bg.options(['-p', '--cwd', str(home), '--provider', 'codex', '--resume', THREAD]))
        try:
            runner.turn([{'type': 'text', 'text': 'continue'}])
        finally:
            runner.close()

    first = calls[0] if calls else []
    codex = next((c for c in calls if c[:1] == ['codex']), [])
    resumed_by = next((c[0] for c in calls if THREAD in c), None)
    measured = 'calls=' + str([c[0] + (' ' + c[2] if len(c) > 2 and c[1] == 'exec' else '') for c in calls]) + \
        ' first=' + (first[0] if first else 'none') + ' codex_resume=' + str(codex[2:4] == ['resume', THREAD]) + ' thread_passed_to=' + str(resumed_by)
    ok = first[:1] == ['codex'] and first[1:4] == ['exec', 'resume', THREAD]
    print(('ok' if ok else 'FAIL') + ' G1 ' + measured)
    sys.exit(0 if ok else 1)
