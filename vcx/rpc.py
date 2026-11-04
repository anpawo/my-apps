import asyncio
import json
import os


class RpcError(Exception):
    pass


class CodexClient:
    def __init__(self, command=None):
        self.command = command or ["codex", "app-server"]
        self.events = asyncio.Queue()
        self.pending = {}
        self.sequence = 0
        self.process = None
        self.tasks = []
        self.closing = False

    async def start(self):
        # Fleet must not attribute this server to the Claude session that installed cx.
        env = {k: v for k, v in os.environ.items() if not k.startswith("CLAUDE")}
        self.process = await asyncio.create_subprocess_exec(
            *self.command, stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
            env=env, limit=32 * 1024 * 1024, start_new_session=True,
        )
        self.tasks = [asyncio.create_task(self.read()), asyncio.create_task(self.drain_stderr())]
        await self.request("initialize", {
            "clientInfo": {"name": "cx", "title": "cx", "version": "0.1.0"},
            "capabilities": {"experimentalApi": True},
        })
        await self.send({"method": "initialized", "params": {}})

    async def send(self, message):
        if not self.process or self.process.returncode is not None:
            raise RpcError("Codex is disconnected. Restart cx with --resume to continue.")
        try:
            self.process.stdin.write((json.dumps(message) + "\n").encode())
            await self.process.stdin.drain()
        except (BrokenPipeError, ConnectionResetError) as exc:
            raise RpcError("The connection to Codex closed.") from exc

    async def request(self, method, params=None):
        self.sequence += 1
        request_id = self.sequence
        future = asyncio.get_running_loop().create_future()
        self.pending[request_id] = future
        try:
            await self.send({"id": request_id, "method": method, "params": params or {}})
            return await asyncio.wait_for(future, 120)
        finally:
            self.pending.pop(request_id, None)

    async def respond(self, request_id, result=None, error=None):
        await self.send({"id": request_id, **({"error": error} if error else {"result": result})})

    async def read(self):
        reason = "The connection to Codex closed. Use cx --resume to continue."
        try:
            while line := await self.process.stdout.readline():
                message = json.loads(line)
                if "method" not in message and "id" in message:
                    future = self.pending.get(message["id"])
                    if future and not future.done():
                        if "error" in message:
                            future.set_exception(RpcError(message["error"].get("message", "Codex request failed")))
                        else:
                            future.set_result(message.get("result", {}))
                else:
                    await self.events.put(message)
        except (ValueError, OSError) as exc:
            reason = f"Invalid response from Codex: {exc}"
        finally:
            for future in self.pending.values():
                if not future.done():
                    future.set_exception(RpcError(reason))
            if not self.closing:
                await self.events.put({"method": "cx/disconnected", "params": {"message": reason}})

    async def drain_stderr(self):
        while await self.process.stderr.read(65536):
            pass

    async def close(self):
        self.closing = True
        if self.process and self.process.returncode is None:
            self.process.stdin.close()
            try:
                await asyncio.wait_for(self.process.wait(), 3)
            except asyncio.TimeoutError:
                self.process.terminate()
                try:
                    await asyncio.wait_for(self.process.wait(), 3)
                except asyncio.TimeoutError:
                    self.process.kill()
                    await self.process.wait()
        for task in self.tasks:
            task.cancel()
        await asyncio.gather(*self.tasks, return_exceptions=True)
