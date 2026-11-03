import asyncio
import io
import json
import os
import sys
import tempfile
import unittest
from html import unescape
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from rich.console import Console
from textual.widgets import Button, Collapsible, Input

from cx import BLUE, GREEN, ORANGE, CxApp, Prompt, Reply, RequestScreen, clean, prompt_input, reply_content, tool_content
from rpc import CodexClient, RpcError
import install


def rendered(source):
    output = io.StringIO()
    console = Console(file=output, force_terminal=True, no_color=False, color_system="truecolor", width=70)
    console.print(reply_content(source))
    return output.getvalue()


class RenderingTests(unittest.TestCase):
    def test_semantic_bands_and_markdown(self):
        output = rendered("⟶ Answer\n\n**Details**\n\n✓ Done: fixed\n\n⟶ Next: look")
        self.assertIn("48;2;214;245;214", output)
        self.assertIn("48;2;255;225;195", output)
        self.assertIn("48;2;214;230;255", output)
        self.assertIn("Details", output)

    def test_code_examples_do_not_become_bands(self):
        console = Console(force_terminal=True, no_color=False, color_system="truecolor", width=70)
        segments = list(console.render(reply_content("```text\n⟶ Example\n```\n⟶ Actual answer")))
        example = next(s for s in segments if "Example" in s.text)
        answer = next(s for s in segments if "Actual answer" in s.text)
        self.assertNotEqual(example.style.bgcolor.name if example.style.bgcolor else None, GREEN)
        self.assertEqual(answer.style.bgcolor.name, GREEN)

    def test_terminal_controls_cannot_escape_into_display(self):
        self.assertEqual(clean("a\x1b[2Jb\x1b]52;c;secret\x07c\x00\n"), "abc\n")

    def test_long_output_cannot_restore_controls_from_its_title(self):
        result = tool_content({"type": "fileChange", "changes": [{"path": "bad\x1b]52;c;secret\x07.py", "diff": "x" * 20000}]})
        self.assertNotIn("\x1b", result.plain)

    def test_image_paths_become_local_image_inputs(self):
        with tempfile.TemporaryDirectory() as tmp:
            image = Path(tmp) / "screenshot with spaces.png"
            image.touch()
            text, inputs = prompt_input(f"Check this {image} now")
            self.assertEqual(text, "Check this now")
            self.assertEqual(inputs, [
                {"type": "text", "text": "Check this now"},
                {"type": "localImage", "path": str(image.resolve())},
            ])


class InstallTests(unittest.TestCase):
    def test_replaces_alias_without_writing_through_to_codex(self):
        with tempfile.TemporaryDirectory(prefix="cx-install-") as tmp:
            root = Path(tmp)
            home = root / "home"
            target = home / ".local/bin/cx"
            target.parent.mkdir(parents=True)
            codex = root / "codex"
            codex.write_bytes(b"original executable")
            target.symlink_to(codex)
            with patch.object(Path, "home", return_value=home), patch.object(install.shutil, "which", return_value=str(codex)), patch.object(install.subprocess, "run"), patch.object(install.venv, "create"):
                install.install()
            self.assertFalse(target.is_symlink())
            self.assertIn("# cx launcher\n", target.read_text())
            self.assertEqual(codex.read_bytes(), b"original executable")
            target.write_text("Unrelated command")
            with patch.object(Path, "home", return_value=home), patch.object(install.subprocess, "run"), patch.object(install.venv, "create"):
                with self.assertRaises(SystemExit):
                    install.install()
            self.assertEqual(target.read_text(), "Unrelated command")


class RpcTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.client = CodexClient([sys.executable, str(Path(__file__).with_name("fake_codex.py"))])
        await self.client.start()

    async def asyncTearDown(self):
        await self.client.close()

    async def test_notifications_do_not_block_responses(self):
        result = await self.client.request("echo", {"hello": "world"})
        self.assertEqual(result, {"hello": "world"})
        event = await asyncio.wait_for(self.client.events.get(), 1)
        self.assertEqual(event["method"], "test/event")

    async def test_server_errors_are_reported(self):
        with self.assertRaisesRegex(RpcError, "Expected failure"):
            await self.client.request("fail")

    async def test_interactive_requests_reach_the_ui(self):
        await self.client.request("request")
        event = await asyncio.wait_for(self.client.events.get(), 1)
        self.assertEqual(event["id"], 999)
        await self.client.respond(999, {"answers": {}})

    async def test_disconnect_fails_waiting_request(self):
        with self.assertRaisesRegex(RpcError, "connection"):
            await asyncio.wait_for(self.client.request("exit"), 2)


class FakeClient:
    def __init__(self):
        self.calls = []
        self.responses = []
        self.events = asyncio.Queue()

    async def request(self, method, params=None):
        self.calls.append((method, params))
        if method in ("thread/start", "thread/resume"):
            return {"thread": {"id": "thread-test"}, "model": "test-model"}
        if method == "thread/turns/list":
            return {"data": [{"id": "old-turn", "status": "completed", "items": [
                {"type": "userMessage", "id": "old-user", "content": [{"type": "text", "text": "Earlier prompt"}]},
                {"type": "agentMessage", "id": "old-reply", "text": "Earlier response"},
            ]}], "nextCursor": None}
        return {}

    async def respond(self, request_id, result=None, error=None):
        self.responses.append((request_id, result, error))

    async def close(self):
        pass


class UiTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.client = FakeClient()
        self.app = CxApp(cwd=self.tmp.name, client=self.client, state_dir=self.tmp.name, offline=True)

    async def asyncTearDown(self):
        self.tmp.cleanup()

    async def test_streaming_final_text_and_tool_folding(self):
        async with self.app.run_test(size=(100, 32)) as pilot:
            app = self.app
            app.thread_id, app.busy = "thread-test", True
            await app.handle_event({"method": "item/agentMessage/delta", "params": {"itemId": "reply", "delta": "⟶ Hel"}})
            await app.handle_event({"method": "item/agentMessage/delta", "params": {"itemId": "reply", "delta": "lo"}})
            app.flush()
            self.assertEqual(app.widgets["reply"].source, "⟶ Hello")
            await app.handle_event({"method": "item/completed", "params": {"item": {"type": "agentMessage", "id": "reply", "text": "⟶ Final"}}})
            self.assertEqual(app.widgets["reply"].source, "⟶ Final")
            await app.show_item({"type": "commandExecution", "id": "cmd", "command": "python --version", "aggregatedOutput": "Python", "exitCode": 0})
            group = app.query_one(Collapsible)
            self.assertTrue(group.collapsed)
            await pilot.press("ctrl+t")
            self.assertFalse(group.collapsed)
            await pilot.resize_terminal(45, 20)
            await pilot.pause()
            region = app.query_one("#prompt").region
            self.assertGreater(region.height, 0)
            self.assertLessEqual(region.right, 45)
            self.assertLessEqual(region.bottom, 20)
            self.assertGreater(app.query_one("#keys").region.height, 1)

    async def test_enter_submits_and_alt_enter_inserts_newline(self):
        async with self.app.run_test() as pilot:
            self.app.ready, self.app.thread_id = True, "thread-test"
            prompt = self.app.query_one(Prompt)
            await pilot.press("h", "i", "alt+enter", "x")
            self.assertEqual(prompt.text, "hi\nx")
            await pilot.press("enter")
            self.assertEqual(self.client.calls[-1][0], "turn/start")
            self.assertEqual(self.client.calls[-1][1]["input"][0]["text"], "hi\nx")
            self.assertEqual(prompt.text, "")

    async def test_option_delete_removes_previous_word(self):
        async with self.app.run_test() as pilot:
            prompt = self.app.query_one(Prompt)
            prompt.load_text("keep this word")
            prompt.cursor_location = (0, len(prompt.text))
            await pilot.press("alt+backspace")
            self.assertEqual(prompt.text, "keep this ")

    async def test_image_path_is_sent_as_attachment(self):
        with tempfile.TemporaryDirectory() as tmp:
            image = Path(tmp) / "screenshot with spaces.png"
            image.touch()
            async with self.app.run_test() as pilot:
                self.app.ready, self.app.thread_id = True, "thread-test"
                await self.app.submit(f"Inspect {image}")
                self.assertEqual(self.client.calls[-1][1]["input"], [
                    {"type": "text", "text": "Inspect"},
                    {"type": "localImage", "path": str(image.resolve())},
                ])

    async def test_clear_compact_and_review_commands(self):
        async with self.app.run_test() as pilot:
            self.app.ready, self.app.thread_id = True, "thread-test"
            await self.app.command("/compact")
            self.assertEqual(self.client.calls[-1], ("thread/compact/start", {"threadId": "thread-test"}))
            await self.app.command("/review")
            self.assertEqual(self.client.calls[-1], ("review/start", {
                "threadId": "thread-test", "target": {"type": "uncommittedChanges"}, "delivery": "inline",
            }))
            await self.app.command("/clear")
            self.assertEqual(self.client.calls[-1][0], "thread/start")

    async def test_steer_and_interrupt(self):
        async with self.app.run_test() as pilot:
            self.app.ready, self.app.busy = True, True
            self.app.thread_id, self.app.turn_id = "thread-test", "turn-test"
            await self.app.submit("Also check this")
            self.assertEqual(self.client.calls[-1][0], "turn/steer")
            self.assertEqual(self.client.calls[-1][1]["expectedTurnId"], "turn-test")
            await pilot.press("ctrl+c")
            self.assertEqual(self.client.calls[-1], ("turn/interrupt", {"threadId": "thread-test", "turnId": "turn-test"}))

    async def test_ctrl_c_quits_when_idle(self):
        async with self.app.run_test() as pilot:
            self.app.query_one(Prompt).load_text("Unsent prompt")
            await pilot.press("ctrl+c")
            self.assertFalse(self.app.is_running)

    async def test_resume_restores_history_and_private_last_pointer(self):
        async with self.app.run_test() as pilot:
            await self.app.open_thread("saved-thread")
            self.assertEqual(self.client.calls[0][0], "thread/resume")
            self.assertEqual(self.app.widgets["old-reply"].source, "Earlier response")
            self.assertEqual(json.loads(self.app.last_file.read_text())["threadId"], "thread-test")
            self.assertEqual(self.app.last_file.stat().st_mode & 0o777, 0o600)

    async def test_failed_tool_is_visible_while_folded(self):
        async with self.app.run_test() as pilot:
            await self.app.show_item({"type": "commandExecution", "id": "cmd", "command": "false", "exitCode": 1})
            self.assertTrue(self.app.query_one(Collapsible).collapsed)
            self.assertEqual(len(self.app.query(".error")), 1)

    async def test_prompt_survives_a_failed_send(self):
        async def fail(method, params):
            raise RpcError("Connection lost")
        self.client.request = fail
        async with self.app.run_test() as pilot:
            self.app.ready, self.app.thread_id = True, "thread-test"
            await self.app.submit("Keep this prompt")
            self.assertEqual(self.app.query_one(Prompt).text, "Keep this prompt")
            self.assertEqual(len(self.app.query(".user-message")), 0)
            self.assertFalse(self.app.busy)

    async def test_warnings_are_visible(self):
        async with self.app.run_test() as pilot:
            await self.app.handle_event({"method": "configWarning", "params": {"summary": "Invalid setting"}})
            self.assertEqual(len(self.app.query(".notice")), 1)

    async def test_usage_next_to_context_updates_and_survives_new_chat(self):
        async with self.app.run_test(size=(120, 32)) as pilot:
            await self.app.handle_event({"method": "thread/tokenUsage/updated", "params": {
                "tokenUsage": {"last": {"totalTokens": 12000}, "modelContextWindow": 100000},
            }})
            await self.app.handle_event({"method": "account/rateLimits/updated", "params": {"rateLimits": {
                "primary": {"usedPercent": 27, "windowDurationMins": 300},
                "secondary": {"usedPercent": 20, "windowDurationMins": 10080},
            }}})
            await pilot.pause()
            self.assertIn("12% context", self.app.context)
            self.assertIn("usage 27% 5h / 20% weekly", self.app.usage)
            self.assertIn("usage 27% 5h / 20% weekly", unescape(self.app.export_screenshot()).replace("\u00a0", " "))
            await self.app.open_thread(reset=True)
            self.assertIn("27% 5h", self.app.usage)
            await self.app.handle_event({"method": "account/rateLimits/updated", "params": {"rateLimits": {
                "primary": {"usedPercent": 0, "windowDurationMins": 15},
            }}})
            self.assertIn("usage 0% 15m", self.app.usage)
            self.assertNotIn("weekly", self.app.usage)

    async def test_usage_reads_live_limits_and_handles_unavailable(self):
        original = self.client.request
        async def request(method, params=None):
            if method == "account/rateLimits/read":
                return {"rateLimits": {"secondary": {"usedPercent": 100, "windowDurationMins": 10080}}}
            return await original(method, params)
        self.client.request = request
        async with self.app.run_test() as pilot:
            await self.app.refresh_usage()
            self.assertIn("usage 100% weekly", self.app.usage)
            async def fail(method, params=None):
                raise RpcError("Not available for this account")
            self.client.request = fail
            await self.app.refresh_usage()
            self.assertIn("usage unavailable", self.app.usage)
            self.assertEqual(len(self.app.query(".error")), 0)

    async def test_disconnected_answer_does_not_crash(self):
        async def respond(*args, **kwargs):
            raise RpcError("Connection closed")
        self.client.respond = respond
        async with self.app.run_test() as pilot:
            await self.app.handle_event({"id": 15, "method": "item/commandExecution/requestApproval", "params": {"command": "echo test"}})
            await pilot.pause()
            await pilot.click("#decline")
            await pilot.pause()
            self.assertEqual(len(self.app.query(".error")), 1)
            self.assertNotIsInstance(self.app.screen, RequestScreen)

    async def test_events_during_resume_wait_for_history(self):
        original_request = self.client.request
        async def request(method, params):
            if method == "thread/turns/list":
                await self.client.events.put({"method": "item/agentMessage/delta", "params": {"threadId": "thread-test", "itemId": "new-reply", "delta": "Received during resume"}})
                await asyncio.sleep(0.01)
            return await original_request(method, params)
        self.client.request = request
        async with self.app.run_test() as pilot:
            self.app.run_worker(self.app.consume())
            await self.app.open_thread("thread-test")
            await pilot.pause()
            self.app.flush()
            self.assertEqual(self.app.widgets["new-reply"].source, "Received during resume")

    async def test_tool_groups_preserve_message_order(self):
        async with self.app.run_test() as pilot:
            await self.app.show_item({"type": "commandExecution", "id": "a", "command": "first"})
            await self.app.show_item({"type": "agentMessage", "id": "b", "text": "Between tools"})
            await self.app.show_item({"type": "commandExecution", "id": "c", "command": "second"})
            groups = list(self.app.groups.values())
            self.assertEqual(groups, [["a"], ["c"]])
            await self.app.add_user("Steering prompt")
            await self.app.show_item({"type": "commandExecution", "id": "d", "command": "third"})
            self.assertEqual(list(self.app.groups.values()), [["a"], ["c"], ["d"]])

    async def test_invalid_resume_keeps_current_chat_usable(self):
        original_request = self.client.request
        async def request(method, params):
            if params.get("threadId") == "invalid":
                raise RpcError("Thread not found")
            return await original_request(method, params)
        self.client.request = request
        async with self.app.run_test() as pilot:
            await self.app.open_thread()
            await self.app.show_item({"type": "agentMessage", "id": "kept", "text": "Keep me"})
            await self.app.command("/resume invalid")
            self.assertTrue(self.app.ready)
            self.assertIn("kept", self.app.widgets)
            await self.app.command("/new")
            self.assertTrue(self.app.ready)
            self.assertNotIn("kept", self.app.widgets)

    async def test_stop_during_turn_start_is_not_lost(self):
        async with self.app.run_test() as pilot:
            self.app.ready, self.app.busy, self.app.thread_id = True, True, "thread-test"
            await self.app.action_interrupt()
            self.assertTrue(self.app.stop_requested)
            await self.app.handle_event({"method": "turn/started", "params": {"turn": {"id": "late-turn"}}})
            await pilot.pause()
            self.assertEqual(self.client.calls[-1], ("turn/interrupt", {"threadId": "thread-test", "turnId": "late-turn"}))

    async def test_questions_can_be_answered(self):
        async with self.app.run_test() as pilot:
            await self.app.handle_event({"id": 9, "method": "item/tool/requestUserInput", "params": {"questions": [
                {"id": "q", "question": "Which color?", "options": [{"label": "Green", "description": "Pastel"}]}
            ]}})
            await pilot.pause()
            self.assertIsInstance(self.app.screen, RequestScreen)
            self.app.screen.query_one(Input).value = "1"
            await pilot.click("#send-answers")
            await pilot.pause()
            self.assertEqual(self.client.responses[0], (9, {"answers": {"q": {"answers": ["Green"]}}}, None))

    async def test_permission_is_not_accepted_implicitly(self):
        async with self.app.run_test() as pilot:
            await self.app.handle_event({"id": 10, "method": "item/commandExecution/requestApproval", "params": {"command": "echo test"}})
            await pilot.pause()
            self.assertEqual(self.client.responses, [])
            await pilot.click("#decline")
            await pilot.pause()
            self.assertEqual(self.client.responses[0][1], {"decision": "decline"})

    async def test_narrow_permission_dialog_keeps_buttons_visible(self):
        async with self.app.run_test(size=(45, 20)) as pilot:
            await self.app.handle_event({"id": 10, "method": "item/commandExecution/requestApproval", "params": {"command": "echo test\n" * 30}})
            await pilot.pause()
            for button in self.app.screen.query(Button):
                self.assertLessEqual(button.region.right, 45)
                self.assertLessEqual(button.region.bottom, 20)
                self.assertGreaterEqual(button.region.x, 0)
                self.assertGreaterEqual(button.region.y, 0)
            await pilot.click("#cancel")
            await pilot.pause()
            self.assertEqual(self.client.responses[0][1], {"decision": "cancel"})

    async def test_file_approval_includes_diff(self):
        async with self.app.run_test() as pilot:
            changes = [{"path": "example.py", "diff": "- old\n+ new"}]
            self.app.items["edit"] = {"type": "fileChange", "changes": changes}
            await self.app.handle_event({"id": 10, "method": "item/fileChange/requestApproval", "params": {"itemId": "edit"}})
            await pilot.pause()
            self.assertEqual(self.app.screen.params["changes"], changes)
            self.assertFalse(self.app.screen.query_one("#allow", Button).disabled)
            await pilot.click("#cancel")

    async def test_unknown_requests_fail_visibly(self):
        async with self.app.run_test() as pilot:
            await self.app.handle_event({"id": 11, "method": "unknown/request", "params": {}})
            await pilot.pause()
            self.assertEqual(self.client.responses[0][2]["code"], -32601)
            self.assertEqual(len(self.app.query(".error")), 1)


if __name__ == "__main__":
    unittest.main()
