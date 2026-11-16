"""Isolated official app-server protocol check; no TUI, model turn or real data.

Uses a new HOME and CODEX_HOME. Only booleans are reported; native responses
are never printed or saved. This is not iTerm/Spaces/notification acceptance.
"""
import argparse
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import tempfile
import time

def interrupted(signum, frame):
    raise SystemExit("Owned native dependency check interrupted")

signal.signal(signal.SIGTERM, interrupted)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--codex", required=True, type=Path)
    parser.add_argument("--helper", required=True, type=Path)
    options = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="aar-native-dependency-") as temporary:
        root = Path(temporary).resolve()
        home, codex_home, work = root / "home", root / "codex-home", root / "work"
        for path in [home, codex_home, work]:
            path.mkdir(mode=0o700)
        env = {"HOME": str(home), "CODEX_HOME": str(codex_home), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": str(root)}
        check = subprocess.run([str(options.helper.absolute()), "check-bridge-dependencies", "--native-codex", str(options.codex.absolute())],
                               capture_output=True, env=env, timeout=40)
        assert check.returncode == 0, "Dependency check failed: " + check.stderr.decode(errors="replace")[:700]
        child = subprocess.Popen([str(options.codex.absolute()), "app-server", "--stdio"], cwd=work, env=env,
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        selector = selectors.DefaultSelector()
        selector.register(child.stdout, selectors.EVENT_READ)
        buffer = b""
        def request(identifier, method, params):
            nonlocal buffer
            child.stdin.write(json.dumps({"id": identifier, "method": method, "params": params}).encode() + b"\n")
            child.stdin.flush()
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                while b"\n" in buffer:
                    line, buffer = buffer.split(b"\n", 1)
                    value = json.loads(line)
                    if value.get("id") == identifier:
                        assert "error" not in value, "Native protocol request failed: " + method
                        return value["result"]
                assert child.poll() is None, "Owned native server exited"
                if selector.select(.1):
                    buffer += os.read(child.stdout.fileno(), 65536)
                    assert len(buffer) <= 2_097_152, "Native response exceeded check bound"
            raise AssertionError("Native protocol timed out: " + method)
        try:
            request(1, "initialize", {"clientInfo": {"name": "aar_delivery_check", "version": "0"}, "capabilities": {"experimentalApi": True}})
            child.stdin.write(b'{"method":"initialized"}\n'); child.stdin.flush()
            created = request(2, "thread/start", {"cwd": str(work), "ephemeral": True})
            thread_id = created["thread"]["id"]
            assert isinstance(thread_id, str) and thread_id
            request(3, "thread/unsubscribe", {"threadId": thread_id})
            print(json.dumps({"reviewed_dependency_check": "pass", "native_initialize": "pass",
                              "native_ephemeral_thread_start_unsubscribe": "pass", "isolated_home": True,
                              "real_data_or_credentials_used": False, "model_turns": 0,
                              "terminal_origin_and_focus": "not tested", "visible_notifications": "not tested"}, indent=2))
        finally:
            selector.close()
            if child.poll() is None:
                child.terminate()
                child.wait(timeout=8)


if __name__ == "__main__":
    main()
