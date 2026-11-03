import fcntl
import os
import select
import struct
import subprocess
import tempfile
import termios
import time
from pathlib import Path


def main():
    master, slave = os.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 32, 100, 0, 0))
    env = {k: v for k, v in os.environ.items() if not k.startswith("CLAUDE") and k != "NO_COLOR"}
    env.update(TERM="xterm-256color", COLORTERM="truecolor")
    process = None
    try:
        with tempfile.TemporaryDirectory(prefix="cx-terminal-") as cwd:
            process = subprocess.Popen(
                [str(Path.home() / ".local/bin/cx"), "--cwd", cwd],
                stdin=slave, stdout=slave, stderr=slave, env=env, start_new_session=True,
            )
            os.close(slave)
            slave = None
            output = bytearray()
            deadline = time.monotonic() + 45
            while time.monotonic() < deadline:
                if select.select([master], [], [], 0.1)[0]:
                    output.extend(os.read(master, 65536))
                    if b"Ready" in output:
                        break
                if process.poll() is not None:
                    raise AssertionError("cx exited before connecting")
            assert b"Ready" in output, "cx did not connect within 45 seconds"
            assert b"FOCUS" in output, "Focus header absent"
            assert b"\x1b[?1049h" in output, "Alternate screen absent"
            assert b"48;2;" in output, "Truecolor backgrounds absent"
            os.write(master, b"\x11")
            while process.poll() is None and time.monotonic() < deadline:
                if select.select([master], [], [], 0.1)[0]:
                    try:
                        os.read(master, 65536)
                    except OSError:
                        break
            process.wait(timeout=5)
            assert process.returncode == 0, "cx did not exit cleanly"
            print("PASS: installed cx connects, renders focus mode with truecolor, and Ctrl+Q exits cleanly")
    finally:
        if process and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        os.close(master)
        if slave is not None:
            os.close(slave)


if __name__ == "__main__":
    main()
