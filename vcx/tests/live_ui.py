import asyncio
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from cx import CxApp, Prompt, Reply


async def wait_for(predicate, timeout=120):
    async with asyncio.timeout(timeout):
        while not predicate():
            await asyncio.sleep(0.1)


async def main():
    with tempfile.TemporaryDirectory(prefix="cx-ui-live-") as cwd:
        app = CxApp(cwd=cwd, state_dir=Path(cwd) / "state")
        async with app.run_test(size=(100, 32)) as pilot:
            await wait_for(lambda: app.ready)
            app.query_one(Prompt).load_text("Run printf CX_UI_TOOL, then reply exactly CX_UI_REPLY. Do not edit files.")
            await pilot.press("enter")
            await wait_for(lambda: any(isinstance(w, Reply) and "CX_UI_REPLY" in w.source for w in app.widgets.values()) and not app.busy)
            await pilot.pause()
            self_order = [w.__class__.__name__ for w in app.query_one("#transcript").children]
            assert self_order[0] == "Static", self_order
            assert len(app.query(".user-message")) == 1, "User prompt duplicated"
            assert any("CX_UI_TOOL" in (item.get("aggregatedOutput") or "") for item in app.items.values()), "Tool output missing"
            assert all(group.collapsed for group in app.groups)
            assert len(app.query(".error")) == 0, "Unexpected UI errors"
            print("PASS: live frontend input, streamed reply, prompt order, tool capture and folding", flush=True)
            await app.submit("Run the shell command sleep 20, then reply CX_SLEEP_DONE. Do not edit files.")
            await wait_for(lambda: any(item.get("type") == "commandExecution" and "sleep 20" in item.get("command", "") for item in app.items.values()))
            await pilot.press("ctrl+c")
            await wait_for(lambda: not app.busy, timeout=15)
            print("PASS: Ctrl+C interrupts a real running Codex turn", flush=True)
        resumed = CxApp(cwd=cwd, state_dir=Path(cwd) / "state", resume="last")
        async with resumed.run_test(size=(100, 32)) as pilot:
            await wait_for(lambda: resumed.ready)
            assert any(isinstance(w, Reply) and "CX_UI_REPLY" in w.source for w in resumed.widgets.values())
            assert len(resumed.query(".user-message")) == 2
            print("PASS: frontend resume restores real conversation and tool history", flush=True)


if __name__ == "__main__":
    asyncio.run(main())
