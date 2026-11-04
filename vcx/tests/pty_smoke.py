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
                ["/bin/zsh", "-f", "-c", '"$@"; result=$?; printf "\\nCX_RETURNED:%s\\n" "$result"; read -r reply; test "$reply" = cx-shell-alive',
                 "cx-smoke", str(Path.home() / ".local/bin/cx"), "--cwd", cwd],
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
            os.write(master, b"\x03")
            output.clear()
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                if select.select([master], [], [], 0.1)[0]:
                    try:
                        output.extend(os.read(master, 65536))
                    except OSError:
                        break
                    if b"CX_RETURNED:0" in output:
                        break
            assert b"CX_RETURNED:0" in output, "Ctrl+C did not exit cx cleanly"
            assert b"\x1b[?1049l" in output, "cx did not restore the terminal screen"
            assert process.poll() is None, "Ctrl+C killed the shell"
            os.write(master, b"cx-shell-alive\n")
            process.wait(timeout=5)
            assert process.returncode == 0, "Shell did not accept input after cx exited"
            print("PASS: installed cx connects, Ctrl+C exits cleanly, and the shell still accepts input")
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
