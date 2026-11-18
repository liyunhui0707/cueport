"""Bounded second-Mac package checks, using synthetic data only.

The output directory must be new. No downloads, dependency installation,
permissions, real Codex sessions or ordinary user settings are changed.
"""
import argparse
import hashlib
import json
import os
import signal
from pathlib import Path
import subprocess
import sys
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--codex", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    options = parser.parse_args()
    os.umask(0o077)
    output = options.output.absolute()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    app = options.app.absolute()
    scripts = Path(__file__).resolve().parent
    env = {**os.environ, "AAR_REVIEW_APP": str(app)}
    checks = [
        ("install_update_rollback", [sys.executable, str(scripts / "test_installation.py"), "--app", str(app)], 90),
        ("startup_duplicate_and_profile", [sys.executable, str(scripts / "test_startup_profile.py")], 90),
        ("closed_process_filter", [sys.executable, str(scripts / "test_open_threads.py")], 90),
        ("native_dependency_protocol", [sys.executable, str(scripts / "test_native_dependency.py"), "--codex", str(options.codex.absolute()), "--helper", str(app / "Contents/MacOS/aar")], 90),
        ("native_sample_views", [str(app / "Contents/MacOS/CueportApp"), "--render-previews", str(output / "sample-views")], 90),
    ]
    results = {}
    for name, command, timeout in checks:
        started = time.monotonic()
        child = subprocess.Popen(command, cwd=output, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        try:
            stdout, stderr = child.communicate(timeout=timeout)
            (output / (name + ".log")).write_bytes(stdout + stderr)
            results[name] = {"status": "PASS" if child.returncode == 0 else "FAIL", "exit_code": child.returncode,
                             "duration_s": round(time.monotonic() - started, 3)}
        except subprocess.TimeoutExpired:
            # Only the process group created for this check. Python fixtures
            # handle TERM through their finally blocks (including owned PTYs).
            os.killpg(child.pid, signal.SIGTERM)
            try:
                stdout, stderr = child.communicate(timeout=8)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                stdout, stderr = child.communicate(timeout=5)
            (output / (name + ".log")).write_bytes(stdout + stderr)
            results[name] = {"status": "INCOMPLETE", "reason": "bounded timeout"}
        print(json.dumps({"check": name, **results[name]}), flush=True)
        if results[name]["status"] != "PASS":
            # Preserve the failed batch; a focused follow-up can be recorded
            # separately after diagnosis, without repeating unrelated GUI work.
            break
    report = {"checks": results, "app_executable_sha256": hashlib.sha256((app / "Contents/MacOS/CueportApp").read_bytes()).hexdigest(),
              "helper_sha256": hashlib.sha256((app / "Contents/MacOS/aar").read_bytes()).hexdigest(),
              "real_codex_tui_origin_and_spaces": "NOT_RUN", "visible_system_banners": "NOT_RUN",
              "real_sessions_or_credentials": "not used", "model_turns": 0, "permission_changes": "none",
              "sample_views": "native sample renders, not real-session screenshots"}
    (output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    if any(value["status"] != "PASS" for value in results.values()):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
