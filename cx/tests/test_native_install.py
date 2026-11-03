import importlib.util
import subprocess
import os
import shlex
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('native_install', Path(__file__).parents[1] / 'install-native.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class NativeInstallTests(unittest.TestCase):
    def test_owned_launcher_is_replaced_without_touching_codex(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            commands = home / '.local/bin'
            commands.mkdir(parents=True)
            codex = commands / 'codex'
            codex.write_text('original codex')
            (commands / 'cx').symlink_to(codex)

            def run(arguments, **kwargs):
                if arguments[0] == '/usr/bin/ditto':
                    Path(arguments[2]).mkdir(parents=True)

            with patch.object(installer.Path, 'home', return_value=home), patch.object(installer.shutil, 'which', return_value=str(codex)), patch.object(installer.subprocess, 'run', side_effect=run):
                installer.install()
            self.assertEqual(codex.read_text(), 'original codex')
            self.assertFalse((commands / 'cx').is_symlink())
            for name in ['cx', 'vcx']:
                text = (commands / name).read_text()
                self.assertIn('open -n', text)
                self.assertIn('--cwd "$PWD" "$@"', text)
                subprocess.run(['/bin/sh', '-n', str(commands / name)], check=True)

    def test_terminal_fallback_bootstraps_a_missing_environment(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            source = home / 'source'
            source.mkdir()
            (source / 'requirements.txt').write_text('textual==6.12.0\n')
            commands = home / 'tools'
            commands.mkdir()
            dependency_marker = home / 'dependencies-installed'
            stub = commands / 'python3'
            venv_program = '#!/bin/sh\nif [ "$1" = "-m" ]; then touch ' + shlex.quote(str(dependency_marker)) + '; exit 0; fi\necho "cx 0.1.0"\n'
            stub.write_text('#!' + sys.executable + '\nimport pathlib,sys\np=pathlib.Path(sys.argv[3])/"bin/python"\np.parent.mkdir(parents=True)\np.write_text(' + repr(venv_program) + ')\np.chmod(0o755)\n')
            stub.chmod(0o755)

            def run(arguments, **kwargs):
                if arguments[0] == '/usr/bin/ditto':
                    Path(arguments[2]).mkdir(parents=True)

            with patch.object(installer, '__file__', str(source / 'install-native.py')), patch.object(installer.Path, 'home', return_value=home), patch.object(installer.subprocess, 'run', side_effect=run):
                installer.install()
            result = subprocess.run([str(home / '.local/bin/cx'), '--terminal', '--version'], env=dict(os.environ, PATH=str(commands) + ':/usr/bin:/bin'), capture_output=True, text=True, check=True)
            self.assertIn('cx 0.1.0', result.stdout)
            self.assertTrue(dependency_marker.exists())
            self.assertTrue((source / '.venv/bin/python').is_file())

    def test_unrelated_command_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            commands = home / '.local/bin'
            commands.mkdir(parents=True)
            target = commands / 'vcx'
            target.write_text('unrelated command')
            with patch.object(installer.Path, 'home', return_value=home), patch.object(installer.subprocess, 'run') as run:
                with self.assertRaises(SystemExit):
                    installer.install()
                run.assert_not_called()
            self.assertEqual(target.read_text(), 'unrelated command')

    def test_unrelated_app_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            app = home / 'Applications/Vibe Code X.app'
            app.mkdir(parents=True)
            with patch.object(installer.Path, 'home', return_value=home), patch.object(installer.subprocess, 'run') as run:
                with self.assertRaises(SystemExit):
                    installer.install()
                run.assert_not_called()
            self.assertTrue(app.exists())
