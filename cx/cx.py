#!/usr/bin/env python3
import argparse
import asyncio
import hashlib
import json
import os
import re
import sys
import uuid
from pathlib import Path

from rich.console import Group
from rich.markdown import Markdown
from rich.padding import Padding
from rich.text import Text
from textual import on
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.message import Message
from textual.screen import ModalScreen
from textual.theme import Theme
from textual.widgets import Button, Collapsible, Input, Static, TextArea

from rpc import CodexClient, RpcError


GREEN = "#d6f5d6"
BLUE = "#d6e6ff"
ORANGE = "#ffe1c3"
INK = "#27312e"
ESCAPES = re.compile(r"\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1b]*(?:\x07|\x1b\\)|[@-_])")


def clean(text):
    return "".join(c for c in ESCAPES.sub("", str(text)) if c in "\n\t" or (ord(c) >= 32 and not 127 <= ord(c) <= 159))


def reply_content(source):
    parts, body = [], []
    first = True
    fence = None
    for line in clean(source).splitlines():
        marker = re.match(r"^\s*(`{3,}|~{3,})", line)
        if marker:
            token = marker[1]
            if fence is None:
                fence = token
            elif token[0] == fence[0] and len(token) >= len(fence):
                fence = None
        color = None
        if fence is None:
            if line.startswith("⟶"):
                color = GREEN if first else BLUE
                first = False
            elif line.startswith("✓ Done"):
                color = ORANGE
        if color:
            if body:
                parts.append(Markdown("\n".join(body), code_theme="friendly"))
                body = []
            text = Text()
            text.append(line, style=f"bold {INK} on {color}")
            parts.append(Padding(text, (0, 1), style=f"{INK} on {color}", expand=True))
        else:
            body.append(line)
    if body:
        parts.append(Markdown("\n".join(body), code_theme="friendly"))
    return Group(*parts) if parts else Text("")


def tool_title(item):
    kind = item.get("type", "activity")
    if kind == "commandExecution":
        return clean(item.get("command", "Command")).splitlines()[0] or "Command"
    if kind == "fileChange":
        return "Edit " + ", ".join(Path(c.get("path", "file")).name for c in item.get("changes", []))
    if kind in ("mcpToolCall", "dynamicToolCall"):
        return ".".join(str(item[k]) for k in ("server", "namespace", "tool") if item.get(k))
    if kind == "webSearch":
        return "Search: " + clean(item.get("query", "web"))
    if kind == "reasoning":
        return "Thinking"
    return re.sub(r"(?<!^)([A-Z])", r" \1", kind).capitalize()


def tool_failed(item):
    return item.get("status") in ("failed", "declined") or item.get("success") is False or bool(item.get("error")) or item.get("exitCode") not in (None, 0)


def tool_content(item):
    lines = [tool_title(item)]
    if item.get("type") == "fileChange":
        lines += [c.get("diff", "") for c in item.get("changes", [])]
    elif item.get("type") == "reasoning":
        lines += item.get("summary", [])
    else:
        for key in ("aggregatedOutput", "result", "error", "contentItems", "output"):
            if item.get(key):
                value = item[key]
                lines.append(value if isinstance(value, str) else json.dumps(value, ensure_ascii=False, indent=2))
    output = clean("\n".join(lines))
    # shortcut: show the last 16 KB of long tool output; Codex retains the full transcript.
    if len(output) > 16384:
        output = clean(lines[0]) + "\n[Showing the last 16 KB; full output remains in Codex history.]\n" + output[-16384:]
    if item.get("exitCode") is not None:
        output += f"\nExit: {item['exitCode']}"
    return Text(output, style="#a12b2b" if tool_failed(item) else "#52605a")


class Reply(Static):
    def __init__(self, source="", **kwargs):
        self.source = source
        super().__init__(reply_content(source), **kwargs)

    def update_source(self, source):
        self.source = source
        self.update(reply_content(source))


class Prompt(TextArea):
    BINDINGS = [Binding("enter", "send", show=False, priority=True), Binding("shift+enter,alt+enter", "newline", show=False)]

    class Submitted(Message):
        def __init__(self, text):
            super().__init__()
            self.text = text

    def action_send(self):
        if self.text.strip():
            self.post_message(self.Submitted(self.text))

    def action_newline(self):
        self.insert("\n")


class RequestScreen(ModalScreen):
    BINDINGS = [Binding("escape", "cancel", "Cancel")]

    def __init__(self, method, params):
        super().__init__()
        self.method, self.params = method, params

    def compose(self) -> ComposeResult:
        with Vertical(id="request-box"):
            with VerticalScroll(id="request-details"):
                if self.method == "item/tool/requestUserInput":
                    for index, question in enumerate(self.params.get("questions", [])):
                        yield Static(clean(question["question"]), classes="request-title", markup=False)
                        options = question.get("options") or []
                        for n, option in enumerate(options, 1):
                            yield Static(f"{n}. {clean(option['label'])}: {clean(option.get('description', ''))}", markup=False)
                        yield Input(placeholder="Option number or your answer", password=question.get("isSecret", False), id=f"answer-{index}")
                else:
                    yield Static("Permission requested", classes="request-title")
                    yield Static(clean(self.params.get("reason") or "Codex needs your decision to continue."), markup=False)
                    if self.method == "item/fileChange/requestApproval":
                        for change in self.params.get("changes", []):
                            yield Static(clean(change.get("path", "") + "\n" + change.get("diff", "")), markup=False)
                        if not self.params.get("changes"):
                            yield Static("The proposed changes are unavailable. Cancel and ask Codex to show the diff.", markup=False)
                    else:
                        yield Static(clean(self.params.get("command") or json.dumps(self.params, ensure_ascii=False, indent=2)), markup=False)
            with Horizontal(classes="request-buttons"):
                if self.method == "item/tool/requestUserInput":
                    yield Button("Send answers", id="send-answers", variant="primary")
                else:
                    yield Button("Allow", id="allow", variant="primary", disabled=self.method == "item/fileChange/requestApproval" and not self.params.get("changes"))
                    yield Button("Decline", id="decline")
                yield Button("Cancel", id="cancel")

    @on(Button.Pressed)
    def answer(self, event):
        event.stop()
        choice = event.button.id
        if choice == "send-answers":
            answers = {}
            for index, q in enumerate(self.params.get("questions", [])):
                value = self.query_one(f"#answer-{index}", Input).value.strip()
                if not value:
                    self.query_one(f"#answer-{index}", Input).focus()
                    return
                options = q.get("options") or []
                if value.isdigit() and 1 <= int(value) <= len(options):
                    value = options[int(value) - 1]["label"]
                answers[q["id"]] = {"answers": [value]}
            self.dismiss({"answers": answers})
        elif choice in ("allow", "decline", "cancel"):
            self.dismiss({"decision": {"allow": "accept", "decline": "decline", "cancel": "cancel"}[choice]} if self.method != "item/tool/requestUserInput" else {"answers": {}})

    def action_cancel(self):
        self.dismiss({"answers": {}} if self.method == "item/tool/requestUserInput" else {"decision": "cancel"})


class CxApp(App):
    TITLE = "cx"
    CSS_PATH = "cx.tcss"
    BINDINGS = [
        Binding("ctrl+c", "interrupt", "Stop", priority=True),
        Binding("ctrl+q", "leave", "Quit", priority=True),
        Binding("ctrl+t", "toggle_tools", "Tool details", priority=True),
        Binding("ctrl+n", "new_thread", "New chat", priority=True),
        Binding("ctrl+l", "follow", "Latest", priority=True),
    ]

    def __init__(self, cwd=None, resume=None, initial_prompt="", client=None, state_dir=None, offline=False):
        super().__init__()
        self.cwd = str(Path(cwd or os.getcwd()).resolve())
        self.resume_id = resume
        self.initial_prompt = initial_prompt
        self.client = client or CodexClient()
        self.state_dir = Path(state_dir or Path.home() / ".local/state/cx")
        self.offline = offline
        self.thread_id = None
        self.turn_id = None
        self.ready = False
        self.busy = False
        self.submitting = False
        self.stop_requested = False
        self.event_gate = asyncio.Lock()
        self.focus_view = True
        self.items = {}
        self.widgets = {}
        self.groups = {}
        self.current_group = None
        self.dirty = set()
        self.seen_users = set()
        self.model = "Codex"
        self.context = ""
        self.register_theme(Theme(
            name="mr", primary="#416d5c", secondary="#56718c", accent="#b57c23",
            foreground=INK, background="#faf9f6", surface="#f1f0eb", panel="#f1f0eb",
            success="#416d5c", warning="#b57c23", error="#a12b2b", dark=False,
        ))
        self.theme = "mr"
        self.animation_level = "none"

    def compose(self) -> ComposeResult:
        yield Static("", id="topbar", markup=False)
        with VerticalScroll(id="transcript"):
            yield Static("Your workspace, with less noise.\nType a prompt. Tool activity stays folded until you need it.", id="welcome", markup=False)
        with Vertical(id="composer"):
            yield Static("Connecting to Codex...", id="activity", markup=False)
            yield Prompt(id="prompt", soft_wrap=True, show_line_numbers=False)
            yield Static("Enter send  ·  Alt+Enter newline  ·  Ctrl+T details  ·  Ctrl+C stop  ·  /help", id="keys", markup=False)

    async def on_mount(self):
        self.query_one("#prompt", Prompt).focus()
        self.set_interval(0.08, self.flush)
        self.update_bar()
        if not self.offline:
            self.run_worker(self.connect(), name="connection")

    def update_bar(self):
        mode = "FOCUS" if self.focus_view else "DETAILS"
        self.query_one("#topbar", Static).update(f" cx   {Path(self.cwd).name or '/'}   ·   {self.model}   ·   {mode}{self.context}")

    def status(self, text):
        self.query_one("#activity", Static).update(clean(text))

    async def notice(self, text, error=False):
        await self.query_one("#transcript", VerticalScroll).mount(Static(clean(text), classes="error" if error else "notice", markup=False))
        self.follow_if_bottom()

    def follow_if_bottom(self, force=False):
        view = self.query_one("#transcript", VerticalScroll)
        if force or view.is_vertical_scroll_end:
            view.call_after_refresh(view.scroll_end, animate=False)

    @property
    def last_file(self):
        return self.state_dir / (hashlib.sha256(self.cwd.encode()).hexdigest()[:24] + ".json")

    def save_last(self):
        self.state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        temporary = self.last_file.with_suffix(f".{os.getpid()}.tmp")
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as stream:
            json.dump({"threadId": self.thread_id}, stream)
        temporary.replace(self.last_file)

    async def connect(self):
        try:
            await self.client.start()
            self.run_worker(self.consume(), name="events")
            resume = self.resume_id
            if resume == "last":
                if not self.last_file.exists():
                    raise RpcError("No cx session saved for this folder. Start with cx to create one.")
                resume = json.loads(self.last_file.read_text())["threadId"]
            await self.open_thread(resume)
            if self.initial_prompt:
                await self.submit(self.initial_prompt)
        except (RpcError, OSError, ValueError, asyncio.TimeoutError) as exc:
            self.ready = False
            self.status("Connection failed. Ctrl+Q to exit.")
            await self.notice(str(exc), error=True)

    async def open_thread(self, resume=None, reset=False):
        async with self.event_gate:
            await self.load_thread(resume, reset)

    async def load_thread(self, resume=None, reset=False):
        was_ready = self.ready
        self.ready = False
        params = {"cwd": self.cwd}
        if resume:
            params.update(threadId=resume, excludeTurns=True)
        history = []
        try:
            result = await self.client.request("thread/resume" if resume else "thread/start", params)
            thread = result["thread"]
            if resume:
                cursor = None
                while True:
                    page = await self.client.request("thread/turns/list", {
                        "threadId": thread["id"], "limit": 50, "sortDirection": "asc", "itemsView": "full", "cursor": cursor,
                    })
                    history.extend(page["data"])
                    cursor = page.get("nextCursor")
                    if not cursor:
                        break
        except (RpcError, OSError, ValueError, KeyError, asyncio.TimeoutError):
            self.ready = was_ready
            raise
        if reset:
            await self.query_one("#transcript", VerticalScroll).remove_children()
            self.items.clear()
            self.widgets.clear()
            self.groups.clear()
            self.dirty.clear()
            self.seen_users.clear()
            self.current_group = None
        self.thread_id = thread["id"]
        self.model = result.get("model") or "Codex"
        self.busy, self.turn_id, self.stop_requested = False, None, False
        self.context = ""
        try:
            self.save_last()
        except OSError as exc:
            await self.notice(f"Could not save the resume pointer: {exc}", error=True)
        for turn in history:
            self.current_group = None
            for item in turn.get("items", []):
                await self.show_item(item, completed=turn.get("status") != "inProgress")
            if turn.get("status") == "inProgress":
                self.turn_id, self.busy = turn["id"], True
        self.ready = True
        self.update_bar()
        self.status("Working..." if self.busy else "Ready")
        self.follow_if_bottom(force=True)

    async def consume(self):
        while True:
            message = await self.client.events.get()
            try:
                async with self.event_gate:
                    await self.handle_event(message)
            except (RpcError, OSError, ValueError, KeyError, TypeError) as exc:
                await self.notice(f"Could not display a Codex event: {exc}", error=True)

    async def add_user(self, text):
        self.current_group = None
        welcome = self.query("#welcome")
        if welcome:
            await welcome.remove()
        widget = Static(Text(clean(text)), classes="user-message")
        await self.query_one("#transcript", VerticalScroll).mount(widget)
        return widget

    async def show_item(self, item, completed=False):
        item_id = item.get("id")
        if not item_id:
            return
        kind = item.get("type")
        self.items[item_id] = item
        if kind == "userMessage":
            client_id = item.get("clientId")
            if item_id in self.seen_users or client_id in self.seen_users:
                return
            self.seen_users.add(item_id)
            await self.add_user("\n".join(c.get("text", "") for c in item.get("content", []) if c.get("type") == "text"))
            return
        if kind in ("agentMessage", "plan"):
            if item_id not in self.widgets:
                self.current_group = None
                widget = Reply(classes="reply")
                self.widgets[item_id] = widget
                await self.query_one("#transcript", VerticalScroll).mount(widget)
            self.widgets[item_id].update_source(item.get("text", ""))
            if completed:
                self.dirty.discard(item_id)
        elif kind not in ("hookPrompt", "contextCompaction"):
            if item_id not in self.widgets:
                if self.current_group is None:
                    group = Collapsible(title="Activity", collapsed=self.focus_view, classes="tools")
                    await self.query_one("#transcript", VerticalScroll).mount(group)
                    self.current_group = group
                    self.groups[group] = []
                group = self.current_group
                self.groups[group].append(item_id)
                widget = Static(tool_content(item), classes="tool", markup=False)
                self.widgets[item_id] = widget
                await group.query_one(Collapsible.Contents).mount(widget)
            else:
                self.widgets[item_id].update(tool_content(item))
            self.update_groups()
            if tool_failed(item):
                await self.notice("Action failed: " + tool_title(item), error=True)
            elif not completed and self.busy:
                self.status("Working: " + tool_title(item))
        self.follow_if_bottom()

    def update_groups(self):
        for group, ids in self.groups.items():
            failures = sum(tool_failed(self.items[i]) for i in ids)
            group.title = f"{len(ids)} {'action' if len(ids) == 1 else 'actions'}" + (f" · {failures} failed" if failures else "")

    def flush(self):
        if not self.dirty:
            return
        follow = self.query_one("#transcript", VerticalScroll).is_vertical_scroll_end
        for item_id in self.dirty:
            item = self.items[item_id]
            widget = self.widgets.get(item_id)
            if isinstance(widget, Reply):
                widget.update_source(item.get("text", ""))
            elif widget:
                widget.update(tool_content(item))
        self.dirty.clear()
        self.follow_if_bottom(force=follow)

    async def handle_event(self, message):
        method, p = message.get("method", ""), message.get("params", {})
        if p.get("threadId") and p["threadId"] != self.thread_id:
            return
        if "id" in message and "method" in message:
            self.run_worker(self.server_request(message), name=f"request-{message['id']}")
        elif method in ("item/started", "item/completed"):
            await self.show_item(p["item"], completed=method == "item/completed")
        elif method in ("item/agentMessage/delta", "item/plan/delta"):
            item_id = p["itemId"]
            if item_id not in self.items:
                await self.show_item({"id": item_id, "type": "agentMessage", "text": ""})
            self.items[item_id]["text"] = self.items[item_id].get("text", "") + p["delta"]
            self.dirty.add(item_id)
        elif method == "item/commandExecution/outputDelta":
            item_id = p["itemId"]
            if item_id in self.items:
                item = self.items[item_id]
                item["aggregatedOutput"] = item.get("aggregatedOutput", "") or ""
                item["aggregatedOutput"] += p["delta"]
                self.dirty.add(item_id)
        elif method == "turn/started":
            self.turn_id, self.busy = p["turn"]["id"], True
            self.status("Working...")
            if self.stop_requested:
                self.run_worker(self.action_interrupt(), name="pending-stop")
        elif method == "turn/completed":
            self.flush()
            self.turn_id, self.busy = None, False
            self.stop_requested = False
            turn = p["turn"]
            if turn.get("error"):
                await self.notice(turn["error"].get("message", "Turn failed"), error=True)
            self.status("Stopped" if turn.get("status") == "interrupted" else "Ready")
            self.update_groups()
        elif method in ("error", "cx/disconnected"):
            error = p.get("error") or p
            await self.notice(error.get("message", "Codex reported an error"), error=True)
            if method == "cx/disconnected":
                self.ready, self.busy, self.turn_id = False, False, None
                self.status("Disconnected. Restart with cx --resume.")
        elif method in ("warning", "guardianWarning", "configWarning", "deprecationNotice"):
            await self.notice(p.get("message") or p.get("summary") or json.dumps(p, ensure_ascii=False))
        elif method == "thread/compacted":
            await self.notice("Codex compacted the conversation. Earlier messages remain in history.")
        elif method == "thread/tokenUsage/updated":
            usage = p.get("tokenUsage", {})
            used = usage.get("last", {}).get("totalTokens")
            limit = usage.get("modelContextWindow")
            if used is not None and limit:
                self.context = f"   ·   {round(used / limit * 100)}% context"
                self.update_bar()
        elif method == "serverRequest/resolved":
            request_id = p.get("requestId")
            for screen in list(self.screen_stack):
                if isinstance(screen, RequestScreen) and getattr(screen, "request_id", None) == request_id:
                    screen.dismiss(None)

    async def server_request(self, message):
        try:
            await self.answer_request(message)
        except (RpcError, OSError, asyncio.TimeoutError) as exc:
            await self.notice(f"Could not send your answer to Codex: {exc}", error=True)
            if not self.ready:
                self.status("Disconnected. Restart with cx --resume.")

    async def answer_request(self, message):
        method, p = message["method"], dict(message.get("params", {}))
        if method not in ("item/tool/requestUserInput", "item/commandExecution/requestApproval", "item/fileChange/requestApproval"):
            await self.notice(f"Unsupported Codex request: {method}. The request was declined.", error=True)
            await self.client.respond(message["id"], error={"code": -32601, "message": f"cx does not support {method}"})
            return
        if method == "item/fileChange/requestApproval":
            p["changes"] = self.items.get(p.get("itemId"), {}).get("changes", [])
        screen = RequestScreen(method, p)
        screen.request_id = message["id"]
        self.status("Your answer is needed")
        answer = await self.push_screen_wait(screen)
        if answer is not None:
            await self.client.respond(message["id"], answer)
        self.status("Working..." if self.busy else "Ready")

    @on(Prompt.Submitted)
    async def prompt_submitted(self, event):
        event.stop()
        self.run_worker(self.submit(event.text), name="submit")

    async def submit(self, text):
        if text.startswith("/"):
            await self.command(text)
            return
        if not self.ready:
            await self.notice("Codex is not connected yet. Your prompt is still in the input.")
            return
        if self.submitting:
            return
        self.submitting = True
        client_id = str(uuid.uuid4())
        user_widget = None
        was_busy = self.busy
        try:
            method = "turn/steer" if self.busy else "turn/start"
            params = {"threadId": self.thread_id, "input": [{"type": "text", "text": text}], "clientUserMessageId": client_id}
            if self.busy:
                if not self.turn_id:
                    raise RpcError("The current turn is still starting. Try again in a moment.")
                params["expectedTurnId"] = self.turn_id
            else:
                self.current_group = None
                self.busy = True
                self.stop_requested = False
            self.seen_users.add(client_id)
            user_widget = await self.add_user(text)
            self.query_one("#prompt", Prompt).clear()
            self.follow_if_bottom(force=True)
            result = await self.client.request(method, params)
            if self.busy and self.turn_id is None and result.get("turn"):
                self.turn_id = result["turn"]["id"]
                if self.stop_requested:
                    await self.action_interrupt()
        except (RpcError, asyncio.TimeoutError) as exc:
            self.seen_users.discard(client_id)
            if not was_busy and not self.turn_id:
                self.busy = False
            if user_widget:
                await user_widget.remove()
            if not self.query_one("#prompt", Prompt).text:
                self.query_one("#prompt", Prompt).load_text(text)
            await self.notice(f"Prompt was not sent: {exc}", error=True)
        finally:
            self.submitting = False

    async def command(self, text):
        name, _, argument = text.strip().partition(" ")
        if name == "/help":
            await self.notice("/new: new chat   /resume [id]: resume chat   /details: toggle tool output\n/status: session details   /model [name]: show or change model\n/quit: exit   Enter during work: steer   Ctrl+C: stop   Alt+Enter: newline")
        elif name in ("/details", "/focus"):
            self.action_toggle_tools()
        elif name in ("/quit", "/exit"):
            await self.action_leave()
            return
        elif name == "/status":
            await self.notice(f"Session: {self.thread_id or 'not connected'}\nFolder: {self.cwd}\nModel: {self.model}")
        elif name in ("/new", "/resume", "/model"):
            if not self.ready or self.busy:
                await self.notice("Stop the current turn before changing sessions or models.")
                return
            try:
                if name == "/model":
                    if argument:
                        page = await self.client.request("model/list", {"limit": 100})
                        if argument not in [m["id"] for m in page["data"]]:
                            raise RpcError("Unknown model. Run /model to see available models.")
                        result = await self.client.request("thread/resume", {"threadId": self.thread_id, "model": argument, "excludeTurns": True})
                        self.model = result.get("model") or argument
                        self.update_bar()
                    else:
                        page = await self.client.request("model/list", {"limit": 100})
                        await self.notice("Available models:\n" + "\n".join(m["id"] for m in page["data"]))
                else:
                    resume = argument or (json.loads(self.last_file.read_text())["threadId"] if name == "/resume" and self.last_file.exists() else None)
                    await self.open_thread(resume, reset=True)
            except (RpcError, OSError, ValueError, asyncio.TimeoutError) as exc:
                await self.notice(str(exc), error=True)
        else:
            await self.notice(f"Unknown command: {name}. Use /help. To send a slash prompt literally, start it with a space.")
            return
        self.query_one("#prompt", Prompt).clear()

    def action_toggle_tools(self):
        self.focus_view = not self.focus_view
        for group in self.groups:
            group.collapsed = self.focus_view
        self.update_bar()

    def action_follow(self):
        self.follow_if_bottom(force=True)

    async def action_new_thread(self):
        self.run_worker(self.command("/new"), name="new-thread")

    async def action_interrupt(self):
        if isinstance(self.screen, RequestScreen):
            self.screen.action_cancel()
        elif self.turn_id:
            try:
                await asyncio.wait_for(self.client.request("turn/interrupt", {"threadId": self.thread_id, "turnId": self.turn_id}), 5)
                self.status("Stopping...")
            except (RpcError, asyncio.TimeoutError) as exc:
                await self.notice(str(exc), error=True)
        elif self.busy:
            self.stop_requested = True
            self.status("Stopping as soon as Codex starts the turn...")
        else:
            self.query_one("#prompt", Prompt).clear()
            self.status("Ready. Ctrl+Q exits.")

    async def action_leave(self):
        if self.turn_id:
            try:
                await asyncio.wait_for(self.client.request("turn/interrupt", {"threadId": self.thread_id, "turnId": self.turn_id}), 5)
            except (RpcError, asyncio.TimeoutError):
                pass
        await self.client.close()
        self.exit()

    async def on_unmount(self):
        await self.client.close()


def main():
    parser = argparse.ArgumentParser(description="A focused terminal interface for Codex.")
    parser.add_argument("prompt", nargs="*", help="Initial prompt")
    parser.add_argument("--resume", "-r", nargs="?", const="last", help="Resume the last cx chat in this folder, or a thread ID")
    parser.add_argument("--cwd", "-C", help="Working folder")
    parser.add_argument("--version", action="version", version="cx 0.1.0")
    args = parser.parse_args()
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        parser.error("cx needs an interactive terminal. Use codex exec for scripts.")
    CxApp(cwd=args.cwd, resume=args.resume, initial_prompt=" ".join(args.prompt)).run()


if __name__ == "__main__":
    main()
