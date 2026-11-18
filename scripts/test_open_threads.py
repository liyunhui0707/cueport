"""Native closed/exit filtering of registered threads using an owned PTY fixture.

No real Codex, user terminal, model task, notification or iTerm API is used.
The fixture is deliberately named codex to exercise the OS-origin probe; it
only prints its own process metadata then pauses. No terminal input is sent.
"""
import json
import os
import pathlib
import plistlib
import select
import shutil
import signal
import subprocess
import time
import uuid

def interrupted(signum, frame):
    raise SystemExit("Owned filtering check interrupted")

signal.signal(signal.SIGTERM, interrupted)

ROOT = pathlib.Path(__file__).resolve().parent.parent
BASE = ROOT / "build/poc/open-threads169"


def main():
    os.umask(0o077)
    directory = BASE / ("native-" + uuid.uuid4().hex)
    directory.mkdir(mode=0o700, parents=True)
    source = directory / "fixture.c"
    source.write_text(r'''
#include <libproc.h>
#include <sys/proc_info.h>
#include <unistd.h>
#include <stdio.h>
int main(void) {
    struct proc_bsdinfo info = {0};
    if (proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return 2;
    printf("{\"pid\":%d,\"uid\":%u,\"startMicroseconds\":%llu,\"processGroup\":%u,\"terminalGroup\":%u,\"terminalDevice\":%u,\"hasControllingTerminal\":%s,\"isCodex\":true,\"capturedAt\":0}\n",
        getpid(), info.pbi_uid, (unsigned long long)info.pbi_start_tvsec * 1000000 + info.pbi_start_tvusec,
        info.pbi_pgid, info.e_tpgid, info.e_tdev, info.pbi_flags & PROC_FLAG_CTTY ? "true" : "false");
    fflush(stdout);
    for (;;) pause();
}
''')
    fixture = directory / "codex"
    subprocess.run(["/usr/bin/clang", str(source), "-o", str(fixture)], check=True, capture_output=True)
    clone = directory / "LiveListCheck.app"
    shutil.copytree(pathlib.Path(os.environ.get("AAR_REVIEW_APP", str(ROOT / "build/artifacts.noindex/Cueport.app"))), clone)
    plist = clone / "Contents/Info.plist"
    info = plistlib.loads(plist.read_bytes())
    info["CFBundleIdentifier"] = "org.agentattentionrouter.open-thread-check." + uuid.uuid4().hex
    info["AARBuildChannel"] = "review"
    plist.write_bytes(plistlib.dumps(info))
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(clone)], check=True, capture_output=True)
    executable = clone / "Contents/MacOS/CueportApp"
    helper = executable.with_name("aar")
    data = directory / "data"
    child = None; fixture_pid = None; master = None
    log = (directory / "app.log").open("wb")
    try:
        fixture_pid, master = os.forkpty()
        if fixture_pid == 0:
            os.execv(str(fixture), [str(fixture)])
        raw = b""; deadline = time.monotonic() + 10
        while b"\n" not in raw and time.monotonic() < deadline:
            if select.select([master], [], [], .1)[0]: raw += os.read(master, 4096)
        process = json.loads(raw.splitlines()[0])
        assert process["pid"] == fixture_pid and process["processGroup"] == process["terminalGroup"] == fixture_pid
        origin = {"terminal": {"type": "iterm2", "sessionID": "12345678-1234-1234-1234-123456789ABC"}, "process": process}
        child = subprocess.Popen([str(executable), "--bridge-poc", "--data-dir", str(data), "--no-notifications"], stdout=log, stderr=log)

        def read(name):
            try: return json.loads((data / name).read_text())
            except (FileNotFoundError, json.JSONDecodeError): return None

        def wait(check, timeout=15):
            end = time.monotonic() + timeout
            while time.monotonic() < end:
                assert child.poll() is None
                value = check()
                if value: return value
                time.sleep(.03)
            raise AssertionError("Timed out waiting for open-thread filter")

        wait(lambda: h if (h := read("runtime-health.json")) and h["pid"] == child.pid else None)
        events = []
        for thread in ["synthetic-one", "synthetic-two"]:
            event = {"schema": 1, "id": uuid.uuid4().hex, "kind": "sessionStarted", "sessionID": thread,
                     "project": "Synthetic current terminal", "timestamp": time.time() - 978307200,
                     "source": "codex-protocol", "questionIDs": [], "executionObservation": "idle",
                     "protocolBinding": {"id": thread, "origin": origin}}
            events.append(event)
            file = directory / "event.json"; file.write_text(json.dumps(event))
            subprocess.run([str(helper), "replay", "--file", str(file), "--data-dir", str(data)], check=True, capture_output=True)
            wait(lambda: s if (s := read("state.json")) and event["id"] in s["processed"] else None)
        question = {"schema": 1, "id": uuid.uuid4().hex, "kind": "questionQueued", "sessionID": "synthetic-one",
                    "project": "Synthetic current terminal", "timestamp": time.time() - 978307200,
                    "source": "codex-protocol", "questionIDs": ["synthetic-question"],
                    "protocolBinding": {"id": "synthetic-one", "origin": origin}}
        file.write_text(json.dumps(question))
        subprocess.run([str(helper), "replay", "--file", str(file), "--data-dir", str(data)], check=True, capture_output=True)
        wait(lambda: s if (s := read("state.json")) and question["id"] in s["processed"] else None)
        wait(lambda: h if (h := read("runtime-health.json")) and h["mainListCounts"]["visibleThreads"] == 2 and h["unavailableTerminalChecks"] == 0 else None)
        snapshot = read("state.json")
        mode = os.environ.get("AAR_CLOSE_MODE", "exit")
        assert mode in ["exit", "hangup"]
        if mode == "hangup":
            os.close(master); master = None  # Normal terminal-master closure, no input.
        else:
            os.kill(fixture_pid, signal.SIGTERM)
        end = time.monotonic() + 5
        while time.monotonic() < end:
            if os.waitpid(fixture_pid, os.WNOHANG)[0]:
                fixture_pid = None; break
            time.sleep(.02)
        assert fixture_pid is None, "Owned fixture did not exit after normal close"
        closed_at = time.monotonic()
        wait(lambda: h if (h := read("runtime-health.json")) and h["mainListCounts"]["visibleThreads"] == 0 else None)
        delay = time.monotonic() - closed_at
        assert read("state.json") == snapshot, "Removing a closed pane changed thread history"
        assert len(snapshot["sessions"]) == 2 and all(next(iter(s["protocolBindings"].values()))["connected"] for s in snapshot["sessions"].values())
        assert snapshot["sessions"]["synthetic-one"]["requests"]["synthetic-question"]["evidence"] == "observed"
        result = {"two_threads_retained_in_one_group_before_exit": True, "close_mode": mode,
                  "closed_owned_process_hidden_without_source_lost_event": True, "outstanding_question_preserved": True,
                  "observed_removal_delay_s": round(delay, 3), "snapshot_bindings_and_ids_unchanged": True,
                  "real_codex_or_iterm_terminal": "not used", "terminal_input": "not sent",
                  "notifications_and_navigation": "not exercised", "menu_clicks": "not exercised"}
        (directory / "result.json").write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result, indent=2))
    finally:
        if child and child.poll() is None:
            child.terminate(); child.wait(timeout=5)
        if fixture_pid:
            os.kill(fixture_pid, signal.SIGTERM); os.waitpid(fixture_pid, 0)
        if master is not None: os.close(master)
        log.close()


if __name__ == "__main__":
    main()
