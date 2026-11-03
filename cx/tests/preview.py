import asyncio
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from cx import CxApp


async def preview(destination):
    with tempfile.TemporaryDirectory(prefix="cx-preview-") as state:
        app = CxApp(cwd="/workspace/cx", offline=True, state_dir=state)
        async with app.run_test(size=(110, 36)) as pilot:
            app.ready, app.model = True, "gpt-6.1-sol"
            app.update_bar()
            await app.add_user("Check the login flow and fix the failing test.")
            await app.show_item({"type": "agentMessage", "id": "progress", "text": "The failure comes from an expired session cookie. Checking the refresh handler."}, completed=True)
            await app.show_item({"type": "commandExecution", "id": "tool-1", "command": "python -m unittest tests.test_login", "aggregatedOutput": "Ran 8 tests\nOK", "exitCode": 0}, completed=True)
            await app.show_item({"type": "fileChange", "id": "tool-2", "changes": [{"path": "auth/session.py", "diff": "+ refresh the session before redirecting"}], "status": "completed"}, completed=True)
            await app.show_item({"type": "agentMessage", "id": "answer", "text": "⟶ Login now refreshes your session before redirecting.\n\n- The session refresh handles expired cookies.\n- All **8 login tests** pass.\n\n✓ Done: login flow fixed.\n\n⟶ Next: try signing in with an expired session."}, completed=True)
            app.status("Ready")
            await pilot.pause()
            app.save_screenshot(filename="cx-focus.svg", path=destination)
            app.action_toggle_tools()
            await pilot.pause()
            app.save_screenshot(filename="cx-details.svg", path=destination)
            await pilot.resize_terminal(55, 26)
            app.action_toggle_tools()
            await pilot.pause()
            app.save_screenshot(filename="cx-narrow.svg", path=destination)
            print("Rendered focus, details, and narrow terminal previews.")


if __name__ == "__main__":
    asyncio.run(preview(sys.argv[1]))
