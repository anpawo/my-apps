import asyncio
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from rpc import CodexClient


async def main():
    client = CodexClient()
    with tempfile.TemporaryDirectory(prefix="cx-live-") as cwd:
        try:
            await client.start()
            result = await client.request("thread/start", {"cwd": cwd})
            thread_id = result["thread"]["id"]
            print("PASS: Codex handshake and thread creation", flush=True)
            await client.request("turn/start", {"threadId": thread_id, "input": [{"type": "text", "text": "Run the shell command printf CX_TOOL_OK, then reply exactly CX_LIVE_OK. Do not edit any files."}]})
            replies, tools, streamed = [], [], False
            async with asyncio.timeout(180):
                while True:
                    event = await client.events.get()
                    method, params = event.get("method"), event.get("params", {})
                    if "id" in event and method:
                        raise AssertionError("Unexpected interactive request during read-only live smoke")
                    if method == "item/agentMessage/delta":
                        streamed = True
                    if method == "item/completed":
                        item = params["item"]
                        if item["type"] == "agentMessage":
                            replies.append(item["text"])
                        if item["type"] == "commandExecution":
                            tools.append(item)
                    if method == "error":
                        raise AssertionError("Codex reported a live error")
                    if method == "turn/completed":
                        assert params["turn"]["status"] == "completed", params["turn"]["status"]
                        break
            assert streamed, "No streamed text"
            assert any("CX_LIVE_OK" in reply for reply in replies), "Expected reply absent"
            assert any("CX_TOOL_OK" in (item.get("aggregatedOutput") or "") and item.get("exitCode") == 0 for item in tools), "Expected tool output absent"
            print("PASS: real streamed reply and shell tool execution", flush=True)
            result = await client.request("thread/resume", {"threadId": thread_id, "excludeTurns": True})
            assert result["thread"]["id"] == thread_id
            history = await client.request("thread/turns/list", {"threadId": thread_id, "itemsView": "full", "sortDirection": "asc"})
            assert any(item.get("type") == "agentMessage" and "CX_LIVE_OK" in item.get("text", "") for turn in history["data"] for item in turn.get("items", []))
            print("PASS: session resume and persisted history", flush=True)
        finally:
            await client.close()


if __name__ == "__main__":
    asyncio.run(main())
