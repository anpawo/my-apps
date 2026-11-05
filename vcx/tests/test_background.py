import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('background', Path(__file__).parents[1] / 'background.py')
bg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bg)


class BackgroundTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.home = Path(self.directory.name)
        self.patches = [patch.object(bg, 'HOME', self.home), patch.object(bg, 'CONFIG', self.home / 'config'), patch.object(bg, 'STATE', self.home / 'state')]
        for item in self.patches:
            item.start()

    def tearDown(self):
        for item in reversed(self.patches):
            item.stop()
        self.directory.cleanup()

    def runner(self, *args):
        runner = bg.Runner(bg.options(['-p', '--cwd', str(self.home), *args]))
        self.addCleanup(runner.close)
        return runner

    def test_fallback_preserves_task_and_shared_limits(self):
        runner = self.runner()
        task = [{'type': 'text', 'text': 'Finish only the pending work.'}]
        calls = []

        def claude(account, content, resume):
            calls.append(account['provider'])
            return {'is_error': True, 'result': 'Usage limit reached', 'session_id': 'old-claude'}

        def codex(account, content, resume):
            calls.append(account['provider'])
            self.assertIsNone(resume)
            self.assertIn('old-claude', bg.content_text(content))
            self.assertIn(task[0]['text'], bg.content_text(content))
            return {'is_error': False, 'result': 'DONE: Finished', 'session_id': 'codex-thread'}

        with patch.object(runner, 'claude', side_effect=claude), patch.object(runner, 'codex', side_effect=codex):
            result = runner.turn(task)
        self.assertEqual(calls, ['claude', 'codex'])
        self.assertEqual(result['provider'], 'codex')
        self.assertIn('claude-default', bg.preferences()['limits'])
        self.assertTrue(result['session_id'].startswith('native:'))
        record = bg.read_json(runner.snapshot())
        self.assertEqual(record['threadId'], 'codex-thread')
        self.assertEqual(record['accountId'], 'codex-default')

    def test_regular_failure_and_timeout_never_replay_actions(self):
        for response in [{'is_error': True, 'result': 'Network disconnected'}, subprocess.TimeoutExpired('claude', 1)]:
            runner = self.runner('--no-session-persistence')
            with patch.object(runner, 'claude', side_effect=response if isinstance(response, Exception) else None, return_value=response), patch.object(runner, 'codex') as codex:
                result = runner.turn([{'type': 'text', 'text': 'Do the task'}])
                self.assertTrue(result['is_error'])
                codex.assert_not_called()

    def test_quota_after_an_action_keeps_activity_and_never_replays(self):
        for provider in ('claude', 'codex'):
            runner = self.runner('--provider', provider)
            response = {'is_error': True, 'result': 'Usage limit reached', 'session_id': 'partial'}
            if provider == 'claude':
                response['_events'] = [{'type': 'assistant', 'message': {'content': [{'type': 'tool_use', 'id': 'call', 'name': 'Bash', 'input': {'command': 'send_once'}}]}},
                                       {'type': 'user', 'message': {'content': [{'type': 'tool_result', 'tool_use_id': 'call', 'content': 'Already sent'}]}}]
            else:
                response['_rows'] = [{'kind': 'activity', 'items': [{'id': 'call', 'command': 'send_once', 'aggregatedOutput': 'Already sent', 'status': 'completed'}]}]
            other = 'codex' if provider == 'claude' else 'claude'
            with patch.object(runner, provider, return_value=response), patch.object(runner, other) as fallback:
                result = runner.turn([{'type': 'text', 'text': 'Send once'}])
            fallback.assert_not_called()
            self.assertTrue(result['is_error'])
            self.assertIn('Automatic replay was stopped', result['result'])
            self.assertIn('Already sent', runner.snapshot().read_text())
            runner.close()

    def test_auth_failure_before_actions_uses_another_provider(self):
        runner = self.runner('--provider', 'codex', '--no-session-persistence')
        with patch.object(runner, 'codex', return_value={'is_error': True, 'result': 'Not logged in'}), patch.object(runner, 'claude', return_value={'result': 'Done'}) as claude:
            result = runner.turn([{'type': 'text', 'text': 'Task'}])
        self.assertEqual(result['provider'], 'claude')
        claude.assert_called_once()

    def test_quota_after_a_started_file_change_never_replays(self):
        runner = self.runner('--provider', 'codex', '--no-session-persistence')
        events = [{'type': 'item.started', 'item': {'id': 'patch', 'type': 'file_change', 'changes': [{'path': 'fixture.txt'}]}},
                  {'type': 'turn.failed', 'error': {'message': 'Usage limit reached'}}]
        with patch.object(bg, 'command', return_value=(1, '\n'.join(map(json.dumps, events)).encode(), b'')), patch.object(runner, 'claude') as fallback:
            result = runner.turn([{'type': 'text', 'text': 'Change the file'}])
        fallback.assert_not_called()
        self.assertIn('Outcome unknown', result['result'])
        self.assertIn('Automatic replay was stopped', result['result'])

    def test_claude_missing_final_result_retains_started_actions(self):
        runner = self.runner('--no-session-persistence')
        event = {'type': 'assistant', 'message': {'content': [{'type': 'tool_use', 'id': 'started', 'name': 'Bash', 'input': {'command': 'send_once'}}]}}
        with patch.object(bg, 'command', return_value=(1, json.dumps(event).encode(), b'Usage limit reached')), patch.object(runner, 'codex') as fallback:
            result = runner.turn([{'type': 'text', 'text': 'Task'}])
        fallback.assert_not_called()
        self.assertIn('Outcome unknown', result['result'])

    def test_qwen_later_failures_keep_commands_and_never_replay(self):
        for error in [(0, b'{"error":"Usage limit reached"}', b''), (1, b'', b'')]:
            runner = self.runner('--provider', 'qwen', '--tools', 'Bash', '--no-session-persistence')
            runner.prefs['limits'] = {}
            first = {'message': {'role': 'assistant', 'content': '', 'tool_calls': [{'function': {'name': 'run_command', 'arguments': {'command': 'send_once'}}}]}}
            responses = [(0, json.dumps(first).encode(), b''), (0, b'Already sent', b''), error]
            with patch.object(bg, 'ensure_qwen'), patch.object(bg, 'command', side_effect=responses), patch.object(runner, 'claude') as fallback:
                result = runner.turn([{'type': 'text', 'text': 'Task'}])
            fallback.assert_not_called()
            self.assertTrue(result['is_error'])
            self.assertIn('send_once', json.dumps(runner.record))

    def test_resume_and_fork_use_native_context_without_touching_original(self):
        first = self.runner()
        with patch.object(first, 'claude', return_value={'is_error': False, 'result': 'First reply', 'session_id': 'claude-thread'}):
            result = first.turn([{'type': 'text', 'text': 'First request'}])
        first.lock.close()
        original = first.snapshot().read_bytes()
        resumed = self.runner('--resume', result['session_id'], '--fork-session')
        with patch.object(resumed, 'claude', return_value={'is_error': False, 'result': 'Second reply', 'session_id': 'fork-thread'}) as claude:
            resumed.turn([{'type': 'text', 'text': 'Continue'}])
            self.assertEqual(claude.call_args.args[2], 'claude-thread')
        self.assertNotEqual(resumed.record_id, first.record_id)
        self.assertEqual(first.snapshot().read_bytes(), original)

    def test_uuid_clients_resume_the_same_native_conversation(self):
        first = self.runner('--session-id-format', 'uuid')
        with patch.object(first, 'claude', return_value={'result': 'First', 'session_id': 'backend-thread'}):
            result = first.turn([{'type': 'text', 'text': 'Task'}])
        self.assertEqual(result['session_id'], first.record_id)
        first.close()
        second = self.runner('--session-id-format', 'uuid', '--resume', result['session_id'])
        self.assertEqual(second.backend, 'backend-thread')
        self.assertEqual(second.record_id, first.record_id)

    def test_instruction_file_is_forwarded_as_system_content(self):
        path = self.home / 'instructions'
        path.write_text('Use the task API before acting.')
        args = bg.options(['-p', '--append-system-prompt-file', str(path)])
        self.assertIn('Use the task API before acting.', args.append_system_prompt)

    def test_paperclip_push_denial_covers_shell_wrappers(self):
        for script in ['git push', 'git -C /tmp push origin main', '/bin/zsh -lc "cd /tmp && git push"']:
            self.assertTrue(bg.tool_denied({'tool_name': 'Bash', 'tool_input': {'command': script}}, 'Bash(git push:*)'))
        self.assertFalse(bg.tool_denied({'tool_name': 'Bash', 'tool_input': {'command': 'git status'}}, 'Bash(git push:*)'))

    def test_explicit_mcp_servers_are_forwarded_to_codex(self):
        config = self.home / 'mcp.json'
        config.write_text(json.dumps({'mcpServers': {'fixture': {'type': 'stdio', 'command': 'fixture-mcp', 'args': ['serve']}}}))
        runner = self.runner('--mcp-config', str(config), '--strict-mcp-config', '--no-session-persistence')
        with patch.object(bg, 'command', return_value=(0, b'{"type":"item.completed","item":{"type":"agent_message","text":"Done"}}', b'')) as command:
            runner.codex({'provider': 'codex'}, [{'type': 'text', 'text': 'Task'}], None)
        self.assertTrue(any(arg.startswith('mcp_servers={"fixture"=') and 'fixture-mcp' in arg for arg in command.call_args.args[0]))
        with patch.object(bg, 'ensure_qwen') as ensure:
            with self.assertRaises(bg.ProviderUnavailable):
                runner.qwen({'provider': 'qwen'}, [{'type': 'text', 'text': 'Task'}])
        ensure.assert_not_called()

    def test_qwen_does_not_execute_a_denied_push(self):
        runner = self.runner('--provider', 'qwen', '--tools', 'Bash', '--disallowedTools', 'Bash(git push:*)', '--no-session-persistence')
        first = {'message': {'role': 'assistant', 'content': '', 'tool_calls': [{'function': {'name': 'run_command', 'arguments': {'command': 'git push'}}}]}}
        final = {'message': {'role': 'assistant', 'content': 'Blocked'}}
        with patch.object(bg, 'ensure_qwen'), patch.object(bg, 'command', side_effect=[(0, json.dumps(first).encode(), b''), (0, json.dumps(final).encode(), b'')]) as command:
            result = runner.qwen({'provider': 'qwen'}, [{'type': 'text', 'text': 'Task'}])
        self.assertEqual(command.call_count, 2)
        self.assertEqual(result['result'], 'Blocked')

    def test_nonpersistent_followup_keeps_context_without_invalid_resume(self):
        runner = self.runner('--no-session-persistence')
        with patch.object(runner, 'claude', return_value={'is_error': False, 'result': 'First reply', 'session_id': 'transient'}) as claude:
            runner.turn([{'type': 'text', 'text': 'Remember this'}])
            runner.turn([{'type': 'text', 'text': 'Continue'}])
            self.assertIsNone(claude.call_args.args[2])
            self.assertIn('Remember this', bg.content_text(claude.call_args.args[1]))
        self.assertFalse(runner.snapshot().exists())

    def test_codex_sealed_turn_disables_local_tools_and_keeps_web(self):
        runner = self.runner('--tools', 'WebSearch,WebFetch', '--strict-mcp-config', '--no-session-persistence')
        events = [{'type': 'thread.started', 'thread_id': 'thread'}, {'type': 'item.completed', 'item': {'type': 'agent_message', 'text': 'Checked sources'}}]
        with patch.object(bg, 'command', return_value=(0, '\n'.join(map(json.dumps, events)).encode(), b'')) as command:
            result = runner.codex({'provider': 'codex'}, [{'type': 'text', 'text': 'Untrusted article'}], None)
        args = command.call_args.args[0]
        for option in ['--ignore-user-config', 'features.shell_tool=false', 'features.view_image=false', 'features.plugins=false', 'features.hooks=false', 'web_search="live"', 'sandbox_mode="read-only"']:
            self.assertIn(option, args)
        self.assertNotIn('--dangerously-bypass-approvals-and-sandbox', args)
        self.assertNotEqual(command.call_args.kwargs['cwd'], str(self.home))
        self.assertFalse(result['is_error'])

    def test_qwen_has_no_tools_for_sealed_inputs(self):
        runner = self.runner('--tools', '', '--no-session-persistence')
        answer = {'message': {'role': 'assistant', 'content': 'Answer'}}
        with patch.object(bg, 'ensure_qwen'), patch.object(bg, 'command', return_value=(0, json.dumps(answer).encode(), b'')) as command:
            result = runner.qwen({'provider': 'qwen'}, [{'type': 'text', 'text': 'Untrusted input'}])
        payload = json.loads(command.call_args.args[1])
        self.assertNotIn('tools', payload)
        self.assertEqual(result['result'], 'Answer')

    def test_qwen_honours_a_shell_deny_flag(self):
        for args in [[], ['--tools', 'Bash']]:
            runner = self.runner(*args, '--disallowedTools', 'Bash', '--no-session-persistence')
            answer = {'message': {'role': 'assistant', 'content': 'Answer'}}
            with patch.object(bg, 'ensure_qwen'), patch.object(bg, 'command', return_value=(0, json.dumps(answer).encode(), b'')) as command:
                runner.qwen({'provider': 'qwen'}, [{'type': 'text', 'text': 'Task'}])
            self.assertNotIn('tools', json.loads(command.call_args.args[1]))

    def test_sealed_strict_codex_does_not_make_incomplete_mcp_entries(self):
        config = self.home / '.codex/config.toml'
        config.parent.mkdir()
        config.write_text('[mcp_servers.lightpanda]\ncommand="lightpanda"\n')
        runner = self.runner('--tools', '', '--strict-mcp-config', '--no-session-persistence')
        with patch.object(bg, 'command', return_value=(0, b'{"type":"item.completed","item":{"type":"agent_message","text":"Done"}}', b'')) as command:
            runner.codex({'provider': 'codex'}, [{'type': 'text', 'text': 'Task'}], None)
        args = command.call_args.args[0]
        self.assertIn('--ignore-user-config', args)
        self.assertNotIn('mcp_servers.lightpanda.enabled=false', args)

    def test_wake_is_only_sent_when_remote_qwen_is_unreachable(self):
        wake = self.home / 'self/jarvis/tools/wake-pc.py'
        wake.parent.mkdir(parents=True)
        wake.touch()
        prefs = dict(qwenURL='http://192.0.2.1:11434/api/chat', qwenProxy='', qwenWake=True)
        calls = []

        def run(args, **kwargs):
            calls.append(args)
            return (1 if len(calls) == 1 else 0, b'', b'')

        bg.ensure_qwen(prefs, run=run, sleep=lambda _: None)
        self.assertEqual(len(calls), 3)
        self.assertEqual(calls[1], ['/opt/homebrew/bin/python3', str(wake)])
        calls.clear()
        bg.ensure_qwen(prefs, run=lambda args, **kwargs: calls.append(args) or (0, b'', b''))
        self.assertEqual(len(calls), 1)

    def test_local_qwen_failure_does_not_wake_windows(self):
        calls = []
        with self.assertRaisesRegex(RuntimeError, 'local Qwen'):
            bg.ensure_qwen(dict(qwenURL='http://127.0.0.1:11434/api/chat', qwenProxy=''), run=lambda args, **kwargs: calls.append(args) or (1, b'', b''))
        self.assertEqual(len(calls), 1)

    def test_remote_qwen_failure_does_not_wake_without_opt_in(self):
        calls = []
        with self.assertRaisesRegex(RuntimeError, 'wake is disabled'):
            bg.ensure_qwen(dict(qwenURL='http://192.0.2.1:11434/api/chat', qwenProxy=''), run=lambda args, **kwargs: calls.append(args) or (1, b'', b''))
        self.assertEqual(len(calls), 1)

    def test_unavailable_qwen_falls_back_before_running_a_task(self):
        runner = self.runner('--provider', 'qwen', '--no-session-persistence')
        with patch.object(runner, 'qwen', side_effect=bg.ProviderUnavailable('offline')), patch.object(runner, 'claude', return_value={'result': 'Ready', 'is_error': False}) as claude:
            result = runner.turn([{'type': 'text', 'text': 'Task'}])
        self.assertEqual(result['provider'], 'claude')
        claude.assert_called_once()

    def test_claude_start_failure_does_not_switch_provider(self):
        for failure in [dict(side_effect=FileNotFoundError()), dict(return_value={'result': 'Not logged in. Please run /login', 'is_error': True})]:
            runner = self.runner('--no-session-persistence')
            with patch.object(runner, 'claude', **failure), patch.object(runner, 'codex') as codex, patch.object(runner, 'qwen') as qwen:
                result = runner.turn([{'type': 'text', 'text': 'Task'}])
            self.assertTrue(result['is_error'])
            codex.assert_not_called()
            qwen.assert_not_called()

    def test_codex_tool_events_stream_before_completion(self):
        import io
        runner = self.runner('--provider', 'codex', '--output-format', 'stream-json', '--no-session-persistence')
        events = [{'type': 'item.started', 'item': {'id': 'cmd', 'type': 'command_execution', 'command': 'true'}},
                  {'type': 'item.completed', 'item': {'id': 'cmd', 'type': 'command_execution', 'command': 'true', 'status': 'completed', 'aggregated_output': 'done'}},
                  {'type': 'item.completed', 'item': {'id': 'msg', 'type': 'agent_message', 'text': 'Answer'}}]
        output = io.StringIO()
        def run(args, *positional, on_line=None, **kwargs):
            for event in events:
                on_line(json.dumps(event).encode())
            self.assertIn('tool_use', output.getvalue())
            return 0, '\n'.join(map(json.dumps, events)).encode(), b''
        with patch('sys.stdout', output), patch.object(bg, 'command', side_effect=run):
            result = runner.turn([{'type': 'text', 'text': 'Task'}])
            bg.emit(result, runner.args)
        emitted = list(map(json.loads, output.getvalue().splitlines()))
        self.assertEqual([e['type'] for e in emitted], ['assistant', 'user', 'assistant', 'result'])

    def test_qwen_can_discover_project_skills(self):
        skill = self.home / '.agents/skills/fixture/SKILL.md'
        skill.parent.mkdir(parents=True)
        skill.write_text('---\nname: fixture\ndescription: Use for fixture tasks\n---\nRead the fixture.\n')
        runner = self.runner('--no-session-persistence')
        answer = {'message': {'role': 'assistant', 'content': 'Answer'}}
        with patch.object(bg, 'ensure_qwen'), patch.object(bg, 'command', return_value=(0, json.dumps(answer).encode(), b'')) as command:
            runner.qwen({'provider': 'qwen'}, [{'type': 'text', 'text': 'Fixture task'}])
        system = json.loads(command.call_args.args[1])['messages'][0]['content']
        self.assertIn(str(skill), system)
        self.assertIn('Use for fixture tasks', system)

    def test_qwen_returns_only_the_final_answer(self):
        runner = self.runner('--tools', '', '--no-session-persistence')
        for content in ['Answer', '<think>Reasoning</think>\nAnswer', 'Reasoning</think>\nAnswer', '<think>Incomplete']:
            response = {'message': {'role': 'assistant', 'content': content}}
            with patch.object(bg, 'ensure_qwen'), patch.object(bg, 'command', return_value=(0, json.dumps(response).encode(), b'')):
                result = runner.qwen({'provider': 'qwen'}, [{'type': 'text', 'text': 'Task'}])
            self.assertEqual(result['is_error'], content == '<think>Incomplete')
            if not result['is_error']:
                self.assertEqual(result['result'], 'Answer')

    def test_qwen_permission_hook_blocks_a_command(self):
        settings = {'hooks': {'PreToolUse': [{'matcher': 'Bash', 'hooks': [{'type': 'command', 'command': 'deny-command'}]}]}}
        runner = self.runner('--tools', 'Bash', '--settings', json.dumps(settings))
        responses = [(0, json.dumps({'message': {'role': 'assistant', 'content': '', 'tool_calls': [{'function': {'name': 'run_command', 'arguments': {'command': 'touch forbidden'}}}]}}).encode(), b''),
                     (2, b'', b'blocked'), (0, json.dumps({'message': {'role': 'assistant', 'content': 'Blocked'}}).encode(), b'')]
        with patch.object(bg, 'ensure_qwen'), patch.object(bg, 'command', side_effect=responses) as command:
            result = runner.qwen({'provider': 'qwen'}, [{'type': 'text', 'text': 'Run a command'}])
        self.assertEqual(result['result'], 'Blocked')
        self.assertEqual(command.call_count, 3)
        self.assertEqual(command.call_args_list[1].args[0], ['/bin/sh', '-c', 'deny-command'])

    def test_codex_retains_the_custom_permission_hook(self):
        settings = {'hooks': {'PreToolUse': [{'matcher': 'Bash', 'hooks': [{'type': 'command', 'command': 'deny-command'}]}]}}
        runner = self.runner('--tools', 'Bash', '--settings', json.dumps(settings))
        with patch.object(bg, 'command', return_value=(0, b'{"type":"item.completed","item":{"type":"agent_message","text":"Done"}}', b'')) as command:
            runner.codex({'provider': 'codex'}, [{'type': 'text', 'text': 'Task'}], None)
        args = command.call_args.args[0]
        self.assertIn('features.hooks=true', args)
        self.assertEqual(args.count('--dangerously-bypass-hook-trust'), 1)
        hook_config = next(arg for arg in args if arg.startswith('hooks.PreToolUse='))
        self.assertIn('deny-command', hook_config)
        self.assertIn('--check-tools', hook_config)

    def test_explicit_default_mode_cannot_inherit_bypass(self):
        runner = self.runner('--permission-mode', 'default', '--no-session-persistence')
        with patch.object(bg, 'command', return_value=(0, b'{"type":"item.completed","item":{"type":"agent_message","text":"Done"}}', b'')) as command:
            runner.codex({'provider': 'codex'}, [{'type': 'text', 'text': 'Task'}], None)
        self.assertNotIn('--dangerously-bypass-approvals-and-sandbox', command.call_args.args[0])
        self.assertIn('read-only', command.call_args.args[0])
        with patch.object(bg, 'ensure_qwen'), patch.object(bg, 'command') as command:
            with self.assertRaisesRegex(ValueError, 'requires command approval'):
                runner.qwen({'provider': 'qwen'}, [{'type': 'text', 'text': 'Task'}])
        command.assert_not_called()

    def test_sealed_tool_guard_denies_native_file_edits(self):
        import io
        for tool, status in [('Bash', 0), ('apply_patch', 2), ('Read', 2)]:
            with patch('sys.stdin', io.StringIO(json.dumps({'tool_name': tool}))), patch('sys.stderr', io.StringIO()):
                self.assertEqual(bg.main(['--check-tools', 'Bash']), status)
        with patch('sys.stdin', io.StringIO('{"tool_name":"web.run"}')):
            self.assertEqual(bg.main(['--check-tools', 'WebSearch']), 0)
        with patch('sys.stdin', io.StringIO('{"tool_name":"webrun"}')):
            self.assertEqual(bg.main(['--check-tools', 'WebSearch']), 0)

    def test_codex_startup_warnings_do_not_prevent_quota_fallback(self):
        runner = self.runner('--provider', 'codex', '--no-session-persistence')
        events = [{'type': 'item.completed', 'item': {'id': 'warning', 'type': 'error', 'message': 'Hooks are enabled'}},
                  {'type': 'turn.failed', 'error': {'message': 'Usage limit reached'}}]
        with patch.object(bg, 'command', return_value=(1, '\n'.join(map(json.dumps, events)).encode(), b'')), patch.object(runner, 'claude', return_value={'result': 'Done'}) as fallback:
            result = runner.turn([{'type': 'text', 'text': 'Task'}])
        fallback.assert_called_once()
        self.assertEqual(result['provider'], 'claude')

    def test_qwen_exceptions_keep_completed_or_uncertain_actions(self):
        first = {'message': {'role': 'assistant', 'content': '', 'tool_calls': [{'function': {'name': 'run_command', 'arguments': {'command': 'send_once'}}}]}}
        for persist in [True, False]:
            for late in [subprocess.TimeoutExpired('curl', 125), (0, b'invalid JSON', b''), 'shell-timeout']:
                runner = self.runner('--provider', 'qwen', '--tools', 'Bash', *([] if persist else ['--no-session-persistence']))
                responses = [(0, json.dumps(first).encode(), b'')]
                responses += [subprocess.TimeoutExpired('shell', 120)] if late == 'shell-timeout' else [(0, b'Already sent', b''), late]
                with patch.object(bg, 'ensure_qwen'), patch.object(bg, 'command', side_effect=responses), patch.object(runner, 'claude') as fallback:
                    result = runner.turn([{'type': 'text', 'text': 'Task'}])
                fallback.assert_not_called()
                self.assertTrue(result['is_error'])
                evidence = runner.snapshot().read_text() if persist else result['result']
                self.assertIn('send_once', evidence)
                self.assertIn('Outcome unknown' if late == 'shell-timeout' else 'Already sent', evidence)
                runner.close()

    def test_stream_input_accepts_string_content(self):
        import io
        self.addCleanup(os.chdir, os.getcwd())
        with patch('sys.stdin', io.StringIO('{"type":"user","message":{"content":"Question"}}\n')), patch('sys.stdout', io.StringIO()), patch.object(bg.Runner, 'turn', return_value={'result': 'Answer'}) as turn:
            self.assertEqual(bg.main(['-p', '--cwd', str(self.home), '--input-format', 'stream-json']), 0)
        self.assertEqual(turn.call_args.args[0], [{'type': 'text', 'text': 'Question'}])

    def test_disabled_profiles_and_cached_limits_are_respected(self):
        prefs = bg.preferences()
        prefs['provider'] = 'codex'
        prefs['accounts'][0]['enabled'] = False
        self.assertEqual([a['provider'] for a in bg.candidates(prefs, bg.options(['-p']))], ['codex', 'qwen'])

    def test_schema_and_unknown_flags_fail_before_running(self):
        with self.assertRaises(SystemExit), patch.object(bg, 'command') as command:
            bg.options(['-p', '--unsupported-security-flag'])
            command.assert_not_called()

    def test_provider_environment_does_not_inherit_another_codex_profile(self):
        with patch.dict(os.environ, {'CODEX_HOME': '/tmp/other-profile', 'CODEX_THREAD_ID': 'other-thread'}):
            default = bg.environment({'provider': 'codex'})
            selected = bg.environment({'provider': 'codex', 'home': '/tmp/selected-profile'})
        self.assertTrue('CODEX_HOME' not in default, 'default account inherited CODEX_HOME')
        self.assertTrue('CODEX_THREAD_ID' not in default, 'default account inherited CODEX_THREAD_ID')
        self.assertEqual(selected['CODEX_HOME'], '/tmp/selected-profile')


if __name__ == '__main__':
    unittest.main()
